# Rollout Plan — Parallel Step 04 to Production

Drafted: 2026-04-25. The parallel-step-04 work is fully implemented
and validated on branch `speedup-step04-parallel`. This doc covers
turning that branch into a production-ready merge: devcontainer
changes, CLI exposure, docs, tests, and PR strategy.

## Current state (2026-04-25)

**Done — uncommitted on branch `speedup-step04-parallel`:**

- `scripts/04_umi.sh` — parallelization for both methods via env var
  `UMI_PARALLEL_JOBS`. Default 1 (serial) preserves prior behavior.
- `docs/pipeline_speed_investigation.md` — root-cause + benchmarks.
- `docs/pipeline_fast_storage_plan.md` — workspace storage plan.
- `docs/umic_seq_speedup_plan.md` — algorithmic plan + measured results.

**Validated:**

| Method | Config | Step 04 wall | Output correctness |
|---|---|---|---|
| longread-umi | serial 9P | 1344 s | baseline |
| longread-umi | `UMI_PARALLEL_JOBS=8` ext4 | 44 s | byte-identical |
| UMIC-seq | serial ext4 | 6498 s | baseline |
| UMIC-seq | `UMI_PARALLEL_JOBS=4` ext4 | 969 s (6.71×) | byte-identical |

**Known technical debt:**

- UMIC-seq branch contains a hardcoded fallback to
  `/opt/miniforge/envs/longread_umi/bin/parallel` because the UMIC-seq
  conda env doesn't ship GNU `parallel`. This works but should be
  removed once `parallel` is added to the UMIC-seq env via Dockerfile.
- `UMI_PARALLEL_JOBS` is undocumented and only an env var. No CLI
  flag, not in `--help`, not in CLAUDE.md.
- No automated test that verifies serial-vs-parallel byte equivalence.

## Decision points (please decide before kickoff)

1. **Default value of `UMI_PARALLEL_JOBS`:**
   - **(a) Keep default = 1 (serial).** Zero-risk. Users opt in.
     **Recommended.**
   - (b) Default = `min(8, nproc/8)`. Faster out-of-the-box but changes
     observed behavior for everyone.
2. **Expose via CLI flag in addition to env var?**
   - **(a) Yes — add `--umi-parallel-jobs N`.** More discoverable;
     env var continues to work as override. **Recommended.**
   - (b) No — env var only. Less surface area but worse UX.
3. **Devcontainer `parallel` install scope:**
   - **(a) Add to UMIC-seq env** (small; one mamba install line).
     **Recommended.**
   - (b) Move to a shared "tools" env, refactor activation. Larger
     change.
4. **Step 05 (racon consensus) — same treatment?**
   - 05 already parallelizes within an RPI via GNU parallel inside
     `consensus_racon.sh`. RPI-level parallelism would help small RPIs
     but stacks with within-RPI saturation — gains are smaller and
     risk of OOM is larger. **Recommend: defer** until step 04 is
     merged, then evaluate.
5. **Commit / PR shape:**
   - **(a) One PR per logical concern** (code; docker; docs; tests).
     Cleaner review. **Recommended.**
   - (b) One mega-PR. Simpler reviewer cognitive load if it's one
     reviewer who sees all parts at once.

The plan below assumes the **(a) Recommended** answer to each.

## Phase plan

Each phase is independently mergeable + reversible. Roughly ordered
by precedence, but 3 and 4 can be done in parallel.

### Phase 1 — Dispatcher CLI + docs hooks (~1 h, no rebuild needed)

Add `--umi-parallel-jobs N` to `L3Rseq run` and `L3Rseq umi`. Maps to
env var. Validation: positive integer.

Touched files:
- `/workspace/L3Rseq` — argument parsing, help text
- `/workspace/scripts/04_umi.sh` — accept either env var or arg
- `/workspace/docs/api.md` (if it has a `run`/`umi` reference)

Diff sketch (in `L3Rseq`, near line 363 where `--method` is parsed):

```bash
local umi_parallel_jobs="${UMI_PARALLEL_JOBS:-1}"
...
case "$1" in
    --umi-parallel-jobs) require_arg "$1" "${2:-}"; umi_parallel_jobs="$2"; shift 2 ;;
    ...
esac
...
# Pass through to env when invoking step 04
UMI_PARALLEL_JOBS="$umi_parallel_jobs" _conda_run "$ENV_LONGREAD_UMI" 04_umi.sh ...
```

### Phase 2 — Devcontainer: install `parallel` in UMIC-seq env (~30 min wait + ~20 min Docker rebuild)

Edit `/workspace/.devcontainer/build/Dockerfile`, line 102-109, add
`parallel` to the `mamba create` for UMIC-seq env:

```dockerfile
# was: mamba create -y -n UMIC-seq -c conda-forge -c bioconda \
#         python=3.11 biopython scikit-bio matplotlib ...
# new: append parallel
RUN mamba create -y -n UMIC-seq -c conda-forge -c bioconda \
    python=3.11 biopython scikit-bio matplotlib ... \
    parallel=20260122
```

Then per `CLAUDE.md` "Dockerfile changes require a tagged release":

```bash
git tag v1.X.Y && git push origin v1.X.Y
gh run watch  # wait for docker-publish.yml
# Then: Dev Containers: Rebuild Container
```

After the rebuild, **remove the hacky fallback**
(`/opt/miniforge/envs/longread_umi/bin/parallel` lookup) from
`scripts/04_umi.sh` — `command -v parallel` will then succeed in
both envs.

### Phase 3 — Documentation (~30 min, no rebuild)

Touched files:

1. **`/workspace/CLAUDE.md`** — under "Container environment" or a new
   "Performance tuning" subsection, document `UMI_PARALLEL_JOBS`:
   ```markdown
   ### Step 04 RPI parallelism

   `--umi-parallel-jobs N` (or env var `UMI_PARALLEL_JOBS=N`) runs N
   RPIs concurrently in step 04. Threads are divided evenly
   (`THREADS / N` per worker). Default 1 = serial. Recommended:
   `--umi-parallel-jobs 4` for UMIC-seq, `--umi-parallel-jobs 8` for
   longread-umi on 64-core hosts. Output is byte-identical to serial.
   ```

2. **`/workspace/README.md`** — if it shows a one-liner usage example,
   add a note about the flag. Keep it brief.

3. **`/workspace/CHANGELOG.md`** — new entry:
   ```markdown
   ## v1.X.Y — 2026-04-XX
   - Added `--umi-parallel-jobs N` for RPI-level parallelism in
     step 04. ~6× speedup on UMIC-seq, ~30× on longread-umi-via-9P.
     Default unchanged (serial).
   - UMIC-seq env now ships GNU parallel.
   ```

4. **Cross-link from `docs/umic_seq_speedup_plan.md`** to this rollout
   doc and from `docs/pipeline_speed_investigation.md`.

### Phase 4 — Tests (~1 h, no rebuild)

Add a parallel-equivalence test to `tests/run_tests.sh`:

```bash
# After the existing serial step 04 test:
echo "[Test] step 04 parallel-vs-serial equivalence ..."
# Re-run step 04 with UMI_PARALLEL_JOBS=4 on the same fixtures
# and diff ExtractedUMIs.fasta + bins_kept counts.
UMI_PARALLEL_JOBS=4 ./L3Rseq run ... --start-at 4 --stop-at 4 \
    --outdir tests/output/step04_parallel
diff <(find tests/output/step04_serial   -name 'ExtractedUMIs.fasta' \
        -exec md5sum {} \; | sort) \
     <(find tests/output/step04_parallel -name 'ExtractedUMIs.fasta' \
        -exec md5sum {} \; | sort)
```

If the synthetic test data has only 1-2 RPIs, parallelism won't really
exercise; consider expanding the fixture, or accept that CI just
verifies the codepath doesn't crash and serial-vs-parallel happens to
match for tiny N.

### Phase 5 — Commit and PR (~30 min)

Suggested commit sequence on branch `speedup-step04-parallel`:

```
1. step04: add UMI_PARALLEL_JOBS env var to longread-umi branch
2. step04: same for UMIC-seq branch (with parallel-binary fallback)
3. dispatcher: add --umi-parallel-jobs CLI flag
4. devcontainer: install parallel in UMIC-seq env (TAG required)
5. step04: remove parallel-binary fallback (depends on 4 + rebuild)
6. tests: add parallel-vs-serial equivalence test
7. docs: CLAUDE.md, README, CHANGELOG, cross-links
```

Or squash to ~3 commits if a tighter review surface is preferred:
(a) "step04: RPI parallelism + CLI flag", (b) "devcontainer:
parallel in UMIC-seq env", (c) "docs+tests".

PR description template:

> **Add RPI-level parallelism to step 04.** Default unchanged
> (serial). New env var `UMI_PARALLEL_JOBS` (and CLI flag
> `--umi-parallel-jobs N`) enables N concurrent per-RPI workers via
> GNU parallel.
>
> Measured on REP3 (18 RPIs) with `UMI_PARALLEL_JOBS=4`:
> - longread-umi: 1344 s → 44 s (30×, ext4 also helped)
> - UMIC-seq: 6498 s → 969 s (6.71×)
>
> Output byte-identical vs serial (verified on bins_kept,
> ExtractedUMIs.fasta md5, cluster counts).
>
> Continuity-preserving: UMIC-seq's algorithm and per-RPI behavior
> are unchanged; only the outer RPI loop is parallelized.

## What I can implement now (without your approval)

These are mechanical, reversible changes that don't require a Docker
rebuild:

1. Add `--umi-parallel-jobs N` to `L3Rseq` dispatcher (Phase 1).
2. Edit Dockerfile to add `parallel` to UMIC-seq env (Phase 2 code,
   not the rebuild).
3. Update CLAUDE.md and CHANGELOG.md drafts (Phase 3).
4. Add the parallel-equivalence test wrapper to `tests/run_tests.sh`
   (Phase 4).

## What needs your involvement

- **Tagging a release** (`git tag v1.X.Y && git push`) — kicks off
  the Docker image rebuild. Per `CLAUDE.md` this is your call.
- **Container rebuild** after the new image lands.
- **Final review and merge** of the branch into main.

## Cross-references

- `docs/pipeline_speed_investigation.md` — root cause + 9P FS
  finding that motivated the parallel work.
- `docs/pipeline_fast_storage_plan.md` — workspace storage rollout
  (orthogonal but stacks).
- `docs/umic_seq_speedup_plan.md` — algorithmic plan + measured
  numbers on UMIC-seq side.
- `runs/pipeline_timings.tsv` — machine-readable benchmark log,
  4 measured rows so far.
- Branch `speedup-step04-parallel` — the working branch with all
  the uncommitted changes.
