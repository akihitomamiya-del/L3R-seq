#!/usr/bin/env bash
# lib.sh — Shared utilities for L3Rseq pipeline scripts.
#
# Source from step scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Iterate barcode/RPI directories (2-level: barcode → RPI).
# Behavior-identical to the existing nested for-loops in steps 05-11.
# Calls: callback bname rpi_name rpi_dir [extra_args...]
# The callback should `return 0` to skip (replaces `continue` in a loop).
#
# Future: add --flat / --no-rpi modes here to support non-standard barcoding.
iterate_samples() {
    local input_dir="$1"; shift
    local callback="$1"; shift
    local bname rpi_name
    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue
        bname=$(basename "$barcode_dir")
        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue
            rpi_name=$(basename "$rpi_dir")
            "$callback" "$bname" "$rpi_name" "$rpi_dir" "$@" || true
        done
    done
}

# Check a prerequisite file or directory exists. Returns 1 with warning if missing.
# Usage: require_input "$file" "$bname" "$rpi" "step_hint" || return 0
require_input() {
    local file="$1" bname="$2" rpi="$3" step_hint="$4"
    if [ ! -f "$file" ] && [ ! -d "$file" ]; then
        echo "  WARNING: Missing $(basename "$file") in $bname/$rpi, skipping (run step $step_hint first)"
        return 1
    fi
}

# Step logging helpers.
log_step_start() { echo "[Step $1] $2 ..."; }
log_step_done()  { echo "[Step $1] Done. Output in $3"; }
