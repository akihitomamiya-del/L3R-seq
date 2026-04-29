# Snakemake `skip_correct` flag — session notes (2026-04-29)

Reference doc for future Claude sessions touching the Snakemake pipeline.
Covers what was added in this session, why, and the non-obvious bits worth
knowing before extending. The full design spec is in
`PIPELINE_MODERNIZATION.md` § "Done (Phase 2 follow-up)"; this doc is the
implementer's notes.

## TL;DR

`config.yaml` now has a `skip_correct: false` flag. When `true`, the DAG
resolves to `concat → trim → demux → umi → consensus → extract → map → count`,
skipping rules `variants`, `correct`, and `export_csv` entirely. Closes the
gap between the bash dispatcher's `L3Rseq run --stop-at 7 && L3Rseq count`
and the Snakemake entry point — both paths now produce byte-identical output.

```bash
# Single-command equivalent of the bash 1→7+count workflow:
snakemake --configfile config.yaml --cores N \
          --config skip_correct=true regions=path/to/regions.tsv
```

## Why this was needed

The bash dispatcher's `count.py` already prefers `09_correct/` but falls
back to `07_map/` (`src/l3rseq/count.py:260-264`), so a 1→7+count workflow
"just works" via `L3Rseq run --stop-at 7 && L3Rseq count`. The Snakefile
couldn't do this because `rule count` and `rule export_csv` declared a
hard dependency on `09_correct/.done`. Takehira-san's LibCheck workflow
(amplicon mapping + qPCR-style transcript counting, no editing analysis)
was forced into a hybrid `snakemake --until map` + `L3Rseq count`
two-tool workaround until this flag landed.

## Files changed

| File | What |
|---|---|
| `Snakefile` | `SKIP_CORRECT` module-level flag (~line 56), `count_input()` function (~line 498), `rule count.input` switched from static `done=...` to function, `all_targets()` drops `csv_outputs()` when `SKIP_CORRECT` |
| `config.yaml` | New documented `skip_correct: false` key in the run-parameters section |
| `tests/run_tests_snake.sh` | New `--mode={full,skip-correct}` flag; mode-specific bash baseline (full=`run_tests.sh --test 2`, skip-correct=`L3Rseq run --start-at 4 --stop-at 7`); dry-run DAG contract assertion; post-run directory negative-existence assertion; step-09 BAM diff gated to full mode |
| `.github/workflows/test.yml` | New step in `snakemake-test` job runs `run_tests_snake.sh --mode skip-correct --cores 4` after the resume-behavior step |
| `docs/PIPELINE_MODERNIZATION.md` | Feature row added to status table; deferred bullet moved to "Done (Phase 2 follow-up)" subsection with LibCheck validation result |

`count.py`, `rule export_csv`, `rule correct`, `tests/data/`, and
`tests/config_synthetic.yaml` were intentionally NOT modified — the
fallback already exists in `count.py`, the unused rules just aren't
pulled in by the DAG, the `--config skip_correct=true` CLI override is
sufficient.

## How the DAG resolves

With `03_demux/` pre-staged (so the checkpoint is satisfied), `snakemake
--dry-run` produces:

| Mode | Job stats |
|---|---|
| default (`skip_correct=false`) | umi(4) + consensus(4) + extract(4) + map(4) + variants(4) + correct(1) + count(1) + export_csv(4) + all(1) = **27** |
| `--config skip_correct=true` | umi(4) + consensus(4) + extract(4) + map(4) + count(1) + all(1) = **18** |

The 9-job delta is exactly `variants + correct + export_csv`. Snakemake
doesn't pull rules nothing depends on, so they're cleanly absent — no
conditional `rule:` syntax needed.

## Validation summary

**Synthetic fixtures** (`tests/run_tests_snake.sh`):

| Mode | Result |
|---|---|
| `--mode full` (default) | 10/10 comparisons identical (no regression) |
| `--mode skip-correct` | 6/6 comparisons identical (gene_counts_all + 4 per-sample + coverage); DAG contract OK; 08/09/10 dirs absent |

**Real-data parity** (LibCheck, Marchantia, 36 samples × 39 genes,
MpTak1_v7.1 genome, 200 MB raw FASTQ): pre-staged `03_demux/` from
`Past_runs/runs/LibCheck/03_demux_all/` (since the bash flow filters RPIs
1-12 manually, but the Takehira RPI fasta only has 12 RPIs anyway, so the
filter is a no-op). 146 jobs in ~62 s on 32 cores. Every output file
byte-identical to the 2026-04-04 bash output: 36/36 BAMs, 1404
`gene_counts_all.tsv` rows, 36 per-sample gene-count TSVs, 1404 coverage
depth files, `isoform_discovery.tsv`.

The 2026-04-05 commit `e6581fd` that changed `count.py` overlap to
exclude `N` (intron) CIGAR ops did NOT cause drift here — `lr:hq`
minimap2 preset doesn't emit `N` ops in DNA mode, so reads in `07_map/`
have only M/I/D/S ops and the algorithm change is a no-op. The change
only matters when reading from `09_correct/` (where step 09 has applied
intron D→N conversion).

## Non-obvious bits I hit (read these before extending)

### 1. Snakemake `--config` is single-flag, space-separated

```bash
# WRONG — second --config silently overwrites the first:
snakemake --config skip_correct=true --config output_dir=/runs/foo

# RIGHT — single --config, space-separated key=val pairs:
snakemake --config skip_correct=true output_dir=/runs/foo
```

I burned a debug cycle on this in `tests/run_tests_snake.sh`'s dry-run
assertion. Both the dry-run and the real run now use a single
`SNAKE_OVERRIDE` string built once at the top.

### 2. Dry-run DAG visibility depends on whether the checkpoint has run

`snakemake --dry-run` only enumerates jobs whose inputs it can already
resolve. Pre-checkpoint, post-`demux` jobs show up as `<TBD>` and the job
stats table omits them. So the DAG-contract assertion in `run_tests_snake.sh`
**must** run after `03_demux/` has been pre-staged — the existing
`[2/4] Pre-staging` block does this, and the dry-run assertion is placed
right after it. Don't move the assertion above the pre-staging or it will
miss the rules it's trying to assert against.

### 3. Past run's `03_demux/` has dangling symlinks

`Past_runs/runs/LibCheck/03_demux/*.fastq` are symlinks to
`/workspace/runs/LibCheck/03_demux_all/...` — that path doesn't exist
anymore (the `/workspace/runs/` tree was different at run time). For
parity tests on past output, copy from `03_demux_all/` (real files), not
from `03_demux/` (symlinks). `cp -L` from `03_demux/` would also
fail because the targets are gone.

### 4. The `count_input()` function has no `wildcards`

`rule count` is an aggregation rule (no per-sample wildcards), so its
`input:` function takes no `wildcards` arg — but Snakemake passes
`wildcards=None` regardless to dispatch-style functions. The signature
`def count_input(wildcards=None)` covers both call paths and is what
`mapped_bams()`, `csv_outputs()`, etc. already use.

### 5. `all_targets()` returning `[]` is a real possibility

When `skip_correct=true` AND `regions` is unset (or empty string), the
default goal list is empty. `snakemake` prints "Nothing to be done" and
exits 0. That's intentional — no useful default target exists for
"skip 8/9/10 with no counting either". Users in that case should be
using `snakemake --until map` instead.

### 6. CI reuse, not parallel job

The skip-correct CI step is added inside the existing `snakemake-test`
job (after the resume-behavior step), not as a separate top-level job.
This reuses the conda-env activation and the on-disk synthetic fixture
from earlier steps, adding only ~35-45s wall-clock to the job. A
top-level job would re-pay container/checkout setup for marginal
parallelism win.

## Where to extend next

If a future session wants to add another DAG-shape control flag (e.g.
"skip step 11 too" or "stop after extract"), follow the same pattern:

1. Read the flag at module top from `config.get(...)`.
2. Make the affected rule's `input:` a function that branches on the flag.
3. Adjust `all_targets()` to drop targets that would no longer build.
4. Leave the now-orphaned rules alone — Snakemake won't pull them.
5. Add a `--mode <name>` branch in `tests/run_tests_snake.sh` with a
   bash baseline that mirrors the new path, a dry-run DAG contract
   assertion, and a post-run negative-existence check.
6. Add a CI step in the existing `snakemake-test` job.

The only orchestration rule that has multi-source fallback today is
`rule count` (via `count.py:260-264`'s `09_correct/ → 07_map/` choice).
Other rules don't have that flexibility, so this pattern doesn't trivially
generalize without first adding fallbacks to the relevant Python module
or shell script.
