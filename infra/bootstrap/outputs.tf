output "state_bucket" {
  description = "Nombre del bucket S3 del remote state. Usalo en environments/*/backend.tf."
  value       = aws_s3_bucket.tf_state.id
}

output "lock_table" {
  description = "Tabla DynamoDB para el lock de Terraform."
  value       = aws_dynamodb_table.tf_lock.name
}

output "account_id" {
  description = "ID de la cuenta de AWS."
  value       = local.account_id
}
