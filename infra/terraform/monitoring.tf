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
    start          = "-PT1H"
    periodOverride = "inherit"
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = "## Canary Lab — cómo leer este dashboard\n**Físico vs lógico:** los target groups `primary` y `alternate` rotan de rol en cada deploy (el que hoy es canary mañana es stable). Los widgets *(physical)* muestran el grupo; los *(EMF)* muestran la `APP_VERSION` real y son la fuente de verdad para decidir rollback.\n\n**Limitación del widget \"Canary traffic shift\":** identifica al canary como el grupo con *menos* tráfico. Es correcto mientras `canary_percent <= 50`; en el cutover final (>50 %) el área muestra `100 - x`. Para confirmar quién es quién, usar \"Requests by APP_VERSION\".\n\n**Tasas, no conteos:** con un split 90/10, unos pocos errores en el canary equivalen a muchos más en stable. Comparar siempre con los widgets de *error rate (%)*."
        }
      },
      # Canary share of traffic. MIN/MAX pick canary/stable by request volume
      # (not by ARN, since roles swap). Valid while canary_percent <= 50.
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 24
        height = 6
        properties = {
          title   = "Canary traffic shift: % of requests on the canary revision"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          period  = 60
          stat    = "Sum"
          yAxis   = { left = { min = 0, max = 100, label = "% of total requests (canary share)" } }
          annotations = {
            horizontal = [
              { label = "configured canary_percent", value = var.canary_percent, color = "#94a3b8", yAxis = "left" },
            ]
          }
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "primary_requests_raw", visible = false }],
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "alternate_requests_raw", visible = false }],
            [{ expression = "FILL(primary_requests_raw, 0)", id = "primary_requests", visible = false }],
            [{ expression = "FILL(alternate_requests_raw, 0)", id = "alternate_requests", visible = false }],
            [{ expression = "MAX([primary_requests, alternate_requests])", id = "stable_requests", visible = false }],
            [{ expression = "MIN([primary_requests, alternate_requests])", id = "canary_requests", visible = false }],
            [{ expression = "IF(stable_requests + canary_requests > 0, 100 * canary_requests / (stable_requests + canary_requests), 0)", id = "canary_pct", label = "canary share (%) — válido mientras canary <= 50 %", color = "#f472b6" }],
          ]
        }
      },
      # Which APP_VERSION is which — the source of truth for rollback decisions.
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          title   = "Requests by APP_VERSION (EMF) — quién es canary hoy"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = "Sum"
          yAxis   = { left = { min = 0, label = "requests / min" } }
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Track,Version} MetricName=\"RequestCount\"', 'Sum', 60)", id = "requestsByVersion" }],
          ]
        }
      },
      # Error COUNT (not rate) by version: SEARCH returns one series per
      # version, and metric math can't do array-vs-scalar or array/array ops,
      # so a per-version rate isn't expressible here. Rate lives at the
      # aggregate level (EMF alarm) and per physical target group (below).
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          title  = "Errors by APP_VERSION (EMF, count)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          yAxis  = { left = { min = 0, label = "errors / min" } }
          metrics = [
            [{ expression = "SEARCH('{${var.metrics_namespace},Track,Version} MetricName=\"ErrorCount\"', 'Sum', 60)", id = "errorsByVersion", color = "#d62728" }],
          ]
        }
      },
      # Rates, not counts — comparable across an uneven traffic split.
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "5xx rate per target group (physical, %)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          yAxis  = { left = { min = 0, label = "% of that group's requests" } }
          annotations = {
            horizontal = [
              { label = "5xx rate alarm threshold", value = var.alarm_error_rate_threshold, color = "#d62728" },
            ]
          }
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "req_p", visible = false }],
            ["AWS/ApplicationELB", "RequestCount", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "req_a", visible = false }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "err_p", visible = false }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { id = "err_a", visible = false }],
            [{ expression = "IF(req_p > 0, 100 * FILL(err_p, 0) / req_p, 0)", id = "rate_p", label = "primary 5xx rate (%)", color = "#1f77b4" }],
            [{ expression = "IF(req_a > 0, 100 * FILL(err_a, 0) / req_a, 0)", id = "rate_a", label = "alternate 5xx rate (%)", color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 15
        width  = 12
        height = 6
        properties = {
          title  = "5xx counts: target + ALB-level (physical)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          yAxis  = { left = { min = 0 } }
          annotations = {
            horizontal = [
              { label = "alarm threshold (count)", value = var.alarm_5xx_threshold, color = "#d62728" },
            ]
          }
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary target 5xx", color = "#1f77b4" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate target 5xx", color = "#d62728" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { label = "ALB-generated 5xx (no target)", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "TargetConnectionErrorCount", "LoadBalancer", aws_lb.this.arn_suffix, { label = "target connection errors", color = "#9467bd" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 21
        width  = 12
        height = 6
        properties = {
          title  = "Latency per target group: p50 / p95 / p99 (physical)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0, label = "seconds" } }
          annotations = {
            horizontal = [
              { label = "latency budget (p95)", value = var.alarm_latency_threshold_seconds, color = "#d62728" },
            ]
          }
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p50", label = "primary p50", color = "#aec7e8" }],
            ["...", { stat = "p95", label = "primary p95", color = "#1f77b4" }],
            ["...", { stat = "p99", label = "primary p99", color = "#08306b" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", aws_lb_target_group.alternate.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p50", label = "alternate p50", color = "#ff9896" }],
            ["...", { stat = "p95", label = "alternate p95", color = "#d62728" }],
            ["...", { stat = "p99", label = "alternate p99", color = "#7f0000" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 21
        width  = 12
        height = 6
        properties = {
          title  = "Healthy / unhealthy targets (physical, min/max per minute)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          yAxis  = { left = { min = 0 } }
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Minimum", label = "primary healthy (min)", color = "#1f77b4" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { stat = "Minimum", label = "alternate healthy (min)", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Maximum", label = "primary unhealthy (max)", color = "#d62728" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { stat = "Maximum", label = "alternate unhealthy (max)", color = "#f472b6" }],
          ]
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 27
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
