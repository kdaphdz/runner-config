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
shift || true

function baseline_measurement() {
    local LABEL="$1"
    local APPROACH="$2"
    local METHOD="$3"
    shift 3
    local TOOL_ARGS=("$@")

    echo "[DEBUG] Starting baseline_measurement..."
    mkdir -p "$OUTPUT_DIR"

    if [[ "$METHOD" == "perf" ]]; then
        echo "[INFO] Launching perf for baseline..."
        nohup bash "$(dirname "$0")/perf.sh" "$PERF_BASELINE_FILE" "${TOOL_ARGS[@]}" > "$OUTPUT_DIR/perf.baseline.log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        echo "[INFO] Baseline measurement started, PID=$pid"
        sleep 5
        pkill -P "$pid" || true
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "[INFO] Baseline measurement finished"
    else
        echo "[ERROR] Unsupported METHOD: $METHOD"
        exit 1
    fi
}

function start_measurement() {
    initialize_vars

    local BASELINE="false"
    if [[ "${1:-}" == baseline=* ]]; then
        BASELINE="${1#baseline=}"
        shift 1
    fi
    echo "[INFO] Baseline flag: $BASELINE"

    if [[ $# -lt 3 ]]; then
        echo "[ERROR] Not enough arguments. Expected LABEL, APPROACH, METHOD."
        show_usage
    fi

    local LABEL="$1"
    local APPROACH="$2"
    local METHOD="$3"
    shift 3
    local TOOL_ARGS=("$@")

    mkdir -p "$OUTPUT_DIR"

    if [[ "$BASELINE" == "true" && ! -f "$PERF_BASELINE_FILE" ]]; then
        echo "[INFO] Baseline file not found. Running baseline_measurement..."
        baseline_measurement "$LABEL" "$APPROACH" "$METHOD" "${TOOL_ARGS[@]}"
    else
        echo "[INFO] Skipping baseline_measurement"
    fi

    date "+%s%6N" >> "$TIMER_FILE_START"
    add_var 'LABEL' "$LABEL"
    add_var 'APPROACH' "$APPROACH"
    add_var 'METHOD' "$METHOD"
    add_var 'BASELINE' "$BASELINE"

    if [[ "$METHOD" == "perf" ]]; then
        echo "[INFO] Launching perf for main measurement..."
        nohup bash "$(dirname "$0")/perf.sh" "$PERF_OUTPUT_FILE" "${TOOL_ARGS[@]}" > "$OUTPUT_DIR/perf.log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        add_var 'PID' "$pid"
        echo "[INFO] Measurement started, PID=$pid"
    else
        echo "[ERROR] Unsupported METHOD: $METHOD"
        exit 1
    fi
}

function end_measurement() {
    read_vars

    if [[ -z "${LABEL:-}" ]]; then
        echo "[ERROR] LABEL is not set"
        exit 1
    fi

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file not found: $PID_FILE"
        exit 1
    fi

    local pid
    pid=$(<"$PID_FILE")
    echo "[INFO] Stopping measurement PID=$pid..."
    pkill -P "$pid" || true
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    date "+%s%6N" >> "$TIMER_FILE_END"
    echo "[INFO] Timer end recorded at $(tail -n1 "$TIMER_FILE_END")"

    if [[ ! -f "$PERF_OUTPUT_FILE" ]]; then
        echo "[ERROR] Output file not found: $PERF_OUTPUT_FILE"
        exit 1
    fi
}

function show_usage() {
    echo "[INFO] Usage: $0 start_measurement [baseline=true|false] LABEL APPROACH METHOD [TOOL_ARGS ...]"
    echo "[INFO]        $0 end_measurement"
    exit 1
}

case "$ACTION" in
    start_measurement) start_measurement "$@" ;;
    end_measurement) end_measurement ;;
    *) show_usage ;;
esac
