#!/bin/bash
# examples/run_with_snakemake.sh — Run the L3Rseq pipeline via Snakemake (recommended path)
#
# WHY SNAKEMAKE: DAG parallelism across {barcode, RPI} samples (different
# stages run concurrently for different RPIs), resume-from-failure on
# interrupt, per-rule resource isolation. Slower than the bash dispatcher
# on tiny datasets (<10 RPIs, fast amplicon refs) due to per-rule overhead;
# wins on everything larger.
#
# HOW TO USE:
#   1. Copy this file:  cp examples/run_with_snakemake.sh runs/my_run.sh
#   2. Open the copy and edit the variables in "YOUR EXPERIMENT" below
#   3. Run it:          cd /workspace && bash runs/my_run.sh
#
# Your terminal must be in /workspace (the devcontainer default).
#
# This script applies per-run overrides on top of the repo's config.yaml via
# `--config key=val` flags — you don't have to copy or edit config.yaml
# itself. For a fully YAML-driven workflow (per-run config files), see
# docs/development.md "Running the pipeline with Snakemake".

set -euo pipefail

# ============================================================================
# YOUR EXPERIMENT — Change these values to match your data
# ============================================================================

# Where Snakemake will write all pipeline artifacts (01_concat/ … 10_csv/).
OUTDIR="runs/my_experiment"

# Directory containing one subdirectory per Nanopore barcode, each holding
# *.fastq.gz files (typically dorado-demultiplex output).
INPUT_DIR="data/my_input"

# Reference FASTA — genomic DNA of your target gene + downstream region.
REF="refs/my_gene.fasta"

# RPI sample-barcode FASTA. The repo ships with the standard 36 RPIs.
RPI_FASTA="resources/rpi_barcodes/RPI_Barcode_20nt.fasta"

# RNA editing pattern. "CT" = C-to-U (plant mitochondria default).
# Use "AG" for A-to-I, or "CT,AG" to count both as primary editing.
PATTERN="CT"

# Optional secondary pattern for SLAM-seq metabolic labeling. "" = disabled.
COUNT_PATTERN=""

# Optional gene-level counting (step 11). Path to a regions.tsv enables it;
# leave empty to skip step 11. Generate one with `L3Rseq regions --help`.
REGIONS=""

# Minimum fraction of a gene region a read must cover to count (step 11).
# 0.95 is right for amplicon refs (reads span ~the whole gene). For
# whole-genome L3Rseq, reads are short 3'-end fragments — use 0.01,
# otherwise every count is silently 0.
MIN_FRAC=0.95

# CPU threads. Snakemake runs as many parallel jobs as fit in this budget.
CORES=$(nproc 2>/dev/null || echo 4)

# ============================================================================
# RUN — You should not need to change anything below this line
# ============================================================================

# Snakemake (and pysam, ruff, mypy, pytest) lives in this conda env.
source /opt/miniforge/etc/profile.d/conda.sh
conda activate l3rseq_py

# Build per-run --config overrides. The repo's config.yaml supplies defaults
# for every key; these overrides win when the same key is set in both.
OVERRIDES=(
    "input_dir=$INPUT_DIR"
    "output_dir=$OUTDIR"
    "ref=$REF"
    "rpi_fasta=$RPI_FASTA"
    "pattern=$PATTERN"
)
[ -n "$COUNT_PATTERN" ] && OVERRIDES+=("count_pattern=$COUNT_PATTERN")
[ -n "$REGIONS" ]       && OVERRIDES+=("regions=$REGIONS" "min_frac=$MIN_FRAC")

echo "========================================"
echo "L3Rseq pipeline — Snakemake"
echo "  Input:    $INPUT_DIR"
echo "  Output:   $OUTDIR"
echo "  Cores:    $CORES"
echo "  Step 11:  ${REGIONS:-skipped}"
echo "========================================"

# Dry-run first — prints the DAG without executing. Catches bad paths or
# missing inputs before committing CPU time to the real run.
echo ""
echo "=== Dry-run (DAG preview) ==="
snakemake --cores "$CORES" --configfile config.yaml \
    --config "${OVERRIDES[@]}" --dry-run

echo ""
echo "=== Real run ==="
# NOTE: --config takes ALL key=val pairs in ONE flag. Repeating --config
# silently overwrites earlier values (Snakemake quirk).
snakemake --cores "$CORES" --configfile config.yaml \
    --config "${OVERRIDES[@]}"

echo ""
echo "========================================"
echo "Done! Results are in: $OUTDIR/"
echo "========================================"
echo "  Per-molecule CSV:   $OUTDIR/10_csv/"
[ -n "$REGIONS" ] && echo "  Gene counts:        $OUTDIR/11_count/"
echo "  Pipeline summary:   $OUTDIR/pipeline_summary.tsv"
echo ""
echo "View in browser:      L3Rseq viewer --dir $OUTDIR"
echo "Resume on interrupt:  re-run this script — Snakemake skips done jobs"
