terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }

resource "null_resource" "ssh_hardening" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-EOF
      # Homelab hardened SSH config
      PermitRootLogin no
      PasswordAuthentication no
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      PermitEmptyPasswords no
      ChallengeResponseAuthentication no
      UsePAM yes
      X11Forwarding no
      PrintMotd no
      AcceptEnv LANG LC_*
      Subsystem sftp /usr/lib/openssh/sftp-server
      # Restrict to key auth only — no passwords, no root
      MaxAuthTries 3
      LoginGraceTime 20
    EOF
    destination = "/tmp/sshd_hardened.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      # Back up original
      "sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true",
      # Drop our config into sshd_config.d (Ubuntu 22.04+ approach)
      "sudo mkdir -p /etc/ssh/sshd_config.d",
      "sudo mv /tmp/sshd_hardened.conf /etc/ssh/sshd_config.d/99-homelab-hardening.conf",
      "sudo chmod 644 /etc/ssh/sshd_config.d/99-homelab-hardening.conf",
      # Validate before reloading
      "sudo sshd -t",
      "sudo systemctl reload sshd",
      "echo 'SSH hardened: root login disabled, password auth disabled.'"
    ]
  }
}

output "done" {
  value = null_resource.ssh_hardening.id
}
