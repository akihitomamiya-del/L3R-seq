#!/bin/bash
# tests/benchmarks/bench_step09.sh — Baseline wall-clock timing for bash step 09.
#
# Captures "before" numbers for the Phase 1b pysam rewrite. The comparison
# point for the Python version is the reads/sec column in docs/step09_baseline.md.
#
# Prerequisites:
#   bash tests/run_tests.sh --quick --no-viewer   # generates tests/output/pipeline_CT/
#
# Usage:
#   bash tests/benchmarks/bench_step09.sh
#
# Re-run after Phase 1b lands and diff the reads/sec against this baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

INPUT_DIR="tests/output/pipeline_CT"
REF="resources/references/test_gene.fasta"
RESULTS="docs/step09_baseline.md"
SAMTOOLS="/opt/miniforge/envs/NanoporeMap/bin/samtools"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ ! -d "$INPUT_DIR/07_map" ]; then
    cat <<EOF >&2
ERROR: $INPUT_DIR/07_map not found.

Run the quick test suite first to generate the step 07 input fixtures:

    bash tests/run_tests.sh --quick --no-viewer

Then re-run this benchmark.
EOF
    exit 1
fi

if [ ! -x "$SAMTOOLS" ]; then
    echo "ERROR: $SAMTOOLS not found. Is the NanoporeMap env installed?" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Count input reads across all samples (for reads/sec calculation)
# ---------------------------------------------------------------------------
TOTAL_READS=0
SAMPLE_LINES=""
while IFS= read -r -d '' sam; do
    n=$("$SAMTOOLS" view -c "$sam" 2>/dev/null || echo 0)
    base="${sam##*/}"
    name="${base%_mapped_only.sam}"
    SAMPLE_LINES="${SAMPLE_LINES}- \`${name}\`: ${n} reads"$'\n'
    TOTAL_READS=$((TOTAL_READS + n))
done < <(find "$INPUT_DIR/07_map" -name '*_mapped_only.sam' -print0)

if [ "$TOTAL_READS" -eq 0 ]; then
    echo "ERROR: Found no reads in $INPUT_DIR/07_map/*/*/*_mapped_only.sam" >&2
    exit 1
fi

echo "[bench] Input: ${TOTAL_READS} reads total across $(echo -n "$SAMPLE_LINES" | wc -l) samples"
echo ""

# ---------------------------------------------------------------------------
# Run L3Rseq correct (step 09 in isolation) with different thread counts.
# Each run uses a fresh temp output dir so runs don't interfere; 08_variants
# is symlinked in so the walk algorithm can use the editing-variant tolerance
# path (matches real pipeline semantics).
# ---------------------------------------------------------------------------
TABLE_ROWS=""
for threads in 1 2 4; do
    BENCH_OUT=$(mktemp -d)
    ln -s "$REPO_ROOT/$INPUT_DIR/08_variants" "$BENCH_OUT/08_variants"

    echo "[bench] Running step 09 with --threads $threads ..."
    START=$SECONDS
    if ! ./L3Rseq correct \
        --input "$INPUT_DIR/07_map" \
        --outdir "$BENCH_OUT" \
        --ref "$REF" \
        --pattern CT \
        --threads "$threads" \
        > "$BENCH_OUT/step09.log" 2>&1; then
        echo "ERROR: L3Rseq correct failed for --threads $threads" >&2
        tail -30 "$BENCH_OUT/step09.log" >&2
        rm -rf "$BENCH_OUT"
        exit 1
    fi
    ELAPSED=$((SECONDS - START))

    if [ "$ELAPSED" -gt 0 ]; then
        RPS=$((TOTAL_READS / ELAPSED))
    else
        RPS="> ${TOTAL_READS}"
    fi
    TABLE_ROWS="${TABLE_ROWS}| ${threads} | ${ELAPSED} | ${RPS} |"$'\n'
    echo "  --threads ${threads}: ${ELAPSED}s  (${RPS} reads/sec)"

    rm -rf "$BENCH_OUT"
done

# ---------------------------------------------------------------------------
# Write markdown report
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$RESULTS")"
cat > "$RESULTS" <<EOF
# Step 09 Baseline Benchmarks (bash)

Baseline wall-clock timing for \`scripts/09_tail_correct.sh\` captured
**before** the Phase 1b pysam rewrite. The reads/sec column is the
comparison point for the Python replacement — Python+pysam is expected
to be 2–5× faster per the modernization plan
(\`docs/PIPELINE_MODERNIZATION.md\`).

## Environment

- Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Host: $(uname -sr) $(uname -m)
- CPUs available: $(nproc)
- Git commit: $(git rev-parse --short HEAD)
- Branch: $(git rev-parse --abbrev-ref HEAD)
- Test data: \`${INPUT_DIR}/07_map/\` (synthetic quick-test fixtures)

## Input size

- Total reads across all samples: **${TOTAL_READS}**

Per-sample breakdown:

${SAMPLE_LINES}
## Step 09 wall-clock time (bash implementation)

| Threads | Wall time (s) | Reads/sec |
|---:|---:|---:|
${TABLE_ROWS}
## Interpretation

The quick-test fixtures are tiny (~2k reads) so absolute timings are
small and the sub-second resolution of the bash \`SECONDS\` builtin may
round some runs to 0. What's meaningful is the **ratio** between
reads/sec for bash (here) vs. reads/sec for the Python rewrite (after
Phase 1b). Re-run this script on the same commit immediately after the
Python dispatcher switch lands and compare the columns directly.

For more representative numbers, run the benchmark against a real
dataset — e.g., \`runs/LibCheck/07_map/\` — by editing \`INPUT_DIR\` at
the top of this script.

## Known limitations of this baseline

- Wall-clock only. Peak RSS is not captured because \`/usr/bin/time\` is
  not installed in the devcontainer; use \`ps\` or \`/proc/self/status\`
  in a follow-up if memory becomes a concern.
- No CPU pinning or warm-up. Numbers can vary ±10% between runs.
- 08_variants/ is symlinked from the existing pipeline output, so the
  walk algorithm uses the real editing-variant tolerance path.
- BLAST DBs are NOT configured — the chimera detection path is skipped.
  If you want to include it, point \`--blast-db\` at a real DB.

## Re-running

\`\`\`bash
bash tests/benchmarks/bench_step09.sh
\`\`\`
EOF

echo ""
echo "[bench] Wrote baseline to: $RESULTS"
echo ""
echo "=== $RESULTS ==="
cat "$RESULTS"
