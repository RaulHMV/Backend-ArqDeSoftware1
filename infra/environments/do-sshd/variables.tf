# DigitalOcean solo acepta letras, numeros, "." y "-" en el nombre (sin "_").
variable "droplet_name" {
  type    = string
  default = "SSHD-Conexion"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]?[a-zA-Z0-9.-]*[a-zA-Z0-9]$", var.droplet_name))
    error_message = "El nombre solo admite letras, numeros, \".\" y \"-\" (DigitalOcean no acepta \"_\")."
  }
}

# El tag si acepta "_": asi el droplet tambien queda identificado como SSHD_Conexion.
variable "droplet_tag" {
  type    = string
  default = "SSHD_Conexion"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_:-]+$", var.droplet_tag))
    error_message = "El tag solo admite letras, numeros, \"_\", \":\" y \"-\"."
  }
}

variable "region" {
  type    = string
  default = "sfo3"
}

variable "size" {
  description = "s-1vcpu-1gb: 1 vCPU / 1 GB (~6 USD/mes, se cobra por hora)."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "image" {
  type    = string
  default = "rockylinux-9-x64"
}

variable "ssh_public_key" {
  description = "Llave publica RSA 4096 en formato OpenSSH (el workflow la saca de tu llave privada)."
  type        = string

  validation {
    condition     = can(regex("^ssh-rsa ", var.ssh_public_key))
    error_message = "ssh_public_key debe ser una llave RSA (ssh-rsa ...); el workflow exige 4096 bits."
  }
}

# DigitalOcean no deja registrar dos veces la misma llave publica: si ya esta en la
# cuenta, el workflow pasa su fingerprint y se reusa en vez de crearla.
variable "existing_ssh_key_fingerprint" {
  type    = string
  default = ""
}

# La UNICA IP que puede entrar por SSH (tu IP publica). El workflow agrega la IP del
# runner solo mientras corre Ansible y la quita al terminar.
variable "my_ip" {
  description = "Tu IP publica, ej. 203.0.113.7 (se usa como /32)."
  type        = string

  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0)) && !strcontains(var.my_ip, "/")
    error_message = "my_ip debe ser una IPv4 sin mascara, ej. 203.0.113.7."
  }
}

# SSH NO va en el 22: el puerto no puede llevar ningun 2. El firewall solo abre este
# puerto (y solo para my_ip).
variable "ssh_port" {
  type    = number
  default = 3947

  validation {
    condition     = !strcontains(tostring(var.ssh_port), "2") && var.ssh_port >= 1024 && var.ssh_port <= 65535
    error_message = "ssh_port debe estar entre 1024 y 65535 y no puede llevar ningun 2 (ej. 3947)."
  }
}
