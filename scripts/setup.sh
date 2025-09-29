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
shift 2
TOOL_ARGS=("$@")

function start_measurement {
    if [[ -z "$LABEL" ]]; then
        echo "[ERROR] start_measurement requires LABEL as first argument."
        exit 1
    fi

    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
    fi
    mkdir -p "$OUTPUT_DIR"

    date "+%s%6N" >> "$TIMER_FILE_START"
    add_var 'LABEL' "$LABEL"

    local METHOD=""
    local interval_ms=""
    local events=""

    # parse TOOL_ARGS
    for arg in "${TOOL_ARGS[@]}"; do
        case "$arg" in
            perf|other_method)
                METHOD="$arg"
                ;;
            interval=*)
                interval_ms="${arg#interval=}"
                ;;
            events=*)
                events="${arg#events=}"
                ;;
            *)
                echo "[WARNING] Unknown argument: $arg (ignored)"
                ;;
        esac
    done

    if [[ -z "$METHOD" ]]; then
        echo "[ERROR] METHOD not specified."
        exit 1
    fi

    add_var 'METHOD' "$METHOD"

    case "$METHOD" in
        perf)
            if [[ -z "$interval_ms" || -z "$events" ]]; then
                echo "[ERROR] perf requires both interval and events."
                exit 1
            fi
            IFS=',' read -r -a PERF_EVENTS <<< "$events"
            perf_events_str=$(IFS=','; echo "${PERF_EVENTS[*]}")

            bash "$(dirname "$0")/perf.sh" "events=${perf_events_str}" "interval=${interval_ms}" < /dev/null 2>&1 &
            local parent_pid=$!
            sleep 1
            local child_pid
            child_pid=$(pgrep -P "$parent_pid" -n)
            if [[ -z "$child_pid" ]]; then
                echo "[ERROR] Failed to detect perf child process."
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

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file $PID_FILE not found for label $LABEL."
        exit 1
    fi

    date "+%s%6N" >> "$TIMER_FILE_END"

    local pid
    pid=$(<"$PID_FILE")
    if kill "$pid" 2>/dev/null; then
        rm -f "$PID_FILE"
    else
        rm -f "$PID_FILE"
        echo "[ERROR] Failed to stop process PID=$pid"
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

    local CHUNK_SIZE="10M"
    split -b "$CHUNK_SIZE" --numeric-suffixes=1 --suffix-length=3 \
          "$COMPRESSED_FILE" "${COMPRESSED_FILE}_chunk_"

    local upload_fields=(
        -F "CI=$CI"
        -F "RUN_ID=$RUN_ID"
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
        fi
    done

    local start_time
    start_time=$(tail -n 1 "$TIMER_FILE_START")
    local end_time
    end_time=$(tail -n 1 "$TIMER_FILE_END")
    local response
    response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
        -F "session_id=$session_id" \
        -F "timer_start=$start_time" \
        -F "timer_end=$end_time" \
        "${upload_fields[@]}" \
        -F "original_name=$ORIGINAL_NAME")

    local summary_md
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

case "$ACTION" in
    start_measurement)
        start_measurement "$@"
        ;;
    end_measurement)
        end_measurement
        ;;
    *)
        echo "[ERROR] Unknown action: $ACTION"
        exit 1
        ;;
esac
