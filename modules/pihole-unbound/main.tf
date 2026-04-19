terraform {
  required_providers {
    null = { source = "hashicorp/null" }
  }
}

variable "server_host"          { type = string }
variable "server_user"          { type = string }
variable "ssh_private_key_path" { type = string }
variable "data_dir"             { type = string }
variable "image"                { type = string }
variable "timezone"             { type = string }
variable "depends_on_id"        { type = string; default = "" }

locals {
  etc_dir     = "${var.data_dir}/etc"
  dnsmasq_dir = "${var.data_dir}/dnsmasq.d"
}

resource "null_resource" "pihole_dirs" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${local.etc_dir} ${local.dnsmasq_dir}",
      "sudo chown -R $USER:$USER ${var.data_dir}",
    ]
  }
}

resource "null_resource" "unbound_config" {
  depends_on = [null_resource.pihole_dirs]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  # Write Unbound config into dnsmasq.d so it persists across container recreates
  provisioner "file" {
    content     = <<-EOF
      server:
          interface: 0.0.0.0@5353
          do-ip4: yes
          do-ip6: no
          auto-trust-anchor-file: "/var/lib/unbound/root.key"
          access-control: 0.0.0.0/0 allow
          access-control: 127.0.0.1 allow
          cache-min-ttl: 300
          cache-max-ttl: 86400
          root-hints: "/var/lib/unbound/root.hints"
          hide-identity: yes
          hide-version: yes
          harden-glue: yes
          harden-dnssec-stripped: yes
          harden-referral-path: yes
          prefetch: yes
          num-threads: 1
          so-rcvbuf: 1m
          private-address: 192.168.0.0/16
          private-address: 169.254.0.0/16
          private-address: 172.16.0.0/12
          private-address: 10.0.0.0/8
          private-address: fd00::/8
          private-address: fe80::/10

      # Forward all queries through Warp tunnel to Cloudflare
      forward-zone:
          name: "."
          forward-addr: 1.1.1.1
          forward-addr: 1.0.0.1
    EOF
    destination = "${local.dnsmasq_dir}/unbound.conf.bak"
  }
}

resource "null_resource" "pihole_compose" {
  depends_on = [null_resource.unbound_config]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "file" {
    content     = <<-EOF
      name: pihole-unbound
      services:
        pihole:
          image: ${var.image}
          container_name: pihole-unbound
          network_mode: host
          restart: unless-stopped
          environment:
            FTLCONF_dns_upstreams: "127.0.0.1#5353"
            FTLCONF_dns_listeningMode: "ALL"
            TZ: "${var.timezone}"
          volumes:
            - type: bind
              source: ${local.etc_dir}
              target: /etc/pihole
            - type: bind
              source: ${local.dnsmasq_dir}
              target: /etc/dnsmasq.d
          cap_add:
            - NET_ADMIN
            - SYS_NICE
          healthcheck:
            test: ["CMD", "pihole", "status"]
            interval: 15s
            timeout: 5s
            retries: 5
            start_period: 20s
    EOF
    destination = "/tmp/pihole-compose.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /opt/pihole-unbound",
      "sudo mv /tmp/pihole-compose.yml /opt/pihole-unbound/docker-compose.yml",
      "echo 'Compose file deployed.'"
    ]
  }
}

resource "null_resource" "pihole_start" {
  depends_on = [null_resource.pihole_compose]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "cd /opt/pihole-unbound",

      # Stop existing container if any
      "docker compose down 2>/dev/null || true",

      # Pull latest image
      "docker compose pull",

      # Start
      "docker compose up -d",

      # Wait for healthy
      "echo 'Waiting for Pi-hole to become healthy...'",
      "for i in $(seq 1 30); do",
      "  STATUS=$(docker inspect pihole-unbound --format '{{.State.Health.Status}}' 2>/dev/null || echo 'starting')",
      "  if [ \"$STATUS\" = 'healthy' ]; then echo 'Pi-hole is healthy.'; break; fi",
      "  if [ \"$i\" = '30' ]; then echo 'ERROR: Pi-hole did not become healthy in time.'; exit 1; fi",
      "  sleep 5",
      "done",

      # Fix Unbound config inside container (copy our config over the image default)
      "docker exec pihole-unbound sh -c 'if [ -f /etc/unbound/unbound.conf ]; then",
      "  grep -q \"forward-zone\" /etc/unbound/unbound.conf || cat >> /etc/unbound/unbound.conf << UNBOUNDEOF",
      "forward-zone:",
      "    name: \".\"",
      "    forward-addr: 1.1.1.1",
      "    forward-addr: 1.0.0.1",
      "UNBOUNDEOF",
      "  kill -HUP \\$(pgrep unbound) 2>/dev/null || true",
      "fi'",

      "echo 'Pi-hole + Unbound stack is running.'"
    ]
  }
}

resource "null_resource" "pihole_password" {
  depends_on = [null_resource.pihole_start]

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "NEW_PASS=$(openssl rand -base64 16)",
      "docker exec pihole-unbound pihole setpassword \"$NEW_PASS\"",
      # Write to a temp file on the server so Terraform output can capture it
      "echo $NEW_PASS | sudo tee /DATA/AppData/.pihole_admin_pass > /dev/null",
      "sudo chmod 600 /DATA/AppData/.pihole_admin_pass",
      "echo 'Pi-hole password set and saved to /DATA/AppData/.pihole_admin_pass'"
    ]
  }
}

output "done" {
  value = null_resource.pihole_password.id
}

output "pihole_ui" {
  value = "http://${var.server_host}/admin"
}
