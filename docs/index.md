---
layout: default
title: "L3R-seq — Single-molecule RNA analysis from nanopore sequencing"
description: >-
  L3Rseq is an open-source bioinformatics pipeline that turns raw Oxford
  Nanopore reads into per-molecule measurements of RNA editing, splicing,
  3-prime cleavage position, and poly(A) tail length using UMI consensus
  sequencing.
---

L3R-seq (**Long-read 3' RACE-seq**) is a targeted nanopore sequencing method that uses unique molecular identifiers (UMIs) to build one high-accuracy consensus sequence per original RNA molecule. **L3Rseq** is its companion bioinformatics pipeline: it takes raw Oxford Nanopore FASTQ files and produces per-molecule CSV tables quantifying RNA editing, alternative splicing, 3' end cleavage position, and poly(A) tail status.

The pipeline was developed for *Arabidopsis thaliana* mitochondrial *ccmC* mRNA, but is adaptable to any target RNA on nanopore platforms.

[Get started on GitHub](https://github.com/akihitomamiya-del/L3R-seq){: .btn }
[Full documentation](https://github.com/akihitomamiya-del/L3R-seq#readme){: .btn }

---

## What you can measure with L3R-seq

Each row in the output CSV represents one original RNA molecule. Per-molecule columns include:

- **RNA editing events** (e.g., C-to-U) with configurable pattern matching
- **3' end cleavage position** on the reference
- **Poly(A) tail length and sequence** from the non-templated 3' extension
- **Splice status** per intron (spliced / retained / not spanned)
- **Noise count** separating biological editing from residual sequencing error

A secondary pattern option (`--count-pattern TC`) enables SLAM-seq T-to-C counting alongside primary editing in the same run.

## Key capabilities

| Capability | Description |
|---|---|
| UMI consensus calling | Groups reads by UMI, polishes each cluster into a single high-accuracy sequence |
| CIGAR-walk correction | Recovers 3' ends that aligners mis-clip due to editing near the transcript boundary |
| Intron splicing detection | Classifies reads as spliced or unspliced; can auto-discover intron coordinates |
| Translocation filtering | BLAST-based chimera detection separates real poly(A) tails from artifacts |
| Built-in alignment viewer | Browser-based IGV.js viewer with sorting and coloring by any SAM tag |

## Getting started

The fastest way to try L3Rseq is **GitHub Codespaces** — click "Code" then "Codespaces" on the repository page to get a fully configured Linux environment in your browser with all dependencies pre-installed.

Alternatively, pull the Docker image:

```bash
docker pull ghcr.io/akihitomamiya-del/l3rseq:latest
```

Then run the pipeline:

```bash
L3Rseq run \
  --input  data/fastq/       \
  --outdir results/           \
  --ref    refs/my_gene.fasta \
  --rpi-fasta refs/barcodes.fasta \
  --pattern CT
```

See the [full documentation](https://github.com/akihitomamiya-del/L3R-seq#readme) for detailed installation and usage instructions.

## Pipeline at a glance

L3Rseq runs ten steps, from raw reads to annotated CSV:

1. **Concatenate** per-barcode FASTQ files
2. **Trim** adapters (cutadapt, 3-pass)
3. **Demultiplex** by sample barcode
4. **UMI extraction** and read grouping
5. **Consensus calling** (Racon-based polishing)
6. **Target region extraction**
7. **Mapping** to reference (minimap2)
8. **Variant calling** (LoFreq)
9. **3' tail correction** with CIGAR-walk
10. **CSV export** and quality reporting

Enter at any step with `--start-at` / `--stop-at`.

## Requirements

All dependencies ship inside the Docker image. No manual installation of bioinformatics tools is needed. The pipeline uses conda environments for minimap2, samtools, cutadapt, racon, vsearch, LoFreq, BLAST+, and more.

## Citation

If you use L3Rseq in your research, please cite:

> Mamiya, A. L3Rseq: bioinformatics pipeline for Long-read 3' RACE-seq. [https://github.com/akihitomamiya-del/L3R-seq](https://github.com/akihitomamiya-del/L3R-seq)

## License

L3Rseq is released under the [GPL-3.0 license](https://github.com/akihitomamiya-del/L3R-seq/blob/main/LICENSE).
