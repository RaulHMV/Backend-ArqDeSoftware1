resource "aws_apigatewayv2_api" "ws" {
  name                       = "${var.prefix}-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
  tags                       = var.tags
}

# Lambda Authorizer (REQUEST) que valida el JWT en el query string del $connect
resource "aws_apigatewayv2_authorizer" "request" {
  api_id                            = aws_apigatewayv2_api.ws.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = var.authorizer_invoke_arn
  identity_sources                  = ["route.request.querystring.token"]
  name                              = "ws-jwt-authorizer"
  authorizer_payload_format_version = null
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowWSAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.authorizer_function_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.request.id}"
}

# ---------------- Rutas ----------------
locals {
  routes = {
    "$connect" = {
      invoke_arn   = var.connect_invoke_arn
      function_arn = var.connect_function_arn
      authorized   = true
    }
    "$disconnect" = {
      invoke_arn   = var.disconnect_invoke_arn
      function_arn = var.disconnect_function_arn
      authorized   = false
    }
    "sendMessage" = {
      invoke_arn   = var.message_invoke_arn
      function_arn = var.message_function_arn
      authorized   = false
    }
  }
}

resource "aws_apigatewayv2_integration" "this" {
  for_each         = local.routes
  api_id           = aws_apigatewayv2_api.ws.id
  integration_type = "AWS_PROXY"
  integration_uri  = each.value.invoke_arn
}

resource "aws_apigatewayv2_route" "this" {
  for_each           = local.routes
  api_id             = aws_apigatewayv2_api.ws.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.key].id}"
  authorization_type = each.value.authorized ? "CUSTOM" : "NONE"
  authorizer_id      = each.value.authorized ? aws_apigatewayv2_authorizer.request.id : null
}

resource "aws_lambda_permission" "routes" {
  for_each      = local.routes
  statement_id  = "AllowWSInvoke-${substr(md5(each.key), 0, 8)}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "stage" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = var.env
  auto_deploy = true
  tags        = var.tags
}
