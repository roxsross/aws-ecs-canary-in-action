/* ---------------------------------------------------------------------------
   The canary_env output is the contract every script and workflow reads.
   `scripts/load-env.sh terraform` turns it into .canary.env.
   --------------------------------------------------------------------------- */

output "app_url" {
  description = "Open this to get the live traffic dashboard."
  value       = "http://${aws_lb.this.dns_name}"
}

output "stable_only_url" {
  description = "Forced routing to the stable version, ignoring the weights."
  value       = "http://${aws_lb.this.dns_name}/?track=stable"
}

output "canary_only_url" {
  description = "Forced routing to the canary version, ignoring the weights."
  value       = "http://${aws_lb.this.dns_name}/?track=canary"
}

output "cloudwatch_dashboard_url" {
  description = "CloudWatch dashboard comparing both tracks."
  value       = var.enable_dashboard ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.canary[0].dashboard_name}" : null
}

output "ecr_push_commands" {
  description = "Reminder of how to publish a new image version."
  value       = "make push TAG=v2   # or: ./scripts/build-push.sh --tag v2"
}

output "vpc_id" {
  description = "VPC in use. Either the one you passed in var.vpc_id, or the one Terraform created for the lab."
  value       = local.vpc_id
}

output "vpc_created" {
  description = "true if Terraform created the VPC (var.vpc_id was left empty), false if it reused an existing one."
  value       = local.create_vpc
}

output "public_subnet_ids" {
  description = "Public subnets in use, created or existing."
  value       = local.public_subnet_ids
}

output "canary_env" {
  description = "Everything the canary scripts need. Consumed by scripts/load-env.sh."
  value = {
    CANARY_REGION          = var.aws_region
    CANARY_PROJECT         = var.project_name
    CANARY_CLUSTER         = aws_ecs_cluster.this.name
    CANARY_ALB_DNS         = aws_lb.this.dns_name
    CANARY_ALB_ARN         = aws_lb.this.arn
    CANARY_LISTENER_ARN    = aws_lb_listener.http.arn
    CANARY_TG_STABLE       = aws_lb_target_group.stable.arn
    CANARY_TG_CANARY       = aws_lb_target_group.canary.arn
    CANARY_SVC_STABLE      = aws_ecs_service.track["stable"].name
    CANARY_SVC_CANARY      = aws_ecs_service.track["canary"].name
    CANARY_TASKDEF_STABLE  = local.stable_task_family
    CANARY_TASKDEF_CANARY  = local.canary_task_family
    CANARY_ECR_REPO        = local.ecr_repository_name
    CANARY_ECR_URI         = local.ecr_repository_url
    CANARY_TABLE           = aws_dynamodb_table.traffic.name
    CANARY_LOG_GROUP       = aws_cloudwatch_log_group.app.name
    CANARY_ALARM_5XX       = aws_cloudwatch_metric_alarm.canary_5xx.alarm_name
    CANARY_ALARM_LATENCY   = aws_cloudwatch_metric_alarm.canary_latency.alarm_name
    CANARY_ALARM_UNHEALTHY = aws_cloudwatch_metric_alarm.canary_unhealthy.alarm_name
    CANARY_ALARM_ERRORRATE = var.enable_emf_alarm ? aws_cloudwatch_metric_alarm.canary_error_rate[0].alarm_name : ""
    CANARY_CONTAINER_NAME  = "app"
    CANARY_CONTAINER_PORT  = tostring(var.container_port)
  }
}
