variable "prefix" {
  type = string
}

variable "env" {
  type = string
}

variable "authorizer_invoke_arn" {
  description = "invoke_arn de la Lambda authorizer (ws-authorizer)."
  type        = string
}

variable "authorizer_function_arn" {
  description = "ARN de la funcion ws-authorizer (para el lambda permission)."
  type        = string
}

variable "connect_invoke_arn" {
  type = string
}

variable "disconnect_invoke_arn" {
  type = string
}

variable "message_invoke_arn" {
  type = string
}

variable "connect_function_arn" {
  type = string
}

variable "disconnect_function_arn" {
  type = string
}

variable "message_function_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
