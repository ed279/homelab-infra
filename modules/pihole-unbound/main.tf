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
  etc_dir      = "${var.data_dir}/etc"
  dnsmasq_dir  = "${var.data_dir}/dnsmasq.d"
  unbound_dir  = "${var.data_dir}/unbound"
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
      "sudo mkdir -p ${local.etc_dir} ${local.dnsmasq_dir} ${local.unbound_dir}",
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

  # Write Unbound config to host-mounted path — persists across container recreates.
  # tls-cert-bundle is required for hostname pinning (#cloudflare-dns.com) to work.
  provisioner "file" {
    content     = <<-EOF
      server:
          interface: 0.0.0.0@5353
          do-ip4: yes
          do-ip6: no
          auto-trust-anchor-file: "/var/lib/unbound/root.key"
          tls-cert-bundle: "/etc/ssl/certs/ca-certificates.crt"
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
          harden-below-nxdomain: yes
          harden-short-bufsize: yes
          harden-large-queries: yes
          use-caps-for-id: yes
          prefetch: yes
          prefetch-key: yes
          num-threads: 1
          so-rcvbuf: 1m
          private-address: 192.168.0.0/16
          private-address: 169.254.0.0/16
          private-address: 172.16.0.0/12
          private-address: 10.0.0.0/8
          private-address: fd00::/8
          private-address: fe80::/10

      # DNS-over-TLS to Cloudflare — double-encrypted (Warp tunnel + DoT)
      forward-zone:
          name: "."
          forward-tls-upstream: yes
          forward-addr: 1.1.1.1@853#cloudflare-dns.com
          forward-addr: 1.0.0.1@853#cloudflare-dns.com
    EOF
    destination = "/tmp/unbound.conf"
  }

  provisioner "remote-exec" {
    inline = ["mv /tmp/unbound.conf ${local.unbound_dir}/unbound.conf"]
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
            - type: bind
              source: ${local.unbound_dir}/unbound.conf
              target: /etc/unbound/unbound.conf
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
      # Generate password in memory — never written to disk
      "NEW_PASS=$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 24)",
      "docker exec pihole-unbound pihole setpassword \"$NEW_PASS\"",
      # Encrypt and store with systemd-creds/TPM2 — no plaintext on disk
      "sudo mkdir -p /etc/pihole",
      "echo -n \"$NEW_PASS\" | sudo systemd-creds encrypt --name=pihole-password --with-key=tpm2 - /etc/pihole/admin-password.cred",
      "sudo chmod 600 /etc/pihole/admin-password.cred",
      "echo 'Pi-hole password set and TPM2-encrypted at /etc/pihole/admin-password.cred'",
      "echo 'Retrieve with: sudo systemd-creds decrypt /etc/pihole/admin-password.cred -'"
    ]
  }
}

output "done" {
  value = null_resource.pihole_password.id
}

output "pihole_ui" {
  value = "http://${var.server_host}/admin"
}
