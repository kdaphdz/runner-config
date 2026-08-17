#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/ci_vars.sh"

JAVA_FILE="/home/carlos/PYPEN_EXECUTION.txt"
PERF_FILE="/tmp/wattsci/perf-energy-intervals.txt"

PYTHON_SCRIPT="/home/carlos/process_energy.py"

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

echo "[INFO] Processing energy locally..."

python3 "$PYTHON_SCRIPT" \
    --java-file "$JAVA_FILE" \
    --perf-file "$PERF_FILE" \
    --ci "${CI:-}" \
    --run-id "${RUN_ID:-}" \
    --ref-name "${REF_NAME:-}" \
    --repository "${REPOSITORY:-}" \
    --workflow-id "${WORKFLOW_ID:-}" \
    --workflow-name "${WORKFLOW_NAME:-}" \
    --commit-hash "${COMMIT_HASH:-}"
