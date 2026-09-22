# Alarms scoped to the alternate target group: that's where ECS runs the new
# revision during a canary deployment. aws_ecs_service.app.alarms references
# these by name, so ECS itself watches them and rolls back automatically —
# no polling script needed.

resource "aws_cloudwatch_metric_alarm" "canary_5xx" {
  alarm_name        = local.alarm_names.canary_5xx
  alarm_description = "The new revision (alternate target group) is returning 5xx responses"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    TargetGroup  = aws_lb_target_group.alternate.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_5xx }
}

resource "aws_cloudwatch_metric_alarm" "canary_latency" {
  alarm_name        = local.alarm_names.canary_latency
  alarm_description = "The new revision's p95 latency is above the agreed budget"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"

  dimensions = {
    TargetGroup  = aws_lb_target_group.alternate.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_latency }
}

resource "aws_cloudwatch_metric_alarm" "canary_unhealthy" {
  alarm_name        = local.alarm_names.canary_unhealthy
  alarm_description = "The new revision's target group has unhealthy targets"

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    TargetGroup  = aws_lb_target_group.alternate.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_unhealthy }
}

# Error rate from the app's own embedded metrics (EMF), catches application
# level failures that never reach the ALB as a 5xx. Both revisions share the
# same EMF namespace with no per-revision dimension (there's no fixed "canary"
# track anymore), so this looks at the app's overall error rate.
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

# Dashboard comparing the primary (current production) and alternate (the
# revision ECS is rolling out) target groups side by side.

resource "aws_cloudwatch_dashboard" "canary" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${local.name}-canary"

  dashboard_body = jsonencode({
    widgets = [
      # New revision's share of total requests, computed from raw request
      # counts so it reflects real traffic, not the deployment's configured
      # canary_percent (which only names the *initial* target, not what's
      # measured live). FILL(..., 0) turns "no datapoint this period" into an
      # explicit zero — without it, CloudWatch leaves a gap (null / null is
      # null, not 0), which is what drew the broken, disconnected line
      # segments instead of a continuous 0-100 line across the whole range.
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title  = "Traffic distribution: new revision's share of total requests (%)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          yAxis = {
            left = { min = 0, max = 100, label = "% of total requests" }
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
            [{ expression = "IF(primary_requests + alternate_requests > 0, 100 * alternate_requests / (primary_requests + alternate_requests), 0)", label = "new revision %", id = "alt_pct", color = "#f472b6" }],
            [{ expression = "IF(primary_requests + alternate_requests > 0, 100 * primary_requests / (primary_requests + alternate_requests), 100)", label = "current revision %", id = "primary_pct", color = "#22d3ee" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Requests per target group"
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
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "5xx per target group"
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
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "p95 latency per target group"
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
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Healthy targets"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary healthy" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "alternate unhealthy", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Requests by APP_VERSION (EMF)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          # SEARCH discovers one series per distinct Version dimension value
          # the app has actually emitted, so the legend shows the real
          # APP_VERSION strings running right now, not a static "primary" /
          # "alternate" label that doesn't say which version that is.
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Version} MetricName=\"RequestCount\"', 'Sum', 60)", id = "requestsByVersion" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Errors by APP_VERSION (EMF)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Version} MetricName=\"ErrorCount\"', 'Sum', 60)", id = "errorsByVersion", color = "#d62728" }],
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
