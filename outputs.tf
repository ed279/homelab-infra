output "pihole_ui" {
  description = "Pi-hole admin web UI"
  value       = module.pihole_unbound.pihole_ui
}

output "vault_ui" {
  description = "Vault web UI (HTTPS with self-signed cert)"
  value       = module.vault.vault_ui
}

output "vault_keys_note" {
  description = "Vault unseal key storage"
  value       = module.vault.vault_keys_note
}

output "pihole_password_note" {
  description = "How to retrieve Pi-hole admin password"
  value       = "sudo systemd-creds decrypt /etc/pihole/admin-password.cred -"
}

output "dns_server" {
  description = "Set this as your LAN DNS server in your router DHCP config"
  value       = "DNS: ${var.server_host}:53"
}

output "dns_chain" {
  description = "DNS resolution chain (double-encrypted)"
  value       = "LAN → Pi-hole (${var.server_host}:53) → Unbound :5353 [DoT/TLS] → Warp tunnel → Cloudflare 1.1.1.1:853"
}
