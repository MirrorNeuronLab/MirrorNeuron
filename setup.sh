#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

VENV_DIR="${HOME}/.local/share/mn_venv"
BIN_DIR="${HOME}/.local/bin"
FORCE_REINSTALL=false

for arg in "$@"; do
    if [ "$arg" == "--reinstall" ]; then
        FORCE_REINSTALL=true
    fi
done

echo "=> Checking dependencies and environment..."
echo "=> Fetching Elixir dependencies..."
mix deps.get
mix compile

if [ "$FORCE_REINSTALL" = true ] && [ -d "$VENV_DIR" ]; then
    echo "=> Force reinstall requested. Removing old venv..."
    rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "=> Creating Python virtual environment in $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
fi

echo "=> Installing Python packages (SDK, CLI, API)..."
"$VENV_DIR/bin/pip" install --upgrade pip

echo "=> Installing mn-python-sdk from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-python-sdk

echo "=> Installing mn-cli from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-cli

echo "=> Installing mn-api from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-api

echo "=> Setting up mn CLI in $BIN_DIR..."
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api"

if [ -f "$VENV_DIR/bin/mn" ]; then ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"; fi
if [ -f "$VENV_DIR/bin/mn-api" ]; then ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"; fi

SHELL_RC="$HOME/.bashrc"
if [[ "$SHELL" == *"zsh"* ]]; then SHELL_RC="$HOME/.zshrc"; fi

if ! grep -q "$BIN_DIR" "$SHELL_RC" 2>/dev/null; then
    echo -e "\nexport PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_RC"
    echo "=> Added $BIN_DIR to $SHELL_RC"
fi

echo "=> Environment setup complete."
