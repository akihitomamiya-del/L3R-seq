[README](../README.md) | [Adaptation](adaptation.md) | [Requirements](requirements.md) | **Code Overview** | [Development](development.md)

---

# Code Overview

This document maps the entire L3Rseq codebase: architecture, data flow,
and per-file summaries. Use it to orient yourself before diving into any
part of the code.

## Architecture diagram

```
                        ┌──────────────┐
                        │    L3Rseq    │  Main dispatcher (bash)
                        │  (run/count  │  Routes subcommands to scripts,
                        │   regions/   │  activates conda envs, logs
                        │   viewer...) │
                        └──────┬───────┘
                               │
            ┌──────────────────┼──────────────────┐
            │                  │                  │
   ┌────────▼─────────┐ ┌─────▼──────────┐ ┌─────▼───────────┐
   │  Pipeline steps  │ │  Post-analysis │ │   IGV Viewer    │
   │     (01-10)      │ │  (11 + utils)  │ │    (Node.js)    │
   └────────┬─────────┘ └─────┬──────────┘ └─────┬───────────┘
            │                  │                  │
            ▼                  ▼                  ▼
   ┌──────────────────────────────────────────────────────────┐
   │                    Output directory                      │
   │  01_concat/ 02_trim/ 03_demux/ 04_umi/ 05_consensus/    │
   │  06_extract/ 07_map/ 08_variants/ 09_correct/           │
   │  10_export_csv/ 11_count/                                │
   └──────────────────────────────────────────────────────────┘
```

## Data flow: pipeline steps

Each step reads from the previous step's output directory.

```
  Raw FASTQ (per-barcode)
       │
  ┌────▼────┐
  │01 concat│  Merge per-barcode fastq.gz → one file per barcode
  └────┬────┘
  ┌────▼────┐
  │02 trim  │  3-pass adapter trimming (cutadapt)
  └────┬────┘
  ┌────▼────┐
  │03 demux │  RPI barcode demultiplexing (cutadapt)
  └────┬────┘
  ┌────▼────┐
  │04 umi   │  UMI extraction + clustering → read bins
  └────┬────┘  (longread-umi or UMIC-seq method)
  ┌────▼────┐
  │05 consns│  Racon consensus per UMI bin → one sequence per molecule
  └────┬────┘
  ┌────▼────┐
  │06 extrac│  Extract target region with flanking primers (cutadapt)
  └────┬────┘
  ┌────▼──────────────────────────────────────────────┐
  │07 map    Map to reference (minimap2) → sorted BAM │──┐
  └────┬──────────────────────────────────────────────┘  │
       │                                                 │
  ┌────▼──────────────────────────────────────────────┐  │
  │08 varnts Variant calling (LoFreq) → VCF           │  │
  └────┬──────────────────────────────────────────────┘  │
       │                                                 │
  ┌────▼──────────────────────────────────────────────┐  │
  │09 correct  CIGAR right-clip correction:           │  │
  │            • BLAST chimera detection              │  │
  │            • Walk algorithm for clip boundaries   │  │
  │            • Splice-aware D→N conversion          │  │
  │            • Re-call variants on corrected BAM    │  │
  └────┬──────────────────────────────────────────────┘  │
  ┌────▼──────────────────────────────────────────────┐  │
  │10 export   SAM → annotated CSV + quality report   │  │
  └───────────────────────────────────────────────────┘  │
                                                         │
  ── Post-analysis (standalone) ───────────────────────  │
                                                         │
  ┌─────────┐     ┌──────────┐                           │
  │ regions │────▶│11 count  │◀──────────────────────────┘
  │(GFF/BED)│     │gene-level│  qPCR-style molecule counting
  └─────────┘     │ counting │  from step 07/09 BAMs
                  └──────────┘
```

## Layer 1: Entry point and config

### `L3Rseq` (root)
Main dispatcher script. Parses subcommands (`run`, `concat`, `trim`, `map`,
`count`, `regions`, `viewer`, etc.), activates the correct conda env for each
step, and forwards arguments to the appropriate script. Also handles logging,
`--verbose`, version display, and the `pipeline_summary.tsv` metrics file.

### `config.sh`
Centralized defaults for all pipeline parameters: adapter sequences, UMI
length (15bp), flanking sequences, thread counts (auto-detected), conda env
names, error thresholds. All values are overridable via CLI flags — this file
is not meant to be edited directly.

### `scripts/lib.sh` (40 lines)
Shared utility functions sourced by steps 05–11: `iterate_samples()` for the
nested barcode/RPI directory loop, `require_input()` for prerequisite checks,
logging helpers, and `_summary_append()` for metrics output.

## Layer 2: Pipeline steps

Steps 01–10 form the core pipeline, running sequentially from raw reads to
per-molecule CSV tables. The entire pipeline can be run at once with
`L3Rseq run`, or any contiguous range of steps with `--start-at` / `--stop-at`.
Each step is also available as a standalone subcommand.

---

### Step 01 — Concatenate (`scripts/01_concat.sh`)

Merge per-barcode `fastq.gz` files (as produced by MinKNOW/dorado) into a
single file per ONT barcode.

| | |
|---|---|
| **Input** | Directory of per-barcode `fastq.gz` files |
| **Output** | `01_concat/{barcode}.fastq.gz` |
| **Command** | `L3Rseq concat --input <dir> --outdir <dir>` |
| **Tools** | gzip, awk |

---

### Step 02 — Trim (`scripts/02_trim.sh`)

Three-pass adapter trimming using cutadapt. Removes the 3'-Adap adapter and
PCR primer sequences introduced during library preparation. A linked adapter
search filters chimeric reads where internal adapters indicate ligation
artifacts.

| | |
|---|---|
| **Input** | `01_concat/{barcode}.fastq.gz` |
| **Output** | `02_trim/{barcode}/trim3.fastq.gz` (final trimmed reads) |
| **Command** | `L3Rseq trim --input <dir> --outdir <dir>` |
| **Key options** | `--adapter-fwd`, `--adapter-rev` (override default adapter sequences) |
| **Tools** | cutadapt (3 passes, `--rc`) |

---

### Step 03 — Demultiplex (`scripts/03_demultiplex.sh`)

Demultiplex reads by RPI (Reverse Primer Index) barcodes — the sample-specific
index primers introduced during PCR. This assigns reads to individual samples
within each ONT barcode.

| | |
|---|---|
| **Input** | `02_trim/{barcode}/trim3.fastq.gz` + RPI barcode FASTA |
| **Output** | `03_demux/{barcode}/{rpi}.fastq` |
| **Command** | `L3Rseq demux --input <dir> --outdir <dir> --rpi-fasta <barcodes.fa>` |
| **Key options** | `--rpi-fasta` (required: FASTA with one entry per sample barcode, 20 nt) |
| **Tools** | cutadapt |

> **Tip:** Steps 01–03 are preprocessing. If your data is already demultiplexed
> by sample, skip them with `--start-at 4`.

---

### Step 04 — UMI clustering (`scripts/04_umi.sh`)

Locates the 15-nt UMI within each read by aligning a probe sequence to the
adapter region flanking the UMI. Reads sharing the same UMI — i.e. reads
derived from the same original RNA molecule — are grouped by hierarchical
clustering. A cluster test is first run on a subset of reads to determine the
optimal alignment score threshold, then full clustering is applied at that
threshold.

| | |
|---|---|
| **Input** | `03_demux/{barcode}/{rpi}.fastq` + probe FASTA |
| **Output** | `04_umi/{barcode}/{rpi}/UMIclusterfull_*/` (one directory per UMI cluster) |
| **Command** | `L3Rseq umi --input <dir> --outdir <dir> --probe <probe.fa>` |
| **Key options** | `--method longread-umi\|umic-seq`, `--size-thresh` (min reads per cluster, default 4), `--aln-thresh` (alignment score threshold) |
| **Tools** | minimap2, cutadapt, vsearch (UMIC-seq method); or bwa, samtools (longread-umi method) |

---

### Step 05 — Consensus (`scripts/05_consensus.sh`)

Within each UMI cluster, reads are aligned with minimap2 and polished through
four iterative rounds of Racon to produce a single high-accuracy consensus
sequence per original RNA molecule. This corrects random ONT sequencing errors
and collapses PCR duplicates, yielding per-molecule sequences suitable for
single-nucleotide variant detection.

| | |
|---|---|
| **Input** | `04_umi/{barcode}/{rpi}/UMIclusterfull_*/` |
| **Output** | `05_consensus/{barcode}/{rpi}/consensus_{rpi}.fa` |
| **Command** | `L3Rseq consensus --input <dir> --outdir <dir>` |
| **Key options** | `--rounds` (Racon polishing rounds, default 4) |
| **Tools** | minimap2, racon |

---

### Step 06 — Extract (`scripts/06_extract.sh`)

Trims the flanking primer and adapter sequences from each consensus using
cutadapt, isolating the region of biological interest. Reads that do not
match both target sequences are written to a separate file
(`extracted_uncut.fa`) and excluded from downstream analysis.

| | |
|---|---|
| **Input** | `05_consensus/{barcode}/{rpi}/consensus_{rpi}.fa` |
| **Output** | `06_extract/{barcode}/{rpi}/{rpi}_extracted_trimmed.fa` |
| **Command** | `L3Rseq extract --input <dir> --outdir <dir>` |
| **Key options** | `--target-fwd`, `--target-rev` (override target sequences), `--min-overlap` (default 52 bp) |
| **Tools** | cutadapt |

---

### Step 07 — Map (`scripts/07_map.sh`)

Aligns the extracted consensus sequences to the reference (genomic DNA)
sequence using minimap2 with the `lr:hq` preset (optimized for high-quality
long reads). Output is converted to sorted, indexed BAM. After this step,
**each alignment represents a single original RNA molecule**. The CIGAR string
encodes the matched region and any 3' sequence extending beyond the reference
as soft-clipped bases.

| | |
|---|---|
| **Input** | `06_extract/{barcode}/{rpi}/{rpi}_extracted_trimmed.fa` + reference FASTA |
| **Output** | `07_map/{barcode}/{rpi}/{rpi}_aligned.sort.bam`, `{rpi}_primary.sort.bam`, `{rpi}_mapped_only.sam` |
| **Command** | `L3Rseq map --input <dir> --outdir <dir> --ref <reference.fa>` |
| **Tools** | minimap2, samtools |

---

### Step 08 — Variants (`scripts/08_variants.sh`)

Identifies single-nucleotide variants in the mapped reads using LoFreq, a
variant caller designed for low-frequency variant detection. Variants are
filtered by the user-specified editing pattern (e.g. `CT` for C-to-U RNA
editing, `AG` for A-to-I). The detected editing positions are recorded for
use in the tail correction step.

| | |
|---|---|
| **Input** | `07_map/{barcode}/{rpi}/{rpi}_primary.sort.bam` + reference FASTA |
| **Output** | `08_variants/{barcode}/{rpi}/variants.vcf`, `observed_variants.txt` |
| **Command** | `L3Rseq variants --input <dir> --outdir <dir> --ref <reference.fa> --pattern CT` |
| **Key options** | `--pattern` (editing pattern, e.g. `CT`, `AG`, or `CT,AG` for dual), `--min-af` (min allele frequency, default 0.01) |
| **Tools** | lofreq, bcftools |

---

### Step 09 — Correct (`scripts/09_tail_correct.sh`)

Resolves the 3' soft-clipped region of each mapped read — the sequence
extending beyond the reference endpoint. The CIGAR string is parsed, and a
base-by-base "walk" comparison is performed between the clipped sequence and
the downstream reference, tolerating mismatches at known RNA editing positions.
This is necessary because edited positions near the 3' end would otherwise
appear as mismatches against the genomic reference, causing premature
assignment of the 3' boundary. Right-clipped sequences exceeding 50 bp are
searched by BLAST to detect trans-splicing or translocation events.

The corrected alignments are annotated with custom SAM tags:

| Tag | Description |
|---|---|
| `3E` | 3' end position on reference |
| `RC` | Remaining tail length after correction |
| `RS` | Remaining tail sequence |
| `TL` | Translocation flag (0 or 1) |
| `EC` | RNA editing event count |

| | |
|---|---|
| **Input** | `07_map/{barcode}/{rpi}/{rpi}_mapped_only.sam` + `08_variants/.../observed_variants.txt` + reference FASTA |
| **Output** | `09_correct/{barcode}/{rpi}/{rpi}_corrected.sort.bam` |
| **Command** | `L3Rseq correct --input <dir> --outdir <dir> --ref <reference.fa> --pattern CT` |
| **Key options** | `--var` (known editing positions file), `--clip-thresh` (BLAST threshold, default 50 bp), `--blast-db` / `--blast-db2` (organism-specific BLAST databases), `--introns` (splice-aware D→N conversion) |
| **Tools** | samtools, BLAST, lofreq |

Internally sources six subscripts:

| Subscript | Purpose |
|---|---|
| `09a_parse_cigar.sh` | Parse CIGAR into operation arrays, map read↔ref positions |
| `09b_blast_rightclip.sh` | Extract soft clips, batch BLAST against 2 databases |
| `09c_walk_correction.sh` | Walk algorithm adjusting clip boundaries by mismatch |
| `09d_rebuild_cigar.sh` | Rebuild CIGAR string + update AS/NM tags |
| `09e_call_variants.sh` | Re-call variants on corrected BAM |
| `09f_splice_check.sh` | Validate intron annotations, skip splice sites |

---

### Step 10 — Export (`scripts/10_export_csv.sh`)

Converts the annotated alignments to a flat CSV file with one row per molecule.
Each row contains standard SAM fields together with the custom annotations:
3' end position, 3' tail length, 3' tail sequence, translocation flag,
editing count, matched alignment length, and all detected variants. This table
is the primary output for downstream statistical analysis in R, Python, or
spreadsheet software.

| | |
|---|---|
| **Input** | `09_correct/{barcode}/{rpi}/{rpi}_corrected.sort.bam` |
| **Output** | `10_export_csv/{barcode}/{rpi}/{rpi}_reads.csv` + `{rpi}_quality_report.txt` |
| **Command** | `L3Rseq export --input <dir> --outdir <dir>` |
| **Tools** | python3, awk |

## Layer 3: Post-analysis

### `scripts/11_count.sh` (370 lines)
Gene-level molecule counting from mapped BAMs. Splice-aware overlap calculation
(excludes N ops). Discovers isoforms from CIGAR patterns. Normalizes against
housekeeping genes.
**Tools:** samtools, awk. **Env:** none.
**Output:** `11_count/gene_counts_all.tsv`, `isoform_discovery.tsv`, etc.

### `scripts/regions.sh` (428 lines)
Prepare gene region coordinates from GFF3, BED, or manual coordinate specs for
use with `L3Rseq count`. Supports `--discover-from` to auto-detect genes from
BAMs + GFF, and `--append` for incremental building.
**Tools:** awk. **Env:** none.

### `scripts/discover_introns.sh` (204 lines)
Scan mapped SAMs for clusters of large deletions (CIGAR N ops) indicating
intron splicing. Outputs candidate BED + confidence report.
**Tools:** python3, awk. **Env:** none.

### `scripts/filter.sh` (68 lines)
Optional pre-filter: rough-map reads with minimap2, keep only mapped reads.
**Tools:** minimap2, awk. **Env:** NanoporeMap.

### `scripts/setup_blast_db.sh` (214 lines)
Download and index BLAST databases (organelle + transcriptome) for step 09.
**Tools:** makeblastdb, wget. **Env:** NanoporeMap.

### `scripts/bump-version.sh` (40 lines)
Update version strings across CITATION.cff, L3Rseq, and CHANGELOG.md.
**Tools:** sed, date.

## Layer 4: UMI core (`longread_umi_L3Rseq/`)

Adapted from the longread-umi toolkit for L3Rseq-specific UMI handling.

### `longread_umi.sh` (141 lines)
Dispatcher that lists available tools in `scripts/` and forwards commands.

### `scripts/umi_binning_single.sh` (427 lines)
The UMI workhorse: extract UMIs with cutadapt (orientation-independent),
deduplicate, cluster at 90% identity (vsearch), assign reads to bins via BWA
with edit-distance filtering (NM≤1), parallel bin extraction.
**Tools:** cutadapt, vsearch, bwa, samtools, parallel.

### `scripts/consensus_racon.sh` (172 lines)
Consensus generation: find median-length seed read, polish with iterative
minimap2→racon rounds, collect into single FASTA.
**Tools:** minimap2, racon, parallel.

### `scripts/dependencies.sh` (84 lines)
Central dependency registry: tool paths, vsearch compatibility flags
(`--output` vs `-fastaout`, `--minseqlength 1`), version dump helper.

## Layer 5: IGV Viewer (`igv_viewer/`)

A Node.js web application on port 8080 with three pages sharing a common
dataset selector and navigation bar. The server is a thin HTTP adapter;
domain logic lives in `lib/` modules. Client JS is in separate `.js` files
(not inline in HTML).

```
  ┌───────────────────────────────────────────────┐
  │  server.js (350 lines) — HTTP adapter         │
  │  Routing, file serving, gzip, byte-range      │
  │                                               │
  │  /api/datasets, /api/tracks, /api/umi-stats   │
  │  /api/gene-counts, /api/gene-coverage         │
  │  /api/pileup, /api/viewer-state, /healthz     │
  └───────────────────┬───────────────────────────┘
                      │ requires
  ┌───────────────────▼───────────────────────────┐
  │  lib/                                         │
  │    helpers.js        — readdirSafe, statSafe  │
  │    bam.js            — BAM headers, tracks    │
  │    discovery.js      — datasets, references   │
  │    pipeline-stats.js — UMI, gene counts       │
  │    fasta.js          — FASTA sanitization     │
  └───────────────────────────────────────────────┘

  ┌───────────────────────────────────────────────┐
  │  HTML shells (no inline JS)                   │
  │    index.html (227 lines) — alignment         │
  │    umi.html   (49 lines)  — UMI stats         │
  │    genes.html (80 lines)  — gene counts       │
  └───────────────────┬───────────────────────────┘
                      │ <script src>
  ┌───────────────────▼───────────────────────────┐
  │  js/                                          │
  │    shared.js      — initDatasetPage(),        │
  │                     buildSampleSelector(),     │
  │                     syncNavLinks(), etc.       │
  │    alignment.js   — IGV.js track controls     │
  │    umi.js         — Chart.js UMI views        │
  │    genes.js       — Chart.js gene views       │
  │    dev-overlay.js — inspector overlay          │
  └───────────────────────────────────────────────┘
```

### Server

#### `server.js` (350 lines)
Thin HTTP adapter: CORS, routing, byte-range BAM support, gzip, static file
serving. Requires lib/ modules and calls them from API handlers.

#### `config.js` (20 lines)
Pipeline step definitions for BAM discovery: directory names, file suffixes,
display labels, and track colors.

#### `pileup.js` (132 lines)
Read pileup generator: runs `samtools mpileup` and parses output for the
`/api/pileup` endpoint. Uses dependency injection (receives `deps` object).

### Server lib modules (`lib/`)

#### `lib/helpers.js` (30 lines)
Shared filesystem helpers: `readdirSafe()`, `isDirSafe()`, `statSafe()`,
`naturalCompare()`. Used by all other lib modules.

#### `lib/bam.js` (123 lines)
BAM file operations: `bamReferenceName()` reads reference from BGZF headers;
`discoverTracks()` walks pipeline output directories to find sorted BAMs;
`trackUrl()` and `resolveTrackPath()` map between filesystem and URLs.
Needs `init({ WORKSPACE, DATA_DIR })`.

#### `lib/discovery.js` (84 lines)
Dataset and reference discovery: `discoverDatasets()` scans for directories
containing `07_map/` or `09_correct/`; `discoverReferences()` finds indexed
FASTAs; `loadDataset()` combines track discovery with reference name lookup.
Needs `init({ WORKSPACE, SCAN_DIR, DATA_DIR })`.

#### `lib/pipeline-stats.js` (171 lines)
Pipeline output parsing: `parseTsv()` for generic TSV; `discoverUmiStats()`
reads step 04 bin size distributions; `discoverGeneCounts()` reads step 11
counts, isoforms, and normalized data; `readCoverageFile()` for depth data.

#### `lib/fasta.js` (80 lines)
FASTA sanitization: strips `\r`, wraps long lines, rebuilds `.fai` index.
Called at server startup for each reference file.

### Client HTML

#### `index.html` (227 lines)
Alignment viewer HTML shell. Contains page-specific CSS, the header with
dataset/reference dropdowns, controls panel HTML, and an inline IIFE for
immediate nav-link sync. Loads `alignment.js` via `<script src>`.

#### `umi.html` (49 lines)
UMI analysis HTML shell. Header, sample panel, view-mode buttons, singleton
toggle. Loads `umi.js`.

#### `genes.html` (80 lines)
Gene counts HTML shell. Header, sample panel, view-mode buttons, gene/
housekeeping selectors, top-N filter. Loads `genes.js`.

### Client JS (`js/`)

#### `js/shared.js` (276 lines)
Shared utilities used by all pages: `naturalSort()`, `barcodeHue()`,
`buildSampleSelector()`, `syncNavLinks()`, `destroyCharts()`,
`setViewMode()`, `initDatasetPage()` (shared dataset-page initialization
with page-specific callbacks for UMI and Genes pages).

#### `js/alignment.js` (723 lines)
IGV.js alignment viewer logic. `loadDataset()` fetches tracks and creates
an IGV browser; controls for display mode, sorting by SAM tags, coloring,
barcode grouping, track toggles with per-barcode checkboxes.

#### `js/umi.js` (431 lines)
UMI analysis: three views — **overlay** (cumulative + histogram), **grid**
(small multiples per sample), **table** (sortable stats). Colored by
barcode family.

#### `js/genes.js` (818 lines)
Gene counts: four views — **table** (heatmap-shaded), **chart** (grouped
bar), **isoforms** (stacked bar), **coverage** (line). Housekeeping
normalization, gene click → alignment viewer link, URL hash state.

#### `js/dev-overlay.js` (137 lines)
Development inspector. Click "DEV" badge → hover shows element name + CSS
selector, right-click copies.

### Utilities

#### `inspect.js` (156 lines)
CLI utility for inspecting BAM file headers and track discovery outside the
browser.

#### `screenshot.js` (188 lines)
Puppeteer-based headless screenshot tool for automated viewer verification.

## Layer 6: Tests

### `tests/run_tests.sh` (1417 lines) — master suite
Full pipeline on synthetic data: steps 01–10, both CT and CT,AG editing
patterns, SLAM-seq, splice discovery, BLAST chimera detection, walk
correction, viewer API checks. **156 checks, ~45s.**
Flags: `--skip-preprocess`, `--quick`, `--no-viewer`, `--test <N|NAME>`.

### `tests/test_shell_functions.sh` (~310 lines)
Unit tests for shell functions in isolation: CIGAR rebuild, intron parsing,
splice junction detection, D→N conversion, BLAST batch helpers, and
`_require_int`/`_require_str` validation guards for step 09.

### `tests/test_dispatcher.sh` (139 lines)
Tests L3Rseq CLI argument parsing: help, version, subcommand routing, unknown
commands, missing args.

### `tests/test_docker_image.sh` (225 lines)
Verifies the Docker image: build, conda envs present, tools work, synthetic
tests pass. **Run on host, not inside container.**

### `tests/test_real_data.sh` (456 lines)
Validates pipeline on real/user-provided data: output files, SAM tags, edit
counts, splice annotations. Configurable start/stop steps.

### `tests/test_splice_real_data.sh` (390 lines)
End-to-end splice workflow validation: mapping, intron discovery, step 09
correction with splice annotation, step 10 metrics.

### `tests/test_bind_mount.sh` (277 lines)
Docker bind-mount I/O: read-only inputs, writable outputs, UID/GID
preservation, spaces in paths.

### `igv_viewer/test_buttons.js` (353 lines)
Puppeteer DOM tests for the alignment viewer: dataset loading, track toggles,
display modes, sorting, coloring, dataset switching. **46 checks.**

### `igv_viewer/test_stress.js` (339 lines)
Scale stress tests: track cap enforcement, barcode group toggle, all view modes
across all 3 pages, cross-page navigation round-trips, URL state preservation.
Auto-discovers largest dataset; gracefully skips if no real data.

---

[README](../README.md) | [Adaptation](adaptation.md) | [Requirements](requirements.md) | **Code Overview** | [Development](development.md)
