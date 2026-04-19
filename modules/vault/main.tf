terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }
variable "data_dir"             { type = string }
variable "depends_on_id"        { type = string; default = "" }

resource "null_resource" "vault_dirs" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${var.data_dir}/data ${var.data_dir}/config",
      "sudo chown -R $USER:$USER ${var.data_dir}",
    ]
  }
}

resource "null_resource" "vault_config" {
  depends_on = [null_resource.vault_dirs]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-EOF
      ui = true

      listener "tcp" {
        address     = "0.0.0.0:8200"
        tls_disable = 1
      }

      storage "file" {
        path = "/vault/data"
      }

      api_addr     = "http://0.0.0.0:8200"
      cluster_addr = "http://0.0.0.0:8201"
    EOF
    destination = "${var.data_dir}/config/vault.hcl"
  }
}

resource "null_resource" "vault_compose" {
  depends_on = [null_resource.vault_config]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-EOF
      services:
        vault:
          image: hashicorp/vault:1.19
          container_name: vault
          restart: unless-stopped
          ports:
            - "8200:8200"
          environment:
            VAULT_ADDR: "http://0.0.0.0:8200"
          volumes:
            - ${var.data_dir}/data:/vault/data
            - ${var.data_dir}/config:/vault/config
          cap_add:
            - IPC_LOCK
          entrypoint: /bin/sh
          command:
            - -c
            - |
              chown -R vault:vault /vault/data
              su-exec vault vault server -config=/vault/config/vault.hcl
          healthcheck:
            test: ["CMD", "vault", "status", "-address=http://127.0.0.1:8200"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s
    EOF
    destination = "/tmp/vault-compose.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/vault",
      "sudo mv /tmp/vault-compose.yml /opt/vault/docker-compose.yml",
    ]
  }
}

resource "null_resource" "vault_start" {
  depends_on = [null_resource.vault_compose]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "cd /opt/vault",
      "docker compose down 2>/dev/null || true",
      "docker compose pull",
      "docker compose up -d",

      # Wait for Vault to be ready
      "echo 'Waiting for Vault...'",
      "for i in $(seq 1 20); do",
      "  if curl -sf http://127.0.0.1:8200/v1/sys/init -o /dev/null 2>&1; then break; fi",
      "  sleep 2",
      "done",

      # Initialize Vault if not already done
      "INIT=$(curl -s http://127.0.0.1:8200/v1/sys/init | python3 -c \"import sys,json; print(json.load(sys.stdin)['initialized'])\")",
      "if [ \"$INIT\" = 'False' ]; then",
      "  echo 'Initializing Vault...'",
      "  RESP=$(curl -s -X PUT http://127.0.0.1:8200/v1/sys/init -d '{\"secret_shares\": 5, \"secret_threshold\": 3}')",

      # Store keys in /DATA/AppData/.vault_keys (chmod 600) — caller should move to Keychain
      "  echo \"$RESP\" | python3 -m json.tool | sudo tee /DATA/AppData/.vault_keys > /dev/null",
      "  sudo chmod 600 /DATA/AppData/.vault_keys",

      # Unseal
      "  for i in 0 1 2; do",
      "    KEY=$(echo \"$RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['keys_base64'][$i])\")",
      "    curl -s -X PUT http://127.0.0.1:8200/v1/sys/unseal -d \"{\\\"key\\\": \\\"$KEY\\\"}\" > /dev/null",
      "  done",

      # Enable KV v2
      "  ROOT=$(echo \"$RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['root_token'])\")",
      "  curl -s -X POST http://127.0.0.1:8200/v1/sys/mounts/secret -H \"X-Vault-Token: $ROOT\" -d '{\"type\": \"kv\", \"options\": {\"version\": \"2\"}}' > /dev/null",
      "  echo 'Vault initialized. Keys at /DATA/AppData/.vault_keys — store these securely and delete the file.'",
      "else",
      "  echo 'Vault already initialized.'",
      "fi",

      "echo 'Vault is running at http://${var.server_host}:8200'"
    ]
  }
}

resource "null_resource" "vault_store_pihole_secret" {
  depends_on = [null_resource.vault_start]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",

      # Read pihole password if it exists
      "if [ ! -f /DATA/AppData/.pihole_admin_pass ]; then echo 'No Pi-hole password file found, skipping Vault secret.'; exit 0; fi",

      "PIHOLE_PASS=$(sudo cat /DATA/AppData/.pihole_admin_pass)",
      "ROOT=$(sudo cat /DATA/AppData/.vault_keys 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin)['root_token'])\" 2>/dev/null || echo '')",
      "if [ -z \"$ROOT\" ]; then echo 'No vault root token found, skipping Pi-hole secret storage.'; exit 0; fi",

      # Wait for Vault to be unsealed
      "for i in $(seq 1 10); do",
      "  SEALED=$(curl -s http://127.0.0.1:8200/v1/sys/seal-status | python3 -c \"import sys,json; print(json.load(sys.stdin)['sealed'])\" 2>/dev/null || echo 'true')",
      "  if [ \"$SEALED\" = 'False' ]; then break; fi",
      "  sleep 2",
      "done",

      "curl -s -X POST http://127.0.0.1:8200/v1/secret/data/pihole \\",
      "  -H \"X-Vault-Token: $ROOT\" \\",
      "  -d \"{\\\"data\\\": {\\\"host\\\": \\\"${var.server_host}\\\", \\\"web_ui\\\": \\\"http://${var.server_host}/admin\\\", \\\"password\\\": \\\"$PIHOLE_PASS\\\"}}\" > /dev/null",

      "echo 'Pi-hole credentials stored in Vault at secret/pihole.'"
    ]
  }
}

output "done" {
  value = null_resource.vault_store_pihole_secret.id
}

output "vault_ui" {
  value = "http://${var.server_host}:8200/ui"
}

output "vault_keys_note" {
  value = "Vault unseal keys are at /DATA/AppData/.vault_keys on the server. Move them to a password manager and delete the file."
}
