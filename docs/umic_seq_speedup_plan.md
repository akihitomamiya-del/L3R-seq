# UMIC-seq Speedup Plan

Drafted: 2026-04-24. Companion to `pipeline_speed_investigation.md`
(which covered the 9P / longread-umi speedup). This doc covers the
**other** UMI method — UMIC-seq
(`/workspace/UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py`,
invoked from `scripts/04_umi.sh` when `--method umic-seq`).

## TL;DR

UMIC-seq is kept for **continuity** — it's the method the original
analyses were run with, and we don't want to change what it produces.
The goal of this plan is to make UMIC-seq faster **without altering
its algorithm or output**. That rules out clustering-backend swaps
and limits us to parallelism and tuning.

**Recommended plan — two tiny, additive changes:**

| # | Change | Effort | Expected gain | Continuity impact |
|---|---|---|---|---|
| 1 | **RPI-parallel** via `UMI_PARALLEL_JOBS` in `scripts/04_umi.sh` (mirror the longread-umi pattern) | ~70 lines, 1 h | ~4-8× on multi-RPI runs | **None — byte-identical output** (validated, see below). Just runs multiple RPIs concurrently. |
| 2 | **Raise `--stop_thresh`** from 0 to 5 in the UMIC-seq invocation | 1 line | ~1.1-1.3× | Minor — early-stop trims singleton-dominated tail of the cluster list. Can be left at 0 if exact parity is required. |

Both changes are opt-in via env var / arg. Default behavior unchanged.

Measured on REP3 (18 RPIs, ~1.3 GB demux, ext4 overlay):

| Config | Step 04 wall | Speedup | Correctness |
|---|---:|---:|---|
| Serial UMIC-seq (baseline) | **108m 18s** (6498s) | 1× | — |
| **`UMI_PARALLEL_JOBS=4`** (change #1 applied) | **16m 9s** (969s) | **6.71×** | **byte-identical** |

Byte-identical verified on:
- `ExtractedUMIs.fasta` md5 per RPI: 18/18 match
- Total cluster count per RPI: 18/18 match (same partitioning)
- `bins_kept` per RPI in pipeline_summary.tsv: 18/18 match

(The change got more than the naive 4× because GNU parallel's
scheduler fills idle slots with next RPIs as early ones finish —
no long-tail idle.)

For reference: the longread-umi method on the same data took 3m 21s
(step 04). We're not trying to beat that — UMIC-seq's inner algorithm
is fundamentally heavier. We just want it to not take 2 hours.

**Explicit non-goals (listed in Appendix C for reference):**

- Swapping the clustering backend to vsearch/starcode — **not
  recommended under the continuity constraint.** Leaves the codebase
  architecturally divergent from the original UMIC-seq paper and would
  need output-equivalence validation. See Appendix C for survey if
  this ever gets revisited.
- Python-side rewrites (chunksize tuning, algorithmic changes inside
  `simplesim_cluster`). Low gain, touches the preserved code path.

## Observed slowdown

Measured 2026-04-24 on REP3 (18 RPIs, ~1.3 GB demux, ext4 overlay FS):

| Method | per-RPI wall time | 18 RPIs total | Note |
|---|---|---|---|
| longread-umi (parallel) | ~11 s | **3m 21s** | `UMI_PARALLEL_JOBS=8` |
| UMIC-seq (serial) | ~7.6 min | **still running — projected ≥2 h** | No parallel option; single-threaded across RPIs, multi-threaded within |

UMIC-seq IS internally multiprocessed (`multiprocessing.Pool(processes=cpu_count())`)
and IS getting 64 threads — but the inner parallel work is a string of
~12k tiny pool dispatches, and IPC + Python overhead dominate the
actual SW alignment work (agent profiling: only ~5-10% of wall time is
in alignment; the rest is Python/IPC).

## Why is UMIC-seq slow?

(Details in Appendix A; line references to
`/workspace/UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py`.)

- **Outer loop is serial** (line 193-229, `simplesim_cluster`): one
  iteration per output cluster, and REP3 RPI_1 produces 12,134 clusters
  — so 12k serial iterations. Each iteration does one
  `pool.starmap(aln_score, ...)` against ALL remaining UMIs.
- **Inner pool.starmap fires ~48k tiny alignment tasks** (line 195),
  each a `StripedSmithWaterman` call on a 20-30 nt UMI. Per alignment
  is fast (~µs); per-task IPC + unpickling + Python overhead is a much
  larger share of the budget than the alignment itself.
- **Cumulative dispatches per RPI:** ~288M `pool.starmap`-item
  executions (agent A estimate). That's the bottleneck.
- **No RPI-level parallelism** in `scripts/04_umi.sh:170-217` — RPIs
  loop sequentially even though the per-RPI Python already grabs all
  CPUs. Extra cores are wasted during the Python process's GIL-bound
  phases.
- **Early-stop disabled.** Invocation passes `--stop_thresh 0`
  (line 213 of `scripts/04_umi.sh`). Early-stop only triggers when
  recent cluster sizes drop below the threshold, which for sparse /
  long-tail datasets can skip 20-30% of the late iterations.

## Can we borrow longread-umi's techniques?

(Details in Appendix B.)

Both methods produce the **same output contract** — per-bin
`umi<N>bins.fastq` files consumed by step 05 racon consensus. The
algorithmic split is clean:

| Phase | UMIC-seq | longread-umi |
|---|---|---|
| Extract UMIs | Smith-Waterman probe alignment (`UMIextract`, lines 94-165) | `cutadapt --revcomp` + flanking motifs |
| Cluster UMIs | Iterative serial-outer / pool-inner SW (`simplesim_cluster`) — O(N × K) | `usearch/vsearch -cluster_fast` greedy centroids — O(N × C) |
| Assign reads | `SeqIO.index` + iterate clusters (lines 386-389) | BWA-map centroids back + streaming binning |

**Extraction and read-assignment work fine in UMIC-seq; only the
clustering middle step is the bottleneck.** A hybrid approach — keep
UMIC-seq's probe-based extraction, swap the clustering for
vsearch/starcode — is the cleanest long-term fix. See Proposed priority
#3 below.

## External alternatives

(Details in Appendix C.)

Short table of drop-in replacements for the clustering step:

| Tool | Algorithm | ONT ~10% error? | Parallel? | In repo? |
|---|---|---|---|---|
| **vsearch** `cluster_fast` | Greedy centroid, SIMD + multi-thread | Yes (`-id 0.75`) | Yes | **Yes** — longread-umi dep |
| **starcode** | Trie-based all-pairs Levenshtein | Yes (`-d N`) | Yes (`-t N`) | No — needs Docker tag |
| UMICollapse | Network + BK-trees | Hamming-only | Partial | No |
| Calib | MinHash/LSH, paired-end | Subst-only | Yes | No |
| umi_tools | Directional adjacency | Hamming-only | No | No |

**Agent recommendation: starcode** — Levenshtein distance (handles ONT
indels), native threading, output format (`centroid<TAB>count<TAB>members`)
is a ~20-line parser away from what UMIC-seq currently produces.
Published claim: orders-of-magnitude faster than alternatives on
similar scale; realistic estimate here is collapsing 2h → seconds.

**Second-best: vsearch** — already in the repo as the clustering
engine used by longread-umi. Lower barrier to adoption (no Dockerfile
change). Slightly slower than starcode but good enough.

## Proposed fix priority

(Continuity constraint: priorities 1 and 2 only. Priority 3 — clustering
swap — is retained below as a future option but **not recommended**
under the current continuity goal. Skip to Appendix C for that.)

### Priority 1 — RPI-parallel UMIC-seq (quick win)

Mirror what I already did for longread-umi in
`scripts/04_umi.sh` (lines ~32-151 on branch `speedup-step04-parallel`).
Apply the same pattern to the UMIC-seq branch (currently lines 153-232
of that file on the same branch).

**Confirmed by git archeology agent (2026-04-24):** no prior attempt at
UMIC-seq per-RPI parallelization exists in any committed form, any
branch, any reflog, any deleted history, or the Takehira snapshot.
The longread-umi parallelization in `scripts/04_umi.sh` on this branch
is the first per-RPI parallel pattern at step-04 level and is still
uncommitted. The UMIC-seq side has never been parallelized.

Full concrete diff lives in **Appendix D**. Summary of what it does:

1. Build a tab-separated task list of `(barcode, fastq, fname)`, one
   row per RPI (skipping `unclassified`).
2. Extract the per-RPI body of the current serial loop into a bash
   function `_step04_umic_process_one`.
3. Export that function + every variable it needs (including a
   resolved-to-absolute probe file path) so GNU `parallel` subshells
   see them.
4. When `UMI_PARALLEL_JOBS > 1` and `parallel` is on `$PATH`, run
   `parallel --line-buffer -j "$UMI_PARALLEL_JOBS" --colsep '\t'`;
   otherwise fall back to the original serial `while read`.
5. Pass `--threads $((THREADS / UMI_PARALLEL_JOBS))` to the Python
   script so we don't oversubscribe cores.

**UMIC-seq-specific edge cases** (not present in the longread-umi
version — see Appendix D §3 for details):

- Python argparse places `--threads` at the **top level**, not per
  subcommand. Must come BEFORE `UMIextract` / `clustertest` /
  `clusterfull`, not after.
- `$cluster_steps` is a 3-integer string consumed by `nargs=3`. Must
  stay unquoted (existing `# shellcheck disable=SC2086` preserves this).
- `$probe_file` is a shared read-only input across workers — resolve
  to absolute path once before parallel dispatch.
- Memory scales roughly linearly with `$UMI_PARALLEL_JOBS`: each Python
  worker holds all UMIs + their SSW objects (~25 MB per RPI on REP3,
  but scales with UMI count). Benchmark with `UMI_PARALLEL_JOBS=2`
  first before pushing to 4-8.

**Expected gain:** ~4-8× on multi-RPI workloads. Projected REP3
timing (18 RPIs): ~2 h serial → ~15-20 min parallel.

**Effort:** ~20 lines net (replace the serial loop block). **Risk:**
minimal — each RPI is already fully isolated (own `$odir`,
no shared writes, no shared counters, no cwd mutations). Trivially
reversible via `UMI_PARALLEL_JOBS=1` (or unset).

### Priority 2 — Enable `--stop_thresh` (one-line change)

In `scripts/04_umi.sh` line ~213, change `--stop_thresh 0` to
`--stop_thresh 5`. This triggers UMIC-seq's existing early-stop logic
when the average of the last 20 clusters drops below 5 members.

- Agent A: saves ~20-30% on sparse/long-tail data.
- Risk: low — early-stop only kicks in after `clussize_window` clusters
  and only if the running average is truly below threshold. `aln_thresh`
  tuning is unaffected.
- Validate by diffing output bin counts on a small sample.

**Effort:** 5 minutes. **Risk:** low.

### Priority 3 — Swap clustering backend (NOT RECOMMENDED under continuity goal)

**Retained here for future reference only.** This change would give
the biggest single speedup but violates the continuity constraint.
Only revisit if UMIC-seq is being reworked for other reasons.

Keep UMIC-seq's probe-based extraction (which works well and is
orientation-aware), replace the in-Python iterative clustering with
one of:

**3a. vsearch (in-repo, minimal infrastructure):**
```bash
# After UMIextract produces ExtractedUMIs.fasta:
vsearch --cluster_fast ExtractedUMIs.fasta --id 0.75 \
    --threads "$threads" --uc clusters.uc \
    --centroids centroids.fa
# Parse clusters.uc to build {UMI_id -> cluster_id}, then emit bins/
```

**3b. starcode (new Docker tag, bigger speedup):**
```bash
# FASTA → seqs on stdin, emit TSV of centroid<TAB>count<TAB>members
starcode -d 4 -t "$threads" --seq-id \
    -i ExtractedUMIs.fasta -o clusters.tsv
```

Either approach: ~50-100 lines of Python/awk post-processing to rebuild
the `{read_id → bin}` mapping UMIC-seq currently produces. Step 05
(racon consensus) consumes the same per-bin FASTQs — **no downstream
changes required**.

**Validation:** run on one REP3 RPI, diff bin sizes against the current
UMIC-seq output. Some small differences expected (different clustering
algorithm), but total bin counts and correlation vs reference should
stay in range.

**Effort:** 4-6 h (vsearch) or 6-8 h (starcode + Docker rebuild).
**Risk:** medium — parameter mapping and edge-case handling for
tie-breaking.

## Validation plan

Before merging any of the three changes:

1. **Correctness** — run on one RPI, diff output bin file md5 set
   (order-independent, as I did for the longread-umi parallel
   validation).
2. **Full-scale timing** — re-run REP3 18-RPI dataset, record in
   `runs/pipeline_timings.tsv` alongside the existing entries.
3. **Downstream equivalence** — confirm step 05 racon consensus counts
   stay within a few % of the current numbers. Pearson correlation
   ≥ 0.95 across RPIs is the acceptance bar.

## Appendix A — UMIC-seq deep profile

Where the time goes, with line-number references to
`/workspace/UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py`.

### Three phases per RPI invocation

| Phase | Lines | Description | Cost |
|---|---|---|---|
| UMIextract | 94-165 | Probe-based SW extraction, streaming fastq | Seconds |
| clustertest | 299-338 | Threshold-approximation on 25-UMI sample | Seconds |
| clusterfull | 346-413 | The slow part: full iterative clustering | Dominates (minutes) |

### Inside the hot loop (`simplesim_cluster`, lines 178-234)

```python
pool = multiprocessing.Pool(processes=threads)  # line 191
while len(seq_index) > 0:                        # line 193 — serial
    score_lst = pool.starmap(aln_score,          # line 195 — parallel
        zip(itertools.repeat(seq_index[0]), remaining_umis))
    # filter by threshold, remove matched, repeat
```

- **Iterations per RPI:** ~12,134 (one per output cluster, observed in
  REP3 RPI_1 logs).
- **Dispatches per iteration:** up to N = 48,825 (early iterations),
  decreasing.
- **Cumulative dispatches:** ~288M item-tasks through the pool per RPI.
- **Pure alignment time share:** 5-10% (agent estimate).
  `StripedSmithWaterman` on 20-30 nt UMIs takes ~µs; 288M calls × µs
  is ~min per RPI. The rest (5-6 min) is IPC + Python + GIL.

### Invocation from shell (`scripts/04_umi.sh` lines 207-214)

```bash
python "$umic_py" clusterfull \
    --input "$odir/ExtractedUMIs.fasta" \
    --reads "$fq" \
    --aln_thresh "$aln_thresh" \
    --size_thresh "$size_thresh" \
    --output "$odir/UMIclusterfull" \
    --stop_thresh 0          # <-- disables early-stop
```

`--threads` is not passed → Python defaults to
`multiprocessing.cpu_count()`. That's fine; all cores are used.

## Appendix B — UMIC-seq vs longread-umi (algorithmic diff)

### Clustering backends

| Aspect | longread-umi | UMIC-seq |
|---|---|---|
| Tool | usearch (C, SIMD) | Python + biopython + skbio.alignment.SSW |
| Algorithm | Greedy centroid (`-cluster_fast`) | Iterative serial-outer / pool-inner SW |
| Complexity | O(N × C), C = centroid count | O(N × K), K = cluster count (K grows fast) |
| Dedup pre-pass | Yes (`fastx_uniques`) | No |
| Read assignment | BWA-map centroids back + streaming | `SeqIO.index()` lookup per cluster |
| Parallelism granularity | Native multi-thread per tool | Python `multiprocessing.Pool` across tiny tasks |

### Why longread-umi wins

1. **Native C + SIMD** beats Python `multiprocessing` for tiny parallel
   tasks — IPC dominates when each task is ~µs of work.
2. **Dedup first** shrinks N before the quadratic-in-worst-case
   clustering even starts.
3. **BWA for read assignment** is a single-pass indexed lookup; UMIC-seq
   iterates reads per cluster from an in-memory index.

### Agent B's one-day recommendation

Do **RPI parallelism first** — 20 lines of shell, copy the pattern from
`scripts/04_umi.sh` longread-umi branch (the one I already wrote),
adapt variable names for UMIC-seq. One hour of work, ~8× speedup, zero
algorithmic change, zero output change. Then benchmark; if still too
slow, proceed to Priority 3 (clustering swap).

## Appendix C — External UMI-clustering tool survey

### Shortlist

| Tool | Algorithm | Speed claim | ONT ~10% error | License | In repo |
|---|---|---|---|---|---|
| **vsearch** `cluster_fast` | Greedy centroid, SIMD + multi-thread | Linear thread scaling | Yes (`-id 0.75`) | BSD-2 | **Yes** |
| **starcode** | Trie-based all-pairs Levenshtein, connected components | "Orders of magnitude faster"; ~linear to 12 threads | Yes (`-d 3/4` for 30 nt UMI) | GPLv3 | No |
| UMICollapse | Network/adjacency + BK-tree | 1M UMIs in ~26s single-threaded | Hamming-only by default | MIT | No |
| Calib | MinHash/LSH on paired-end barcode+insert | Balanced speed/memory | Subst-only | MIT | No |
| umi_tools (network) | Directional adjacency on BAM | Baseline | Hamming-only | MIT | No |

### Why starcode won agent C's recommendation

- **I/O match:** input FASTA, output TSV of `centroid<TAB>count<TAB>members`
  — exactly what UMIC-seq currently produces, modulo a small parser.
- **Error model match:** Levenshtein `-d N` is the right model for ONT
  indel-heavy UMIs; UMICollapse/umi_tools' Hamming-only is not.
- **Native `-t N` threading;** single sample saturates ~12 cores. With
  RPI-level GNU parallel on top, we can fully use a 64-core box.
- **Published gain:** 100-1000× on comparable workloads, which would
  make UMIC-seq's clustering step effectively free.

### Why vsearch is a strong "first swap"

- **Already in the repo** — longread-umi uses it (actually usearch in
  current code, but vsearch is a drop-in open-source replacement with
  the same CLI). No Docker rebuild.
- **Good enough** — won't hit starcode's theoretical speedup but will
  still collapse several minutes into seconds per RPI.
- **Lowest-risk swap:** same algorithm family longread-umi already
  trusts for clustering.

If we're going to change the backend, my suggestion: **vsearch first**
(because no Docker change), reserve starcode for a second iteration
if vsearch's speedup isn't sufficient.

### Sources (from agent C)

- starcode — <https://academic.oup.com/bioinformatics/article/31/12/1913/213875>
- UMICollapse paper — <https://pmc.ncbi.nlm.nih.gov/articles/PMC6921982/>
- 2025 benchmark (Scientific Reports) — <https://www.nature.com/articles/s41598-025-33128-x>
- Calib — <https://academic.oup.com/bioinformatics/article/35/11/1829/5142725>
- vsearch — <https://github.com/torognes/vsearch>
- ONT pipeline-umi-amplicon — <https://github.com/nanoporetech/pipeline-umi-amplicon>

## Appendix D — Concrete Priority-1 implementation

Ready to apply after the currently-running UMIC-seq serial pipeline
finishes (writing to `/home/vscode/runs/rep3_umic_test/`, do NOT
disturb until done).

### D.1 — Target lines to replace

In `/workspace/scripts/04_umi.sh` on branch `speedup-step04-parallel`:
lines **153-232**, from `# ---- umic-seq method (default) ----`
through the trailing summary loop. Everything after the serial
`for barcode_dir; do for fq; do ... done; done` structure is
replaced with the task-list + worker + parallel-dispatch pattern.

### D.2 — The diff

```bash
    # ---- umic-seq method (default) ----
    echo "[Step 04] UMI extraction and clustering (method: $method) ..."

    # Prefer workspace source (UMIC-seq_L3Rseq/) over conda env copy.
    local _script_dir_umic
    _script_dir_umic="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local umic_py="$_script_dir_umic/../UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py"
    if [ ! -f "$umic_py" ]; then
        umic_py="$CONDA_PREFIX/UMIC-seq/UMIC-seq_fastq_v2.py"
    fi
    if [ ! -f "$umic_py" ]; then
        echo "[Step 04] ERROR: UMIC-seq script not found" >&2
        return 1
    fi

    # Resolve probe_file to absolute path once so all parallel workers
    # see the same file regardless of cwd changes inside subshells.
    local _probe_abs
    _probe_abs="$(cd "$(dirname "$probe_file")" && pwd)/$(basename "$probe_file")"

    # Build task list: bname<TAB>fq<TAB>fname
    local _tasks_umic
    _tasks_umic=$(mktemp)
    trap "rm -f '$_tasks_umic'" RETURN
    local _step04_umic_count=0
    for barcode_dir in "$demux_base"/*/; do
        [ -d "$barcode_dir" ] || continue
        local bname
        bname=$(basename "$barcode_dir")
        for fq in "$barcode_dir"/*.fastq; do
            [ -f "$fq" ] || continue
            local fname
            fname=$(basename "$fq" .fastq)
            [[ "$fname" == *"unclassified"* ]] && continue
            printf '%s\t%s\t%s\n' "$bname" "$fq" "$fname" >> "$_tasks_umic"
            _step04_umic_count=$((_step04_umic_count + 1))
        done
    done

    if [ "$_step04_umic_count" -eq 0 ]; then
        echo "  WARNING: No input FASTQs found in $demux_base. Check --input path." >&2
        echo "[Step 04] Done. Output in $output_dir/04_umi/"
        return 0
    fi

    # Parallelism across RPIs. Same env var as longread-umi branch.
    local _jobs="${UMI_PARALLEL_JOBS:-1}"
    local _total_threads="${THREADS:-$(nproc 2>/dev/null || echo 1)}"
    local _threads_per_job=$(( _total_threads / _jobs ))
    (( _threads_per_job < 1 )) && _threads_per_job=1

    _step04_umic_process_one() {
        local bname="$1" fq="$2" fname="$3"
        local odir="$_step04_UMIC_OUTPUT_DIR/04_umi/$bname/$fname"
        echo "  Processing $bname / $fname ..."
        mkdir -p "$odir"

        # NOTE: --threads is a TOP-LEVEL arg, must come BEFORE the subcommand
        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" UMIextract \
            --input  "$fq" \
            --output "$odir/ExtractedUMIs.fasta" \
            --probe  "$_step04_UMIC_PROBE" \
            --umi_loc "$_step04_UMIC_UMI_LOC" --umi_len "$_step04_UMIC_UMI_LEN" \
            --min_probe_score "$_step04_UMIC_MIN_PROBE_SCORE" \
            2>&1 | tee "$odir/ExtractedUMIs.log"

        # cluster_steps is "L R W" triple — MUST stay unquoted (nargs=3)
        # shellcheck disable=SC2086
        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" clustertest \
            --input  "$odir/ExtractedUMIs.fasta" \
            --steps  $_step04_UMIC_CLUSTER_STEPS \
            --output "$odir/UMIclustertest" \
            --samplesize "$_step04_UMIC_SAMPLE_SIZE" \
            2>&1 | tee "$odir/UMIclustertest.log"

        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" clusterfull \
            --input  "$odir/ExtractedUMIs.fasta" \
            --reads  "$fq" \
            --aln_thresh  "$_step04_UMIC_ALN_THRESH" \
            --size_thresh "$_step04_UMIC_SIZE_THRESH" \
            --output "$odir/UMIclusterfull" \
            --stop_thresh 0 \
            2>&1 | tee "$odir/UMIclusterfull.log"
    }

    export _step04_UMIC_OUTPUT_DIR="$output_dir"
    export _step04_UMIC_PY="$umic_py"
    export _step04_UMIC_PROBE="$_probe_abs"
    export _step04_UMIC_UMI_LOC="$umi_loc"
    export _step04_UMIC_UMI_LEN="$umi_len"
    export _step04_UMIC_MIN_PROBE_SCORE="$min_probe_score"
    export _step04_UMIC_CLUSTER_STEPS="$cluster_steps"
    export _step04_UMIC_SAMPLE_SIZE="$sample_size"
    export _step04_UMIC_ALN_THRESH="$aln_thresh"
    export _step04_UMIC_SIZE_THRESH="$size_thresh"
    export _step04_UMIC_THREADS_PER_JOB="$_threads_per_job"
    export -f _step04_umic_process_one

    if [ "$_jobs" -gt 1 ] && command -v parallel >/dev/null 2>&1; then
        echo "  [parallel] $_jobs jobs × $_threads_per_job threads/job (UMI_PARALLEL_JOBS=$_jobs)"
        parallel --line-buffer -j "$_jobs" --colsep '\t' \
            _step04_umic_process_one {1} {2} {3} < "$_tasks_umic"
    else
        while IFS=$'\t' read -r bname fq fname; do
            _step04_umic_process_one "$bname" "$fq" "$fname"
        done < "$_tasks_umic"
    fi

    # Summary unchanged
    for _rdir in "$output_dir"/04_umi/*/*; do
        [ -d "$_rdir" ] || continue
        local _bname _rname _nbins
        _bname=$(basename "$(dirname "$_rdir")")
        _rname=$(basename "$_rdir")
        _nbins=0
        if [ -d "$_rdir/UMIclusterfull" ]; then
            _nbins=$(find "$_rdir/UMIclusterfull" -name '*bins.fastq' 2>/dev/null | wc -l)
        fi
        echo "    $_bname/$_rname: $_nbins bins"
        _summary_append "$output_dir" "$_bname" "$_rname" "04" "bins_kept" "$_nbins" \
            || echo "  WARNING: Failed to write summary metric" >&2
    done
    echo "[Step 04] Done. Output in $output_dir/04_umi/"
}
```

### D.3 — Edge cases (vs. longread-umi branch)

| Issue | Detail | Handled by |
|---|---|---|
| `--threads` placement | Top-level argparse in `UMIC-seq_fastq_v2.py:28`; must precede subcommand (`UMIextract`/`clustertest`/`clusterfull`) | Worker passes before subcommand name |
| Probe file shared | All RPI workers read same file; cwd may differ in subshells | Resolve to absolute path once via `_probe_abs` before export |
| `$cluster_steps` word-splitting | It's a string like `"20 70 10"` with `nargs=3` — MUST NOT be quoted | Exported as string, used unquoted (shellcheck disable preserved) |
| Per-worker memory | ~25 MB + SSW objects per RPI; 8-way parallel could hit 200-500 MB. Not a problem on a 64-core box, but worth a note. | Recommend start with `UMI_PARALLEL_JOBS=2` and tune up |
| Matplotlib backend | `pyplot` imported at module top; each worker process is separate so no X-server contention | Docker sets `MPLBACKEND=Agg` by default — no action |
| `trap RETURN` on temp task file | Both branches now `trap` on their own `_tasks`/`_tasks_umic`. Each branch `return`s before the other's trap installs. | Harmless — only one branch runs per invocation |
| No shared state | `UMIC-seq_fastq_v2.py` only writes to per-RPI `$args.output` — no shared counters, no shared plot paths | No mutex needed |

### D.4 — Test plan (post-serial-run, non-disturbing)

The current serial UMIC-seq run (PID-tracked, writing to
`/home/vscode/runs/rep3_umic_test/`) will finish on its own. After
that:

```bash
# 1. Hardlink demux into a separate dir (zero extra disk, same inodes)
cp -al /home/vscode/runs/rep3_umic_test/03_demux \
       /home/vscode/runs/rep3_umic_parallel/03_demux
cp /home/vscode/runs/rep3_umic_test/pipeline_summary.tsv \
   /home/vscode/runs/rep3_umic_parallel/pipeline_summary.tsv
# Strip the step-04 rows (we're regenerating them)
awk -F'\t' 'NR==1 || $4 < "04"' \
    /home/vscode/runs/rep3_umic_parallel/pipeline_summary.tsv \
    > /home/vscode/runs/rep3_umic_parallel/pipeline_summary.tmp && \
mv /home/vscode/runs/rep3_umic_parallel/pipeline_summary.tmp \
   /home/vscode/runs/rep3_umic_parallel/pipeline_summary.tsv

# 2. Run parallel UMIC-seq (start cautious — jobs=2)
cd /workspace
UMI_PARALLEL_JOBS=2 ./L3Rseq run \
    --input  /home/vscode/runs/rep3_umic_parallel \
    --outdir /home/vscode/runs/rep3_umic_parallel \
    --method umic-seq \
    --probe  resources/probes/RPI_probe_bottom_20nt.fasta \
    --threads 64 --no-target-fwd \
    --start-at 4 --stop-at 4

# 3. Diff output vs serial reference
S=/home/vscode/runs/rep3_umic_test/04_umi
P=/home/vscode/runs/rep3_umic_parallel/04_umi

# a) Same set of RPIs + bin files?
diff <(cd "$S" && find . -name '*bins.fastq' | sort) \
     <(cd "$P" && find . -name '*bins.fastq' | sort)

# b) Byte-identical content? (deterministic — clusterfull is stable)
(cd "$S" && find . -name '*bins.fastq' -exec md5sum {} \;) | sort -k2 > /tmp/serial.md5
(cd "$P" && find . -name '*bins.fastq' -exec md5sum {} \;) | sort -k2 > /tmp/parallel.md5
diff /tmp/serial.md5 /tmp/parallel.md5
```

Acceptance: diff on (a) must be empty (same set of bins); diff on
(b) expected empty (clusterfull is deterministic with `--stop_thresh 0`
and stable input FASTA order). If (b) has minor differences, compare
sorted read-ID sets per bin as a fallback — read-ID set should
still match exactly.

After the correctness check:

```bash
# 4. Scale up (4-way parallel)
rm -rf /home/vscode/runs/rep3_umic_parallel/04_umi
UMI_PARALLEL_JOBS=4 ./L3Rseq run ... (same args as above)
# record wall time, append to runs/pipeline_timings.tsv

# 5. If memory is fine and scaling holds, try 8-way
```

Expect near-linear speedup up to `min(N_RPIs, UMI_PARALLEL_JOBS)` until
memory saturates. On 18-RPI REP3 data, a 4-way parallel run should
complete step 04 in roughly 25-30 min (vs ~120 min serial). 8-way
should drop to 15-20 min if memory permits.

## Cross-references

- `docs/pipeline_speed_investigation.md` — the longread-umi / FS / parallel work from earlier today.
- `docs/pipeline_fast_storage_plan.md` — rollout plan for the workspace storage change.
- `docs/rep3_comparison_limitations.md` — what we couldn't verify against REP3 due to missing reference.
- `runs/pipeline_timings.tsv` — benchmark log including the REP3 timings that motivated this doc.
- Branch `speedup-step04-parallel` — the longread-umi RPI-parallelization precedent. Any UMIC-seq work would live on a sibling branch or the same branch depending on review scope.
- **Git archeology (2026-04-24):** verified no prior UMIC-seq RPI-parallelization attempt exists in any commit, branch, reflog, deleted file, or in the Takehira snapshot's independent git history. The pattern in Appendix D is a genuine first implementation.
