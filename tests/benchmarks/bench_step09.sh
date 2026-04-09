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
#   ITERATIONS=5 bash tests/benchmarks/bench_step09.sh   # override default
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
ITERATIONS="${ITERATIONS:-3}"
THREAD_COUNTS=(1 2 4)

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
# Sub-second timer — bash SECONDS only gives integer resolution, so a 2.3s
# run and a 1.7s run both round to "2s". Use date +%s.%N and python3 for the
# subtraction so we can tell them apart.
# ---------------------------------------------------------------------------
timer_start() { date +%s.%N; }
timer_elapsed() {
    local start="$1"
    local end
    end=$(date +%s.%N)
    python3 -c "print(f'{$end - $start:.3f}')"
}

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

echo "[bench] Input: ${TOTAL_READS} reads across $(find "$INPUT_DIR/07_map" -name '*_mapped_only.sam' | wc -l) samples"
echo "[bench] Thread counts: ${THREAD_COUNTS[*]}"
echo "[bench] Iterations per thread count: ${ITERATIONS}"
echo ""

# ---------------------------------------------------------------------------
# Run L3Rseq correct (step 09 in isolation) with each thread count × N iters.
# Each iteration uses a fresh temp output dir; 08_variants/ is symlinked in
# so the walk algorithm uses the real editing-variant tolerance path.
# ---------------------------------------------------------------------------
RAW_CSV=$(mktemp)
echo "threads,iteration,elapsed_sec" > "$RAW_CSV"

for threads in "${THREAD_COUNTS[@]}"; do
    echo "[bench] --threads ${threads}:"
    for iter in $(seq 1 "$ITERATIONS"); do
        BENCH_OUT=$(mktemp -d)
        ln -s "$REPO_ROOT/$INPUT_DIR/08_variants" "$BENCH_OUT/08_variants"

        START=$(timer_start)
        if ! ./L3Rseq correct \
            --input "$INPUT_DIR/07_map" \
            --outdir "$BENCH_OUT" \
            --ref "$REF" \
            --pattern CT \
            --threads "$threads" \
            > "$BENCH_OUT/step09.log" 2>&1; then
            echo "ERROR: L3Rseq correct failed for --threads $threads iter $iter" >&2
            tail -30 "$BENCH_OUT/step09.log" >&2
            rm -rf "$BENCH_OUT"
            exit 1
        fi
        ELAPSED=$(timer_elapsed "$START")
        echo "    iter ${iter}: ${ELAPSED}s"
        echo "${threads},${iter},${ELAPSED}" >> "$RAW_CSV"

        rm -rf "$BENCH_OUT"
    done
done

# ---------------------------------------------------------------------------
# Compute stats (min/median/mean) per thread count using python
# ---------------------------------------------------------------------------
STATS_TABLE=$(python3 - "$RAW_CSV" "$TOTAL_READS" <<'PY'
import csv, statistics, sys
csv_path, total_reads = sys.argv[1], int(sys.argv[2])
by_threads: dict[int, list[float]] = {}
with open(csv_path) as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        by_threads.setdefault(int(row["threads"]), []).append(float(row["elapsed_sec"]))

rows = []
for threads in sorted(by_threads):
    times = sorted(by_threads[threads])
    tmin = times[0]
    tmedian = statistics.median(times)
    tmean = statistics.mean(times)
    # Use the MIN time for reads/sec (best case, least noise)
    rps = total_reads / tmin if tmin > 0 else float("inf")
    rows.append(
        f"| {threads} | {tmin:.3f} | {tmedian:.3f} | {tmean:.3f} | {rps:.0f} |"
    )
print("\n".join(rows))
PY
)

RAW_TABLE=$(python3 - "$RAW_CSV" <<'PY'
import csv, sys
csv_path = sys.argv[1]
rows = []
with open(csv_path) as fh:
    reader = csv.DictReader(fh)
    for row in reader:
        rows.append(f"| {row['threads']} | {row['iteration']} | {float(row['elapsed_sec']):.3f} |")
print("\n".join(rows))
PY
)

rm -f "$RAW_CSV"

# ---------------------------------------------------------------------------
# Write markdown report
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$RESULTS")"
cat > "$RESULTS" <<EOF
# Step 09 Baseline Benchmarks (bash)

Baseline wall-clock timing for \`scripts/09_tail_correct.sh\` captured
**before** the Phase 1b pysam rewrite. The reads/sec column (using the
**min** wall time across iterations, i.e., best case) is the comparison
point for the Python replacement — Python+pysam is expected to be 2–5×
faster per the modernization plan (\`docs/PIPELINE_MODERNIZATION.md\`).

## Environment

- Captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Host: $(uname -sr) $(uname -m)
- CPUs available: $(nproc)
- Git commit: $(git rev-parse --short HEAD)
- Branch: $(git rev-parse --abbrev-ref HEAD)
- Test data: \`${INPUT_DIR}/07_map/\` (synthetic quick-test fixtures)
- Iterations per thread count: ${ITERATIONS}

## Input size

- Total reads across all samples: **${TOTAL_READS}**

Per-sample breakdown:

${SAMPLE_LINES}
## Step 09 wall-clock time (bash implementation)

Sub-second timing via \`date +%s.%N\`. **Min** is the best-case run
(fastest of ${ITERATIONS} iterations); **median** and **mean** are shown
for dispersion context. Reads/sec is computed from the min time.

| Threads | Min (s) | Median (s) | Mean (s) | Reads/sec (best) |
|---:|---:|---:|---:|---:|
${STATS_TABLE}

### Raw per-iteration data

| Threads | Iteration | Elapsed (s) |
|---:|---:|---:|
${RAW_TABLE}

## Interpretation

The quick-test fixtures are tiny (${TOTAL_READS} reads across 4 samples)
so absolute timings are small. What's meaningful is:

1. **The ratio** between bash reads/sec (here) vs. Python reads/sec
   (after Phase 1b). Re-run this script on the same commit after the
   dispatcher switch and divide.
2. **The scaling curve** across thread counts. A speedup that flattens
   past a certain thread count indicates a serialization bottleneck —
   for the bash version, that's per-read subprocess spawning (fork +
   exec of awk/grep/cut/cat × ~10 per read). The Python version
   eliminates this: \`pysam.AlignmentFile\` iterates at htslib speed
   and the per-read work is in-process.

For more representative absolute numbers, run against a real dataset
(e.g., \`runs/LibCheck/07_map/\`) by editing \`INPUT_DIR\` at the top
of the script.

## Known limitations of this baseline

- Wall-clock only. Peak RSS is not captured because \`/usr/bin/time\`
  is not installed in the devcontainer. Memory will be measured in the
  Phase 1b benchmark via \`psutil\` if we need it.
- No CPU pinning or warm-up. The min-over-${ITERATIONS}-runs approach
  filters out most noise but not all.
- BLAST DBs are NOT configured — the chimera detection path is skipped
  (step 09 falls back to walk-only correction). Real pipeline runs with
  a populated blast-db will be slower.
- 08_variants/ is symlinked from the existing pipeline output, so the
  walk algorithm uses the real editing-variant tolerance path.

## Re-running

\`\`\`bash
bash tests/benchmarks/bench_step09.sh              # default 3 iterations
ITERATIONS=5 bash tests/benchmarks/bench_step09.sh # more precision
\`\`\`
EOF

echo ""
echo "[bench] Wrote baseline to: $RESULTS"
echo ""
echo "=== Summary ==="
echo "$STATS_TABLE"
