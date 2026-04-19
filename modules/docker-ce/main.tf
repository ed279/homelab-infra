terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }

resource "null_resource" "docker_ce" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      # Skip if already installed
      "if command -v docker &>/dev/null; then echo 'Docker already installed, skipping.'; exit 0; fi",

      # Install dependencies
      "sudo apt-get update -qq",
      "sudo apt-get install -y ca-certificates curl gnupg lsb-release",

      # Add Docker GPG key and repo
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "sudo chmod a+r /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",

      # Install Docker CE
      "sudo apt-get update -qq",
      "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",

      # Enable and start
      "sudo systemctl enable docker",
      "sudo systemctl start docker",

      # Add current user to docker group
      "sudo usermod -aG docker ${var.server_user}",

      "echo 'Docker CE installed successfully.'"
    ]
  }
}

output "done" {
  value = null_resource.docker_ce.id
}
