# One cluster, one service. Canary behaviour comes from ECS's native
# deployment_configuration (strategy = CANARY), not from a second service: ECS
# creates the "green" revision, target group registration and listener rule
# weighting for you, watches the alarms below, and rolls back on its own if one
# breaches. See docs/architecture.md for how this replaced the two-service /
# hand-rolled listener weights design used by local/mini-alb.

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

resource "aws_ecs_task_definition" "app" {
  family                   = local.task_family
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
        [{ name = "APP_VERSION", value = var.app_version }],
      )

      # No container healthCheck on purpose: the target group health check is
      # what drives the alarms and the rollback decision.

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      stopTimeout = 20
    },
  ])

  tags = { Name = local.task_family }
}

resource "aws_ecs_service" "app" {
  name            = local.service_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = local.service_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = local.create_vpc ? true : var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.primary.arn
    container_name   = "app"
    container_port   = var.container_port

    advanced_configuration {
      alternate_target_group_arn = aws_lb_target_group.alternate.arn
      production_listener_rule   = aws_lb_listener_rule.production.arn
      role_arn                   = aws_iam_role.ecs_infrastructure.arn
    }
  }

  health_check_grace_period_seconds = 60

  deployment_configuration {
    strategy             = "CANARY"
    bake_time_in_minutes = var.bake_time_in_minutes
    canary_configuration {
      canary_percent              = var.canary_percent
      canary_bake_time_in_minutes = var.canary_bake_time_in_minutes
    }
  }

  alarms {
    enable      = true
    rollback    = true
    alarm_names = local.rollback_alarm_names
  }

  # A rollout is triggered with `aws ecs update-service --force-new-deployment
  # --task-definition ...`, not by editing this resource, so Terraform should
  # not fight the in-flight canary/green revision it created.
  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [
    aws_lb_listener_rule.production,
    aws_iam_role_policy.task,
    aws_iam_role_policy_attachment.execution_managed,
    aws_iam_role_policy_attachment.ecs_infrastructure,
  ]

  tags = { Name = local.service_name }
}
