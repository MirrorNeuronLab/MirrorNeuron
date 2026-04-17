#!/usr/bin/env bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

PID_DIR="${DIR}/.pids"
LOG_DIR="${DIR}/.logs"
BEAM_PID_FILE="${PID_DIR}/beam.pid"
API_PID_FILE="${PID_DIR}/api.pid"
BEAM_LOG="${LOG_DIR}/beam.log"
API_LOG="${LOG_DIR}/api.log"
VENV_DIR="${HOME}/.local/share/mn_venv"

print_ascii_art() {
    cat << "ASCIIEOF"
  __  __ _                     _   _                     
 |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ 
 | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \ 
 | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |
 |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|
                                                               
===================================================================
                  MirrorNeuron Server Manager                      
===================================================================
ASCIIEOF
}

check_status() {
    local pid_file=$1
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0 # Running
        else
            return 1 # Stale
        fi
    fi
    return 2 # Not running
}

kill_tree() {
    local parent=$1
    if kill -0 "$parent" 2>/dev/null; then
        local children=$(pgrep -P "$parent" 2>/dev/null || true)
        for child in $children; do
            kill_tree "$child"
        done
        kill -15 "$parent" 2>/dev/null || true
    fi
}

start_services() {
    print_ascii_art
    if check_status "$BEAM_PID_FILE" || check_status "$API_PID_FILE"; then
        echo "=> Error: MirrorNeuron is already running."
        echo "=> Use '$0 status' to check, or '$0 stop' to stop."
        exit 1
    fi

    mkdir -p "$PID_DIR" "$LOG_DIR"

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

    API_BIN="${VENV_DIR}/bin/mn-api"
    if [ -x "$API_BIN" ]; then
        echo "=> Starting mn-api (REST on port 4001)..."
        nohup "$API_BIN" > "$API_LOG" 2>&1 &
        API_PID=$!
        echo $API_PID > "$API_PID_FILE"
        echo "   [Started] REST API (PID: $API_PID)"
    else
        echo "=> Warning: mn-api not found, skipping. Did you run setup.sh?"
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
    
    for pid_file in "$API_PID_FILE" "$BEAM_PID_FILE"; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if [ "$pid_file" == "$API_PID_FILE" ]; then
                    echo "   Stopping REST API (PID: $pid)..."
                else
                    echo "   Stopping Core Service (PID: $pid)..."
                fi
                kill_tree "$pid"
                sleep 1
            fi
            rm -f "$pid_file"
        fi
    done
    
    echo "=> All services stopped."
}

status_services() {
    print_ascii_art
    echo "Service Status:"
    
    check_status "$BEAM_PID_FILE"
    local beam_stat=$?
    if [ $beam_stat -eq 0 ]; then
        echo "  [OK] Core Service is running (PID: $(cat "$BEAM_PID_FILE"))"
    elif [ $beam_stat -eq 1 ]; then
        echo "  [!!] Core Service PID file exists but process is dead."
        rm -f "$BEAM_PID_FILE"
    else
        echo "  [--] Core Service is not running."
    fi

    check_status "$API_PID_FILE"
    local api_stat=$?
    if [ $api_stat -eq 0 ]; then
        echo "  [OK] REST API is running (PID: $(cat "$API_PID_FILE"))"
    elif [ $api_stat -eq 1 ]; then
        echo "  [!!] REST API PID file exists but process is dead."
        rm -f "$API_PID_FILE"
    else
        echo "  [--] REST API is not running."
    fi
}

case "$1" in
    start) start_services ;;
    stop) stop_services ;;
    restart) stop_services; sleep 2; start_services ;;
    status) status_services ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
