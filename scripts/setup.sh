#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/ci_vars.sh"
load_ci_vars
source "$(dirname "$0")/vars.sh"
read_vars

SERVER_URL="http://172.24.106.17:5000"

OUTPUT_DIR="/tmp/wattsci"
PID_FILE="$OUTPUT_DIR/measurement.pid"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
VAR_FILE="$OUTPUT_DIR/vars.sh"

PERF_OUTPUT_FILE="$OUTPUT_DIR/perf-data.txt"
PERF_BASELINE_FILE="$OUTPUT_DIR/perf-baseline.txt"

ACTION="${1:-}"
shift || true

function run_method_instance() {
    local METHOD="$1"
    local OUTPUT_FILE="$2"
    shift 2
    local TOOL_ARGS=("$@")

    mkdir -p "$OUTPUT_DIR"

    case "$METHOD" in
        perf)
            echo "[INFO] Launching perf, output=$OUTPUT_FILE"
            nohup bash "$(dirname "$0")/perf.sh" "$OUTPUT_FILE" "${TOOL_ARGS[@]}" > "$OUTPUT_DIR/$(basename "$OUTPUT_FILE").log" 2>&1 &
            local pid=$!
            echo "$pid" > "$PID_FILE"
            echo "[INFO] $METHOD measurement started, PID=$pid"
            ;;
        *)
            echo "[ERROR] Unsupported METHOD: $METHOD"
            exit 1
            ;;
    esac
}

function perform_measurement() {
    local LABEL="$1"
    local APPROACH="$2"
    local METHOD="$3"
    shift 3
    local TOOL_ARGS=("$@")
    local OUTPUT_FILE

    case "$METHOD" in
        perf)
            OUTPUT_FILE="$PERF_OUTPUT_FILE"
            ;;
        *)
            echo "[ERROR] Unsupported METHOD: $METHOD"
            exit 1
            ;;
    esac

    run_method_instance "$METHOD" "$OUTPUT_FILE" "${TOOL_ARGS[@]}"
}

function baseline_measurement() {
    local LABEL="$1"
    local APPROACH="$2"
    local METHOD="$3"
    shift 3
    local TOOL_ARGS=("$@")
    local OUTPUT_FILE

    case "$METHOD" in
        perf)
            OUTPUT_FILE="$PERF_BASELINE_FILE"
            ;;
        *)
            echo "[ERROR] Unsupported METHOD for baseline: $METHOD"
            exit 1
            ;;
    esac

    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "[INFO] Baseline file not found. Running baseline measurement..."
        run_method_instance "$METHOD" "$OUTPUT_FILE" "${TOOL_ARGS[@]}"
        sleep 5
        local pid
        pid=$(<"$PID_FILE")
        echo "[INFO] Stopping baseline PID=$pid..."
        pkill -P "$pid" || true
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "[INFO] Baseline measurement finished"
    else
        echo "[INFO] Baseline file exists, skipping measurement"
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

    date "+%s%6N" >> "$TIMER_FILE_START"
    add_var 'LABEL' "$LABEL"
    add_var 'APPROACH' "$APPROACH"
    add_var 'METHOD' "$METHOD"
    add_var 'BASELINE' "$BASELINE"

    if [[ "$BASELINE" == "true" ]]; then
        baseline_measurement "$LABEL" "$APPROACH" "$METHOD" "${TOOL_ARGS[@]}"
    fi

    echo "[INFO] Running main measurement..."
    perform_measurement "$LABEL" "$APPROACH" "$METHOD" "${TOOL_ARGS[@]}"
}

function end_measurement() {
    read_vars

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

    upload_measurement
}

function upload_measurement() {
    local session_id=""
    
    # --- Upload baseline if exists ---
    if [[ -f "$PERF_BASELINE_FILE" ]]; then
        echo "[INFO] Uploading baseline measurement"
        local original_name baseline_compressed
        original_name=$(basename "$PERF_BASELINE_FILE")
        baseline_compressed="$OUTPUT_DIR/${original_name}.gz"
        
        echo "[INFO] Compressing baseline $PERF_BASELINE_FILE -> $baseline_compressed"
        gzip -c "$PERF_BASELINE_FILE" > "$baseline_compressed"
        
        local chunk_size="10M"
        echo "[INFO] Splitting baseline compressed file into chunks of $chunk_size"
        split -b "$chunk_size" --numeric-suffixes=1 --suffix-length=3 \
            "$baseline_compressed" "${baseline_compressed}_chunk_"
        
        for chunk in "${baseline_compressed}_chunk_"*; do
            echo "[INFO] Uploading baseline chunk: $chunk"
            local resp
            resp=$(curl -s -X POST "$SERVER_URL/upload" \
                -F "chunk=@${chunk}" \
                -F "chunk_name=$(basename "$chunk")" \
                -F "type=baseline" \
                -F "LABEL=$LABEL" \
                -F "METHOD=$METHOD" \
                -F "CI=$CI" \
                -F "RUN_ID=$RUN_ID")
            echo "[DEBUG] Server response: $resp"
            
            if [[ -z "$session_id" ]]; then
                session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
                echo "[INFO] Session ID received for baseline: $session_id"
            fi
        done
    else
        echo "[INFO] No baseline file to upload"
    fi

    # --- Upload main measurement ---
    if [[ -f "$PERF_OUTPUT_FILE" ]]; then
        echo "[INFO] Uploading main measurement"
        local original_name main_compressed
        original_name=$(basename "$PERF_OUTPUT_FILE")
        main_compressed="$OUTPUT_DIR/${original_name}.gz"
        
        echo "[INFO] Compressing main $PERF_OUTPUT_FILE -> $main_compressed"
        gzip -c "$PERF_OUTPUT_FILE" > "$main_compressed"
        
        local chunk_size="10M"
        echo "[INFO] Splitting main compressed file into chunks of $chunk_size"
        split -b "$chunk_size" --numeric-suffixes=1 --suffix-length=3 \
            "$main_compressed" "${main_compressed}_chunk_"
        
        for chunk in "${main_compressed}_chunk_"*; do
            echo "[INFO] Uploading main chunk: $chunk"
            local resp
            resp=$(curl -s -X POST "$SERVER_URL/upload" \
                -F "chunk=@${chunk}" \
                -F "chunk_name=$(basename "$chunk")" \
                -F "type=main" \
                -F "LABEL=$LABEL" \
                -F "METHOD=$METHOD" \
                -F "CI=$CI" \
                -F "RUN_ID=$RUN_ID")
            echo "[DEBUG] Server response: $resp"
            
            if [[ -z "$session_id" ]]; then
                session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
                echo "[INFO] Session ID received for main: $session_id"
            fi
        done
    else
        echo "[ERROR] Main measurement file not found: $PERF_OUTPUT_FILE"
    fi

    # --- Reconstruct on server ---
    if [[ -n "$session_id" ]]; then
        local start_time end_time response summary_md
        start_time=$(tail -n 1 "$TIMER_FILE_START")
        end_time=$(tail -n 1 "$TIMER_FILE_END")
        echo "[DEBUG] start_time=$start_time, end_time=$end_time"

        response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
            -F "session_id=$session_id" \
            -F "timer_start=$start_time" \
            -F "timer_end=$end_time" \
            -F "LABEL=$LABEL" \
            -F "METHOD=$METHOD" \
            -F "CI=$CI" \
            -F "RUN_ID=$RUN_ID")
        echo "[DEBUG] Reconstruct response: $response"
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
