# Step 09 Baseline Benchmarks (bash)

Baseline wall-clock timing for `scripts/09_tail_correct.sh` captured
**before** the Phase 1b pysam rewrite. The reads/sec column (using the
**min** wall time across iterations, i.e., best case) is the comparison
point for the Python replacement — Python+pysam is expected to be 2–5×
faster per the modernization plan (`docs/PIPELINE_MODERNIZATION.md`).

## Environment

- Captured: 2026-04-09T15:29:29Z
- Host: Linux 6.12.76-linuxkit aarch64
- CPUs available: 8
- Git commit: 41e9080
- Branch: pipeline-modernization
- Test data: `tests/output/pipeline_CT/07_map/` (synthetic quick-test fixtures)
- Iterations per thread count: 3

## Input size

- Total reads across all samples: **434**

Per-sample breakdown:

- `barcode02_RPI_1`: 111 reads
- `barcode02_RPI_2`: 118 reads
- `barcode01_RPI_1`: 99 reads
- `barcode01_RPI_2`: 106 reads

## Step 09 wall-clock time (bash implementation)

Sub-second timing via `date +%s.%N`. **Min** is the best-case run
(fastest of 3 iterations); **median** and **mean** are shown
for dispersion context. Reads/sec is computed from the min time.

| Threads | Min (s) | Median (s) | Mean (s) | Reads/sec (best) |
|---:|---:|---:|---:|---:|
| 1 | 6.674 | 6.990 | 6.906 | 65 |
| 2 | 4.297 | 4.309 | 4.381 | 101 |
| 4 | 3.530 | 3.645 | 3.614 | 123 |

### Raw per-iteration data

| Threads | Iteration | Elapsed (s) |
|---:|---:|---:|
| 1 | 1 | 6.990 |
| 1 | 2 | 6.674 |
| 1 | 3 | 7.055 |
| 2 | 1 | 4.538 |
| 2 | 2 | 4.297 |
| 2 | 3 | 4.309 |
| 4 | 1 | 3.645 |
| 4 | 2 | 3.530 |
| 4 | 3 | 3.668 |

## Interpretation

The quick-test fixtures are tiny (434 reads across 4 samples)
so absolute timings are small. What's meaningful is:

1. **The ratio** between bash reads/sec (here) vs. Python reads/sec
   (after Phase 1b). Re-run this script on the same commit after the
   dispatcher switch and divide.
2. **The scaling curve** across thread counts. A speedup that flattens
   past a certain thread count indicates a serialization bottleneck —
   for the bash version, that's per-read subprocess spawning (fork +
   exec of awk/grep/cut/cat × ~10 per read). The Python version
   eliminates this: `pysam.AlignmentFile` iterates at htslib speed
   and the per-read work is in-process.

For more representative absolute numbers, run against a real dataset
(e.g., `runs/LibCheck/07_map/`) by editing `INPUT_DIR` at the top
of the script.

## Known limitations of this baseline

- Wall-clock only. Peak RSS is not captured because `/usr/bin/time`
  is not installed in the devcontainer. Memory will be measured in the
  Phase 1b benchmark via `psutil` if we need it.
- No CPU pinning or warm-up. The min-over-3-runs approach
  filters out most noise but not all.
- BLAST DBs are NOT configured — the chimera detection path is skipped
  (step 09 falls back to walk-only correction). Real pipeline runs with
  a populated blast-db will be slower.
- 08_variants/ is symlinked from the existing pipeline output, so the
  walk algorithm uses the real editing-variant tolerance path.

## Re-running

```bash
bash tests/benchmarks/bench_step09.sh              # default 3 iterations
ITERATIONS=5 bash tests/benchmarks/bench_step09.sh # more precision
```
