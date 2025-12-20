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

install_pulumi() {
    echo "Installing Pulumi..."
    curl -fsSL https://get.pulumi.com | sh
    # Attempt to add to PATH for current session only if not already there
    export PATH=$PATH:$HOME/.pulumi/bin
}

install_talosctl() {
    echo "Installing Talosctl..."
    curl -fsSL https://talos.dev/install | bash
}

install_golangci_lint() {
     echo "Installing golangci-lint..."
     curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin v1.55.2
}

# 1. Check Go
if ! check_cmd go; then
    echo "Please install Go: https://go.dev/doc/install"
    exit 1
fi

# 2. Check Docker
if ! check_cmd docker; then
    echo "Please install Docker."
    exit 1
fi

# 3. Check Pulumi
if ! check_cmd pulumi; then
    install_pulumi
fi

# 4. Check Talosctl
if ! check_cmd talosctl; then
    install_talosctl
fi

# 5. Check golangci-lint
if ! check_cmd golangci-lint; then
    install_golangci_lint
fi

install_task() {
    echo "Installing Task..."
    sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
}

# 6. Check Task
if ! check_cmd task; then
    install_task
fi

echo -e "\n${GREEN}🚀 Environment ready!${NC}"
echo "You may need to restart your shell if you just installed Pulumi."
echo "Run 'source ~/.bashrc' or 'source ~/.zshrc' if paths were updated."
