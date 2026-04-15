# L3Rseq — Claude Code Guidelines

## Memory

Actively use the memory system (`~/.claude/projects/-workspace/memory/`).
Save user preferences, feedback corrections, and project context as they
come up — don't wait to be asked. When you encounter a non-obvious bug or
environment issue and find the fix, save it to memory so the same problem
is never debugged twice. Personal details stay in memory files (not
committed); only behavioral instructions belong in this CLAUDE.md.

## Proactive workflow tips

When the situation fits, suggest these features the user may not know about:

- **`/loop`** — when debugging iteratively, suggest `/loop 2m bash tests/run_tests.sh --quick`
  to auto-run tests in the background while editing
- **Plan mode** (`/plan`) — suggest before complex multi-step changes (new pipeline
  steps, major viewer refactors) to align on approach before writing code
- **Custom slash commands** — if a workflow is being repeated manually, suggest
  creating a `.claude/commands/` shortcut for it
- **Hooks** — if the user keeps forgetting a step (e.g., testing all 3 viewer pages),
  suggest a hook to automate the reminder
- **Parallel subagents** — when debugging independent issues, suggest spawning
  parallel agents instead of debugging sequentially
- **`/effort low`** for quick lookups — remind that simple searches and file reads
  don't need max effort

Don't nag — mention each tip once per session, only when genuinely relevant.

## After confirming a fix

Once a fix is verified (tests pass, manual checks succeed), **immediately
offer to commit and push** — don't wait for the user to ask. Confirmed fixes
sitting uncommitted risk being lost to container restarts or branch switches.

## Container environment

This is a **sandboxed devcontainer** with a network firewall. Key constraints:

- **No general internet access.** `apt-get install`, `pip install`, and `curl`
  to external sites will fail. Only GitHub, npm, and Anthropic APIs are allowed.
- **Conda environments are pre-built** and read-only. Do not try to create or
  modify them. Pipeline tools are NOT on the default PATH — you must activate
  the correct env before running them:
  - `longread_umi` — samtools, minimap2, bwa, racon, cutadapt, vsearch, parallel
  - `cutadaptenv` — cutadapt (steps 03, 06)
  - `NanoporeMap` — minimap2, samtools, bcftools (steps 07, and demo data)
  - `LoFreq` — lofreq, bcftools (step 08)
  - `UMIC-seq` — python3, biopython, scikit-bio (alternative UMI method)
  - `Entrez` — efetch, esearch (fetching NCBI references)
  - `analysis` — matplotlib, numpy (plotting scripts)
  - `l3rseq_py` — python3, pysam, biopython, pyranges, snakemake, pandas, scipy, pytest, ruff, mypy (Python algorithmic core for step 09 + dev tooling)
  Example: `conda activate NanoporeMap && samtools view ...`
  The `L3Rseq` dispatcher handles env activation automatically for pipeline runs.
- **The IGV viewer auto-starts** on port 8080 via `postStartCommand`. Use
  `L3Rseq viewer --stop` / `L3Rseq viewer --dir <dir>` to restart with a
  different directory. No need to start it manually.
- **Puppeteer + Chrome** is available for headless screenshots of the viewer
  (e.g., `node igv_viewer/screenshot.js`). Use `--no-sandbox` flag when
  launching Puppeteer directly.
- **Claude Code authentication.** Two methods work out of the box:
  1. **Browser login (default for new users)** — inside the container, run
     `claude /login`, pick Claude Pro/Max, authorize in browser, paste the
     code back. Credentials persist in the `~/.claude` Docker volume across
     rebuilds. Zero host-side config.
  2. **Host-injected token (automation / Codespaces)** — set
     `CLAUDE_CODE_OAUTH_TOKEN` on the host; `remoteEnv` in `devcontainer.json`
     injects it into every VS Code remote session. Takes precedence over the
     credentials file when set.
  Both methods coexist — if the env var is set it wins, otherwise the CLI
  falls back to the credentials file, otherwise it prompts for login. Verify
  whichever you use: `claude -p "say pong"`. Full setup and troubleshooting:
  `docs/auth.md`.

## Devcontainer configurations

Three configs live under `.devcontainer/`:

| Directory | Name | Notes |
|---|---|---|
| `devcontainer.json` (root) | L3Rseq Pipeline | **Default for Codespaces.** Uses pre-built ghcr image. No Claude Code CLI. |
| `claude-code/` | L3Rseq Pipeline (Claude Code Sandbox) | Builds from Dockerfile. Adds Claude CLI, firewall, dev tooling. Auth: browser login (default) or `CLAUDE_CODE_OAUTH_TOKEN` via `remoteEnv`. |
| `build/` | L3Rseq Pipeline (build) | Builds from Dockerfile. For testing local image changes |

## Docker image publishing

The base image is `ghcr.io/akihitomamiya-del/l3rseq`. CI publishes it on
version tags:

```bash
git tag v1.0.XX && git push origin v1.0.XX   # triggers .github/workflows/docker-publish.yml
```

After CI finishes, rebuild the devcontainer to pick up the new base image.

### CLAUDE.md copies (keep in sync)

There are three copies of this file — update all three when making changes:
1. `.devcontainer/claude-code/CLAUDE.md` — **committed** (template, copied on container create)
2. `~/.claude/CLAUDE.md` — **active** (what Claude reads; on a Docker volume)
3. `/workspace/CLAUDE.md` — **gitignored** (project-level; may have extra local notes)

Quick sync: `cp .devcontainer/claude-code/CLAUDE.md ~/.claude/CLAUDE.md`

## Before starting work

- **Always fetch and pull the latest commits** on `main` before starting any task:
  `git fetch --all && git pull`. Upstream fixes may already address the issue.

## Common gotchas

- **Inverted `.gitignore`**: The repo ignores everything (`*`) and allowlists
  specific paths. New files won't be staged by `git add` unless their path is
  in `.gitignore` with a `!` prefix. `/workspace/CLAUDE.md` is intentionally
  gitignored — never commit it. The tracked copy is `.devcontainer/claude-code/CLAUDE.md`.
- **Viewer development — strict cycle**: Every viewer change must follow:
  1. **Edit** the file(s) — apply fixes to ALL 3 pages (index/umi/genes) when relevant
  2. **Restart** the viewer: `L3Rseq viewer --stop && L3Rseq viewer --dir <dir>`
  3. **Screenshot-verify** with Puppeteer (`LD_LIBRARY_PATH="/opt/miniforge/envs/analysis/lib"`)
  4. **Test the exact user scenario** end-to-end (click buttons, navigate pages, come back)
  5. **Read the screenshots** and confirm the UI is correct before telling the user
  Never rely solely on API responses or JS state — screenshots are the only
  reliable way to catch caching, layout, and navigation bugs.
- **Viewer — IGV.js uses Shadow DOM**: Since IGV.js v3 renders inside a Shadow
  Root, external CSS cannot style IGV internals (navbar, tracks, etc.). To
  inspect or style them, access `browser.root.getRootNode()` in JS after
  `igv.createBrowser()`. Puppeteer headless mode can read the Shadow DOM state
  (e.g. `window.browser.trackViews.length`) but does NOT render IGV canvases
  visually — track areas appear blank in headless screenshots. Use DOM/JS
  assertions (like `test_buttons.js`) for automated checks, and ask the user
  to verify visual rendering in their real browser when canvas output matters.
  Puppeteer screenshots are still useful for verifying layout, sticky headers,
  z-index layering, and non-canvas UI elements.
- **Viewer — primary usage pattern (test this!)**: The core workflow is
  gene-centric back-and-forth between the gene counts and alignment pages:
  1. On Gene Counts page: find a gene of interest in the barplot, click it
  2. Click "Alignment Viewer" to jump to that gene's locus with tracks loaded
  3. Inspect read quality/mapping at that locus — toggle barcode groups on/off
  4. Navigate back to Gene Counts → select another gene → return to alignment
  5. Optionally zoom into the barplot to see per-sample counts for that gene
  Every viewer change MUST be tested against this flow. Verify: locus is
  preserved when toggling tracks, controls bar stays visible when deselecting
  all tracks, navigation between pages preserves dataset and state.
- **Viewer — shared code architecture**: Common CSS lives in `css/shared.css`,
  common JS in `js/shared.js` (sample selector, toggles, chart cleanup, nav
  sync, `initDatasetPage()`). Page-specific JS lives in separate files:
  `js/alignment.js`, `js/umi.js`, `js/genes.js`. HTML files are slim shells
  (no inline JS). Server domain logic is in `lib/` modules (`bam.js`,
  `discovery.js`, `pipeline-stats.js`, `fasta.js`, `helpers.js`); `server.js`
  is a thin HTTP adapter. When adding a feature that applies to multiple
  pages, add it to the shared files — not copy-pasted into each page JS.
  The alignment page has its own track/IGV logic and does not use the shared
  sample selector or `initDatasetPage()`.
- **Viewer — dev overlay**: Click the grey "DEV" button (bottom-right) to
  toggle. Hover shows component name + CSS selector. Right-click copies the
  label to clipboard. Uses `document.execCommand("copy")` because VS Code
  Simple Browser blocks the clipboard API. The overlay never modifies element
  styles and never intercepts left clicks.
- **Viewer — state architecture**: Pages share dataset via `?name=` URL param.
  The genes page stores view state in URL hash (`#v=table&sel=GENE&g=FILTER`).
  Nav links are set by `syncNavLinksFromUrl()` (immediate, from shared.js)
  and by `syncNavLinks()` (after dataset loads). Immediate sync is critical
  for the alignment page which is slow to initialize (30+ BAM tracks).
  URL hash is the primary state channel; sessionStorage is backup for sample
  selections. Gene clicks update the header link instead of navigating away
  (`target="_blank"` doesn't work in VS Code Simple Browser).
- **Viewer — known fixes baked in**: `Cache-Control: no-cache` on HTML files;
  `loadDefaultGenomes: false` in IGV.js config; BAI content inspection for
  empty BAM filtering; skip `sanitizeFasta` for >10MB files; `{ samtools ... || true; }`
  pipes to prevent pipefail crashes on missing chromosomes; hidden tracks start
  unchecked in `buildTrackToggles`; multi-chromosome reference matching via FAI.
- **Test flags**: Do not add `--no-viewer` by default — the test suite handles
  viewer restart automatically. Use `--quick` for fast iteration.
- **Step 09 error handling**: `09_tail_correct.sh` uses `set -euo pipefail` at
  file level, but the per-read worker `_process_one_read()` starts with `set +e`
  to tolerate arithmetic and grep exit codes. Validation guards (`_require_int`,
  `_require_str`) check `RESULT_*` variables after each subscript call — if a
  subscript fails silently under `set +e`, the guard writes `FAILED` status and
  skips the read with a `BUG:` warning. Other scripts use `set -euo pipefail`.
- **Known issues**: See `docs/development.md` § "Known issues" for tracked bugs
  in the pipeline (coverage ignoring min-mapq, stale file globs after rename) and
  test suite (variant check too lenient, grep -c unguarded, --test flag gaps).
  Consult that section before working on steps 07-11 or the test suite.
- **Real data test**: Always `rm -rf runs/LibCheck` before re-running
  `runs/LibCheck_sample.sh` — leftover `03_demux_all/` breaks RPI filtering.

## Pipeline modernization habits

The bash → Python modernization arc (Phases 0–4) is complete. Step 09 and
step 11 run from `src/l3rseq/` under the `l3rseq_py` env, the Snakefile wraps
all 11 steps, and `config.yaml` is the single source of truth for pipeline
defaults. See `docs/PIPELINE_MODERNIZATION.md` for history and the current
phase status. The habits below are permanent — they apply to any new work
touching the Python modules, config, or the dispatcher.

- **Pre-commit check trio for Python changes.** Before committing anything
  under `src/l3rseq/` or `tests/python/`, run all three:
  ```bash
  /opt/miniforge/envs/l3rseq_py/bin/ruff check src/ tests/python/
  /opt/miniforge/envs/l3rseq_py/bin/mypy src/l3rseq/
  /opt/miniforge/envs/l3rseq_py/bin/pytest tests/python/ -v
  ```
  (or `conda activate l3rseq_py` once and drop the prefix). CI runs the same
  three commands in the `python-test` job — running them locally first
  prevents push-then-fix loops. Mypy is configured `strict = true`, so
  missing type hints and `Any` leaks will fail.

- **Algorithm modules stay pure.** `src/l3rseq/cigar.py`, `walk.py`,
  `variants.py`, `splice.py`, and `tags.py` must **never** `import pysam`,
  never touch the filesystem, and never spawn subprocesses. They are
  pure-Python + stdlib only. The orchestrators (`tail_correct.py`,
  `count.py`), the BLAST wrapper (`blast.py`), and the config loader
  (`config.py`) are the ONLY places that touch pysam, I/O, or `subprocess`.
  This keeps the algorithm tests runnable in isolation and makes future
  refactors cheaper.

- **Config is centralized in `config.yaml`.** `config.sh` holds only conda
  env names and `$(nproc)`-derived thread defaults. All step parameters
  (adapters, thresholds, patterns, ...) live in `config.yaml`. Dispatcher
  precedence is CLI flag > YAML (via `--config-file`) > `_fallback_defaults()`
  bash block in `scripts/load_config.sh`. When adding or changing a
  parameter:
  1. Edit `config.yaml`.
  2. Edit the matching bash line in `scripts/load_config.sh::_fallback_defaults`.
  3. If it's a new key, extend `YAML_TO_BASH` in `src/l3rseq/config.py`.
  4. Run `PYTHONPATH=src python3 scripts/check_config_sync.py` locally.
  CI fails the PR if any of those steps is missed.

- **Dockerfile changes require a tagged release — no runtime installs.**
  The devcontainer firewall blocks PyPI, conda-forge, and bioconda at
  runtime (`curl https://pypi.org → exit 7`). To add a Python package, edit
  `.devcontainer/build/Dockerfile`, commit, then:
  ```bash
  git tag v1.X.Y && git push origin v1.X.Y
  # wait ~20 min for docker-publish.yml to finish (gh run watch)
  # then: Dev Containers: Rebuild Container
  ```
  There is no `pip install -e .` shortcut; `src/l3rseq/` is discovered via
  the `pythonpath = ["src"]` setting in `pyproject.toml`'s
  `[tool.pytest.ini_options]` and via `PYTHONPATH=src` for the module
  entry point.

- **Port shell test cases verbatim when rewriting a bash script.** If any
  future port replaces a bash step with Python, every corresponding case in
  `tests/test_shell_functions.sh` MUST be ported to pytest with the same
  inputs, expected outputs, and edge cases — see `tests/python/test_cigar.py`
  (mirrors `test_shell_functions.sh:44-80`) and `tests/python/test_splice.py`
  (mirrors `:88-216`) for the pattern.

- **Differential test before switching the dispatcher to Python.** Before
  changing any `cmd_*` in the `L3Rseq` dispatcher to call Python instead of
  bash, prove byte-identical SAM/BAM output on the full quick-test fixtures.
  "Byte-identical" = `samtools view` | sort | `diff` on the output BAMs.
  Any deviation must be documented in the commit message with a
  justification. See `tests/benchmarks/diff_step09.sh` and `diff_step11.sh`
  for the pattern.

- **Benchmark with `date +%s.%N`, not bash `SECONDS`.** The integer
  `SECONDS` builtin rounds to whole seconds, which rounds away real signal
  on sub-10-second runs (a 3.5s run and a 4.3s run both show as "4s"). See
  `tests/benchmarks/bench_step09.sh` for the correct sub-second timing
  pattern and the multi-iteration min/median/mean reporting.

## Project overview

L3Rseq is a long-read UMI sequencing pipeline for Oxford Nanopore data. The main
entry point is the `L3Rseq` script (bash), which dispatches subcommands: `run`,
`concat`, `regions`, `count`, `viewer`, etc. Pipeline steps live in `scripts/01_concat.sh`
through `scripts/11_count.sh`. UMI-specific logic is in `longread_umi_L3Rseq/scripts/`.

Analyzes RNA editing, splicing, 3' end cleavage, poly(A) tails on single molecules using nanopore long reads.

## Key Tools
- longread-umi (adapted) for UMI consensus generation
- UMIC-seq for UMI clustering
- Custom SAM tag-based IGV visualization
- BLAST for sequence identification

## Running tests

### Synthetic test suite (primary)

```bash
bash tests/run_tests.sh                    # Full suite (156 checks, ~45s)
bash tests/run_tests.sh --skip-preprocess  # Steps 04-10 only (~30s)
bash tests/run_tests.sh --quick            # Smoke test (~26s, for CI)
bash tests/run_tests.sh --no-viewer        # Skip IGV viewer auto-start after tests
```

Tests are fully deterministic — identical results across runs on the same container.
Output goes to `tests/output/`. Expected values are in `tests/expected/`.

### Docker image tests (host only — do NOT run inside the container)

```bash
bash tests/test_docker_image.sh                        # Build + test
bash tests/test_docker_image.sh --skip-build           # Test existing image
```

These require Docker on the host machine. They build/pull the image and run
the test suite inside a fresh container. Not applicable in devcontainer sessions.

### Shell function unit tests (standalone)

```bash
bash tests/test_shell_functions.sh          # CIGAR, splice, BLAST helpers
```

### Python algorithm tests (l3rseq_py env)

```bash
conda activate l3rseq_py
pytest tests/python/ -v --cov=src/l3rseq --cov-report=term-missing
ruff check src/ tests/python/
mypy src/l3rseq/
```

The Python modules under `src/l3rseq/` (cigar, walk, variants, splice) are
the algorithmic core of step 09's tail correction. They mirror the bash
subscripts in `scripts/09a-09f_*.sh` and have unit tests under `tests/python/`.

All three checks (`ruff`, `mypy`, `pytest`) must pass before committing
anything under `src/l3rseq/` or `tests/python/`. CI runs the same three
commands in the `python-test` job; running them locally first is the
difference between a clean PR and a push-then-fix loop.

### Viewer tests

```bash
cd igv_viewer && npm test                   # Puppeteer DOM tests (46 checks, synthetic data)
cd igv_viewer && npm run test:stress        # Stress tests (real data, auto-discovers)
node igv_viewer/test_stress.js runs/LibCheck  # Explicit dataset
```

The stress tests (`test_stress.js`) auto-discover the largest dataset from the
running viewer server and exercise scale-dependent behaviors: track cap (>8
tracks), barcode group toggling, all view modes, gene click → alignment
round-trip, and cross-page state preservation. They gracefully skip if no real
data is available (exit 0). Run them after any viewer change that touches
shared code, navigation, or sample selectors.

**Slash command**: Type `/stress-test` in Claude Code to run the full stress
test cycle (restart viewer + automated tests + screenshots + report).

### Viewer API stress test (curl-based, no browser needed)

Run after any viewer or server change to catch regressions without Puppeteer:

```bash
# All pages serve with shared.css
for p in "/" "/umi" "/genes"; do curl -sf "http://localhost:8080${p}" | grep -q shared.css && echo "$p OK"; done

# APIs return valid JSON for all datasets
for ds in demo pipeline_blast pipeline_splice pipeline_SLAM pipeline pipeline_dual; do
  curl -sf "http://localhost:8080/api/tracks?name=tests/output/$ds" | python3 -c "import sys,json; json.load(sys.stdin)" && echo "$ds tracks OK"
done

# Error handling: bad inputs return 400/404, not 500
curl -s -o /dev/null -w "%{http_code}" 'http://localhost:8080/api/tracks?name=DOESNOTEXIST'  # expect 404
curl -s -o /dev/null -w "%{http_code}" 'http://localhost:8080/api/tracks?name='               # expect 400

# Byte-range BAM requests (critical for IGV.js)
curl -s -I -H "Range: bytes=0-100" "http://localhost:8080/data/tests/output/pipeline/09_correct/barcode01/barcode01_RPI_1/barcode01_RPI_1_corrected.sort.bam" | grep "206 Partial"

# JS/CSS no-cache headers (edits take effect on reload)
curl -s -I http://localhost:8080/js/shared.js | grep "no-cache"
curl -s -I http://localhost:8080/css/shared.css | grep "no-cache"
```

## IGV viewer

```bash
L3Rseq viewer --dir <output_dir>            # Start on port 8080
L3Rseq viewer --stop                        # Stop
```

The viewer auto-starts after `tests/run_tests.sh` unless `--no-viewer` is passed.
In Codespaces/remote, check the Ports tab to open in browser.

Three pages:
- `/` — Alignment viewer (IGV.js BAM tracks for steps 07/09)
- `/umi` — UMI analysis (Chart.js histograms for step 04 bin sizes)
- `/genes` — Gene counts (qPCR-style molecule counting from step 11)

All pages share the same dataset dropdown and link to each other in the header.
Dataset selection is preserved across navigation via `?name=` URL parameter.

### UMI analysis page (`/umi`)

Compares UMI bin size distributions across samples from step 04 output.
API endpoint: `/api/umi-stats?name=<dataset>` (reads TSV files from
`04_umi/{barcode}/{rpi}/read_binning/`).

Three view modes:
- **Overlay** — cumulative curve + histogram, all selected samples on one chart
- **Grid** — small multiples, one histogram per sample
- **Table** — sortable summary metrics (total reads, kept bins, yield %, etc.)

Samples are colored by barcode family. Singletons hidden by default (toggle to show).

### Gene counts page (`/genes`)

qPCR-style molecule counting from `L3Rseq count` output. Since each UMI-consensus
read represents a single original RNA molecule, counting reads per gene gives
accurate molecule counts analogous to qPCR — with the added benefit of per-isoform
resolution from splice patterns.

Four view modes:
- **Table** — sortable counts with heatmap shading; toggle per-isoform rows
- **Chart** — grouped bar chart of counts/ratios across samples
- **Isoforms** — stacked bar showing splice-pattern composition per sample
- **Coverage** — per-base read depth line chart

Controls: housekeeping gene selector (for normalization), gene filter, sample checkboxes.
API endpoints: `/api/gene-counts?name=<dataset>`, `/api/gene-coverage?name=<dataset>&gene=<gene>&sample=<sample>`.

## Gene-level counting (qPCR-style)

Standalone post-analysis subcommands for molecule quantification. Not part of
`L3Rseq run` — run after the main pipeline completes.

```bash
# Auto-discover gene regions from BAMs + GFF (recommended)
L3Rseq regions --gff annotation.gff3 --discover-from out/ --output regions.tsv --min-reads 5

# Or define manually (GFF, BED, coordinates, --append to build incrementally)
L3Rseq regions --gff annotation.gff3 --output regions.tsv
L3Rseq regions --coordinates "gene1:chr:start-end" --output regions.tsv
L3Rseq regions --bed genes.bed --output regions.tsv --append

# Count molecules per gene from step 07 BAMs
L3Rseq count --input out/ --outdir out/ --regions regions.tsv
L3Rseq count ... --housekeeping GENE_NAME    # normalize against housekeeping gene
L3Rseq count ... --min-frac 0.95             # overlap threshold (default)
L3Rseq count ... --min-mapq 20               # filter multi-mappers (homologue families)
```

Output in `11_count/`: per-sample counts, merged counts with per-isoform
breakdown, pooled isoform discovery (per barcode), housekeeping normalization,
and per-base coverage depth files.

**Splice-aware counting**: Gene counting prefers `09_correct/` BAMs (where
intron D→N conversion has been applied) over `07_map/` BAMs, falling back
to `07_map` if step 09 wasn't run. The CIGAR overlap calculation excludes
`N` (intron skip) operations, so spliced reads don't count toward intron
regions they skip over. Regions TSV files may include a header line
(`gene\tchr\tstart\tend\t...`) which is automatically skipped.

**Strand note**: Gene counting is strand-agnostic (counts all primary alignments).
Step 09 CIGAR-walk correction assumes reads map to + strand (3' tail = right clip).
For genome-wide mapping, minus-strand genes need left-clip correction instead —
not yet implemented. Use per-gene references for 3' tail analysis.

## Key directories

- `L3Rseq` — main entry point (bash script, not a directory)
- `scripts/` — pipeline step scripts (01-10) + regions.sh, 11_count.sh
- `longread_umi_L3Rseq/scripts/` — UMI binning and consensus scripts
- `igv_viewer/` — Node.js viewer (IGV.js alignment + Chart.js UMI analysis + gene counts)
- `tests/` — test suite, test data, generators, expected output
- `tests/data/` — synthetic test datasets
- `resources/` — reference FASTAs, RPI barcodes, BLAST DBs
- `docs/` — detailed docs: [adaptation](../docs/adaptation.md), [testing](../docs/testing.md), [development](../docs/development.md), [requirements](../docs/requirements.md)
- `runs/` — pipeline output directories (gitignored)

## Coding conventions

- Shell scripts use `set -euo pipefail`
- Pipeline progress messages use `[Step NN]` and `[script_name]` prefixes
- Log files are auto-generated as `l3rseq_YYYYMMDD_HHMMSS.log` in the output dir
- Tool stderr (minimap2, bwa, racon, usearch) is suppressed by default; use `--verbose` to show

## Output file naming (steps 05-10)

Output files in steps 05-10 include the RPI name as a prefix for identification
outside their directory context. The prefix is `${rpi_name}_` where `rpi_name` is
the sample directory name (e.g., `barcode01_RPI_1`).

Examples:
- Step 05: `consensus_barcode01_RPI_1.fa`
- Step 06: `barcode01_RPI_1_extracted_trimmed.fa`, `barcode01_RPI_1_extracted_uncut.fa`
- Step 07: `barcode01_RPI_1_aligned.sort.bam`, `barcode01_RPI_1_primary.sort.bam`, `barcode01_RPI_1_mapped_only.sam`
- Step 09: `barcode01_RPI_1_corrected.sort.bam`, `barcode01_RPI_1_chimeric_rightclip.sort.bam`
- Step 10: `barcode01_barcode01_RPI_1.csv` (flat dir, uses `${bname}_${rpi_name}`)

The IGV viewer discovers BAM files by suffix matching (e.g., files ending in
`primary.sort.bam`), so the prefix does not affect viewer discovery.

Step 11 (gene counting) outputs:
- `11_count/{bname}_{rpi}_gene_counts.tsv` — per-sample counts
- `11_count/gene_counts_all.tsv` — merged counts (gene x sample x splice pattern)
- `11_count/isoform_discovery.tsv` — pooled isoform patterns per barcode
- `11_count/gene_counts_normalized.tsv` — housekeeping-normalized ratios
- `11_count/coverage/{bname}_{rpi}_{gene}.depth.tsv` — per-base coverage
