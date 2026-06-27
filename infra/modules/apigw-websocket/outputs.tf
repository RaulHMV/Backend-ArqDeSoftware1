output "api_id" {
  value = aws_apigatewayv2_api.ws.id
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.ws.api_endpoint
}

output "stage_name" {
  value = aws_apigatewayv2_stage.stage.name
}

output "stage_url" {
  value = "${aws_apigatewayv2_api.ws.api_endpoint}/${aws_apigatewayv2_stage.stage.name}"
}

output "execution_arn" {
  value = aws_apigatewayv2_api.ws.execution_arn
}

# Endpoint HTTPS para postToConnection (ApiGatewayManagementApi)
output "management_endpoint" {
  value = "https://${aws_apigatewayv2_api.ws.id}.execute-api.${data.aws_region.current.name}.amazonaws.com/${aws_apigatewayv2_stage.stage.name}"
}

data "aws_region" "current" {}
