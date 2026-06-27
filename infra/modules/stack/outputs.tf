output "http_api_url" {
  description = "Base URL de la REST/HTTP API."
  value       = module.apigw_http.api_endpoint
}

output "ws_api_url" {
  description = "URL del WebSocket (wss). Conectar con ?token=<JWT>."
  value       = replace(module.apigw_ws.stage_url, "https://", "wss://")
}

output "cognito_pool_id" {
  value = module.cognito.pool_id
}

output "cognito_client_id" {
  value = module.cognito.client_id
}

output "attachments_bucket" {
  value = module.s3.bucket_name
}

output "main_table" {
  value = module.dynamodb.main_table_name
}

output "ws_table" {
  value = module.dynamodb.ws_table_name
}
