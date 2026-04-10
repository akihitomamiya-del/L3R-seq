#!/bin/bash
# tests/benchmarks/diff_step09.sh — Byte-identical BAM comparison between
# the bash step 09 (scripts/09_tail_correct.sh) and the Python rewrite
# (src/l3rseq/tail_correct.py).
#
# This is the correctness gate for Phase 1b. Before switching the L3Rseq
# dispatcher to call Python instead of bash, this script must report
# "ALL SAMPLES IDENTICAL" on the quick-test fixtures.
#
# Prerequisites:
#   bash tests/run_tests.sh --quick --no-viewer
#   # generates tests/output/pipeline_CT/{07_map,08_variants,09_correct}
#
# Usage:
#   bash tests/benchmarks/diff_step09.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

INPUT_DIR="tests/output/pipeline_CT"
REF="resources/references/test_gene.fasta"
SAMTOOLS="/opt/miniforge/envs/NanoporeMap/bin/samtools"
PY_ENV_BIN="/opt/miniforge/envs/l3rseq_py/bin/python"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ ! -d "$INPUT_DIR/07_map" ]; then
    echo "ERROR: $INPUT_DIR/07_map not found." >&2
    echo "Run 'bash tests/run_tests.sh --quick --no-viewer' first." >&2
    exit 1
fi

if [ ! -x "$PY_ENV_BIN" ]; then
    echo "ERROR: $PY_ENV_BIN not found. Is the l3rseq_py env installed?" >&2
    echo "If not, rebuild the devcontainer (see docs/PIPELINE_MODERNIZATION.md)." >&2
    exit 1
fi

if [ ! -x "$SAMTOOLS" ]; then
    echo "ERROR: $SAMTOOLS not found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Run BOTH engines into fresh temp dirs so the comparison is meaningful
# even after cmd_correct in L3Rseq was switched to Python. We invoke the
# bash subscripts directly via `source` + `run_step_09`, bypassing the
# dispatcher entirely.
# ---------------------------------------------------------------------------
BASH_OUT=$(mktemp -d)
PY_OUT=$(mktemp -d)
trap 'rm -rf "$BASH_OUT" "$PY_OUT"' EXIT

echo "[diff] Running BASH step 09 (scripts/09_tail_correct.sh directly) ..."
(
    # shellcheck source=/dev/null
    source /opt/miniforge/etc/profile.d/conda.sh
    conda activate NanoporeMap
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/legacy/09_tail_correct.sh"
    # run_step_09 args: input_dir output_dir ref var pattern blast1 blast2 clip_thresh variants_dir threads count_pattern introns
    run_step_09 \
        "$INPUT_DIR/07_map" \
        "$BASH_OUT" \
        "$REF" \
        "" \
        "CT" \
        "" \
        "" \
        50 \
        "$INPUT_DIR/08_variants" \
        1 \
        "" \
        ""
    conda deactivate
) 2>&1 | sed 's/^/  /'

echo ""
echo "[diff] Running PYTHON step 09 (python -m l3rseq.tail_correct) ..."
PYTHONPATH="$REPO_ROOT/src" "$PY_ENV_BIN" -m l3rseq.tail_correct \
    --input "$INPUT_DIR/07_map" \
    --outdir "$PY_OUT" \
    --ref "$REF" \
    --pattern CT \
    --variants-dir "$INPUT_DIR/08_variants" \
    --threads 1 \
    2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Compare each sample's corrected.sort.bam via samtools view | sort | cmp
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$BASH_OUT" "$PY_OUT" "$TMPDIR"' EXIT

echo ""
echo "[diff] Comparing BAMs ..."
FAIL=0
TOTAL=0
for bc_rpi in barcode01/barcode01_RPI_1 barcode01/barcode01_RPI_2 barcode02/barcode02_RPI_1 barcode02/barcode02_RPI_2; do
    rpi=${bc_rpi##*/}
    bash_bam="$BASH_OUT/09_correct/$bc_rpi/${rpi}_corrected.sort.bam"
    py_bam="$PY_OUT/09_correct/$bc_rpi/${rpi}_corrected.sort.bam"
    TOTAL=$((TOTAL + 1))

    if [ ! -f "$bash_bam" ]; then
        echo "  [MISS] $bc_rpi — bash BAM not found"
        FAIL=$((FAIL + 1))
        continue
    fi
    if [ ! -f "$py_bam" ]; then
        echo "  [MISS] $bc_rpi — Python BAM not found"
        FAIL=$((FAIL + 1))
        continue
    fi

    "$SAMTOOLS" view "$bash_bam" | sort > "$TMPDIR/bash_$rpi.txt"
    "$SAMTOOLS" view "$py_bam"   | sort > "$TMPDIR/py_$rpi.txt"

    if cmp -s "$TMPDIR/bash_$rpi.txt" "$TMPDIR/py_$rpi.txt"; then
        read_count=$(wc -l < "$TMPDIR/bash_$rpi.txt")
        echo "  [OK]   $bc_rpi — $read_count reads identical"
    else
        echo "  [FAIL] $bc_rpi — diff follows:"
        diff "$TMPDIR/bash_$rpi.txt" "$TMPDIR/py_$rpi.txt" | head -20 | sed 's/^/         /'
        FAIL=$((FAIL + 1))
    fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "========================================"
    echo "ALL $TOTAL SAMPLES IDENTICAL ✓"
    echo "========================================"
    exit 0
else
    echo "========================================"
    echo "$FAIL / $TOTAL SAMPLES DIFFER ✗"
    echo "========================================"
    exit 1
fi
