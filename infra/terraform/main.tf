# Canary lab on ECS Fargate. Networking is handled in vpc.tf.

data "aws_caller_identity" "current" {}

locals {
  name = var.project_name

  account_id = data.aws_caller_identity.current.account_id

  ecr_repository_name = var.ecr_repository_name != "" ? var.ecr_repository_name : "${var.project_name}-app"

  ecr_repository_url = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.ecr_repository_name}"

  # Composed rather than looked up, so `terraform plan` works even before the
  # image exists in the registry.
  container_image = var.container_image != "" ? var.container_image : "${local.ecr_repository_url}:${var.image_tag}"

  table_name         = "${var.project_name}-traffic"
  log_group_name     = "/ecs/${var.project_name}"
  stable_service     = "${var.project_name}-stable"
  canary_service     = "${var.project_name}-canary"
  stable_task_family = "${var.project_name}-stable"
  canary_task_family = "${var.project_name}-canary"

  alarm_names = {
    canary_5xx        = "${var.project_name}-canary-5xx"
    canary_latency    = "${var.project_name}-canary-latency"
    canary_unhealthy  = "${var.project_name}-canary-unhealthy"
    canary_error_rate = "${var.project_name}-canary-error-rate"
  }

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "ecs-canary-lab"
      Repo      = "roxsross/aws-ecs-canary-in-action"
    },
    var.tags,
  )

  # Shared by both tracks; per-track values are appended in ecs.tf.
  # ADMIN_TOKEN travels as a plain env var (visible via ecs:DescribeTaskDefinition).
  # Accepted lab tradeoff — see "Seguridad" in the README before using this for real.
  base_environment = [
    { name = "PROJECT_NAME", value = var.project_name },
    { name = "PORT", value = tostring(var.container_port) },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "TABLE_NAME", value = aws_dynamodb_table.traffic.name },
    { name = "RECORD_MODE", value = var.record_mode },
    { name = "METRICS_NAMESPACE", value = var.metrics_namespace },
    { name = "LISTENER_ARN", value = aws_lb_listener.http.arn },
    { name = "STABLE_TARGET_GROUP_ARN", value = aws_lb_target_group.stable.arn },
    { name = "CANARY_TARGET_GROUP_ARN", value = aws_lb_target_group.canary.arn },
    { name = "ADMIN_TOKEN", value = var.admin_token },
  ]
}
