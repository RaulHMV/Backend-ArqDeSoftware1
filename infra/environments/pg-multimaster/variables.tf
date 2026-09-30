variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "ticketsys"
}

variable "instance_type" {
  description = "t3.micro entra en free tier en cuentas viejas y nuevas; t3.small solo con creditos."
  type        = string
  default     = "t3.micro"
}

variable "volume_size" {
  description = "GB del disco raiz (gp3) de cada nodo."
  type        = number
  default     = 20
}

variable "ssh_cidr" {
  description = "CIDR con acceso SSH. Restringelo a tu IP (ej. 203.0.113.7/32) si puedes."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0))
    error_message = "ssh_cidr debe ser un CIDR valido, ej. 203.0.113.7/32."
  }
}
