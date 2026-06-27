variable "prefix" {
  type = string
}

variable "callback_urls" {
  description = "URLs de callback OAuth (frontend). Lista vacia por ahora."
  type        = list(string)
  default     = []
}

variable "post_confirmation_lambda_arn" {
  description = "ARN de la Lambda que se ejecuta tras confirmar el registro (crea el item USER)."
  type        = string
  default     = null
}

variable "enable_post_confirmation" {
  description = "Activa el trigger PostConfirmation. Estatico (no depende del ARN) para evitar count/for_each unknown."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
