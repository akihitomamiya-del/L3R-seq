#!/bin/bash
# 08_variants.sh -- Variant calling with LoFreq + bcftools filtering
# Called by L3Rseq dispatcher. Expects LoFreq conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, REF_FILE, MIN_AF, PATTERN

set -euo pipefail

run_step_08() {
    local input_dir="$1"
    local output_dir="$2"
    local ref_file="$3"
    local min_af="$4"
    local pattern="$5"

    mkdir -p "$output_dir/08_variants"

    # Build the bcftools grep pattern from the editing pattern
    # e.g. "CT" -> grep for lines where REF=C and ALT=T -> pattern "C.*T" in cols 4,5
    local ref_base="${pattern:0:1}"
    local alt_base="${pattern:1:1}"

    echo "[Step 08] Calling variants (pattern: ${ref_base}>${alt_base}) ..."

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            local sort_bam="$rpi_dir/aligned.sort.bam"
            if [ ! -f "$sort_bam" ]; then
                echo "  WARNING: No aligned.sort.bam in $bname/$rpi_name, skipping (run step 07 first)"
                continue
            fi

            echo "  Processing $bname / $rpi_name ..."
            mkdir -p "$output_dir/08_variants/$bname/$rpi_name"
            local odir="$output_dir/08_variants/$bname/$rpi_name"

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
                grep -E "[0-9]+${ref_base}${alt_base}" \
                > "$odir/observed_variants.txt" || true

        done
    done

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
            echo "    $_bname/$_rname: $_nvar ${ref_base}>${alt_base} variant positions"
            _summary_append "$output_dir" "$_bname" "$_rname" "08" "variant_positions" "$_nvar" 2>/dev/null || true
        fi
    done
    echo "[Step 08] Done. Output in $output_dir/08_variants/"
}
