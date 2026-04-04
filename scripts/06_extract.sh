#!/bin/bash
# 06_extract.sh -- Target region extraction with cutadapt
# Called by L3Rseq dispatcher. Expects cutadaptenv conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, TARGET_FWD, TARGET_REV, ERROR_RATE, MIN_OVERLAP

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_process_sample_06() {
    local bname="$1" rpi_name="$2" rpi_dir="$3"
    local output_dir="$4" target_fwd="$5" target_rev="$6" error_rate="$7" min_overlap="$8"

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
        return 0
    fi

    echo "  Processing $bname / $rpi_name ..."
    local odir="$output_dir/06_extract/$bname/$rpi_name"
    mkdir -p "$odir"

    local prefix="${rpi_name}_"

    if [ -n "$target_fwd" ]; then
        # Linked adapter: both forward and reverse primers required
        local adapter_spec="^${target_fwd}...${target_rev};min_overlap=${min_overlap}"

        # Extract with adapters retained (uncut)
        cutadapt --cores=0 --action=none --rc -e "$error_rate" --discard-untrimmed \
            -g "$adapter_spec" \
            -o "$odir/${prefix}extracted_uncut.fa" \
            "$consensus_fa" \
            > "$odir/${prefix}extracted_uncut.log"

        # Extract with adapters trimmed
        cutadapt --cores=0 --rc -e "$error_rate" --discard-untrimmed \
            -g "$adapter_spec" \
            -o "$odir/${prefix}extracted_trimmed.fa" \
            "$consensus_fa" \
            > "$odir/${prefix}extracted_trimmed.log"
    else
        # No forward primer: trim only the reverse (adapter) side.
        # All consensus reads are kept (no --discard-untrimmed).
        echo "    (no forward primer — trimming reverse adapter only)"

        cp "$consensus_fa" "$odir/${prefix}extracted_uncut.fa"

        cutadapt --cores=0 --rc -e "$error_rate" \
            -a "${target_rev}" \
            -o "$odir/${prefix}extracted_trimmed.fa" \
            "$consensus_fa" \
            > "$odir/${prefix}extracted_trimmed.log"
    fi
}

run_step_06() {
    local input_dir="$1"
    local output_dir="$2"
    local target_fwd="$3"
    local target_rev="$4"
    local error_rate="$5"
    local min_overlap="$6"

    mkdir -p "$output_dir/06_extract"

    echo "[Step 06] Extracting target region ..."

    iterate_samples "$input_dir" _process_sample_06 \
        "$output_dir" "$target_fwd" "$target_rev" "$error_rate" "$min_overlap"

    # Summary: count extracted sequences per RPI
    for _edir in "$output_dir"/06_extract/*/*; do
        [ -d "$_edir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_edir")")
        _rname=$(basename "$_edir")
        local _rpi_prefix="${_rname}_"
        if [ -f "$_edir/${_rpi_prefix}extracted_trimmed.fa" ]; then
            local _n
            _n=$(grep -c '^>' "$_edir/${_rpi_prefix}extracted_trimmed.fa" || true)
            echo "    $_bname/$_rname: $_n extracted"
            _summary_append "$output_dir" "$_bname" "$_rname" "06" "extracted_seqs" "$_n" || echo "  WARNING: Failed to write summary metric" >&2
        fi
    done
    echo "[Step 06] Done. Output in $output_dir/06_extract/"
}
