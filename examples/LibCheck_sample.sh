#!/bin/bash
# examples/LibCheck_sample.sh — L3Rseq analysis of LibCheck_sample data (BAI981)
#
# Processes the real Oxford Nanopore data in LibCheck_sample/ (barcode44,
# barcode45, barcode46) through the full L3Rseq pipeline.
#
# Sample: MpPHT1_atp9 (Marchantia polymorpha, library check 260118)
# Flow cell: BAI981  |  Basecaller: dna_r10.4.1_e8.2_400bps_sup@v5.2.0
#
# HOW TO USE:
#   1. Set REF to your target gene reference FASTA (see below)
#   2. Set TARGET_FWD to your gene-specific forward primer
#   3. Optionally adjust RPIS to select specific samples
#   4. Run:  cd /workspace && bash examples/LibCheck_sample.sh
#
# The script runs in two phases:
#   Phase 1 (steps 01-03): concat, trim, demux — runs immediately, no ref needed
#   Phase 2 (steps 04-10): UMI → consensus → map → export — requires REF

set -euo pipefail

# ============================================================================
# YOUR EXPERIMENT — Change these values to match your data
# ============================================================================

# Input: LibCheck_sample/ already contains barcode44/, barcode45/, barcode46/
# in the correct directory structure for step 01.
INPUT_DIR="LibCheck_sample"

# Output directory for all pipeline results
OUTDIR="runs/LibCheck"

# Reference FASTA — genomic DNA sequence of your target gene + downstream.
# This is required for steps 07-10 (mapping, variant calling, correction).
#   Example: REF="refs/MpPHT1_atp9_genomic.fasta"
# If you only have the full genome, you can use it but a gene-specific
# reference is strongly recommended for variant calling accuracy:
#   REF="resources/references/MpTak_v7.1.fa"
REF="resources/references/MpTak_v7.1.fa"

# RPI barcode FASTA — 36 standard 20nt RPI barcodes
RPI_FASTA="resources/rpi_barcodes/RPI_Barcode_20nt_Takehira.fasta"

# Which RPIs to keep after demux (space-separated numbers).
# Set to "" to process ALL RPIs found.
RPIS="1 2 3 4 5 6 7 8 9 10 11 12"

# Forward target primer — gene-specific primer used in your library prep.
# Used by step 06 (extract) to trim consensus reads to the gene insert.
# NNNN = IUPAC wildcard, matches any sequence at the 5' end. This keeps
# all reads and lets the reverse adapter do the trimming/filtering.
# Replace with your actual forward primer for stricter target selection.
TARGET_FWD=""


# UMI extraction method (longread-umi uses flanking-sequence extraction)
METHOD="longread-umi"

THREADS=$(nproc 2>/dev/null || echo 4)

# ============================================================================
# PIPELINE — You should not need to change anything below this line
# ============================================================================

echo "========================================"
echo "L3Rseq — LibCheck_sample analysis"
echo "  Input:   $INPUT_DIR (barcode44, barcode45, barcode46)"
echo "  Output:  $OUTDIR"
echo "  Method:  $METHOD"
echo "  RPIs:    ${RPIS:-all}"
echo "========================================"

# Build common arguments
ARGS=(
    --method "$METHOD"
    --threads "$THREADS"
)
[ -n "$REF" ]           && ARGS+=(--ref "$REF")
if [ -n "$TARGET_FWD" ]; then
    ARGS+=(--target-fwd "$TARGET_FWD")
else
    ARGS+=(--no-target-fwd)
fi

# ---- Phase 1: Steps 01-03 (no reference needed) ----------------------------

echo ""
echo "=== Phase 1: Preprocessing (steps 01-03) ==="
echo ""

L3Rseq run --input "$INPUT_DIR" --outdir "$OUTDIR" \
    --rpi-fasta "$RPI_FASTA" "${ARGS[@]}" --stop-at 3

# ---- Filter RPIs (optional) ------------------------------------------------

if [ -n "$RPIS" ]; then
    echo ""
    echo "Filtering to RPIs: $RPIS"
    for bc_dir in "$OUTDIR"/03_demux/*/; do
        [ -d "$bc_dir" ] || continue
        bc=$(basename "$bc_dir")
        mkdir -p "$OUTDIR/03_demux_all"
        mv "$OUTDIR/03_demux/$bc" "$OUTDIR/03_demux_all/$bc"
        mkdir -p "$OUTDIR/03_demux/$bc"
        for rpi in $RPIS; do
            src="$(pwd)/$OUTDIR/03_demux_all/$bc/${bc}_RPI_${rpi}.fastq"
            if [ -f "$src" ]; then
                ln -sf "$src" "$OUTDIR/03_demux/$bc/"
            else
                echo "  WARNING: $bc / RPI $rpi not found" >&2
            fi
        done
    done
fi

# ---- Phase 2: Steps 04-07 (requires REF) -----------------------------------

if [ -z "$REF" ]; then
    echo ""
    echo "========================================"
    echo "Phase 1 complete. Preprocessed data is in:"
    echo "  $OUTDIR/01_concat/   (concatenated reads)"
    echo "  $OUTDIR/02_trim/     (adapter-trimmed reads)"
    echo "  $OUTDIR/03_demux/    (RPI-demultiplexed reads)"
    echo ""
    echo "To continue with steps 04-07, set REF in this script"
    echo "and run again (or use --start-at 4)."
    echo "========================================"
    exit 0
fi

echo ""
echo "=== Phase 2: Core pipeline (steps 04-07) ==="
echo ""

L3Rseq run --input "$OUTDIR" --outdir "$OUTDIR" "${ARGS[@]}" --start-at 4 --stop-at 7

# ---- Done -------------------------------------------------------------------

# ---- Phase 3: Gene-level counting ------------------------------------------

# Auto-discover gene regions from mapped reads + GFF annotation.
# Requires a GFF3 file for the reference genome.
GFF="resources/references/MpTak_v7.1.gff3"

if [ -f "$GFF" ] && [ -d "$OUTDIR/07_map" ]; then
    echo ""
    echo "=== Phase 3: Gene-level counting ==="
    echo ""

    # Discover which genes have mapped reads (min 5 reads to filter noise)
    L3Rseq regions --gff "$GFF" --discover-from "$OUTDIR" \
        --min-reads 5 --output "$OUTDIR/regions.tsv"

    # Count molecules per gene (low --min-frac for genome-wide mapping where
    # PCR amplicons are shorter than full gene spans)
    L3Rseq count --input "$OUTDIR" --outdir "$OUTDIR" \
        --regions "$OUTDIR/regions.tsv" --min-frac 0.01
fi

# ---- Done -------------------------------------------------------------------

echo ""
echo "========================================"
echo "Done! Results are in: $OUTDIR/"
echo "========================================"
echo ""
echo "Key output files:"
echo "  Mapped BAMs:       $OUTDIR/07_map/"
echo "  Gene counts:       $OUTDIR/11_count/"
echo "  Regions:           $OUTDIR/regions.tsv"
echo "  Pipeline summary:  $OUTDIR/pipeline_summary.tsv"
echo ""
echo "Next steps:"
echo "  # View alignments and gene counts in your browser"
echo "  L3Rseq viewer --dir $OUTDIR"
echo ""
echo "  # Re-run counting with housekeeping normalization"
echo "  # L3Rseq count --input $OUTDIR --outdir $OUTDIR \\"
echo "  #     --regions $OUTDIR/regions.tsv --housekeeping GENE_NAME"
