provider "aws" {}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # canonical id
}

### get default vpc
data "aws_vpc" "selected" {
  default = true
}

data "aws_subnet_ids" "example" {
  vpc_id = data.aws_vpc.selected.id
}

data "aws_subnet" "example" {
  for_each = data.aws_subnet_ids.example.ids
  id       = each.value
}

### security group used by the ec2 instances spinned up by the ASGs
resource "aws_security_group" "launch_config_security_group" {
  vpc_id      = data.aws_vpc.selected.id
  name        = "launch_config_security_group"
  description = "used by the ec2 instances spinned up by the ASG"

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups  = [aws_security_group.alb_security_group.id] # allow traffic comming from ALB to the ec2 instances using this launch config
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### alb security group - allowing port 80
resource "aws_security_group" "alb_security_group" {
  vpc_id      = data.aws_vpc.selected.id
  name        = "alb_security_group"
  description = "security group for the application load balancer"

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "launch_configuration_default" {
  name_prefix   = "launch_configuration_default"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  lifecycle {
    create_before_destroy = true
  }

  security_groups = [aws_security_group.launch_config_security_group.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get install nginx -y
              echo 'asg default' > /var/www/html/index.html
              sudo systemctl --now enable nginx
              EOF
}

### template file to setup nginx on the launch configuration for /videos
data "template_file" "script" {
  template = "${file("${path.module}/cloud_config_nginx_videos.yaml")}"
}

data "template_cloudinit_config" "config" {
   gzip          = true
   base64_encode = true

   part {
     filename     = "default"
     content_type = "text/cloud-config"
     content      = "${data.template_file.script.rendered}"
   }   
 }

### launch config that will spin up ec2 instances replying to /videos/ 
resource "aws_launch_configuration" "launch_configuration_videos" {
  name_prefix   = "launch_configuration_videos"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  lifecycle {
    create_before_destroy = true
  }

  security_groups = [aws_security_group.launch_config_security_group.id]
  user_data     = data.template_cloudinit_config.config.rendered # nginx installation and adding a location block for /videos/
}

resource "aws_autoscaling_group" "asg-default" {
  name                 = "asg-default"
  launch_configuration = aws_launch_configuration.launch_configuration_default.id
  min_size             = 1
  max_size             = 2
  desired_capacity     = 2

  vpc_zone_identifier = [for s in data.aws_subnet.example : s.id]
  target_group_arns   = [aws_lb_target_group.target_group_default.arn] # all ec2 instances spinned up by this asg will be associated with the target group

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [load_balancers, target_group_arns]
  }

  wait_for_capacity_timeout = "15m"
}

resource "aws_autoscaling_group" "asg-videos" {
  name                 = "asg-videos"
  launch_configuration = aws_launch_configuration.launch_configuration_videos.id # specifying the launch config that has the /videos/ available
  min_size             = 3
  max_size             = 4
  desired_capacity     = 4

  vpc_zone_identifier = [for s in data.aws_subnet.example : s.id]
  target_group_arns   = [aws_lb_target_group.target_group_videos.arn] # all ec2 instances spinned up by this asg will be associated with the target group

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [load_balancers, target_group_arns]
  }

  wait_for_capacity_timeout = "15m"
}

resource "aws_lb_target_group" "target_group_default" {
  name     = "target-group-default"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.selected.id
}

resource "aws_lb_target_group" "target_group_videos" {
  name     = "target-group-videos"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.selected.id
}

resource "aws_lb" "alb_sample" {
  name               = "alb-sample"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_security_group.id]
  subnets            = [for s in data.aws_subnet.example : s.id]

  enable_deletion_protection = false
}

resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.alb_sample.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_default.arn # listener will forward traffic to the target group which is binded to the asg already
  }
}

### rule that will forward traffic to the target_group_videos/asg-videos
resource "aws_lb_listener_rule" "videos_rule" {
  listener_arn = aws_lb_listener.alb_listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group_videos.arn
  }

  condition {
    path_pattern {
      values = ["/videos/*"]
    }
  }
}
