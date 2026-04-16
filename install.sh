#!/usr/bin/env bash

set -e

# MirrorNeuron Installation Script
# Supported OS: macOS, Linux, WSL

REPO_URL="https://github.com/MirrorNeuronLab/MirrorNeuron.git"
INSTALL_DIR="${HOME}/.mirror_neuron"
BIN_DIR="${HOME}/.local/bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=> Starting MirrorNeuron Installation...${NC}"

# 1. Check dependencies
if ! command -v git &> /dev/null; then
    echo -e "${RED}Error: 'git' is not installed. Please install git and try again.${NC}"
    exit 1
fi

if ! command -v mix &> /dev/null; then
    echo -e "${RED}Error: 'mix' (Elixir) is not installed.${NC}"
    echo -e "MirrorNeuron requires Erlang/Elixir to build and run."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "You can install it via Homebrew: ${YELLOW}brew install elixir${NC}"
    elif command -v apt-get &> /dev/null; then
        echo -e "You can install it via apt: ${YELLOW}sudo apt-get update && sudo apt-get install elixir erlang-dev erlang-parsetools erlang-xmerl${NC}"
    elif command -v pacman &> /dev/null; then
        echo -e "You can install it via pacman: ${YELLOW}sudo pacman -S elixir${NC}"
    else
        echo -e "Please install Elixir by following the guide: https://elixir-lang.org/install.html"
    fi
    exit 1
fi

# 2. Clone or update repo
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${BLUE}=> Directory $INSTALL_DIR already exists. Updating from git...${NC}"
    cd "$INSTALL_DIR"
    # Ensure we are on main and pull latest
    git fetch origin
    # Try to fast-forward, handle detached heads or uncommitted changes gracefully?
    # Simple pull for now
    git pull origin main || echo -e "${YELLOW}Warning: Could not pull latest changes. Proceeding with local version.${NC}"
else
    echo -e "${BLUE}=> Cloning repository into $INSTALL_DIR...${NC}"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Build escript
echo -e "${BLUE}=> Fetching mix dependencies and building...${NC}"
mix deps.get
mix escript.build

# 4. Install binaries
echo -e "${BLUE}=> Setting up symlinks in $BIN_DIR...${NC}"
mkdir -p "$BIN_DIR"

# Remove existing to prevent symlink errors
rm -f "$BIN_DIR/mirror_neuron"
rm -f "$BIN_DIR/mn"

# Link binaries
ln -s "$INSTALL_DIR/mirror_neuron" "$BIN_DIR/mirror_neuron"
ln -s "$INSTALL_DIR/mirror_neuron" "$BIN_DIR/mn"

echo -e "${GREEN}=> Installation successfully completed!${NC}"
echo -e "MirrorNeuron is available as ${YELLOW}mirror_neuron${NC} and ${YELLOW}mn${NC}."

# 5. Check PATH and advise user
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e ""
    echo -e "${YELLOW}WARNING: $BIN_DIR is not in your PATH.${NC}"
    
    # Detect shell configuration file
    SHELL_RC=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        SHELL_RC="~/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        SHELL_RC="~/.bashrc"
    else
        SHELL_RC="your shell's profile file"
    fi
    
    echo -e "To use the commands globally, please add the following line to ${SHELL_RC}:"
    echo -e "\n    ${GREEN}export PATH=\"\$PATH:$BIN_DIR\"${NC}\n"
    echo -e "Then run: ${YELLOW}source ${SHELL_RC}${NC} or restart your terminal."
else
    echo -e "\n=> You can now run '${GREEN}mn monitor${NC}' to start using MirrorNeuron!"
fi
