#!/usr/bin/env python3
"""
Generate synthetic test data for L3Rseq intron splicing support.

Creates a reference with a 200bp intron, plus pre-mapped SAM files containing
spliced and unspliced reads. This bypasses steps 01-08 and tests step 09's
splice annotation + step 10's CSV/quality report directly.
"""

import os
import random

SEED = 42
random.seed(SEED)

TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_DIR = os.path.dirname(TESTS_DIR)
OUT_DIR = os.path.join(TESTS_DIR, "data", "splice_test")
REF_PATH = os.path.join(PIPELINE_DIR, "resources", "references", "test_gene_with_intron.fasta")
REF_NAME = "test_gene_with_intron"

# Gene structure: exon1 (300bp) + intron (200bp) + exon2 (250bp) = 750bp total
EXON1_LEN = 300
INTRON_LEN = 200
EXON2_LEN = 250
INTRON_START = EXON1_LEN          # 300 (0-based)
INTRON_END = EXON1_LEN + INTRON_LEN  # 500 (0-based)
TOTAL_LEN = EXON1_LEN + INTRON_LEN + EXON2_LEN  # 750


def random_seq(length):
    return "".join(random.choice("ACGT") for _ in range(length))


def revcomp(seq):
    comp = str.maketrans("ACGTacgt", "TGCAtgca")
    return seq.translate(comp)[::-1]


def mutate(seq, rate=0.03):
    result = list(seq)
    for i in range(len(result)):
        if random.random() < rate:
            alts = [b for b in "ACGT" if b != result[i]]
            result[i] = random.choice(alts)
    return "".join(result)


def generate_quality(length):
    return "".join(random.choice("89:;<=>?@ABCDEFGHIJ") for _ in range(length))


def make_cigar_unspliced(read_len):
    """CIGAR for a read that maps through the intron (no deletion)."""
    return f"{read_len}M"


def make_cigar_spliced(exon1_match, intron_del, exon2_match):
    """CIGAR for a spliced read: exon1 match + intron deletion + exon2 match."""
    return f"{exon1_match}M{intron_del}D{exon2_match}M"


def read_fasta(path):
    """Read a single-sequence FASTA file and return the sequence."""
    seq_lines = []
    with open(path) as f:
        for line in f:
            if not line.startswith(">"):
                seq_lines.append(line.strip())
    return "".join(seq_lines).upper()


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # Read reference from resources/references/
    ref_seq = read_fasta(REF_PATH)
    assert len(ref_seq) == TOTAL_LEN, f"Expected {TOTAL_LEN}bp, got {len(ref_seq)}bp"

    exon1 = ref_seq[:EXON1_LEN]
    intron = ref_seq[INTRON_START:INTRON_END]
    exon2 = ref_seq[INTRON_END:]

    print(f"Reference: {REF_PATH} ({TOTAL_LEN}bp)")
    print(f"  Exon1: 0-{EXON1_LEN} ({EXON1_LEN}bp)")
    print(f"  Intron: {INTRON_START}-{INTRON_END} ({INTRON_LEN}bp)")
    print(f"  Exon2: {INTRON_END}-{TOTAL_LEN} ({EXON2_LEN}bp)")

    # Write intron BED file
    bed_path = os.path.join(OUT_DIR, "introns.bed")
    with open(bed_path, "w") as f:
        f.write(f"{REF_NAME}\t{INTRON_START}\t{INTRON_END}\tintron1\n")
    print(f"Intron BED: {bed_path}")

    # Generate reads as pre-mapped SAM
    # Structure: already mapped, so we create the SAM directly
    # This simulates what step 07 would produce

    reads = []
    read_num = 0

    # === Spliced reads: map to exon1 + skip intron + map to exon2 ===
    n_spliced = 15
    for i in range(n_spliced):
        read_num += 1
        # Read starts ~20bp into exon1, ends ~20bp before exon2 end
        start_offset = random.randint(10, 50)
        end_offset = random.randint(10, 50)
        e1_match = EXON1_LEN - start_offset
        e2_match = EXON2_LEN - end_offset

        # Build the actual read sequence (exon1 part + exon2 part, no intron)
        read_seq = mutate(exon1[start_offset:]) + mutate(exon2[:EXON2_LEN - end_offset])
        cigar = make_cigar_spliced(e1_match, INTRON_LEN, e2_match)
        pos = start_offset + 1  # 1-based
        qual = generate_quality(len(read_seq))
        qname = f"spliced_read_{read_num};ubs=8"

        reads.append((qname, "0", REF_NAME, str(pos), "60", cigar,
                      "*", "0", "0", read_seq, qual))

    # === Unspliced reads: map continuously through intron ===
    n_unspliced = 10
    for i in range(n_unspliced):
        read_num += 1
        start_offset = random.randint(10, 50)
        end_offset = random.randint(10, 50)
        read_len = TOTAL_LEN - start_offset - end_offset

        read_seq = mutate(ref_seq[start_offset:TOTAL_LEN - end_offset])
        cigar = make_cigar_unspliced(read_len)
        pos = start_offset + 1
        qual = generate_quality(len(read_seq))
        qname = f"unspliced_read_{read_num};ubs=8"

        reads.append((qname, "0", REF_NAME, str(pos), "60", cigar,
                      "*", "0", "0", read_seq, qual))

    # === Short reads that don't span the intron ===
    n_short = 5
    for i in range(n_short):
        read_num += 1
        # Map only within exon1 (before intron)
        start_offset = random.randint(10, 50)
        read_len = random.randint(100, 200)
        read_len = min(read_len, EXON1_LEN - start_offset - 30)

        read_seq = mutate(ref_seq[start_offset:start_offset + read_len])
        cigar = f"{read_len}M"
        pos = start_offset + 1
        qual = generate_quality(len(read_seq))
        qname = f"short_read_{read_num};ubs=8"

        reads.append((qname, "0", REF_NAME, str(pos), "60", cigar,
                      "*", "0", "0", read_seq, qual))

    # Write SAM file (pre-mapped, as if step 07 produced it)
    sam_dir = os.path.join(OUT_DIR, "07_map", "barcode_splice", "barcode_splice_RPI_1")
    os.makedirs(sam_dir, exist_ok=True)
    sam_path = os.path.join(sam_dir, "mapped_only.sam")

    with open(sam_path, "w") as f:
        f.write(f"@HD\tVN:1.6\tSO:coordinate\n")
        f.write(f"@SQ\tSN:{REF_NAME}\tLN:{TOTAL_LEN}\n")
        for fields in reads:
            f.write("\t".join(fields) + "\n")

    # Also create a sorted BAM + index (needed by step 08)
    os.system(f"samtools view -bS {sam_path} > {sam_dir}/aligned.bam 2>/dev/null")
    os.system(f"samtools sort {sam_dir}/aligned.bam > {sam_dir}/aligned.sort.bam 2>/dev/null")
    os.system(f"samtools index {sam_dir}/aligned.sort.bam 2>/dev/null")

    # Write an empty variants file (step 09 needs it)
    var_dir = os.path.join(OUT_DIR, "08_variants", "barcode_splice", "barcode_splice_RPI_1")
    os.makedirs(var_dir, exist_ok=True)
    with open(os.path.join(var_dir, "observed_variants.txt"), "w") as f:
        pass  # empty — no editing variants in this test

    print(f"\nSAM: {sam_path}")
    print(f"  Spliced reads:   {n_spliced} (deletion at intron {INTRON_START}-{INTRON_END})")
    print(f"  Unspliced reads: {n_unspliced} (map through intron)")
    print(f"  Short reads:     {n_short} (don't span intron)")
    print(f"  Total:           {read_num}")
    print(f"\nIntron spec for testing: \"{INTRON_START}-{INTRON_END}\"")
    print(f"Expected SJ distribution: S={n_spliced}, R={n_unspliced}, -={n_short}")


if __name__ == "__main__":
    main()
