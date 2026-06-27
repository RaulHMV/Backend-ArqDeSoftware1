resource "aws_cognito_user_pool" "main" {
  name                     = "${var.prefix}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
    require_lowercase = true
  }

  schema {
    name                     = "areaId"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false
    string_attribute_constraints {
      min_length = 0
      max_length = 64
    }
  }

  dynamic "lambda_config" {
    for_each = var.enable_post_confirmation ? [1] : []
    content {
      post_confirmation = var.post_confirmation_lambda_arn
    }
  }

  tags = var.tags
}

resource "aws_cognito_user_pool_client" "web" {
  name            = "${var.prefix}-web"
  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
  ]

  read_attributes  = ["email", "custom:areaId"]
  write_attributes = ["email", "custom:areaId"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  callback_urls = length(var.callback_urls) > 0 ? var.callback_urls : null
}

resource "aws_cognito_user_group" "roles" {
  for_each     = toset(["Requester", "Agent", "Manager", "Admin"])
  name         = each.value
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Rol ${each.value}"
}

# Permiso para que Cognito invoque la Lambda de PostConfirmation
resource "aws_lambda_permission" "post_confirmation" {
  count         = var.enable_post_confirmation ? 1 : 0
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.post_confirmation_lambda_arn
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}
