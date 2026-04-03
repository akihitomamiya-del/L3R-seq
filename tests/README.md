# L3Rseq Synthetic Test Suite

Automated tests for verifying the L3Rseq pipeline on synthetic data.

## Quick start

```bash
bash tests/run_tests.sh --quick           # smoke test (~26s, 77 checks)
bash tests/run_tests.sh --skip-preprocess  # steps 04-10 only (~40s)
bash tests/run_tests.sh                    # all steps 01-10 + gene counting (156 checks)
bash tests/run_tests.sh --no-viewer        # skip IGV viewer after tests
```

The test runner starts the IGV viewer after tests by default.
Use `--no-viewer` to suppress it (e.g., in CI).

## Test data

The `data/` directory contains pre-generated synthetic FASTQ files:

- **2 barcodes** (barcode01, barcode02) × **2 RPIs** (RPI_1, RPI_2)
- ~190 UMI clusters per RPI (~180 kept bins above threshold)
- barcode01 reads contain **C-to-T** edits at fixed sites (for `--pattern CT` testing)
- barcode02 reads contain **A-to-G** edits at fixed sites (for `--pattern AG` testing)
- Chimeric reads with mock cDNA right-clips (for BLAST filtering)
- Poly-A tails on ~30% of clusters

### Directory layout

```
data/
  raw_fastq/          5 .fastq.gz files per barcode (for step 01)
  demux/              pre-demuxed FASTQs (for step 04+)
  (RPI barcodes for step 03 are in resources/rpi_barcodes/)
  slam_test/          synthetic SLAM-seq data (pre-mapped, 40 reads with T→C gradient)
  splice_test/        synthetic splice data (pre-mapped, 30 reads)
  blast_test/         synthetic BLAST data (pre-mapped, 32 reads)
  test_regions.tsv    gene regions for counting tests (TSV format)
  test_regions.bed    gene regions for counting tests (BED format)

expected/             reference results from a validated run
  csv_CT/             step 10 CSVs with --pattern CT
  consensus_CT/       step 05 consensus FASTAs
```

### Resource files used

The synthetic tests use these files from `resources/`:

| File | Used by |
|------|---------|
| `references/test_gene.fasta` | Steps 04-10 (main synthetic reference) |
| `references/test_gene_with_intron.fasta` | Splice test (Test 5) |
| `rpi_barcodes/RPI_Barcode_20nt.fasta` | Step 03 demux (Test 1) |
| `primers/ccb3_default.txt` | Documents the default target primers (matches `config.sh`) |
| `blast/mock_chrm/` | BLAST walk correction test (Test 6) |
| `blast/mock_cdna/` | BLAST chimeric detection test (Test 6) |

## What the tests check

| Check | Type | Tolerance |
|-------|------|-----------|
| Step 04 bin count | range | ≥ final mapped reads |
| Step 05 consensus count | exact | must match bins |
| Step 05 sequence identity | exact | ≥99% (deterministic) |
| Step 06 extracted count | exact | must match |
| Step 07 mapped read count | exact | must match |
| Step 09 editing count (EC) | tolerant | ±10% |
| Step 09 NC/SC tags | exact | must match |
| Step 10 CSV row count | exact | must match |
| CT vs AG pattern specificity | tolerant | correct pattern = high EC, wrong = low EC |
| SLAM-seq EC/SC/NC | exact | fixed C→T sites + random T→C gradient |
| Splice SJ/SI/IR tags | exact | must match |
| BLAST walk correction | exact | per-read CIGAR before→after checked |
| BLAST chimeric detection | exact | cDNA-matching clips removed |
| BLAST translocation | exact | ChrM-matching clips flagged TL:i:1 |
| Gene regions (coordinates) | exact | regions TSV format, column count |
| Gene regions (BED) | exact | BED → TSV conversion |
| Gene counting | tolerant | total counted vs flagstat (±20%) |
| BED/TSV equivalence | exact | BED-derived counts match TSV counts |
| Housekeeping normalization | exact | self-normalization ratio = 1.000 |

The pipeline is fully deterministic: racon runs single-threaded (`-t 1`) with
deterministic seed selection (median-length read). Consensus sequences are
identical across runs on the same container. Tool binaries are pre-compiled
by conda, so pinned versions (`racon=1.5.0`, `vsearch=2.30.4`) produce
identical output regardless of the host OS.

## Real data tests

Separate from the synthetic suite, real data validation scripts exist:

```bash
bash tests/test_splice_real_data.sh   # 892 ccmFc reads, intron discovery + splice annotation (~20 sec)
```

The splice test activates its own conda environment and uses BLAST databases
for chimeric read filtering.

For the real-data guide and testing details, see the
[README](../README.md#running-on-real-data).

## Regenerating test data

All generators live in `tests/generators/`. Each can be re-run independently:

```bash
python3 tests/generators/generate_synthetic_data.py   # full pipeline data → tests/synthetic_data/
python3 tests/generators/generate_blast_test_data.py   # BLAST fixtures → tests/data/blast_test/
python3 tests/generators/generate_slam_test_data.py    # SLAM fixtures → tests/data/slam_test/
python3 tests/generators/generate_splice_test_data.py  # splice fixtures → tests/data/splice_test/
python3 tests/generators/generate_demo_data.py <dir>   # demo (needs minimap2) → <dir>
```

RPI barcode FASTAs live in `resources/rpi_barcodes/` and are not regenerated.
After regenerating, run the pipeline once and copy the key outputs to
`expected/` to update the reference results.
