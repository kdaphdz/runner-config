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

ACTION="${1:-}"
LABEL="${2:-}"
APPROACH="${3:-}"
METHOD="${4:-}"
shift 4
TOOL_ARGS=("$@")

function start_measurement {
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
    fi
    mkdir -p "$OUTPUT_DIR"

    date "+%s%6N" >> "$TIMER_FILE_START"

    add_var 'LABEL' "$LABEL"
    add_var 'METHOD' "$METHOD"
    add_var 'APPROACH' "$APPROACH"

    case "$METHOD" in
        perf)
            local interval_ms="${TOOL_ARGS[-1]}"
            local perf_events=("${TOOL_ARGS[@]:0:${#TOOL_ARGS[@]}-1}")
            bash "$(dirname "$0")/perf.sh" "${perf_events[@]}" "$interval_ms" < /dev/null 2>&1 &
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
            exit 1
            ;;
    esac
}

function end_measurement {
    # Cargar todas las variables guardadas en vars.sh
    read_vars

    if [[ -z "${LABEL:-}" ]]; then
        echo "[ERROR] end_measurement requires LABEL to be set."
        exit 1
    fi

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file $PID_FILE not found for label $LABEL."
        exit 1
    fi

    date "+%s%6N" >> "$TIMER_FILE_END"

    local pid
    pid=$(<"$PID_FILE")
    if kill "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
        echo "[INFO] Measurement process PID=$pid stopped."
    else
        rm -f "$PID_FILE"
        echo "[ERROR] Failed to stop measurement process PID=$pid"
        exit 1
    fi

    if [[ ! -f "$WATTSCI_OUTPUT_FILE" ]]; then
        echo "[ERROR] Output file not found: $WATTSCI_OUTPUT_FILE"
        exit 1
    fi

    local ORIGINAL_NAME
    ORIGINAL_NAME=$(basename "$WATTSCI_OUTPUT_FILE")
    local COMPRESSED_FILE="$OUTPUT_DIR/${ORIGINAL_NAME}.gz"
    gzip -c "$WATTSCI_OUTPUT_FILE" > "$COMPRESSED_FILE"
    echo "[INFO] Compressed perf output saved to: $COMPRESSED_FILE"

    local CHUNK_SIZE="10M"
    split -b "$CHUNK_SIZE" --numeric-suffixes=1 --suffix-length=3 \
          "$COMPRESSED_FILE" "${COMPRESSED_FILE}_chunk_"
    echo "[INFO] Chunks created: ${COMPRESSED_FILE}_chunk_*"

    # Campos para upload
    local upload_fields=(
        -F "CI=$CI"
        -F "RUN_ID=$RUN_ID"
        -F "REF_NAME=$REF_NAME"
        -F "REPOSITORY=$REPOSITORY"
        -F "WORKFLOW_ID=$WORKFLOW_ID"
        -F "WORKFLOW_NAME=$WORKFLOW_NAME"
        -F "COMMIT_HASH=$COMMIT_HASH"
        -F "METHOD=$METHOD"
        -F "LABEL=$LABEL"
    )

    local session_id=""
    for chunk in "${COMPRESSED_FILE}_chunk_"*; do
        local resp
        resp=$(curl -s -X POST "$SERVER_URL/upload" \
            -F "chunk=@${chunk}" \
            -F "chunk_name=$(basename "$chunk")" \
            "${upload_fields[@]}")
        if [[ -z "$session_id" ]]; then
            session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
            echo "[INFO] Session ID received: $session_id"
        fi
    done

    local start_time end_time response summary_md
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
            if [[ -n "$summary_md" ]]; then
                echo "### Server Summary"
                echo "$summary_md"
            fi
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

function baseline {
    start_measurement "$@"
    sleep 5
    end_measurement --baseline
}

function show_usage {
    exit 1
}

case "$ACTION" in
    start_measurement)
        start_measurement "$@"
        ;;
    end_measurement)
        end_measurement "$@"
        ;;
    baseline)
        baseline "$@"
        ;;
    *)
        show_usage
        ;;
esac
