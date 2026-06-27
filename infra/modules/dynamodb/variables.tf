variable "prefix" {
  description = "Prefijo de nombres, ej. ticketsys-dev."
  type        = string
}

variable "env" {
  description = "Ambiente (dev/prod)."
  type        = string
}

variable "tags" {
  description = "Tags comunes."
  type        = map(string)
  default     = {}
}
