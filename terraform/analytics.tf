# Phase 7: sales analytics (VPC, RDS Postgres, Lambda in the VPC, ECS Fargate)
#
#  DynamoDB stream -> sales-loader Lambda (in VPC) -> RDS Postgres (private subnets)
#  Dashboard -> API Gateway -> forecast Lambda (in VPC) -> RDS + DynamoDB
#  EventBridge schedule (midnight IST) -> ECS Fargate report task -> RDS -> SNS email
#
# There is no NAT gateway. Lambdas reach DynamoDB through a gateway endpoint and Secrets
# Manager through an interface endpoint. The Fargate task sits in a public subnet so it can
# pull its image and call AWS APIs without a NAT; nothing can connect in to it.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  vpc_cidr = "10.20.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  db_name  = "stockwatch"
}

# --- Network -------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project}-private-${count.index + 1}" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, 10)
  availability_zone = local.azs[0]
  tags              = { Name = "${var.project}-public-1" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-public" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private subnets have no route to the internet at all.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "secrets" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id] # one subnet keeps the hourly cost down
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda"
  description = "Analytics Lambdas"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "lambda_out" {
  security_group_id = aws_security_group.lambda.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0" # private subnets have no internet route; this reaches the endpoints
}

resource "aws_security_group" "task" {
  name        = "${var.project}-report-task"
  description = "Fargate report task (no inbound)"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_egress_rule" "task_out" {
  security_group_id = aws_security_group.task.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "Postgres, reachable only from the analytics Lambdas and the report task"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_lambda" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "db_from_task" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "endpoint" {
  name        = "${var.project}-endpoints"
  description = "VPC interface endpoints"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_from_lambda" {
  security_group_id            = aws_security_group.endpoint.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# --- RDS Postgres (private) ----------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "main" {
  identifier                  = "${var.project}-db"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = local.db_name
  username                    = "stockwatch_admin"
  manage_master_user_password = true # password is generated and kept in Secrets Manager
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  multi_az                    = false # single AZ keeps the demo cheap
  backup_retention_period     = 1
  skip_final_snapshot         = true
  deletion_protection         = false
  apply_immediately           = true
}

locals {
  db_secret_arn = aws_db_instance.main.master_user_secret[0].secret_arn
}

# --- Analytics Lambdas (inside the VPC) ----------------------------------------

data "archive_file" "analytics" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/analytics"
  output_path = "${path.module}/build/analytics.zip"
}

resource "aws_cloudwatch_log_group" "sales_loader" {
  name              = "/aws/lambda/${var.project}-sales-loader"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "forecast_api" {
  name              = "/aws/lambda/${var.project}-forecast-api"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "sales_loader" {
  name               = "${var.project}-sales-loader-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "sales_loader_vpc" {
  role       = aws_iam_role.sales_loader.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "sales_loader" {
  statement {
    sid       = "ReadDbPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_secret_arn]
  }

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
    sid       = "ListProductsForSeeding"
    actions   = ["dynamodb:Query"]
    resources = ["${aws_dynamodb_table.main.arn}/index/*"]
  }

  statement {
    sid       = "StreamFailureDestination"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.stream_dlq.arn]
  }
}

resource "aws_iam_role_policy" "sales_loader" {
  name   = "${var.project}-sales-loader-policy"
  role   = aws_iam_role.sales_loader.id
  policy = data.aws_iam_policy_document.sales_loader.json
}

resource "aws_lambda_function" "sales_loader" {
  function_name    = "${var.project}-sales-loader"
  role             = aws_iam_role.sales_loader.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "analytics.load_handler"
  filename         = data.archive_file.analytics.output_path
  source_code_hash = data.archive_file.analytics.output_base64sha256
  memory_size      = 256
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.main.name
      DB_HOST       = aws_db_instance.main.address
      DB_NAME       = local.db_name
      DB_SECRET_ARN = local.db_secret_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.sales_loader,
    aws_iam_role_policy_attachment.sales_loader_vpc,
    aws_vpc_endpoint.secrets,
    aws_vpc_endpoint.dynamodb,
  ]
}

# A second consumer of the same stream: only sales (stock going down) become rows.
resource "aws_lambda_event_source_mapping" "stream_to_sales_loader" {
  event_source_arn               = aws_dynamodb_table.main.stream_arn
  function_name                  = aws_lambda_function.sales_loader.arn
  starting_position              = "LATEST"
  batch_size                     = 10
  maximum_retry_attempts         = 3
  bisect_batch_on_function_error = true

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["MODIFY"]
        dynamodb  = { Keys = { pk = { S = [{ prefix = "PRODUCT#" }] }, sk = { S = ["META"] } } }
      })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_dlq.arn
    }
  }

  depends_on = [aws_iam_role_policy.sales_loader]
}

resource "aws_iam_role" "forecast_api" {
  name               = "${var.project}-forecast-api-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "forecast_api_vpc" {
  role       = aws_iam_role.forecast_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "forecast_api" {
  statement {
    sid       = "ReadDbPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_secret_arn]
  }

  statement {
    sid       = "ListProducts"
    actions   = ["dynamodb:Query"]
    resources = ["${aws_dynamodb_table.main.arn}/index/*"]
  }
}

resource "aws_iam_role_policy" "forecast_api" {
  name   = "${var.project}-forecast-api-policy"
  role   = aws_iam_role.forecast_api.id
  policy = data.aws_iam_policy_document.forecast_api.json
}

resource "aws_lambda_function" "forecast_api" {
  function_name    = "${var.project}-forecast-api"
  role             = aws_iam_role.forecast_api.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "analytics.api_handler"
  filename         = data.archive_file.analytics.output_path
  source_code_hash = data.archive_file.analytics.output_base64sha256
  memory_size      = 256
  timeout          = 20

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.main.name
      DB_HOST       = aws_db_instance.main.address
      DB_NAME       = local.db_name
      DB_SECRET_ARN = local.db_secret_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.forecast_api,
    aws_iam_role_policy_attachment.forecast_api_vpc,
    aws_vpc_endpoint.secrets,
    aws_vpc_endpoint.dynamodb,
  ]
}

resource "aws_apigatewayv2_integration" "forecast" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.forecast_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "forecast" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /forecast"
  target             = "integrations/${aws_apigatewayv2_integration.forecast.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "forecast_api" {
  statement_id  = "AllowAPIGatewayInvokeForecast"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.forecast_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# --- ECS Fargate: nightly report ------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = var.project
}

resource "aws_cloudwatch_log_group" "report" {
  name              = "/ecs/${var.project}-report"
  retention_in_days = var.log_retention_days
}

# Execution role: lets ECS pull the image, write logs and inject the database password.
resource "aws_iam_role" "report_exec" {
  name               = "${var.project}-report-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "report_exec" {
  role       = aws_iam_role.report_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "report_exec" {
  statement {
    sid       = "InjectDbPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "report_exec" {
  name   = "${var.project}-report-exec-policy"
  role   = aws_iam_role.report_exec.id
  policy = data.aws_iam_policy_document.report_exec.json
}

# Task role: what the report code itself may do.
resource "aws_iam_role" "report_task" {
  name               = "${var.project}-report-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "report_task" {
  statement {
    sid       = "EmailSummary"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "ListProducts"
    actions   = ["dynamodb:Query"]
    resources = ["${aws_dynamodb_table.main.arn}/index/*"]
  }
}

resource "aws_iam_role_policy" "report_task" {
  name   = "${var.project}-report-task-policy"
  role   = aws_iam_role.report_task.id
  policy = data.aws_iam_policy_document.report_task.json
}

# The container is the public python image; the script is passed in, so there is no
# Docker build or registry to manage for this demo.
resource "aws_ecs_task_definition" "report" {
  family                   = "${var.project}-report"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.report_exec.arn
  task_role_arn            = aws_iam_role.report_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "report"
    image     = "public.ecr.aws/docker/library/python:3.12-slim"
    essential = true
    command = [
      "sh", "-c",
      "pip install -q --no-cache-dir --root-user-action=ignore pg8000 boto3 && python -c \"$REPORT_SCRIPT\"",
    ]
    environment = [
      { name = "REPORT_SCRIPT", value = file("${path.module}/../lambdas/report/report.py") },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = local.db_name },
      { name = "TABLE_NAME", value = aws_dynamodb_table.main.name },
      { name = "TOPIC_ARN", value = aws_sns_topic.alerts.arn },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "PIP_DISABLE_PIP_VERSION_CHECK", value = "1" },
    ]
    secrets = [
      { name = "DB_USER", valueFrom = "${local.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${local.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.report.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "report"
      }
    }
  }])
}

# Midnight in India (18:30 UTC) every day.
resource "aws_cloudwatch_event_rule" "nightly_report" {
  name                = "${var.project}-nightly-report"
  schedule_expression = "cron(30 18 * * ? *)"
}

resource "aws_iam_role" "events_run_report" {
  name               = "${var.project}-events-run-report-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_run_report" {
  statement {
    sid     = "RunTask"
    actions = ["ecs:RunTask"]
    resources = [
      aws_ecs_task_definition.report.arn_without_revision,
      "${aws_ecs_task_definition.report.arn_without_revision}:*",
    ]
  }

  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.report_exec.arn, aws_iam_role.report_task.arn]
  }
}

resource "aws_iam_role_policy" "events_run_report" {
  name   = "${var.project}-events-run-report-policy"
  role   = aws_iam_role.events_run_report.id
  policy = data.aws_iam_policy_document.events_run_report.json
}

resource "aws_cloudwatch_event_target" "nightly_report" {
  rule      = aws_cloudwatch_event_rule.nightly_report.name
  target_id = "report-task"
  arn       = aws_ecs_cluster.main.arn
  role_arn  = aws_iam_role.events_run_report.arn

  ecs_target {
    launch_type         = "FARGATE"
    task_definition_arn = aws_ecs_task_definition.report.arn
    task_count          = 1

    network_configuration {
      subnets          = [aws_subnet.public.id]
      security_groups  = [aws_security_group.task.id]
      assign_public_ip = true
    }
  }
}

# Alarm if the Lambdas that touch the database fail.
resource "aws_cloudwatch_metric_alarm" "analytics_errors" {
  for_each = {
    sales_loader = aws_lambda_function.sales_loader.function_name
    forecast_api = aws_lambda_function.forecast_api.function_name
  }

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

output "db_endpoint" {
  value = aws_db_instance.main.address
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "task_security_group_id" {
  value = aws_security_group.task.id
}

output "sales_loader_function" {
  value = aws_lambda_function.sales_loader.function_name
}

# The VPC's Secrets Manager address resolves to this endpoint, so the report task needs it too.
resource "aws_vpc_security_group_ingress_rule" "endpoint_from_task" {
  security_group_id            = aws_security_group.endpoint.id
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
