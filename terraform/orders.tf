# Phase 3: purchase-order approval workflow
#
#  LowStockDetected event -> EventBridge rule -> Step Functions state machine
#     AcquireLock (one open order per product)
#       -> RequestApproval (pauses until the owner approves or rejects through the API)
#            approved -> SendToSupplier -> done
#            rejected -> done
#            no answer in 24 h -> MarkExpired -> done

data "archive_file" "orders" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/orders"
  output_path = "${path.module}/build/orders.zip"
}

locals {
  order_routes = [
    "GET /orders",
    "GET /orders/{id}",
    "POST /orders/{id}/approve",
    "POST /orders/{id}/reject",
  ]

  lambda_retry = [{
    ErrorEquals = [
      "Lambda.ServiceException",
      "Lambda.AWSLambdaException",
      "Lambda.SdkClientException",
      "Lambda.TooManyRequestsException",
    ]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2
  }]
}

# --- Orders API Lambda -------------------------------------------------------

resource "aws_cloudwatch_log_group" "orders_api" {
  name              = "/aws/lambda/${var.project}-orders-api"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "orders_api" {
  name               = "${var.project}-orders-api-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "orders_api" {
  statement {
    sid = "TableAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [
      aws_dynamodb_table.main.arn,
      "${aws_dynamodb_table.main.arn}/index/*",
    ]
  }

  # These two actions do not support resource-level permissions.
  statement {
    sid       = "ResumeWorkflow"
    actions   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.orders_api.arn}:*"]
  }
}

resource "aws_iam_role_policy" "orders_api" {
  name   = "${var.project}-orders-api-policy"
  role   = aws_iam_role.orders_api.id
  policy = data.aws_iam_policy_document.orders_api.json
}

resource "aws_lambda_function" "orders_api" {
  function_name    = "${var.project}-orders-api"
  role             = aws_iam_role.orders_api.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "orders.api_handler"
  filename         = data.archive_file.orders.output_path
  source_code_hash = data.archive_file.orders.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.main.name
      GSI_NAME   = "gsi1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.orders_api]
}

# --- Workflow task Lambda (same code file, different entry point) ------------

resource "aws_cloudwatch_log_group" "po_tasks" {
  name              = "/aws/lambda/${var.project}-po-tasks"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "po_tasks" {
  name               = "${var.project}-po-tasks-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "po_tasks" {
  statement {
    sid = "TableAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.main.arn]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.po_tasks.arn}:*"]
  }
}

resource "aws_iam_role_policy" "po_tasks" {
  name   = "${var.project}-po-tasks-policy"
  role   = aws_iam_role.po_tasks.id
  policy = data.aws_iam_policy_document.po_tasks.json
}

resource "aws_lambda_function" "po_tasks" {
  function_name    = "${var.project}-po-tasks"
  role             = aws_iam_role.po_tasks.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "orders.task_handler"
  filename         = data.archive_file.orders.output_path
  source_code_hash = data.archive_file.orders.output_base64sha256
  memory_size      = 256
  timeout          = 15

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.main.name
      TOPIC_ARN  = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.po_tasks]
}

# --- API routes (same Cognito authorizer as the products API) ----------------

resource "aws_apigatewayv2_integration" "orders" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orders_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "orders" {
  for_each = toset(local.order_routes)

  api_id             = aws_apigatewayv2_api.main.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.orders.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "orders_api" {
  statement_id  = "AllowAPIGatewayInvokeOrders"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# --- Step Functions state machine --------------------------------------------

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.project}-po-workflow-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn" {
  statement {
    sid       = "InvokeTaskLambda"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.po_tasks.arn, "${aws_lambda_function.po_tasks.arn}:*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "${var.project}-po-workflow-policy"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_sfn_state_machine" "po_approval" {
  name     = "${var.project}-po-approval"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD" # needed for waiting up to 24 hours on a human

  definition = jsonencode({
    Comment = "Low stock -> purchase order -> owner approval -> email supplier"
    StartAt = "AcquireLock"
    States = {
      AcquireLock = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.po_tasks.arn
          Payload = {
            "action"   = "acquire_lock"
            "po_id.$"  = "$$.Execution.Name"
            "detail.$" = "$.detail"
          }
        }
        ResultSelector = { "proceed.$" = "$.Payload.proceed" }
        ResultPath     = "$.lock"
        Retry          = local.lambda_retry
        Next           = "ShouldOrder"
      }

      ShouldOrder = {
        Type    = "Choice"
        Choices = [{ Variable = "$.lock.proceed", BooleanEquals = true, Next = "RequestApproval" }]
        Default = "SkippedOpenOrder"
      }

      SkippedOpenOrder = { Type = "Succeed" }

      RequestApproval = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        TimeoutSeconds = 86400
        Parameters = {
          FunctionName = aws_lambda_function.po_tasks.arn
          Payload = {
            "action"       = "request_approval"
            "po_id.$"      = "$$.Execution.Name"
            "detail.$"     = "$.detail"
            "task_token.$" = "$$.Task.Token"
          }
        }
        ResultPath = "$.approval"
        Catch = [
          { ErrorEquals = ["States.Timeout"], ResultPath = "$.error", Next = "MarkExpired" },
          { ErrorEquals = ["Rejected"], ResultPath = "$.error", Next = "OrderRejected" },
          { ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "OrderFailed" },
        ]
        Next = "SendToSupplier"
      }

      SendToSupplier = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.po_tasks.arn
          Payload = {
            "action"  = "send_to_supplier"
            "po_id.$" = "$$.Execution.Name"
          }
        }
        ResultPath = "$.sent"
        Retry      = local.lambda_retry
        Next       = "OrderSent"
      }

      OrderSent = { Type = "Succeed" }

      MarkExpired = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.po_tasks.arn
          Payload = {
            "action"   = "mark_expired"
            "po_id.$"  = "$$.Execution.Name"
            "detail.$" = "$.detail"
          }
        }
        ResultPath = "$.expired"
        Retry      = local.lambda_retry
        Next       = "OrderExpired"
      }

      OrderExpired  = { Type = "Succeed" }
      OrderRejected = { Type = "Succeed" }

      OrderFailed = {
        Type  = "Fail"
        Error = "WorkflowError"
        Cause = "The purchase order workflow could not complete"
      }
    }
  })

  depends_on = [aws_iam_role_policy.sfn]
}

# --- EventBridge: low-stock event starts the workflow ------------------------

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_start_po" {
  name               = "${var.project}-events-start-po-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_start_po" {
  statement {
    sid       = "StartWorkflow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.po_approval.arn]
  }
}

resource "aws_iam_role_policy" "events_start_po" {
  name   = "${var.project}-events-start-po-policy"
  role   = aws_iam_role.events_start_po.id
  policy = data.aws_iam_policy_document.events_start_po.json
}

resource "aws_cloudwatch_event_rule" "start_po" {
  name           = "${var.project}-start-po"
  event_bus_name = aws_cloudwatch_event_bus.main.name

  event_pattern = jsonencode({
    "source"      = ["stockwatch.inventory"]
    "detail-type" = ["LowStockDetected"]
  })
}

resource "aws_cloudwatch_event_target" "start_po" {
  rule           = aws_cloudwatch_event_rule.start_po.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "po-approval-workflow"
  arn            = aws_sfn_state_machine.po_approval.arn
  role_arn       = aws_iam_role.events_start_po.arn
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.po_approval.arn
}
