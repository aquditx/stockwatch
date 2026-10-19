data "archive_file" "products" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/products"
  output_path = "${path.module}/build/products.zip"
}

resource "aws_cloudwatch_log_group" "products" {
  name              = "/aws/lambda/${var.project}-products"
  retention_in_days = var.log_retention_days
}

# --- Least-privilege execution role -----------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "products" {
  name               = "${var.project}-products-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "products" {
  statement {
    sid = "TableAccess"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.main.arn,
      "${aws_dynamodb_table.main.arn}/index/*",
    ]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.products.arn}:*"]
  }
}

resource "aws_iam_role_policy" "products" {
  name   = "${var.project}-products-policy"
  role   = aws_iam_role.products.id
  policy = data.aws_iam_policy_document.products.json
}

# --- Function ---------------------------------------------------------------

resource "aws_lambda_function" "products" {
  function_name    = "${var.project}-products"
  role             = aws_iam_role.products.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.products.output_path
  source_code_hash = data.archive_file.products.output_base64sha256
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.main.name
      GSI_NAME   = "gsi1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.products]
}
