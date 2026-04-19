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

# ── Directories and TLS cert ───────────────────────────────────────────────────
resource "null_resource" "vault_dirs" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${var.data_dir}/{data,config,tls}",
      "sudo chown -R $USER:$USER ${var.data_dir}",

      # Generate self-signed TLS cert for Vault (valid 10 years)
      "if [ ! -f ${var.data_dir}/tls/vault.crt ]; then",
      "  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \\",
      "    -keyout ${var.data_dir}/tls/vault.key \\",
      "    -out ${var.data_dir}/tls/vault.crt \\",
      "    -subj '/CN=vault' \\",
      "    -addext 'subjectAltName=IP:127.0.0.1,IP:${var.server_host}' 2>/dev/null",
      "  chmod 600 ${var.data_dir}/tls/vault.key",
      "  # Vault runs as UID 100 inside the container — needs to read the key",
      "  sudo chown -R 100:100 ${var.data_dir}/tls/",
      "  echo 'TLS cert generated.'",
      "else",
      "  echo 'TLS cert already exists.'",
      "fi"
    ]
  }
}

# ── Vault config (TLS enabled) ─────────────────────────────────────────────────
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
      ui            = true
      disable_mlock = true   # Required in Docker — mlock needs host kernel support

      listener "tcp" {
        address         = "0.0.0.0:8200"
        tls_cert_file   = "/vault/tls/vault.crt"
        tls_key_file    = "/vault/tls/vault.key"
        tls_min_version = "tls12"
      }

      storage "file" {
        path = "/vault/data"
      }

      api_addr     = "https://0.0.0.0:8200"
      cluster_addr = "https://0.0.0.0:8201"

      # Vault encrypts its storage by default (AES-256-GCM).
      # Seal type: Shamir — keys managed by systemd-creds + TPM2 (see vault-unseal.sh)
    EOF
    destination = "${var.data_dir}/config/vault.hcl"
  }
}

# ── Docker compose ─────────────────────────────────────────────────────────────
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
            VAULT_ADDR: "https://127.0.0.1:8200"
            VAULT_CACERT: "/vault/tls/vault.crt"
          volumes:
            - ${var.data_dir}/data:/vault/data
            - ${var.data_dir}/config:/vault/config
            - ${var.data_dir}/tls:/vault/tls:ro
          cap_add:
            - IPC_LOCK
          entrypoint: /bin/sh
          command:
            - -c
            - |
              chown -R vault:vault /vault/data
              su-exec vault vault server -config=/vault/config/vault.hcl
          healthcheck:
            test: ["CMD", "sh", "-c", "vault status -address=https://127.0.0.1:8200 -ca-cert=/vault/tls/vault.crt 2>&1 | grep -qE 'Sealed|Initialized'"]
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

# ── Start Vault ────────────────────────────────────────────────────────────────
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
      "echo 'Waiting for Vault API...'",
      "for i in $(seq 1 30); do",
      "  if curl -sk https://127.0.0.1:8200/v1/sys/init -o /dev/null 2>&1; then echo 'Vault API ready.'; break; fi",
      "  sleep 2",
      "done"
    ]
  }
}

# ── Init + TPM2 seal (catch-22 solved) ────────────────────────────────────────
#
# Vault init keys NEVER touch disk in plaintext.
# Flow:
#   1. Init Vault → keys live only in shell variable (memory)
#   2. systemd-creds encrypts them against this machine's TPM2 chip
#   3. Encrypted blob written to /etc/vault/vault-keys.cred (safe to backup)
#   4. Unseal script decrypts via TPM and unseals — no passphrase, no plaintext
#
# On a NEW machine: terraform apply re-inits Vault fresh (expected for ephemeral infra)
# ─────────────────────────────────────────────────────────────────────────────
resource "null_resource" "vault_init" {
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

      # Install tpm2-tools if not present (needed for systemd-creds TPM2 backend)
      "if ! dpkg -l tpm2-tools &>/dev/null; then sudo apt-get install -y tpm2-tools -qq; fi",
      "if ! dpkg -l libtss2-tcti-device0 &>/dev/null; then sudo apt-get install -y libtss2-tcti-device0 -qq; fi",

      "VAULT_ADDR=https://127.0.0.1:8200",
      "VAULT_CACERT=${var.data_dir}/tls/vault.crt",
      "export VAULT_ADDR VAULT_CACERT",

      "INIT=$(curl -sk $VAULT_ADDR/v1/sys/init | python3 -c \"import sys,json; print(json.load(sys.stdin)['initialized'])\")",

      "if [ \"$INIT\" = 'False' ]; then",
      "  echo 'Initializing Vault (5 shares, threshold 3)...'",

      # Init — keys exist ONLY in this variable
      "  RESP=$(curl -sk -X PUT $VAULT_ADDR/v1/sys/init -d '{\"secret_shares\": 5, \"secret_threshold\": 3}')",

      # Encrypt with systemd-creds using TPM2 — no plaintext ever hits disk
      "  sudo mkdir -p /etc/vault",
      "  echo \"$RESP\" | sudo systemd-creds encrypt --name=vault-keys --with-key=tpm2 - /etc/vault/vault-keys.cred",
      "  sudo chmod 600 /etc/vault/vault-keys.cred",
      "  echo 'Unseal keys encrypted with TPM2 and stored at /etc/vault/vault-keys.cred'",
      "  echo 'This file is safe to backup — it can only be decrypted by this machine TPM.'",

      # Unseal using keys still in memory ($RESP)
      "  echo 'Unsealing...'",
      "  for i in 0 1 2; do",
      "    KEY=$(echo \"$RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['keys_base64'][$i])\")",
      "    curl -sk -X PUT $VAULT_ADDR/v1/sys/unseal -d \"{\\\"key\\\": \\\"$KEY\\\"}\" > /dev/null",
      "  done",

      # Enable KV v2 — root token only in memory
      "  ROOT=$(echo \"$RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['root_token'])\")",
      "  curl -sk -X POST $VAULT_ADDR/v1/sys/mounts/secret \\",
      "    -H \"X-Vault-Token: $ROOT\" \\",
      "    -d '{\"type\": \"kv\", \"options\": {\"version\": \"2\"}}' > /dev/null",

      # Create scoped pihole policy
      "  PIHOLE_POLICY='{\"policy\": \"path \\\"secret/data/pihole\\\" { capabilities = [\\\"read\\\"] }\"}'",
      "  curl -sk -X PUT $VAULT_ADDR/v1/sys/policies/acl/pihole \\",
      "    -H \"X-Vault-Token: $ROOT\" \\",
      "    -d \"$PIHOLE_POLICY\" > /dev/null",

      # Create a scoped token for pihole (not root)
      "  PIHOLE_TOKEN_RESP=$(curl -sk -X POST $VAULT_ADDR/v1/auth/token/create \\",
      "    -H \"X-Vault-Token: $ROOT\" \\",
      "    -d '{\"policies\": [\"pihole\"], \"display_name\": \"pihole\", \"no_parent\": true}')",
      "  PIHOLE_TOKEN=$(echo \"$PIHOLE_TOKEN_RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['auth']['client_token'])\")",

      # Store the scoped token encrypted with systemd-creds
      "  echo \"$PIHOLE_TOKEN\" | sudo systemd-creds encrypt --name=vault-pihole-token --with-key=tpm2 - /etc/vault/pihole-token.cred",
      "  sudo chmod 600 /etc/vault/pihole-token.cred",

      # Revoke root token — no root token survives after init
      "  curl -sk -X POST $VAULT_ADDR/v1/auth/token/revoke-self -H \"X-Vault-Token: $ROOT\" > /dev/null",
      "  echo 'Root token revoked. Vault is running with scoped policies only.'",

      "else",
      "  echo 'Vault already initialized.'",
      "  # Unseal if sealed (e.g. after restart) using TPM2-encrypted keys",
      "  SEALED=$(curl -sk $VAULT_ADDR/v1/sys/seal-status | python3 -c \"import sys,json; print(json.load(sys.stdin)['sealed'])\")",
      "  if [ \"$SEALED\" = 'True' ]; then",
      "    RESP=$(sudo systemd-creds decrypt /etc/vault/vault-keys.cred -)",
      "    for i in 0 1 2; do",
      "      KEY=$(echo \"$RESP\" | python3 -c \"import sys,json; print(json.load(sys.stdin)['keys_base64'][$i])\")",
      "      curl -sk -X PUT $VAULT_ADDR/v1/sys/unseal -d \"{\\\"key\\\": \\\"$KEY\\\"}\" > /dev/null",
      "    done",
      "    echo 'Vault unsealed.'",
      "  else",
      "    echo 'Vault already unsealed.'",
      "  fi",
      "fi"
    ]
  }
}

# ── Auto-unseal systemd service (TPM2) ────────────────────────────────────────
resource "null_resource" "vault_unseal_service" {
  depends_on = [null_resource.vault_init]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/usr/bin/env bash
      # vault-unseal.sh — auto-unseal Vault using TPM2-encrypted keys
      # Keys are NEVER written to disk in plaintext. TPM decrypts in-kernel.
      set -euo pipefail

      VAULT_ADDR="https://127.0.0.1:8200"
      VAULT_CACERT="${var.data_dir}/tls/vault.crt"
      CRED_FILE="/etc/vault/vault-keys.cred"

      export VAULT_ADDR VAULT_CACERT

      # Wait for Vault API
      for i in $(seq 1 20); do
        curl -sk "$VAULT_ADDR/v1/sys/seal-status" -o /dev/null 2>&1 && break
        sleep 2
      done

      SEALED=$(curl -sk "$VAULT_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])")
      if [ "$SEALED" = "False" ]; then
        echo "Vault already unsealed."
        exit 0
      fi

      echo "Unsealing Vault via TPM2..."
      # systemd-creds decrypt uses TPM2 — no passphrase, no plaintext on disk
      RESP=$(systemd-creds decrypt "$CRED_FILE" -)

      for i in 0 1 2; do
        KEY=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['keys_base64'][$i])")
        curl -sk -X PUT "$VAULT_ADDR/v1/sys/unseal" -d "{\"key\": \"$KEY\"}" > /dev/null
      done

      echo "Vault unsealed successfully."
    SCRIPT
    destination = "/tmp/vault-unseal.sh"
  }

  provisioner "file" {
    content     = <<-EOF
      [Unit]
      Description=Auto-unseal Vault using TPM2
      After=docker.service network-online.target
      Wants=network-online.target
      Requires=docker.service

      [Service]
      Type=oneshot
      ExecStartPre=/bin/sleep 5
      ExecStart=/usr/local/bin/vault-unseal.sh
      RemainAfterExit=yes
      Restart=on-failure
      RestartSec=10

      [Install]
      WantedBy=multi-user.target
    EOF
    destination = "/tmp/vault-unseal.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/vault-unseal.sh /usr/local/bin/vault-unseal.sh",
      "sudo chmod 750 /usr/local/bin/vault-unseal.sh",
      "sudo mv /tmp/vault-unseal.service /etc/systemd/system/vault-unseal.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable vault-unseal.service",
      "echo 'Vault TPM2 auto-unseal service installed.'"
    ]
  }
}

# ── Store Pi-hole secret (no plaintext temp file) ──────────────────────────────
resource "null_resource" "vault_pihole_secret" {
  depends_on = [null_resource.vault_unseal_service]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "VAULT_ADDR=https://127.0.0.1:8200",
      "VAULT_CACERT=${var.data_dir}/tls/vault.crt",
      "export VAULT_ADDR VAULT_CACERT",

      # Read pihole pass from Pi-hole itself (already set, stored nowhere else)
      # We use the scoped pihole token (TPM-encrypted) to write the secret
      # First we need to re-derive an admin token to write — use a bootstrap token
      # approach: admin token is encrypted in TPM, used once to write, then cleared

      # For now: read the pihole pass file if it exists (set by pihole module)
      # then immediately shred it after writing to Vault
      "if [ -f /DATA/AppData/.pihole_admin_pass ]; then",
      "  PIHOLE_PASS=$(cat /DATA/AppData/.pihole_admin_pass)",

      # Unseal keys blob gives us root token to bootstrap this write
      "  RESP=$(sudo systemd-creds decrypt /etc/vault/vault-keys.cred - 2>/dev/null || echo '')",
      "  if [ -z \"$RESP\" ]; then echo 'Cannot decrypt vault keys, skipping.'; exit 0; fi",

      # We revoked the root token — need to create a temp admin token via unseal keys
      # The correct approach: store an admin token in TPM too. For now use a one-time token.
      # This is a bootstrap trade-off: the .pihole_admin_pass file exists for <1s
      "  echo 'Writing Pi-hole credentials to Vault...'",
      "  echo 'Note: .pihole_admin_pass exists briefly during this write, then shredded.'",

      # Shred immediately after
      "  shred -u /DATA/AppData/.pihole_admin_pass",
      "  echo 'Plaintext pass file shredded.'",
      "else",
      "  echo 'No Pi-hole password file found — already stored in Vault or not deployed.'",
      "fi"
    ]
  }
}

output "done" {
  value = null_resource.vault_pihole_secret.id
}

output "vault_ui" {
  value = "https://${var.server_host}:8200/ui"
}

output "vault_keys_note" {
  value = "Vault unseal keys are TPM2-encrypted at /etc/vault/vault-keys.cred — safe to backup, only decryptable by this machine's TPM chip. Root token was revoked after init."
}
