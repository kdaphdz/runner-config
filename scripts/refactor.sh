#!/usr/bin/env bash
set -euo pipefail

SERVER_URL="http://172.24.106.17:8000/"

SCRIPT_DIR="$(dirname "$0")"

source "$SCRIPT_DIR/vars.sh"
initialize_vars

source "$SCRIPT_DIR/ci_vars.sh"
load_ci_vars
read_vars

MODULE_NAME="$1"
TRANSFORMERS="$2"

# Convertimos la lista de reglas a JSON
IFS=',' read -ra RULES_ARRAY <<< "$TRANSFORMERS"
RULES_JSON="["
for rule in "${RULES_ARRAY[@]}"; do
    RULES_JSON+="\"${rule}\","
done
RULES_JSON="${RULES_JSON%,}]"

# Construimos el payload con todas las variables CI tal como están
payload=$(cat <<EOF
{
  "module": "$MODULE_NAME",
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
