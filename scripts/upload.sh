#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/ci_vars.sh"

SERVER_URL="http://192.168.1.54:8000"

OUTPUT_DIR="/tmp/wattsci"

JAVA_FILE="/home/carlos/PYPEN_EXECUTION.txt"

PERF_FILE="/tmp/wattsci/perf-energy-intervals.txt"

initialize_vars
load_ci_vars
read_vars

if [[ ! -f "$JAVA_FILE" ]]; then
    echo "[ERROR] File not found: $JAVA_FILE"
    exit 1
fi

if [[ ! -f "$PERF_FILE" ]]; then
    echo "[ERROR] File not found: $PERF_FILE"
    exit 1
fi

echo "[INFO] Java file: $JAVA_FILE"
echo "[INFO] Perf file: $PERF_FILE"
echo "[INFO] Server: $SERVER_URL/upload"

RESPONSE=$(curl \
    --fail-with-body \
    -sS \
    -X POST "$SERVER_URL/upload" \
    -F "file=@${JAVA_FILE};filename=PYPEN_EXECUTION.txt" \
    -F "file=@${PERF_FILE};filename=perf-energy-intervals.txt" \
    -F "CI=${CI:-}" \
    -F "RUN_ID=${RUN_ID:-}" \
    -F "REF_NAME=${REF_NAME:-}" \
    -F "REPOSITORY=${REPOSITORY:-}" \
    -F "WORKFLOW_ID=${WORKFLOW_ID:-}" \
    -F "WORKFLOW_NAME=${WORKFLOW_NAME:-}" \
    -F "COMMIT_HASH=${COMMIT_HASH:-}"
)

echo "$RESPONSE"
