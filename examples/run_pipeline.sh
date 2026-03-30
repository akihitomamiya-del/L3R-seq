#!/bin/bash
# run_pipeline.sh — Example L3Rseq analysis script
#
# HOW TO USE:
#   1. Copy this file:  cp examples/run_pipeline.sh runs/my_experiment.sh
#   2. Open the copy and change the variables in the "YOUR EXPERIMENT" section
#   3. Run it:  bash runs/my_experiment.sh
#
# IMPORTANT: Your terminal must be in the /workspace directory when you run
# this script. In Codespaces or the devcontainer, your terminal opens there
# by default. If you're unsure, type "cd /workspace" first.

set -euo pipefail

# ============================================================================
# YOUR EXPERIMENT — Change these values to match your data
# ============================================================================

# Where are your raw sequencing files? Point this to the directory containing
# your .fastq.gz files for one barcode (e.g., from dorado demultiplexing).
INPUT_DIR="data/barcode48"

# Where should the pipeline write its output?
OUTDIR="runs/my_experiment"

# Path to your reference FASTA (the genomic sequence of your target gene).
REF="refs/my_gene.fasta"

# Path to your RPI barcode FASTA. Each entry is a 20nt barcode sequence that
# identifies a sample within the barcode. The default file has 36 RPIs.
RPI_FASTA="resources/rpi_barcodes/RPI_Barcode_20nt.fasta"

# Which RPI samples do you want to analyze? List the numbers separated by
# spaces. Set to "" (empty) to process all RPIs found after demultiplexing.
RPIS="3 4"

# RNA editing pattern to detect. "CT" means C-to-U editing (the default for
# plant mitochondria). Use "AG" for A-to-I editing.
PATTERN="CT"

# Secondary pattern for SLAM-seq. "TC" counts T-to-C conversions from 4sU
# metabolic labeling. Set to "" if you're not doing SLAM-seq.
COUNT_PATTERN="TC"

# UMI method. Most users should use "longread-umi" (the default). Set to
# "umic-seq" only if you have a probe sequence for probe-based UMI extraction.
METHOD="longread-umi"

# Probe FASTA — only needed when METHOD="umic-seq". Leave as "" otherwise.
PROBE=""

# BLAST databases for detecting chimeric reads (optional). If you don't have
# these, leave as "" — the pipeline will still run, it just won't check for
# translocations or chimeric PCR artifacts. See README.md for how to build
# BLAST databases for your organism.
BLAST_DB=""
BLAST_DB2=""

# Number of CPU threads to use. Defaults to all available cores.
THREADS=$(nproc 2>/dev/null || echo 4)

# ============================================================================
# PIPELINE — You should not need to change anything below this line
# ============================================================================

BARCODE=$(basename "$INPUT_DIR")

# Build the command-line arguments from the variables above
ARGS=(
  --ref "$REF"
  --rpi-fasta "$RPI_FASTA"
  --method "$METHOD"
  --pattern "$PATTERN"
  --threads "$THREADS"
)
[ -n "$COUNT_PATTERN" ] && ARGS+=(--count-pattern "$COUNT_PATTERN")
[ -n "$PROBE" ]         && ARGS+=(--probe "$PROBE")
[ -n "$BLAST_DB" ]      && ARGS+=(--blast-db "$BLAST_DB")
[ -n "$BLAST_DB2" ]     && ARGS+=(--blast-db2 "$BLAST_DB2")

echo "========================================"
echo "L3Rseq analysis ($METHOD)"
echo "  Input:   $INPUT_DIR"
echo "  Output:  $OUTDIR"
echo "  Barcode: $BARCODE"
echo "  RPIs:    ${RPIS:-all}"
echo "  Pattern: $PATTERN ${COUNT_PATTERN:+/ $COUNT_PATTERN}"
echo "========================================"

# --- Steps 1-3: Concatenate raw files, trim adapters, demultiplex by RPI ----

# Step 01 expects a parent directory containing barcode subdirectories.
# This creates a temporary link so the pipeline finds your data correctly.
mkdir -p "${OUTDIR}_input"
ln -sf "$(cd "$(dirname "$INPUT_DIR")" && pwd)/$(basename "$INPUT_DIR")" \
       "${OUTDIR}_input/$BARCODE"

L3Rseq run --input "${OUTDIR}_input" --outdir "$OUTDIR" "${ARGS[@]}" --stop-at 3

# --- Keep only the RPIs you want (skip this if RPIS is empty) ---------------

if [ -n "$RPIS" ]; then
  echo "Filtering to RPIs: $RPIS"
  mv "$OUTDIR/03_demux" "$OUTDIR/03_demux_all"
  mkdir -p "$OUTDIR/03_demux/$BARCODE"
  for rpi in $RPIS; do
    src="$(pwd)/$OUTDIR/03_demux_all/$BARCODE/${BARCODE}_RPI_${rpi}.fastq"
    if [ -f "$src" ]; then
      ln -sf "$src" "$OUTDIR/03_demux/$BARCODE/"
    else
      echo "  WARNING: RPI $rpi not found in demultiplexed output" >&2
    fi
  done
fi

# --- Steps 4-10: UMI grouping, consensus, mapping, correction, export ------

L3Rseq run --input "$OUTDIR" --outdir "$OUTDIR" "${ARGS[@]}" --start-at 4

# --- Done! ------------------------------------------------------------------

echo ""
echo "========================================"
echo "Done! Results are in: $OUTDIR/"
echo "========================================"
echo ""
echo "Key output files:"
echo "  Per-molecule CSV:  $OUTDIR/10_csv/"
echo "  Corrected BAMs:   $OUTDIR/09_correct/"
echo "  Quality reports:  $OUTDIR/10_csv/*_quality_report.txt"
echo "  Pipeline summary: $OUTDIR/pipeline_summary.tsv"
echo ""
echo "Suggested next steps:"
echo "  # Generate UMI bin analysis plots"
echo "  conda run -n analysis python3 scripts/plot_umi_bins.py $OUTDIR --quality --outdir runs/figures/"
echo ""
echo "  # View alignments in your browser"
echo "  L3Rseq viewer"
echo "  # Then open http://localhost:8080 and select your dataset"
