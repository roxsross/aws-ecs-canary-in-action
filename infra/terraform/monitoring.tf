# Per-target-group alarms, OR'd into composite alarms. Both target groups are
# watched because ECS swaps which one holds the canary between deployments.

resource "aws_cloudwatch_metric_alarm" "tg_5xx" {
  for_each = local.target_groups

  alarm_name        = "${local.name}-${each.key}-5xx"
  alarm_description = "The ${each.key} target group is returning 5xx responses"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    TargetGroup  = each.value.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${local.name}-${each.key}-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "tg_latency" {
  for_each = local.target_groups

  alarm_name        = "${local.name}-${each.key}-latency"
  alarm_description = "The ${each.key} target group's p95 latency is above the agreed budget"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"

  dimensions = {
    TargetGroup  = each.value.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${local.name}-${each.key}-latency" }
}

resource "aws_cloudwatch_metric_alarm" "tg_unhealthy" {
  for_each = local.target_groups

  alarm_name        = "${local.name}-${each.key}-unhealthy"
  alarm_description = "The ${each.key} target group has unhealthy targets"

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    TargetGroup  = each.value.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${local.name}-${each.key}-unhealthy" }
}

# Composite alarms are what ECS and the dashboard reference; the per-target-group
# alarms above carry no actions so nothing double-fires.
resource "aws_cloudwatch_composite_alarm" "canary_5xx" {
  alarm_name        = local.alarm_names.canary_5xx
  alarm_description = "Either target group is returning 5xx responses"
  alarm_rule        = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_5xx[key].alarm_name}\")"])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_5xx }
}

resource "aws_cloudwatch_composite_alarm" "canary_latency" {
  alarm_name        = local.alarm_names.canary_latency
  alarm_description = "Either target group's p95 latency is above the agreed budget"
  alarm_rule        = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_latency[key].alarm_name}\")"])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_latency }
}

resource "aws_cloudwatch_composite_alarm" "canary_unhealthy" {
  alarm_name        = local.alarm_names.canary_unhealthy
  alarm_description = "Either target group has unhealthy targets"
  alarm_rule        = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_unhealthy[key].alarm_name}\")"])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_unhealthy }
}

# App-level error rate from EMF metrics, catches failures that never reach the ALB as 5xx.
resource "aws_cloudwatch_metric_alarm" "canary_error_rate" {
  count = var.enable_emf_alarm ? 1 : 0

  alarm_name        = local.alarm_names.canary_error_rate
  alarm_description = "Application error rate above ${var.alarm_error_rate_threshold}%"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_error_rate_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "Application error rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = var.metrics_namespace
      metric_name = "ErrorCount"
      period      = var.alarm_period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = var.metrics_namespace
      metric_name = "RequestCount"
      period      = var.alarm_period
      stat        = "Sum"
    }
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_error_rate }
}

resource "aws_cloudwatch_dashboard" "canary" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${local.name}-canary"

  dashboard_body = jsonencode({
    widgets = [
      # Canary share of traffic. MIN/MAX pick canary/stable by request volume
      # (not by ARN, since roles swap); FILL(...,0) keeps the line continuous;
      # the right axis overlays real per-APP_VERSION counts.
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title   = "Canary traffic shift: % of requests on the canary revision, by APP_VERSION"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          period  = 60
          stat    = "Sum"
          yAxis = {
            left  = { min = 0, max = 100, label = "% of total requests (canary share)" }
            right = { min = 0, label = "requests / min, by APP_VERSION" }
          }
          annotations = {
            horizontal = [
              { label = "configured canary_percent", value = var.canary_percent, color = "#94a3b8", yAxis = "left" },
            ]
          }
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix,
              { id = "primary_requests_raw", visible = false }
            ],
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix,
              { id = "alternate_requests_raw", visible = false }
            ],
            [{ expression = "FILL(primary_requests_raw, 0)", label = "primary_requests", id = "primary_requests", visible = false }],
            [{ expression = "FILL(alternate_requests_raw, 0)", label = "alternate_requests", id = "alternate_requests", visible = false }],
            [{ expression = "MAX([primary_requests, alternate_requests])", label = "stable_requests", id = "stable_requests", visible = false }],
            [{ expression = "MIN([primary_requests, alternate_requests])", label = "canary_requests", id = "canary_requests", visible = false }],
            [{ expression = "IF(stable_requests + canary_requests > 0, 100 * canary_requests / (stable_requests + canary_requests), 0)", label = "canary % (filled area) — rest of the axis is the stable revision", id = "canary_pct", color = "#f472b6" }],
            [{ expression = "SEARCH('{${var.metrics_namespace},Track,Version} MetricName=\"RequestCount\"', 'Sum', 60)", label = "", id = "requestsByVersion", yAxis = "right" }],
          ]
        }
      },
      # Per-APP_VERSION view (the one that says which revision is which).
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Requests by APP_VERSION (EMF)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Track,Version} MetricName=\"RequestCount\"', 'Sum', 60)", id = "requestsByVersion" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Errors by APP_VERSION (EMF)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Track,Version} MetricName=\"ErrorCount\"', 'Sum', 60)", id = "errorsByVersion", color = "#d62728" }],
          ]
        }
      },
      # Raw physical target groups (stable/canary role swaps between deploys).
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Requests per target group (physical — roles swap per deploy)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "5xx per target group (physical)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary 5xx" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate 5xx", color = "#d62728" }],
          ]
          annotations = {
            horizontal = [
              { label = "alarm threshold", value = var.alarm_5xx_threshold, color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "p95 latency per target group (physical)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "p95"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary p95" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate p95", color = "#d62728" }],
          ]
          annotations = {
            horizontal = [
              { label = "latency budget", value = var.alarm_latency_threshold_seconds, color = "#d62728" },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Healthy targets (physical)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary healthy" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary unhealthy", color = "#d62728" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate unhealthy", color = "#f472b6" }],
          ]
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 24
        width  = 24
        height = 4
        properties = {
          title  = "Canary rollback triggers"
          alarms = local.rollback_alarm_arns
        }
      },
    ]
  })
}
