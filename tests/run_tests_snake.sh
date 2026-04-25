#!/bin/bash
# tests/run_tests_snake.sh — Phase 4 snakemake test parity harness
#
# Proves the snakemake execution path produces byte-identical step 09
# (corrected BAM) and step 11 (gene counts) output to the bash dispatcher
# (`L3Rseq run`) on the synthetic fixtures. CI runs this after the existing
# bash-path quick test, so any future drift between the two paths fails CI.
#
# What it does:
#
#   1. Generates the bash baseline at tests/output/pipeline_CT/ if missing
#      (runs `bash tests/run_tests.sh --quick --no-viewer --test 2`),
#      then runs the bash `count` subcommand to populate
#      tests/output/pipeline_CT/11_count/ with `--min-frac 0.3`.
#
#   2. Pre-stages tests/output/snake_quick/03_demux/ from tests/data/demux/
#      so snakemake resumes from step 04 with the *same* step-04 input the
#      bash baseline used. (The Snakefile has no --start-at equivalent,
#      and starting from raw_fastq diverges at the demux step — that's a
#      separate, expected drift; pre-staging isolates the comparison to
#      the steps where parity matters.)
#
#   3. Runs `snakemake --cores N --configfile tests/config_synthetic.yaml`
#      (l3rseq_py env). The synthetic config enables step 11 with
#      tests/data/test_regions.tsv and `min_frac=0.3`, matching the bash
#      side.
#
#   4. Diffs the equivalent files between the two output trees. The diff
#      pattern is borrowed from tests/benchmarks/diff_step09.sh and
#      tests/benchmarks/diff_step11.sh:
#        - step 09: `samtools view | sort | cmp` for each corrected BAM
#        - step 11: text diff of gene_counts_all.tsv (set-equal via sort)
#                   and per-sample / coverage TSVs
#
#   5. Exits 0 on full match, non-zero with a clear summary on any drift.
#
# Usage:
#   bash tests/run_tests_snake.sh             # full harness
#   bash tests/run_tests_snake.sh --cores 8   # override snakemake cores
#   bash tests/run_tests_snake.sh --refresh   # force-regenerate bash baseline
#
# Exit codes:
#   0   all comparisons identical
#   1   one or more files drifted (details in stdout)
#   2   harness setup failed (missing fixture, env, etc.)

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PY_ENV_BIN="/opt/miniforge/envs/l3rseq_py/bin"
SAMTOOLS="/opt/miniforge/envs/NanoporeMap/bin/samtools"

BASH_OUT="$SCRIPT_DIR/output/pipeline_CT"
SNAKE_OUT="$SCRIPT_DIR/output/snake_quick"
DEMUX_FIXTURE="$SCRIPT_DIR/data/demux"
REGIONS="$SCRIPT_DIR/data/test_regions.tsv"
CONFIG="$SCRIPT_DIR/config_synthetic.yaml"

CORES=4
REFRESH_BASELINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cores)    CORES="${2:?}"; shift 2 ;;
        --refresh)  REFRESH_BASELINE=1; shift ;;
        -h|--help)
            sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ -x "$PY_ENV_BIN/snakemake" ] || {
    echo "ERROR: $PY_ENV_BIN/snakemake not found. Is the l3rseq_py env installed?" >&2
    exit 2
}
[ -x "$SAMTOOLS" ] || {
    echo "ERROR: $SAMTOOLS not found." >&2
    exit 2
}
[ -f "$CONFIG" ] || {
    echo "ERROR: $CONFIG not found." >&2
    exit 2
}
[ -d "$DEMUX_FIXTURE" ] || {
    echo "ERROR: $DEMUX_FIXTURE not found (synthetic demux fixture)." >&2
    exit 2
}
[ -f "$REGIONS" ] || {
    echo "ERROR: $REGIONS not found (synthetic regions TSV)." >&2
    exit 2
}

echo "========================================"
echo "Phase 4 — Snakemake parity harness"
echo "========================================"
echo "  Repo root: $REPO_ROOT"
echo "  Bash baseline:  $BASH_OUT"
echo "  Snakemake out:  $SNAKE_OUT"
echo "  Cores: $CORES"
echo ""

# ---------------------------------------------------------------------------
# Step 1: bash baseline (run_tests.sh --quick + step 11)
# ---------------------------------------------------------------------------
if [ "$REFRESH_BASELINE" -eq 1 ]; then
    echo "[1/4] --refresh: removing existing bash baseline ..."
    rm -rf "$BASH_OUT"
fi

if [ ! -d "$BASH_OUT/09_correct" ]; then
    echo "[1/4] Bash baseline missing — running bash tests/run_tests.sh --quick --no-viewer --test 2 ..."
    # `--test 2` runs only the steps 04-10 pipeline block; that's all the
    # parity test compares. Avoid running test 1 (preprocess) and test 8
    # (counting) here — we run step 11 explicitly below with the same
    # parameters the snake config uses.
    bash "$SCRIPT_DIR/run_tests.sh" --quick --no-viewer --test 2 \
        > "$SCRIPT_DIR/output/_bash_baseline.log" 2>&1 || {
            echo "ERROR: bash baseline run_tests.sh failed. Log:" >&2
            tail -50 "$SCRIPT_DIR/output/_bash_baseline.log" >&2
            exit 2
        }
    echo "  Done."
else
    echo "[1/4] Bash baseline already present at $BASH_OUT — skipping."
    echo "      (Use --refresh to force regeneration.)"
fi

# Run step 11 on the bash baseline if not already there.
if [ ! -f "$BASH_OUT/11_count/gene_counts_all.tsv" ]; then
    echo "[1/4] Running bash step 11 (L3Rseq count) on baseline ..."
    "$REPO_ROOT/L3Rseq" count \
        --input "$BASH_OUT" \
        --outdir "$BASH_OUT" \
        --regions "$REGIONS" \
        --min-frac 0.3 \
        > "$SCRIPT_DIR/output/_bash_count.log" 2>&1 || {
            echo "ERROR: bash L3Rseq count failed. Log:" >&2
            tail -50 "$SCRIPT_DIR/output/_bash_count.log" >&2
            exit 2
        }
    echo "  Done."
else
    echo "[1/4] Bash step 11 output already present — skipping."
fi

# ---------------------------------------------------------------------------
# Step 2: pre-stage 03_demux/ + run snakemake
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] Pre-staging snake_quick/03_demux/ from $DEMUX_FIXTURE ..."
rm -rf "$SNAKE_OUT"
mkdir -p "$SNAKE_OUT/03_demux"
# Copy (not symlink) — snakemake's mtime-based resume logic compares against
# the materialized files, and a directory symlink can confuse the checkpoint.
cp -r "$DEMUX_FIXTURE"/barcode01 "$SNAKE_OUT/03_demux/"
cp -r "$DEMUX_FIXTURE"/barcode02 "$SNAKE_OUT/03_demux/"
echo "  Copied $(find "$SNAKE_OUT/03_demux" -name '*.fastq' | wc -l) demuxed FASTQs."

echo ""
echo "[2/4] Running snakemake --cores $CORES --configfile tests/config_synthetic.yaml ..."
SNAKE_LOG="$SCRIPT_DIR/output/_snake_run.log"
if ! "$PY_ENV_BIN/snakemake" \
        --configfile "$CONFIG" \
        --cores "$CORES" \
        > "$SNAKE_LOG" 2>&1; then
    echo "ERROR: snakemake run failed. Log tail:" >&2
    tail -80 "$SNAKE_LOG" >&2
    exit 2
fi
echo "  Done."

# ---------------------------------------------------------------------------
# Step 3: diff step-09 corrected BAMs (samtools view | sort | cmp pattern,
#         lifted from tests/benchmarks/diff_step09.sh)
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Diffing step-09 corrected BAMs ..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

declare -i FAIL=0 OK=0
DRIFT_FILES=()

SAMPLES=(
    "barcode01/barcode01_RPI_1"
    "barcode01/barcode01_RPI_2"
    "barcode02/barcode02_RPI_1"
    "barcode02/barcode02_RPI_2"
)

for bc_rpi in "${SAMPLES[@]}"; do
    rpi="${bc_rpi##*/}"
    bash_bam="$BASH_OUT/09_correct/$bc_rpi/${rpi}_corrected.sort.bam"
    snake_bam="$SNAKE_OUT/09_correct/$bc_rpi/${rpi}_corrected.sort.bam"

    if [ ! -f "$bash_bam" ]; then
        echo "  [MISS] 09_correct/$bc_rpi — bash BAM not found"
        DRIFT_FILES+=("$bash_bam")
        FAIL+=1
        continue
    fi
    if [ ! -f "$snake_bam" ]; then
        echo "  [MISS] 09_correct/$bc_rpi — snake BAM not found"
        DRIFT_FILES+=("$snake_bam")
        FAIL+=1
        continue
    fi

    "$SAMTOOLS" view "$bash_bam"  | sort > "$TMPDIR/bash_$rpi.sam"
    "$SAMTOOLS" view "$snake_bam" | sort > "$TMPDIR/snake_$rpi.sam"

    if cmp -s "$TMPDIR/bash_$rpi.sam" "$TMPDIR/snake_$rpi.sam"; then
        n=$(wc -l < "$TMPDIR/bash_$rpi.sam")
        echo "  [OK]   09_correct/$bc_rpi — $n reads identical"
        OK+=1
    else
        echo "  [FAIL] 09_correct/$bc_rpi — SAM body differs (first 5 diff lines):"
        { diff "$TMPDIR/bash_$rpi.sam" "$TMPDIR/snake_$rpi.sam" || true; } | head -5 | sed 's/^/         /' || true
        DRIFT_FILES+=("$snake_bam")
        FAIL+=1
    fi
done

# ---------------------------------------------------------------------------
# Step 4: diff step-11 outputs (gene counts + coverage; pattern lifted from
#         tests/benchmarks/diff_step11.sh)
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Diffing step-11 gene counts + coverage ..."

# 4a: merged gene_counts_all.tsv — set-equal comparison (rows may be in any
#     order, so sort first)
bash_merged="$BASH_OUT/11_count/gene_counts_all.tsv"
snake_merged="$SNAKE_OUT/11_count/gene_counts_all.tsv"

if [ ! -f "$bash_merged" ]; then
    echo "  [MISS] 11_count/gene_counts_all.tsv — bash side missing"
    DRIFT_FILES+=("$bash_merged")
    FAIL+=1
elif [ ! -f "$snake_merged" ]; then
    echo "  [MISS] 11_count/gene_counts_all.tsv — snake side missing"
    DRIFT_FILES+=("$snake_merged")
    FAIL+=1
else
    bash_rows=$(tail -n +2 "$bash_merged"  | sort)
    snake_rows=$(tail -n +2 "$snake_merged" | sort)
    if [ "$bash_rows" = "$snake_rows" ]; then
        n=$(echo "$bash_rows" | wc -l)
        echo "  [OK]   11_count/gene_counts_all.tsv — $n rows identical (set-equal)"
        OK+=1
    else
        echo "  [FAIL] 11_count/gene_counts_all.tsv — set differs (first 5 diff lines):"
        { diff <(echo "$bash_rows") <(echo "$snake_rows") || true; } | head -5 | sed 's/^/         /' || true
        DRIFT_FILES+=("$snake_merged")
        FAIL+=1
    fi
fi

# 4b: per-sample gene_counts.tsv files
for bc_rpi in "${SAMPLES[@]}"; do
    bc="${bc_rpi%%/*}"
    rpi="${bc_rpi##*/}"
    fname="${bc}_${rpi}_gene_counts.tsv"
    bash_per="$BASH_OUT/11_count/$fname"
    snake_per="$SNAKE_OUT/11_count/$fname"

    if [ ! -f "$bash_per" ] || [ ! -f "$snake_per" ]; then
        echo "  [MISS] 11_count/$fname — one side missing (bash=$( [ -f "$bash_per" ] && echo present || echo missing), snake=$( [ -f "$snake_per" ] && echo present || echo missing))"
        DRIFT_FILES+=("$snake_per")
        FAIL+=1
        continue
    fi
    bash_pl=$(tail -n +2 "$bash_per"  | sort)
    snake_pl=$(tail -n +2 "$snake_per" | sort)
    if [ "$bash_pl" = "$snake_pl" ]; then
        echo "  [OK]   11_count/$fname identical (set-equal)"
        OK+=1
    else
        echo "  [FAIL] 11_count/$fname — differs (first 5 diff lines):"
        { diff <(echo "$bash_pl") <(echo "$snake_pl") || true; } | head -5 | sed 's/^/         /' || true
        DRIFT_FILES+=("$snake_per")
        FAIL+=1
    fi
done

# 4c: coverage depth files
declare -i COV_OK=0 COV_FAIL=0
for bash_cov in "$BASH_OUT"/11_count/coverage/*.depth.tsv; do
    [ -f "$bash_cov" ] || continue
    fname=$(basename "$bash_cov")
    snake_cov="$SNAKE_OUT/11_count/coverage/$fname"
    if [ ! -f "$snake_cov" ]; then
        echo "  [FAIL] 11_count/coverage/$fname — snake side missing"
        DRIFT_FILES+=("$snake_cov")
        COV_FAIL+=1
        continue
    fi
    if cmp -s "$bash_cov" "$snake_cov"; then
        COV_OK+=1
    else
        echo "  [FAIL] 11_count/coverage/$fname — bytes differ"
        DRIFT_FILES+=("$snake_cov")
        COV_FAIL+=1
    fi
done
if [ "$COV_FAIL" -eq 0 ] && [ "$COV_OK" -gt 0 ]; then
    echo "  [OK]   11_count/coverage/*.depth.tsv — all $COV_OK files identical"
    OK+=1
elif [ "$COV_FAIL" -gt 0 ]; then
    FAIL+=$COV_FAIL
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
if [ "$FAIL" -eq 0 ]; then
    echo "PARITY OK — $OK comparison group(s) identical"
    echo "========================================"
    exit 0
else
    echo "DRIFT DETECTED — $FAIL comparison group(s) differ, $OK matched"
    echo ""
    echo "Drifted files:"
    for f in "${DRIFT_FILES[@]}"; do
        echo "  - $f"
    done
    echo "========================================"
    exit 1
fi
