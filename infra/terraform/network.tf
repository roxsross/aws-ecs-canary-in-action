/* ---------------------------------------------------------------------------
   Security groups — the only network resources this stack owns.
   --------------------------------------------------------------------------- */

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Ingress for the canary lab load balancer"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

# The dashboard is a public demo page with no authentication in front of it.
# Narrow allowed_ingress_cidrs to your own address for anything long lived.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to the app tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Canary lab Fargate tasks"
  vpc_id      = local.vpc_id

  tags = { Name = "${local.name}-tasks" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "App port, load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# Tasks need outbound access to pull from ECR and reach DynamoDB, CloudWatch and
# the ECS control plane.
#trivy:ignore:AWS-0104 the created VPC has no NAT/VPC endpoints, so tasks reach AWS APIs and the image registry over the public internet. Use VPC endpoints and scope this down if you deploy into a VPC with private subnets.
resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound to AWS APIs and image registry"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
