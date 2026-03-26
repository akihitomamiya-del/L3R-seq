# Attribution

This directory contains scripts adapted from the
[longread_umi](https://github.com/SorenKarst/longread_umi) project by
Søren M. Karst and Ryan M. Ziels, licensed under GPL-3.0.

## Modified files

| File | Change |
|---|---|
| `scripts/dependencies.sh` | Replaced hardcoded usearch with vsearch and added compatibility flags |
| `scripts/consensus_racon.sh` | Uses `$USEARCH_SORTOUT_FLAG` for vsearch compatibility |

## New files

| File | Description |
|---|---|
| `scripts/umi_binning_single.sh` | Single-UMI binning for 3' RNA-seq libraries (based on the dual-UMI `umi_binning.sh` design) |

## Unmodified files

| File | Description |
|---|---|
| `longread_umi.sh` | Original dispatcher (entry point for `longread_umi` conda command) |

## Reference

Karst SM, Ziels RM, Kirkegaard RH, Sørensen EA, McDonald D, Zhu Q,
Knight R, Albertsen M. (2021). High-accuracy long-read amplicon sequences
using unique molecular identifiers with Nanopore or PacBio sequencing.
*Nature Methods*, 18, 165-169.
