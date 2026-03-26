#!/bin/bash
# 06_extract.sh -- Target region extraction with cutadapt
# Called by L3Rseq dispatcher. Expects cutadaptenv conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, TARGET_FWD, TARGET_REV, ERROR_RATE, MIN_OVERLAP

set -euo pipefail

run_step_06() {
    local input_dir="$1"
    local output_dir="$2"
    local target_fwd="$3"
    local target_rev="$4"
    local error_rate="$5"
    local min_overlap="$6"

    mkdir -p "$output_dir/06_extract"

    echo "[Step 06] Extracting target region ..."

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            # Find consensus fasta -- longread_umi outputs consensus_*.fa
            local consensus_fa=""
            for f in "$rpi_dir"/consensus_*.fa "$rpi_dir"/consensus.fa; do
                if [ -f "$f" ]; then
                    consensus_fa="$f"
                    break
                fi
            done

            if [ -z "$consensus_fa" ]; then
                echo "  WARNING: No consensus fasta in $bname/$rpi_name, skipping (run step 05 first)"
                continue
            fi

            echo "  Processing $bname / $rpi_name ..."
            mkdir -p "$output_dir/06_extract/$bname/$rpi_name"
            local odir="$output_dir/06_extract/$bname/$rpi_name"

            # Extract with adapters retained (uncut)
            cutadapt --cores=0 --action=none --rc -e "$error_rate" --discard-untrimmed \
                -g "^${target_fwd}...${target_rev};min_overlap=${min_overlap}" \
                -o "$odir/extracted_uncut.fa" \
                "$consensus_fa" \
                > "$odir/extracted_uncut.log"

            # Extract with adapters trimmed
            cutadapt --cores=0 --rc -e "$error_rate" --discard-untrimmed \
                -g "^${target_fwd}...${target_rev};min_overlap=${min_overlap}" \
                -o "$odir/extracted_trimmed.fa" \
                "$consensus_fa" \
                > "$odir/extracted_trimmed.log"

        done
    done

    # Summary: count extracted sequences per RPI
    for _edir in "$output_dir"/06_extract/*/*; do
        [ -d "$_edir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_edir")")
        _rname=$(basename "$_edir")
        if [ -f "$_edir/extracted_trimmed.fa" ]; then
            local _n
            _n=$(grep -c '^>' "$_edir/extracted_trimmed.fa")
            echo "    $_bname/$_rname: $_n extracted"
            _summary_append "$output_dir" "$_bname" "$_rname" "06" "extracted_seqs" "$_n" 2>/dev/null || true
        fi
    done
    echo "[Step 06] Done. Output in $output_dir/06_extract/"
}
