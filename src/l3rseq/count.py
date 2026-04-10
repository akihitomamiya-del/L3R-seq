"""L3Rseq step 11 gene counting — pysam-backed port of scripts/11_count.sh.

Counts UMI-consensus molecules per gene region from mapped BAMs, discovers
splice isoforms from CIGAR N operations, and delegates aggregation (isoform
discovery + housekeeping normalization) to the existing awk helpers in
``scripts/11_count.sh``.

Architecture (mirrors ``tail_correct.py``):

- :func:`compute_region_overlap` and :func:`extract_splice_pattern` are
  pure functions operating on CIGAR tuples + integer coordinates.  No
  pysam, no I/O — fully unit-testable.
- :func:`count_gene_reads` is the pysam wrapper: fetches reads in a
  region, walks each CIGAR, accumulates counts and patterns.
- :func:`count_directory` is the orchestrator iterating samples × genes.
- :func:`main` is the CLI entry (``python -m l3rseq.count``).
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import pysam

_LOG = logging.getLogger("l3rseq.count")

# ---------------------------------------------------------------------------
# Region data
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Region:
    """A single gene region from a regions TSV file."""

    name: str
    chrom: str
    start: int  # 1-based inclusive
    end: int    # 1-based inclusive

    @property
    def length(self) -> int:
        return self.end - self.start + 1


def load_regions(path: Path) -> list[Region]:
    """Load regions TSV (gene, chr, start, end, [strand, source]).

    Skips comment lines (``#...``), the ``gene`` header variant, and blank
    lines — mirroring ``scripts/11_count.sh:131-139``.
    """
    regions: list[Region] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if parts[0] == "gene":
                continue  # non-# header variant
            if len(parts) < 4:
                continue
            regions.append(Region(
                name=parts[0],
                chrom=parts[1],
                start=int(parts[2]),
                end=int(parts[3]),
            ))
    return regions


# ---------------------------------------------------------------------------
# Pure CIGAR overlap + splice extraction (no pysam imports needed)
# ---------------------------------------------------------------------------

# CIGAR ops as (length, op_char) tuples — the same representation pysam
# uses when you iterate ``read.cigartuples`` (but with char, not int code).
# We accept ``list[tuple[int, str]]`` for pure-function testability and
# convert from pysam's ``(op_code, length)`` tuples at the call site.

# CIGAR op characters that consume reference positions.
_REF_CONSUMING = frozenset("MDN=X")
# Subset that also counts toward gene-region overlap (N does NOT).
_OVERLAP_OPS = frozenset("MD=X")


def compute_region_overlap(
    cigar_ops: list[tuple[int, str]],
    aln_start: int,
    region_start: int,
    region_end: int,
) -> int:
    """Compute bases of *cigar_ops* that overlap [region_start, region_end].

    Mirrors the awk CIGAR walk in ``scripts/11_count.sh:55-71``:
    - M, D, =, X advance ``rpos`` and contribute to overlap.
    - N advances ``rpos`` but contributes **zero** overlap (intron skip).
    - I, S, H, P do not move on the reference.

    All coordinates are 1-based inclusive (matching SAM POS convention).
    """
    overlap = 0
    rpos = aln_start
    for length, op in cigar_ops:
        if op in _OVERLAP_OPS:
            # Block covers rpos .. rpos + length - 1 on the reference.
            ov_s = max(rpos, region_start)
            ov_e = min(rpos + length - 1, region_end)
            if ov_e >= ov_s:
                overlap += ov_e - ov_s + 1
            rpos += length
        elif op == "N":
            rpos += length
        # I, S, H, P: no reference movement
    return overlap


def extract_splice_pattern(
    cigar_ops: list[tuple[int, str]],
    aln_start: int,
) -> str:
    """Extract splice (N-op) pattern from CIGAR.

    Returns ``"none"`` if no N operations, or a comma-separated string of
    ``"<rpos>:<N_len>"`` entries — mirroring ``scripts/11_count.sh:76-82``.
    """
    parts: list[str] = []
    rpos = aln_start
    for length, op in cigar_ops:
        if op == "N":
            parts.append(f"{rpos}:{length}")
        if op in _REF_CONSUMING:
            rpos += length
    return ",".join(parts) if parts else "none"


# ---------------------------------------------------------------------------
# pysam helpers — convert CIGAR tuple format
# ---------------------------------------------------------------------------

# pysam uses (op_code, length); we use (length, op_char).
_PYSAM_OP_TO_CHAR = "MIDNSHP=X"


def _pysam_cigar_to_ops(cigartuples: list[tuple[int, int]]) -> list[tuple[int, str]]:
    """Convert pysam's ``(op_code, length)`` tuples to ``(length, op_char)``."""
    return [(length, _PYSAM_OP_TO_CHAR[op]) for op, length in cigartuples]


# ---------------------------------------------------------------------------
# Per-gene counting (pysam wrapper)
# ---------------------------------------------------------------------------

@dataclass
class GeneCountResult:
    """Result of counting reads for a single gene region in one sample."""

    total: int = 0
    patterns: Counter[str] = field(default_factory=Counter)


def count_gene_reads(
    bam_path: str | Path,
    region: Region,
    min_frac: float,
    min_mapq: int,
) -> GeneCountResult:
    """Count primary alignments overlapping *region* by >= *min_frac*.

    Mirrors ``scripts/11_count.sh:22-91`` (count_gene_reads bash function).
    """
    result = GeneCountResult()
    try:
        with pysam.AlignmentFile(str(bam_path), "rb") as bam:
            for read in bam.fetch(region.chrom, region.start - 1, region.end):
                # Exclude unmapped, secondary, supplementary (matches -F 0x904)
                if read.is_unmapped or read.is_secondary or read.is_supplementary:
                    continue
                if read.mapping_quality < min_mapq:
                    continue
                if read.cigartuples is None:
                    continue

                ops = _pysam_cigar_to_ops(read.cigartuples)
                aln_start = read.reference_start + 1  # pysam is 0-based

                overlap = compute_region_overlap(
                    ops, aln_start, region.start, region.end,
                )
                frac = overlap / region.length
                if frac >= min_frac:
                    pattern = extract_splice_pattern(ops, aln_start)
                    result.patterns[pattern] += 1
                    result.total += 1
    except (ValueError, OSError):
        # Region chromosome not in BAM, or BAM unreadable — mirror bash's
        # `{ samtools view ... || true; }` graceful empty-result behavior.
        pass
    return result


# ---------------------------------------------------------------------------
# Coverage generation (pysam.depth wrapper)
# ---------------------------------------------------------------------------

def generate_coverage(
    bam_path: str | Path,
    region: Region,
    outfile: Path,
) -> None:
    """Write per-base depth for *region* to *outfile*.

    Mirrors ``scripts/11_count.sh:96-105`` (generate_coverage).
    Uses ``pysam.depth()`` which produces the same 3-column TSV as
    ``samtools depth -a -r ...``.
    """
    region_str = f"{region.chrom}:{region.start}-{region.end}"
    try:
        raw = pysam.depth(
            "-a", "-r", region_str, str(bam_path),
        )
        depth_output: str = raw if isinstance(raw, str) else str(raw)
        outfile.write_text(depth_output)
    except (pysam.SamtoolsError, Exception):  # type: ignore[attr-defined]
        # Missing chromosome or unreadable BAM — write empty file (matches
        # bash's `samtools depth ... || true` behavior).
        outfile.write_text("")


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def count_directory(
    map_dir: Path,
    output_dir: Path,
    regions: list[Region],
    min_frac: float,
    min_mapq: int,
    housekeeping: str,
    scripts_dir: Path | None = None,
) -> None:
    """Iterate all barcode/rpi samples and count gene reads.

    Mirrors ``scripts/11_count.sh:110-255`` (run_step_11).
    """
    count_dir = output_dir / "11_count"
    cov_dir = count_dir / "coverage"
    count_dir.mkdir(parents=True, exist_ok=True)
    cov_dir.mkdir(parents=True, exist_ok=True)

    # BAM source: prefer 09_correct, fallback 07_map
    map_base: Path | None = None
    bam_suffix = "primary.sort.bam"
    if (map_dir / "09_correct").is_dir():
        map_base = map_dir / "09_correct"
        bam_suffix = "corrected.sort.bam"
    elif (map_dir / "07_map").is_dir():
        map_base = map_dir / "07_map"
    elif map_dir.is_dir():
        # Flat layout — check for any sort.bam files
        if list(map_dir.glob("*/*.sort.bam")):
            map_base = map_dir
    if map_base is None:
        _LOG.error("No 09_correct or 07_map directory found in %s", map_dir)
        sys.exit(1)

    # Merged output
    merged_file = count_dir / "gene_counts_all.tsv"
    with open(merged_file, "w") as merged_fh:
        merged_fh.write("gene\tsample\ttotal_count\tsplice_pattern\tpattern_count\n")

        sample_count = 0
        for barcode_dir in sorted(map_base.iterdir()):
            if not barcode_dir.is_dir():
                continue
            bname = barcode_dir.name

            for rpi_dir in sorted(barcode_dir.iterdir()):
                if not rpi_dir.is_dir():
                    continue
                rpi_name = rpi_dir.name

                bam_path = rpi_dir / f"{rpi_name}_{bam_suffix}"
                if not bam_path.exists():
                    _LOG.warning(
                        "No %s_%s in %s/%s, skipping",
                        rpi_name, bam_suffix, bname, rpi_name,
                    )
                    continue

                sample_id = f"{bname}/{rpi_name}"
                _LOG.info("  Counting %s ...", sample_id)
                sample_count += 1

                # Per-sample output
                sample_file = count_dir / f"{bname}_{rpi_name}_gene_counts.tsv"
                with open(sample_file, "w") as sfh:
                    sfh.write("#gene\tchr\tstart\tend\ttotal_count\tsplice_patterns\n")

                    for region in regions:
                        result = count_gene_reads(
                            bam_path, region, min_frac, min_mapq,
                        )

                        # Merged file — per-pattern rows
                        if result.total > 0:
                            for pattern, pcount in result.patterns.items():
                                merged_fh.write(
                                    f"{region.name}\t{sample_id}\t"
                                    f"{result.total}\t{pattern}\t{pcount}\n"
                                )
                        else:
                            merged_fh.write(
                                f"{region.name}\t{sample_id}\t0\tnone\t0\n"
                            )

                        # Per-sample file — one row per gene
                        patterns_str = ",".join(
                            f"{p}:{c}" for p, c in result.patterns.items()
                        ) if result.patterns else "none:0"
                        sfh.write(
                            f"{region.name}\t{region.chrom}\t{region.start}\t"
                            f"{region.end}\t{result.total}\t{patterns_str}\n"
                        )

                        # Coverage
                        generate_coverage(
                            bam_path, region,
                            cov_dir / f"{bname}_{rpi_name}_{region.name}.depth.tsv",
                        )

    if sample_count == 0:
        _LOG.warning("No samples found with BAMs in %s", map_base)
        return

    _LOG.info("  Counted %d sample(s) x %d gene(s)", sample_count, len(regions))

    # --- Aggregation helpers (delegated to bash awk functions) ---
    if scripts_dir is None:
        scripts_dir = Path(__file__).resolve().parent.parent.parent / "scripts"

    iso_file = count_dir / "isoform_discovery.tsv"
    _run_bash_helper(
        scripts_dir, "_generate_isoform_discovery",
        str(merged_file), str(iso_file),
    )

    if housekeeping:
        norm_file = count_dir / "gene_counts_normalized.tsv"
        _run_bash_helper(
            scripts_dir, "_normalize_counts",
            str(merged_file), housekeeping, str(norm_file),
        )


def _run_bash_helper(
    scripts_dir: Path,
    func_name: str,
    *args: str,
) -> None:
    """Shell out to a bash function in scripts/11_count.sh."""
    # Stub _summary_append + source lib.sh prerequisites
    cmd = (
        f"_summary_append() {{ :; }}; "
        f"source '{scripts_dir}/lib.sh' 2>/dev/null || true; "
        f"source '{scripts_dir}/11_count.sh' && "
        f"{func_name} {' '.join(repr(a) for a in args)}"
    )
    subprocess.run(["bash", "-c", cmd], check=True)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> int:
    """CLI for ``python -m l3rseq.count``."""
    parser = argparse.ArgumentParser(
        prog="python -m l3rseq.count",
        description="Step 11 gene counting — pysam-backed port of scripts/11_count.sh",
    )
    parser.add_argument("--input", required=True, dest="input_dir",
                        help="Input dir (parent of 09_correct/ or 07_map/)")
    parser.add_argument("--outdir", required=True,
                        help="Output dir (11_count/ created inside)")
    parser.add_argument("--regions", required=True,
                        help="Regions TSV file (from L3Rseq regions)")
    parser.add_argument("--min-frac", type=float, default=0.95,
                        help="Min fractional overlap to count a read (default: 0.95)")
    parser.add_argument("--min-mapq", type=int, default=0,
                        help="Min mapping quality (default: 0)")
    parser.add_argument("--housekeeping", default="",
                        help="Comma-separated housekeeping gene names for normalization")
    parser.add_argument("--scripts-dir", default=None,
                        help="Path to scripts/ dir (for bash aggregation helpers)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Enable DEBUG logging")

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="[%(name)s] %(message)s",
    )

    regions = load_regions(Path(args.regions))
    if not regions:
        _LOG.error("No regions found in %s", args.regions)
        return 1

    _LOG.info("[Step 11py] Gene counting (python orchestrator)")
    _LOG.info("  Loaded %d gene region(s)", len(regions))

    scripts_path = Path(args.scripts_dir) if args.scripts_dir else None

    count_directory(
        map_dir=Path(args.input_dir),
        output_dir=Path(args.outdir),
        regions=regions,
        min_frac=args.min_frac,
        min_mapq=args.min_mapq,
        housekeeping=args.housekeeping,
        scripts_dir=scripts_path,
    )

    _LOG.info("[Step 11py] Done. Output in %s/11_count", args.outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
