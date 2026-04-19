terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }
variable "lan_subnet"           { type = string }
variable "mgmt_subnet"          { type = string; default = "" }

resource "null_resource" "ufw" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo apt-get install -y ufw -qq",

      # Reset to clean state
      "sudo ufw --force reset",

      # Default: deny inbound, allow outbound
      "sudo ufw default deny incoming",
      "sudo ufw default allow outgoing",

      # SSH — LAN + management VLANs (add your management subnet here)
      "sudo ufw allow from ${var.lan_subnet} to any port 22 proto tcp comment 'SSH from LAN'",
      "[ -n '${var.mgmt_subnet}' ] && sudo ufw allow from ${var.mgmt_subnet} to any port 22 proto tcp comment 'SSH from mgmt VLAN' || true",

      # DNS — LAN only (Pi-hole)
      "sudo ufw allow from ${var.lan_subnet} to any port 53 proto tcp comment 'DNS TCP from LAN'",
      "sudo ufw allow from ${var.lan_subnet} to any port 53 proto udp comment 'DNS UDP from LAN'",

      # Pi-hole web UI
      "sudo ufw allow from ${var.lan_subnet} to any port 80 proto tcp comment 'Pi-hole HTTP from LAN'",
      "sudo ufw allow from ${var.lan_subnet} to any port 443 proto tcp comment 'Pi-hole HTTPS from LAN'",
      "[ -n '${var.mgmt_subnet}' ] && sudo ufw allow from ${var.mgmt_subnet} to any port 80 proto tcp comment 'Pi-hole HTTP from mgmt' || true",
      "[ -n '${var.mgmt_subnet}' ] && sudo ufw allow from ${var.mgmt_subnet} to any port 443 proto tcp comment 'Pi-hole HTTPS from mgmt' || true",

      # Vault
      "sudo ufw allow from ${var.lan_subnet} to any port 8200 proto tcp comment 'Vault from LAN'",
      "[ -n '${var.mgmt_subnet}' ] && sudo ufw allow from ${var.mgmt_subnet} to any port 8200 proto tcp comment 'Vault from mgmt' || true",

      # DHCP (Pi-hole optional DHCP server)
      "sudo ufw allow from ${var.lan_subnet} to any port 67 proto udp comment 'DHCP from LAN'",

      # Loopback always allowed
      "sudo ufw allow in on lo",

      # Enable
      "sudo ufw --force enable",
      "sudo ufw status verbose",
      "echo 'Firewall enabled.'"
    ]
  }
}

output "done" {
  value = null_resource.ufw.id
}
