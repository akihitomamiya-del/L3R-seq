#!/bin/bash
# filter.sh -- Pre-filter reads by rough mapping (optional)
# Called by L3Rseq dispatcher. Expects NanoporeMap conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, REF_FILE, MAP_PRESET

set -euo pipefail

run_step_filter() {
    local input_dir="$1"
    local output_dir="$2"
    local ref_file="$3"
    local preset="${4:-lr:hq}"

    mkdir -p "$output_dir/filter"

    echo "[Filter] Pre-filtering reads by mapping to reference ..."

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")
        mkdir -p "$output_dir/filter/$bname"

        local total=0
        local mapped=0

        for fq in "$barcode_dir"/*.fastq; do
            [ -f "$fq" ] || continue
            local fname
            fname=$(basename "$fq")

            # Skip unclassified
            [[ "$fname" == *"unclassified"* ]] && continue

            # Skip empty files (e.g. RPIs with no assigned reads)
            [ ! -s "$fq" ] && continue

            local count_before
            count_before=$(( $(wc -l < "$fq") / 4 ))
            total=$((total + count_before))

            # Map with minimap2, extract mapped reads, convert back to fastq
            local tmp_sam
            tmp_sam=$(mktemp)
            trap 'rm -f "$tmp_sam"' EXIT

            minimap2 -ax "$preset" "$ref_file" "$fq" 2>/dev/null > "$tmp_sam"

            # Extract mapped reads as fastq
            samtools fastq -F 4 "$tmp_sam" > "$output_dir/filter/$bname/$fname" 2>/dev/null

            local count_after
            count_after=$(( $(wc -l < "$output_dir/filter/$bname/$fname") / 4 ))
            mapped=$((mapped + count_after))

            rm -f "$tmp_sam"
            trap - EXIT
        done

        echo "  $bname: $mapped / $total reads mapped (on-target)" \
            > "$output_dir/filter/$bname/${bname}_filter_report.log"
        echo "  $bname: $mapped / $total reads on-target"

    done

    echo "[Filter] Done. Output in $output_dir/filter/"
}
