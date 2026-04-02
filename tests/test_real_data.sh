#!/bin/bash
# test_real_data.sh — Validate L3Rseq pipeline on real or user-provided data
#
# A general-purpose test that runs the pipeline and checks output sanity.
# Works for any dataset: provide your data paths via CLI flags.
#
# Usage examples:
#
#   # REP2 validation (from demuxed FASTQs, steps 4-10)
#   bash tests/test_real_data.sh \
#       --input runs/REP2 --ref ccb3CDS+downstream.fasta \
#       --start-at 4 --pattern CT --method longread-umi \
#       --blast-db REP2/blast_db/TAIR10_ChrM/TAIR10_ChrM_db \
#       --blast-db2 REP2/blast_db/TAIR10_cDNA/TAIR10_cdna_db
#
#   # SLAM-seq validation (from extracted consensus, steps 7-10)
#   bash tests/test_real_data.sh \
#       --reads SLAM/.../cutadapt_*.fa --ref ccmC+downstream_PB.fasta \
#       --barcode slam --rpi RPI_5 --start-at 7 \
#       --pattern CT --count-pattern TC
#
#   # Your own data (from demuxed FASTQs)
#   bash tests/test_real_data.sh \
#       --input my_data/03_demux --ref my_reference.fa \
#       --start-at 4 --pattern CT
#
# Requirements: conda environments must be available (longread_umi,
#   cutadaptenv, NanoporeMap, LoFreq — as needed for the steps being run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

check_gt() {
    local label="$1" got="$2" threshold="$3"
    if [ "$got" -gt "$threshold" ]; then
        pass "$label: $got (> $threshold)"
    else
        fail "$label: $got (expected > $threshold)"
    fi
}

count_sam_reads() { local n; n=$(grep -cv '^@' "$1" 2>/dev/null) || n=0; echo "$n"; }
count_csv_rows() { echo $(( $(wc -l < "$1") - 1 )); }

usage() {
    cat <<'USAGE'
Usage: bash tests/test_real_data.sh [OPTIONS]

Input (one of --input or --reads is required):
  --input DIR          Pipeline directory with step subdirs (e.g., 03_demux/)
                       or flat directory of demuxed FASTQs
  --reads FILE         Single FASTA/FASTQ file (for starting at step 7+).
                       Requires --barcode and --rpi to set up directory structure.

Required:
  --ref FILE           Reference FASTA

Pipeline options:
  --start-at N         Pipeline step to start from (default: 4)
  --stop-at N          Pipeline step to stop at (default: 10)
  --pattern PAT        Editing pattern (default: CT)
  --count-pattern PAT  Secondary count pattern (e.g., TC for SLAM-seq)
  --introns SPEC       Intron specification (start-end, BED, or GFF3)
  --method METHOD      UMI method: longread-umi (default) or umic-seq
  --blast-db PATH      BLAST database for organellar genome
  --blast-db2 PATH     BLAST database for transcriptome (cDNA)
  --threads N          Number of threads (default: 4)

Directory setup:
  --outdir DIR         Output directory (default: runs/test_<timestamp>)
  --barcode NAME       Barcode name (used with --reads to set up dir structure)
  --rpi NAME           RPI name (used with --reads to set up dir structure)

Other:
  --keep               Keep output directory on success (default: keep)
  --help               Show this help
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

INPUT_DIR=""
READS_FILE=""
REF=""
OUTDIR=""
BARCODE=""
RPI=""
START_AT=4
STOP_AT=10
PATTERN="CT"
COUNT_PATTERN=""
INTRONS=""
METHOD="longread-umi"
BLAST_DB=""
BLAST_DB2=""
THREADS=4

while [ $# -gt 0 ]; do
    case "$1" in
        --input)          INPUT_DIR="$2"; shift 2 ;;
        --reads)          READS_FILE="$2"; shift 2 ;;
        --ref)            REF="$2"; shift 2 ;;
        --outdir)         OUTDIR="$2"; shift 2 ;;
        --barcode)        BARCODE="$2"; shift 2 ;;
        --rpi)            RPI="$2"; shift 2 ;;
        --start-at)       START_AT="$2"; shift 2 ;;
        --stop-at)        STOP_AT="$2"; shift 2 ;;
        --pattern)        PATTERN="$2"; shift 2 ;;
        --count-pattern)  COUNT_PATTERN="$2"; shift 2 ;;
        --introns)        INTRONS="$2"; shift 2 ;;
        --method)         METHOD="$2"; shift 2 ;;
        --blast-db)       BLAST_DB="$2"; shift 2 ;;
        --blast-db2)      BLAST_DB2="$2"; shift 2 ;;
        --threads)        THREADS="$2"; shift 2 ;;
        --keep)           shift ;;
        --help)           usage ;;
        *)                echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if [ -z "$INPUT_DIR" ] && [ -z "$READS_FILE" ]; then
    echo "ERROR: --input or --reads is required. Run with --help for usage." >&2
    exit 1
fi

if [ -z "$REF" ]; then
    echo "ERROR: --ref is required" >&2
    exit 1
fi

if [ ! -f "$REF" ]; then
    echo "ERROR: Reference not found: $REF" >&2
    exit 1
fi

if [ -n "$READS_FILE" ] && [ ! -f "$READS_FILE" ]; then
    echo "ERROR: Reads file not found: $READS_FILE" >&2
    exit 1
fi

if [ -n "$INPUT_DIR" ] && [ ! -d "$INPUT_DIR" ]; then
    echo "ERROR: Input directory not found: $INPUT_DIR" >&2
    exit 1
fi

if [ -n "$READS_FILE" ]; then
    if [ -z "$BARCODE" ] || [ -z "$RPI" ]; then
        echo "ERROR: --barcode and --rpi are required when using --reads" >&2
        exit 1
    fi
fi

if [ -n "$BLAST_DB" ] && [ ! -f "${BLAST_DB}.nsq" ] && [ ! -f "${BLAST_DB}.ndb" ]; then
    echo "ERROR: BLAST database not found: $BLAST_DB" >&2
    exit 1
fi

if [ -n "$BLAST_DB2" ] && [ ! -f "${BLAST_DB2}.nsq" ] && [ ! -f "${BLAST_DB2}.ndb" ]; then
    echo "ERROR: BLAST database not found: $BLAST_DB2" >&2
    exit 1
fi

# Set default output directory
if [ -z "$OUTDIR" ]; then
    OUTDIR="$PIPELINE_DIR/runs/test_$(date +%Y%m%d_%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

eval "$(conda shell.bash hook)"

echo "========================================"
echo "L3Rseq Real Data Validation"
echo "========================================"
echo ""
echo "  Reference:     $(basename "$REF")"
echo "  Steps:         $START_AT → $STOP_AT"
echo "  Pattern:       $PATTERN"
[ -n "$COUNT_PATTERN" ] && echo "  Count pattern: $COUNT_PATTERN"
[ -n "$INTRONS" ]       && echo "  Introns:       $INTRONS"
[ -n "$BLAST_DB" ]      && echo "  BLAST DB:      $(basename "$BLAST_DB")"
[ -n "$BLAST_DB2" ]     && echo "  BLAST DB2:     $(basename "$BLAST_DB2")"
echo "  Method:        $METHOD"
echo "  Threads:       $THREADS"
echo "  Output:        $OUTDIR"

mkdir -p "$OUTDIR"

# When --reads is provided (single file), create the directory structure
# that L3Rseq expects for the starting step.
if [ -n "$READS_FILE" ]; then
    ABS_READS="$(cd "$(dirname "$READS_FILE")" && pwd)/$(basename "$READS_FILE")"
    echo ""
    echo "  Setting up from single reads file: $(basename "$READS_FILE")"
    echo "  → barcode=$BARCODE  rpi=${BARCODE}_${RPI}"

    if [ "$START_AT" -le 7 ]; then
        # Starting at step 7 or earlier from extracted reads
        EXTRACT_DIR="$OUTDIR/06_extract/$BARCODE/${BARCODE}_${RPI}"
        mkdir -p "$EXTRACT_DIR"
        ln -sf "$ABS_READS" "$EXTRACT_DIR/${BARCODE}_${RPI}_extracted_trimmed.fa"
        echo "  → Linked as 06_extract/$BARCODE/${BARCODE}_${RPI}/${BARCODE}_${RPI}_extracted_trimmed.fa"
        # Adjust start to 7 minimum (can't run step 6 from a symlink)
        if [ "$START_AT" -lt 7 ]; then
            echo "  → Adjusting --start-at to 7 (reads already extracted)"
            START_AT=7
        fi
    elif [ "$START_AT" -le 9 ]; then
        # Starting at step 9 from pre-mapped reads
        MAP_DIR="$OUTDIR/07_map/$BARCODE/${BARCODE}_${RPI}"
        mkdir -p "$MAP_DIR"
        ln -sf "$ABS_READS" "$MAP_DIR/${BARCODE}_${RPI}_mapped_only.sam"
        echo "  → Linked as 07_map/$BARCODE/${BARCODE}_${RPI}/${BARCODE}_${RPI}_mapped_only.sam"
    fi

    # Create empty variant file so step 09 doesn't complain
    VAR_DIR="$OUTDIR/08_variants/$BARCODE/${BARCODE}_${RPI}"
    mkdir -p "$VAR_DIR"
    touch "$VAR_DIR/observed_variants.txt"

    # Point --input at the outdir so L3Rseq finds the data we set up
    INPUT_DIR="$OUTDIR"
fi
echo ""

# ---------------------------------------------------------------------------
# Run pipeline
# ---------------------------------------------------------------------------

echo "[RUNNING] L3Rseq pipeline (steps $START_AT-$STOP_AT) ..."
echo ""

PIPELINE_CMD=(
    "$PIPELINE_DIR/L3Rseq" run
    --outdir "$OUTDIR"
    --ref "$REF"
    --method "$METHOD"
    --pattern "$PATTERN"
    --start-at "$START_AT"
    --stop-at "$STOP_AT"
    --threads "$THREADS"
    --keep-intermediates
)

[ -n "$INPUT_DIR" ]     && PIPELINE_CMD+=(--input "$INPUT_DIR")
[ -n "$COUNT_PATTERN" ] && PIPELINE_CMD+=(--count-pattern "$COUNT_PATTERN")
[ -n "$INTRONS" ]       && PIPELINE_CMD+=(--introns "$INTRONS")
[ -n "$BLAST_DB" ]      && PIPELINE_CMD+=(--blast-db "$BLAST_DB")
[ -n "$BLAST_DB2" ]     && PIPELINE_CMD+=(--blast-db2 "$BLAST_DB2")

LOG="$OUTDIR/test_real_data.log"

if "${PIPELINE_CMD[@]}" > "$LOG" 2>&1; then
    pass "Pipeline completed without error"
else
    fail "Pipeline exited with error (see $LOG)"
    echo ""
    echo "  Last 20 lines of log:"
    tail -20 "$LOG" | sed 's/^/    /'
    echo ""
    echo "========================================"
    echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
    echo "========================================"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Validate output
# ---------------------------------------------------------------------------

echo "[VALIDATING] Checking pipeline output ..."
echo ""

# Discover samples from the output
SAMPLE_COUNT=0
for bc_dir in "$OUTDIR"/09_correct/*/; do
    [ -d "$bc_dir" ] || continue
    bc=$(basename "$bc_dir")

    for rpi_dir in "$bc_dir"/*/; do
        [ -d "$rpi_dir" ] || continue
        rpi=$(basename "$rpi_dir")
        SAMPLE_COUNT=$((SAMPLE_COUNT + 1))

        echo "  --- $bc / $rpi ---"

        # Corrected SAM exists
        SAM="$rpi_dir/${rpi}_corrected.sam"
        if [ -f "$SAM" ]; then
            pass "${rpi}_corrected.sam exists"
        else
            fail "${rpi}_corrected.sam missing"
            continue
        fi

        # Sorted BAM + index exist
        if [ -f "$rpi_dir/${rpi}_corrected.sort.bam" ] && [ -f "$rpi_dir/${rpi}_corrected.sort.bam.bai" ]; then
            pass "Sorted BAM + index exist"
        else
            fail "Missing sorted BAM or index"
        fi

        # Read count > 0
        NREADS=$(count_sam_reads "$SAM")
        check_gt "Corrected reads" "$NREADS" 0

        # EC tags present on all reads
        EC_COUNT=$(grep -v '^@' "$SAM" | grep -c 'EC:i:' || true)
        if [ "$EC_COUNT" = "$NREADS" ]; then
            pass "EC tag on all $NREADS reads"
        else
            fail "EC tag on $EC_COUNT / $NREADS reads"
        fi

        # NC tags present on all reads
        NC_COUNT=$(grep -v '^@' "$SAM" | grep -c 'NC:i:' || true)
        if [ "$NC_COUNT" = "$NREADS" ]; then
            pass "NC tag on all $NREADS reads"
        else
            fail "NC tag on $NC_COUNT / $NREADS reads"
        fi

        # Total EC
        TOTAL_EC=$(grep -v '^@' "$SAM" | grep -oE 'EC:i:[0-9]+' | sed 's/EC:i://' | awk '{s+=$1} END{print s+0}')
        echo "    EC total: $TOTAL_EC (avg $(echo "$TOTAL_EC $NREADS" | awk '{printf "%.1f", $1/$2}') / read)"

        # Total NC
        TOTAL_NC=$(grep -v '^@' "$SAM" | grep -oE 'NC:i:[0-9]+' | sed 's/NC:i://' | awk '{s+=$1} END{print s+0}')
        echo "    NC total: $TOTAL_NC"

        # SC tags (only expected with --count-pattern)
        if [ -n "$COUNT_PATTERN" ]; then
            SC_COUNT=$(grep -v '^@' "$SAM" | grep -c 'SC:i:' || true)
            if [ "$SC_COUNT" = "$NREADS" ]; then
                pass "SC tag on all $NREADS reads (--count-pattern $COUNT_PATTERN)"
            else
                fail "SC tag on $SC_COUNT / $NREADS reads"
            fi
            TOTAL_SC=$(grep -v '^@' "$SAM" | grep -oE 'SC:i:[0-9]+' | sed 's/SC:i://' | awk '{s+=$1} END{print s+0}')
            echo "    SC total: $TOTAL_SC"
        fi

        # Splice tags (only expected with --introns)
        if [ -n "$INTRONS" ]; then
            SJ_COUNT=$(grep -v '^@' "$SAM" | grep -c 'SJ:Z:' || true)
            if [ "$SJ_COUNT" -gt 0 ]; then
                pass "SJ tags present ($SJ_COUNT reads)"
            else
                fail "No SJ tags found (--introns was set)"
            fi
            N_SPLICED=$(grep -v '^@' "$SAM" | grep -oE 'SJ:Z:S' | sed 's/SJ:Z://' | wc -l || echo 0)
            N_UNSPLICED=$(grep -v '^@' "$SAM" | grep -oE 'SJ:Z:R' | sed 's/SJ:Z://' | wc -l || echo 0)
            N_UNSPANNED=$(grep -v '^@' "$SAM" | grep -oE 'SJ:Z:-' | sed 's/SJ:Z://' | wc -l || echo 0)
            echo "    Splice: S=$N_SPLICED R=$N_UNSPLICED -=$N_UNSPANNED"
        fi

        # BLAST outputs (only when --blast-db provided)
        if [ -n "$BLAST_DB" ]; then
            CHIM_SAM="$rpi_dir/${rpi}_chimeric_rightclip.sam"
            if [ -f "$CHIM_SAM" ]; then
                CHIM_COUNT=$(grep -cv '^@' "$CHIM_SAM" 2>/dev/null || echo 0)
                echo "    Chimeric reads removed: $CHIM_COUNT"
            fi
            TL_COUNT=$(grep -v '^@' "$SAM" | grep -c 'TL:i:1' || echo 0)
            echo "    Translocation flagged: $TL_COUNT"
        fi

        # CSV output
        CSV="$OUTDIR/10_csv/${bc}_${rpi}.csv"
        if [ -f "$CSV" ]; then
            CSV_ROWS=$(count_csv_rows "$CSV")
            if [ "$CSV_ROWS" = "$NREADS" ]; then
                pass "CSV rows match reads: $CSV_ROWS"
            else
                warn "CSV rows ($CSV_ROWS) != corrected reads ($NREADS)"
            fi
            CSV_COLS=$(head -1 "$CSV" | awk -F',' '{print NF}')
            echo "    CSV columns: $CSV_COLS"
        else
            fail "CSV missing: $CSV"
        fi

        # Quality report
        QR="$OUTDIR/10_csv/${bc}_${rpi}_quality_report.txt"
        if [ -f "$QR" ]; then
            pass "Quality report exists"
            # Extract key stats
            Q_SUBS=$(grep 'Q (subs only)' "$QR" | grep -oE 'Q[0-9.]+' | head -1 || true)
            Q_ALL=$(grep 'Q (subs.indels)' "$QR" | grep -oE 'Q[0-9.]+' | head -1 || true)
            ERR_FREE=$(grep 'Error-free' "$QR" | grep -oE '[0-9.]+%' | head -1 || true)
            [ -n "$Q_SUBS" ]   && echo "    Q (subs): $Q_SUBS"
            [ -n "$Q_ALL" ]    && echo "    Q (subs+indels): $Q_ALL"
            [ -n "$ERR_FREE" ] && echo "    Error-free: $ERR_FREE"

            if [ -n "$INTRONS" ] && grep -q "Splicing analysis" "$QR"; then
                EFFICIENCY=$(grep "Intron 1:" "$QR" | grep -oE '\(.*\)' || true)
                [ -n "$EFFICIENCY" ] && echo "    Splicing efficiency: $EFFICIENCY"
            fi
        else
            fail "Quality report missing"
        fi

        echo ""
    done
done

if [ "$SAMPLE_COUNT" -eq 0 ]; then
    fail "No samples found in output"
fi

# Pipeline summary
if [ -f "$OUTDIR/pipeline_summary.tsv" ]; then
    pass "pipeline_summary.tsv exists"
else
    warn "pipeline_summary.tsv missing"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "  Output: $OUTDIR"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "Some tests FAILED. Check $LOG for pipeline output."
    exit 1
fi

echo "All checks passed."
