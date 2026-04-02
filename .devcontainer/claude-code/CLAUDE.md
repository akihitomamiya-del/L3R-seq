# L3Rseq — Claude Code Guidelines

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

### Docker image tests

```bash
bash tests/test_docker_image.sh                        # Build + test
bash tests/test_docker_image.sh --skip-build           # Test existing image
```

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
