# Attribution

This directory contains a modified copy of the
[UMIC-seq](https://github.com/fhlab/UMIC-seq) script by
Paul Jannis Zurek, licensed under GPL-3.0.

## Bundled files

| File | Source | Status |
|---|---|---|
| `UMIC-seq_fastq_v2.py` | Upstream `UMIC-seq.py` (v1.1.2, 14 Sep 2022) | Modified |

The script is bundled here so the Docker image can install it
into the UMIC-seq conda environment without cloning the full
upstream repository at runtime.

## Modifications

Changes from the upstream `UMIC-seq.py`:

1. **Output format changed from FASTA to FASTQ** — `cluster_N.fasta` renamed to `umiNbins.fastq` and written as FASTQ instead of FASTA, to match the input format expected by longread_umi's `consensus_racon.sh`.
2. **Version header added** — comments on lines 10-11 document the FASTQ output change.

## Reference

Zurek PJ, Knyphausen P, Hollfelder F. (2020). UMI-linked consensus
sequencing enables phylogenetic analysis of directed evolution.
*Nature Communications*, 11, 6023.
