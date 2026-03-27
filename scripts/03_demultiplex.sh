#!/bin/bash
# 03_demultiplex.sh -- RPI barcode demultiplexing with cutadapt
# Called by L3Rseq dispatcher. Expects conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, RPI_FASTA, DEMUX_ERROR_RATE, DEMUX_MIN_OVERLAP

set -euo pipefail

run_step_03() {
    local input_dir="$1"
    local output_dir="$2"
    local rpi_fasta="$3"
    local error_rate="$4"
    local min_overlap="$5"

    mkdir -p "$output_dir/03_demux"

    echo "[Step 03] Demultiplexing trimmed files ..."

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")
        mkdir -p "$output_dir/03_demux/$bname"

        # Determine which RPI fasta to use.
        # If the specified fasta itself follows the barcode-specific naming
        # convention (*_B<num>.fasta), look for sibling files matching other
        # barcodes.  Otherwise, use the specified file for all barcodes.
        local rpi_file="$rpi_fasta"
        local rpi_base_name
        rpi_base_name=$(basename "$rpi_fasta")

        if [[ "$rpi_base_name" =~ _B[0-9]+\.fasta$ ]]; then
            local barcode_num
            barcode_num=$(echo "$bname" | sed -n 's/.*barcode\([0-9]*\).*/\1/p')
            if [ -n "$barcode_num" ]; then
                local rpi_dir
                rpi_dir=$(dirname "$rpi_fasta")
                for candidate in "$rpi_dir"/*_B${barcode_num}.fasta; do
                    if [ -f "$candidate" ]; then
                        rpi_file="$candidate"
                        break
                    fi
                done
            fi
        fi

        echo "  $bname -> using RPI fasta: $(basename "$rpi_file")"

        local trim3_fq="$barcode_dir/${bname}_trim3.fastq.gz"
        if [ ! -f "$trim3_fq" ]; then
            echo "  WARNING: $trim3_fq not found, skipping"
            continue
        fi

        cutadapt --cores=0 --rc --action=none \
            -e "$error_rate" -O "$min_overlap" \
            -a "file:$rpi_file" \
            -o "$output_dir/03_demux/$bname/${bname}_{name}.fastq" \
            "$trim3_fq" \
            --untrimmed-output "$output_dir/03_demux/$bname/${bname}_unclassified.fastq" \
            > "$output_dir/03_demux/$bname/${bname}_demux_report.log"

    done

    # Summary: count RPIs and reads per barcode
    for _ddir in "$output_dir"/03_demux/*/; do
        [ -d "$_ddir" ] || continue
        local _bn
        _bn=$(basename "$_ddir")
        local _nrpi=0 _nunclass=0
        for _rfq in "$_ddir"/${_bn}_RPI_*.fastq; do
            [ -f "$_rfq" ] || continue
            _nrpi=$((_nrpi + 1))
        done
        if [ -f "$_ddir/${_bn}_unclassified.fastq" ]; then
            _nunclass=$(( $(wc -l < "$_ddir/${_bn}_unclassified.fastq") / 4 ))
        fi
        echo "    $_bn: $_nrpi RPIs assigned, $_nunclass unclassified"
        _summary_append "$output_dir" "$_bn" "-" "03" "rpis_assigned" "$_nrpi" 2>/dev/null || true
        _summary_append "$output_dir" "$_bn" "-" "03" "unclassified" "$_nunclass" 2>/dev/null || true
    done
    echo "[Step 03] Done. Output in $output_dir/03_demux/"
}
