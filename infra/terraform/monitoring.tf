/* ---------------------------------------------------------------------------
   Alarms scoped to the *canary* target group only. scripts/canary-deploy.sh polls
   them between traffic steps: any ALARM aborts the rollout and shifts traffic
   back to stable.
   --------------------------------------------------------------------------- */

resource "aws_cloudwatch_metric_alarm" "canary_5xx" {
  alarm_name        = local.alarm_names.canary_5xx
  alarm_description = "Canary target group is returning 5xx responses"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    TargetGroup  = aws_lb_target_group.canary.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # No data means no canary traffic yet, which is not a failure.
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_5xx, Track = "canary" }
}

resource "aws_cloudwatch_metric_alarm" "canary_latency" {
  alarm_name        = local.alarm_names.canary_latency
  alarm_description = "Canary p95 latency is above the agreed budget"

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"

  dimensions = {
    TargetGroup  = aws_lb_target_group.canary.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_latency, Track = "canary" }
}

resource "aws_cloudwatch_metric_alarm" "canary_unhealthy" {
  alarm_name        = local.alarm_names.canary_unhealthy
  alarm_description = "Canary target group has unhealthy targets"

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    TargetGroup  = aws_lb_target_group.canary.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }

  period              = var.alarm_period
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_unhealthy, Track = "canary" }
}

/* Error rate from the app's own embedded metrics (EMF), expressed as a
   percentage. Catches application level failures that never reach the ALB as
   5xx, and proves the EMF pipeline works end to end. */
resource "aws_cloudwatch_metric_alarm" "canary_error_rate" {
  count = var.enable_emf_alarm ? 1 : 0

  alarm_name        = local.alarm_names.canary_error_rate
  alarm_description = "Canary application error rate above ${var.alarm_error_rate_threshold}%"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_error_rate_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 0, 100 * errors / requests, 0)"
    label       = "Canary error rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"

    metric {
      namespace   = var.metrics_namespace
      metric_name = "ErrorCount"
      period      = var.alarm_period
      stat        = "Sum"
      dimensions  = { Track = "canary" }
    }
  }

  metric_query {
    id = "requests"

    metric {
      namespace   = var.metrics_namespace
      metric_name = "RequestCount"
      period      = var.alarm_period
      stat        = "Sum"
      dimensions  = { Track = "canary" }
    }
  }

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_error_rate, Track = "canary" }
}

/* ---------------------------------------------------------------------------
   Dashboard comparing both tracks side by side.
   --------------------------------------------------------------------------- */

resource "aws_cloudwatch_dashboard" "canary" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${local.name}-canary"

  dashboard_body = jsonencode({
    widgets = [
      # Traffic distribution: the single number that answers "how much traffic
      # is the canary actually getting right now". Computed with metric math
      # from raw request counts (stable_requests, canary_requests -> percentage),
      # so it reflects real traffic through the load balancer, not the weight
      # configured on the listener (which lives in the ALB, not in CloudWatch).
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title  = "Traffic distribution: canary share of total requests (%)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          yAxis = {
            left = { min = 0, max = 100, label = "% of total requests" }
          }
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.stable.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix,
              { id = "stable_requests", visible = false }
            ],
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.canary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix,
              { id = "canary_requests", visible = false }
            ],
            [{ expression = "100 * canary_requests / (stable_requests + canary_requests)", label = "canary %", id = "canary_pct", color = "#f472b6" }],
            [{ expression = "100 * stable_requests / (stable_requests + canary_requests)", label = "stable %", id = "stable_pct", color = "#22d3ee" }],
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
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.stable.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "stable" }],
            ["...", aws_lb_target_group.canary.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "canary" }],
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
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.stable.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "stable 5xx" }],
            ["...", aws_lb_target_group.canary.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "canary 5xx", color = "#d62728" }],
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
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.stable.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "stable p95" }],
            ["...", aws_lb_target_group.canary.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "canary p95", color = "#d62728" }],
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
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.stable.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "stable healthy" }],
            ["...", aws_lb_target_group.canary.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "canary healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.canary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "canary unhealthy", color = "#d62728" }],
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
          title  = "Application metrics (EMF) by track"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [var.metrics_namespace, "RequestCount", "Track", "stable", { label = "stable requests" }],
            ["...", "canary", { label = "canary requests" }],
            [var.metrics_namespace, "ErrorCount", "Track", "canary", { label = "canary errors", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title = "Canary rollback triggers"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.canary_5xx.arn,
              aws_cloudwatch_metric_alarm.canary_latency.arn,
              aws_cloudwatch_metric_alarm.canary_unhealthy.arn,
            ],
            var.enable_emf_alarm ? [aws_cloudwatch_metric_alarm.canary_error_rate[0].arn] : [],
          )
        }
      },
    ]
  })
}
