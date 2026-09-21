# ALB with two target groups and a weighted default rule. scripts/canary-deploy.sh
# shifts the weights from 100/0 to 0/100 one step at a time.

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

resource "aws_lb_target_group" "stable" {
  name        = "${local.name}-stable"
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

  tags = { Name = "${local.name}-stable", Track = "stable" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "canary" {
  name        = "${local.name}-canary"
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

  tags = { Name = "${local.name}-canary", Track = "canary" }

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
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.stable.arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.canary.arn
        weight = 0
      }

      stickiness {
        enabled  = false
        duration = 3600
      }
    }
  }

  # The canary scripts own the weights at runtime; otherwise a mid-rollout
  # `terraform apply` would snap traffic back to 100/0.
  lifecycle {
    ignore_changes = [default_action]
  }
}

# Forced routing rules, used by the dashboard's "ver solo esta versión" links.

resource "aws_lb_listener_rule" "force_canary_query" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.canary.arn
  }

  condition {
    query_string {
      key   = "track"
      value = "canary"
    }
  }

  tags = { Name = "${local.name}-force-canary-query" }
}

resource "aws_lb_listener_rule" "force_stable_query" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 11

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.stable.arn
  }

  condition {
    query_string {
      key   = "track"
      value = "stable"
    }
  }

  tags = { Name = "${local.name}-force-stable-query" }
}

resource "aws_lb_listener_rule" "force_canary_header" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.canary.arn
  }

  condition {
    http_header {
      http_header_name = "X-Canary"
      values           = ["always"]
    }
  }

  tags = { Name = "${local.name}-force-canary-header" }
}

resource "aws_lb_listener_rule" "force_stable_header" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 21

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.stable.arn
  }

  condition {
    http_header {
      http_header_name = "X-Canary"
      values           = ["never"]
    }
  }

  tags = { Name = "${local.name}-force-stable-header" }
}
