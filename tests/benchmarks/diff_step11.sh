#!/bin/bash
# diff_step11.sh — Differential test: bash step 11 vs. Python step 11
#
# Runs both implementations on the same quick-test fixture and compares:
#   1. gene_counts_all.tsv total counts per (gene, sample) — must be equal
#   2. Per-sample gene_counts.tsv total_count columns — must be equal
#   3. Coverage .depth.tsv files — must be byte-identical
#
# Requires: tests/output/pipeline_CT/ exists (from `bash tests/run_tests.sh --quick`)
#
# Usage: bash tests/benchmarks/diff_step11.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/output/pipeline_CT"
REGIONS="$REPO_ROOT/tests/data/test_regions.tsv"
PY_ENV="/opt/miniforge/envs/l3rseq_py/bin"
MAP_ENV="/opt/miniforge/envs/NanoporeMap/bin"

if [ ! -d "$FIXTURE/09_correct" ]; then
    echo "ERROR: $FIXTURE/09_correct not found. Run 'bash tests/run_tests.sh --quick --no-viewer' first."
    exit 1
fi

BASH_OUT=$(mktemp -d)
PY_OUT=$(mktemp -d)
trap "rm -rf $BASH_OUT $PY_OUT" EXIT

echo "=== Differential test: bash vs. Python step 11 ==="
echo "  Fixture: $FIXTURE"
echo "  Regions: $REGIONS"
echo "  Bash output: $BASH_OUT"
echo "  Python output: $PY_OUT"
echo ""

# --- Run bash step 11 ---
echo "[1/4] Running bash step 11 ..."
source /opt/miniforge/etc/profile.d/conda.sh
conda activate NanoporeMap
bash -c "
    _summary_append() { :; }
    export -f _summary_append
    source '$REPO_ROOT/scripts/lib.sh'
    source '$REPO_ROOT/scripts/11_count.sh'
    run_step_11 '$FIXTURE' '$BASH_OUT' '$REGIONS' '' 0.3 0
" > /dev/null 2>&1
conda deactivate
echo "  Done."

# --- Run Python step 11 ---
echo "[2/4] Running Python step 11 ..."
PYTHONPATH="$REPO_ROOT/src" "$PY_ENV/python" -m l3rseq.count \
    --input "$FIXTURE" \
    --outdir "$PY_OUT" \
    --regions "$REGIONS" \
    --min-frac 0.3 \
    --min-mapq 0 \
    --scripts-dir "$REPO_ROOT/scripts" > /dev/null 2>&1
echo "  Done."

# --- Compare total counts ---
echo "[3/4] Comparing gene_counts_all.tsv ..."
FAIL=0

# Extract (gene, sample, total) triples, sorted for stable comparison.
# Column layout: gene sample total_count splice_pattern pattern_count
bash_totals=$(awk -F'\t' 'NR>1 {k=$1"\t"$2; if(!(k in seen)){seen[k]=1; print $1"\t"$2"\t"$3}}' \
    "$BASH_OUT/11_count/gene_counts_all.tsv" | sort)
py_totals=$(awk -F'\t' 'NR>1 {k=$1"\t"$2; if(!(k in seen)){seen[k]=1; print $1"\t"$2"\t"$3}}' \
    "$PY_OUT/11_count/gene_counts_all.tsv" | sort)

if [ "$bash_totals" = "$py_totals" ]; then
    echo "  ✓ Merged totals MATCH"
else
    echo "  ✗ Merged totals DIFFER"
    diff <(echo "$bash_totals") <(echo "$py_totals")
    FAIL=1
fi

# Compare set of (gene, sample, pattern, count) tuples (order-insensitive)
bash_tuples=$(tail -n +2 "$BASH_OUT/11_count/gene_counts_all.tsv" | sort)
py_tuples=$(tail -n +2 "$PY_OUT/11_count/gene_counts_all.tsv" | sort)

if [ "$bash_tuples" = "$py_tuples" ]; then
    echo "  ✓ Pattern tuples MATCH (set-equal)"
else
    echo "  ✗ Pattern tuples DIFFER"
    diff <(echo "$bash_tuples") <(echo "$py_tuples")
    FAIL=1
fi

# --- Compare coverage files ---
echo "[4/4] Comparing coverage files ..."
COV_MATCH=0
COV_DIFF=0
for bash_cov in "$BASH_OUT"/11_count/coverage/*.depth.tsv; do
    [ -f "$bash_cov" ] || continue
    fname=$(basename "$bash_cov")
    py_cov="$PY_OUT/11_count/coverage/$fname"
    if [ ! -f "$py_cov" ]; then
        echo "  ✗ Missing Python coverage: $fname"
        COV_DIFF=$((COV_DIFF + 1))
        continue
    fi
    if cmp -s "$bash_cov" "$py_cov"; then
        COV_MATCH=$((COV_MATCH + 1))
    else
        echo "  ✗ Coverage differs: $fname"
        COV_DIFF=$((COV_DIFF + 1))
    fi
done

if [ "$COV_DIFF" -eq 0 ]; then
    echo "  ✓ All $COV_MATCH coverage files MATCH"
else
    echo "  ✗ $COV_DIFF coverage file(s) differ"
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "ALL MATCH ✓"
    exit 0
else
    echo "DIFFERENCES FOUND ✗"
    exit 1
fi
