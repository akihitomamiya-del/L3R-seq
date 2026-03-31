#!/usr/bin/env python3
"""
Generate synthetic FASTQ test data for L3Rseq pipeline testing.

Creates 2 barcodes × 2 RPIs with ~100 UMI clusters per RPI,
including noise reads. Output is split across 5 files per barcode
to mimic the original multi-file nanopore output.

The reads contain real ccb3 gene content so the full pipeline
(steps 01-10) can be tested end-to-end.
"""

import os
import gzip
import json
import random
import uuid
import sys
from collections import defaultdict

# ============================================================================
# Constants
# ============================================================================

SEED = 42
random.seed(SEED)

TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_DIR = os.path.dirname(TESTS_DIR)

# Reference gene sequence (1.5kbp test reference for clean viewer display)
REF_FASTA = os.path.join(PIPELINE_DIR, "resources", "references", "test_gene.fasta")

# Adapter sequences (from config.sh)
# Read structure (reverse orientation, which is ~87% of reads):
#   [TARGET_FWD][gene_body][CTGAC][15bp UMI][TGGAATTCTCGGGTGCCAAGGAACTCCAGTCAC][RPI_RC][adapter_3']
# Read structure (forward orientation):
#   [adapter_5'][RPI][GTGACTGGAGTTCCTTGGCACCCGAGAATTCCA][UMI_RC][GTCAG][gene_body_RC][TARGET_FWD_RC]

TARGET_FWD = "CTACGCGCAAATTCTCATTGG"  # 5' target primer
FLANK5 = "CTGAC"  # 5' UMI flanking
FLANK3 = "TGGAATTCTCGGGTGCCAAGGC"  # 3' UMI flanking (22bp)
ADAPTER_3_CORE = "TGGAATTCTCGGGTGCCAAGGAACTCCAGTCAC"  # after UMI
ADAPTER_3_TAIL = "ATCTCGTATGCCGTCTTCTGCTTG"  # after RPI

# RPI barcodes (6bp inserts from the 20nt RPI sequences)
RPI_BARCODES = {
    "barcode01": {
        "RPI_1": "CGTGAT",  # same as barcode02 for simplicity
        "RPI_2": "ACATCG",
    },
    "barcode02": {
        "RPI_1": "CGTGAT",
        "RPI_2": "ACATCG",
    },
}

# For step 03 demux, we need the full 20nt RPI barcodes
RPI_FULL_20NT = {
    "RPI_1": "ACGAGATCGTGATGTGACTG",
    "RPI_2": "ACGAGATACATCGGTGACTG",
}

# Cluster size distribution per RPI
# Format: (count_of_clusters, reads_per_cluster)
# Weighted toward larger bins to produce enough corrected reads for a
# clear pileup in the viewer (~40-50 corrected reads per sample).
CLUSTER_SPEC = [
    # Large bins — produce high-quality consensus, clear editing signal
    (10, 15), (10, 13), (10, 12), (10, 11), (10, 10),
    # Medium-large bins — bulk of the data
    (38, 9), (38, 8), (32, 7),
    # Medium bins (at threshold — min 4 for longread-umi)
    (10, 6), (10, 5), (5, 4),
    # Below-threshold bins (filtered out by pipeline)
    (3, 3), (3, 2),
    # Singletons
    (5, 1),
]

# Noise reads per RPI
NOISE_NO_ADAPTER = 40  # random sequence, no UMI structure
NOISE_CORRUPTED = 15   # partial adapter, will fail extraction
NOISE_NONMAPPING = 20  # valid adapter structure but random gene body (tests filter step)
CHIMERIC_READS = 3     # gene body + cDNA right-clip (tests BLAST chimera detection)

# Mock cDNA sequence for chimeric reads (must match mock_cdna BLAST DB: mock_rRNA_18S)
MOCK_CDNA_SEQ = (
    "CAGCCACATCAACCGCCACACACTGCCGCGTGGGACCAGCGTGTATCGTATCAACGTACTGACCCGCCCCGGC"
    "ATCCGCGGCCTTCATAAAATTCAAGACCTTCGCCCGAGAAGCCAACGCGTGCTCCTGGGGTCTGCCCAATATA"
    "ATTTTCGAGACCTCACCGTTGGAGCGACCTCGAATAAACCGGGACTTTCCTGTT"
)

# Variant specifications for testing different patterns.
# Positions are REFERENCE coordinates (not gene-body-relative).  All reads share
# the same editing sites (like real biology), but each site has a per-read
# probability of being edited (editing_rate) to model heterogeneous editing.
# Sites near the 3' end (>550) test walk correction: an edit right before the
# soft-clip boundary can prevent minimap2 from extending, but the correction
# algorithm walks through it using the known variant list.
# Shared position sets for reuse across samples
_CT_SPEC = {
    "pattern": "CT",
    "positions": [85, 260, 440, 580, 606, 607, 820],
    "boundary_positions": [606, 607],
    "editing_rate": 0.90,
}
_AG_SPEC = {
    "pattern": "AG",
    "positions": [95, 270, 455, 590, 616, 617, 835],
    "boundary_positions": [616, 617],
    "editing_rate": 0.90,
}
_TC_SPEC = {
    "pattern": "TC",
    "positions": [90, 265, 445, 585, 610, 612, 825],
    "boundary_positions": [610, 612],
    "editing_rate": 0.90,
}

# Per-(barcode, RPI) variant specifications.
# Each sample has a "patterns" list (one or more editing patterns) and
# optional "slam_tc" for T→C SLAM-seq labeling with gradient rates.
VARIANT_SPECS = {
    # CT editing only
    ("barcode01", "RPI_1"): {"patterns": [_CT_SPEC]},
    # AG editing only
    ("barcode01", "RPI_2"): {"patterns": [_AG_SPEC]},
    # CT + AG dual editing
    ("barcode02", "RPI_1"): {"patterns": [_CT_SPEC, _AG_SPEC]},
    # TC editing + T→C SLAM labeling (gradient: 0%, 1.5%, 4%, 8%)
    ("barcode02", "RPI_2"): {
        "patterns": [_TC_SPEC],
        "slam_tc": True,
        "tc_rates": [0.0, 0.015, 0.04, 0.08],
    },
}

# Output directories
OUT_DIR = os.path.join(TESTS_DIR, "synthetic_data")
DEMUX_DIR = os.path.join(OUT_DIR, "03_demux")
RAW_DIR = os.path.join(OUT_DIR, "Original_Fastq", "synth_test")

# Quality score characters (Phred+33, biased toward high quality)
QUAL_CHARS = "456789:;<=>?@ABCDEFGHIJKLMNO"
QUAL_LOW = "()*+,-./"


# ============================================================================
# Helper functions
# ============================================================================

def revcomp(seq):
    """Reverse complement a DNA sequence."""
    comp = str.maketrans("ACGTacgt", "TGCAtgca")
    return seq.translate(comp)[::-1]


def generate_umi(existing_umis, min_hamming=3):
    """Generate a random 15bp UMI that is at least min_hamming away from all existing UMIs."""
    bases = "ACGT"
    for _ in range(10000):
        umi = "".join(random.choice(bases) for _ in range(15))
        # Check Hamming distance to all existing UMIs
        too_close = False
        for existing in existing_umis:
            dist = sum(a != b for a, b in zip(umi, existing))
            if dist < min_hamming:
                too_close = True
                break
        if not too_close:
            return umi
    raise RuntimeError("Could not generate UMI with sufficient Hamming distance")


def generate_quality(length):
    """Generate a realistic nanopore quality string."""
    qual = []
    i = 0
    while i < length:
        # 5% chance of a low-quality burst (2-5 bases)
        if random.random() < 0.05:
            burst_len = min(random.randint(2, 5), length - i)
            qual.extend(random.choice(QUAL_LOW) for _ in range(burst_len))
            i += burst_len
        else:
            qual.append(random.choice(QUAL_CHARS))
            i += 1
    return "".join(qual[:length])


def make_read_name(barcode, read_num):
    """Generate a nanopore-style read name."""
    read_uuid = str(uuid.uuid4())
    return (
        f"@{read_uuid} runid=00000000000000000000000000synth01 "
        f"sampleid=synth_test read={read_num} ch={random.randint(1, 512)} "
        f"start_time=2026-01-01T00:00:{read_num % 60:02d}Z "
        f"model_version_id=synthetic_v1 barcode={barcode}"
    )


def introduce_nanopore_errors(seq, error_rate=0.02, indel_rate=0.005):
    """Introduce random substitution and indel errors to simulate nanopore noise.
    Default rates: 2% substitution + 0.5% indel (~Q20, typical R10.4.1 consensus).
    """
    bases = "ACGT"
    result = []
    for i, base in enumerate(seq):
        if random.random() < indel_rate:
            if random.random() < 0.5:
                # Insertion: add a random base before this one
                result.append(random.choice(bases))
                result.append(base)
            else:
                # Deletion: skip this base
                pass
        elif random.random() < error_rate:
            # Substitution
            alts = [b for b in bases if b != base.upper()]
            result.append(random.choice(alts))
        else:
            result.append(base)
    return "".join(result)


def introduce_variant(seq, pos, ref_base, alt_base):
    """Introduce a specific variant at a position if the ref base matches."""
    seq_list = list(seq)
    # Search near the position for the ref base (in case of length variation)
    for offset in range(0, 10):
        for p in [pos + offset, pos - offset]:
            if 0 <= p < len(seq_list) and seq_list[p].upper() == ref_base.upper():
                seq_list[p] = alt_base
                return "".join(seq_list), p
    return seq, None


def build_read_reverse(gene_body, umi, rpi_6bp):
    """Build a read in reverse orientation (majority of nanopore reads).
    Structure: TARGET_FWD + gene_body + FLANK5 + UMI + ADAPTER_3_CORE + RPI_RC + ADAPTER_3_TAIL
    """
    rpi_rc = revcomp(rpi_6bp)
    read = TARGET_FWD + gene_body + FLANK5 + umi + ADAPTER_3_CORE + rpi_rc + ADAPTER_3_TAIL
    # Reverse complement the whole thing (nanopore reads the other strand)
    return revcomp(read)


def build_read_forward(gene_body, umi, rpi_6bp):
    """Build a read in forward orientation.
    Structure: TARGET_FWD + gene_body + FLANK5 + UMI + ADAPTER_3_CORE + RPI_RC + ADAPTER_3_TAIL
    (kept in forward orientation)
    """
    rpi_rc = revcomp(rpi_6bp)
    return TARGET_FWD + gene_body + FLANK5 + umi + ADAPTER_3_CORE + rpi_rc + ADAPTER_3_TAIL


# ============================================================================
# Main generator
# ============================================================================

def load_reference():
    """Load the test_gene reference sequence."""
    with open(REF_FASTA) as f:
        lines = f.readlines()
    seq = "".join(line.strip() for line in lines if not line.startswith(">"))
    return seq.upper()



def generate_rpi_data(barcode, rpi_name, ref_seq, manifest):
    """Generate all reads for one barcode/RPI combination."""
    rpi_6bp = RPI_BARCODES[barcode][rpi_name]
    variant_spec = VARIANT_SPECS[(barcode, rpi_name)]
    reads = []
    rpi_manifest = {
        "barcode": barcode,
        "rpi": rpi_name,
        "variant_patterns": [p["pattern"] for p in variant_spec["patterns"]],
        "clusters": [],
        "noise_reads": 0,
        "corrupted_reads": 0,
    }

    # Generate UMI pool
    umis = []
    cluster_sizes = []
    for count, size in CLUSTER_SPEC:
        for _ in range(count):
            umi = generate_umi(umis)
            umis.append(umi)
            cluster_sizes.append(size)

    read_num = 0

    # Generate reads for each cluster
    for i, (umi, size) in enumerate(zip(umis, cluster_sizes)):
        expected_status = "kept" if size >= 4 else ("small" if size >= 2 else "singleton")

        cluster_info = {
            "umi": umi,
            "size": size,
            "expected_status": expected_status,
            "variant_positions": [],
        }

        # Pick a region of the reference for this cluster's gene body.
        # Mimics real 3' RACE-seq: all reads start near the forward primer
        # (position ~0) and vary in 3' extent.  The 3' end varies per cluster,
        # creating a wedge pileup like real data.
        gene_start = random.randint(0, 20)  # slight start variation (primer site)
        # Variable 3' extent across the 1.5kbp reference.
        # Dense editing cluster at 580-600.  Some reads end RIGHT INSIDE
        # this zone (3' end at 585-598), showing poly-A tails immediately
        # after a burst of editing — the hardest case for the aligner.
        r = random.random()
        if r < 0.20:
            gene_len = random.randint(585, 598)   # ends INSIDE editing cluster
        elif r < 0.40:
            gene_len = random.randint(620, 700)   # ends just past the cluster
        elif r < 0.60:
            gene_len = random.randint(800, 1200)  # long reads
        else:
            gene_len = random.randint(500, 580)   # ends before cluster (no editing at 3' end)
        gene_len = min(gene_len, len(ref_seq) - gene_start - 1)
        gene_body_template = ref_seq[gene_start:gene_start + gene_len]

        # Poly-A decision is per-cluster (same molecule → same poly-A status).
        # 30% of clusters have a poly-A tail; all reads in the cluster share
        # the same tail length (±1bp from sequencing noise).
        cluster_has_polya = random.random() < 0.30
        cluster_polya_len = random.randint(15, 50) if cluster_has_polya else 0

        for j in range(size):
            read_num += 1

            # All reads in the same bin share the same 3' end (same molecule).
            gene_body = gene_body_template

            # Poly-A tail: same length for all reads in the cluster (same molecule),
            # with ±1bp sequencing noise.
            if cluster_polya_len > 0:
                read_polya = cluster_polya_len + random.randint(-1, 1)
                gene_body = gene_body + "A" * max(0, read_polya)

            # Introduce editing at shared variant sites.
            # Iterates over all pattern entries (supports multi-pattern samples).
            # Each site is independently edited with editing_rate probability,
            # so different reads in the same bin have slightly different editing
            # patterns — matching real heterogeneous RNA editing biology.
            for pat_entry in variant_spec["patterns"]:
                ref_base = pat_entry["pattern"][0]
                alt_base = pat_entry["pattern"][1]
                boundary_positions = pat_entry.get("boundary_positions", [])
                editing_rate = pat_entry.get("editing_rate", 0.85)
                for vpos in pat_entry["positions"]:
                    rel_pos = vpos - gene_start
                    if rel_pos < 0 or rel_pos >= len(gene_body):
                        continue
                    site_rate = 0.75 if vpos in boundary_positions else editing_rate
                    if random.random() < site_rate:
                        gene_body, actual_pos = introduce_variant(
                            gene_body, rel_pos, ref_base, alt_base
                        )
                        if actual_pos is not None and actual_pos not in cluster_info["variant_positions"]:
                            cluster_info["variant_positions"].append(actual_pos)

            # SLAM-seq T→C labeling: random T→C at all T positions with gradient rate.
            # Reads are divided into groups with increasing TC rates (models pulse-chase).
            if variant_spec.get("slam_tc"):
                tc_rates = variant_spec["tc_rates"]
                group_idx = min(j * len(tc_rates) // size, len(tc_rates) - 1)
                tc_rate = tc_rates[group_idx]
                if tc_rate > 0:
                    body_list = list(gene_body)
                    for pos_idx in range(len(body_list)):
                        if body_list[pos_idx] == "T" and random.random() < tc_rate:
                            body_list[pos_idx] = "C"
                    gene_body = "".join(body_list)

            # Build the clean read first, then add errors to the ENTIRE read
            # (including adapters, flanks, and UMI — realistic nanopore behavior)
            if random.random() < 0.87:
                clean_seq = build_read_reverse(gene_body, umi, rpi_6bp)
            else:
                clean_seq = build_read_forward(gene_body, umi, rpi_6bp)

            # Apply nanopore errors across the full read
            seq = introduce_nanopore_errors(clean_seq, error_rate=0.02, indel_rate=0.005)

            qual = generate_quality(len(seq))
            name = make_read_name(barcode, read_num)
            reads.append((name, seq, qual))

        rpi_manifest["clusters"].append(cluster_info)

    # Generate noise reads (no adapter structure)
    for _ in range(NOISE_NO_ADAPTER):
        read_num += 1
        noise_len = random.randint(200, 600)
        seq = "".join(random.choice("ACGT") for _ in range(noise_len))
        qual = generate_quality(len(seq))
        name = make_read_name(barcode, read_num)
        reads.append((name, seq, qual))
        rpi_manifest["noise_reads"] += 1

    # Generate non-mapping reads with valid adapter structure.
    # These pass trimming and demuxing (correct adapters + RPI barcode)
    # but have random gene body that won't map to the reference.
    # Tests that the filter step actually filters something.
    for _ in range(NOISE_NONMAPPING):
        read_num += 1
        umi = "".join(random.choice("ACGT") for _ in range(15))
        gene_len = random.randint(300, 500)
        random_gene = "".join(random.choice("ACGT") for _ in range(gene_len))

        if random.random() < 0.87:
            seq = build_read_reverse(random_gene, umi, rpi_6bp)
        else:
            seq = build_read_forward(random_gene, umi, rpi_6bp)

        qual = generate_quality(len(seq))
        name = make_read_name(barcode, read_num)
        reads.append((name, seq, qual))
        rpi_manifest["noise_reads"] += 1

    # Generate corrupted adapter reads
    for k in range(NOISE_CORRUPTED):
        read_num += 1
        gene_len = random.randint(200, 400)
        gene_start = random.randint(50, len(ref_seq) - gene_len - 50)
        gene_body = ref_seq[gene_start:gene_start + gene_len]

        if k < 5:
            # Only FLANK5, no FLANK3
            seq = TARGET_FWD + gene_body + FLANK5 + "ACGTACGTACGTACG"
        elif k < 10:
            # Only FLANK3, no FLANK5
            seq = gene_body + "ACGTACGTACGTACG" + FLANK3 + ADAPTER_3_TAIL[:10]
        else:
            # Wrong spacing (5bp instead of 15bp between flanks)
            seq = TARGET_FWD + gene_body + FLANK5 + "ACGTG" + FLANK3

        # Random orientation
        if random.random() < 0.5:
            seq = revcomp(seq)

        qual = generate_quality(len(seq))
        name = make_read_name(barcode, read_num)
        reads.append((name, seq, qual))
        rpi_manifest["corrupted_reads"] += 1

    # Generate chimeric reads: real gene body + appended cDNA sequence.
    # These look like valid consensus reads but have a right-clip from a
    # PCR chimera (e.g., rRNA).  BLAST identifies the clip as non-target
    # cDNA and removes the read from corrected.sam.
    for k in range(CHIMERIC_READS):
        read_num += 1
        umi = generate_umi(umis)
        umis.append(umi)

        # Real gene body (maps to reference) + cDNA fragment (creates right-clip)
        gene_start = random.randint(0, 20)
        gene_len = random.randint(400, min(550, len(ref_seq) - gene_start - 1))
        gene_body = ref_seq[gene_start:gene_start + gene_len]
        # Append 120-180bp of mock cDNA — enough to exceed the clip_thresh (100bp)
        cdna_len = random.randint(120, 180)
        chimeric_body = gene_body + MOCK_CDNA_SEQ[:cdna_len]

        # Build as a normal UMI read (will pass steps 01-08)
        # Use a bin size of 5 so it passes the longread-umi threshold
        for _j in range(5):
            read_num += 1
            read_body = chimeric_body
            if random.random() < 0.87:
                clean_seq = build_read_reverse(read_body, umi, rpi_6bp)
            else:
                clean_seq = build_read_forward(read_body, umi, rpi_6bp)
            seq = introduce_nanopore_errors(clean_seq, error_rate=0.02, indel_rate=0.005)
            qual = generate_quality(len(seq))
            name = make_read_name(barcode, read_num)
            reads.append((name, seq, qual))

    # Shuffle reads
    random.shuffle(reads)

    manifest[f"{barcode}/{rpi_name}"] = rpi_manifest
    return reads


def write_fastq(reads, filepath):
    """Write reads to a FASTQ file."""
    with open(filepath, "w") as f:
        for name, seq, qual in reads:
            f.write(f"{name}\n{seq}\n+\n{qual}\n")


def write_fastq_gz(reads, filepath):
    """Write reads to a gzipped FASTQ file."""
    with gzip.open(filepath, "wt") as f:
        for name, seq, qual in reads:
            f.write(f"{name}\n{seq}\n+\n{qual}\n")


def split_reads(reads, n_files):
    """Split reads into n_files roughly equal groups."""
    chunks = [[] for _ in range(n_files)]
    for i, read in enumerate(reads):
        chunks[i % n_files].append(read)
    return chunks


def main():
    print("Loading reference sequence...")
    ref_seq = load_reference()
    print(f"  Reference length: {len(ref_seq)} bp")

    manifest = {}

    # Track all reads per barcode (for step 01 split files)
    barcode_all_reads = defaultdict(list)

    for barcode in ["barcode01", "barcode02"]:
        for rpi_name in ["RPI_1", "RPI_2"]:
            print(f"\nGenerating {barcode}/{rpi_name}...")
            reads = generate_rpi_data(barcode, rpi_name, ref_seq, manifest)

            # Count statistics
            m = manifest[f"{barcode}/{rpi_name}"]
            total = len(reads)
            clusters = len(m["clusters"])
            kept = sum(1 for c in m["clusters"] if c["expected_status"] == "kept")
            small = sum(1 for c in m["clusters"] if c["expected_status"] == "small")
            singletons = sum(1 for c in m["clusters"] if c["expected_status"] == "singleton")
            valid_reads = sum(c["size"] for c in m["clusters"])
            print(f"  Total reads: {total}")
            print(f"  Valid UMI reads: {valid_reads}")
            print(f"  Clusters: {clusters} (kept={kept}, small={small}, singleton={singletons})")
            print(f"  Noise reads: {m['noise_reads']}")
            print(f"  Corrupted reads: {m['corrupted_reads']}")
            print(f"  Variant patterns: {','.join(m['variant_patterns'])}")

            # Write demux-style output (single FASTQ per RPI)
            demux_barcode_dir = os.path.join(DEMUX_DIR, barcode)
            os.makedirs(demux_barcode_dir, exist_ok=True)
            fastq_path = os.path.join(demux_barcode_dir, f"{barcode}_{rpi_name}.fastq")
            write_fastq(reads, fastq_path)
            print(f"  Written: {fastq_path}")

            # Accumulate for barcode-level split files
            barcode_all_reads[barcode].extend(reads)

    # Write split files (5 per barcode, gzipped) for step 01 testing
    print("\nWriting split raw FASTQ files (5 per barcode)...")
    for barcode, all_reads in barcode_all_reads.items():
        raw_barcode_dir = os.path.join(RAW_DIR, barcode)
        os.makedirs(raw_barcode_dir, exist_ok=True)

        # Shuffle all reads from both RPIs together
        random.shuffle(all_reads)
        chunks = split_reads(all_reads, 5)

        for i, chunk in enumerate(chunks):
            gz_path = os.path.join(
                raw_barcode_dir,
                f"fastq_runid_synth_{i:04d}_0.fastq.gz"
            )
            write_fastq_gz(chunk, gz_path)
            print(f"  Written: {gz_path} ({len(chunk)} reads)")

    # Write unclassified files (empty, for demux compatibility)
    for barcode in ["barcode01", "barcode02"]:
        unclass_path = os.path.join(DEMUX_DIR, barcode, f"{barcode}_unclassified.fastq")
        with open(unclass_path, "w") as f:
            pass  # empty file

    # Write manifest
    manifest_path = os.path.join(OUT_DIR, "expected_results.json")
    # Add summary
    manifest["_summary"] = {
        "seed": SEED,
        "barcodes": ["barcode01", "barcode02"],
        "rpis_per_barcode": ["RPI_1", "RPI_2"],
        "files_per_barcode": 5,
        "min_bin_size": 4,
        "barcode01_pattern": "CT",
        "barcode02_pattern": "AG",
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"\nManifest: {manifest_path}")

    # Write a summary of expected results
    print("\n=== Expected Results Summary ===")
    for key, m in manifest.items():
        if key.startswith("_"):
            continue
        kept = sum(1 for c in m["clusters"] if c["expected_status"] == "kept")
        small = sum(1 for c in m["clusters"] if c["expected_status"] == "small")
        valid = sum(c["size"] for c in m["clusters"] if c["expected_status"] == "kept")
        print(f"  {key}: {kept} kept bins, {small} small bins, {valid} reads in kept bins")

    print("\nDone.")


if __name__ == "__main__":
    main()
