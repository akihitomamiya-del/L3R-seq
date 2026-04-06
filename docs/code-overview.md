[README](../README.md) | [Advanced](advanced.md) | [Requirements](requirements.md) | **Code Overview** | [Development](development.md)

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

### `scripts/01_concat.sh` (50 lines)
Concatenate per-barcode `fastq.gz` files into single files.
**Tools:** gzip, awk. **Env:** none. **Output:** `01_concat/*.fastq.gz`

### `scripts/02_trim.sh` (70 lines)
Three-pass adapter trimming with linked adapter search to filter chimeric reads.
**Tools:** cutadapt (3 passes, `--rc`). **Env:** cutadaptenv.
**Output:** `02_trim/{barcode}/trim{1,2,3}.fastq.gz`

### `scripts/03_demultiplex.sh` (85 lines)
RPI barcode demultiplexing — assigns reads to sample-specific barcodes.
**Tools:** cutadapt. **Env:** cutadaptenv.
**Output:** `03_demux/{barcode}/*.fastq`

### `scripts/04_umi.sh` (201 lines)
UMI extraction and clustering. Two methods: **longread-umi** (default,
flank-based) or **UMIC-seq** (probe-alignment-based). Delegates heavy lifting
to `longread_umi_L3Rseq/scripts/umi_binning_single.sh`.
**Tools:** minimap2, cutadapt, vsearch. **Env:** longread_umi or UMIC-seq.
**Output:** `04_umi/{barcode}/{rpi}/UMIclusterfull_*/`

### `scripts/05_consensus.sh` (109 lines)
Racon-based consensus from UMI-clustered reads. Finds median-length seed read,
iteratively polishes with minimap2+racon.
**Tools:** racon, minimap2. **Env:** longread_umi.
**Output:** `05_consensus/{barcode}/{rpi}/consensus_*.fa`

### `scripts/06_extract.sh` (95 lines)
Extract target region from consensus using flanking primer sequences.
**Tools:** cutadapt (`--action=none`). **Env:** cutadaptenv.
**Output:** `06_extract/{barcode}/{rpi}/*_extracted_{trimmed,uncut}.fa`

### `scripts/07_map.sh` (116 lines)
Map consensus reads to reference genome, generate indexed BAM.
**Tools:** minimap2 (`lr:hq`), samtools. **Env:** NanoporeMap.
**Output:** `07_map/{barcode}/{rpi}/*_{aligned,primary}.sort.bam`

### `scripts/08_variants.sh` (77 lines)
Variant calling, filtering by allele frequency and RNA editing pattern (e.g. C→T).
**Tools:** lofreq, bcftools. **Env:** LoFreq.
**Output:** `08_variants/{barcode}/{rpi}/variants.vcf`

### `scripts/09_tail_correct.sh` (~470 lines) — orchestrator
Right-clip CIGAR correction: discovers translocations via BLAST, corrects clip
boundaries with a walk algorithm, converts intron D→N, re-calls variants.
Uses `set +e` inside per-read workers for arithmetic tolerance. Sources six
subscripts (09a–09f). Includes `_require_int`/`_require_str` validation guards
that check `RESULT_*` variables after each subscript call — catches silent
failures under `set +e` during development.
**Tools:** BLAST, samtools, LoFreq. **Env:** NanoporeMap.
**Output:** `09_correct/{barcode}/{rpi}/*_corrected.sort.bam`

| Subscript | Lines | Purpose |
|---|---|---|
| `09a_parse_cigar.sh` | 42 | Parse CIGAR into operation arrays, map read↔ref positions |
| `09b_blast_rightclip.sh` | 104 | Extract soft clips, batch BLAST against 2 DBs |
| `09c_walk_correction.sh` | 55 | Walk algorithm adjusting clip boundaries by mismatch |
| `09d_rebuild_cigar.sh` | 38 | Rebuild CIGAR string + update AS/NM tags |
| `09e_call_variants.sh` | 77 | Re-call variants on corrected BAM |
| `09f_splice_check.sh` | 291 | Validate intron annotations, skip splice sites |

### `scripts/10_export_csv.sh` (242 lines)
Convert corrected SAM to annotated CSV with quality metrics (substitution types,
error counts, coverage stats).
**Tools:** python3, awk. **Env:** none.
**Output:** `10_export_csv/{barcode}/{rpi}/*_reads.csv + *_quality_report.txt`

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

[README](../README.md) | [Advanced](advanced.md) | [Requirements](requirements.md) | **Code Overview** | [Development](development.md)
