output "http_api_url" {
  value = module.stack.http_api_url
}

output "ws_api_url" {
  value = module.stack.ws_api_url
}

output "cognito_pool_id" {
  value = module.stack.cognito_pool_id
}

output "cognito_client_id" {
  value = module.stack.cognito_client_id
}

output "attachments_bucket" {
  value = module.stack.attachments_bucket
}

output "main_table" {
  value = module.stack.main_table
}

output "ws_table" {
  value = module.stack.ws_table
}
