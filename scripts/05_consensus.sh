#!/bin/bash
# 05_consensus.sh -- Racon-based consensus calling via longread_umi
# Called by L3Rseq dispatcher. Expects longread_umi conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, THREADS, ROUNDS, PRESET
# Optional: KEEP_INTERMEDIATES (0=clean per-bin dirs after consensus, 1=keep all)

set -euo pipefail

run_step_05() {
    local input_dir="$1"
    local output_dir="$2"
    local threads="$3"
    local rounds="$4"
    local preset="$5"
    local keep_intermediates="${6:-0}"

    mkdir -p "$output_dir/05_consensus"

    echo "[Step 05] Generating consensus sequences ..."
    local _step05_count=0

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            local _cons_dir="$output_dir/05_consensus/$bname/$rpi_name"

            # Resume support: skip RPIs that already completed.
            # Checked BEFORE UMIclusterfull — after cleanup, UMIclusterfull
            # is gone but .done proves the consensus FASTA was already built.
            if [ -f "$_cons_dir/.done" ]; then
                echo "  Skipping $bname / $rpi_name (already complete)"
                continue
            fi

            local cluster_dir="$rpi_dir/UMIclusterfull"
            if [ ! -d "$cluster_dir" ]; then
                echo "  WARNING: No UMIclusterfull directory in $bname/$rpi_name, skipping (run step 04 first)"
                continue
            fi

            # Clean up any partial output from an interrupted run
            rm -rf "$_cons_dir"

            _step05_count=$((_step05_count + 1))
            echo "  Processing $bname / $rpi_name ..."
            mkdir -p "$output_dir/05_consensus/$bname"

            longread_umi consensus_racon \
                -d "$cluster_dir" \
                -o "$_cons_dir" \
                -t "$threads" \
                -r "$rounds" \
                -p "$preset"

            # Cleanup per-bin intermediates (ovlp.paf, *_centroids.fa, per-bin dirs)
            # The merged consensus_*.fa is the only output needed by step 06.
            if [ "$keep_intermediates" -eq 0 ]; then
                find "$_cons_dir" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
            fi

            # Mark complete AFTER cleanup — this is the resume marker.
            touch "$_cons_dir/.done"

        done
    done

    if [ "$_step05_count" -eq 0 ]; then
        echo "  WARNING: No UMI bins found in $input_dir. Check step 04 output." >&2
    fi

    # Summary: count consensus sequences per RPI
    for _cdir in "$output_dir"/05_consensus/*/*; do
        [ -d "$_cdir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_cdir")")
        _rname=$(basename "$_cdir")
        local _fa
        _fa=$(find "$_cdir" -maxdepth 1 -name 'consensus_*.fa' 2>/dev/null | head -1)
        if [ -n "$_fa" ] && [ -f "$_fa" ]; then
            local _ncons
            _ncons=$(grep -c '^>' "$_fa")
            echo "    $_bname/$_rname: $_ncons consensus sequences"
            _summary_append "$output_dir" "$_bname" "$_rname" "05" "consensus_seqs" "$_ncons" 2>/dev/null || true
        fi
    done
    echo "[Step 05] Done. Output in $output_dir/05_consensus/"
}
