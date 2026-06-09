#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🌐 Checking OpenAether Development Environment...${NC}"

# Helper to check command existence
check_cmd() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}✖ $1 is missing${NC}"
        return 1
    else
        VERSION=$("$1" version 2>/dev/null || "$1" --version 2>/dev/null || echo "detected")
        echo -e "${GREEN}✔ $1 is installed${NC} ($VERSION)"
        return 0
    fi
}

install_tofu() {
    echo "Installing OpenTofu..."
    if command -v snap &> /dev/null; then
        sudo snap install --classic opentofu
    elif command -v brew &> /dev/null; then
        brew install opentofu
    else
        # Official install script
        curl -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
        chmod +x install-opentofu.sh
        ./install-opentofu.sh --install-method standalone
        rm -f install-opentofu.sh
    fi
}

install_talosctl() {
    echo "Installing Talosctl..."
    curl -fsSL https://talos.dev/install | bash
}

install_kubectl() {
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    if [ -w /usr/local/bin ]; then
        mv kubectl /usr/local/bin/
    elif command -v sudo &> /dev/null; then
        sudo mv kubectl /usr/local/bin/
    else
        mkdir -p ~/.local/bin
        mv kubectl ~/.local/bin/
        echo "NOTE: kubectl installed to ~/.local/bin. Ensure it's in your PATH."
    fi
}

install_yamllint() {
    echo "Installing yamllint..."
    if command -v pip3 &> /dev/null; then
        pip3 install --user yamllint
    elif command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y yamllint
    else
        echo "⚠️  Could not install yamllint automatically. Please install it manually."
    fi
}

install_task() {
    echo "Installing Task..."
    if [ -w /usr/local/bin ]; then
        sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
    elif command -v sudo &> /dev/null; then
        sudo sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
    else
        mkdir -p ~/.local/bin
        sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin
        echo "NOTE: task installed to ~/.local/bin. Ensure it's in your PATH."
    fi
}

install_awscli_bundle() {
    echo "Installing AWS CLI v2 from the official bundle..."
    command -v unzip &> /dev/null || sudo apt-get install -y unzip
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp/aws.zip"
    (cd "$tmp" && unzip -q aws.zip && sudo ./aws/install --update)
    rm -rf "$tmp"
}

install_image_tools() {
    echo "Installing Talos image + backup tools (zstd, qemu-img, gpg, jq, aws)..."

    # zstd + qemu-img (image build), gpg (client-side backup encryption) and jq
    # (backup-state.sh) — installed separately so a missing aws package never
    # blocks them (Ubuntu 24.04 dropped awscli from apt).
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y zstd qemu-utils gnupg jq
    elif command -v brew &> /dev/null; then
        brew install zstd qemu gnupg jq
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y zstd qemu-img gnupg2 jq
    else
        echo "⚠️  Could not auto-install zstd/qemu-img/gpg/jq. Install them manually."
    fi

    # AWS CLI — not in every distro's repos; try brew, then snap, then the
    # official v2 bundle (used to upload the image to Object Storage).
    if ! command -v aws &> /dev/null; then
        if command -v brew &> /dev/null; then
            brew install awscli
        elif command -v snap &> /dev/null; then
            sudo snap install aws-cli --classic 2>/dev/null || install_awscli_bundle
        else
            install_awscli_bundle
        fi
    fi
}

install_flux() {
    local FLUX_VERSION="2.4.0"
    local ARCH="linux_amd64"
    echo "Installing Flux CLI v${FLUX_VERSION}..."
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${ARCH}.tar.gz" -o "$tmp/flux.tar.gz"
    tar -xzf "$tmp/flux.tar.gz" -C "$tmp"
    if [ -w /usr/local/bin ]; then
        install -m 755 "$tmp/flux" /usr/local/bin/flux
    elif command -v sudo &> /dev/null; then
        sudo install -m 755 "$tmp/flux" /usr/local/bin/flux
    else
        mkdir -p ~/.local/bin
        install -m 755 "$tmp/flux" ~/.local/bin/flux
        echo "NOTE: flux installed to ~/.local/bin. Ensure it's in your PATH."
    fi
    rm -rf "$tmp"
}

install_precommit() {
    echo "Installing pre-commit..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y pre-commit
    elif command -v brew &> /dev/null; then
        brew install pre-commit
    elif command -v pip3 &> /dev/null; then
        pip3 install --user pre-commit
        export PATH=$PATH:$HOME/.local/bin
    else
        echo "⚠️  Could not install pre-commit automatically. Please install 'pip3' or 'brew' first."
        return 1
    fi
}

# 1. Check OpenTofu
if ! check_cmd tofu; then
    install_tofu
fi

# 2. Check talosctl
if ! check_cmd talosctl; then
    install_talosctl
fi

# 3. Check kubectl
if ! check_cmd kubectl; then
    install_kubectl
fi

# 4. Check yamllint
if ! check_cmd yamllint; then
    install_yamllint
fi

# 5. Check Task
if ! check_cmd task; then
    install_task
fi

# 6. Check Talos image + backup tools (used by `task talos-image` and the S3 backups)
MISSING_IMG_TOOLS=0
for t in curl zstd qemu-img aws gpg jq; do
    check_cmd "$t" || MISSING_IMG_TOOLS=1
done
if [ "$MISSING_IMG_TOOLS" -eq 1 ]; then
    install_image_tools
fi

# 7. Check Flux CLI
if ! check_cmd flux; then
    install_flux
fi

# 8. Check pre-commit (optional but recommended)
if ! check_cmd pre-commit; then
    echo -e "${RED}⚠ pre-commit is not installed (recommended for DevSecOps)${NC}"
    read -p "Install pre-commit? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_precommit
        echo "Run 'pre-commit install' in the repo root to activate hooks."
    fi
fi

echo -e "\n${GREEN}🚀 Environment ready!${NC}"
echo ""
echo "Next steps (one env file == one cluster):"
echo "  1. export SCW_ACCESS_KEY / SCW_SECRET_KEY / SCW_DEFAULT_PROJECT_ID"
echo "  2. export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (= your Scaleway keys, for S3)"
echo "     (prod cross-provider backup: also export BACKUP_AWS_ACCESS_KEY_ID / BACKUP_AWS_SECRET_ACCESS_KEY)"
echo "  3. export TF_VAR_encryption_passphrase=<32+ chars>   # encrypts tfstate AND the backups"
echo "  4. Build the Talos image once:  task talos-image PROVIDER=scaleway   (or ovh or outscale)"
echo "  5. cd infrastructure/opentofu"
echo "  6. cp envs/management-scaleway.tfvars.example envs/management-scaleway.tfvars  # then edit"
echo "  7. tofu init -reconfigure \$(../../../scripts/tf-backend.sh envs/management-scaleway.tfvars) && tofu plan -var-file=envs/management-scaleway.tfvars"
