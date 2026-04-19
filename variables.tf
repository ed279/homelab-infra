variable "server_host" {
  description = "IP or hostname of the target Ubuntu server"
  type        = string
}

variable "server_user" {
  description = "SSH user on the target server"
  type        = string
  default     = "claude"
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for connecting to the server"
  type        = string
  default     = "~/.ssh/id_ed25519_ubuntu"
}

variable "timezone" {
  description = "Timezone for all services (e.g. America/Los_Angeles)"
  type        = string
  default     = "America/Los_Angeles"
}

variable "lan_subnet" {
  description = "LAN subnet to exclude from Warp tunnel (keeps SSH and LAN access direct)"
  type        = string
  default     = "10.0.9.0/24"
}

variable "pihole_data_dir" {
  description = "Host path for Pi-hole persistent data"
  type        = string
  default     = "/DATA/AppData/pihole-unbound"
}

variable "pihole_image" {
  description = "Pi-hole + Unbound Docker image"
  type        = string
  default     = "bigbeartechworld/big-bear-pihole-unbound:2026.04.0"
}

variable "mgmt_subnet" {
  description = "Optional management/WiFi VLAN subnet that also needs SSH access (e.g. 10.0.253.0/24)"
  type        = string
  default     = ""
}

variable "netbird_subnet" {
  description = "NetBird mesh VPN subnet. Excluded from Warp tunnel, allowed through UFW. Default covers all NetBird allocations."
  type        = string
  default     = "100.64.0.0/10"
}

variable "vault_data_dir" {
  description = "Host path for Vault persistent data"
  type        = string
  default     = "/DATA/AppData/vault"
}
