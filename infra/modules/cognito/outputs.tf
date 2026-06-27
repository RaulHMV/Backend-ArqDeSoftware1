output "pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "pool_arn" {
  value = aws_cognito_user_pool.main.arn
}

output "client_id" {
  value = aws_cognito_user_pool_client.web.id
}
