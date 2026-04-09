# Step 09 Baseline Benchmarks (bash)

Baseline wall-clock timing for `scripts/09_tail_correct.sh` captured
**before** the Phase 1b pysam rewrite. The reads/sec column is the
comparison point for the Python replacement — Python+pysam is expected
to be 2–5× faster per the modernization plan
(`docs/PIPELINE_MODERNIZATION.md`).

## Environment

- Captured: 2026-04-09T15:22:28Z
- Host: Linux 6.12.76-linuxkit aarch64
- CPUs available: 8
- Git commit: ab34d85
- Branch: pipeline-modernization
- Test data: `tests/output/pipeline_CT/07_map/` (synthetic quick-test fixtures)

## Input size

- Total reads across all samples: **434**

Per-sample breakdown:

- `barcode02_RPI_1`: 111 reads
- `barcode02_RPI_2`: 118 reads
- `barcode01_RPI_1`: 99 reads
- `barcode01_RPI_2`: 106 reads

## Step 09 wall-clock time (bash implementation)

| Threads | Wall time (s) | Reads/sec |
|---:|---:|---:|
| 1 | 7 | 62 |
| 2 | 4 | 108 |
| 4 | 4 | 108 |

## Interpretation

The quick-test fixtures are tiny (~2k reads) so absolute timings are
small and the sub-second resolution of the bash `SECONDS` builtin may
round some runs to 0. What's meaningful is the **ratio** between
reads/sec for bash (here) vs. reads/sec for the Python rewrite (after
Phase 1b). Re-run this script on the same commit immediately after the
Python dispatcher switch lands and compare the columns directly.

For more representative numbers, run the benchmark against a real
dataset — e.g., `runs/LibCheck/07_map/` — by editing `INPUT_DIR` at
the top of this script.

## Known limitations of this baseline

- Wall-clock only. Peak RSS is not captured because `/usr/bin/time` is
  not installed in the devcontainer; use `ps` or `/proc/self/status`
  in a follow-up if memory becomes a concern.
- No CPU pinning or warm-up. Numbers can vary ±10% between runs.
- 08_variants/ is symlinked from the existing pipeline output, so the
  walk algorithm uses the real editing-variant tolerance path.
- BLAST DBs are NOT configured — the chimera detection path is skipped.
  If you want to include it, point `--blast-db` at a real DB.

## Re-running

```bash
bash tests/benchmarks/bench_step09.sh
```
