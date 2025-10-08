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

# Check required arguments
if [[ $# -lt 2 ]]; then
    echo "[ERROR] Usage: $0 <greencoderefactor-executable-or-dir> <transformers>"
    echo "Example: $0 greencoderefactor-python ExplicitRaiseToExceptBodyTransformer,UnusedLocalVariablesTransformer"
    exit 1
fi

GCF_EXEC="$1"
TRANSFORMERS="$2"

# Output directory
OUTPUT_DIR="$HOME/greencoderefactor"
mkdir -p "$OUTPUT_DIR"

# Construir ruta completa
EXEC_PATH="$HOME/greencoderefactor/$GCF_EXEC"

# Si es un directorio, buscar main.py dentro
if [[ -d "$EXEC_PATH" ]]; then
    EXEC_PATH="$EXEC_PATH/main.py"
fi

# Comprobar que existe
if [[ ! -f "$EXEC_PATH" ]]; then
    echo "[ERROR] Executable not found: $EXEC_PATH"
    exit 1
fi

echo "[INFO] Running $EXEC_PATH with transformers: $TRANSFORMERS"
python3 "$EXEC_PATH" \
    --repo "$REPOSITORY" \
    --ref "$REF_NAME" \
    --output "$OUTPUT_DIR" \
    --rules "$TRANSFORMERS"

if [[ $? -eq 0 ]]; then
    echo "[INFO] greencoderefactor completed successfully. Output in $OUTPUT_DIR"
else
    echo "[ERROR] greencoderefactor failed"
    exit 1
fi

# ------------------------------
# Upload results to server
# ------------------------------
SERVER_URL="http://172.24.106.23:8000/refactor"

# Construir payload mínimo
payload=$(jq -n \
    --arg repo "$REPOSITORY" \
    --arg ref "$REF_NAME" \
    --arg output "$OUTPUT_DIR" \
    '{repo: $repo, ref: $ref, output: $output}')

echo "[INFO] Sending results to server: $SERVER_URL"
curl -s -X POST "$SERVER_URL" \
    -H "Content-Type: application/json" \
    -d "$payload"

echo "[INFO] Upload completed"

