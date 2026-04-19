terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }
variable "lan_subnet"           { type = string }
variable "netbird_subnet"       { type = string; default = "100.64.0.0/10" }
variable "depends_on_id"        { type = string; default = "" }

resource "null_resource" "warp_install" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "if command -v warp-cli &>/dev/null; then echo 'Warp CLI already installed, skipping install.'; exit 0; fi",
      "curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg",
      "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list",
      "sudo apt-get update -qq",
      "sudo apt-get install -y cloudflare-warp",
      "sudo systemctl enable warp-svc",
      "sudo systemctl start warp-svc",
      "sleep 3",
      "echo 'Warp CLI installed.'"
    ]
  }
}

resource "null_resource" "warp_configure" {
  depends_on = [null_resource.warp_install]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",

      # Register if not already registered
      "STATUS=$(warp-cli --accept-tos status 2>&1 || true)",
      "if echo \"$STATUS\" | grep -q 'Registration Missing'; then",
      "  warp-cli --accept-tos registration new",
      "  sleep 2",
      "fi",

      # Set tunnel_only mode (no DNS proxy — Pi-hole owns port 53)
      "warp-cli --accept-tos mode tunnel_only",

      # Add LAN, private ranges, and NetBird mesh to split tunnel excludes
      # so SSH, local traffic, and mesh VPN traffic bypass the Warp tunnel
      "warp-cli --accept-tos tunnel ip add-range ${var.lan_subnet} 2>/dev/null || true",
      "warp-cli --accept-tos tunnel ip add-range 127.0.0.0/8 2>/dev/null || true",
      "warp-cli --accept-tos tunnel ip add-range 192.168.0.0/16 2>/dev/null || true",
      "warp-cli --accept-tos tunnel ip add-range 172.16.0.0/12 2>/dev/null || true",
      "warp-cli --accept-tos tunnel ip add-range ${var.netbird_subnet} 2>/dev/null || true",

      # Connect
      "warp-cli --accept-tos connect",
      "sleep 3",

      # Verify
      "WARP_STATUS=$(warp-cli --accept-tos status 2>&1)",
      "echo \"Warp status: $WARP_STATUS\"",
      "if ! echo \"$WARP_STATUS\" | grep -q 'Connected'; then echo 'ERROR: Warp failed to connect'; exit 1; fi",

      "echo 'Warp configured and connected.'"
    ]
  }
}

resource "null_resource" "warp_boot_service" {
  depends_on = [null_resource.warp_configure]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-EOF
      [Unit]
      Description=Connect Cloudflare WARP tunnel
      After=warp-svc.service network-online.target
      Wants=network-online.target
      Requires=warp-svc.service

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/warp-cli --accept-tos connect
      RemainAfterExit=yes
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    EOF
    destination = "/tmp/warp-connect.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/warp-connect.service /etc/systemd/system/warp-connect.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable warp-connect.service",
      "echo 'Warp boot service installed.'"
    ]
  }
}

output "done" {
  value = null_resource.warp_boot_service.id
}
