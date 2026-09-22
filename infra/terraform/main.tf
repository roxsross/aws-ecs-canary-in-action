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

  # Iterated in monitoring.tf to create one metric alarm per target group per
  # signal (5xx, latency, unhealthy), since neither target group can be
  # trusted to always be "the canary" — see the comment above tg_5xx there.
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

  # The alarm names deployment_configuration.alarms watches for automatic
  # rollback. canary_5xx/latency/unhealthy are composite alarms (OR of the
  # same signal on both target groups, see monitoring.tf) so a problem on
  # whichever target group is actually running the canary this deployment
  # gets caught regardless of which physical target group that turns out to
  # be. Filters out the EMF-based one when it's disabled.
  rollback_alarm_names = concat(
    [
      aws_cloudwatch_composite_alarm.canary_5xx.alarm_name,
      aws_cloudwatch_composite_alarm.canary_latency.alarm_name,
      aws_cloudwatch_composite_alarm.canary_unhealthy.alarm_name,
    ],
    var.enable_emf_alarm ? [aws_cloudwatch_metric_alarm.canary_error_rate[0].alarm_name] : [],
  )

  # Same alarms, as ARNs, for the CloudWatch dashboard's "alarm" widget.
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

  # ADMIN_TOKEN travels as a plain env var (visible via ecs:DescribeTaskDefinition).
  # Accepted lab tradeoff — see "Seguridad" in the README before using this for real.
  #
  # LISTENER_ARN / *_TARGET_GROUP_ARN / PRODUCTION_LISTENER_RULE_ARN let the
  # app's live-weights reader (app/src/alb-weights.js) read the real traffic
  # split. Important: primary and alternate do NOT keep a fixed stable/canary
  # role across deployments — confirmed live against this account by cross-
  # checking running task definitions against target group membership on two
  # separate rollouts: the first one put the new revision in the alternate
  # target group, the second one put it in primary. So the app doesn't trust
  # "primary = stable" as a label; it reads both weights and picks the larger
  # one as stable, the smaller as canary (same fix applied to the dashboard's
  # traffic widget and to the mirrored per-target-group alarms below).
  # PRODUCTION_LISTENER_RULE_ARN matters because that's the rule ECS actually
  # rewrites during a rollout, not the listener's default action.
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
