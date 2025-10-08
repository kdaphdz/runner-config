#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="http://172.24.106.23:8000/"

SCRIPT_DIR="$(dirname "$0")"

source "$SCRIPT_DIR/vars.sh"
initialize_vars

source "$SCRIPT_DIR/ci_vars.sh"
load_ci_vars
read_vars

MODULE_NAME="$1"
TRANSFORMERS="$2"

IFS=',' read -ra RULES_ARRAY <<< "$TRANSFORMERS"
RULES_JSON="["
for rule in "${RULES_ARRAY[@]}"; do
    RULES_JSON+="\"${rule}\","
done
RULES_JSON="${RULES_JSON%,}]"

payload=$(cat <<EOF
{
  "module": "$MODULE_NAME",
  "repo": "$REPOSITORY",
  "ref": "$REF_NAME",
  "rules": ${RULES_JSON}
}
EOF
)

echo "[INFO] Sending refactor request to server: $SERVER_URL"
echo "[DEBUG] Payload: $payload"

response=$(curl -s -X POST "$SERVER_URL" \
    -H "Content-Type: application/json" \
    -d "$payload")

echo "[INFO] Server response:"
echo "$response"
