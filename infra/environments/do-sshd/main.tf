resource "digitalocean_ssh_key" "this" {
  count      = var.existing_ssh_key_fingerprint == "" ? 1 : 0
  name       = "${var.droplet_name}-key"
  public_key = var.ssh_public_key
}

locals {
  ssh_key_fingerprint = (
    var.existing_ssh_key_fingerprint != ""
    ? var.existing_ssh_key_fingerprint
    : digitalocean_ssh_key.this[0].fingerprint
  )
}

resource "digitalocean_droplet" "this" {
  name       = var.droplet_name
  image      = var.image
  region     = var.region
  size       = var.size
  ssh_keys   = [local.ssh_key_fingerprint]
  tags       = [var.droplet_tag]
  monitoring = true
  ipv6       = false

  # Sin el agente de la "Droplet Console" web: una puerta de entrada menos que no
  # pasa por el SSH endurecido. La "Recovery Console" del panel sigue disponible.
  # (Rocky trae SELinux en enforcing; el playbook lo asume.)
  droplet_agent = false
}

# Firewall de red de DigitalOcean: SOLO tu IP y SOLO el puerto de SSH; nada mas entra
# (el 22 tampoco). Mientras corre el pipeline, el workflow agrega la IP del runner (22 y
# ssh_port) y la quita al terminar. Salida abierta (dnf, DNS y NTP: los codigos TOTP
# dependen de que la hora este bien).
resource "digitalocean_firewall" "ssh" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.this.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.ssh_port)
    source_addresses = ["${var.my_ip}/32"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
