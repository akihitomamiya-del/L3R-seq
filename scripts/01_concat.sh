#!/bin/bash
# 01_concat.sh -- Concatenate per-barcode fastq.gz files
# Called by L3Rseq dispatcher. Expects: INPUT_DIR, OUTPUT_DIR, PREFIX (optional)
# No conda environment needed.

set -euo pipefail

run_step_01() {
    local input_dir="$1"
    local output_dir="$2"
    local prefix="${3:-}"

    mkdir -p "$output_dir/01_concat"

    echo "[Step 01] Concatenating fastq.gz files from $input_dir ..."

    ls -1 "$input_dir" | while read -r barcode_dir; do
        [ -d "$input_dir/$barcode_dir" ] || continue

        local n_files
        n_files=$(ls "$input_dir/$barcode_dir"/*fastq.gz 2>/dev/null | wc -l)
        echo "  $barcode_dir: $n_files fastq.gz files"

        local out_name
        if [ -n "$prefix" ]; then
            out_name="${prefix}_${barcode_dir}"
        else
            out_name="$barcode_dir"
        fi

        cat "$input_dir/$barcode_dir"/*fastq.gz \
            > "$output_dir/01_concat/${out_name}.fastq.gz"

    done

    echo "[Step 01] Done. Output in $output_dir/01_concat/"

    # Summary: count reads per barcode
    for _fq in "$output_dir"/01_concat/*.fastq.gz; do
        [ -f "$_fq" ] || continue
        local _bn
        _bn=$(basename "$_fq" .fastq.gz)
        local _nreads
        _nreads=$(gzip -dc "$_fq" | awk 'NR%4==1' | wc -l)
        local _size
        _size=$(du -h "$_fq" | cut -f1)
        echo "    $_bn: $_nreads reads ($_size)"
        _summary_append "$output_dir" "$_bn" "-" "01" "reads" "$_nreads" || echo "  WARNING: Failed to write summary metric" >&2
    done
}
