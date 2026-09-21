# ALB using ECS's native canary deployment strategy (deployment_configuration
# in ecs.tf). Two target groups, "primary" (current production revision) and
# "alternate" (the revision ECS is rolling out); ECS itself moves the listener
# rule weights during a deployment via load_balancer.advanced_configuration.
# Terraform only owns the initial 100/0 state and the rule; it does not touch
# weights afterwards, the same way it never touched them in the old design.

resource "aws_lb" "this" {
  name = "${local.name}-alb"
  #trivy:ignore:AWS-0053 intentionally public: this is a demo dashboard meant to be shared. Narrow allowed_ingress_cidrs to your own IP for anything long lived.
  internal           = false
  load_balancer_type = "application"
  subnets            = local.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  enable_deletion_protection = var.enable_deletion_protection
  idle_timeout               = 60
  drop_invalid_header_fields = true

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "primary" {
  name        = "${local.name}-primary"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = 5
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }

  tags = { Name = "${local.name}-primary" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "alternate" {
  name        = "${local.name}-alternate"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = 5
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }

  tags = { Name = "${local.name}-alternate" }

  lifecycle {
    create_before_destroy = true
  }
}

#trivy:ignore:AWS-0054 HTTP on purpose to keep the lab a one-command deploy: HTTPS needs an ACM certificate and a domain. Put TLS in front for anything beyond a demo.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary.arn
  }
}

# ECS requires the production traffic action to live on a listener *rule*, not
# the listener's own default action, so this is what deployment_configuration
# points at. ECS rewrites its target group during each deployment; Terraform
# only sets the initial state.
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  tags = { Name = "${local.name}-production" }

  lifecycle {
    ignore_changes = [action]
  }
}
