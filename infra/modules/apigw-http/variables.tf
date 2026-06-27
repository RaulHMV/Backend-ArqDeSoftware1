variable "prefix" {
  type = string
}

variable "env" {
  type = string
}

variable "cors_origins" {
  type    = list(string)
  default = ["*"]
}

variable "cognito_client_id" {
  type = string
}

variable "cognito_pool_id" {
  type = string
}

variable "region" {
  type = string
}

variable "routes" {
  description = "Mapa 'METHOD /path' => { uri = invoke_arn, fn = function_name } de la Lambda."
  type = map(object({
    uri = string
    fn  = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
