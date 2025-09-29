#!/usr/bin/env bash
set -euo pipefail

# --- Cargar funciones comunes ---
source "$(dirname "$0")/ci_vars.sh"
load_ci_vars
source "$(dirname "$0")/vars.sh"
read_vars

# --- Variables de entorno ---
OUTPUT_DIR="/tmp/wattsci"
SERVER_URL="http://172.24.106.17:5000"
PID_FILE="$OUTPUT_DIR/perf.pid"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
VAR_FILE="$OUTPUT_DIR/vars.sh"
WATTSCI_OUTPUT_FILE="$OUTPUT_DIR/perf-data.txt"

# --- Argumentos ---
ACTION="${1:-}"
LABEL="${2:-}"

# --- Funciones ---
function add_var() {
    local key="$1"
    local value="$2"
    echo "${key}='${value}'" >> "$VAR_FILE"
}

function read_vars() {
    [[ -f "$VAR_FILE" ]] && source "$VAR_FILE"
}

function start_measurement() {
    # Para start_measurement necesitamos LABEL, APPROACH, METHOD y TOOL_ARGS
    APPROACH="${3:-}"
    METHOD="${4:-}"
    shift 4
    TOOL_ARGS=("$@")

    echo "[DEBUG] Starting start_measurement..." >&2

    mkdir -p "$OUTPUT_DIR"
    date "+%s%6N" >> "$TIMER_FILE_START"

    add_var 'LABEL' "$LABEL"
    add_var 'METHOD' "$METHOD"
    add_var 'APPROACH' "$APPROACH"

    if [[ "$METHOD" == "perf" ]]; then
        local perf_log="$OUTPUT_DIR/perf.log"

        # Lanzar perf.sh en background, salida a log
        nohup bash "$(dirname "$0")/perf.sh" "${TOOL_ARGS[@]}" > "$perf_log" 2>&1 &
        local pid=$!

        # Guardar PID
        echo "$pid" > "$PID_FILE"
        add_var 'PID' "$pid"

        echo "[INFO] Measurement started, PID=$pid, logging to $perf_log" >&2
    else
        echo "[ERROR] Unsupported METHOD: $METHOD" >&2
        exit 1
    fi
}

function end_measurement() {
    echo "[DEBUG] Starting end_measurement..." >&2
    read_vars

    if [[ -z "${LABEL:-}" ]]; then
        echo "[ERROR] LABEL is not set" >&2
        exit 1
    fi

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file not found: $PID_FILE" >&2
        exit 1
    fi

    local pid
    pid=$(<"$PID_FILE")
    echo "[INFO] Killing measurement PID=$pid and its children..." >&2
    pkill -P "$pid" || true
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    date "+%s%6N" >> "$TIMER_FILE_END"
    echo "[INFO] Timer end recorded at $(tail -n1 "$TIMER_FILE_END")" >&2

    echo "[INFO] end_measurement finished" >&2
}

function baseline() {
    start_measurement "$@"
    sleep 5
    end_measurement
}

function show_usage() {
    echo "Usage: $0 start_measurement|end_measurement|baseline LABEL [APPROACH METHOD ...]" >&2
    exit 1
}

# --- Acción principal ---
case "$ACTION" in
    start_measurement) start_measurement "$@" ;;
    end_measurement) end_measurement ;;
    baseline) baseline "$@" ;;
    *) show_usage ;;
esac

