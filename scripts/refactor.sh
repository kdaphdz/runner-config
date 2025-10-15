#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/ci_vars.sh"

initialize_vars
load_ci_vars
read_vars

SERVER_URL="http://172.24.106.15:8000/"

TOOL="$1"
RULES="$2"

IFS=',' read -ra RULES_ARRAY <<< "$RULES"
RULES_JSON="["
for rule in "${RULES_ARRAY[@]}"; do
    RULES_JSON+="\"${rule}\","
done
RULES_JSON="${RULES_JSON%,}]"

payload=$(cat <<EOF
{
  "tool": "$TOOL",
  "CI": "$CI",
  "RUN_ID": "$RUN_ID",
  "REF_NAME": "$REF_NAME",
  "REPOSITORY": "$REPOSITORY",
  "WORKFLOW_ID": "$WORKFLOW_ID",
  "WORKFLOW_NAME": "$WORKFLOW_NAME",
  "COMMIT_HASH": "$COMMIT_HASH",
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
