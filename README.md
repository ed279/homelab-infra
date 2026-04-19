# homelab-infra

One-command Terraform deployment for a privacy-focused homelab DNS and secrets stack on bare Ubuntu. Fully ephemeral — replace the machine, run one command, back in minutes.

## Stack

```
LAN clients
    ↓ DNS queries
Pi-hole (port 53)       ← ad blocking, LAN DNS
    ↓
Unbound (port 5353)     ← recursive/forwarding resolver, DNSSEC
    ↓
Cloudflare WARP tunnel  ← encrypted egress, all outbound traffic
    ↓
Cloudflare 1.1.1.1      ← upstream DNS over secure tunnel

Vault (port 8200)       ← secrets store (Pi-hole password, API keys, etc.)
```

## Prerequisites

Install Terraform (and optionally the Vault CLI) on your local machine:

```bash
# macOS
brew install terraform vault

# Ubuntu/Debian
./prerequisites.sh
```

## Usage

### 1. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your server IP, SSH key path, timezone, etc.
```

### 2. Deploy

```bash
terraform init
terraform apply
```

That's it. The full stack is deployed. Outputs will show you:
- Pi-hole admin URL
- Vault UI URL
- DNS chain summary
- Where to find your Vault unseal keys

### 3. Point your router at the DNS server

In your router's DHCP settings, set the DNS server to your server's IP (e.g. `10.0.9.99`). All LAN clients will automatically route DNS through Pi-hole → Unbound → Warp.

## What Gets Deployed

| Component | Where | Notes |
|---|---|---|
| Docker CE | Remote server | Installed via apt |
| Cloudflare WARP | Remote server | `tunnel_only` mode, LAN excluded from tunnel |
| Pi-hole + Unbound | Remote server | Host network mode, port 53 |
| Vault | Remote server | File backend, KV v2, port 8200 |

## Modules

| Module | Purpose |
|---|---|
| `modules/docker-ce` | Installs Docker CE via apt, adds user to docker group |
| `modules/warp-cli` | Installs Warp, configures split tunnel, connects, sets up boot service |
| `modules/pihole-unbound` | Deploys Pi-hole+Unbound container, sets password, writes config |
| `modules/vault` | Deploys Vault, initializes, unseals, enables KV v2, stores Pi-hole creds |

## Security Notes

- **Vault unseal keys** are written to `/DATA/AppData/.vault_keys` on the server after first init. Move these to a password manager (macOS Keychain, 1Password, etc.) and delete the file.
- `terraform.tfvars` is gitignored — it contains your server IP and SSH key path.
- `terraform.tfstate` is gitignored — it may contain sensitive output values.
- Warp `tunnel_only` mode means Pi-hole owns DNS on port 53; all other egress is tunneled.
- The LAN subnet (`lan_subnet` variable) is excluded from the Warp tunnel so SSH and LAN services remain directly accessible.

## Replacing the Machine

On a new machine with Ubuntu installed and your SSH key authorized:

1. Update `server_host` in `terraform.tfvars`
2. `terraform apply`
3. Move Vault keys to safe storage, delete `/DATA/AppData/.vault_keys`

## Variables

| Variable | Default | Description |
|---|---|---|
| `server_host` | — | IP of target Ubuntu server |
| `server_user` | `claude` | SSH user |
| `ssh_private_key_path` | `~/.ssh/id_ed25519_ubuntu` | SSH private key |
| `timezone` | `America/Los_Angeles` | Timezone for all services |
| `lan_subnet` | `10.0.9.0/24` | LAN subnet excluded from Warp tunnel |
| `pihole_data_dir` | `/DATA/AppData/pihole-unbound` | Pi-hole persistent data |
| `pihole_image` | `bigbeartechworld/big-bear-pihole-unbound:2026.04.0` | Docker image |
| `vault_data_dir` | `/DATA/AppData/vault` | Vault persistent data |
