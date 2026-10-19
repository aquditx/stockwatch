# Phase 5: monitoring and audit
#
#  - CloudWatch dashboard: API traffic and errors, Lambda errors, queues, workflow
#  - Alarms (email via the existing SNS topic): API 5xx, Lambda errors, failed workflows
#  - CloudTrail: who did what in the account, into a locked-down S3 bucket

locals {
  lambda_names = {
    products = aws_lambda_function.products.function_name
    detector = aws_lambda_function.detector.function_name
    notifier = aws_lambda_function.notifier.function_name
    orders   = aws_lambda_function.orders_api.function_name
    po_tasks = aws_lambda_function.po_tasks.function_name
  }
}

# --- Alarms --------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.project}-api-5xx"
  alarm_description   = "The API returned server errors"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambda_names

  alarm_name          = "${var.project}-${each.key}-errors"
  alarm_description   = "Lambda ${each.value} reported errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "workflow_failed" {
  alarm_name          = "${var.project}-workflow-failed"
  alarm_description   = "A purchase order workflow execution failed"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.po_approval.arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Dashboard -----------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { label = "Requests" }],
            [".", "4xx", ".", ".", { label = "Client errors (4xx)" }],
            [".", "5xx", ".", ".", { label = "Server errors (5xx)" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API latency (ms)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.main.id, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda errors"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 300
          metrics = [for k, v in local.lambda_names : ["AWS/Lambda", "Errors", "FunctionName", v, { label = k }]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title   = "Lambda invocations"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 300
          metrics = [for k, v in local.lambda_names : ["AWS/Lambda", "Invocations", "FunctionName", v, { label = k }]]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Alert queues (messages waiting)"
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.alerts.name, { label = "Alerts queue" }],
            [".", ".", ".", aws_sqs_queue.alerts_dlq.name, { label = "Alerts dead-letter queue" }],
            [".", ".", ".", aws_sqs_queue.stream_dlq.name, { label = "Stream dead-letter queue" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Purchase order workflow"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.po_approval.arn, { label = "Started" }],
            [".", "ExecutionsSucceeded", ".", ".", { label = "Succeeded" }],
            [".", "ExecutionsFailed", ".", ".", { label = "Failed" }],
            [".", "ExecutionsTimedOut", ".", ".", { label = "Timed out" }],
          ]
        }
      },
    ]
  })
}

# --- CloudTrail: audit log of API activity in this account ----------------------

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "trail" {
  bucket_prefix = "${var.project}-audit-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}

data "aws_iam_policy_document" "trail" {
  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket     = aws_s3_bucket.trail.id
  policy     = data.aws_iam_policy_document.trail.json
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.trail]
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}
