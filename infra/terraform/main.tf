# Canary lab on ECS Fargate. Networking is handled in vpc.tf.

data "aws_caller_identity" "current" {}

locals {
  name = var.project_name

  account_id = data.aws_caller_identity.current.account_id

  ecr_repository_name = var.ecr_repository_name != "" ? var.ecr_repository_name : "${var.project_name}-app"

  ecr_repository_url = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.ecr_repository_name}"

  # Composed, not looked up, so plan works before the image exists.
  container_image = var.container_image != "" ? var.container_image : "${local.ecr_repository_url}:${var.image_tag}"

  table_name     = "${var.project_name}-traffic"
  log_group_name = "/ecs/${var.project_name}"
  service_name   = "${var.project_name}-app"
  task_family    = "${var.project_name}-app"

  # Both target groups get their own alarms; the canary role swaps between them.
  target_groups = {
    primary   = aws_lb_target_group.primary
    alternate = aws_lb_target_group.alternate
  }

  alarm_names = {
    canary_5xx        = "${var.project_name}-canary-5xx"
    canary_latency    = "${var.project_name}-canary-latency"
    canary_unhealthy  = "${var.project_name}-canary-unhealthy"
    canary_error_rate = "${var.project_name}-canary-error-rate"
  }

  # Alarm names ECS watches for automatic rollback (EMF one dropped when disabled).
  rollback_alarm_names = concat(
    [
      aws_cloudwatch_composite_alarm.canary_5xx.alarm_name,
      aws_cloudwatch_composite_alarm.canary_latency.alarm_name,
      aws_cloudwatch_composite_alarm.canary_unhealthy.alarm_name,
    ],
    var.enable_emf_alarm ? [aws_cloudwatch_metric_alarm.canary_error_rate[0].alarm_name] : [],
  )

  # Same alarms as ARNs, for the dashboard's alarm widget.
  rollback_alarm_arns = concat(
    [
      aws_cloudwatch_composite_alarm.canary_5xx.arn,
      aws_cloudwatch_composite_alarm.canary_latency.arn,
      aws_cloudwatch_composite_alarm.canary_unhealthy.arn,
    ],
    var.enable_emf_alarm ? [aws_cloudwatch_metric_alarm.canary_error_rate[0].arn] : [],
  )

  common_tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
      Component = "ecs-canary-lab"
      Repo      = "roxsross/aws-ecs-canary-in-action"
    },
    var.tags,
  )

  # ADMIN_TOKEN is a plain env var (lab tradeoff). The LISTENER/TARGET_GROUP/RULE
  # ARNs let the app read the live traffic split from the production rule.
  base_environment = [
    { name = "PROJECT_NAME", value = var.project_name },
    { name = "PORT", value = tostring(var.container_port) },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "TABLE_NAME", value = aws_dynamodb_table.traffic.name },
    { name = "RECORD_MODE", value = var.record_mode },
    { name = "METRICS_NAMESPACE", value = var.metrics_namespace },
    { name = "ADMIN_TOKEN", value = var.admin_token },
    { name = "LISTENER_ARN", value = aws_lb_listener.http.arn },
    { name = "STABLE_TARGET_GROUP_ARN", value = aws_lb_target_group.primary.arn },
    { name = "CANARY_TARGET_GROUP_ARN", value = aws_lb_target_group.alternate.arn },
    { name = "PRODUCTION_LISTENER_RULE_ARN", value = aws_lb_listener_rule.production.arn },
  ]
}
