variable "region" {
  description = "Region de AWS donde vive el state y la infraestructura."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefijo del proyecto."
  type        = string
  default     = "ticketsys"
}
