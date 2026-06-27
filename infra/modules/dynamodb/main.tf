# ------------------------------------------------------------------
# Tabla principal (single-table) + 4 GSIs + DynamoDB Streams
# ------------------------------------------------------------------
resource "aws_dynamodb_table" "main" {
  name         = "${var.prefix}-TicketsSystem"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI1SK"
    type = "S"
  }
  attribute {
    name = "GSI2PK"
    type = "S"
  }
  attribute {
    name = "GSI2SK"
    type = "S"
  }
  attribute {
    name = "GSI3PK"
    type = "S"
  }
  attribute {
    name = "GSI3SK"
    type = "S"
  }
  attribute {
    name = "GSI4PK"
    type = "S"
  }
  attribute {
    name = "GSI4SK"
    type = "S"
  }

  # GSI1: tickets por area + estado concreto
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "number", "title", "priority", "state",
      "assignedToName", "requesterName", "updatedAt", "dueDate"
    ]
  }

  # GSI2: tickets por requester
  global_secondary_index {
    name            = "GSI2"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "number", "title", "priority", "state",
      "assignedToName", "updatedAt", "dueDate"
    ]
  }

  # GSI3: tickets asignados a un agent (sparse)
  global_secondary_index {
    name            = "GSI3"
    hash_key        = "GSI3PK"
    range_key       = "GSI3SK"
    projection_type = "KEYS_ONLY"
  }

  # GSI4: todos los tickets de un area + usuarios de un area (particion compartida)
  global_secondary_index {
    name            = "GSI4"
    hash_key        = "GSI4PK"
    range_key       = "GSI4SK"
    projection_type = "INCLUDE"
    non_key_attributes = [
      "number", "title", "priority", "state",
      "assignedToName", "requesterName", "updatedAt", "dueDate",
      "role", "fullName", "email"
    ]
  }

  point_in_time_recovery {
    enabled = var.env == "prod"
  }

  tags = var.tags
}

# ------------------------------------------------------------------
# Tabla de conexiones WebSocket (efimeras, TTL) + 2 GSIs
# ------------------------------------------------------------------
resource "aws_dynamodb_table" "ws" {
  name         = "${var.prefix}-WSConnections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }
  attribute {
    name = "areaId"
    type = "S"
  }
  attribute {
    name = "userId"
    type = "S"
  }

  ttl {
    attribute_name = "expirationTime"
    enabled        = true
  }

  global_secondary_index {
    name            = "GSIByArea"
    hash_key        = "areaId"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "GSIByUser"
    hash_key        = "userId"
    projection_type = "ALL"
  }

  tags = var.tags
}
