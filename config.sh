#!/bin/bash
# config.sh -- Shared defaults for the L3Rseq pipeline
# Sourced by the L3Rseq dispatcher. Users should not need to edit this file;
# all values can be overridden with command-line flags.

# ---------------------------------------------------------------------------
# Step 02: Adapter trimming (cutadapt)
#
# These are the Illumina TruSeq Small RNA adapter sequences flanking the
# insert. The N-runs are the 6bp RPI barcode region. Reads are oriented
# 3'→5' by nanopore, so "FWD" is the 3' adapter seen first.
#
# FWD/REV: used by step 02 to find and orient reads (linked adapter search).
# TRIM3:   anchored ($) pattern for trimming the 3' adapter after orientation.
# ---------------------------------------------------------------------------
DEFAULT_ADAPTER_FWD='CAAGCAGAAGACGGCATACGAGATNNNNNNGTGACTGGAGTTCCTTGGCACCCGAGAATTCCA;min_overlap=63'
DEFAULT_ADAPTER_REV='TGGAATTCTCGGGTGCCAAGGAACTCCAGTCACNNNNNNATCTCGTATGCCGTCTTCTGCTTG;min_overlap=63'
DEFAULT_ADAPTER_TRIM3='TGGAATTCTCGGGTGCCAAGGAACTCCAGTCACNNNNNNATCTCGTATGCCGTCTTCTGCTTG$'

# ---------------------------------------------------------------------------
# Step 03: RPI demultiplexing (cutadapt)
# ---------------------------------------------------------------------------
DEFAULT_DEMUX_ERROR_RATE=1        # max errors in 20bp RPI barcode match
DEFAULT_DEMUX_MIN_OVERLAP=20      # require full 20bp overlap

# ---------------------------------------------------------------------------
# Step 04: UMI extraction — UMIC-seq method
#
# Used when --method umic-seq. Requires --probe pointing to a probe FASTA.
# ---------------------------------------------------------------------------
DEFAULT_UMI_LEN=15                # UMI length in bases
DEFAULT_UMI_LOC="down"            # UMI position relative to probe (up/down)
DEFAULT_MIN_PROBE_SCORE=33        # min alignment score for probe match
DEFAULT_ALN_THRESH=24             # min alignment score for UMI clustering
DEFAULT_SIZE_THRESH=3             # min reads per UMI bin (UMIC-seq)
DEFAULT_CLUSTER_STEPS="15 29 1"   # starcode distance sweep: start stop step
DEFAULT_SAMPLE_SIZE=50            # reads sampled per bin for consensus

# ---------------------------------------------------------------------------
# Step 04: UMI extraction — longread-umi method (default)
#
# Uses flanking sequences around the UMI to extract it from each read.
# FLANK5 is the 5bp motif upstream of the UMI; FLANK3 is the 22bp motif
# downstream. These are constant across all our library preps.
# ---------------------------------------------------------------------------
DEFAULT_UMI_FLANK5="CTGAC"
DEFAULT_UMI_FLANK3="TGGAATTCTCGGGTGCCAAGGC"
DEFAULT_LONGREAD_SIZE_THRESH=3    # min reads per UMI bin (longread-umi)

# ---------------------------------------------------------------------------
# Step 05: Consensus calling (racon + minimap2)
# ---------------------------------------------------------------------------
DEFAULT_CONSENSUS_THREADS=$(nproc 2>/dev/null || echo 4)
DEFAULT_CONSENSUS_ROUNDS=4        # racon polishing iterations
DEFAULT_CONSENSUS_PRESET="lr:hq"  # minimap2 preset for consensus alignment

# ---------------------------------------------------------------------------
# Step 06: Target sequence extraction (cutadapt)
#
# Primers that flank the gene of interest. Used to trim adapter remnants
# from consensus reads, leaving only the target insert.
# Defaults are for ccb3 (ccmB-ccmC intergenic, Arabidopsis mitochondria).
# Override with --target-fwd / --target-rev for other genes.
# See resources/primers/ for primer files used in different experiments.
# ---------------------------------------------------------------------------
DEFAULT_TARGET_FWD='CTACGCGCAAATTCTCATTGG'
DEFAULT_TARGET_REV='CTGACNNNNNNNNNNNNNNNTGGAATTCTCGGGTGCCAAGGAACTCCAGTCA'
DEFAULT_TARGET_MIN_OVERLAP=52
DEFAULT_ERROR_RATE=0.2            # cutadapt error rate (steps 02, 06)

# ---------------------------------------------------------------------------
# Step 07: Read mapping (minimap2)
# ---------------------------------------------------------------------------
DEFAULT_MAP_PRESET="lr:hq"        # minimap2 preset for mapping to reference

# ---------------------------------------------------------------------------
# Step 08: Variant detection (LoFreq)
# ---------------------------------------------------------------------------
DEFAULT_MIN_AF=0.01               # min allele frequency to call a variant
DEFAULT_PATTERN="CT"              # RNA editing pattern (ref→edit, e.g. CT = C-to-T)

# ---------------------------------------------------------------------------
# Step 09: 3' tail correction (walk algorithm + BLAST)
# ---------------------------------------------------------------------------
DEFAULT_CLIP_THRESH=50            # min soft-clip length (bp) to trigger BLAST
DEFAULT_CORRECT_THREADS=$(nproc 2>/dev/null || echo 4)

# ---------------------------------------------------------------------------
# Conda environment names
# ---------------------------------------------------------------------------
ENV_CUTADAPT="cutadaptenv"        # steps 02, 03, 06
ENV_UMIC="UMIC-seq"              # step 04 (--method umic-seq)
ENV_LONGREAD_UMI="longread_umi"  # steps 04, 05 (--method longread-umi)
ENV_MAP="NanoporeMap"            # steps 07, 09, filter
ENV_LOFREQ="LoFreq"             # step 08
