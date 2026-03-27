#!/bin/bash
# test_splice_real_data.sh — Validate L3Rseq splicing support on real data
#
# Tests the full splice workflow: mapping → intron discovery → step 09 splice
# annotation → step 10 CSV/quality report → backward compatibility (no --introns).
#
# Usage:
#   bash tests/test_splice_real_data.sh \
#       --ref ccmFc+downstream_PB.fasta \
#       --reads cutadapt_consensus.fa \
#       [--blast-db TAIR10_ChrM_db] \
#       [--blast-db2 TAIR10_cdna_db] \
#       [--outdir runs/Splice] \
#       [--barcode E241002_Fw3_Rv14] \
#       [--rpi RPI_1]
#
# Requirements: NanoporeMap conda env (minimap2, samtools, blastn)
#
# Example with the original experiment data:
#   bash tests/test_splice_real_data.sh \
#       --ref "Splice/Ref for Splice/ccmFc+downstream_PB.fasta" \
#       --reads "Splice/E241002_Rv14_Cutadapt/E241002_Fw3_Rv14_RPI_1/cutadapt_E241002_Fw3_Rv14_RPI_1.fa" \
#       --blast-db resources/blast/TAIR10_ChrM/TAIR10_ChrM_db \
#       --blast-db2 resources/blast/TAIR10_cDNA/TAIR10_cdna_db

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: bash tests/test_splice_real_data.sh [OPTIONS]

Required:
  --ref FILE           Reference FASTA (gene with intron)
  --reads FILE         Consensus FASTA (e.g., cutadapt output from step 06)

Optional:
  --blast-db PATH      BLAST database for organellar genome
  --blast-db2 PATH     BLAST database for transcriptome (cDNA)
  --outdir DIR         Output directory (default: runs/splice_test)
  --barcode NAME       Barcode label (default: derived from reads filename)
  --rpi NAME           RPI label (default: derived from reads filename)
  --help               Show this help

The script maps the reads, discovers introns, runs step 09 with --introns,
exports CSV + quality report, and verifies backward compatibility.
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

REF=""
READS=""
BLAST_DB=""
BLAST_DB2=""
OUTDIR=""
BARCODE=""
RPI=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)       REF="$2"; shift 2 ;;
        --reads)     READS="$2"; shift 2 ;;
        --blast-db)  BLAST_DB="$2"; shift 2 ;;
        --blast-db2) BLAST_DB2="$2"; shift 2 ;;
        --outdir)    OUTDIR="$2"; shift 2 ;;
        --barcode)   BARCODE="$2"; shift 2 ;;
        --rpi)       RPI="$2"; shift 2 ;;
        --help)      usage ;;
        *)           echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if [ -z "$REF" ]; then
    echo "ERROR: --ref is required. Run with --help for usage." >&2
    exit 1
fi
if [ ! -f "$REF" ]; then
    echo "ERROR: Reference not found: $REF" >&2
    exit 1
fi

if [ -z "$READS" ]; then
    echo "ERROR: --reads is required. Run with --help for usage." >&2
    exit 1
fi
if [ ! -f "$READS" ]; then
    echo "ERROR: Reads file not found: $READS" >&2
    exit 1
fi

if [ -n "$BLAST_DB" ] && [ ! -f "${BLAST_DB}.nsq" ] && [ ! -f "${BLAST_DB}.ndb" ]; then
    echo "ERROR: BLAST database not found: $BLAST_DB" >&2
    exit 1
fi
if [ -n "$BLAST_DB2" ] && [ ! -f "${BLAST_DB2}.nsq" ] && [ ! -f "${BLAST_DB2}.ndb" ]; then
    echo "ERROR: BLAST database not found: $BLAST_DB2" >&2
    exit 1
fi

# Derive barcode/RPI from reads filename if not provided
READS_BASENAME=$(basename "$READS" | sed 's/\.\(fa\|fasta\|fq\|fastq\)\(\.gz\)\?$//')
if [ -z "$BARCODE" ]; then
    BARCODE="$READS_BASENAME"
fi
if [ -z "$RPI" ]; then
    RPI="${READS_BASENAME}_RPI_1"
fi

if [ -z "$OUTDIR" ]; then
    OUTDIR="$WORKSPACE/runs/splice_test"
fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

eval "$(conda shell.bash hook)"
conda activate NanoporeMap

NREADS=$(grep -c '^>' "$READS")

echo "=== L3Rseq Splice Test ==="
echo "  Reference: $(basename "$REF")"
echo "  Reads:     $NREADS consensus sequences ($(basename "$READS"))"
echo "  Barcode:   $BARCODE"
echo "  RPI:       $RPI"
echo "  Output:    $OUTDIR"
[ -n "$BLAST_DB" ]  && echo "  BLAST DB:  $(basename "$BLAST_DB")"
[ -n "$BLAST_DB2" ] && echo "  BLAST DB2: $(basename "$BLAST_DB2")"
echo ""

# Clean previous run
rm -rf "$OUTDIR"

# ── Step 1: Map reads ─────────────────────────────────────────────────
echo "[1/5] Mapping reads with minimap2 ..."
MAP_DIR="$OUTDIR/07_map/$BARCODE/$RPI"
mkdir -p "$MAP_DIR"
samtools faidx "$REF" 2>/dev/null
minimap2 -ax lr:hq "$REF" "$READS" 2>/dev/null \
    | samtools view -F 4 -h -o "$MAP_DIR/mapped_only.sam"

MAPPED=$(samtools view -c "$MAP_DIR/mapped_only.sam")
echo "  Mapped reads: $MAPPED"

if [ "$MAPPED" -gt 0 ]; then
    ok "Mapping produced $MAPPED reads"
else
    fail "No reads mapped"
    echo "Aborting: cannot continue without mapped reads."
    exit 1
fi

# Create sorted BAM
samtools view -bS "$MAP_DIR/mapped_only.sam" > "$MAP_DIR/aligned.bam" 2>/dev/null
samtools sort "$MAP_DIR/aligned.bam" > "$MAP_DIR/aligned.sort.bam" 2>/dev/null
samtools index "$MAP_DIR/aligned.sort.bam" 2>/dev/null

# ── Step 2: Discover introns ──────────────────────────────────────────
echo ""
echo "[2/5] Running intron discovery ..."
source "$WORKSPACE/scripts/discover_introns.sh"
run_discover_introns "$OUTDIR/07_map" "$OUTDIR/discover" 50 5 10 2>&1 | sed 's/^/  /'

BED="$OUTDIR/discover/${BARCODE}_${RPI}_candidate_introns.bed"
if [ -f "$BED" ] && [ -s "$BED" ]; then
    ok "Discovery produced BED file"
    INTRON_LINE=$(head -1 "$BED")
    INTRON_START=$(echo "$INTRON_LINE" | cut -f2)
    INTRON_END=$(echo "$INTRON_LINE" | cut -f3)
    INTRON_LEN=$((INTRON_END - INTRON_START))
    echo "  Found intron: $INTRON_START-$INTRON_END (${INTRON_LEN}bp)"

    if [ "$INTRON_LEN" -ge 30 ]; then
        ok "Intron length plausible ($INTRON_LEN bp)"
    else
        fail "Intron too short: $INTRON_LEN bp"
    fi
else
    fail "No intron BED file produced"
    echo "  Cannot continue splice test without discovered intron."
    echo ""
    echo "============================================"
    echo "  Results: $PASS passed, $FAIL failed"
    echo "============================================"
    exit 1
fi

REPORT="$OUTDIR/discover/${BARCODE}_${RPI}_intron_discovery_report.txt"
if [ -f "$REPORT" ] && grep -q "HIGH CONFIDENCE" "$REPORT"; then
    ok "Discovery report shows HIGH CONFIDENCE"
else
    # Not a hard fail — low confidence might still be correct
    echo "  [WARN] Discovery report missing or no HIGH CONFIDENCE candidate"
fi

# ── Step 3: Run step 09 (tail correction + splice annotation) ────────
echo ""
echo "[3/5] Running step 09 (tail correction + splice annotation) ..."
VAR_DIR="$OUTDIR/08_variants/$BARCODE/$RPI"
mkdir -p "$VAR_DIR"
touch "$VAR_DIR/observed_variants.txt"

source "$WORKSPACE/scripts/09_tail_correct.sh"
run_step_09 \
    "$OUTDIR/07_map" \
    "$OUTDIR" \
    "$REF" \
    "" \
    "CT" \
    "$BLAST_DB" \
    "$BLAST_DB2" \
    "50" \
    "$OUTDIR/08_variants" \
    "1" \
    "" \
    "$INTRON_START-$INTRON_END" \
    2>&1 | sed 's/^/  /'

CORRECTED_SAM="$OUTDIR/09_correct/$BARCODE/$RPI/corrected.sam"
if [ -f "$CORRECTED_SAM" ]; then
    ok "corrected.sam exists"
else
    fail "corrected.sam not found"
    echo "Aborting: cannot continue without corrected output."
    exit 1
fi

# Check splice tags exist
N_SJ=$(grep -c "SJ:Z:" "$CORRECTED_SAM" 2>/dev/null || true)
if [ "$N_SJ" -gt 0 ]; then
    ok "SJ tags present in $N_SJ reads"
else
    fail "No SJ tags found in corrected.sam"
fi

# Check distribution: S, R, -
N_SPLICED=$(grep -oE "SJ:Z:S" "$CORRECTED_SAM" | sed 's/SJ:Z://' | wc -l || echo 0)
N_UNSPLICED=$(grep -oE "SJ:Z:R" "$CORRECTED_SAM" | sed 's/SJ:Z://' | wc -l || echo 0)
N_UNSPANNED=$(grep -oE "SJ:Z:-" "$CORRECTED_SAM" | sed 's/SJ:Z://' | wc -l || echo 0)

echo "  Splice distribution: S=$N_SPLICED  R=$N_UNSPLICED  -=$N_UNSPANNED"

if [ "$N_SPLICED" -gt 0 ]; then
    ok "Spliced reads found: $N_SPLICED"
else
    fail "No spliced reads detected"
fi

if [ "$N_UNSPLICED" -gt 0 ]; then
    ok "Unspliced reads found: $N_UNSPLICED"
else
    fail "No unspliced reads detected"
fi

# Verify SI/IR tags match SJ
SAMPLE_S=$(grep "SJ:Z:S" "$CORRECTED_SAM" | head -1)
if [ -n "$SAMPLE_S" ]; then
    SI_VAL=$(echo "$SAMPLE_S" | grep -oE "SI:i:[0-9]+" | sed 's/SI:i://')
    IR_VAL=$(echo "$SAMPLE_S" | grep -oE "IR:i:[0-9]+" | sed 's/IR:i://')
    if [ "$SI_VAL" = "1" ] && [ "$IR_VAL" = "0" ]; then
        ok "Spliced read has SI:i:1, IR:i:0"
    else
        fail "Spliced read tags wrong: SI=$SI_VAL IR=$IR_VAL (expected SI=1 IR=0)"
    fi
fi

SAMPLE_R=$(grep "SJ:Z:R" "$CORRECTED_SAM" | head -1)
if [ -n "$SAMPLE_R" ]; then
    SI_VAL=$(echo "$SAMPLE_R" | grep -oE "SI:i:[0-9]+" | sed 's/SI:i://')
    IR_VAL=$(echo "$SAMPLE_R" | grep -oE "IR:i:[0-9]+" | sed 's/IR:i://')
    if [ "$SI_VAL" = "0" ] && [ "$IR_VAL" = "1" ]; then
        ok "Unspliced read has SI:i:0, IR:i:1"
    else
        fail "Unspliced read tags wrong: SI=$SI_VAL IR=$IR_VAL (expected SI=0 IR=1)"
    fi
fi

# Verify sorted BAM exists
if [ -f "$OUTDIR/09_correct/$BARCODE/$RPI/corrected.sort.bam" ] && \
   [ -f "$OUTDIR/09_correct/$BARCODE/$RPI/corrected.sort.bam.bai" ]; then
    ok "Sorted BAM + index exist"
else
    fail "Missing sorted BAM or index"
fi

# ── Step 4: Run step 10 (CSV + quality report) ───────────────────────
echo ""
echo "[4/5] Running step 10 (CSV export + quality report) ..."
source "$WORKSPACE/scripts/10_export_csv.sh"
run_step_10 "$OUTDIR/09_correct" "$OUTDIR" 2>&1 | sed 's/^/  /'

CSV="$OUTDIR/10_csv/${BARCODE}_${RPI}.csv"
if [ -f "$CSV" ]; then
    ok "CSV file exists"
    HEADER=$(head -1 "$CSV")
    if echo "$HEADER" | grep -q 'splice_pattern'; then
        ok "CSV header includes splice columns"
    else
        fail "CSV header missing splice columns"
    fi
    CSV_ROWS=$(( $(wc -l < "$CSV") - 1 ))
    echo "  CSV rows: $CSV_ROWS"
else
    fail "CSV file not found"
fi

QR="$OUTDIR/10_csv/${BARCODE}_${RPI}_quality_report.txt"
if [ -f "$QR" ]; then
    ok "Quality report exists"
    if grep -q "Splicing analysis" "$QR"; then
        ok "Quality report includes splicing section"
        EFFICIENCY=$(grep "Intron 1:" "$QR" | grep -oE '\(.*\)' || true)
        [ -n "$EFFICIENCY" ] && echo "  Splicing efficiency: $EFFICIENCY"
    else
        fail "Quality report missing splicing section"
    fi
else
    fail "Quality report not found"
fi

# ── Step 5: Backward compatibility (no --introns) ────────────────────
echo ""
echo "[5/5] Backward compatibility check (no --introns) ..."
BC_DIR="$OUTDIR/bc_test"
mkdir -p "$BC_DIR/09_correct"
source "$WORKSPACE/scripts/09_tail_correct.sh"
# Run without introns — should produce no SJ tags
run_step_09 \
    "$OUTDIR/07_map" \
    "$BC_DIR" \
    "$REF" \
    "" \
    "CT" \
    "$BLAST_DB" \
    "$BLAST_DB2" \
    "50" \
    "$OUTDIR/08_variants" \
    "1" \
    "" \
    "" \
    2>&1 | sed 's/^/  /'

BC_SAM="$BC_DIR/09_correct/$BARCODE/$RPI/corrected.sam"
BC_SJ=$(grep -c "SJ:Z:" "$BC_SAM" 2>/dev/null || true)
if [ "$BC_SJ" -eq 0 ]; then
    ok "No SJ tags when --introns not provided (backward compatible)"
else
    fail "SJ tags found ($BC_SJ) even without --introns"
fi

# Cleanup backward compat test
rm -rf "$BC_DIR"

conda deactivate 2>/dev/null

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "  Output:  $OUTDIR"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
    echo "  All tests passed!"
    exit 0
else
    echo "  Some tests failed. Review output above."
    exit 1
fi
