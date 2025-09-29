#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/ci_vars.sh"
load_ci_vars
source "$(dirname "$0")/vars.sh"
read_vars

OUTPUT_DIR="/tmp/wattsci"
SERVER_URL="http://172.24.106.17:5000"
PID_FILE="$OUTPUT_DIR/perf.pid"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
VAR_FILE="$OUTPUT_DIR/vars.sh"
PERF_OUTPUT_FILE="$OUTPUT_DIR/perf-data.txt"
PERF_BASELINE_FILE="$OUTPUT_DIR/perf-baseline.txt"

ACTION="${1:-}"

function add_var() {
    local key="$1"
    local value="$2"
    echo "${key}='${value}'" >> "$VAR_FILE"
}

function read_vars() {
    [[ -f "$VAR_FILE" ]] && source "$VAR_FILE"
}

function baseline_measurement() {
    LABEL="${1:-}"
    APPROACH="${2:-}"
    METHOD="${3:-}"
    shift 3
    TOOL_ARGS=("$@")

    echo "[DEBUG] Starting baseline_measurement..." >&2
    mkdir -p "$OUTPUT_DIR"

    if [[ "$METHOD" == "perf" ]]; then
        nohup bash "$(dirname "$0")/perf.sh" "$PERF_BASELINE_FILE" "${TOOL_ARGS[@]}" > "$OUTPUT_DIR/perf.baseline.log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        echo "[INFO] Baseline measurement started, PID=$pid" >&2
        sleep 5
        pkill -P "$pid" || true
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "[INFO] Baseline measurement finished" >&2
    else
        echo "[ERROR] Unsupported METHOD: $METHOD" >&2
        exit 1
    fi
}

function start_measurement() {
    initialize_vars

    BASELINE="false"
    if [[ "${1:-}" == baseline=* ]]; then
        BASELINE="${1#baseline=}"
        shift 1
    fi
    echo "[INFO] Baseline flag: $BASELINE"

    LABEL="${1:-}"
    APPROACH="${2:-}"
    METHOD="${3:-}"
    shift 3
    TOOL_ARGS=("$@")

    mkdir -p "$OUTPUT_DIR"

    if [[ "$BASELINE" == "true" && ! -f "$PERF_BASELINE_FILE" ]]; then
        echo "[INFO] Running baseline_measurement..."
        baseline_measurement "$LABEL" "$APPROACH" "$METHOD" "${TOOL_ARGS[@]}"
    fi

    date "+%s%6N" >> "$TIMER_FILE_START"
    add_var 'LABEL' "$LABEL"
    add_var 'APPROACH' "$APPROACH"
    add_var 'METHOD' "$METHOD"
    add_var 'BASELINE' "$BASELINE"

    if [[ "$METHOD" == "perf" ]]; then
        nohup bash "$(dirname "$0")/perf.sh" "$PERF_OUTPUT_FILE" "${TOOL_ARGS[@]}" > "$OUTPUT_DIR/perf.log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        add_var 'PID' "$pid"
        echo "[INFO] Measurement started, PID=$pid" >&2
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
    pkill -P "$pid" || true
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    date "+%s%6N" >> "$TIMER_FILE_END"

    if [[ ! -f "$PERF_OUTPUT_FILE" ]]; then
        echo "[ERROR] Output file not found: $PERF_OUTPUT_FILE" >&2
        exit 1
    fi
}

function show_usage() {
    echo "Usage: $0 start_measurement [baseline=true|false] LABEL APPROACH METHOD [TOOL_ARGS ...]" >&2
    echo "       $0 end_measurement" >&2
    echo "       $0 baseline LABEL APPROACH METHOD [TOOL_ARGS ...]" >&2
    exit 1
}

case "$ACTION" in
    start_measurement) start_measurement "$@" ;;
    end_measurement) end_measurement ;;
    baseline) baseline_measurement "$@" ;;
    *) show_usage ;;
esac
