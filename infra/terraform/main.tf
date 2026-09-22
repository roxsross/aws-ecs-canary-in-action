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

  table_name     = "${var.project_name}-traffic"
  log_group_name = "/ecs/${var.project_name}"
  service_name   = "${var.project_name}-app"
  task_family    = "${var.project_name}-app"

  alarm_names = {
    canary_5xx        = "${var.project_name}-canary-5xx"
    canary_latency    = "${var.project_name}-canary-latency"
    canary_unhealthy  = "${var.project_name}-canary-unhealthy"
    canary_error_rate = "${var.project_name}-canary-error-rate"
  }

  # The alarm names deployment_configuration.alarms watches for automatic
  # rollback. Filters out the EMF-based one when it's disabled.
  rollback_alarm_names = concat(
    [
      aws_cloudwatch_metric_alarm.canary_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.canary_latency.alarm_name,
      aws_cloudwatch_metric_alarm.canary_unhealthy.alarm_name,
    ],
    var.enable_emf_alarm ? [aws_cloudwatch_metric_alarm.canary_error_rate[0].alarm_name] : [],
  )

  # Same alarms, as ARNs, for the CloudWatch dashboard's "alarm" widget.
  rollback_alarm_arns = concat(
    [
      aws_cloudwatch_metric_alarm.canary_5xx.arn,
      aws_cloudwatch_metric_alarm.canary_latency.arn,
      aws_cloudwatch_metric_alarm.canary_unhealthy.arn,
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

  # ADMIN_TOKEN travels as a plain env var (visible via ecs:DescribeTaskDefinition).
  # Accepted lab tradeoff — see "Seguridad" in the README before using this for real.
  #
  # LISTENER_ARN / *_TARGET_GROUP_ARN / PRODUCTION_LISTENER_RULE_ARN: primary
  # and alternate are not an arbitrary pair here. Per AWS's own canary/blue-
  # green deployment model, the "original" target group (primary) always
  # keeps the current stable revision and the majority of traffic, and the
  # "alternate" target group always receives the new/canary revision during
  # a rollout - confirmed live against this account's ALB while a rollout was
  # in progress. That pairing is fixed across every deployment, so the app's
  # live-weights reader (app/src/alb-weights.js) can point at it directly.
  # It reads PRODUCTION_LISTENER_RULE_ARN (not the listener's default action)
  # because that's the rule ECS actually rewrites during a rollout.
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
