[README](../README.md) | **Adaptation** | [Requirements](requirements.md) | [Code Overview](code-overview.md) | [Development](development.md)

---

# Adaptation

## Adapting to your experiment

L3Rseq ships with default adapter sequences and reference files for the *Arabidopsis* ccmC gene. To use with a different organism or library, adjust the flags below. If you are using the [L3Rseq Pipeline (Claude Code Sandbox)](development.md#claude-code-ai-assisted-development), you can also ask Claude to guide you through these adjustments interactively.

| What to change | How |
|---|---|
| Reference sequence | `--ref your_gene.fa` |
| Sample barcodes (RPI) | `--rpi-fasta your_barcodes.fa` |
| UMI flanking sequences | `--umi-flank5 NNNNN --umi-flank3 NNNNN` |
| BLAST databases | `bash scripts/setup_blast_db.sh --organelle-fasta your_mtDNA.fa --transcriptome-fasta your_cDNA.fa` then `--blast-db` / `--blast-db2` (see [below](#blast-databases)) |
| Adapter sequences | `L3Rseq trim --adapter-fwd ... --adapter-rev ...` (defaults match the protocol in the manuscript; override for different library designs) |
| Target extraction primers | `L3Rseq extract --target-fwd ... --target-rev ...` (users analyzing shorter amplicons may need to reduce `--min-overlap`). Use `--no-target-fwd` to skip the forward primer and trim only the reverse (adapter) side — useful for library checks or when the forward primer is unknown |
| Editing pattern | `--pattern AG` (for A-to-I editing), or `--pattern CT,AG` to count multiple editing types as primary editing |
| Known editing positions | `--var known_sites.txt` (use when a control sample with established editing sites is available, in addition to or instead of LoFreq-detected positions) |

### UMI bin size tuning

The default `min_bin_size=3` balances consensus quality and yield. On real data (*Arabidopsis* ccmC), quality plateaus at n>=3 (89% error-free, 0.22 noise/1000bp). Increase to n>=4 or n>=5 for lower noise at the cost of fewer consensus reads.

To evaluate your data, generate bin analysis plots or use the viewer's [UMI analysis page](#alignment-viewer) (`/umi`):

```bash
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --quality
```

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

The viewer has three pages:
- `/` — Alignment viewer (IGV.js BAM tracks for steps 07/09)
- `/umi` — UMI analysis (Chart.js histograms for step 04 bin sizes)
- `/genes` — Gene counts (molecule counts per gene from step 11)

All pages share the same dataset dropdown and link to each other in the header.
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

### Gene counts page (`/genes`)

Displays gene-level molecule counts from `L3Rseq count` output (step 11). Only visible when the selected dataset contains `11_count/` data — otherwise shows a help message with the commands to run.

Four view modes:
- **Table** — sortable count table with heatmap-style shading. Toggle "Per-isoform rows" to see splice-pattern breakdown. When a housekeeping gene is selected, shows normalized ratios
- **Chart** — grouped bar chart comparing molecule counts (or ratios) across samples per gene
- **Isoforms** — stacked bar chart showing splice-pattern composition per sample, with a pooled isoform discovery panel (per barcode) summarizing pattern frequencies across all samples
- **Coverage** — per-base read depth line chart fetched on demand via `/api/gene-coverage`

Controls:
- **Housekeeping** dropdown — select a gene for normalization; Table and Chart views switch to showing ratios
- **Gene** dropdown — filter to a single gene (affects all views)
- **Sample checkboxes** — same barcode-grouped selector as the UMI page

API endpoints: `/api/gene-counts?name=<dataset>` and `/api/gene-coverage?name=<dataset>&gene=<gene>&sample=<sample>`.

## Gene-level counting (qPCR-style quantification)

L3Rseq supports qPCR-style molecule counting from UMI-consensus BAMs. Since each consensus read represents a single original RNA molecule, counting reads per gene gives accurate absolute molecule counts — analogous to qPCR, but with the added benefit of per-isoform resolution from splice patterns in the same data.

Like qPCR, expression is quantified by normalizing target gene counts against a housekeeping gene. Unlike qPCR, each "measurement" also carries isoform identity (from CIGAR N operations), so you get both gene-level totals and splice-variant breakdown in a single experiment.

This is a standalone post-analysis workflow (not part of `L3Rseq run`). Two subcommands:

### Defining gene regions

```bash
# Auto-discover: scan BAMs to find which GFF genes have reads (recommended starting point)
L3Rseq regions --gff annotation.gff3 --discover-from results/ --output regions.tsv
L3Rseq regions --gff annotation.gff3 --discover-from results/ --output regions.tsv --min-reads 5

# From a GFF3 annotation (all genes, or filtered)
L3Rseq regions --gff annotation.gff3 --output regions.tsv
L3Rseq regions --gff annotation.gff3 --output regions.tsv \
    --span cds --name-pattern "Mp1g*" --chr chr5

# From a BED file
L3Rseq regions --bed genes.bed --output regions.tsv

# Manual coordinates (1-based inclusive)
L3Rseq regions --coordinates "gene1:chr5:1000-5000,gene2:chr8:2000-9000" --output regions.tsv

# Build up incrementally
L3Rseq regions --coordinates "geneA:chr1:100-500" --output regions.tsv
L3Rseq regions --coordinates "geneB:chr2:200-800" --output regions.tsv --append
```

**Auto-discovery** (`--discover-from`) is the recommended starting point for genome-wide mapping data. It scans all primary BAMs, extracts read midpoints, intersects them with every gene in the GFF, and outputs only genes that have mapped reads — sorted by read count descending, with a summary table. This avoids the error-prone process of manually identifying hotspot positions and looking up gene names. Use `--min-reads` to filter out low-count noise (genes with only 1-2 stray reads).

The `--span` option controls which part of the gene is used (GFF3 only):
- `gene` (default) — full gene extent
- `cds` — coding sequence only (ATG to stop codon)
- `mrna` — mRNA extent (includes UTRs)

### Counting molecules

```bash
# Basic counting
L3Rseq count --input results/ --outdir results/ --regions regions.tsv

# With housekeeping normalization
L3Rseq count --input results/ --outdir results/ --regions regions.tsv \
    --housekeeping MPTK1_5g02220

# Strict overlap (default 0.95 = reads must cover 95% of gene region)
L3Rseq count --input results/ --outdir results/ --regions regions.tsv \
    --min-frac 0.95

# Filter ambiguous multi-mappers (useful for homologue gene families)
L3Rseq count ... --min-mapq 20
```

Output (in `11_count/`):
- **Per-sample counts** — `{barcode}_{rpi}_gene_counts.tsv`
- **Merged counts** — `gene_counts_all.tsv` (one row per gene x sample x splice pattern)
- **Isoform discovery** — `isoform_discovery.tsv` (splice patterns pooled per barcode, sorted by frequency)
- **Normalized counts** — `gene_counts_normalized.tsv` (when `--housekeeping` is used; includes both gene-total and per-isoform ratios)
- **Coverage** — `coverage/{barcode}_{rpi}_{gene}.depth.tsv` (per-base depth for each gene)

### Iterative workflow

1. **Overview** — broad gene regions, permissive `--min-frac` (e.g., `0.01`) to see which genes got reads
2. **Discover** — inspect pooled isoform patterns in the viewer's Isoforms tab
3. **Refine** — narrow coordinates (e.g., `--span cds`), strict `--min-mapq 20` for homologue families

## How CIGAR-walk works

In L3R-seq, the reference sequence represents the genomic (DNA) sequence. Because C-to-U RNA editing changes the transcript relative to the genome, edited positions near the 3' end of the aligned region appear as mismatches, causing the aligner to prematurely soft-clip the rest of the sequence. For example, a read with true alignment `527M10S` may be reported as `513M24S` because 14 edited bases near the 3' boundary look like mismatches.

The CIGAR-walk correction parses the right-clipped portion and performs a base-by-base comparison between the clipped sequence and the downstream reference, tolerating mismatches at positions known to undergo RNA editing (from step 08). The comparison proceeds until a non-editing mismatch or the end of the reference is encountered, at which point the CIGAR is rebuilt with updated match and soft-clip counts. The remaining soft-clipped sequence after correction represents the true non-templated 3' extension (e.g., poly(A) tail).

Right-clipped sequences exceeding 50 bp are additionally searched by BLAST against the organellar genome to detect translocation events (e.g., trans-splicing or DNA recombination). Reads with an organellar hit are flagged (`TL:i:1`). Reads with no organellar hit are searched against a cDNA database; those matching elsewhere (e.g., ribosomal RNA) are classified as chimeric artifacts and separated for manual review. A user-supplied file of known editing positions (`--var`) can be used in addition to or instead of the positions detected in step 08.

## BLAST databases

Step 09 (tail correction) uses BLAST to classify reads whose 3' soft-clipped
region exceeds 50 bp. These long extensions may indicate trans-splicing,
genomic translocation, or chimeric ligation artifacts — events that cannot be
resolved by the walk algorithm alone.

Two BLAST databases are searched in order:

1. **Organelle genome** (`--blast-db`) — the full organellar genome (e.g.
   mitochondrial or chloroplast DNA). Reads with a hit here are flagged as
   translocations (`TL:i:1` SAM tag), meaning the 3' extension maps to a
   distant locus on the same genome.
2. **Transcriptome / cDNA** (`--blast-db2`) — a cDNA or transcript database.
   Reads that had no organellar hit but match here (e.g. ribosomal RNA
   contamination) are classified as chimeric artifacts and written to a
   separate file (`abnormal_rightclip.sam`) for manual review.

The default databases are for *Arabidopsis thaliana* (TAIR10 ChrM and cDNA).
For other organisms, build your own databases:

```bash
bash scripts/setup_blast_db.sh \
    --organelle-fasta your_mtDNA.fa \
    --transcriptome-fasta your_cDNA.fa
```

Then pass `--blast-db <path>` and `--blast-db2 <path>` to `L3Rseq correct` or
`L3Rseq run`.

> **When can you skip BLAST?** If your target gene is short and you do not
> expect 3' extensions longer than 50 bp (e.g. short poly(A) tails only),
> BLAST will rarely be triggered. The pipeline still runs without BLAST
> databases — reads exceeding the threshold are simply left unannotated for
> translocation status.

## Strand specificity and genome-wide mapping

L3R-seq libraries are inherently strand-specific: the adapter is ligated to the 3' end of the RNA, so every read originates from the sense strand. Steps 02 and 06 use cutadapt `--rc` to orient reads consistently based on adapter/primer sequences.

**Single-gene reference (default pipeline):** When reads are mapped to a per-gene reference FASTA (the standard workflow), the reference is oriented to match the gene, so reads map to the + strand. The 3' end of the RNA is at the right side of the alignment, and step 09's CIGAR-walk correction works correctly.

**Genome-wide reference (multi-gene counting):** When reads are mapped to a genome (e.g., for `L3Rseq count`), genes on the **- strand** produce reads that map to the - strand in SAM. In this case:
- **Gene counting (step 11) is unaffected** — it counts reads regardless of strand
- **3' tail correction (step 09) would be incorrect** for minus-strand genes — the "right clip" in the SAM record corresponds to the RNA's 5' end, not the 3' end. The CIGAR-walk algorithm would attempt to extend the wrong end of the molecule

If you plan to run step 09 on genome-mapped data, minus-strand genes will need the walk correction applied to the left clip instead of the right clip. This is not yet implemented — for now, use a per-gene reference for 3' tail analysis, and the genome reference only for counting.

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

[README](../README.md) | **Adaptation** | [Requirements](requirements.md) | [Code Overview](code-overview.md) | [Development](development.md)
