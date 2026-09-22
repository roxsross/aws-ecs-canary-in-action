# Two roles, as ECS expects: execution role pulls the image and writes logs,
# task role is used by the app itself (DynamoDB).

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  description        = "Pulls images and ships container logs for the canary lab"
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  description        = "Application permissions for the canary lab tasks"
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "TrafficTableAccess"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchWriteItem",
    ]

    resources = [aws_dynamodb_table.traffic.arn]
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid    = "EcsExecChannel"
      effect = "Allow"

      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]

      resources = ["*"]
    }
  }

  # Lets the app itself read the production listener rule's live weights
  # (app/src/alb-weights.js), so its dashboard shows the real canary split
  # ECS is driving instead of falling back to an estimate.
  #
  # elasticloadbalancing:DescribeRules is a Describe/List-style action and
  # does not support resource-level permissions in IAM — confirmed with
  # `aws iam simulate-principal-policy`, which returned implicitDeny with no
  # MatchedStatements when this was scoped to a specific rule ARN. It needs
  # Resource = "*". It's still read-only (no rule modification actions are
  # granted), so this can only leak the shape of this account's own ALB
  # rules, not change anything.
  statement {
    sid    = "ReadListenerRules"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:DescribeRules",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.name}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# Lets ECS itself create/modify the alternate target group and rewrite the
# production listener rule's weights during a canary deployment. Without this
# role, deployment_configuration.strategy = "CANARY" cannot move any traffic.
data "aws_iam_policy_document" "ecs_infrastructure_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${local.name}-ecs-infra"
  assume_role_policy = data.aws_iam_policy_document.ecs_infrastructure_assume_role.json
  description        = "Lets ECS manage ALB target groups and listener rules during canary deployments"
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
