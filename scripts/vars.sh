#!/usr/bin/env bash
set -euo pipefail

var_file="/tmp/wattsci/vars.sh"

function add_var() {
    local key="$1"
    local value="$2"
    echo "${key}='${value}'" >> "$var_file"
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

