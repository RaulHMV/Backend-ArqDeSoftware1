variable "prefix" {
  type = string
}

variable "name" {
  description = "Nombre corto de la funcion, ej. tickets."
  type        = string
}

variable "source_dir" {
  description = "Carpeta con el bundle (index.js) generado por esbuild, ej. ../../backend/dist/tickets."
  type        = string
}

variable "handler" {
  type    = string
  default = "index.handler"
}

variable "runtime" {
  type    = string
  default = "nodejs20.x"
}

variable "timeout" {
  type    = number
  default = 15
}

variable "memory" {
  type    = number
  default = 256
}

variable "env_vars" {
  type    = map(string)
  default = {}
}

variable "extra_policy_json" {
  description = "Policy IAM least-privilege en JSON. null para no adjuntar nada extra."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
