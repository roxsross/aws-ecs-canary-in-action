# Alarms mirrored on BOTH target groups, combined with a composite alarm
# ("ALARM(primary) OR ALARM(alternate)"). Why both, not just one:
#
# ECS's canary/blue-green strategy does not keep a fixed physical target
# group for "the new revision" across deployments - confirmed live against
# this account by cross-checking running task definitions against target
# group membership on two separate rollouts. The first rollout put the new
# revision in the alternate target group; the second put it in primary.
# A single metric alarm can only watch one fixed dimension value, so an
# alarm scoped to "alternate" would watch the actual canary every other
# rollout and watch the *stable* revision the rest of the time - silently
# useless for its stated job (catching a bad canary) exactly half the time.
#
# CloudWatch's math functions (IF, MIN, MAX) can't fix this at the alarm
# level either: comparing two time series to conditionally pick a third
# ("whichever target group has less traffic, use *its* 5xx count") isn't
# expressible in metric math - IF only compares a time series against a
# scalar, not against another time series. A composite alarm sidesteps the
# whole problem: watch both target groups unconditionally, and treat a
# problem on either one as a reason to trigger ECS's automatic rollback.
# This also means a regression on the stable revision (not just the canary)
# triggers a rollback too, which is a reasonable thing to want anyway.
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

  treat_missing_data = "notBreaching"

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

# One composite alarm per signal, OR-ing the two per-target-group alarms.
# These (not the per-target-group alarms above) are what
# aws_ecs_service.app.alarms and the dashboard's alarm widget reference -
# the per-target-group ones intentionally carry no alarm_actions/ok_actions
# of their own, so nothing double-fires.
resource "aws_cloudwatch_composite_alarm" "canary_5xx" {
  alarm_name        = local.alarm_names.canary_5xx
  alarm_description = "Either target group is returning 5xx responses"

  alarm_rule = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_5xx[key].alarm_name}\")"])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_5xx }
}

resource "aws_cloudwatch_composite_alarm" "canary_latency" {
  alarm_name        = local.alarm_names.canary_latency
  alarm_description = "Either target group's p95 latency is above the agreed budget"

  alarm_rule = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_latency[key].alarm_name}\")"])

  alarm_actions = var.alarm_sns_topic_arns
  ok_actions    = var.alarm_sns_topic_arns

  tags = { Name = local.alarm_names.canary_latency }
}

resource "aws_cloudwatch_composite_alarm" "canary_unhealthy" {
  alarm_name        = local.alarm_names.canary_unhealthy
  alarm_description = "Either target group has unhealthy targets"

  alarm_rule = join(" OR ", [for key in keys(local.target_groups) : "ALARM(\"${aws_cloudwatch_metric_alarm.tg_unhealthy[key].alarm_name}\")"])

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

# Dashboard comparing the primary and alternate target groups side by side.
# Which one is "stable" and which is "canary" swaps between deployments (see
# tg_5xx above), so most widgets here plot both raw target groups without
# claiming either one is the canary — only the top widget and the two
# per-APP_VERSION EMF widgets make that call, and they do it by request
# volume / real version string, not by ARN.

resource "aws_cloudwatch_dashboard" "canary" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${local.name}-canary"

  dashboard_body = jsonencode({
    widgets = [
      # Canary revision's share of total requests, computed from raw request
      # counts so it reflects real traffic, not just the deployment's
      # configured canary_percent (which only names the *target* for the
      # hold phase, not what's measured live).
      #
      # Important: ECS's canary/blue-green strategy does NOT keep a fixed
      # physical target group for "the stable revision" across deployments —
      # confirmed live against this account by cross-checking task
      # definitions against target group membership on two separate
      # rollouts: the first one put the new revision in the alternate target
      # group, the second one put it in primary. What ECS keeps constant is
      # the *shape*: the majority of traffic (or all of it, at rest) is
      # always on whichever target group holds the stable revision, and the
      # minority is on whichever holds the one being tested. So this widget
      # cannot just plot "the alternate target group's %" and call it the
      # canary's share — half the time that would actually be the stable
      # revision's share. MIN(a, b) / MAX(a, b) picks the canary/stable
      # share by size instead of by which ARN it came from, same fix as
      # app/src/alb-weights.js applies for the app's own dashboard.
      #
      # FILL(..., 0) turns "no datapoint this period" into an explicit zero —
      # without it, CloudWatch leaves a gap (null / null is null, not 0)
      # instead of a continuous line across the whole range.
      #
      # stacked=true renders a filled area under the line instead of a bare
      # line, which is what removes the crossing/flickering look you get
      # from plotting two lines that add up to 100 and cross every time the
      # split moves. Only one series is stacked here (canary_pct): stacking
      # both canary_pct and stable_pct together would sum 100 on top of 100
      # and blow past the 0-100 axis instead of reading as a clean split.
      # With a single stacked series capped at yAxis max=100, the filled
      # area *is* the canary's share and the empty space above it *is* the
      # stable revision's share.
      #
      # The right-hand axis overlays the app's own per-version EMF counters
      # (Version dimension, unchanged in app/src/metrics.js) as plain lines,
      # so this widget answers both questions at once: "what % is on the
      # canary right now" and "which APP_VERSION strings are actually
      # serving" — a bare % number doesn't say whether the canary is 1.0.1 or
      # 1.0.5, this does.
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
            [{ expression = "SEARCH('{${var.metrics_namespace},Version} MetricName=\"RequestCount\"', 'Sum', 60)", label = "", id = "requestsByVersion", yAxis = "right" }],
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
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.primary.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix, { label = "primary unhealthy", color = "#d62728" }],
            ["...", aws_lb_target_group.alternate.arn_suffix, ".", aws_lb.this.arn_suffix, { label = "alternate unhealthy", color = "#f472b6" }],
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
