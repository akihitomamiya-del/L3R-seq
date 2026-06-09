# L3Rseq — Claude Code Guidelines

## Memory

Actively use the memory system (`~/.claude/projects/-workspace/memory/`).
Save user preferences, feedback corrections, and project context as they
come up — don't wait to be asked. When you find a fix for a non-obvious
bug or environment issue, save it so the same problem is never debugged
twice. Personal details stay in memory files (not committed); only
behavioral instructions belong in this CLAUDE.md.

## Proactive workflow tips

Suggest these once per session, only when relevant:
- **`/loop`** for iterative debugging (e.g., `/loop 2m bash tests/run_tests.sh --quick`)
- **`/plan`** before complex multi-step changes
- **Custom slash commands** (`.claude/commands/`) for repeated workflows
- **Hooks** when the user keeps forgetting a step
- **Parallel subagents** for independent debugging
- **`/effort low`** for simple lookups

## After confirming a fix

Once verified (tests pass, manual checks succeed), **immediately offer to
commit and push**. Confirmed fixes sitting uncommitted risk being lost to
container restarts.

## Container environment

Sandboxed devcontainer with a network firewall: only GitHub, npm, and
Anthropic APIs are reachable — `apt-get install`, `pip install`, and
arbitrary `curl` will fail.

**Conda envs are pre-built and read-only** — activate before use:

| Env | Tools | Used by |
|---|---|---|
| `longread_umi` | samtools, minimap2, bwa, racon, cutadapt, vsearch, parallel, pigz | most pipeline steps |
| `cutadaptenv` | cutadapt | steps 03, 06 |
| `NanoporeMap` | minimap2, samtools, bcftools | step 07, demo data |
| `LoFreq` | lofreq, bcftools | step 08 |
| `UMIC-seq` | python3, biopython, scikit-bio | alt UMI method |
| `Entrez` | efetch, esearch | NCBI fetch |
| `analysis` | matplotlib, numpy | plotting |
| `l3rseq_py` | pysam, biopython, pyranges, snakemake, pandas, scipy, pytest, ruff, mypy | step 09/11 + dev tooling |

The `L3Rseq` dispatcher handles env activation automatically. The IGV
viewer auto-starts on port 8080 via `postStartCommand`. Puppeteer + Chrome
is available (use `--no-sandbox`).

**Auth**: browser login (`claude /login`) or host-injected
`CLAUDE_CODE_OAUTH_TOKEN` (precedence: env var > credentials file >
prompt). Verify with `claude -p "say pong"`. Setup: `docs/auth.md`.

## Step 04 RPI parallelism

Step 04 runs N RPIs concurrently via `--umi-parallel-jobs N` (or
`UMI_PARALLEL_JOBS=N`). Default 1. Threads divided evenly. Output
byte-identical to serial. On 64-core hosts: `longread-umi` → 8 (~4-8×);
`umic-seq` → 4 (~6-7×, internal multiprocessing.Pool — don't oversubscribe).
Benchmarks: `docs/parallel_step04_rollout_plan.md`,
`docs/umic_seq_speedup_plan.md`.

## Fast output volume (`/runs`)

Docker named volume `l3rseq-runs` mounted at `/runs` (ext4). Post-create
hook symlinks `/workspace/runs → /runs`. `TMPDIR=/runs/.tmp`. Survives
container rebuilds; only `docker volume rm l3rseq-runs` deletes it.
Bypasses Windows-host 9P overhead — ~30× speedup on Windows/WSL2.
**No-op on native Linux** (already on ext4) but kept for portability.
Background: `docs/pipeline_speed_investigation.md`.

Inspect/back-up:
```bash
docker volume ls
docker run --rm -v l3rseq-runs:/data -v "$PWD:/out" alpine \
    tar czf /out/runs-backup.tar.gz -C /data .
```

## Devcontainer configurations

| Directory | Notes |
|---|---|
| `devcontainer.json` (root) | Default for Codespaces. Pre-built ghcr image. No Claude CLI. |
| `claude-code/` | Builds Dockerfile. Adds Claude CLI, firewall, dev tooling. |
| `build/` | Builds Dockerfile. For testing local image changes. |

## Docker image publishing

Base: `ghcr.io/akihitomamiya-del/l3rseq`. CI publishes on version tags:
```bash
git tag v1.0.XX && git push origin v1.0.XX
```
Then rebuild devcontainer to pick up the new image.

## Branch protection

`main` (set 2026-04-25): force pushes blocked, branch deletion blocked,
no PR/review/check-gating (solo-dev), `enforce_admins = false` (owner can
bypass). Inspect: `gh api repos/akihitomamiya-del/L3R-seq/branches/main/protection`.

### CLAUDE.md copies (keep in sync)

Three copies — update all three when changing this file:
1. `.devcontainer/claude-code/CLAUDE.md` — **committed** template
2. `~/.claude/CLAUDE.md` — **active** (what Claude reads; on a Docker volume)
3. `/workspace/CLAUDE.md` — **gitignored**, may not exist

Quick sync: `cp .devcontainer/claude-code/CLAUDE.md ~/.claude/CLAUDE.md`

## Before starting work

`git fetch --all && git pull` on `main`. Upstream fixes may already
address the issue.

## Common gotchas

- **Inverted `.gitignore`**: repo ignores `*` and allowlists with `!`-prefix.
  New files won't be staged unless their path is allowlisted.
  `/workspace/CLAUDE.md` is gitignored — never commit it; tracked copy is
  `.devcontainer/claude-code/CLAUDE.md`.
- **Line endings**: `.gitattributes` opens with `* text=auto eol=lf`,
  overriding Windows' `core.autocrlf=true`. **New binary file types** need
  `*.newext binary` added (BAM, BAI, gz, PNG, BLAST DB shards already
  tagged). If `git status` shows a large batch of unchanged "modified"
  files: `git ls-files --eol | awk '$1 ~ /crlf/'` to confirm, then
  `git add --renormalize <path>`.
- **Viewer dev cycle (strict)**:
  1. Edit — apply to ALL 3 pages (index/umi/genes) when relevant
  2. Restart: `L3Rseq viewer --stop && L3Rseq viewer --dir <dir>`
  3. Screenshot-verify with Puppeteer (`LD_LIBRARY_PATH="/opt/miniforge/envs/analysis/lib"`)
  4. Test the user scenario end-to-end (gene click → alignment → back)
  5. Read screenshots before declaring success
  Never rely solely on API/JS state — screenshots catch caching, layout, navigation bugs.
- **IGV.js Shadow DOM (v3+)**: external CSS can't style IGV internals.
  Access `browser.root.getRootNode()` from JS. Puppeteer headless can read
  Shadow DOM state (`window.browser.trackViews.length`) but does NOT
  render IGV canvases visually — track areas are blank in headless
  screenshots. Use DOM/JS assertions for automated checks; ask the user
  to verify visual rendering when canvas matters.
- **Viewer primary usage flow** (test every change against this):
  Gene Counts → click gene → "Alignment Viewer" → toggle barcode groups
  → back → another gene → return. Verify: locus preserved across track
  toggles, controls bar visible with all tracks deselected, dataset/state
  preserves across pages.
- **Viewer shared code**: common CSS in `css/shared.css`, common JS in
  `js/shared.js` (sample selector, toggles, chart cleanup, nav sync,
  `initDatasetPage()`). Page JS in `js/{alignment,umi,genes}.js`. Server
  domain logic in `lib/` (`bam.js`, `discovery.js`, `pipeline-stats.js`,
  `fasta.js`, `helpers.js`); `server.js` is a thin HTTP adapter.
  Multi-page features go in shared files. The alignment page does NOT use
  the shared sample selector or `initDatasetPage()`.
- **Viewer dev overlay**: grey "DEV" button (bottom-right). Hover →
  component name + selector. Right-click copies label
  (`document.execCommand("copy")` because Simple Browser blocks the
  clipboard API). Never modifies styles, never intercepts left clicks.
- **Viewer state**: dataset via `?name=` query param; genes-page view
  state in URL hash (`#v=table&sel=GENE&g=FILTER`). Nav links set by
  `syncNavLinksFromUrl()` (immediate) and `syncNavLinks()` (after
  dataset load) — immediate sync matters for the slow alignment page.
  URL hash primary; sessionStorage backup. Gene clicks update the header
  link instead of navigating away (`target="_blank"` doesn't work in
  Simple Browser).
- **Viewer — known fixes baked in**: `Cache-Control: no-cache` on HTML;
  `loadDefaultGenomes: false` in IGV.js; BAI content inspection for
  empty-BAM filtering; skip `sanitizeFasta` for >10MB files;
  `{ samtools ... || true; }` pipes to prevent pipefail crashes on missing
  chromosomes; hidden tracks start unchecked in `buildTrackToggles`;
  multi-chromosome reference matching via FAI.
- **Test flags**: don't add `--no-viewer` by default — the test suite
  handles viewer restart. Use `--quick` for fast iteration.
- **Step 09 error handling**: `09_tail_correct.sh` uses `set -euo pipefail`
  at file level, but per-read worker `_process_one_read()` starts with
  `set +e`. Validation guards (`_require_int`, `_require_str`) check
  `RESULT_*` after each subscript — silent failures get `FAILED` status +
  `BUG:` warning. Other scripts use strict mode.
- **Known issues**: `docs/development.md` § "Known issues" tracks bugs
  (coverage ignoring min-mapq, stale file globs after rename) and test
  gaps. Consult before working on steps 07-11 or the test suite.
- **RPI-filter rerun**: `rm -rf` previous OUTDIR before rerunning
  `examples/run_pipeline_with_rpi_filter.sh` — leftover `03_demux_all/`
  breaks RPI filtering on the second pass.

## Pipeline modernization habits

The bash → Python modernization (Phases 0–4) is complete: step 09 + 11
run from `src/l3rseq/` under `l3rseq_py`, the Snakefile wraps all 11
steps, `config.yaml` is the single source of truth. History:
`docs/PIPELINE_MODERNIZATION.md`.

- **Pre-commit check trio for Python changes** (run before any commit
  under `src/l3rseq/` or `tests/python/`):
  ```bash
  /opt/miniforge/envs/l3rseq_py/bin/ruff check src/ tests/python/
  /opt/miniforge/envs/l3rseq_py/bin/mypy src/l3rseq/
  /opt/miniforge/envs/l3rseq_py/bin/pytest tests/python/ -v
  ```
  CI runs the same trio. Mypy is `strict = true` — missing hints fail.
- **Algorithm modules stay pure**: `cigar.py`, `walk.py`, `variants.py`,
  `splice.py`, `tags.py` MUST NOT `import pysam`, touch the filesystem,
  or spawn subprocesses. Only `tail_correct.py`, `count.py`, `blast.py`,
  `config.py` may. Keeps tests isolatable.
- **Config centralized in `config.yaml`**. `config.sh` holds only conda
  env names + nproc-derived defaults. Dispatcher precedence: CLI flag >
  YAML > `_fallback_defaults()` in `scripts/load_config.sh`. To add or
  change a parameter:
  1. Edit `config.yaml`
  2. Edit `_fallback_defaults` in `scripts/load_config.sh`
  3. If new key, extend `YAML_TO_BASH` in `src/l3rseq/config.py`
  4. Run `PYTHONPATH=src python3 scripts/check_config_sync.py`
  CI fails if any step is missed.
- **Dockerfile changes require a tagged release**. Firewall blocks
  PyPI/conda-forge/bioconda at runtime. Edit
  `.devcontainer/build/Dockerfile`, commit, then
  `git tag v1.X.Y && git push origin v1.X.Y` (~20 min CI), then rebuild
  devcontainer. No `pip install -e .` shortcut; `src/l3rseq/` is on
  `pythonpath = ["src"]` (pyproject) and `PYTHONPATH=src` for module entry.
- **Port shell tests verbatim** when rewriting bash → Python: every case
  in `tests/test_shell_functions.sh` ports to pytest with same I/O. See
  `tests/python/test_cigar.py`, `test_splice.py`.
- **Differential test before flipping the dispatcher to Python**: prove
  byte-identical SAM/BAM output on full quick-test fixtures
  (`samtools view | sort | diff`). Document any deviation in the commit.
  Pattern: `tests/benchmarks/diff_step09.sh`, `diff_step11.sh`.
- **Benchmark with `date +%s.%N`**, not bash `SECONDS` (integer rounding
  hides sub-10s signal). See `tests/benchmarks/bench_step09.sh` for the
  multi-iteration min/median/mean pattern.

## Running the pipeline with Snakemake

The Snakefile is the modern entry point; bash dispatcher
(`L3Rseq run --start-at N --stop-at M`) still works but lacks DAG
parallelism, resume-from-failure, and `skip_correct`.

- **Per-experiment configfile, not the repo's `config.yaml`**. The shipped
  one is wired to test fixtures. For real runs, copy to
  `<run_dir>/config.yaml`, edit `input_dir` / `output_dir` / `ref` /
  `rpi_fasta`, pass via `--configfile`. Override paths with
  `--config key=val`. Co-locate a `RUN_NOTES.md` capturing experimental
  decisions — that's the durable scientific record.
- **`--configfile` REPLACES the default; does not merge**. Whatever YAML
  you pass becomes the entire `config` dict — every key the Snakefile
  reads must be present or `KeyError`. Start from a verbatim copy.
  **Don't drop the `threads:` block** even when using defaults.
- **`--config` idiom**: single flag, space-separated `key=val` pairs:
  ```
  --config output_dir=/runs/foo skip_correct=true regions=/runs/foo/regions.tsv
  ```
  Repeating `--config` overwrites previous overrides — only the last wins
  (`tests/run_tests_snake.sh:222`). Build the override string once and
  reuse for both dry-run and real run.
- **Skip step 01 (pre-concatenated FASTQs)**: pre-stage
  `<output_dir>/01_concat/{barcode}.fastq.gz`; mtime check skips
  `rule concat`. **Still need `input_dir` with one subdir per barcode**
  because `BARCODES = sorted(os.listdir(input_dir))` runs at Snakefile
  load time (`Snakefile:101-104`); empty placeholder dirs suffice.
- **Multi-gene pool / no 5' anchor**: `target_fwd: ""` in configfile.
  Step 06 falls into the trim-rev-only branch
  (`scripts/06_extract.sh:50-62`). Snakemake-native equivalent of the bash
  `--no-target-fwd` flag.
- **No RNA editing analysis**: `skip_correct: true` (merged 2026-04-29,
  `docs/snakemake_skip_correct.md`). DAG resolves to
  `concat → trim → demux → umi → consensus → extract → map → count`,
  skipping `variants`/`correct`/`export_csv`. Still requires `regions:
  <path>`. `count.py:260-264` falls back from `09_correct/` to `07_map/`.
- **`--until <rule>` doesn't work at the checkpoint**. Post-checkpoint
  wildcards (`{rpi}`) are only enumerable AFTER `rule demux` materializes
  `03_demux/{barcode}/`. Workarounds:
  1. Generate seed regions.tsv from GFF alone (no `--discover-from`),
     run end-to-end with `regions=<seed>`. `rule count` as terminal target
     pulls everything through the checkpoint. Optionally re-discover with
     `--discover-from <out>/07_map --min-reads 5` post-run.
  2. Two-phase explicit-targets: phase 1 with `regions=""` runs trim+demux;
     phase 2 demands BAM paths via globbing `03_demux/`.
  Option (1) is cleaner.
- **DAG-contract dry-run before the real run**. Snakemake silently no-ops
  bad invocations:
  ```bash
  snakemake --configfile ... --cores 1 --dry-run --config $OVERRIDES \
      2>&1 | tee dryrun.log
  # for skip_correct, verify these are NOT scheduled:
  for r in variants correct export_csv; do
      grep -qE "^${r} +[0-9]+$" dryrun.log && { echo FAIL; exit 1; }
  done
  ```
  See `tests/run_tests_snake.sh:231-253`.
- **Output-tree contract assertion**. After a `skip_correct` run:
  ```bash
  for d in 08_variants 09_correct 10_csv; do
      [ -d $OUT/$d ] && { echo "FAIL: $d exists"; exit 1; }
  done
  ```
- **`pigz` is in `longread_umi`**, not on default PATH. Use
  `/opt/miniforge/envs/longread_umi/bin/pigz` or `conda run -n longread_umi pigz`.
  ~6× faster than single-threaded `gzip` at `-p 8`.
- **`--housekeeping` is per-sample**: divides each gene's count in S by
  housekeeping count in same S. Only works when housekeeping is
  co-amplified in every library. Cross-NB / cross-RPI normalization is
  downstream (R/pandas) — get raw counts via `gene_counts_all.tsv`.
- **Auto-discover regions, two modes**:
  - `L3Rseq regions --gff <f> --output regions.tsv` — every gene from GFF.
    Use as seed for end-to-end snakemake.
  - `L3Rseq regions --gff <f> --discover-from <bam_dir> --output regions.tsv --min-reads N` —
    filter to genes with ≥N reads in step-7 BAMs. Use post-run for curated list.
- **Ultra-long reads can trip cutadapt at step 02**. Concatemer/artifact
  reads (>4 MB) raise `OverflowError: FASTA/FASTQ record does not fit
  into buffer` (cutadapt 4.9 has no `--buffer-size`). Pre-filter:
  ```bash
  zcat barcode_X.fastq.gz | \
    awk 'NR%4==1 {h=$0; getline s; getline p; getline q;
                  if (length(s) <= 100000) {print h; print s; print p; print q}}' | \
    /opt/miniforge/envs/longread_umi/bin/pigz -p 8 > barcode_X.filtered.fastq.gz
  ```
  100 KB is safe (typical amplicons 1–5 kb). Drop fraction <0.01%. Keep
  the original as `*.fastq.gz.orig`. Snakemake mtime-reruns affected barcode.
- **`min_frac=0.95` (the doc default) is wrong for whole-genome L3Rseq —
  use `min_frac=0.01`**. Reads are ~700 bp 3'-end fragments; on a 5 kb
  gene `overlap/region.length` ~14% (`count.py:195`). Symptom: every cell
  in `gene_counts_all.tsv` is 0 even though step-7 BAMs are healthy.
  Verified: forcing `min_frac=0.01` took UBE2 from 0 → 12,459 reads.
  Pass `--config min_frac=0.01` or set in configfile from start. Bash
  dispatcher has the same trap (past LibCheck used `--min-frac 0.01`,
  see `Past_runs/runs/LibCheck_sample.sh`).
- **IGV viewer + `/runs` output**: the claude-code devcontainer now sets
  `IGV_DATA_DIR=/runs` by default (`containerEnv`), so
  `L3Rseq viewer --dir /runs/<run_name>` serves `/runs` datasets with no
  extra flags. `bam.js:trackUrl()` only emits servable URLs for paths under
  `WORKSPACE` or `IGV_DATA_DIR`, so if `IGV_DATA_DIR` is unset (e.g. the
  plain Codespaces root config) or output lives outside `/runs`, set it
  explicitly — else `/api/tracks` returns "No BAM files found":
  `IGV_DATA_DIR=<dir> L3Rseq viewer --dir <dir>`.

## Project overview

L3Rseq — long-read UMI sequencing pipeline for Oxford Nanopore data.
Analyzes RNA editing, splicing, 3' end cleavage, and poly(A) tails on
single molecules.

Two execution paths produce identical output (steps 09, 11 byte-identical):
- **Snakemake (recommended)** — `snakemake --cores N --configfile config.yaml`
  from `l3rseq_py`. DAG-parallel across `{barcode, RPI}`,
  resume-from-failure. Snakefile at repo root delegates to
  `scripts/0?_*.sh` and `src/l3rseq/*.py`.
- **Bash dispatcher** — `L3Rseq` script with subcommands (`run`, `concat`,
  `regions`, `count`, `viewer`, ...). One-off invocations with CLI flags;
  no DAG parallelism (only `--umi-parallel-jobs N` for step-04).

Key tools: longread-umi (adapted) for UMI consensus, UMIC-seq for UMI
clustering, custom SAM-tag IGV visualization, BLAST for sequence ID.

## Running tests

```bash
bash tests/run_tests.sh                    # Full suite (156 checks, ~45s)
bash tests/run_tests.sh --skip-preprocess  # Steps 04-10 only (~30s)
bash tests/run_tests.sh --quick            # Smoke test (~26s, CI)
bash tests/run_tests.sh --no-viewer        # Skip viewer auto-start
bash tests/test_shell_functions.sh         # CIGAR/splice/BLAST helpers
bash tests/test_docker_image.sh            # Host only — NOT inside container
```
Tests are deterministic. Output goes to `tests/output/`.

**Python tests** (from `l3rseq_py`):
```bash
pytest tests/python/ -v --cov=src/l3rseq --cov-report=term-missing
ruff check src/ tests/python/
mypy src/l3rseq/
```
All three must pass before any commit under `src/l3rseq/` or `tests/python/`.

**Viewer tests**:
```bash
cd igv_viewer && npm test                 # Puppeteer DOM (46 checks, synthetic)
cd igv_viewer && npm run test:stress      # Real data, auto-discovers
node igv_viewer/test_stress.js runs/LibCheck   # Explicit dataset
```
Stress tests exercise track cap (>8), barcode toggles, all view modes,
gene→alignment round-trip, cross-page state. Skip cleanly if no real data.
Slash command `/stress-test` runs the full cycle.

**Curl API stress test** (no browser): see `docs/development.md` or run
`/stress-test`. Covers shared.css inclusion, JSON validity per dataset,
400/404 error handling, byte-range BAM, no-cache headers.

## IGV viewer

```bash
L3Rseq viewer --dir <output_dir>     # Start on port 8080
L3Rseq viewer --stop                  # Stop
```
Auto-starts after `tests/run_tests.sh` (unless `--no-viewer`). Three
pages share dataset via `?name=` URL parameter:
- `/` — Alignment (IGV.js BAM tracks, steps 07/09)
- `/umi` — UMI bin-size analysis (Chart.js, step 04). Modes: Overlay,
  Grid, Table. Singletons hidden by default; samples colored by barcode family.
- `/genes` — Gene counts (qPCR-style, step 11). Modes: Table, Chart,
  Isoforms, Coverage. Housekeeping selector + gene/sample filters.

API endpoints all take `?name=<dataset>`: `/api/tracks`, `/api/umi-stats`,
`/api/gene-counts`, `/api/gene-coverage`.

## Gene-level counting (qPCR-style)

Standalone post-analysis subcommands. Run AFTER the main pipeline.

```bash
# Auto-discover regions from BAMs + GFF (recommended)
L3Rseq regions --gff annotation.gff3 --discover-from out/ --output regions.tsv --min-reads 5

# Or define manually (GFF, BED, coordinates; --append for incremental)
L3Rseq regions --gff annotation.gff3 --output regions.tsv

# Count molecules per gene
L3Rseq count --input out/ --outdir out/ --regions regions.tsv \
    [--housekeeping GENE] [--min-frac 0.01] [--min-mapq 20]
```
Outputs in `11_count/`: per-sample counts, merged, per-isoform breakdown,
pooled isoform discovery, normalized ratios, per-base coverage.

**Splice-aware**: prefers `09_correct/` BAMs (intron D→N) over `07_map/`,
falls back automatically. CIGAR overlap excludes `N` (intron skip) so
spliced reads don't count toward intron regions. Header lines in regions
TSV are auto-skipped.

**Strand**: gene counting is strand-agnostic (all primary alignments).
Step 09 CIGAR-walk correction assumes + strand (3' tail = right clip);
minus-strand genes need left-clip correction (not yet implemented). Use
per-gene references for 3' tail analysis.

## Key directories

- `L3Rseq` — main entry script (bash, not a directory)
- `scripts/` — pipeline steps 01-11 + regions.sh
- `longread_umi_L3Rseq/scripts/` — UMI binning + consensus
- `igv_viewer/` — Node.js viewer (IGV.js + Chart.js)
- `src/l3rseq/` — Python algorithmic core (steps 09, 11)
- `tests/` — test suite, fixtures, expected output
- `resources/` — reference FASTAs, RPI barcodes, BLAST DBs
- `docs/` — [adaptation](../docs/adaptation.md), [testing](../docs/testing.md), [development](../docs/development.md), [requirements](../docs/requirements.md), [troubleshooting](../docs/troubleshooting.md)
- `runs/` — pipeline output (gitignored, symlinked to `/runs`)

## Coding conventions

- Shell: `set -euo pipefail`
- Pipeline progress: `[Step NN]` and `[script_name]` prefixes
- Logs auto-generated as `l3rseq_YYYYMMDD_HHMMSS.log` in output dir
- Tool stderr suppressed by default; use `--verbose` to show

## Output file naming (steps 05-10)

Steps 05-10 prefix each output with `${rpi_name}_` (e.g., `barcode01_RPI_1`)
for identification outside their directory. Step 10 uses `${bname}_${rpi_name}`
in a flat dir. The IGV viewer discovers BAMs by suffix, so prefixes don't
affect discovery.

Step 11 outputs:
- `11_count/{bname}_{rpi}_gene_counts.tsv` — per-sample counts
- `11_count/gene_counts_all.tsv` — merged (gene × sample × splice pattern)
- `11_count/isoform_discovery.tsv` — pooled per barcode
- `11_count/gene_counts_normalized.tsv` — housekeeping-normalized
- `11_count/coverage/{bname}_{rpi}_{gene}.depth.tsv` — per-base
