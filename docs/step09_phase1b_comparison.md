# Step 09 Phase 1b — Bash vs Python head-to-head

Side-by-side wall-clock comparison of scripts/09_tail_correct.sh
(bash) and src/l3rseq/tail_correct.py (pysam) on the same
quick-test fixtures. The Python implementation is byte-identical to
the bash implementation — see tests/benchmarks/diff_step09.sh for
the correctness proof.

## Environment

- Captured: 2026-04-09T16:56:12Z
- Host: Linux 6.12.76-linuxkit aarch64
- CPUs available: 8
- Git commit: 5aacacc
- Branch: pipeline-modernization
- Test data: `tests/output/pipeline_CT/07_map/` (434 reads)
- Iterations per thread count: 3
- Engine commands:
  - bash: `./L3Rseq correct --input … --outdir … --ref … --pattern CT --threads N`
  - python: `PYTHONPATH=src python -m l3rseq.tail_correct --input … --outdir … --ref … --pattern CT --variants-dir … --threads N`

## Head-to-head wall time (min of 3 iterations)

| Threads | Bash min (s) | Bash r/s | Python min (s) | Python r/s | Speedup |
|---:|---:|---:|---:|---:|---:|
| 1 | 6.629 | 65 | 0.145 | 2993 | 45.72× |
| 2 | 4.358 | 100 | 0.140 | 3100 | 31.13× |
| 4 | 3.487 | 124 | 0.139 | 3122 | 25.09× |

### Raw iterations

| Engine | Threads | Iter | Elapsed (s) |
|---|---:|---:|---:|
| bash | 1 | 1 | 6.943 |
| bash | 1 | 2 | 6.743 |
| bash | 1 | 3 | 6.629 |
| bash | 2 | 1 | 4.521 |
| bash | 2 | 2 | 4.371 |
| bash | 2 | 3 | 4.358 |
| bash | 4 | 1 | 3.548 |
| bash | 4 | 2 | 3.487 |
| bash | 4 | 3 | 3.542 |
| python | 1 | 1 | 0.156 |
| python | 1 | 2 | 0.145 |
| python | 1 | 3 | 0.199 |
| python | 2 | 1 | 0.140 |
| python | 2 | 2 | 0.149 |
| python | 2 | 3 | 0.142 |
| python | 4 | 1 | 0.141 |
| python | 4 | 2 | 0.139 |
| python | 4 | 3 | 0.141 |

## Interpretation

The Python implementation replaces the per-read subprocess-spawn loop
(~8-12 child process invocations per read under `_process_one_read`
in bash) with in-process pysam iteration. On this tiny fixture the
win is modest in absolute terms (~2k reads total), but the **ratio**
in the Speedup column is what matters — it'll hold or improve on
real 50k-read samples where the bash spawn overhead dominates even
more.

The ratio is the gating number for Phase 1c (bash-09 fate decision).
Targets from docs/PIPELINE_MODERNIZATION.md:
  - Minimum: 1.6× speedup at 4 threads (≥ 200 reads/sec)
  - Stretch: 3.3× (≥ 400 reads/sec)

## Re-running

```bash
bash tests/benchmarks/bench_step09_compare.sh              # 3 iterations (default)
ITERATIONS=5 bash tests/benchmarks/bench_step09_compare.sh # tighter numbers
```

## Known limitations

- Wall-clock only (no peak RSS; `/usr/bin/time` not available).
- Python `--threads` is currently ignored (single-threaded orchestrator);
  its column shows the same numbers at each thread count. The speedup
  is achieved without parallelism, which is the key finding — the bash
  ~2× gain from 1→4 threads is entirely replaced by the constant-factor
  win of avoiding subprocess spawns.
- BLAST DBs are NOT configured — the chimera detection path is skipped.
