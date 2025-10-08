#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------
# refactor.sh - Send refactor request to GreencodeRefactor Server
# ----------------------------------------------------------

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/vars.sh"
initialize_vars

source "$SCRIPT_DIR/ci_vars.sh"
load_ci_vars

# Check required arguments
if [[ $# -lt 2 ]]; then
    echo "[ERROR] Usage: $0 <module-name> <transformers>"
    echo "Example: $0 greencoderefactor-python ExplicitRaiseToExceptBodyTransformer,UnusedLocalVariablesTransformer"
    exit 1
fi

MODULE_NAME="$1"
TRANSFORMERS="$2"

SERVER_URL="http://172.24.106.23:8000/refactor"
OUTPUT_DIR="$HOME/greencoderefactor/output"

# Create output directory if needed
mkdir -p "$OUTPUT_DIR"

# Convert comma-separated transformers into JSON array
IFS=',' read -ra RULES_ARRAY <<< "$TRANSFORMERS"
RULES_JSON="["
for rule in "${RULES_ARRAY[@]}"; do
    RULES_JSON+="\"${rule}\","
done
RULES_JSON="${RULES_JSON%,}]"

# Build JSON payload
payload=$(cat <<EOF
{
  "repo": "$REPOSITORY",
  "ref": "$REF_NAME",
  "output": "${OUTPUT_DIR}",
  "rules": ${RULES_JSON}
}
EOF
)

echo "[INFO] Sending refactor request to server: $SERVER_URL"
echo "[DEBUG] Payload: $payload"

# Send POST request
response=$(curl -s -X POST "$SERVER_URL" \
    -H "Content-Type: application/json" \
    -d "$payload")

echo "[INFO] Server response:"
echo "$response"

