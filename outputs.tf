output "pihole_ui" {
  description = "Pi-hole admin web UI"
  value       = module.pihole_unbound.pihole_ui
}

output "vault_ui" {
  description = "Vault web UI"
  value       = module.vault.vault_ui
}

output "vault_keys_note" {
  description = "Where to find Vault unseal keys"
  value       = module.vault.vault_keys_note
}

output "dns_server" {
  description = "Set this as your LAN DNS server in your router DHCP config"
  value       = "DNS: ${var.server_host}:53"
}

output "dns_chain" {
  description = "DNS resolution chain"
  value       = "LAN → Pi-hole (${var.server_host}:53) → Unbound (:5353) → Warp tunnel → Cloudflare 1.1.1.1"
}
