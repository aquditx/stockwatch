# Phase 2: low-stock detection pipeline
#
#  DynamoDB stream -> detector Lambda -> EventBridge bus -> rule -> SQS (+DLQ)
#                                                                    -> notifier Lambda -> SNS email
#
# Failure handling:
#  - stream batches that keep failing go to stream_dlq
#  - alert messages that fail 3 times go to alerts_dlq
#  - CloudWatch alarms email you if either DLQ is not empty

data "archive_file" "detector" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/detector"
  output_path = "${path.module}/build/detector.zip"
}

data "archive_file" "notifier" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/notifier"
  output_path = "${path.module}/build/notifier.zip"
}

# --- SNS: where humans get told ----------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

# You must click "Confirm subscription" in the email AWS sends after apply.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- SQS: buffer + retries + dead-letter queues ------------------------------

resource "aws_sqs_queue" "alerts_dlq" {
  name                      = "${var.project}-alerts-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "alerts" {
  name                       = "${var.project}-alerts"
  visibility_timeout_seconds = 60 # 6x the notifier timeout
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.alerts_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "stream_dlq" {
  name                      = "${var.project}-stream-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

# --- EventBridge: custom bus, rule, target -----------------------------------

resource "aws_cloudwatch_event_bus" "main" {
  name = "${var.project}-bus"
}

resource "aws_cloudwatch_event_rule" "low_stock" {
  name           = "${var.project}-low-stock"
  event_bus_name = aws_cloudwatch_event_bus.main.name

  event_pattern = jsonencode({
    "source"      = ["stockwatch.inventory"]
    "detail-type" = ["LowStockDetected"]
  })
}

resource "aws_cloudwatch_event_target" "low_stock_to_sqs" {
  rule           = aws_cloudwatch_event_rule.low_stock.name
  event_bus_name = aws_cloudwatch_event_bus.main.name
  target_id      = "alerts-queue"
  arn            = aws_sqs_queue.alerts.arn
}

data "aws_iam_policy_document" "alerts_queue" {
  statement {
    sid       = "AllowEventBridgeRule"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.low_stock.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "alerts" {
  queue_url = aws_sqs_queue.alerts.id
  policy    = data.aws_iam_policy_document.alerts_queue.json
}

# --- Detector Lambda (stream consumer) ---------------------------------------

resource "aws_cloudwatch_log_group" "detector" {
  name              = "/aws/lambda/${var.project}-detector"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "detector" {
  name               = "${var.project}-detector-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "detector" {
  statement {
    sid = "ReadStream"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = ["${aws_dynamodb_table.main.arn}/stream/*"]
  }

  statement {
    sid       = "PublishEvents"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.main.arn]
  }

  statement {
    sid       = "StreamFailureDestination"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.stream_dlq.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.detector.arn}:*"]
  }
}

resource "aws_iam_role_policy" "detector" {
  name   = "${var.project}-detector-policy"
  role   = aws_iam_role.detector.id
  policy = data.aws_iam_policy_document.detector.json
}

resource "aws_lambda_function" "detector" {
  function_name    = "${var.project}-detector"
  role             = aws_iam_role.detector.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "detector.handler"
  filename         = data.archive_file.detector.output_path
  source_code_hash = data.archive_file.detector.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.main.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.detector]
}

resource "aws_lambda_event_source_mapping" "stream_to_detector" {
  event_source_arn               = aws_dynamodb_table.main.stream_arn
  function_name                  = aws_lambda_function.detector.arn
  starting_position              = "LATEST"
  batch_size                     = 10
  maximum_retry_attempts         = 3
  bisect_batch_on_function_error = true

  # Only product META items reach the detector; alert/other items never invoke it.
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT", "MODIFY"]
        dynamodb  = { Keys = { pk = { S = [{ prefix = "PRODUCT#" }] }, sk = { S = ["META"] } } }
      })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_dlq.arn
    }
  }

  depends_on = [aws_iam_role_policy.detector]
}

# --- Notifier Lambda (SQS consumer) ------------------------------------------

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${var.project}-notifier"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "notifier" {
  name               = "${var.project}-notifier-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "notifier" {
  statement {
    sid       = "ConsumeQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.alerts.arn]
  }

  statement {
    sid       = "SendEmailViaSns"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "RecordAlerts"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.main.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notifier.arn}:*"]
  }
}

resource "aws_iam_role_policy" "notifier" {
  name   = "${var.project}-notifier-policy"
  role   = aws_iam_role.notifier.id
  policy = data.aws_iam_policy_document.notifier.json
}

resource "aws_lambda_function" "notifier" {
  function_name    = "${var.project}-notifier"
  role             = aws_iam_role.notifier.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "notifier.handler"
  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.main.name
      TOPIC_ARN  = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.notifier]
}

resource "aws_lambda_event_source_mapping" "queue_to_notifier" {
  event_source_arn        = aws_sqs_queue.alerts.arn
  function_name           = aws_lambda_function.notifier.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.notifier]
}

# --- Alarms: tell a human when something lands in a dead-letter queue --------

locals {
  dlqs = {
    alerts = aws_sqs_queue.alerts_dlq
    stream = aws_sqs_queue.stream_dlq
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.dlqs

  alarm_name          = "${var.project}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages are sitting in the ${each.key} dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.main.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
