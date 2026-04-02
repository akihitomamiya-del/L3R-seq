[README](../README.md) | **Advanced** | [Testing](testing.md) | [Development](development.md) | [Requirements](requirements.md)

---

# Advanced usage

## Adapting to your experiment

L3Rseq ships with default adapter sequences and reference files for the *Arabidopsis* ccmC gene. To use with a different organism or library:

| What to change | How |
|---|---|
| Reference sequence | `--ref your_gene.fa` |
| Sample barcodes (RPI) | `--rpi-fasta your_barcodes.fa` |
| UMI flanking sequences | `--umi-flank5 NNNNN --umi-flank3 NNNNN` |
| BLAST databases | `bash scripts/setup_blast_db.sh --organelle-fasta your_mtDNA.fa --transcriptome-fasta your_cDNA.fa` then `--blast-db` / `--blast-db2` |
| Adapter sequences | `L3Rseq trim --adapter-fwd ... --adapter-rev ...` (defaults match the protocol in the manuscript; override for different library designs) |
| Target extraction primers | `L3Rseq extract --target-fwd ... --target-rev ...` (users analyzing shorter amplicons may need to reduce `--min-overlap`). Use `--no-target-fwd` to skip the forward primer and trim only the reverse (adapter) side — useful for library checks or when the forward primer is unknown |
| Editing pattern | `--pattern AG` (for A-to-I editing), or `--pattern CT,AG` to count multiple editing types as primary editing |
| Known editing positions | `--var known_sites.txt` (use when a control sample with established editing sites is available, in addition to or instead of LoFreq-detected positions) |

## Alignment viewer

L3Rseq includes a built-in [IGV.js](https://github.com/igvteam/igv.js) alignment viewer that runs in your browser. It auto-discovers BAM files from any pipeline output directory — no file upload or manual configuration needed.

**Features:**
- **Dataset selector** — dropdown lists all samples; any directory containing `07_map/` or `09_correct/` is detected automatically
- **Before/after tracks** — primary mapping (step 07, excludes secondary/supplementary alignments) and tail-corrected reads (step 09) displayed side by side so you can see the effect of CIGAR-walk correction
- **Sort reads by SAM tag** — sort by editing count (EC), noise (NC), 3' end position (3E), splice status (SJ), translocation (TL), double-sorter (DS), and more
- **Group reads by SAM tag** — group by EC to see editing levels (including EC=0 unedited reads), SJ for splice status, TL for translocations
- **Color reads by SAM tag** — color by splice status (green = spliced, red = retained, gray = unknown), editing count, noise, strand, or translocation, with auto-generated legend
- **Click any read** to inspect all [SAM tags](../README.md#6-sam-tags) (editing counts, 3' tail sequence, splice junctions, etc.)
- **Dataset descriptions** — place a `description.txt` file in any output directory to display a description in the viewer info bar when that dataset is selected. Line breaks are preserved. Example:

  ```
  results/description.txt:
    My experiment — C-to-T editing analysis
    
    barcode48/RPI_3: treated sample, barcode48/RPI_4: control
    
    Command:
    L3Rseq run --pattern CT --ref refs/gene.fasta --start-at 4
  ```

**Starting the viewer:**

```bash
L3Rseq viewer                          # start on default port 8080
L3Rseq viewer --dir tests/output       # scan a specific directory
L3Rseq viewer --port 9090              # use a different port
L3Rseq viewer --stop                   # stop the viewer
L3Rseq viewer --stop && L3Rseq viewer  # restart
```

> **Note:** `bash tests/run_tests.sh` temporarily stops the viewer during Test 6 (viewer API checks). It restarts automatically at the end unless `--no-viewer` is used.

In **Codespaces**, the viewer starts automatically — check the **Ports** tab in VS Code for the URL.

**With Docker** (view pipeline output without entering the container):

```bash
docker run --rm -p 8080:8080 \
    -v ~/results:/data/output:ro \
    -e IGV_DATA_DIR=/data/output \
    ghcr.io/akihitomamiya-del/l3rseq:latest \
    bash -c 'cd /workspace/igv_viewer && node server.js'
```

Then open `http://localhost:8080` in your browser.

The viewer has two pages:
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
- **Grid** — small multiples, one histogram per sample (adaptive layout: 1 sample = full width, 2 = side-by-side, 3-4 = 2 columns, 5-9 = 3 columns, 10+ = compact auto-fill)
- **Table** — sortable summary metrics (total reads, kept bins, yield %, etc.)

Samples are colored by barcode family. Singletons hidden by default (toggle to show).

## How CIGAR-walk works

In L3R-seq, the reference sequence represents the genomic (DNA) sequence. Because C-to-U RNA editing changes the transcript relative to the genome, edited positions near the 3' end of the aligned region appear as mismatches, causing the aligner to prematurely soft-clip the rest of the sequence. For example, a read with true alignment `527M10S` may be reported as `513M24S` because 14 edited bases near the 3' boundary look like mismatches.

The CIGAR-walk correction parses the right-clipped portion and performs a base-by-base comparison between the clipped sequence and the downstream reference, tolerating mismatches at positions known to undergo RNA editing (from step 08). The comparison proceeds until a non-editing mismatch or the end of the reference is encountered, at which point the CIGAR is rebuilt with updated match and soft-clip counts. The remaining soft-clipped sequence after correction represents the true non-templated 3' extension (e.g., poly(A) tail).

Right-clipped sequences exceeding 50 bp are additionally searched by BLAST against the organellar genome to detect translocation events (e.g., trans-splicing or DNA recombination). Reads with an organellar hit are flagged (`TL:i:1`). Reads with no organellar hit are searched against a cDNA database; those matching elsewhere (e.g., ribosomal RNA) are classified as chimeric artifacts and separated for manual review. A user-supplied file of known editing positions (`--var`) can be used in addition to or instead of the positions detected in step 08.

## Intron splicing support

For genes with introns, L3Rseq can classify reads as spliced or unspliced:

```bash
# If you know the intron coordinates
L3Rseq run --introns "847-2891" ...

# Using a BED file (multiple introns)
L3Rseq run --introns introns.bed ...

# Using a GFF3 annotation
L3Rseq run --introns gene_annotation.gff3 ...

# Discover introns from the data
L3Rseq discover-introns --input out/07_map --outdir out/
# Review the report, then use the candidate BED file
L3Rseq run --introns out/candidate_introns.bed ...
```

---

[README](../README.md) | **Advanced** | [Testing](testing.md) | [Development](development.md) | [Requirements](requirements.md)
