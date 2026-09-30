output "nodes" {
  description = "Datos de cada nodo; el workflow los usa para armar el inventario de Ansible."
  value = {
    for k, i in aws_instance.node : k => {
      index       = local.nodes[k].index
      az          = i.availability_zone
      instance_id = i.id
      public_ip   = i.public_ip
      private_ip  = i.private_ip
    }
  }
}

output "ssh_private_key" {
  description = "Llave privada SSH (usuario ubuntu)."
  value       = tls_private_key.ssh.private_key_openssh
  sensitive   = true
}
