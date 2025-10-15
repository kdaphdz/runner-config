#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/ci_vars.sh"

SERVER_URL="http://172.24.106.15:5000"

OUTPUT_DIR="/tmp/wattsci"
PID_FILE="$OUTPUT_DIR/measurement.pid"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
TIMER_FILE_BASELINE_START="$OUTPUT_DIR/timer_baseline_start.txt"
TIMER_FILE_BASELINE_END="$OUTPUT_DIR/timer_baseline_end.txt"
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
        perf) OUTPUT_FILE="$PERF_OUTPUT_FILE" ;;
        *) echo "[ERROR] Unsupported METHOD: $METHOD"; exit 1 ;;
    esac

    add_var 'OUTPUT_FILE' "$OUTPUT_FILE"

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
        perf) OUTPUT_FILE="$PERF_BASELINE_FILE" ;;
        *) echo "[ERROR] Unsupported METHOD for baseline: $METHOD"; exit 1 ;;
    esac

    add_var 'BASELINE_OUTPUT_FILE' "$OUTPUT_FILE"

    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "[INFO] Baseline file not found. Running baseline measurement..."
        date "+%s%6N" >> "$TIMER_FILE_BASELINE_START"

        run_method_instance "$METHOD" "$OUTPUT_FILE" "${TOOL_ARGS[@]}"
        sleep 5

        local pid
        pid=$(<"$PID_FILE")
        echo "[INFO] Stopping baseline PID=$pid..."
        pkill -P "$pid" || true
        kill "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"

        date "+%s%6N" >> "$TIMER_FILE_BASELINE_END"
        echo "[INFO] Baseline measurement finished"
    else
        echo "[INFO] Baseline file exists, skipping measurement"
    fi
}

function start_measurement() {
    initialize_vars
    load_ci_vars
    read_vars
    
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

    local upload_fields=(
        -F "CI=$CI"
        -F "RUN_ID=$RUN_ID"
        -F "REF_NAME=$REF_NAME"
        -F "REPOSITORY=$REPOSITORY"
        -F "WORKFLOW_ID=$WORKFLOW_ID"
        -F "WORKFLOW_NAME=$WORKFLOW_NAME"
        -F "COMMIT_HASH=$COMMIT_HASH"
        -F "APPROACH=$APPROACH"
        -F "METHOD=$METHOD"
        -F "LABEL=$LABEL"
    )

    if [[ -n "${BASELINE_OUTPUT_FILE:-}" && -f "$BASELINE_OUTPUT_FILE" ]]; then
        echo "[INFO] Uploading baseline measurement"
        local original_name baseline_compressed
        original_name=$(basename "$BASELINE_OUTPUT_FILE")
        baseline_compressed="$OUTPUT_DIR/${original_name}.gz"

        gzip -c "$BASELINE_OUTPUT_FILE" > "$baseline_compressed"
        split -b 10M --numeric-suffixes=1 --suffix-length=3 "$baseline_compressed" "${baseline_compressed}_chunk_"

        for chunk in "${baseline_compressed}_chunk_"*; do
            echo "[INFO] Uploading baseline chunk: $chunk"
            local resp
            resp=$(curl -s -X POST "$SERVER_URL/upload" \
                -F "chunk=@${chunk}" \
                -F "chunk_name=$(basename "$chunk")" \
                -F "type=baseline" \
                -F "timer_start=$(tail -n1 "$TIMER_FILE_BASELINE_START")" \
                -F "timer_end=$(tail -n1 "$TIMER_FILE_BASELINE_END")" \
                "${upload_fields[@]}")
            echo "[DEBUG] Server response: $resp"

            if [[ -z "$session_id" ]]; then
                session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
                echo "[INFO] Session ID received for baseline: $session_id"
            fi
        done
    fi

    if [[ -n "${OUTPUT_FILE:-}" && -f "$OUTPUT_FILE" ]]; then
        echo "[INFO] Uploading main measurement"
        local original_name main_compressed
        original_name=$(basename "$OUTPUT_FILE")
        main_compressed="$OUTPUT_DIR/${original_name}.gz"

        gzip -c "$OUTPUT_FILE" > "$main_compressed"
        split -b 10M --numeric-suffixes=1 --suffix-length=3 "$main_compressed" "${main_compressed}_chunk_"

        for chunk in "${main_compressed}_chunk_"*; do
            echo "[INFO] Uploading main chunk: $chunk"
            local resp
            resp=$(curl -s -X POST "$SERVER_URL/upload" \
                -F "chunk=@${chunk}" \
                -F "chunk_name=$(basename "$chunk")" \
                -F "type=main" \
                -F "timer_start=$(tail -n1 "$TIMER_FILE_START")" \
                -F "timer_end=$(tail -n1 "$TIMER_FILE_END")" \
                "${upload_fields[@]}")
            echo "[DEBUG] Server response: $resp"

            if [[ -z "$session_id" ]]; then
                session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
                echo "[INFO] Session ID received for main: $session_id"
            fi
        done
    fi

    if [[ -n "$session_id" ]]; then
        local start_time end_time response
        start_time=$(tail -n 1 "$TIMER_FILE_START")
        end_time=$(tail -n 1 "$TIMER_FILE_END")
        response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
            -F "session_id=$session_id" \
            "${upload_fields[@]}")
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
