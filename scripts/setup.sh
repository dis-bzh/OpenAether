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

# 6. Check pre-commit (optional but recommended)
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
echo "Next steps:"
echo "  1. cd infrastructure/opentofu"
echo "  2. cp tofu.tfvars.example tofu.tfvars  # Edit with your config"
echo "  3. export AWS_ACCESS_KEY_ID=<KEY>"
echo "  4. export AWS_SECRET_ACCESS_KEY=<SECRET>"
echo "  5. export TF_VAR_encryption_passphrase=<PASSPHRASE>"
echo "  6. tofu init && tofu plan -var-file=tofu.tfvars"
