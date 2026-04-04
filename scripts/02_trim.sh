#!/bin/bash
# 02_trim.sh -- 3-pass adapter trimming with cutadapt
# Called by L3Rseq dispatcher. Expects conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, ADAPTER_FWD, ADAPTER_REV, ADAPTER_TRIM3, ERROR_RATE

set -euo pipefail

run_step_02() {
    local input_dir="$1"
    local output_dir="$2"
    local adapter_fwd="$3"
    local adapter_rev="$4"
    local adapter_trim3="$5"
    local error_rate="$6"

    mkdir -p "$output_dir/02_trim"

    echo "[Step 02] Trimming fastq files from $input_dir ..."

    for fq in "$input_dir"/*.fastq.gz; do
        [ -f "$fq" ] || continue

        local fname
        fname=$(basename "$fq" .fastq.gz)
        mkdir -p "$output_dir/02_trim/$fname"
        local odir="$output_dir/02_trim/$fname"

        echo "  Processing $fname ..."

        # Pass 1: Discard reads with two 3' adapters in the same direction
        cutadapt --cores=0 --rc -e "$error_rate" --discard-trimmed \
            -g "${adapter_fwd}...${adapter_fwd}" \
            -o "$odir/${fname}_trim1.fastq.gz" \
            "$fq" \
            > "$odir/${fname}_trim1_report.log"

        # Pass 2: Discard reads with two 3' adapters in the opposite direction
        cutadapt --cores=0 --rc -e "$error_rate" --discard-trimmed \
            -g "${adapter_fwd}...${adapter_rev}" \
            -o "$odir/${fname}_trim2.fastq.gz" \
            "$odir/${fname}_trim1.fastq.gz" \
            > "$odir/${fname}_trim2_report.log"

        # Pass 3: Discard reads with no detectable 3' adapter
        cutadapt --cores=0 --action=none -e "$error_rate" --rc --discard-untrimmed \
            -a "$adapter_trim3" \
            -o "$odir/${fname}_trim3.fastq.gz" \
            "$odir/${fname}_trim2.fastq.gz" \
            > "$odir/${fname}_trim3_report.log"

    done

    # Summary: parse trim3 cutadapt report for reads in/out
    for _odir in "$output_dir"/02_trim/*/; do
        [ -d "$_odir" ] || continue
        local _bn
        _bn=$(basename "$_odir")
        local _log="$_odir/${_bn}_trim3_report.log"
        if [ -f "$_log" ]; then
            local _in _out _pct
            _in=$(grep -m1 'Total reads processed' "$_log" | grep -oE '[0-9,]+' | tr -d ',')
            _out=$(grep -m1 'Reads written' "$_log" | grep -oE '[0-9,]+' | head -1 | tr -d ',')
            _pct=$(( _out * 100 / (_in > 0 ? _in : 1) ))
            echo "    $_bn: ${_in:-?} → ${_out:-?} reads after trimming (${_pct}%)"
            _summary_append "$output_dir" "$_bn" "-" "02" "reads_in" "${_in:-0}" || echo "  WARNING: Failed to write summary metric" >&2
            _summary_append "$output_dir" "$_bn" "-" "02" "reads_out" "${_out:-0}" || echo "  WARNING: Failed to write summary metric" >&2
        fi
    done
    echo "[Step 02] Done. Output in $output_dir/02_trim/"
}
