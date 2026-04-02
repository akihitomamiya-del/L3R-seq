#!/usr/bin/env python3
"""
Generate walk correction demo INPUT for the IGV viewer "demo" tab.

Creates FASTQ reads mapped by real minimap2, then fed to L3Rseq step 09.

  - ~100 walk-correctable reads: gene body with C→T edits at 606-607,
    followed by poly-A tail.  Minimap2 clips at the editing boundary.
  - ~20 long reads: span past 606 with C→T visible as aligned mismatches.

Usage:
  python3 tests/generate_demo_data.py <demo_outdir>

Requires: minimap2, samtools in PATH (activate NanoporeMap conda env).
"""

import os
import random
import subprocess
import sys

SEED = 42
random.seed(SEED)

TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_DIR = os.path.dirname(TESTS_DIR)
REF_FASTA = os.path.join(PIPELINE_DIR, "resources", "references", "test_gene.fasta")
REF_NAME = "test_gene"

BARCODE = "demo"
RPI = "demo_demo_RPI_1"

# C→T editing sites (0-based).  Reference has CCCC at 605-608.
EDIT_POSITIONS = {580, 606, 607}


def read_reference(path):
    with open(path) as f:
        lines = f.readlines()
    return "".join(l.strip() for l in lines if not l.startswith(">")).upper()


def apply_edits(seq, offset=0):
    """Apply C→T edits at known positions.  offset = reference position of seq[0]."""
    seq = list(seq)
    for ep in EDIT_POSITIONS:
        idx = ep - offset
        if 0 <= idx < len(seq) and seq[idx] == "C":
            seq[idx] = "T"
    return "".join(seq)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <demo_outdir>", file=sys.stderr)
        sys.exit(1)

    out_dir = sys.argv[1]
    ref_seq = read_reference(REF_FASTA)
    ref_len = len(ref_seq)

    map_dir = os.path.join(out_dir, "07_map", BARCODE, RPI)
    var_dir = os.path.join(out_dir, "08_variants", BARCODE, RPI)
    os.makedirs(map_dir, exist_ok=True)
    os.makedirs(var_dir, exist_ok=True)

    # === Build FASTQ reads ===
    fastq_path = os.path.join(map_dir, "demo_reads.fastq")
    reads = []

    # --- Walk-correctable reads (100) ---
    # Gene body ends RIGHT AT the editing zone (606-610bp).  C→T edits at
    # 606-607 sit at the boundary where poly-A begins.  Minimap2 aligns the
    # clean gene body, hits C→T + poly-A, and soft-clips there.  Walk
    # correction then extends through the known C→T variants.
    n_walk = 100
    for i in range(n_walk):
        gene_len = random.randint(610, 616)
        polya_len = random.randint(25, 50)
        gene_body = apply_edits(ref_seq[:gene_len])
        seq = gene_body + "A" * polya_len
        qual = "I" * len(seq)
        name = f"walk_{i+1:03d};ubs=8"
        reads.append((name, seq, qual))

    # --- Long reads (20) ---
    # Span well past 606 — C→T visible as mismatches in aligned region.
    # No poly-A, so minimap2 aligns the full length.
    n_long = 20
    for i in range(n_long):
        gene_len = random.randint(900, min(1300, ref_len))
        seq = apply_edits(ref_seq[:gene_len])
        qual = "I" * len(seq)
        name = f"long_{i+1:03d};ubs=8"
        reads.append((name, seq, qual))

    # Write FASTQ
    with open(fastq_path, "w") as f:
        for name, seq, qual in reads:
            f.write(f"@{name}\n{seq}\n+\n{qual}\n")

    # === Map with minimap2 → sorted BAM ===
    prefix = RPI + "_"
    sam_path = os.path.join(map_dir, prefix + "mapped_only.sam")
    bam_path = os.path.join(map_dir, prefix + "aligned.bam")
    sort_path = os.path.join(map_dir, prefix + "aligned.sort.bam")

    # minimap2 -a produces SAM; pipe through samtools to get sorted BAM
    subprocess.run(
        f"minimap2 -a {REF_FASTA} {fastq_path} 2>/dev/null > {sam_path}",
        shell=True, check=True
    )
    subprocess.run(f"samtools view -bS {sam_path} > {bam_path}",
                   shell=True, capture_output=True, check=True)
    subprocess.run(f"samtools sort {bam_path} > {sort_path}",
                   shell=True, capture_output=True, check=True)
    subprocess.run(f"samtools index {sort_path}",
                   shell=True, capture_output=True, check=True)

    # === Write variant file (1-based, CT pattern) ===
    with open(os.path.join(var_dir, "observed_variants.txt"), "w") as f:
        for ep in sorted(EDIT_POSITIONS):
            f.write(f"{ep + 1}CT\n")  # 1-based

    # === Report ===
    mapped = subprocess.run(f"samtools view -c {sort_path}",
                            shell=True, capture_output=True, text=True).stdout.strip()
    # Show a few CIGARs
    cigars = subprocess.run(f"samtools view {sort_path} | head -5 | awk '{{print $1, $6}}'",
                            shell=True, capture_output=True, text=True).stdout.strip()

    print(f"Demo input: {n_walk + n_long} reads ({n_walk} walk-correctable, {n_long} long)")
    print(f"  Mapped by minimap2: {mapped} reads")
    print(f"  Variants: positions {sorted(EDIT_POSITIONS)} (0-based)")
    print(f"  Sample CIGARs:")
    for line in cigars.split("\n"):
        print(f"    {line}")


if __name__ == "__main__":
    main()
