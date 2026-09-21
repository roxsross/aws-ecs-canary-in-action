# One cluster, two services: stable and canary. Same image contract, different
# TRACK and APP_VERSION, each wired to its own target group.

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = local.name }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = { Name = local.log_group_name }
}

locals {
  tracks = {
    stable = {
      family        = local.stable_task_family
      service       = local.stable_service
      app_version   = var.stable_app_version
      desired_count = var.stable_desired_count
      target_group  = aws_lb_target_group.stable.arn
    }
    canary = {
      family        = local.canary_task_family
      service       = local.canary_service
      app_version   = var.canary_app_version
      desired_count = var.canary_desired_count
      target_group  = aws_lb_target_group.canary.arn
    }
  }
}

resource "aws_ecs_task_definition" "track" {
  for_each = local.tracks

  family                   = each.value.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = local.container_image
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
          appProtocol   = "http"
        },
      ]

      environment = concat(
        local.base_environment,
        [
          { name = "TRACK", value = each.key },
          { name = "APP_VERSION", value = each.value.app_version },
        ],
      )

      # No container healthCheck on purpose: the target group health check is
      # what drives the alarms and the rollback decision.

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.key
        }
      }

      stopTimeout = 20
    },
  ])

  tags = { Name = each.value.family, Track = each.key }
}

resource "aws_ecs_service" "track" {
  for_each = local.tracks

  name            = each.value.service
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.track[each.key].arn
  desired_count   = each.value.desired_count

  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  # Deployments within a track are plain rolling updates; canary behaviour
  # comes from the listener weights, not the service deployment controller.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.service_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = local.create_vpc ? true : var.assign_public_ip
  }

  load_balancer {
    target_group_arn = each.value.target_group
    container_name   = "app"
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60

  # scripts/canary-deploy.sh drives these at runtime.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.task,
    aws_iam_role_policy_attachment.execution_managed,
  ]

  tags = { Name = each.value.service, Track = each.key }
}
