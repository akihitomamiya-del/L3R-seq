# L3Rseq — Claude Code Guidelines

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
  Example: `conda activate NanoporeMap && samtools view ...`
  The `L3Rseq` dispatcher handles env activation automatically for pipeline runs.
- **The IGV viewer auto-starts** on port 8080 via `postStartCommand`. Use
  `L3Rseq viewer --stop` / `L3Rseq viewer --dir <dir>` to restart with a
  different directory. No need to start it manually.
- **Puppeteer + Chrome** is available for headless screenshots of the viewer
  (e.g., `node igv_viewer/screenshot.js`). Use `--no-sandbox` flag when
  launching Puppeteer directly.

## Docker image publishing

The base image is `ghcr.io/akihitomamiya-del/l3rseq`. CI publishes it on
version tags:

```bash
git tag v1.0.XX && git push origin v1.0.XX   # triggers .github/workflows/docker-publish.yml
```

After CI finishes, rebuild the devcontainer to pick up the new base image.
The project `/workspace/CLAUDE.md` is gitignored. The committed copy is
`.devcontainer/claude-code/CLAUDE.md` (copied to `~/.claude/CLAUDE.md` on
container creation).

## Common gotchas

- **Inverted `.gitignore`**: The repo ignores everything (`*`) and allowlists
  specific paths. New files won't be staged by `git add` unless their path is
  in `.gitignore` with a `!` prefix. `/workspace/CLAUDE.md` is intentionally
  gitignored — never commit it. The tracked copy is `.devcontainer/claude-code/CLAUDE.md`.
- **Viewer restart**: Changes to `umi.html` or `index.html` take effect on
  browser refresh. Changes to `server.js` or `config.js` require
  `L3Rseq viewer --stop && L3Rseq viewer --dir <dir>`.
- **Test flags**: Always use `--no-viewer` when running tests if the viewer is
  already running (avoids port conflicts). Use `--quick` for fast iteration.
- **Step 09 error handling**: `09_tail_correct.sh` uses `set +e` (not pipefail)
  due to complex control flow. Other scripts use `set -euo pipefail`.
- **Real data test**: Always `rm -rf runs/LibCheck` before re-running
  `runs/LibCheck_sample.sh` — leftover `03_demux_all/` breaks RPI filtering.

## Project overview

L3Rseq is a long-read UMI sequencing pipeline for Oxford Nanopore data. The main
entry point is the `L3Rseq` script (bash), which dispatches subcommands: `run`,
`concat`, `viewer`, etc. Pipeline steps live in `scripts/01_concat.sh` through
`scripts/10_export_csv.sh`. UMI-specific logic is in `longread_umi_L3Rseq/scripts/`.

Analyzes RNA editing, splicing, 3' end cleavage, poly(A) tails on single molecules using nanopore long reads.

## Key Tools
- longread-umi (adapted) for UMI consensus generation
- UMIC-seq for UMI clustering
- Custom SAM tag-based IGV visualization
- BLAST for sequence identification

## Running tests

### Synthetic test suite (primary)

```bash
bash tests/run_tests.sh                    # Full suite (140 checks, ~42s)
bash tests/run_tests.sh --skip-preprocess  # Steps 04-10 only (~30s)
bash tests/run_tests.sh --quick            # Smoke test (~15s, for CI)
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

## IGV viewer

```bash
L3Rseq viewer --dir <output_dir>            # Start on port 8080
L3Rseq viewer --stop                        # Stop
```

The viewer auto-starts after `tests/run_tests.sh` unless `--no-viewer` is passed.
In Codespaces/remote, check the Ports tab to open in browser.

Two pages:
- `/` — Alignment viewer (IGV.js BAM tracks for steps 07/09)
- `/umi` — UMI analysis (Chart.js histograms for step 04 bin sizes)

Both share the same dataset dropdown and link to each other in the header.
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

## Key directories

- `L3Rseq` — main entry point (bash script, not a directory)
- `scripts/` — pipeline step scripts (01-10)
- `longread_umi_L3Rseq/scripts/` — UMI binning and consensus scripts
- `igv_viewer/` — Node.js viewer (IGV.js alignment viewer + Chart.js UMI analysis)
- `tests/` — test suite, test data, generators, expected output
- `tests/data/` — synthetic test datasets
- `resources/` — reference FASTAs, RPI barcodes, BLAST DBs
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
