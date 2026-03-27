#!/bin/bash
# 07_map.sh -- Mapping to reference with minimap2 + samtools
# Called by L3Rseq dispatcher. Expects NanoporeMap conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, REF_FILE, PRESET

set -euo pipefail

## Sanitize a FASTA reference: strip \r, ensure trailing newline, wrap long
## lines to 80 chars, and regenerate .fai if the FASTA was modified.
sanitize_fasta() {
    local fa="$1"
    [ -f "$fa" ] || return 0
    local dirty=0

    # Check for \r (Windows line endings) or lines > 80 chars in sequence
    if grep -q $'\r' "$fa" 2>/dev/null; then
        sed 's/\r//g' "$fa" > "${fa}.tmp" && mv "${fa}.tmp" "$fa"
        dirty=1
        echo "  Fixed \\r line endings in $(basename "$fa")"
    fi

    # Ensure trailing newline
    if [ "$(tail -c 1 "$fa" | wc -l)" -eq 0 ]; then
        echo "" >> "$fa"
        dirty=1
        echo "  Added trailing newline to $(basename "$fa")"
    fi

    # Wrap sequence lines longer than 80 chars
    if awk '/^[^>]/ && length > 80 { exit 0 } END { exit 1 }' "$fa"; then
        local tmp="${fa}.rewrap.tmp"
        awk '/^>/ { print; next }
             { for (i=1; i<=length; i+=80) print substr($0, i, 80) }' "$fa" > "$tmp"
        mv "$tmp" "$fa"
        dirty=1
        echo "  Rewrapped long sequence lines in $(basename "$fa")"
    fi

    # Regenerate .fai if FASTA was modified or .fai is missing/stale
    if [ "$dirty" -eq 1 ] || [ ! -f "${fa}.fai" ] || [ "$fa" -nt "${fa}.fai" ]; then
        samtools faidx "$fa"
        echo "  Regenerated $(basename "${fa}.fai")"
    fi
}

run_step_07() {
    local input_dir="$1"
    local output_dir="$2"
    local ref_file="$3"
    local preset="$4"

    mkdir -p "$output_dir/07_map"

    echo "[Step 07] Mapping to reference ..."

    # Sanitize reference FASTA before use
    sanitize_fasta "$ref_file"

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            local input_fa="$rpi_dir/extracted_trimmed.fa"
            if [ ! -f "$input_fa" ]; then
                echo "  WARNING: No extracted_trimmed.fa in $bname/$rpi_name, skipping (run step 06 first)"
                continue
            fi

            echo "  Processing $bname / $rpi_name ..."
            mkdir -p "$output_dir/07_map/$bname/$rpi_name"
            local odir="$output_dir/07_map/$bname/$rpi_name"

            # Align with minimap2
            if ! minimap2 -ax "$preset" "$ref_file" "$input_fa" \
                > "$odir/aligned.sam" \
                2> "$odir/aligned.minimap2.log"; then
                echo "  ERROR: minimap2 failed for $bname/$rpi_name (see $odir/aligned.minimap2.log)" >&2
                return 1
            fi

            # Flagstat on all reads
            samtools flagstat "$odir/aligned.sam" > "$odir/aligned.flagstat.txt"

            # Convert to sorted BAM + index
            samtools view -bS "$odir/aligned.sam" > "$odir/aligned.bam"
            samtools sort "$odir/aligned.bam" > "$odir/aligned.sort.bam"
            samtools index "$odir/aligned.sort.bam"

            # Extract mapped-only reads
            samtools view -h -F 4 "$odir/aligned.sam" > "$odir/mapped_only.sam"
            samtools flagstat "$odir/mapped_only.sam" > "$odir/mapped_only.flagstat.txt"

        done
    done

    # Summary: mapped read counts from flagstat
    for _mdir in "$output_dir"/07_map/*/*; do
        [ -d "$_mdir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_mdir")")
        _rname=$(basename "$_mdir")
        local _fs="$_mdir/mapped_only.flagstat.txt"
        if [ -f "$_fs" ]; then
            local _mapped
            _mapped=$(head -1 "$_fs" | awk '{print $1}')
            echo "    $_bname/$_rname: $_mapped mapped"
            _summary_append "$output_dir" "$_bname" "$_rname" "07" "mapped_reads" "$_mapped" 2>/dev/null || true
        fi
    done
    echo "[Step 07] Done. Output in $output_dir/07_map/"
}
