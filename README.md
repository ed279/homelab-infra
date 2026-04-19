# homelab-infra

One-command Terraform deployment for a privacy-first, security-hardened homelab stack. Replace the machine, run one command, back in minutes. No plaintext secrets anywhere.

## Architecture

```
LAN clients
    │
    ▼ DNS (port 53)
┌─────────────────────────────────┐
│  Pi-hole  ← ad/tracker blocking │
└──────────────┬──────────────────┘
               │
               ▼ port 5353
┌──────────────────────────────────────────────┐
│  Unbound  ← DNSSEC validation, hardening     │
│            DNS-over-TLS to Cloudflare :853   │ ← encrypted DNS (layer 1)
└──────────────┬───────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  Cloudflare WARP  ← tunnel_only mode        │ ← encrypted tunnel (layer 2)
│  All egress encrypted. LAN traffic direct.  │
└──────────────┬──────────────────────────────┘
               │
               ▼
         Cloudflare 1.1.1.1

┌────────────────────────────────────────────┐
│  HashiCorp Vault  ← TLS enabled            │
│  Encrypted at rest (AES-256-GCM default)   │
│  Auto-unseal via TPM2 (no plaintext keys)  │
│  Root token revoked after init             │
└────────────────────────────────────────────┘
```

## Security Design

### The Vault Catch-22 — Solved with TPM2

Normally: Vault unseal keys must be stored somewhere, creating a plaintext secret that needs securing.

**This stack uses `systemd-creds` with TPM2:**
- Vault init → unseal keys exist only in memory
- `systemd-creds encrypt --with-key=tpm2` encrypts them against this machine's TPM chip (in-kernel, never in userspace plaintext)
- Encrypted blob written to `/etc/vault/vault-keys.cred`
- On boot: `systemd-creds decrypt` uses TPM to unseal — no passphrase, no plaintext
- **The encrypted blob is machine-specific.** Safe to backup. Useless on any other hardware.
- Root token is revoked immediately after init — scoped tokens only

### Encryption Coverage

| Layer | Mechanism | What it protects |
|---|---|---|
| DNS transport (layer 1) | DNS-over-TLS (Unbound → Cloudflare :853) | DNS queries even if Warp is bypassed |
| DNS transport (layer 2) | Cloudflare WARP tunnel | All egress including DNS |
| Vault API | TLS 1.2+ with self-signed cert | All Vault API calls |
| Vault storage | AES-256-GCM (built-in) | Secrets at rest on disk |
| Unseal keys | systemd-creds + TPM2 | Init keys, admin tokens |
| Pi-hole password | systemd-creds + TPM2 | Admin credentials |
| SSH | Ed25519 key auth only | No password auth |

### What Never Touches Disk in Plaintext

- Vault unseal keys (TPM2-encrypted immediately)
- Vault root token (revoked in-memory, never stored)
- Pi-hole admin password (TPM2-encrypted immediately)
- Any other generated secrets

## Prerequisites

```bash
# macOS
brew install terraform

# Ubuntu/Debian
./prerequisites.sh
```

## Usage

### 1. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: server IP, SSH key path, timezone, LAN subnet
```

### 2. Deploy

```bash
terraform init
terraform apply
```

That's it. All modules run in order:
1. Docker CE installed
2. SSH hardened (key-only, no root, no passwords)
3. UFW firewall enabled (LAN-only access to services)
4. Cloudflare WARP configured (tunnel_only, LAN excluded)
5. Pi-hole + Unbound deployed (DoT to Cloudflare)
6. Vault deployed (TLS, TPM2 auto-unseal, scoped tokens, root revoked)

### 3. Retrieve credentials (no plaintext files)

```bash
# Pi-hole admin password
sudo systemd-creds decrypt /etc/pihole/admin-password.cred -

# Vault unseal keys (for emergency/migration only)
sudo systemd-creds decrypt /etc/vault/vault-keys.cred - | python3 -m json.tool
```

### 4. Point your router at the DNS server

Set DHCP DNS option to `<server_host>`. All LAN clients route through the full chain.

## Replacing the Machine

On a new Ubuntu machine with your SSH key authorized:

```bash
# Update terraform.tfvars with new IP
terraform apply
```

Vault is re-initialized fresh on the new machine (TPM changes with hardware — expected behavior for ephemeral infra). Vault secrets from the old machine should be backed up via `vault kv export` before decommission.

## Modules

| Module | What it does |
|---|---|
| `docker-ce` | Installs Docker CE via official apt repo |
| `ssh-hardening` | Disables password auth, root login; key-only |
| `firewall` | UFW: LAN-only on all service ports, deny everything else |
| `warp-cli` | Installs Warp, `tunnel_only` mode, split tunnel for LAN, boot service |
| `pihole-unbound` | Deploys Pi-hole+Unbound, DoT config, TPM2-encrypted password |
| `vault` | TLS-enabled Vault, TPM2 auto-unseal, scoped policies, root revoked |

## Variables

| Variable | Default | Description |
|---|---|---|
| `server_host` | — | IP of target Ubuntu server |
| `server_user` | `claude` | SSH user (must have passwordless sudo) |
| `ssh_private_key_path` | `~/.ssh/id_ed25519_ubuntu` | SSH private key |
| `timezone` | `America/Los_Angeles` | Timezone for all services |
| `lan_subnet` | `10.0.9.0/24` | LAN subnet (excluded from Warp, allowed through firewall) |
| `pihole_data_dir` | `/DATA/AppData/pihole-unbound` | Pi-hole persistent data |
| `pihole_image` | `bigbeartechworld/big-bear-pihole-unbound:2026.04.0` | Docker image |
| `vault_data_dir` | `/DATA/AppData/vault` | Vault persistent data |

## Security Notes

- `terraform.tfvars` and `*.tfstate` are gitignored — they contain your server address
- Vault TLS uses a self-signed cert scoped to the server IP — add it to your trust store or use `-tls-skip-verify` for CLI access
- The UFW firewall restricts Vault (8200) to LAN only — do not expose to internet
- Warp `tunnel_only` mode means Warp does not intercept DNS — Pi-hole owns port 53
- The `/etc/vault/vault-keys.cred` file is safe to include in encrypted backups — it cannot be decrypted without the original TPM chip
