#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# refactor.sh - Run greencoderefactor locally with arguments
# ----------------------------------------------------------

# Load CI variables
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/vars.sh"
initialize_vars

source "$SCRIPT_DIR/ci_vars.sh"
load_ci_vars

# Check required environment variables
: "${TOKEN:?TOKEN must be set}"
: "${REPOSITORY:?REPOSITORY must be set}"
: "${BASE_BRANCH:?BASE_BRANCH must be set}"

if [[ $# -lt 2 ]]; then
    echo "[ERROR] Usage: $0 <greencoderefactor-executable> <transformers>"
    echo "Example: $0 greencoderefactor-python ExplicitRaiseToExceptBodyTransformer,UnusedLocalVariablesTransformer"
    exit 1
fi

GCF_EXEC="$1"
TRANSFORMERS="$2"

OUTPUT_DIR="$HOME/greencoderefactor"
mkdir -p "$OUTPUT_DIR"

echo "[INFO] Running $GCF_EXEC with transformers: $TRANSFORMERS"
"$GCF_EXEC" "$TRANSFORMERS" \
    --output "$OUTPUT_DIR" \
    --repo "$REPOSITORY" \
    --branch "$BASE_BRANCH" \
    --token "$TOKEN"

if [[ $? -eq 0 ]]; then
    echo "[INFO] greencoderefactor completed successfully. Output in $OUTPUT_DIR"
else
    echo "[ERROR] greencoderefactor failed"
    exit 1
fi
