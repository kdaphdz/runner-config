#!/usr/bin/env bash
set -euo pipefail

var_file="/tmp/wattsci/vars.sh"

function add_var() {
    local key="$1"
    local value="$2"
    if [[ -f "$VAR_FILE" ]]; then
        grep -v "^${key}=" "$VAR_FILE" > "${VAR_FILE}.tmp" 2>/dev/null || true
        mv "${VAR_FILE}.tmp" "$VAR_FILE"
    fi
    echo "${key}='${value}'" >> "$VAR_FILE"
}

function read_vars() {
    if [ -f "$var_file" ]; then
        source "$var_file"
    fi
}

function initialize_vars() {
    mkdir -p "$(dirname "$var_file")"
    : > "$var_file"
}

