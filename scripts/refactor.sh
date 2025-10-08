#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# refactor.sh - Send refactor request to server
# ----------------------------------------------------------

# Load CI variables
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/vars.sh"
initialize_vars

source "$SCRIPT_DIR/ci_vars.sh"
load_ci_vars

# Check required arguments
if [[ $# -lt 2 ]]; then
    echo "[ERROR] Usage: $0 <repo> <transformers>"
    echo "Example: $0 owner/repo ExplicitRaiseToExceptBodyTransformer,UnusedLocalVariablesTransformer"
    exit 1
fi

REPO="$1"
TRANSFORMERS="$2"

# Server URL
SERVER_URL="http://172.24.106.23:8000/refactor"

# Construir payload JSON
payload=$(jq -n \
    --arg repo "$REPO" \
    --arg ref "$REF_NAME" \
    --arg rules "$TRANSFORMERS" \
    '{repo: $repo, ref: $ref, rules: $rules}')

echo "[INFO] Sending refactor request to server: $SERVER_URL"
curl -s -X POST "$SERVER_URL" \
    -H "Content-Type: application/json" \
    -d "$payload"

echo "[INFO] Request sent"
