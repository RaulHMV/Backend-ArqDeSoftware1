# ------------------------------------------------------------------
# Red: VPC default y una subnet default por AZ. Si la cuenta no tiene
# VPC default (hardening), el data source falla aqui con "no matching VPC".
# ------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# AZs donde realmente existe el tipo de instancia (no todas lo ofrecen).
data "aws_ec2_instance_type_offerings" "az" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name = "${var.project}-mysqlmm"

  subnet_by_az = {
    for s in data.aws_subnet.default : s.availability_zone => s.id
    if contains(data.aws_ec2_instance_type_offerings.az.locations, s.availability_zone)
  }
  azs = sort(keys(local.subnet_by_az))

  # Un nodo por AZ distinta. index: 0 -> server_id 1 / IDs impares, 1 -> server_id 2 / IDs pares.
  nodes = {
    for i, n in ["node_a", "node_b"] : n => {
      index = i
      az    = try(local.azs[i], "")
    }
  }
}

resource "terraform_data" "guard" {
  lifecycle {
    precondition {
      condition     = length(local.azs) >= 2
      error_message = "Se necesitan 2 AZs con subnet default que ofrezcan ${var.instance_type}. Revisa la VPC default de la region."
    }
  }
}

# ------------------------------------------------------------------
# SSH: llave generada por Terraform (la privada queda como output sensitive)
# ------------------------------------------------------------------
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = "${local.name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# ------------------------------------------------------------------
# Security group: TODAS las reglas son recursos aparte (nada inline), asi
# no hay conflicto entre aws_security_group y las reglas sueltas.
# ------------------------------------------------------------------
resource "aws_security_group" "pg" {
  name        = "${local.name}-sg"
  description = "SSH + MySQL entre nodos"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.pg.id
  cidr_ipv4         = var.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# 3306 solo entre miembros del mismo SG (los 2 nodos), nunca al mundo.
resource "aws_vpc_security_group_ingress_rule" "mysql_peer" {
  security_group_id            = aws_security_group.pg.id
  referenced_security_group_id = aws_security_group.pg.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.pg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ------------------------------------------------------------------
# Nodos EC2
# ------------------------------------------------------------------
resource "aws_instance" "node" {
  for_each = local.nodes

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_by_az[each.value.az]
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.pg.id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-${each.key}"
  }

  depends_on = [terraform_data.guard]

  lifecycle {
    # most_recent cambia cuando Canonical publica AMI nueva; sin esto el
    # siguiente apply reemplazaria los servidores y perderia los datos.
    ignore_changes = [ami]
  }
}
