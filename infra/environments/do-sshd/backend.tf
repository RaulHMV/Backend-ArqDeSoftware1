terraform {
  required_version = ">= 1.6.0"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  # SIN backend remoto (a proposito, es gratis): el state vive solo durante el run.
  # El workflow busca el droplet por su tag: si no existe lo crea con este Terraform;
  # si ya existe solo re-aplica Ansible. sshd-destroy borra todo con doctl.
}

# El token se toma de la variable de entorno DIGITALOCEAN_TOKEN (secret del repo).
provider "digitalocean" {}
