#!/usr/bin/env python3
"""
Generate synthetic test data for L3Rseq SLAM-seq support (--count-pattern TC).

Reads the shared test_gene.fasta reference (1520bp, no intron) and generates
pre-mapped SAM files containing reads with:
  - C->T editing at FIXED positions (enzymatic RNA editing, shared across reads)
  - T->C SLAM-seq incorporation at RANDOM positions (metabolic labeling)
  - Small amount of random noise (counted as NC)

This bypasses steps 01-08 and tests step 09's dual-pattern counting
+ step 10's CSV/quality report directly.
"""

import os
import random
import shutil
import subprocess

SEED = 99
random.seed(SEED)

TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_DIR = os.path.dirname(TESTS_DIR)
OUT_DIR = os.path.join(TESTS_DIR, "data", "slam_test")
REF_PATH = os.path.join(PIPELINE_DIR, "resources", "references", "test_gene.fasta")
REF_NAME = "test_gene"

# Read generation parameters
N_READS = 40

# Fixed C->T editing sites (0-based reference coordinates).
# These are shared across reads (enzymatic editing at known positions).
# ~85% of reads are edited at each site.
CT_EDIT_POSITIONS = [84, 169, 262, 353, 441, 521, 580, 607]
CT_EDIT_RATE = 0.85  # per-site probability

# T->C SLAM-seq incorporation: varies per read to model different labeling
# durations / nascent RNA fractions.  In real SLAM-seq, newly transcribed
# RNA has high T->C conversion, while pre-existing RNA has zero.
# We create a gradient: ~25% unlabeled (0%), ~25% low, ~25% medium, ~25% high.
TC_SLAM_GROUPS = [
    (10, 0.00),    # unlabeled (pre-existing RNA, no s4U incorporation)
    (10, 0.015),   # low labeling (short pulse)
    (10, 0.04),    # medium labeling
    (10, 0.08),    # high labeling (long pulse / fully nascent)
]

# Random noise (non-CT, non-TC substitutions)
NOISE_RATE = 0.002


def read_fasta(path):
    seq_lines = []
    with open(path) as f:
        for line in f:
            if not line.startswith(">"):
                seq_lines.append(line.strip())
    return "".join(seq_lines).upper()


def generate_quality(length):
    return "".join(random.choice("89:;<=>?@ABCDEFGHIJ") for _ in range(length))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    ref_seq = read_fasta(REF_PATH)
    total_len = len(ref_seq)
    print(f"Reference: {REF_PATH} ({total_len}bp)")

    t_positions = [i for i, b in enumerate(ref_seq) if b == "T"]
    print(f"  C->T editing sites: {CT_EDIT_POSITIONS}")
    print(f"  T positions for SLAM: {len(t_positions)}")

    reads = []
    total_ec = 0
    total_sc = 0
    total_nc = 0
    read_idx = 0

    for group_size, tc_rate in TC_SLAM_GROUPS:
        group_label = "unlabeled" if tc_rate == 0 else f"tc{tc_rate:.3f}"
        for _ in range(group_size):
            read_idx += 1
            start_offset = random.randint(5, 80)
            end_offset = random.randint(5, 80)
            read_start = start_offset
            read_end = total_len - end_offset

            read_bases = list(ref_seq[read_start:read_end])
            read_len = len(read_bases)

            ec = 0
            sc = 0
            nc = 0

            # C->T editing at FIXED positions (enzymatic, per-site stochastic)
            for ref_pos in CT_EDIT_POSITIONS:
                local_pos = ref_pos - read_start
                if 0 <= local_pos < read_len and ref_seq[ref_pos] == "C":
                    if random.random() < CT_EDIT_RATE:
                        read_bases[local_pos] = "T"
                        ec += 1

            # T->C SLAM incorporation at group-specific rate
            if tc_rate > 0:
                for ref_pos in t_positions:
                    local_pos = ref_pos - read_start
                    if 0 <= local_pos < read_len and read_bases[local_pos] == "T":
                        if random.random() < tc_rate:
                            read_bases[local_pos] = "C"
                            sc += 1

            # Random noise (skip CT and TC mutations to avoid confusion)
            for local_pos in range(read_len):
                ref_base = ref_seq[read_start + local_pos]
                if read_bases[local_pos] == ref_base and random.random() < NOISE_RATE:
                    alts = [b for b in "ACGT" if b != ref_base]
                    new_base = random.choice(alts)
                    if (ref_base == "C" and new_base == "T") or \
                       (ref_base == "T" and new_base == "C"):
                        continue
                    read_bases[local_pos] = new_base
                    nc += 1

            read_seq = "".join(read_bases)
            cigar = f"{read_len}M"
            pos = read_start + 1  # 1-based
            qual = generate_quality(read_len)
            qname = f"slam_{group_label}_{read_idx};ubs=8"

            reads.append((qname, "0", REF_NAME, str(pos), "60", cigar,
                          "*", "0", "0", read_seq, qual))

            total_ec += ec
            total_sc += sc
            total_nc += nc

    # Write SAM file
    sam_dir = os.path.join(OUT_DIR, "07_map", "slam", "slam_RPI_5")
    os.makedirs(sam_dir, exist_ok=True)
    prefix = "slam_RPI_5_"
    sam_path = os.path.join(sam_dir, prefix + "mapped_only.sam")

    with open(sam_path, "w") as f:
        f.write(f"@HD\tVN:1.6\tSO:coordinate\n")
        f.write(f"@SQ\tSN:{REF_NAME}\tLN:{total_len}\n")
        for fields in reads:
            f.write("\t".join(fields) + "\n")

    # Create sorted BAM + index
    samtools = shutil.which("samtools")
    if not samtools:
        for p in ["/opt/miniforge/envs/NanoporeMap/bin/samtools",
                  "/opt/miniforge/envs/longread_umi/bin/samtools"]:
            if os.path.exists(p):
                samtools = p
                break
    if not samtools:
        print("WARNING: samtools not found — BAM files not created")
    else:
        bam = os.path.join(sam_dir, prefix + "aligned.bam")
        sort_bam = os.path.join(sam_dir, prefix + "aligned.sort.bam")
        subprocess.run([samtools, "view", "-bS", sam_path, "-o", bam],
                       check=True, capture_output=True)
        subprocess.run([samtools, "sort", bam, "-o", sort_bam],
                       check=True, capture_output=True)
        subprocess.run([samtools, "index", sort_bam],
                       check=True, capture_output=True)

    # Write variant file with the fixed editing positions (for walk correction)
    var_dir = os.path.join(OUT_DIR, "08_variants", "slam", "slam_RPI_5")
    os.makedirs(var_dir, exist_ok=True)
    with open(os.path.join(var_dir, "observed_variants.txt"), "w") as f:
        for pos in CT_EDIT_POSITIONS:
            f.write(f"{pos + 1}CT\n")  # 1-based

    print(f"\nSAM: {sam_path}")
    print(f"  Reads:     {N_READS}")
    print(f"  Total EC:  {total_ec} (C->T at {len(CT_EDIT_POSITIONS)} fixed sites)")
    print(f"  Total SC:  {total_sc} (T->C random SLAM)")
    print(f"  Total NC:  {total_nc} (noise)")


if __name__ == "__main__":
    main()
