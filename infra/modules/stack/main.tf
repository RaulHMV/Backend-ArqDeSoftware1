data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix     = "${var.project}-${var.env}"
  account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Project     = "ticket-system"
    Environment = var.env
    ManagedBy   = "Terraform"
  }

  ssm_arn = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/${var.env}/*"

  # Variables de entorno comunes a todas las Lambdas
  common_env = {
    MAIN_TABLE         = module.dynamodb.main_table_name
    WS_TABLE           = module.dynamodb.ws_table_name
    ATTACHMENTS_BUCKET = module.s3.bucket_name
    APP_REGION         = var.region
    COGNITO_POOL_ID    = module.cognito.pool_id
    COGNITO_CLIENT_ID  = module.cognito.client_id
    SSM_PREFIX         = "/${var.project}/${var.env}"
    WS_ENDPOINT_PARAM  = "/${var.project}/${var.env}/ws_management_endpoint"
    MAX_UPLOAD_BYTES   = "10485760"
  }

  # ---------------- Policies least-privilege ----------------
  policy_data_rw = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DdbMain"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:BatchWriteItem",
          "dynamodb:BatchGetItem"
        ]
        Resource = [module.dynamodb.main_table_arn, "${module.dynamodb.main_table_arn}/index/*"]
      },
      {
        Sid      = "Ssm"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [local.ssm_arn]
      }
    ]
  })

  policy_attachments = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DdbMain"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query"
        ]
        Resource = [module.dynamodb.main_table_arn, "${module.dynamodb.main_table_arn}/index/*"]
      },
      {
        Sid      = "S3Attachments"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${module.s3.bucket_arn}/attachments/*"]
      },
      {
        Sid      = "Ssm"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [local.ssm_arn]
      }
    ]
  })

  policy_authorizer = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Ssm"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [local.ssm_arn]
      }
    ]
  })

  policy_ws = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DdbWs"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:GetItem"
        ]
        Resource = [module.dynamodb.ws_table_arn, "${module.dynamodb.ws_table_arn}/index/*"]
      },
      {
        Sid      = "Ssm"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [local.ssm_arn]
      }
    ]
  })

  policy_notifications = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DdbMainRead"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem"]
        Resource = [module.dynamodb.main_table_arn, "${module.dynamodb.main_table_arn}/index/*"]
      },
      {
        Sid      = "DdbWs"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:DeleteItem"]
        Resource = [module.dynamodb.ws_table_arn, "${module.dynamodb.ws_table_arn}/index/*"]
      },
      {
        Sid    = "Stream"
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords", "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream", "dynamodb:ListStreams"
        ]
        Resource = [module.dynamodb.main_table_stream_arn]
      },
      {
        Sid      = "Ssm"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [local.ssm_arn]
      }
    ]
  })

  policy_manage_connections = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["execute-api:ManageConnections"]
        Resource = ["${module.apigw_ws.execution_arn}/*"]
      }
    ]
  })

  policy_cognito_admin = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminAddUserToGroup", "cognito-idp:AdminRemoveUserFromGroup",
          "cognito-idp:AdminUpdateUserAttributes", "cognito-idp:AdminGetUser",
          "cognito-idp:ListUsers", "cognito-idp:ListUsersInGroup"
        ]
        Resource = [module.cognito.pool_arn]
      }
    ]
  })

  # Lambdas HTTP/WS/stream (todas menos la de PostConfirmation, que va antes de Cognito)
  handlers = {
    "tickets"                = { policy = local.policy_data_rw, timeout = 15, memory = 256 }
    "comments"               = { policy = local.policy_data_rw, timeout = 15, memory = 256 }
    "users"                  = { policy = local.policy_data_rw, timeout = 15, memory = 256 }
    "areas"                  = { policy = local.policy_data_rw, timeout = 15, memory = 256 }
    "attachments"            = { policy = local.policy_attachments, timeout = 15, memory = 256 }
    "ws-authorizer"          = { policy = local.policy_authorizer, timeout = 10, memory = 256 }
    "ws-connect"             = { policy = local.policy_ws, timeout = 10, memory = 256 }
    "ws-disconnect"          = { policy = local.policy_ws, timeout = 10, memory = 256 }
    "ws-message"             = { policy = local.policy_ws, timeout = 10, memory = 256 }
    "notifications-dispatch" = { policy = local.policy_notifications, timeout = 30, memory = 256 }
  }

  http_routes = {
    "GET /tickets"                = { uri = module.lambdas["tickets"].invoke_arn, fn = module.lambdas["tickets"].function_name }
    "POST /tickets"               = { uri = module.lambdas["tickets"].invoke_arn, fn = module.lambdas["tickets"].function_name }
    "GET /tickets/{id}"           = { uri = module.lambdas["tickets"].invoke_arn, fn = module.lambdas["tickets"].function_name }
    "PUT /tickets/{id}"           = { uri = module.lambdas["tickets"].invoke_arn, fn = module.lambdas["tickets"].function_name }
    "GET /tickets/{id}/comments"  = { uri = module.lambdas["comments"].invoke_arn, fn = module.lambdas["comments"].function_name }
    "POST /tickets/{id}/comments" = { uri = module.lambdas["comments"].invoke_arn, fn = module.lambdas["comments"].function_name }
    "POST /attachments/presign"   = { uri = module.lambdas["attachments"].invoke_arn, fn = module.lambdas["attachments"].function_name }
    "GET /attachments/download"   = { uri = module.lambdas["attachments"].invoke_arn, fn = module.lambdas["attachments"].function_name }
    "GET /users/me"               = { uri = module.lambdas["users"].invoke_arn, fn = module.lambdas["users"].function_name }
    "GET /users"                  = { uri = module.lambdas["users"].invoke_arn, fn = module.lambdas["users"].function_name }
    "POST /users"                 = { uri = module.lambdas["users"].invoke_arn, fn = module.lambdas["users"].function_name }
    "GET /areas"                  = { uri = module.lambdas["areas"].invoke_arn, fn = module.lambdas["areas"].function_name }
    "POST /areas"                 = { uri = module.lambdas["areas"].invoke_arn, fn = module.lambdas["areas"].function_name }
  }
}

# ------------------------------------------------------------------
# Datos
# ------------------------------------------------------------------
module "dynamodb" {
  source = "../dynamodb"
  prefix = local.prefix
  env    = var.env
  tags   = local.common_tags
}

module "s3" {
  source       = "../s3-attachments"
  prefix       = local.prefix
  cors_origins = var.cors_origins
  tags         = local.common_tags
}

# ------------------------------------------------------------------
# Lambda de PostConfirmation (debe existir ANTES de crear el pool)
# ------------------------------------------------------------------
module "lambda_postconf" {
  source     = "../lambda"
  prefix     = local.prefix
  name       = "cognito-postconfirmation"
  source_dir = "${var.backend_dist_path}/cognito-postconfirmation"
  env_vars = {
    MAIN_TABLE = module.dynamodb.main_table_name
    APP_REGION = var.region
    SSM_PREFIX = "/${var.project}/${var.env}"
  }
  extra_policy_json = local.policy_data_rw
  tags              = local.common_tags
}

module "cognito" {
  source                       = "../cognito"
  prefix                       = local.prefix
  post_confirmation_lambda_arn = module.lambda_postconf.function_arn
  enable_post_confirmation     = true
  tags                         = local.common_tags
}

# ------------------------------------------------------------------
# Resto de Lambdas (consumen outputs de Cognito/DynamoDB/S3)
# ------------------------------------------------------------------
module "lambdas" {
  source            = "../lambda"
  for_each          = local.handlers
  prefix            = local.prefix
  name              = each.key
  source_dir        = "${var.backend_dist_path}/${each.key}"
  env_vars          = local.common_env
  extra_policy_json = each.value.policy
  timeout           = each.value.timeout
  memory            = each.value.memory
  tags              = local.common_tags
}

# ------------------------------------------------------------------
# API Gateways
# ------------------------------------------------------------------
module "apigw_http" {
  source            = "../apigw-http"
  prefix            = local.prefix
  env               = var.env
  region            = var.region
  cors_origins      = var.cors_origins
  cognito_client_id = module.cognito.client_id
  cognito_pool_id   = module.cognito.pool_id
  routes            = local.http_routes
  tags              = local.common_tags
}

module "apigw_ws" {
  source                  = "../apigw-websocket"
  prefix                  = local.prefix
  env                     = var.env
  authorizer_invoke_arn   = module.lambdas["ws-authorizer"].invoke_arn
  authorizer_function_arn = module.lambdas["ws-authorizer"].function_arn
  connect_invoke_arn      = module.lambdas["ws-connect"].invoke_arn
  disconnect_invoke_arn   = module.lambdas["ws-disconnect"].invoke_arn
  message_invoke_arn      = module.lambdas["ws-message"].invoke_arn
  connect_function_arn    = module.lambdas["ws-connect"].function_arn
  disconnect_function_arn = module.lambdas["ws-disconnect"].function_arn
  message_function_arn    = module.lambdas["ws-message"].function_arn
  tags                    = local.common_tags
}

# ------------------------------------------------------------------
# SSM: endpoint de gestion del WebSocket (lo lee notifications-dispatch en runtime)
# ------------------------------------------------------------------
resource "aws_ssm_parameter" "ws_management_endpoint" {
  name  = "/${var.project}/${var.env}/ws_management_endpoint"
  type  = "String"
  value = module.apigw_ws.management_endpoint
  tags  = local.common_tags
}

# ------------------------------------------------------------------
# Policies extra que cierran ciclos (se adjuntan despues de crear apigw/cognito)
# ------------------------------------------------------------------
resource "aws_iam_role_policy" "ws_message_manage" {
  name   = "${local.prefix}-ws-message-manage"
  role   = module.lambdas["ws-message"].role_name
  policy = local.policy_manage_connections
}

resource "aws_iam_role_policy" "notifications_manage" {
  name   = "${local.prefix}-notifications-manage"
  role   = module.lambdas["notifications-dispatch"].role_name
  policy = local.policy_manage_connections
}

resource "aws_iam_role_policy" "users_cognito" {
  name   = "${local.prefix}-users-cognito"
  role   = module.lambdas["users"].role_name
  policy = local.policy_cognito_admin
}

resource "aws_iam_role_policy" "postconf_cognito" {
  name   = "${local.prefix}-postconf-cognito"
  role   = module.lambda_postconf.role_name
  policy = local.policy_cognito_admin
}

# ------------------------------------------------------------------
# DynamoDB Streams -> notifications-dispatch
# ------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "stream" {
  event_source_arn  = module.dynamodb.main_table_stream_arn
  function_name     = module.lambdas["notifications-dispatch"].function_arn
  starting_position = "LATEST"
  batch_size        = 10

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT", "MODIFY"]
      })
    }
  }
}
