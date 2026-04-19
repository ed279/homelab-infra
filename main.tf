terraform {
  required_version = ">= 1.5"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# ── Bootstrap: ensure target user exists with sudo + docker rights ─────────────
resource "null_resource" "bootstrap" {
  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.server_user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'Connected to $(hostname) as $(whoami)'",
      # Ensure sudo is available and passwordless for this run
      "sudo true",
    ]
  }
}

# ── Module: Docker CE ──────────────────────────────────────────────────────────
module "docker_ce" {
  source               = "./modules/docker-ce"
  server_host          = var.server_host
  server_user          = var.server_user
  ssh_private_key_path = var.ssh_private_key_path

  depends_on = [null_resource.bootstrap]
}

# ── Module: Cloudflare WARP CLI ────────────────────────────────────────────────
module "warp_cli" {
  source               = "./modules/warp-cli"
  server_host          = var.server_host
  server_user          = var.server_user
  ssh_private_key_path = var.ssh_private_key_path
  lan_subnet           = var.lan_subnet
  depends_on_id        = module.docker_ce.done

  depends_on = [module.docker_ce]
}

# ── Module: Pi-hole + Unbound ──────────────────────────────────────────────────
module "pihole_unbound" {
  source               = "./modules/pihole-unbound"
  server_host          = var.server_host
  server_user          = var.server_user
  ssh_private_key_path = var.ssh_private_key_path
  data_dir             = var.pihole_data_dir
  image                = var.pihole_image
  timezone             = var.timezone
  depends_on_id        = module.warp_cli.done

  # Pi-hole must come after Docker and Warp (Warp tunnel routes DNS queries out)
  depends_on = [module.docker_ce, module.warp_cli]
}

# ── Module: Vault ──────────────────────────────────────────────────────────────
module "vault" {
  source               = "./modules/vault"
  server_host          = var.server_host
  server_user          = var.server_user
  ssh_private_key_path = var.ssh_private_key_path
  data_dir             = var.vault_data_dir
  depends_on_id        = module.pihole_unbound.done

  depends_on = [module.docker_ce, module.pihole_unbound]
}
