# Two roles, as ECS expects: execution role pulls the image and writes logs,
# task role is used by the app itself (DynamoDB, listener read).

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

  # elasticloadbalancing Describe* actions don't support resource-level perms.
  dynamic "statement" {
    for_each = var.grant_listener_read ? [1] : []

    content {
      sid       = "ReadListenerWeights"
      effect    = "Allow"
      actions   = ["elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeListeners"]
      resources = ["*"]
    }
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
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.name}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
