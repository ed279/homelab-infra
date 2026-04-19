#!/usr/bin/env bash
set -euo pipefail

# Install prerequisites for running homelab-infra Terraform stack.
# Works on macOS (brew) and Ubuntu/Debian (apt).

OS="$(uname -s)"

install_mac() {
  if ! command -v brew &>/dev/null; then
    echo "Homebrew not found. Install it from https://brew.sh first."
    exit 1
  fi
  echo "Installing prerequisites via Homebrew..."
  brew install terraform vault
  echo "Done."
}

install_linux() {
  echo "Installing prerequisites via apt..."
  sudo apt-get update -qq

  # Terraform
  if ! command -v terraform &>/dev/null; then
    sudo apt-get install -y gnupg software-properties-common curl
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update -qq && sudo apt-get install -y terraform
  fi

  # Vault CLI
  if ! command -v vault &>/dev/null; then
    sudo apt-get install -y vault
  fi

  echo "Done."
}

case "$OS" in
  Darwin) install_mac ;;
  Linux)  install_linux ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

echo ""
echo "All prerequisites installed. Next steps:"
echo "  1. Copy terraform.tfvars.example to terraform.tfvars and fill in your values"
echo "  2. terraform init"
echo "  3. terraform apply"
