[README](../README.md) | [Advanced](advanced.md) | [Testing](testing.md) | **Development** | [Requirements](requirements.md)

---

# Development

## UMI bin size analysis

Consensus quality depends on reads per UMI bin. Analysis on real data (*Arabidopsis* ccmC gene) shows quality plateaus at n>=3:

| Min reads per bin | Error-free consensus | Noise (/1000 bp) | Consensus reads retained |
|---|---|---|---|
| n>=1 | 48-80% | 0.5-4.4 | 4,727 |
| n>=2 | 78-80% | 0.5-0.7 | 4,727 |
| **n>=3** | **89%** | **0.22** | **3,423** |
| n>=4 | 93% | 0.13 | 2,147 |
| n>=5 | 95% | 0.11 | 1,192 |

The current default `min_bin_size=3` balances quality and yield. Generate your own bin analysis plots:

```bash
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --quality
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --quality --pattern CT,AG  # show both patterns
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --compare results_umic/ --quality  # compare methods
```

Plots include conversion-colored editing/noise panels (stacked by nucleotide conversion type), a noise pattern breakdown table, and a parameter header showing the pattern and aggregate EC/NC counts. Output goes to `{run_dir}/figures/` by default.

The [UMI analysis page](advanced.md#alignment-viewer) in the viewer (`/umi`) provides interactive cross-sample comparison of bin size distributions.

## Viewer development

The IGV viewer is a multi-page web app (`/` alignment, `/umi` UMI analysis, `/genes` gene counts). Shared CSS lives in `css/shared.css`, shared JS in `js/shared.js` (sample selector, toggle functions, chart cleanup, nav sync, dataset descriptions). Page-specific code stays inline. Follow this cycle for every change:

### Edit → Restart → Screenshot → Confirm

1. Edit the file(s)
2. Restart the viewer: `L3Rseq viewer --stop && L3Rseq viewer --dir <dir>`
3. Take Puppeteer screenshots to verify (see below)
4. Test the exact user-reported scenario end-to-end

**Never skip the screenshot step.** API responses can look correct while the page is broken.

```bash
# Puppeteer screenshot template
LD_LIBRARY_PATH="/opt/miniforge/envs/analysis/lib" node -e "
const puppeteer = require('/workspace/igv_viewer/node_modules/puppeteer');
(async () => {
  const b = await puppeteer.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await b.newPage();
  await page.setViewport({ width: 1400, height: 900 });
  await page.goto('http://localhost:8080/genes?name=runs/LibCheck', { waitUntil: 'networkidle0', timeout: 20000 });
  await new Promise(r => setTimeout(r, 3000));
  await page.screenshot({ path: '/tmp/test.png' });
  await b.close();
})();
"
```

### Common pitfalls and solutions

| Problem | Root cause | Solution |
|---------|-----------|----------|
| Browser shows old HTML | Cache | Server sends `Cache-Control: no-cache` for HTML. Always restart viewer. |
| State lost navigating between pages | sessionStorage unreliable in VS Code Simple Browser | Primary state in URL hash (`#v=table&sel=GENE`). Hash embedded in nav links. sessionStorage as backup. |
| Nav links don't carry state | Async `init()` hasn't updated links yet | Inline `<script>` in `<header>` sets links immediately from URL params. |
| `target="_blank"` doesn't work | VS Code Simple Browser | Gene names use `onclick` to update the Alignment Viewer link; no navigation. |
| Alignment viewer crashes | Empty BAMs or blocked `igv.org` fetch | BAI content check filters empty BAMs. `loadDefaultGenomes: false`. |
| Large FASTA blocks startup | `sanitizeFasta()` reads synchronously | Skip >10MB files. |
| `samtools \| awk` fails with pipefail | samtools non-zero for missing chromosomes | `{ samtools ... \|\| true; } \| awk` |

### Cross-page state architecture

All three pages share dataset via `?name=`. The genes page additionally stores view state in URL hash:

- `#v=table` — view mode
- `&sel=GENE` — selected gene for alignment viewer
- `&g=GENE` — gene filter, `&hk=GENE` — housekeeping, `&iso=1` — isoform rows

Other pages read `sessionStorage["l3rseq_genes_hash_<name>"]` to build Gene Counts nav links with the hash. Each page calls `syncNavLinksFromUrl()` from shared.js immediately in an inline `<script>`, before async init.

**When changing shared code, test all three pages.** When changing page-specific code, test that page plus navigation to/from the other two.

### Dev overlay

All viewer pages include `js/dev-overlay.js`. Click the grey **DEV** button (bottom-right corner) to activate. When active:

- **Hover** any element → tooltip shows component name + CSS selector
- **Right-click** → copies the label to clipboard (uses `execCommand("copy")` — clipboard API is blocked in VS Code Simple Browser)
- **Left clicks work normally** — no interference with links, buttons, or charts

The overlay auto-derives labels from `id`, `data-*` attributes, class names, and parent context. No registry to maintain when adding new components.

## Maintenance

### Version management

Version is tracked in three files — **all three must match**:

| File | Field | Current (as of April 2026) |
|------|-------|---------------------------|
| `L3Rseq` line 31 | `VERSION="1.0.11"` | **outdated** |
| `CITATION.cff` line 4 | `version: "1.0.10"` | **outdated** |
| `CHANGELOG.md` line 5 | `## [1.0.12]` | latest |

These have drifted apart because updates are manual. To prevent this, use the
bump script (once created — see `scripts/bump-version.sh` below) or update all
three by hand every time.

### Release checklist

Every release should follow this sequence:

```bash
# 1. Ensure tests pass
bash tests/run_tests.sh

# 2. Update version in all three files
#    - L3Rseq:       VERSION="X.Y.Z"
#    - CITATION.cff:  version: "X.Y.Z"   AND   date-released: "YYYY-MM-DD"
#    - CHANGELOG.md:  ## [X.Y.Z] - YYYY-MM-DD  (move items from Unreleased)

# 3. Commit, tag, push
git add L3Rseq CITATION.cff CHANGELOG.md
git commit -m "Release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags    # triggers docker-publish.yml
```

A `scripts/bump-version.sh` script that automates step 2 would prevent the
version skew problem. See `docs/improvements.md` item 6 for the design.

### Running tests during development

The test suite supports several modes for fast iteration:

```bash
bash tests/run_tests.sh --quick            # Smoke test (~26s) — good for CI
bash tests/run_tests.sh --skip-preprocess  # Skip steps 01-03 (~30s)
bash tests/run_tests.sh                    # Full suite, 156 checks (~45s)
bash tests/test_shell_functions.sh         # Unit tests only (~1s)
```

**Current gap:** There is no way to run a single test group (e.g., only the
SLAM-seq tests or only the viewer API tests). The test suite uses numbered
blocks (TEST 1 through TEST 8) that are conditionally skipped by `--quick` or
`--skip-preprocess`, but individual selection is not supported. Adding a
`--test N` flag would speed up iteration when working on a specific step.

Test blocks in `tests/run_tests.sh`:

| Block | Scope | Skipped by |
|-------|-------|-----------|
| TEST 1 | Steps 01-03 (preprocess) | `--skip-preprocess` |
| TEST 1b | Filter step | `--skip-preprocess` |
| TEST 1c | Negative/error tests | never (always runs) |
| TEST 2 | Steps 04-10, CT pattern | never |
| TEST 2b | CT,AG dual pattern | `--quick` |
| TEST 3 | SLAM-seq + count-pattern | `--quick` |
| TEST 4 | Splicing + introns | `--quick` |
| TEST 5 | BLAST + walk correction | `--quick` |
| TEST 6 | IGV viewer API | `--quick` |
| TEST 7 | Plot generation | `--quick` |
| TEST 8 | Gene counting (step 11) + splice-aware counting (8f) | `--quick` |

### Test coverage gaps (as of 2026-04-04)

Comprehensive audit of code paths with zero test coverage.

**High impact — functional code never exercised:**

| # | Feature | Risk |
|---|---------|------|
| 1 | `--method umic-seq` with actual data | Entirely different UMI pipeline (`UMIC-seq` conda env). Only the missing-`--probe` error path is tested (Test 1c). |
| 2 | `--no-target-fwd` | Changes step 06 extraction to skip forward primer. Never invoked in any test. |
| 3 | `regions --gff` / `--discover-from` / `--append` | Major real-world features for gene counting. Only `--coordinates` and `--bed` are tested (Test 8). |
| 4 | `count --min-mapq` | MAPQ filtering for homologue families. Always defaults to 0 in tests. |
| 5 | Multi-gene counting (step 11) | Main pipeline test has 1 gene (`test_gene`). Test 8f adds splice-aware counting with 3 regions (exon1/intron/exon2) on the splice dataset. Real-world multi-gene with overlapping regions and cross-gene isoform discovery remain untested. |
| 6 | Multi-chromosome references | All tests use single-contig `test_gene.fasta`. Multi-chromosome FAI reference matching in the viewer and step 07 is untested. |
| 7 | `validate_introns()` | Input validation function (L3Rseq:120-163) for BED format, `start >= end`, bad extensions, empty files — never called in tests. |
| 8 | `--prefilter` inside `L3Rseq run` | Standalone `filter` is tested (Test 1b), but the `--prefilter` flag that runs it as part of `run` is never invoked. |

**Medium impact — standalone subcommand routing:**

All 10 standalone subcommands (`concat`, `trim`, `demux`, `umi`, `consensus`,
`extract`, `map`, `variants`, `correct`, `export`) are only tested via
`L3Rseq run`. Their standalone entry points (argument parsing, input
validation) are never exercised with actual data. Dispatcher `--help` tests
also miss 5 subcommands: `filter`, `umi`, `consensus`, `extract`,
`discover-introns`, `viewer`.

**Low impact — edge cases and defensive paths:**

| Feature | Notes |
|---------|-------|
| `--start-at > --stop-at` | Silent no-op, no validation or error |
| `--verbose` | Alters stderr routing only |
| Empty FASTQ / malformed BAM input | No defensive tests |
| Invalid `--pattern` values (e.g., "XY") | Passes through unchecked to LoFreq/step 09 |
| `--prefix`, `--target-fwd/rev`, `--var` overrides | Always use defaults in tests |
| DS:i: tag in SAM/CSV output | Never explicitly validated |
| Combined SLAM + splice + BLAST in one run | Each tested in isolation, never combined |
| Step 09 with `--introns` but zero spliced reads | Splice test always includes spliced reads |
| Step 10 TL column value validation | Column exists but values not checked in CSV |

### Linting

Shell scripts are not currently linted. Adding shellcheck would catch common
bugs (unquoted variables, incorrect test operators, unreachable code).

```bash
# Manual shellcheck run (shellcheck must be installed)
shellcheck -x L3Rseq scripts/*.sh longread_umi_L3Rseq/scripts/*.sh
```

Known: `scripts/04_umi.sh` line 166 has one intentional `# shellcheck disable=SC2086`
for unquoted expansion. Other scripts have not been audited with shellcheck.

### Dispatcher test coverage

The `L3Rseq` dispatcher (argument parsing, subcommand routing, `--help` output)
is only tested for `--help` and `--version` (in `tests/test_docker_image.sh`
lines 89-92, Docker-only). There are no tests for:

- Unknown subcommand error messages
- Invalid argument combinations (e.g., `--ref` without a file)
- `--start-at` / `--stop-at` range validation
- Help text for individual subcommands (`L3Rseq map --help`)

Adding dispatcher tests to `tests/run_tests.sh` (or a new
`tests/test_dispatcher.sh`) would catch argument parsing regressions.

## Known issues (as of 2026-04-04)

Tracked here so they are fixed in priority order. Each entry notes the
commit that introduced it (if known) and the file + line to patch.

### Pipeline logic

| # | Severity | File : Line | Description |
|---|----------|-------------|-------------|
| P1 | Medium | `scripts/11_count.sh:96` | **Coverage depth ignores `--min-mapq`.** `samtools depth` is called without `-Q`, so low-MAPQ reads inflate coverage plots even when `--min-mapq` filters them from gene counts. Fix: pass `min_mapq` to `generate_coverage` and add `-Q "$min_mapq"`. |
| P2 | Low | `L3Rseq:937` | **Step 07 intermediate cleanup is a no-op.** After commit `53b478e` renamed outputs to include the RPI prefix, `rm -f aligned.sam aligned.bam` no longer matches `${rpi_name}_aligned.sam`. Intermediates are never cleaned. Fix: `rm -f "$_rpi_dir"/*_aligned.sam "$_rpi_dir"/*_aligned.bam`. |
| P3 | Low | `scripts/11_count.sh:148` | **Fallback BAM discovery uses old naming.** Globs for `*/primary.sort.bam` but post-rename files are `*_primary.sort.bam`. Only affects the edge case of passing a non-standard directory to `L3Rseq count`. Fix: `*/*_primary.sort.bam`. |

### Test suite

All items fixed in commit `5820e8f`.

| # | Status | Description |
|---|--------|-------------|
| T1 | **Fixed** | Variant check now sample-aware — RPI_1 asserts non-empty, RPI_2 accepts empty. |
| T2 | **Fixed** | `check_range` floors lower bound at 1 when expected > 0. |
| T3 | **Fixed** | Three `grep -c` calls guarded with `\|\| true`. |
| T4 | **Fixed** | Test 1b split into own `should_run 1b` block. |
| T5 | **Fixed** | `OUT` set as default before test blocks; `--test` without value errors. |
| T6 | **Fixed** | Row count uses `tail -n +2 \| wc -l` instead of `grep -cv '^gene'`. |

### Documentation

| # | File | Description |
|---|------|-------------|
| D1 | `.devcontainer/claude-code/CLAUDE.md:139` | Says "Step 09 uses `set +e` (not pipefail)" but since commit `e93b94c` the file uses `set -euo pipefail` with `set +e` only inside the per-read worker function. |

## Build the Docker image from source

For developers who want to modify the pipeline or Dockerfile. If you use VS Code, clone the repo and select **Reopen in Container** > **L3Rseq Pipeline (build)** — this builds the image and drops you into a ready-to-edit environment. Otherwise, build manually:

```bash
git clone https://github.com/akihitomamiya-del/L3R-seq.git
cd L3R-seq
docker build -f .devcontainer/build/Dockerfile -t l3rseq .
```

On Apple Silicon Macs, this builds a native arm64 image. Docker Desktop for Mac uses a Linux VM, so expect slower I/O on bind-mounted volumes compared to native Linux. Use VirtioFS (the default file sharing backend in Docker Desktop settings) for best performance.

## Docker image publishing

The base image is `ghcr.io/akihitomamiya-del/l3rseq`. CI publishes it when a version tag is pushed:

```bash
git tag v1.0.XX
git push origin v1.0.XX   # triggers .github/workflows/docker-publish.yml
```

The workflow builds for both amd64 and arm64, then creates a multi-arch manifest tagged as both `:v1.0.XX` and `:latest`.

## Claude Code (AI-assisted development)

For running and customizing the pipeline with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Claude can execute the pipeline for you, explain results, and help you adapt the code to your own gene and organism — useful if you're less comfortable with shell scripting. If you want to modify the pipeline itself, fork the repo first so Claude can commit and push changes to your copy. This devcontainer extends the pre-built L3Rseq image with the Claude CLI, a network firewall (for safe `--dangerously-skip-permissions` use), and developer tooling (zsh, git-delta, fzf).

1. Fork this repo (if you plan to make changes), then clone your fork
2. Set your API key as an environment variable on your host: `export ANTHROPIC_API_KEY=sk-ant-...`
3. Open the repo in VS Code
4. Select **Reopen in Container** > **Claude Code Sandbox**
5. Run `claude` in the terminal to start an AI-assisted session

The firewall restricts outbound network access to GitHub, Anthropic API, npm, and VS Code services only. The devcontainer setup is based on Anthropic's [Claude Code DevContainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

---

[README](../README.md) | [Advanced](advanced.md) | [Testing](testing.md) | **Development** | [Requirements](requirements.md)
