output "api_url" {
  value = aws_apigatewayv2_api.main.api_endpoint
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "table_name" {
  value = aws_dynamodb_table.main.name
}

output "region" {
  value = var.region
}
