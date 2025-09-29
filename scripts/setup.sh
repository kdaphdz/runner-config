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
WATTSCI_OUTPUT_FILE="$OUTPUT_DIR/perf-data.txt"

ACTION="${1:-}"
LABEL="${2:-}"
APPROACH="${3:-}"
METHOD="${4:-}"
shift 4
TOOL_ARGS=("$@")

function start_measurement {
    if [[ -z "$METHOD" || -z "$APPROACH" || -z "$LABEL" ]]; then
        echo "[ERROR] start_measurement requires LABEL, APPROACH, METHOD"
        exit 1
    fi

    [[ -d "$OUTPUT_DIR" ]] && rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    date "+%s%6N" >> "$TIMER_FILE_START"

    add_var 'LABEL' "$LABEL"
    add_var 'APPROACH' "$APPROACH"
    add_var 'METHOD' "$METHOD"

    case "$METHOD" in
        perf)
            local interval_ms=""
            local events=""
            for arg in "${TOOL_ARGS[@]}"; do
                [[ "$arg" == interval=* ]] && interval_ms="${arg#interval=}"
                [[ "$arg" == events=* ]] && events="${arg#events=}"
            done

            if [[ -z "$interval_ms" ]]; then
                interval_ms=1000
            fi

            IFS=',' read -ra PERF_EVENTS <<< "$events"

            bash "$(dirname "$0")/perf.sh" "${PERF_EVENTS[@]}" "$interval_ms" < /dev/null 2>&1 &
            local parent_pid=$!
            sleep 1
            local child_pid
            child_pid=$(pgrep -P "$parent_pid" -n)
            if [[ -z "$child_pid" ]]; then
                kill "$parent_pid" || true
                exit 1
            fi
            echo "$child_pid" > "$PID_FILE"
            ;;
        *)
            echo "[ERROR] Unsupported METHOD: $METHOD"
            exit 1
            ;;
    esac
}

function end_measurement {
    if [[ -z "$LABEL" ]]; then
        echo "[ERROR] end_measurement requires LABEL as first argument."
        exit 1
    fi

    [[ ! -f "$PID_FILE" ]] && { echo "[ERROR] PID file not found for label $LABEL."; exit 1; }

    date "+%s%6N" >> "$TIMER_FILE_END"

    local pid
    pid=$(<"$PID_FILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"

    [[ ! -f "$WATTSCI_OUTPUT_FILE" ]] && { echo "[ERROR] Output file not found: $WATTSCI_OUTPUT_FILE"; exit 1; }

    local ORIGINAL_NAME COMPRESSED_FILE CHUNK_SIZE session_id start_time end_time response summary_md
    ORIGINAL_NAME=$(basename "$WATTSCI_OUTPUT_FILE")
    COMPRESSED_FILE="$OUTPUT_DIR/${ORIGINAL_NAME}.gz"
    gzip -c "$WATTSCI_OUTPUT_FILE" > "$COMPRESSED_FILE"

    CHUNK_SIZE="10M"
    split -b "$CHUNK_SIZE" --numeric-suffixes=1 --suffix-length=3 "$COMPRESSED_FILE" "${COMPRESSED_FILE}_chunk_"

    local upload_fields=(-F "CI=$CI" -F "RUN_ID=$RUN_ID" -F "LABEL=$LABEL")

    session_id=""
    for chunk in "${COMPRESSED_FILE}_chunk_"*; do
        resp=$(curl -s -X POST "$SERVER_URL/upload" \
            -F "chunk=@${chunk}" \
            -F "chunk_name=$(basename "$chunk")" \
            "${upload_fields[@]}")
        if [[ -z "$session_id" ]]; then
            session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
        fi
    done

    start_time=$(tail -n 1 "$TIMER_FILE_START")
    end_time=$(tail -n 1 "$TIMER_FILE_END")
    response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
        -F "session_id=$session_id" \
        -F "timer_start=$start_time" \
        -F "timer_end=$end_time" \
        "${upload_fields[@]}" \
        -F "original_name=$ORIGINAL_NAME")

    summary_md=$(echo "$response" | grep -oP '"summary_md"\s*:\s*"\K[^"]*' | sed 's/\\n/\n/g')
    if [[ "$CI" == "GitHub" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        {
            echo "## Reconstruction Status"
            echo "- Session ID: $session_id"
            echo "- Timer start: $start_time"
            echo "- Timer end: $end_time"
            [[ -n "$summary_md" ]] && echo -e "### Server Summary\n$summary_md"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

case "$ACTION" in
    start_measurement)
        start_measurement
        ;;
    end_measurement)
        end_measurement
        ;;
    *)
        echo "[ERROR] Unknown action: $ACTION"
        exit 1
        ;;
esac
