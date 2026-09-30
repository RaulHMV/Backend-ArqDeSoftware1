#!/usr/bin/env python3
"""Arma el inventario de Ansible (JSON) desde `terraform output -json nodes`.

Uso: make_inventory.py nodes.json ruta_llave_privada > inventory.json
"""
import json
import sys

nodes_file, key_file = sys.argv[1], sys.argv[2]

with open(nodes_file) as f:
    nodes = json.load(f)

inventory = {
    "pg": {
        "hosts": {
            name: {
                "ansible_host": n["public_ip"],
                "private_ip": n["private_ip"],
                "node_index": n["index"],
            }
            for name, n in sorted(nodes.items())
        },
        "vars": {
            "ansible_user": "ubuntu",
            "ansible_ssh_private_key_file": key_file,
        },
    }
}

json.dump(inventory, sys.stdout, indent=2)
