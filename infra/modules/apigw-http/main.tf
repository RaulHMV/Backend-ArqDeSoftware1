resource "aws_apigatewayv2_api" "http" {
  name          = "${var.prefix}-http"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3000
  }

  tags = var.tags
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.http.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [var.cognito_client_id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${var.cognito_pool_id}"
  }
}

# Una integracion + ruta por cada entrada del mapa de rutas
resource "aws_apigatewayv2_integration" "this" {
  for_each               = var.routes
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.uri
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each           = var.routes
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.key].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  tags        = var.tags
}

# Permiso para que API Gateway invoque cada Lambda. Se itera sobre las rutas
# (claves estaticas) en vez de los ARNs (known-after-apply). Varias rutas a la
# misma funcion generan permisos extra inofensivos con statement_id distinto.
resource "aws_lambda_permission" "this" {
  for_each      = var.routes
  statement_id  = "AllowHTTPInvoke-${substr(md5(each.key), 0, 12)}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.fn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
