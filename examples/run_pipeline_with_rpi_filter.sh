#!/bin/bash
# examples/run_pipeline_with_rpi_filter.sh — three-phase pipeline template
#
# This template extends examples/run_pipeline.sh with two patterns useful
# for real-data analyses:
#
#   - Phase split with optional RPI filtering: steps 01-03 run first
#     (no reference needed), then a filter step keeps only the RPIs you
#     care about, then steps 04-07 run on the filtered set. Useful when
#     a barcode contains many RPIs but only a subset is in your library.
#
#   - Gene-level counting (step 11) appended to the end. Auto-discovers
#     gene regions from a GFF3 and counts molecules per gene.
#
# HOW TO USE:
#   1. Copy:  cp examples/run_pipeline_with_rpi_filter.sh runs/my_run.sh
#   2. Edit the variables in the "YOUR EXPERIMENT" section
#   3. Run:   cd /workspace && bash runs/my_run.sh
#
# Re-running on the same OUTDIR: `rm -rf "$OUTDIR"` first, otherwise the
# leftover `03_demux_all/` directory breaks the RPI-filter step on rerun.

set -euo pipefail

# ============================================================================
# YOUR EXPERIMENT — Change these values to match your data
# ============================================================================

# Input: directory containing barcodeNN/ subdirectories of FASTQs
INPUT_DIR="data/my_input"

# Output directory for all pipeline results
OUTDIR="runs/my_experiment"

# Reference FASTA — genomic DNA sequence of your target gene + downstream.
# Required for steps 07-10 (mapping, variant calling, correction).
# Leave empty to stop after Phase 1 (preprocessing only).
REF=""

# RPI barcode FASTA. The repo ships with the standard 36 RPI barcodes:
RPI_FASTA="resources/rpi_barcodes/RPI_Barcode_20nt.fasta"

# Which RPIs to keep after demux (space-separated numbers).
# Set to "" to process ALL RPIs found.
RPIS=""

# Forward target primer used by step 06 (extract) to trim consensus reads
# to the gene insert. Leave empty to skip target-fwd trimming.
TARGET_FWD=""

# UMI extraction method: "longread-umi" (flanking-sequence) or "umic-seq"
METHOD="longread-umi"

# GFF3 annotation for gene-level counting (Phase 3). Leave empty to skip.
GFF=""

THREADS=$(nproc 2>/dev/null || echo 4)

# ============================================================================
# PIPELINE — You should not need to change anything below this line
# ============================================================================

echo "========================================"
echo "L3Rseq pipeline run"
echo "  Input:   $INPUT_DIR"
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

# ---- Phase 3: Gene-level counting (optional) -------------------------------

if [ -n "$GFF" ] && [ -f "$GFF" ] && [ -d "$OUTDIR/07_map" ]; then
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
[ -n "$GFF" ] && echo "  Gene counts:       $OUTDIR/11_count/"
[ -n "$GFF" ] && echo "  Regions:           $OUTDIR/regions.tsv"
echo "  Pipeline summary:  $OUTDIR/pipeline_summary.tsv"
echo ""
echo "Next steps:"
echo "  # View alignments and gene counts in your browser"
echo "  L3Rseq viewer --dir $OUTDIR"
