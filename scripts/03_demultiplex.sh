#!/bin/bash
# 03_demultiplex.sh -- RPI barcode demultiplexing with cutadapt
# Called by L3Rseq dispatcher. Expects conda env already activated.
# Requires: INPUT_DIR, OUTPUT_DIR, RPI_FASTA, DEMUX_ERROR_RATE, DEMUX_MIN_OVERLAP
# Optional: DROP_AMBIGUOUS (1 = move reads that match two RPIs equally well to
#           <barcode>_unclassified_ambiguous.fastq; default 0)

set -euo pipefail

# Two RPIs can both match one read when their edit distance is at most the sum
# of their allowed errors (with -e 1: 2 edits; the 36-RPI set has 12 such pairs,
# e.g. RPI_1/RPI_9). cutadapt then gives the read to whichever RPI comes first in
# the FASTA, without warning. For every RPI with such a partner, scan its reads
# against the partners and move the ones that match out of the RPI's file.
_drop_ambiguous_03() {
    local ddir="$1" bname="$2" rpi_file="$3" error_rate="$4" min_overlap="$5"
    local amb_fq="$ddir/${bname}_unclassified_ambiguous.fastq"
    local report="$ddir/${bname}_ambiguous_report.tsv"
    local tmp
    tmp=$(mktemp -d)

    : > "$amb_fq"
    printf 'rpi\tpartners\treads_in\tambiguous\tkept\n' > "$report"

    # One line "<rpi>\t<partner,...>" per RPI with a close partner, plus
    # $tmp/<rpi>.partners.fasta holding those partners.
    python3 - "$rpi_file" "$error_rate" "$tmp" > "$tmp/partners.tsv" <<'PY'
import sys

path, rate, outdir = sys.argv[1], float(sys.argv[2]), sys.argv[3]
seqs = {}
name = None
for line in open(path):
    line = line.strip()
    if not line:
        continue
    if line.startswith(">"):
        name = line[1:].split()[0]
        seqs[name] = ""
    else:
        seqs[name] += line.upper()


def max_errors(seq):
    # cutadapt: -e >= 1 is an absolute count, otherwise a rate over the match
    return int(rate) if rate >= 1 else int(rate * len(seq))


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


for x, sx in seqs.items():
    partners = [y for y, sy in seqs.items()
                if y != x and edit_distance(sx, sy) <= max_errors(sx) + max_errors(sy)]
    if partners:
        with open(f"{outdir}/{x}.partners.fasta", "w") as fh:
            fh.writelines(f">{y}\n{seqs[y]}\n" for y in partners)
        print(f"{x}\t{','.join(partners)}")
PY

    local rpi partners fq n_in n_amb
    while IFS=$'\t' read -r rpi partners; do
        fq="$ddir/${bname}_${rpi}.fastq"
        [ -s "$fq" ] || continue
        # No --rc: step 03 wrote every read in the orientation its RPI matched
        # in, so a partner at the same barcode position matches forward too.
        cutadapt --cores=0 --action=none -e "$error_rate" -O "$min_overlap" \
            -a "file:$tmp/$rpi.partners.fasta" \
            -o "$tmp/ambiguous.fastq" \
            --untrimmed-output "$tmp/kept.fastq" \
            "$fq" > "$tmp/cutadapt.log"
        n_in=$(( $(wc -l < "$fq") / 4 ))
        n_amb=$(( $(wc -l < "$tmp/ambiguous.fastq") / 4 ))
        cat "$tmp/ambiguous.fastq" >> "$amb_fq"
        mv "$tmp/kept.fastq" "$fq"
        printf '%s\t%s\t%d\t%d\t%d\n' "$rpi" "$partners" "$n_in" "$n_amb" "$(( n_in - n_amb ))" >> "$report"
    done < "$tmp/partners.tsv"

    rm -rf "$tmp"
}

run_step_03() {
    local input_dir="$1"
    local output_dir="$2"
    local rpi_fasta="$3"
    local error_rate="$4"
    local min_overlap="$5"
    local drop_ambiguous="${6:-0}"

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

        if [ "$drop_ambiguous" = "1" ]; then
            _drop_ambiguous_03 "$output_dir/03_demux/$bname" "$bname" "$rpi_file" "$error_rate" "$min_overlap"
        fi
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
        _summary_append "$output_dir" "$_bn" "-" "03" "rpis_assigned" "$_nrpi" || echo "  WARNING: Failed to write summary metric" >&2
        _summary_append "$output_dir" "$_bn" "-" "03" "unclassified" "$_nunclass" || echo "  WARNING: Failed to write summary metric" >&2
        if [ "$drop_ambiguous" = "1" ]; then
            local _namb=0
            if [ -f "$_ddir/${_bn}_unclassified_ambiguous.fastq" ]; then
                _namb=$(( $(wc -l < "$_ddir/${_bn}_unclassified_ambiguous.fastq") / 4 ))
            fi
            echo "    $_bn: $_namb ambiguous (matched two RPIs; see ${_bn}_ambiguous_report.tsv)"
            _summary_append "$output_dir" "$_bn" "-" "03" "ambiguous" "$_namb" || echo "  WARNING: Failed to write summary metric" >&2
        fi
    done
    echo "[Step 03] Done. Output in $output_dir/03_demux/"
}
