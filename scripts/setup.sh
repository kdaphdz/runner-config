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

# --- Funciones ---
function add_var() {
    local key="$1"
    local value="$2"
    echo "${key}='${value}'" >> "$VAR_FILE"
}

function read_vars() {
    [[ -f "$VAR_FILE" ]] && source "$VAR_FILE"
}

function baseline_measurement() {
    # Baseline measurement sin inicializar vars ni add_var
    LABEL="${1:-}"
    APPROACH="${2:-}"
    METHOD="${3:-}"
    shift 3
    TOOL_ARGS=("$@")

    echo "[DEBUG] Starting baseline_measurement..." >&2
    mkdir -p "$OUTPUT_DIR"

    if [[ "$METHOD" == "perf" ]]; then
        local perf_log="$OUTPUT_DIR/perf.baseline.log"
        nohup bash "$(dirname "$0")/perf.sh" "${TOOL_ARGS[@]}" > "$perf_log" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        echo "[INFO] Baseline measurement started, PID=$pid, logging to $perf_log" >&2

        # Simulación de duración de baseline
        sleep 5

        # Terminar medición
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

    # --- Detectar baseline flag ---
    BASELINE="false"
    if [[ "${1:-}" == baseline=* ]]; then
        BASELINE="${1#baseline=}"
        shift 1
    fi
    echo "[INFO] Baseline flag: $BASELINE"

    # --- LABEL, APPROACH, METHOD ---
    LABEL="${1:-}"
    APPROACH="${2:-}"
    METHOD="${3:-}"
    shift 3

    # --- TOOL_ARGS ---
    TOOL_ARGS=("$@")

    mkdir -p "$OUTPUT_DIR"

    # --- Ejecutar baseline si corresponde ---
    if [[ "$BASELINE" == "true" ]]; then
        local baseline_file="$OUTPUT_DIR/perf.baseline.txt"
        if [[ ! -f "$baseline_file" ]]; then
            echo "[INFO] Baseline file not found. Running baseline_measurement..."
            baseline_measurement "$LABEL" "$APPROACH" "$METHOD" "${TOOL_ARGS[@]}"
            echo "[INFO] Baseline measurement finished."
        else
            echo "[INFO] Baseline file exists: $baseline_file. Skipping baseline measurement."
        fi
    fi

    # --- Iniciar medición normal ---
    date "+%s%6N" >> "$TIMER_FILE_START"
    add_var 'LABEL' "$LABEL"
    add_var 'APPROACH' "$APPROACH"
    add_var 'METHOD' "$METHOD"
    add_var 'BASELINE' "$BASELINE"

    if [[ "$METHOD" == "perf" ]]; then
        local perf_log="$OUTPUT_DIR/perf.log"
        nohup bash "$(dirname "$0")/perf.sh" "${TOOL_ARGS[@]}" > "$perf_log" 2>&1 &
        local pid=$!
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

    # --- Comprimir y dividir en chunks ---
    if [[ ! -f "$WATTSCI_OUTPUT_FILE" ]]; then
        echo "[ERROR] Output file not found: $WATTSCI_OUTPUT_FILE" >&2
        exit 1
    fi

    local original_name compressed_file
    original_name=$(basename "$WATTSCI_OUTPUT_FILE")
    compressed_file="$OUTPUT_DIR/${original_name}.gz"
    gzip -c "$WATTSCI_OUTPUT_FILE" > "$compressed_file"
    echo "[INFO] Compressed perf output saved to: $compressed_file" >&2

    local chunk_size="10M"
    split -b "$chunk_size" --numeric-suffixes=1 --suffix-length=3 \
        "$compressed_file" "${compressed_file}_chunk_"
    echo "[INFO] Chunks created: ${compressed_file}_chunk_*" >&2

    # --- Campos para upload ---
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
    for chunk in "${compressed_file}_chunk_"*; do
        echo "[DEBUG] Uploading chunk: $chunk" >&2
        local resp
        resp=$(curl -s -X POST "$SERVER_URL/upload" \
            -F "chunk=@${chunk}" \
            -F "chunk_name=$(basename "$chunk")" \
            "${upload_fields[@]}")
        echo "[DEBUG] Server response: $resp" >&2

        if [[ -z "$session_id" ]]; then
            session_id=$(echo "$resp" | grep -oP '"session_id"\s*:\s*"\K[^"]+')
            echo "[INFO] Session ID received: $session_id" >&2
        fi
    done

    local start_time end_time response summary_md
    start_time=$(tail -n 1 "$TIMER_FILE_START")
    end_time=$(tail -n 1 "$TIMER_FILE_END")
    echo "[DEBUG] start_time=$start_time, end_time=$end_time" >&2

    response=$(curl -s -X POST "$SERVER_URL/reconstruct" \
        -F "session_id=$session_id" \
        -F "timer_start=$start_time" \
        -F "timer_end=$end_time" \
        "${upload_fields[@]}" \
        -F "original_name=$original_name")
    echo "[DEBUG] Reconstruct response: $response" >&2

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

    echo "[DEBUG] end_measurement finished" >&2
}

function show_usage() {
    echo "Usage: $0 start_measurement [baseline=true|false] LABEL APPROACH METHOD [TOOL_ARGS ...]" >&2
    echo "       $0 end_measurement" >&2
    echo "       $0 baseline LABEL APPROACH METHOD [TOOL_ARGS ...]" >&2
    exit 1
}

# --- Acción principal ---
case "$ACTION" in
    start_measurement) start_measurement "$@" ;;
    end_measurement) end_measurement ;;
    baseline) baseline_measurement "$@" ;;
    *) show_usage ;;
esac

