#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"

OUTPUT_DIR="/tmp/wattsci"
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
WATTSCI_OUTPUT_FILE="$OUTPUT_DIR/perf-data.txt"
INTERVAL_MS=1000
REQUESTED_EVENTS=()

function show_usage() {
    echo "Usage:"
    echo "  $0 events=<event1,event2,...> interval=<ms>"
    exit 1
}

function setup_output_dir() {
    mkdir -p "$OUTPUT_DIR"
}

function parse_arguments() {
    if [[ $# -lt 1 ]]; then
        echo "[ERROR] No arguments specified."
        show_usage
    fi

    for arg in "$@"; do
        case "$arg" in
            interval=*)
                INTERVAL_MS="${arg#interval=}"
                ;;
            events=*)
                IFS=',' read -r -a REQUESTED_EVENTS <<< "${arg#events=}"
                ;;
            *)
                echo "[ERROR] Unknown argument: $arg"
                show_usage
                ;;
        esac
    done

    if [[ ${#REQUESTED_EVENTS[@]} -eq 0 ]]; then
        echo "[ERROR] No perf events specified."
        show_usage
    fi
}

function check_perf_paranoid() {
    local PERF_PARANOID
    PERF_PARANOID=$(< /proc/sys/kernel/perf_event_paranoid)
    if [[ "$PERF_PARANOID" -gt 1 ]]; then
        echo "[WARNING] perf_event_paranoid is set to $PERF_PARANOID"
        echo "[WARNING] Consider: sudo sysctl -w kernel.perf_event_paranoid=-1"
        echo "[WARNING] And: sudo modprobe msr"
    fi
}

function get_available_events() {
    mapfile -t AVAILABLE_EVENTS < <(perf list | grep -E '^ *power/energy-[^ ]+/' | awk '{print $1}')
}

function validate_events() {
    VALID_EVENTS=()
    INVALID_EVENTS=()

    for evt in "${REQUESTED_EVENTS[@]}"; do
        if printf '%s\n' "${AVAILABLE_EVENTS[@]}" | grep -Fxq "$evt"; then
            VALID_EVENTS+=("$evt")
        else
            INVALID_EVENTS+=("$evt")
        fi
    done

    if (( ${#VALID_EVENTS[@]} == 0 )); then
        echo "[ERROR] None of the specified events are available on this machine."
        echo "[INFO] Available energy-related perf events:"
        for evt in "${AVAILABLE_EVENTS[@]}"; do
            echo "  - $evt"
        done
        exit 1
    fi

    if (( ${#INVALID_EVENTS[@]} > 0 )); then
        echo "[WARNING] The following events are not available and will be ignored:"
        for evt in "${INVALID_EVENTS[@]}"; do
            echo "  - $evt"
        done
    fi
}

function run_perf() {
    echo "[INFO] Measuring perf energy usage with sampling interval ${INTERVAL_MS}ms..."
    echo "[INFO] Events requested: ${VALID_EVENTS[*]}"

    add_var "PERF_INTERVAL_MS" "$INTERVAL_MS"
    add_var "PERF_EVENTS" "${VALID_EVENTS[*]}"
    add_var "WATTSCI_OUTPUT_FILE" "$WATTSCI_OUTPUT_FILE"

    LC_NUMERIC=C perf stat -a -I "$INTERVAL_MS" -e "$(IFS=','; echo "${VALID_EVENTS[*]}")" 2> "$WATTSCI_OUTPUT_FILE"

    echo "[INFO] Measurement complete. Output saved to: $WATTSCI_OUTPUT_FILE"
}

function main() {
    setup_output_dir
    parse_arguments "$@"
    check_perf_paranoid
    get_available_events
    validate_events
    run_perf
}

main "$@"
