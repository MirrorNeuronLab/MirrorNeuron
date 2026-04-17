#!/usr/bin/env bash
set -e

# MirrorNeuron Server Management Script

# Get current directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

PID_DIR="${DIR}/.pids"
BEAM_PID_FILE="${PID_DIR}/beam.pid"
API_PID_FILE="${PID_DIR}/api.pid"
LOG_DIR="${DIR}/.logs"
BEAM_LOG="${LOG_DIR}/beam.log"
API_LOG="${LOG_DIR}/api.log"

mkdir -p "$PID_DIR"
mkdir -p "$LOG_DIR"

print_ascii_art() {
    cat << "EOF"
  __  __ _                     _   _                     
 |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ 
 | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \ 
 | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |
 |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|
                                                               
===================================================================
                  MirrorNeuron Server Manager                      
===================================================================
EOF
}

print_help() {
    print_ascii_art
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  start     Start the MirrorNeuron services in detached mode"
    echo "  stop      Stop the running MirrorNeuron services"
    echo "  restart   Stop and then start the services"
    echo "  status    Check the status of the services"
    echo "  setup     Run only the setup (install deps, CLI, PATH)"
    echo "  --help    Show this help message"
    echo ""
}

setup_env() {
    echo "=> Checking dependencies and environment..."
    
    # 1. Download and install Elixir dependencies from Hex/GitHub
    echo "=> Fetching Elixir dependencies..."
    mix deps.get
    mix compile

    # 2. Setup Python environment and install Python dependencies
    VENV_DIR="${HOME}/.local/share/mn_venv"
    if [ ! -d "$VENV_DIR" ]; then
        echo "=> Creating Python virtual environment in $VENV_DIR..."
        python3 -m venv "$VENV_DIR"
    fi

    echo "=> Installing Python packages (SDK, CLI, API)..."
    "$VENV_DIR/bin/pip" install --upgrade pip

    # Install sibling python packages or from github if not available locally
    if [ -d "../mn-python-sdk" ]; then
        "$VENV_DIR/bin/pip" install -e ../mn-python-sdk
    else
        echo "=> Sibling mn-python-sdk not found. Downloading from GitHub..."
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-python-sdk.git || echo "=> Failed to install mn-python-sdk from github"
    fi

    if [ -d "../mn-cli" ]; then
        "$VENV_DIR/bin/pip" install -e ../mn-cli
    else
        echo "=> Sibling mn-cli not found. Downloading from GitHub..."
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-cli.git || echo "=> Failed to install mn-cli from github"
    fi

    if [ -d "../mn-api" ]; then
        "$VENV_DIR/bin/pip" install -e ../mn-api
    else
        echo "=> Sibling mn-api not found. Downloading from GitHub..."
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-api.git || echo "=> Failed to install mn-api from github"
    fi

    # 3. Add 'mn' to PATH
    BIN_DIR="${HOME}/.local/bin"
    echo "=> Setting up mn CLI in $BIN_DIR..."
    mkdir -p "$BIN_DIR"
    rm -f "$BIN_DIR/mn"
    rm -f "$BIN_DIR/mn-api"

    if [ -f "$VENV_DIR/bin/mn" ]; then
        ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
    fi
    if [ -f "$VENV_DIR/bin/mn-api" ]; then
        ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
    fi

    # Add to PATH permanently for current user
    SHELL_RC="$HOME/.bashrc"
    if [[ "$SHELL" == *"zsh"* ]]; then
        SHELL_RC="$HOME/.zshrc"
    fi

    if ! grep -q "$BIN_DIR" "$SHELL_RC" 2>/dev/null; then
        echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_RC"
        echo "=> Added $BIN_DIR to $SHELL_RC"
    fi

    # Add to current session PATH
    export PATH="$PATH:$BIN_DIR"
    echo "=> Environment setup complete."
}

check_status() {
    local service=$1
    local pid_file=$2
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0 # Running
        else
            return 1 # Not running but PID file exists (stale)
        fi
    else
        return 2 # Not running
    fi
}

start_services() {
    print_ascii_art
    
    # Check if already running
    if check_status "BEAM" "$BEAM_PID_FILE" || check_status "API" "$API_PID_FILE"; then
        echo "=> Error: MirrorNeuron is already running."
        echo "=> Use '$0 status' to check, or '$0 stop' to stop."
        exit 1
    fi

    setup_env

    echo "==========================================="
    echo "Starting Services in Detached Mode..."
    echo "==========================================="

    echo "=> Starting MirrorNeuron Core Service (gRPC on port 50051)..."
    nohup mix run --no-halt > "$BEAM_LOG" 2>&1 &
    BEAM_PID=$!
    echo $BEAM_PID > "$BEAM_PID_FILE"
    echo "   [Started] Core Service (PID: $BEAM_PID)"

    echo "=> Waiting for Elixir to boot..."
    sleep 3

    VENV_DIR="${HOME}/.local/share/mn_venv"
    if [ -f "$VENV_DIR/bin/mn-api" ]; then
        echo "=> Starting mn-api (REST on port 4001)..."
        nohup "$VENV_DIR/bin/mn-api" > "$API_LOG" 2>&1 &
        API_PID=$!
        echo $API_PID > "$API_PID_FILE"
        echo "   [Started] REST API (PID: $API_PID)"
    else
        echo "=> Warning: mn-api not found, skipping."
    fi

    echo ""
    echo "==========================================="
    echo "MirrorNeuron is running in the background!"
    echo "Logs are available at:"
    echo "  Core: $BEAM_LOG"
    echo "  API:  $API_LOG"
    echo ""
    echo "Run 'mn' anywhere in your terminal to use the CLI."
    echo "Run '$0 stop' to shut down the services."
    echo "==========================================="
}

stop_services() {
    echo "=> Stopping MirrorNeuron Services..."
    
    if [ -f "$API_PID_FILE" ]; then
        API_PID=$(cat "$API_PID_FILE")
        if kill -0 "$API_PID" 2>/dev/null; then
            echo "   Stopping REST API (PID: $API_PID)..."
            kill "$API_PID"
            sleep 1
        fi
        rm -f "$API_PID_FILE"
    fi

    if [ -f "$BEAM_PID_FILE" ]; then
        BEAM_PID=$(cat "$BEAM_PID_FILE")
        if kill -0 "$BEAM_PID" 2>/dev/null; then
            echo "   Stopping Core Service (PID: $BEAM_PID)..."
            kill "$BEAM_PID"
            sleep 1
        fi
        rm -f "$BEAM_PID_FILE"
    fi
    
    echo "=> All services stopped."
}

status_services() {
    print_ascii_art
    echo "Service Status:"
    
    if check_status "BEAM" "$BEAM_PID_FILE"; then
        echo "  [OK] Core Service is running (PID: $(cat "$BEAM_PID_FILE"))"
    elif [ $? -eq 1 ]; then
        echo "  [!!] Core Service PID file exists but process is dead."
        rm -f "$BEAM_PID_FILE"
    else
        echo "  [--] Core Service is not running."
    fi

    if check_status "API" "$API_PID_FILE"; then
        echo "  [OK] REST API is running (PID: $(cat "$API_PID_FILE"))"
    elif [ $? -eq 1 ]; then
        echo "  [!!] REST API PID file exists but process is dead."
        rm -f "$API_PID_FILE"
    else
        echo "  [--] REST API is not running."
    fi
}

case "$1" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2
        start_services
        ;;
    status)
        status_services
        ;;
    setup)
        setup_env
        ;;
    --help|-h|"")
        print_help
        ;;
    *)
        echo "Unknown command: $1"
        print_help
        exit 1
        ;;
esac