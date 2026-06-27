output "main_table_name" {
  value = aws_dynamodb_table.main.name
}

output "main_table_arn" {
  value = aws_dynamodb_table.main.arn
}

output "main_table_stream_arn" {
  value = aws_dynamodb_table.main.stream_arn
}

output "ws_table_name" {
  value = aws_dynamodb_table.ws.name
}

output "ws_table_arn" {
  value = aws_dynamodb_table.ws.arn
}
