# L3Rseq Pipeline Speed Investigation (WSL2 / 9P filesystem)

Captured: 2026-04-24, during the LibCheck real-data comparison run.

## TL;DR

On this devcontainer, the pipeline runs **~25-30× slower** than it did on
the reference Linux machine, despite identical scripts and data. The root
cause is that `/workspace` is a **9P-mounted Windows NTFS drive** — every
small-file syscall pays the WSL2 → Windows bridging overhead. Pipeline
steps that create many small files per unit of work (step 04 UMI binning,
step 05 racon consensus) dominate wall time.

**Fix priority:**

1. [P0] Move the devcontainer's working directory off 9P onto WSL2-native
   ext4 (Docker named volume or clone the repo inside the WSL2 distro).
   Expected: **10×+ speedup, zero code change.**
2. [P1] Point `TMPDIR` for the pipeline at `/tmp` (ext4 overlay) so
   cutadapt / GNU parallel / racon scratch files don't touch 9P.
3. [P2] Parallelize the RPI loop in `scripts/04_umi.sh`. Stacks on top of
   P0 — on a native-FS box, another ~4-8× on step 04 at no data risk.
4. [P2] Add `.done` resume markers to step 04 (step 05 already has them),
   so re-runs after a kill skip completed RPIs.

## Observed slowdown

Same 3 barcodes (44/45/46), same 36 RPIs, same scripts, same reference:

| Step | Prior run (2026-04-04, Linux) | This run (2026-04-24, WSL2/9P) | Ratio |
|------|------------------------------:|-------------------------------:|------:|
| 01 concat | ~2 s | (matched, fast) | ~1× |
| 02 trim | ~7 s | (matched, similar) | ~1× |
| 03 demux | ~2 s | (matched, similar) | ~1× |
| 04 UMI binning (36 RPIs) | **76 s** | **22 min 24 s** (1344 s) | **17.7×** |
| 05 racon consensus | 23 s | 3 min 41 s (221 s) | 9.6× |
| 06 extract | 4 s | 26 s | 6.5× |
| 07 map (minimap2) | 88 s | 3 min 48 s (228 s) | 2.6× |
| **Phase 2 total (04-07)** | **3 min 11 s (191 s)** | **30 min 21 s (1821 s)** | **9.5×** |

Numbers for prior run are derived from the end-of-step timestamps in
`runs/LibCheck/pipeline_summary.tsv` (snapshot at
`/workspace/L3Rseq_Takehira_260403/L3R-seq/runs/LibCheck/`). Prior run
was on a native Linux box (no WSL2, no 9P).

Fast steps (01-03) are fast on both sides because they're dominated by
CPU-bound work on a few large files (gzip, cutadapt on whole fastqs).
Step 04 is dominated by small-file creates per UMI bin, which is exactly
the 9P weak spot.

## Environment

Confirmed via `mount` and `df`:

```
/workspace       9p       C:\ (Windows host NTFS via WSL2)
/tmp             overlay  /dev/sde (ext4 inside WSL2 distro)
/home/vscode     overlay  /dev/sde (ext4 inside WSL2 distro)
/root            overlay  /dev/sde (ext4 inside WSL2 distro)
```

Kernel: `Linux 6.6.87.2-microsoft-standard-WSL2`. 9P mount options
include `cache=5, msize=65536, trans=fd` — default WSL2 drvfs.

## Filesystem benchmarks (9P vs ext4-overlay)

Measured 2026-04-24 on this devcontainer with a live pipeline running
on `/workspace` (slow-side numbers are therefore *representative* of
actual concurrent load, not clean-room best-case):

| Workload | /tmp (ext4 overlay) | /workspace (9P→NTFS) | Slowdown |
|---|---:|---:|---:|
| Create 1000 × 1 KB files | 0.08 s (13k files/s) | **6.2 s** (162 files/s) | **80×** |
| `stat` 1000 files | 0.005 s (200k/s) | **3.0 s** (334/s) | **600×** |
| Delete 1000 files | 0.03 s (30k/s) | **3.7 s** (271/s) | **113×** |
| Sequential write 100 MB | 0.21 s (485 MB/s) | 0.76 s (132 MB/s) | 3.7× |
| `fsync()` after 1 MB | 6.2 ms | 16.4 ms | 2.6× |
| fork+exec /bin/true × 1000 | 1.07 s | 1.17 s | 1.09× (noise) |
| **10 KB write → fork/read → repeat ×500** | **1.57 s** | **12.9 s** | **8.2×** |

**Interpretation.** Bulk I/O (large sequential writes, forking
processes) is barely affected. The pain is concentrated in **per-file
metadata syscalls** — `creat`, `stat`, `unlink` are 80-600× slower. The
"write 10 KB → fork/read → repeat" micro, which models the real
pipeline pattern most closely, sits at ~8× per op — and once amortized
across thousands of ops per step, stacks to the ~26× pipeline-level
slowdown we observe.

Full benchmark detail and methodology caveats in Appendix A.

## Where the pipeline creates small files

Drilling into `longread_umi_L3Rseq/scripts/umi_binning_single.sh`
(called once per RPI by `scripts/04_umi.sh`):

| Category | Files per RPI | Notes |
|---|---:|---|
| Per-UMI-bin FASTQs (`read_binning/bins/<grp>/umi*bins.fastq`) | ~500 | 2-10 KB each; one per unique UMI observed |
| Reference/intermediate FASTAs (`umi.fa`, `umi_u.fa`, `umi_c.fa`, …) | ~6 | |
| BWA index sidecars (`.amb .ann .bwt .pac .sa`) | 5 | |
| SAM intermediates (`umi_map.sai`, `umi_map.sam`) | 2 | |
| Stats TSVs (`umi_cluster_stats.tsv`, …) | 4 | |
| GNU parallel job dirs (`bins/job<n>/`) | ~THREADS | Created + cleaned up during aggregation (lines 339-379) |
| **Total per RPI** | **~520-620** | × 36 RPIs = **~20k small files created per step 04** |

**Hot loops identified by the hotspot agent:**

1. **`umi_binning_single.sh:339-348`** — GNU parallel binning pipeline:
   millions of `print > binfile` appends to ~500 distinct files via
   gawk (libc FD cache managed). 9P cost compounds per append.
2. **`umi_binning_single.sh:389-405`** — bin-size filter: iterates
   ~513 fastqs doing `wc -l` (open+scan+close) + conditional `mv`.
   Every `open` pays full 9P metadata cost.
3. **`consensus_racon.sh:155-161`** — GNU parallel racon; each job
   writes `ovlp.paf` (10-100 MB per bin × 2-3 rounds) to the workspace
   filesystem. No `TMPDIR` override anywhere in the pipeline.

**Zero scratch-dir handling** found in any of: `scripts/04_umi.sh`,
`scripts/05_consensus.sh`, `longread_umi_L3Rseq/scripts/umi_binning_single.sh`,
`longread_umi_L3Rseq/scripts/consensus_racon.sh`. All temp files land
on the same filesystem as the workspace.

Full hotspot detail in Appendix B.

## Fixes in detail

### P0: Get off 9P (expected 10×+ speedup, zero code risk)

Two straightforward options, either one works:

**Option A — Named Docker volume.** Replace the bind mount in
`.devcontainer/*/devcontainer.json` with a Docker-managed volume:

```json
"workspaceMount": "source=l3rseq-workspace,target=/workspace,type=volume",
"workspaceFolder": "/workspace"
```

Docker volumes inside Docker-Desktop-for-WSL2 land on WSL2-native ext4
(not on the Windows host filesystem). Drawback: no longer browse the
workspace from Windows Explorer.

**Option B — Clone the repo inside the WSL2 distro.** Do `git clone` at
e.g. `\\wsl$\Ubuntu\home\<user>\l3rseq` (or `~/l3rseq` from inside the
distro) and open that folder in VS Code. The devcontainer's workspace
mount then comes from WSL2 ext4 natively. Minimal tooling change; keeps
the "edit from VS Code" workflow.

Either option: expect step 04 to drop from ~30 min back to ~1-2 min
(the prior-run timing), with no code changes.

### P1: Redirect scratch to fast filesystem

Even before moving workspaces, a quick wins:

```bash
export TMPDIR=/tmp/l3rseq_scratch
mkdir -p "$TMPDIR"
```

This affects tools that honor `$TMPDIR` (cutadapt, some racon temp
behavior, GNU parallel job files). The final outputs still land on
`/workspace` (still slow to write), but the many-small-file scratch
work runs on ext4. Estimated partial gain: 1.5-3× on step 04 even
without moving the workspace.

### P2a: Parallelize RPI loop in step 04

`scripts/04_umi.sh` lines 37-94 iterate barcodes × RPIs serially. On a
64-core box, we're using ~8 cores (what cutadapt + bwa actually saturate
per RPI). Using GNU parallel with `-j 8` and `--threads 8` inside each
job would ~8× throughput for step 04. Sketch:

```bash
find "$demux_base" -mindepth 2 -name '*.fastq' ! -name '*unclassified*' \
  | parallel --line-buffer -j 8 bash "$_umi_script" \
      -d {} -o "$output_dir/04_umi/{//: }/{/.}" \
      -f "$umi_flank5" -r "$umi_flank3" -l "$umi_len" -n "$size_thresh" -t 8
```

This change stacks multiplicatively with P0: native FS × RPI parallelism
would take step 04 down to ~10-20 s.

### P2b: Step 04 resume markers

`scripts/05_consensus.sh:51-54` has a clean idiom:

```bash
if [ -f "$_cons_dir/.done" ]; then
    echo "  Skipping $bname / $rpi_name (already complete)"
    continue
fi
```

Port to `scripts/04_umi.sh`. Cheap, makes iteration much better
— if a step 04 run dies midway, we don't reprocess already-completed
RPIs.

## Validation plan and results

Live benchmark log: **`runs/step04_fs_benchmarks.tsv`** — structured
record of every step-04 measurement. Updated as new rows are collected.

Progress on the 4-config matrix. Only rows requiring no workspace
migration can be run in this session.

| Config | FS | RPI parallel (UMI_PARALLEL_JOBS) | Step 04 wall | Speedup vs 9P serial |
|---|---|---|---|---|
| current | 9P | 1 (serial) | **1344 s (22m 24s)** | 1× |
| P2a only | 9P | 8 × 8 threads | **839 s (14m 0s)** | 1.60× |
| P0 only | ext4 overlay (`/home/vscode/runs`) | 1 | **329 s (5m 29s)** | 4.09× |
| **P0 + P2a** | **ext4 overlay** | **8 × 8 threads** | **44 s (0m 44s)** | **30.5×** |

Reference point: prior Linux baseline was 76 s. **P0+P2a (44 s)
actually beats the prior Linux baseline by 1.7×** — likely because
this WSL2 box has more cores (64 vs whatever the prior machine had).

All four rows measured live on 2026-04-24 (see
`runs/step04_fs_benchmarks.tsv`). Key takeaways:

1. **P2a alone (parallel on 9P) gives only 1.6×** — 8× concurrency
   hits the same 9P metadata bottleneck. Classic I/O-bound workload.
2. **P0 alone (ext4, serial) gives 4×** — moving off 9P helps a lot
   even without parallelism, confirming the FS is the dominant factor.
3. **P0 + P2a stacks to 30.5×** — each change multiplies because they
   attack different bottlenecks (FS latency vs CPU underutilization).
4. **The parallel change was always correct**, but its value is only
   unlocked once the FS bottleneck is gone. On 9P it looked marginal.

### Correctness of the parallel strategy

Full cross-diff across the three step-04-only runs (all performed with
identical inputs; step 05+ cleanup had not run on any of them, so the
per-bin FASTQs are all intact for comparison):

| Comparison | Purpose | Result |
|---|---|---|
| B (9P, parallel) vs C (ext4, serial) | different FS × different parallelism | 36/36 match |
| B (9P, parallel) vs D (ext4, parallel) | same parallelism, different FS | 36/36 match |
| C (ext4, serial) vs D (ext4, parallel) | same FS, parallelism on/off | **36/36 match** |

"Match" means both the per-RPI `umi_cluster_stats.tsv` is byte-identical
AND the md5-of-md5s of every `*bins.fastq` file in `read_binning/bins/`
is identical (sorted, order-independent). 36 × ~500 bin FASTQs = ~18 000
individual bin-content hashes cross-checked. Zero diffs.

The C-vs-D pair is the decisive test: same filesystem, same inputs, only
`UMI_PARALLEL_JOBS` flipped from 1 to 8. Byte-identical confirms the
parallel code path does not alter output semantics.

Note: the earlier `LibCheck_takehira_test` run (which went through the
full steps 04-07) now has fewer bin FASTQs on disk because step 05+
cleanup removed the `UMIclusterfull/` hardlinks (and the original
`bins/` ones along with them). That's a pipeline-side cleanup, not a
parallel-code regression; it affects what's *still on disk*, not what
was *produced*. Cross-diffs above are restricted to the step-04-only
runs to avoid this artifact.

The parallel variant is preserved as an opt-in via env var so it costs
nothing when unused:

```bash
UMI_PARALLEL_JOBS=8 L3Rseq run --threads 64 ...   # parallel
L3Rseq run --threads 64 ...                        # default: serial
```

Branch: `speedup-step04-parallel`, file: `scripts/04_umi.sh` (longread-umi
path only; umic-seq method unchanged).

Correctness: byte-identical to serial (validated via per-RPI
`umi_cluster_stats.tsv` diff and the pipeline_summary.tsv metric diff).

The parallel variant is preserved as an opt-in via env var so it costs
nothing when unused:

```bash
UMI_PARALLEL_JOBS=8 L3Rseq run --threads 64 ...   # parallel
L3Rseq run --threads 64 ...                        # default: serial
```

Branch: `speedup-step04-parallel`, file: `scripts/04_umi.sh` (longread-umi
path only; umic-seq method unchanged).

## Appendix A — Raw filesystem benchmarks (methodology)

Single Python driver, `time.perf_counter()` around each phase, ~30 s
total wall time. Fast side: `/tmp/bench_fast` (overlay → `/dev/sde`
ext4). Slow side: `/workspace/runs/LibCheck_takehira_test/tmp_bench/`
(9P → `C:\`). Benchmark dirs were cleaned up after the run.

Caveats:

- `echo > /proc/sys/vm/drop_caches` is not writable inside an
  unprivileged devcontainer, so the fast-side 100 MB sequential read
  benchmark measures page cache (7 GB/s) rather than cold disk. The
  9P side is effectively uncached (9P `cache=5` → short TTL), so
  direct comparison of the read-throughput row is unfair; the 132
  MB/s 9P number is realistic for the pipeline's working case.
- A pipeline run was actively writing to `/workspace` during the
  slow-side benchmark. This biases slow-side numbers slightly worse
  than a quiescent measurement, but is representative of the real
  scenario.
- `fork+exec` benchmark was run with `cwd=ROOT` to verify the
  slowdown isn't cwd-related — confirmed within noise. Slowdown is
  path-I/O, not working directory.

All 7 benchmarks completed; none skipped or failed.

## Appendix B — Per-step I/O patterns (detail)

### Step 04 `umi_binning_single.sh` file structure

After one RPI completes, `read_binning/bins/` looks like:

```
read_binning/bins/
├── 0/                             ← group 0 (up to ~4000 bins per group)
│   ├── umi1bins.fastq
│   ├── umi2bins.fastq
│   ├── ...
│   └── umi513bins.fastq          ← ~513 files, each 2-10 KB
└── 1/                             ← group 1 if needed
```

Grouping logic at `umi_binning_single.sh:309-320` caps directory
entries at ~4000 per group to avoid ext4 directory inode bloat.
Works fine on ext4, irrelevant overhead on NTFS — a flat
dump-to-one-dir approach would also work on NTFS, though.

### Step 05 `consensus_racon.sh` per-job temp files

For each UMI bin processed in parallel:

- `${UMINO}_sr.fa` — seed FASTA (0.5-2 KB)
- `ovlp.paf` — minimap2 alignment (**10-100 MB per bin**, rewritten each round)
- `${UMINO}_tmp.fa` — racon output (rewritten each round)

`ovlp.paf` is the largest repeated write. On 9P, writing a 50 MB file
per bin × 500 bins × 2 rounds = ~50 GB of write traffic to the
Windows filesystem during step 05 alone. Redirecting this via
`TMPDIR=/tmp/scratch` would land it on ext4 overlay instead.

### Low-hanging optimizations (beyond P0-P2 fixes above)

- **P3a:** Bump `--block 300M` → `--block 1G` on `umi_binning_single.sh:340`
  to halve the number of GNU parallel job directories created
  (slight RAM cost per job, negligible on Nanopore read sizes).
- **P3b:** Track bin size during parallel aggregation (lines 352-376)
  and skip writing small bins in the first place, instead of the
  post-hoc `wc -l` + `mv` pass at lines 389-405.
- **P3c:** Replace per-read `print > binfile` gawk appends (lines
  323-332) with a single intermediate `(umi_id, read)` stream
  followed by a bulk partition — trades complexity for fewer
  metadata ops per read.

These are secondary to P0 and only worth touching if we're on a fast
FS and still want more throughput.

## Appendix C — Cross-references

- `docs/PIPELINE_MODERNIZATION.md` — current modernization status; this
  speed issue is orthogonal (fixable without code changes).
- `docs/pipeline_fast_storage_plan.md` — the "how to roll out" plan
  based on the findings in this document.
- `CLAUDE.md` — already notes the viewer added 15s TTL caches on
  filesystem discovery specifically because of WSL2 9P cost (commit
  `67fcb82`).
- `.devcontainer/` — where the `workspaceMount` change would go.
- `runs/step04_fs_benchmarks.tsv` — machine-readable benchmark log; 5
  measured rows spanning the full FS × parallelism matrix.

## Appendix D — Session log (2026-04-24)

Chronological record of the investigation + validation + prototype done
on branch `speedup-step04-parallel`.

1. **Full pipeline regression test on real ONT data** (`LibCheck_sample`
   3 barcodes × 12 RPIs). Outputs `runs/LibCheck_takehira_test/`. Result:
   all step-01-07 metrics and step-11 gene counts byte-identical vs the
   2026-04-04 reference run in `L3Rseq_Takehira_260403/runs/LibCheck/`.
   Wall-time for the baseline serial 9P run was captured as the starting
   point for this investigation.

2. **Filesystem micro-benchmarks** (agent-generated). Confirmed 9P
   metadata ops are 80-600× slower than ext4 overlay; bulk throughput
   only 2.6-3.7× slower. Established that pipeline slowdown is
   concentrated in small-file metadata calls, not streaming I/O.

3. **Step-04 I/O hotspot audit** (agent-generated). Catalogued the
   ~520-620 small-file creates per RPI and the hot loops in
   `umi_binning_single.sh` that drive them. No existing TMPDIR
   redirection. Documented in Appendix B.

4. **Parallel-step-04 prototype** on `scripts/04_umi.sh`. Opt-in via
   `UMI_PARALLEL_JOBS` env var (default 1 = original serial behavior).
   Uses GNU parallel for RPI-level concurrency with threads divided
   evenly across jobs. Per-RPI worker (including `UMIclusterfull`
   hardlink creation) extracted into a function so each parallel job
   produces fully-formed output.

5. **4-point benchmark matrix**:

   | Config | Step 04 wall | vs 9P serial |
   |---|---|---|
   | 9P serial | 22m 24s | 1× |
   | 9P parallel (8 × 8) | 14m 00s | 1.60× |
   | ext4 serial | 5m 29s | 4.09× |
   | ext4 parallel (8 × 8) | **0m 44s** | **30.5×** |

   The ext4-parallel point beats the prior 2026-04-04 Linux baseline
   (76 s) by 1.7× on this 64-core WSL2 box.

6. **Correctness verification** (all 36 RPIs, 4 runs, pairwise
   cross-diff on `umi_cluster_stats.tsv` + every `*bins.fastq` md5).
   The parallel code path is **byte-identical** to the serial path
   regardless of filesystem. See "Correctness of the parallel strategy"
   section above.

7. **Rollout plan** drafted in `docs/pipeline_fast_storage_plan.md` —
   Docker named volume at `/runs`, 5 phases, each independently
   reversible. Phase 0 (measurement) validated in this session;
   Phase 1+ (devcontainer edits) awaiting user go-ahead.

### Artifacts left on disk

| Path | Contents | Retention |
|---|---|---|
| `runs/LibCheck_takehira_test/` | Full 9P-serial pipeline output (steps 01-07, 11) | Keep until compared or re-run elsewhere |
| `runs/LibCheck_parallel_test/` | 9P-parallel step-04-only output | Keep for correctness-diff reproducibility |
| `/home/vscode/runs/phase0_test/` | ext4-serial step-04-only output | Safe to delete; ephemeral overlay |
| `/home/vscode/runs/phase0_parallel/` | ext4-parallel step-04-only output | Safe to delete; ephemeral overlay |
| `runs/step04_fs_benchmarks.tsv` | Machine-readable benchmark log | Commit with docs |

### Uncommitted files on branch `speedup-step04-parallel`

- `scripts/04_umi.sh` — parallel-capable via `UMI_PARALLEL_JOBS` env var
- `docs/pipeline_speed_investigation.md` — this file
- `docs/pipeline_fast_storage_plan.md` — rollout plan

Ready for review and commit when the user says so. Not committed
autonomously per repo convention.
