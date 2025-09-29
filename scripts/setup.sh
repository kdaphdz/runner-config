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

function start_measurement {
    if [[ $# -lt 1 ]]; then
        echo "[ERROR] Missing arguments for start_measurement" >&2
        show_usage
    fi

    if [[ -d "$OUTPUT_DIR" ]]; then
        echo "[INFO] Cleaning previous output directory"
        rm -rf "$OUTPUT_DIR"
    fi
    mkdir -p "$OUTPUT_DIR"

    date "+%s%6N" >> "$TIMER_FILE_START"
    echo "[INFO] Timer start recorded at $(tail -n 1 "$TIMER_FILE_START")"

    local label="$1"
    shift 1
    local method="$1"
    shift 1
    local args=("$@")

    add_var 'LABEL' "$label"
    add_var 'METHOD' "$method"

    case "$method" in
        perf)
            local interval_ms="${args[-1]}"
            # Todos los anteriores son eventos
            local perf_events=("${args[@]:0:${#args[@]}-1}")

            bash "$(dirname "$0")/perf.sh" "${perf_events[@]}" "$interval_ms" < /dev/null 2>&1 &

            local parent_pid=$!
            sleep 1
            local child_pid
            child_pid=$(pgrep -P "$parent_pid" -n)

            if [[ -z "$child_pid" ]]; then
                echo "[ERROR] Failed to detect perf child process PID" >&2
                kill "$parent_pid" || true
                exit 1
            fi

            echo "$child_pid" > "$PID_FILE"
            echo "[INFO] Measurement running with PID $child_pid"
            ;;
        *)
            echo "[ERROR] Unsupported method: $method" >&2
            exit 1
            ;;
    esac
}

function end_measurement {
    local baseline_flag="false"
    for arg in "$@"; do
        if [[ "$arg" == "--baseline" ]]; then
            baseline_flag="true"
            break
        fi
    done

    if [[ ! -f "$PID_FILE" ]]; then
        echo "[ERROR] PID file not found. Cannot stop measurement." >&2
        exit 1
    fi

    date "+%s%6N" >> "$TIMER_FILE_END"
    echo "[INFO] Timer end recorded at $(tail -n 1 "$TIMER_FILE_END")"

    local pid
    pid=$(<"$PID_FILE")

    if kill "$pid" 2>/dev/null; then
        echo "[INFO] Stopped measurement process PID=$pid"
        rm -f "$PID_FILE"
    else
        echo "[ERROR] Failed to stop process PID=$pid"
        rm -f "$PID_FILE"
        exit 1
    fi

    if [[ ! -f "$WATTSCI_OUTPUT_FILE" ]]; then
        echo "[ERROR] Perf output file not found: $WATTSCI_OUTPUT_FILE" >&2
        exit 1
    fi

    ORIGINAL_NAME=$(basename "$WATTSCI_OUTPUT_FILE")

    COMPRESSED_FILE="$OUTPUT_DIR/${ORIGINAL_NAME}.gz"
    gzip -c "$WATTSCI_OUTPUT_FILE" > "$COMPRESSED_FILE"
    echo "[INFO] Compressed perf output saved to: $COMPRESSED_FILE"

    CHUNK_SIZE="10M"
    split -b "$CHUNK_SIZE" --numeric-suffixes=1 --suffix-length=3 \
          "$COMPRESSED_FILE" "${COMPRESSED_FILE}_chunk_"
    echo "[INFO] Chunks created:"
    ls -lh "${COMPRESSED_FILE}_chunk_"*

    upload_fields=(
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

    if [[ "$baseline_flag" == "true" ]]; then
        upload_fields+=(-F "WATTSCI_BASELINE=true")
    else
        upload_fields+=(-F "WATTSCI_BASELINE=false")
    fi

    session_id=""
    for chunk in "${COMPRESSED_FILE}_chunk_"*; do
        echo "[INFO] Uploading chunk: $chunk"
        resp=$(curl -s -X POST "$SERVER_URL/upload" \
            -F "chunk=@${chunk}" \
            -F "chunk_name=$(basename "$chunk")" \
            "${upload_fields[@]}")

        echo " - Server response: $resp"

        if [[ -z "$session_id" ]]; then
            session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
            echo "[INFO] Session ID received: $session_id"
        fi
    done

    echo "[INFO] Requesting file reconstruction on server..."
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
            echo ""
            if [[ -n "$summary_md" ]]; then
                echo "### Server Summary"
                echo "$summary_md"
            fi
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

function baseline {
    echo "[DEBUG] baseline args: $@"
    start_measurement "$@"
    echo "[INFO] Sleeping for 5 seconds between start and end measurement..."
    sleep 5
    end_measurement --baseline
}

function show_usage {
    echo "Usage:"
    echo "  $0 start_measurement perf <event1> [<event2> ...] <interval_ms>"
    echo "  $0 end_measurement"
    echo "  $0 baseline <all start_measurement args>"
    exit 1
}

option="${1:-}"

if [[ -z "$option" ]]; then
    echo "[ERROR] No option provided."
    show_usage
fi

shift || true

case "$option" in
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
        echo "[ERROR] Invalid option: $option"
        show_usage
        ;;
esac

