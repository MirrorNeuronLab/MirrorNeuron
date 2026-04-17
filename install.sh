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
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: 'python3' is not installed.${NC}"
    exit 1
fi

# 2. Clone or update repo
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${BLUE}=> Directory $INSTALL_DIR already exists. Updating from git...${NC}"
    cd "$INSTALL_DIR"
    git fetch origin
    git pull origin main || echo -e "${YELLOW}Warning: Could not pull latest changes.${NC}"
else
    echo -e "${BLUE}=> Cloning repository into $INSTALL_DIR...${NC}"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Build Elixir Core
echo -e "${BLUE}=> Fetching mix dependencies and compiling core service...${NC}"
cd "$INSTALL_DIR/MirrorNeuron"
mix deps.get
mix compile

# 4. Setup Python Environment and Install SDK/CLI/API
echo -e "${BLUE}=> Setting up Python virtual environment...${NC}"
VENV_DIR="${HOME}/.local/share/mn_venv"
python3 -m venv "$VENV_DIR"

echo -e "${BLUE}=> Installing mn-python-sdk, mn-cli, and mn-api...${NC}"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install "$INSTALL_DIR/mn-python-sdk"
"$VENV_DIR/bin/pip" install "$INSTALL_DIR/mn-cli"
"$VENV_DIR/bin/pip" install "$INSTALL_DIR/mn-api"

# 5. Install binaries
echo -e "${BLUE}=> Setting up symlinks in $BIN_DIR...${NC}"
mkdir -p "$BIN_DIR"

rm -f "$BIN_DIR/mn"
rm -f "$BIN_DIR/mn-api"

ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"

echo -e "${GREEN}=> Installation successfully completed!${NC}"
echo -e "MirrorNeuron CLI is available as ${YELLOW}mn${NC}."
echo -e "MirrorNeuron API is available as ${YELLOW}mn-api${NC}."

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "\n${YELLOW}WARNING: $BIN_DIR is not in your PATH.${NC}"
else
    echo -e "\n=> To start the core daemon, run: ${GREEN}cd $INSTALL_DIR/MirrorNeuron && mix run --no-halt${NC}"
    echo -e "=> You can then run '${GREEN}mn nodes${NC}' to start using MirrorNeuron CLI!"
fi