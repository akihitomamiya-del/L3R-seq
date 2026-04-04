#!/bin/bash
# 08_variants.sh -- Variant calling with LoFreq + bcftools filtering
# Called by L3Rseq dispatcher. Expects LoFreq conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, REF_FILE, MIN_AF, PATTERN

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_process_sample_08() {
    local bname="$1" rpi_name="$2" rpi_dir="$3"
    local output_dir="$4" ref_file="$5" min_af="$6" _var_regex="$7" _pattern_label="$8"

    local sort_bam="$rpi_dir/${rpi_name}_aligned.sort.bam"
    require_input "$sort_bam" "$bname" "$rpi_name" "07" || return 0

    echo "  Processing $bname / $rpi_name ..."
    local odir="$output_dir/08_variants/$bname/$rpi_name"
    mkdir -p "$odir"

    # Call variants with LoFreq
    if ! lofreq call -f "$ref_file" \
        -o "$odir/variants.vcf" \
        "$sort_bam" 2>/dev/null; then
        echo "  ERROR: lofreq failed for $bname/$rpi_name" >&2
        return 1
    fi

    # Filter for the specified editing pattern
    bcftools view --no-header -i "AF > $min_af" "$odir/variants.vcf" | \
        awk '{print $2 $4 $5}' | \
        grep -E "$_var_regex" \
        > "$odir/observed_variants.txt" || true
}

run_step_08() {
    local input_dir="$1"
    local output_dir="$2"
    local ref_file="$3"
    local min_af="$4"
    local pattern="$5"

    mkdir -p "$output_dir/08_variants"

    # Build grep regex from editing pattern(s) (supports comma-separated, e.g. "CT,AG")
    local _var_regex=""
    local _pattern_label=""
    IFS=',' read -ra _patterns <<< "$pattern"
    for _p in "${_patterns[@]}"; do
        _p="${_p// /}"
        local _rb="${_p:0:1}" _ab="${_p:1:1}"
        [ -n "$_var_regex" ] && _var_regex="${_var_regex}|"
        _var_regex="${_var_regex}[0-9]+${_rb}${_ab}"
        [ -n "$_pattern_label" ] && _pattern_label="${_pattern_label}, "
        _pattern_label="${_pattern_label}${_rb}>${_ab}"
    done

    echo "[Step 08] Calling variants (pattern: ${_pattern_label}) ..."

    iterate_samples "$input_dir" _process_sample_08 \
        "$output_dir" "$ref_file" "$min_af" "$_var_regex" "$_pattern_label"

    # Summary: variant position counts
    for _vdir in "$output_dir"/08_variants/*/*; do
        [ -d "$_vdir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_vdir")")
        _rname=$(basename "$_vdir")
        local _vf="$_vdir/observed_variants.txt"
        if [ -f "$_vf" ]; then
            local _nvar
            _nvar=$(wc -l < "$_vf")
            echo "    $_bname/$_rname: $_nvar ${_pattern_label} variant positions"
            _summary_append "$output_dir" "$_bname" "$_rname" "08" "variant_positions" "$_nvar" || echo "  WARNING: Failed to write summary metric" >&2
        fi
    done
    echo "[Step 08] Done. Output in $output_dir/08_variants/"
}
