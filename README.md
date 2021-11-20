# alb-multiple-asgs-sample

# This sample will:

 - use default vpc
 - use ubuntu-focal-20.04-amd64 ami from canonical
 - build two security groups 
   * first one for the auto scaling groups instances (port 22 opened, optionally)
   * second one for the ALB (port 80 opened)
 - build two launch configurations:
   - build a launch configuration that installs nginx (will be used as template for the auto scaling group instances)
   - build a launch configuration that uses template_file containing a cloud-init script that will install nginx and create a route /videos/ 
 - build two auto scaling groups:
   - first one for the default route domain.com/
   - second one for the /videos/ route
 - build two target groups (linked to the auto scaling groups instances)
   - first target group for the default route domain.com
   - second target group for the domain.com/videos/ route
 - build a load balancer (application)
 - build a listener for the load balancer (forwards traffic to the target groups based on default (domain.com) and custom rule (domain.com/videos/))

 ![Image](images/multi-asg.png?raw=true)