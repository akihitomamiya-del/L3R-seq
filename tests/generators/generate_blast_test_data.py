#!/usr/bin/env python3
"""
Generate synthetic test data for L3Rseq BLAST + walk correction (Test 6).

Creates 32 pre-mapped SAM reads exercising every BLAST/walk code path,
with named BLAST database entries that demonstrate how right-clips are
identified and classified.

  Category              Count  Expected behavior
  ───────────────────────────────────────────────────────────
  Walk-correctable        8    CIGAR extended through C→T edits
  ChrM translocation      4    BLAST organelle hit → TL:i:1
  Chimeric (cDNA/rRNA)    4    BLAST cDNA hit → chimeric_rightclip.sam
  Poly-A tail             4    No BLAST hit → retained (TL:i:0)
  Unidentified clip       4    No BLAST hit → retained
  Control (no clip)       8    Pass through unchanged
  ───────────────────────────────────────────────────────────
  Total                  32    (28 in corrected.sam, 4 in chimeric)

Mock BLAST databases use designed sequences with real gene names:
  Organelle DB (mock_chrm):
    - mock_ChrM_cox1  (250bp)  cytochrome c oxidase subunit I
    - mock_ChrM_nad1  (200bp)  NADH dehydrogenase subunit 1
  Transcript DB (mock_cdna):
    - mock_rRNA_18S   (250bp)  18S ribosomal RNA
    - mock_rRNA_28S   (200bp)  28S ribosomal RNA
    - mock_mRNA_Rubisco (200bp)  ribulose-1,5-bisphosphate carboxylase

Each ChrM/chimeric read's right-clip is a recognizable fragment copied
directly from a database entry, showing how BLAST traces contamination
back to its source.

Follows the splice test pattern: bypasses steps 01-08, tests 09-10 directly.
"""

import os
import random
import subprocess

SEED = 42
random.seed(SEED)

TESTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_DIR = os.path.dirname(TESTS_DIR)
REF_FASTA = os.path.join(PIPELINE_DIR, "resources", "references", "test_gene.fasta")
OUT_DIR = os.path.join(TESTS_DIR, "data", "blast_test")
BLAST_DIR = os.path.join(PIPELINE_DIR, "resources", "blast")
REF_NAME = "test_gene"


# ============================================================================
# Mock BLAST database sequences
# ============================================================================
# Generated deterministically with biologically-inspired GC content:
#   - Mitochondrial DNA: AT-rich (GC ~30%), typical of plant organelles
#   - rRNA: GC-rich (~55-60%), typical of ribosomal RNA
#   - Rubisco mRNA: moderate GC (~45%), typical coding sequence

def _make_seq(seed_str, length, gc_bias=0.5):
    """Deterministic fake DNA with controlled GC content."""
    rng = random.Random(seed_str)
    at = (1 - gc_bias) / 2
    gc = gc_bias / 2
    return "".join(rng.choices("ACGT", weights=[at, gc, gc, at], k=length))


# --- Organelle genome (ChrM) ---
# Fragments from these sequences end up ligated to the target gene during
# library prep, creating chimeric molecules.  BLAST identifies the clip as
# organelle-origin → pipeline sets TL:i:1 (translocation flag).

CHRM_SEQUENCES = {
    "mock_ChrM_cox1": {
        "desc": "cytochrome c oxidase subunit I (mitochondrial)",
        "seq": _make_seq("cox1_mito_gene", 250, gc_bias=0.30),
    },
    "mock_ChrM_nad1": {
        "desc": "NADH dehydrogenase subunit 1 (mitochondrial)",
        "seq": _make_seq("nad1_mito_gene", 200, gc_bias=0.32),
    },
}

# --- Transcript database (cDNA) ---
# Abundant RNAs (rRNA, housekeeping genes) form PCR chimeras with the
# target during amplification.  BLAST identifies the clip as a non-target
# transcript → pipeline moves the read to chimeric_rightclip.sam.

CDNA_SEQUENCES = {
    "mock_rRNA_18S": {
        "desc": "18S ribosomal RNA small subunit (contaminant)",
        "seq": _make_seq("18S_rRNA_contam", 250, gc_bias=0.55),
    },
    "mock_rRNA_28S": {
        "desc": "28S ribosomal RNA large subunit (contaminant)",
        "seq": _make_seq("28S_rRNA_contam", 200, gc_bias=0.60),
    },
    "mock_mRNA_Rubisco": {
        "desc": "ribulose-1,5-bisphosphate carboxylase (off-target transcript)",
        "seq": _make_seq("Rubisco_mRNA_offtarget", 200, gc_bias=0.45),
    },
}


# ============================================================================
# Read builders
# ============================================================================

def read_reference(path):
    with open(path) as f:
        lines = f.readlines()
    return "".join(l.strip() for l in lines if not l.startswith(">")).upper()


def build_walk_read(ref_seq, pos, match_len, clip_len, forced_stop_offset):
    """Build a read with a walk-correctable right-clip.

    The clip is the reference with all C→T (editing).  A forced non-CT
    mismatch at forced_stop_offset halts the walk at a known point.
    If forced_stop_offset is None, the walk runs to the end (full correction).

    Returns (seq, cigar, expected_cigar, variant_positions).
    """
    clip_start = (pos - 1) + match_len
    clip_end = clip_start + clip_len

    aligned_seq = ref_seq[pos - 1 : pos - 1 + match_len]
    clip_ref = ref_seq[clip_start:clip_end]

    # Convert all C→T in the clip (simulates RNA editing)
    clip_seq = list(clip_ref)
    variant_positions = []
    for i, base in enumerate(clip_ref):
        if base == "C":
            clip_seq[i] = "T"
            variant_positions.append(clip_start + i + 1)  # 1-based

    # Insert forced stop: change base to something that doesn't match ref
    if forced_stop_offset is not None:
        ref_base = clip_ref[forced_stop_offset]
        alts = [b for b in "ACGT" if b != ref_base and not (ref_base == "C" and b == "T")]
        clip_seq[forced_stop_offset] = alts[0]
        walk_ext = forced_stop_offset
    else:
        walk_ext = clip_len

    clip_seq = "".join(clip_seq)
    remaining = clip_len - walk_ext

    orig_cigar = f"{match_len}M{clip_len}S"
    if remaining > 0:
        expected_cigar = f"{match_len + walk_ext}M{remaining}S"
    else:
        expected_cigar = f"{match_len + walk_ext}M"

    return aligned_seq + clip_seq, orig_cigar, expected_cigar, variant_positions


def build_clip_read(ref_seq, pos, match_len, clip_content):
    """Build a read with a right-clip of arbitrary content."""
    aligned_seq = ref_seq[pos - 1 : pos - 1 + match_len]
    cigar = f"{match_len}M{len(clip_content)}S"
    return aligned_seq + clip_content, cigar


def build_control_read(ref_seq, pos, match_len):
    """Build a read with no right-clip (pure alignment)."""
    seq = ref_seq[pos - 1 : pos - 1 + match_len]
    return seq, f"{match_len}M"


# ============================================================================
# Main
# ============================================================================

def main():
    ref_seq = read_reference(REF_FASTA)
    print(f"Reference: {REF_NAME} ({len(ref_seq)}bp)")

    os.makedirs(OUT_DIR, exist_ok=True)

    # ------------------------------------------------------------------
    # Walk-correctable reads (8)
    # Each demonstrates a different correction length.  The clip region
    # is the reference with C→T editing; the walk extends through these
    # known variants until hitting a forced mismatch (or end of clip).
    # ------------------------------------------------------------------
    walk_specs = [
        # (name,              pos, match, clip_len, forced_stop)
        ("walk_short",          1,  500,    55,       12),
        ("walk_medium",         1,  400,    80,       30),
        ("walk_long",           1,  300,   120,       60),
        ("walk_full",           1,  450,    60,     None),  # full correction
        ("walk_dense",          1,  350,    70,       25),
        ("walk_from_50",       50,  400,    65,       20),
        ("walk_extend_45",      1,  500,    80,       45),
        ("walk_minimal",        1,  600,    55,        8),
    ]

    walk_reads = []
    all_variants = []
    for name, pos, ml, cl, stop in walk_specs:
        seq, cigar, expected, vpos = build_walk_read(ref_seq, pos, ml, cl, stop)
        walk_reads.append((f"{name};ubs=8", str(pos), cigar, seq, expected))
        all_variants.extend(vpos)

    all_variants = sorted(set(all_variants))

    # ------------------------------------------------------------------
    # ChrM translocation reads (4)
    # Right-clips are fragments of mitochondrial gene sequences.
    # BLAST identifies them as organelle DNA → TL:i:1 in corrected.sam.
    # ------------------------------------------------------------------
    cox1 = CHRM_SEQUENCES["mock_ChrM_cox1"]["seq"]
    nad1 = CHRM_SEQUENCES["mock_ChrM_nad1"]["seq"]

    chrm_specs = [
        # (name,              pos, match, source_gene, source_name, slice)
        ("chrm_cox1_head",      1,  400,  cox1,  "cox1",  (0, 80)),
        ("chrm_cox1_tail",     50,  350,  cox1,  "cox1",  (100, 190)),
        ("chrm_nad1_head",      1,  450,  nad1,  "nad1",  (0, 70)),
        ("chrm_nad1_mid",     100,  300,  nad1,  "nad1",  (50, 130)),
    ]

    chrm_reads = []
    for name, pos, ml, gene_seq, gene_name, (s, e) in chrm_specs:
        clip = gene_seq[s:e]
        seq, cigar = build_clip_read(ref_seq, pos, ml, clip)
        chrm_reads.append((f"{name};ubs=8", str(pos), cigar, seq, gene_name, s, e))

    # ------------------------------------------------------------------
    # Chimeric reads (4)
    # Right-clips are fragments of abundant transcripts (rRNA, off-target
    # mRNA).  BLAST identifies them as non-target cDNA → moved to
    # chimeric_rightclip.sam and excluded from corrected.sam.
    # ------------------------------------------------------------------
    rrna18 = CDNA_SEQUENCES["mock_rRNA_18S"]["seq"]
    rrna28 = CDNA_SEQUENCES["mock_rRNA_28S"]["seq"]
    rubisco = CDNA_SEQUENCES["mock_mRNA_Rubisco"]["seq"]

    chimeric_specs = [
        # (name,                pos, match, source_seq, source_name, slice)
        ("chimeric_18S_head",     1,  400,  rrna18,  "18S",     (0, 80)),
        ("chimeric_18S_mid",     50,  350,  rrna18,  "18S",     (80, 155)),
        ("chimeric_28S",          1,  350,  rrna28,  "28S",     (0, 80)),
        ("chimeric_Rubisco",    100,  300,  rubisco, "Rubisco", (0, 70)),
    ]

    chimeric_reads = []
    for name, pos, ml, src_seq, src_name, (s, e) in chimeric_specs:
        clip = src_seq[s:e]
        seq, cigar = build_clip_read(ref_seq, pos, ml, clip)
        chimeric_reads.append((f"{name};ubs=8", str(pos), cigar, seq, src_name, s, e))

    # ------------------------------------------------------------------
    # Poly-A tail reads (4)
    # Right-clips are poly-A tails — no BLAST hit.
    # Retained in corrected.sam with TL:i:0.
    # ------------------------------------------------------------------
    polya_specs = [
        # (name,          pos, match, tail_len)
        ("polya_150",       1,  300,   150),
        ("polya_80",       50,  400,    80),
        ("polya_60",        1,  500,    60),
        ("polya_100",     100,  350,   100),
    ]

    polya_reads = []
    for name, pos, ml, tail in polya_specs:
        seq, cigar = build_clip_read(ref_seq, pos, ml, "A" * tail)
        polya_reads.append((f"{name};ubs=8", str(pos), cigar, seq))

    # ------------------------------------------------------------------
    # Unidentified clip reads (4)
    # Random right-clips that don't match any BLAST database.
    # Retained in corrected.sam (unknown contamination/artifact).
    # ------------------------------------------------------------------
    unid_specs = [
        # (name,              pos, match, clip_len)
        ("unid_clip_70",        1,  500,    70),
        ("unid_clip_90",       50,  400,    90),
        ("unid_clip_55",      100,  350,    55),
        ("unid_clip_110",       1,  450,   110),
    ]

    # Use seeded RNG for deterministic but non-matching clips
    clip_rng = random.Random("unidentified_clips")
    unid_reads = []
    for name, pos, ml, cl in unid_specs:
        clip = "".join(clip_rng.choice("ACGT") for _ in range(cl))
        seq, cigar = build_clip_read(ref_seq, pos, ml, clip)
        unid_reads.append((f"{name};ubs=8", str(pos), cigar, seq))

    # ------------------------------------------------------------------
    # Control reads (8)
    # No right-clip — pure alignments that pass through unchanged.
    # ------------------------------------------------------------------
    ctrl_specs = [
        # (name,          pos, match)
        ("control_600",     1,  600),
        ("control_500",    50,  500),
        ("control_400",   100,  400),
        ("control_300",   200,  300),
        ("control_700",     1,  700),
        ("control_250",   150,  250),
        ("control_350",     1,  350),
        ("control_200",   300,  200),
    ]

    control_reads = []
    for name, pos, ml in ctrl_specs:
        seq, cigar = build_control_read(ref_seq, pos, ml)
        control_reads.append((f"{name};ubs=8", str(pos), cigar, seq))

    # ==================================================================
    # Write SAM
    # ==================================================================
    sam_dir = os.path.join(OUT_DIR, "07_map", "barcode_blast", "barcode_blast_RPI_1")
    os.makedirs(sam_dir, exist_ok=True)
    sam_path = os.path.join(sam_dir, "mapped_only.sam")

    with open(sam_path, "w") as f:
        # SAM header (all @-lines must precede alignment records)
        f.write(f"@HD\tVN:1.6\tSO:coordinate\n")
        f.write(f"@SQ\tSN:{REF_NAME}\tLN:{len(ref_seq)}\n")
        f.write(f"@CO\tBLAST test data: 32 reads (8 walk + 4 ChrM + 4 chimeric + 4 polyA + 4 unid + 8 control)\n")
        f.write(f"@CO\tWalk-correctable reads: CIGAR extended through C>T edits\n")
        f.write(f"@CO\tChrM translocation reads: right-clip matches organelle DB\n")
        f.write(f"@CO\tChimeric reads: right-clip matches cDNA/rRNA DB\n")
        f.write(f"@CO\tPoly-A reads: no BLAST hit, retained\n")
        f.write(f"@CO\tUnidentified clip reads: no BLAST hit, retained\n")
        f.write(f"@CO\tControl reads: no right-clip, pass through\n")

        # Alignment records
        for qname, pos, cigar, seq, *_ in walk_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")
        for qname, pos, cigar, seq, *_ in chrm_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")
        for qname, pos, cigar, seq, *_ in chimeric_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")
        for qname, pos, cigar, seq in polya_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")
        for qname, pos, cigar, seq in unid_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")
        for qname, pos, cigar, seq in control_reads:
            f.write(f"{qname}\t0\t{REF_NAME}\t{pos}\t60\t{cigar}\t*\t0\t0\t{seq}\t*\n")

    # Create sorted BAM + index
    bam_path = os.path.join(sam_dir, "aligned.bam")
    sort_path = os.path.join(sam_dir, "aligned.sort.bam")
    subprocess.run(f"samtools view -bS {sam_path} > {bam_path}",
                   shell=True, capture_output=True)
    subprocess.run(f"samtools sort {bam_path} > {sort_path}",
                   shell=True, capture_output=True)
    subprocess.run(f"samtools index {sort_path}",
                   shell=True, capture_output=True)

    # ==================================================================
    # Write variant file
    # ==================================================================
    var_dir = os.path.join(OUT_DIR, "08_variants", "barcode_blast", "barcode_blast_RPI_1")
    os.makedirs(var_dir, exist_ok=True)
    with open(os.path.join(var_dir, "observed_variants.txt"), "w") as f:
        for vpos in all_variants:
            f.write(f"{vpos}CT\n")

    # ==================================================================
    # Write mock BLAST database FASTAs
    # ==================================================================
    chrm_dir = os.path.join(BLAST_DIR, "mock_chrm")
    cdna_dir = os.path.join(BLAST_DIR, "mock_cdna")
    os.makedirs(chrm_dir, exist_ok=True)
    os.makedirs(cdna_dir, exist_ok=True)

    with open(os.path.join(chrm_dir, "mock_chrm.fasta"), "w") as f:
        for name, info in CHRM_SEQUENCES.items():
            f.write(f">{name} {info['desc']}\n{info['seq']}\n")

    with open(os.path.join(cdna_dir, "mock_cdna.fasta"), "w") as f:
        for name, info in CDNA_SEQUENCES.items():
            f.write(f">{name} {info['desc']}\n{info['seq']}\n")

    # ==================================================================
    # Write expected CIGARs
    # ==================================================================
    with open(os.path.join(OUT_DIR, "expected_cigars.txt"), "w") as f:
        for qname, pos, cigar, seq, expected in walk_reads:
            f.write(f"{qname}\t{cigar}\t{expected}\n")

    # ==================================================================
    # Summary
    # ==================================================================
    total = len(walk_reads) + len(chrm_reads) + len(chimeric_reads) + \
            len(polya_reads) + len(unid_reads) + len(control_reads)

    print(f"\nOutput: {OUT_DIR}")
    print(f"SAM: {sam_path} ({total} reads)")
    print(f"Variant file: {len(all_variants)} CT positions")

    # --- Walk correction table ---
    print(f"\n{'='*72}")
    print(f"  Walk-Correctable Reads ({len(walk_reads)})")
    print(f"  Clip = reference with C→T edits; walk extends through known variants")
    print(f"{'='*72}")
    print(f"  {'Read':<22} {'Pos':>4}  {'Original':>12} → {'Corrected':>12}  {'Extension':>6}")
    print(f"  {'-'*22} {'-'*4}  {'-'*12}   {'-'*12}  {'-'*6}")
    for qname, pos, cigar, seq, expected in walk_reads:
        name = qname.split(";")[0]
        orig_m = int(cigar.split("M")[0])
        exp_m = int(expected.split("M")[0])
        ext = exp_m - orig_m
        print(f"  {name:<22} {pos:>4}  {cigar:>12} → {expected:>12}  +{ext}bp")

    # --- BLAST decision tree ---
    print(f"\n{'='*72}")
    print(f"  BLAST Decision Tree — How right-clips are classified")
    print(f"{'='*72}")
    print(f"  {'Read':<24} {'Clip':>5} {'Source':<30} {'Decision'}")
    print(f"  {'-'*24} {'-'*5} {'-'*30} {'-'*25}")

    for qname, pos, cigar, seq, gene, s, e in chrm_reads:
        name = qname.split(";")[0]
        clip_len = int(cigar.split("M")[1].rstrip("S"))
        src = f"ChrM {gene} [{s}:{e}]"
        print(f"  {name:<24} {clip_len:>3}bp {src:<30} TL:i:1 (organelle)")

    for qname, pos, cigar, seq, src_name, s, e in chimeric_reads:
        name = qname.split(";")[0]
        clip_len = int(cigar.split("M")[1].rstrip("S"))
        src = f"cDNA {src_name} [{s}:{e}]"
        print(f"  {name:<24} {clip_len:>3}bp {src:<30} → chimeric_rightclip.sam")

    for qname, pos, cigar, seq in polya_reads:
        name = qname.split(";")[0]
        clip_len = int(cigar.split("M")[1].rstrip("S"))
        print(f"  {name:<24} {clip_len:>3}bp {'poly-A tail':<30} TL:i:0 (retained)")

    for qname, pos, cigar, seq in unid_reads:
        name = qname.split(";")[0]
        clip_len = int(cigar.split("M")[1].rstrip("S"))
        print(f"  {name:<24} {clip_len:>3}bp {'random (no hit)':<30} retained (unknown)")

    for qname, pos, cigar, seq in control_reads:
        name = qname.split(";")[0]
        print(f"  {name:<24}   0bp {'— no clip —':<30} pass through")

    # --- Right-clip → database alignment demo ---
    print(f"\n{'='*72}")
    print(f"  Right-Clip Sequence Alignment Demo")
    print(f"  Showing how BLAST matches clips to database entries")
    print(f"{'='*72}")

    # Show one ChrM example in detail
    demo_read = chrm_reads[0]
    demo_name = demo_read[0].split(";")[0]
    demo_gene = demo_read[4]
    demo_s, demo_e = demo_read[5], demo_read[6]
    demo_clip = CHRM_SEQUENCES[f"mock_ChrM_{demo_gene}"]["seq"][demo_s:demo_e]
    demo_db = CHRM_SEQUENCES[f"mock_ChrM_{demo_gene}"]["seq"]

    print(f"\n  Example: {demo_name}")
    print(f"  Right-clip ({len(demo_clip)}bp) = mock_ChrM_{demo_gene}[{demo_s}:{demo_e}]")
    print(f"")
    print(f"  Database:  ...{demo_db[max(0,demo_s-5):demo_s]}[{demo_clip[:40]}...]")
    print(f"  Clip:       {'':>{max(0,demo_s-5)+3}}[{demo_clip[:40]}...]")
    print(f"               {'':>{max(0,demo_s-5)+3}}{'|'*min(40, len(demo_clip))}")
    print(f"  → BLAST hit to mock_ChrM_{demo_gene} → TL:i:1 (translocation)")

    # Show one chimeric example
    demo2 = chimeric_reads[0]
    demo2_name = demo2[0].split(";")[0]
    demo2_src = demo2[4]
    demo2_s, demo2_e = demo2[5], demo2[6]
    db_name = {
        "18S": "mock_rRNA_18S",
        "28S": "mock_rRNA_28S",
        "Rubisco": "mock_mRNA_Rubisco",
    }[demo2_src]
    demo2_clip = CDNA_SEQUENCES[db_name]["seq"][demo2_s:demo2_e]
    demo2_db = CDNA_SEQUENCES[db_name]["seq"]

    print(f"\n  Example: {demo2_name}")
    print(f"  Right-clip ({len(demo2_clip)}bp) = {db_name}[{demo2_s}:{demo2_e}]")
    print(f"")
    print(f"  Database:  ...{demo2_db[max(0,demo2_s-5):demo2_s]}[{demo2_clip[:40]}...]")
    print(f"  Clip:       {'':>{max(0,demo2_s-5)+3}}[{demo2_clip[:40]}...]")
    print(f"               {'':>{max(0,demo2_s-5)+3}}{'|'*min(40, len(demo2_clip))}")
    print(f"  → BLAST hit to {db_name} (cDNA) → chimeric_rightclip.sam")

    # --- BLAST database contents ---
    print(f"\n{'='*72}")
    print(f"  Mock BLAST Database Contents")
    print(f"{'='*72}")

    print(f"\n  Organelle DB ({chrm_dir}):")
    for name, info in CHRM_SEQUENCES.items():
        seq = info["seq"]
        at_pct = (seq.count("A") + seq.count("T")) / len(seq) * 100
        print(f"    {name} ({len(seq)}bp, AT={at_pct:.0f}%)")
        print(f"      {info['desc']}")
        print(f"      5' {seq[:50]}...")

    print(f"\n  Transcript DB ({cdna_dir}):")
    for name, info in CDNA_SEQUENCES.items():
        seq = info["seq"]
        gc_pct = (seq.count("G") + seq.count("C")) / len(seq) * 100
        print(f"    {name} ({len(seq)}bp, GC={gc_pct:.0f}%)")
        print(f"      {info['desc']}")
        print(f"      5' {seq[:50]}...")

    print(f"\nDone. ({total} reads, {len(all_variants)} variant positions)")


if __name__ == "__main__":
    main()
