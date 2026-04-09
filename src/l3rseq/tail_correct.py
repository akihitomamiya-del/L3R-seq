"""Orchestrator for L3Rseq step 09 tail correction (Phase 1b rewrite).

Replaces ``scripts/09_tail_correct.sh`` + subscripts 09a/09c/09d/09e/09f.
The bash per-read subprocess spawn loop (which dominates runtime per
``docs/step09_baseline.md``) becomes an in-process pysam iteration at
htslib speed.

Architecture:

- :func:`compute_correction` is a pure function taking strings and
  algorithm-module results, returning a :class:`CorrectionResult`. No
  pysam, no I/O — fully unit-testable.
- :func:`tail_correct_sample` is the pysam wrapper for one sample:
  opens the input SAM, runs a BLAST pre-pass, iterates reads, and
  writes corrected + chimeric output BAMs.
- :func:`tail_correct_directory` iterates ``{barcode}/{rpi}/`` samples.
- :func:`main` is the CLI entry point (``python -m l3rseq.tail_correct``).
"""

from __future__ import annotations

import argparse
import logging
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

import pysam

from l3rseq.blast import BatchBlastResult, run_batch_blast
from l3rseq.cigar import parse_cigar, rebuild_cigar
from l3rseq.splice import Intron, check_splice, convert_intron_d_to_n, parse_introns
from l3rseq.tags import Step09TagValues, TagTuple, build_tags
from l3rseq.variants import call_variants
from l3rseq.walk import walk_correction

_LOG = logging.getLogger("l3rseq.tail_correct")

# ATGC-tail regex matching bash `grep -Eio "[ATGC]{N}$"` — case-insensitive
# but preserves original case in the captured text (matches -o behavior).
_ATGC_TAIL_RE = re.compile(r"^[ATGCatgc]+$")

#: M-op length extractor, matches ``grep -Eo '[0-9]+M'`` in the bash
#: per-read worker (``scripts/09_tail_correct.sh:213``).
_M_OP_RE = re.compile(r"(\d+)M")


class ReadKind(Enum):
    """Classification of a processed read."""

    CORRECTED = "corrected"
    CHIMERIC = "chimeric"


@dataclass(frozen=True)
class CorrectionResult:
    """Result of :func:`compute_correction`.

    Attributes:
        kind: Whether the read goes to the corrected or chimeric output.
        new_cigar: CIGAR string to set on the output read. For chimeric
            reads, this is the original CIGAR (unchanged).
        tags: Step-09 SAM tags as pysam tuples. For chimeric reads, an
            empty list (tags are stripped — matches the bash
            ``cut -f1-11`` at ``scripts/09_tail_correct.sh:175``).
    """

    kind: ReadKind
    new_cigar: str
    tags: list[TagTuple]


@dataclass(frozen=True)
class SampleStats:
    """Summary stats for one sample's tail correction run."""

    total_reads: int
    corrected_reads: int
    chimeric_reads: int
    blast_queries: int


# ============================================================================
# Pure computation (no pysam, no I/O) — unit-testable with strings only
# ============================================================================


def _sum_m_ops(cigar_str: str) -> int:
    """Sum the lengths of all M operations in a CIGAR string.

    Matches ``scripts/09_tail_correct.sh:213`` and
    ``09d_rebuild_cigar.sh:16`` which use
    ``grep -Eo '[0-9]+M' | grep -Eo '[0-9]+' | awk '{a+=$1}'``.
    """
    return sum(int(m) for m in _M_OP_RE.findall(cigar_str))


def _extract_rightclip_seq(query_sequence: str, new_tail_s: int) -> str:
    """Extract the remaining right-clip nucleotides.

    Matches ``scripts/09_tail_correct.sh:222-223``::

        rightclip_seq_new=$(echo "$seq" | grep -Eio "[ATGC]{$N}$" || true)

    Returns the last ``new_tail_s`` characters of the read sequence IF
    they are all in ``[ATGCatgc]``; otherwise returns an empty string
    (matching the bash ``|| true`` fallthrough on grep miss).
    """
    if new_tail_s <= 0:
        return ""
    tail = query_sequence[-new_tail_s:]
    if _ATGC_TAIL_RE.match(tail):
        return tail
    return ""


def compute_correction(
    *,
    cigar_str: str,
    query_seq: str,
    aln_start: int,
    ref_seq: str,
    known_variants: frozenset[str],
    pattern: str,
    count_pattern: str,
    introns: list[Intron],
    blast_chrm_hit: bool = False,
    blast_cdna_hit: bool = False,
) -> CorrectionResult:
    """Compute the step-09 correction for a single read.

    Pure function: given the strings and values from a SAM record, applies
    the walk / splice / variant algorithms from the :mod:`l3rseq.cigar`,
    :mod:`walk`, :mod:`variants`, :mod:`splice` modules and returns the
    new CIGAR plus the 13 step-09 SAM tags.

    Mirrors the per-read body of ``scripts/09_tail_correct.sh:93-240``.

    Args:
        cigar_str: The read's CIGAR string (from SAM field 6).
        query_seq: The read's nucleotide sequence (from SAM field 10).
        aln_start: 1-based alignment start (from SAM field 4 / pysam
            ``read.reference_start + 1``).
        ref_seq: Pre-loaded reference sequence as a single string.
        known_variants: Editing-variant mismatch strings to tolerate
            during walk correction.
        pattern: Primary editing pattern(s), comma-separated
            (e.g., ``"CT"``).
        count_pattern: Optional secondary count pattern (e.g., ``"TC"``).
        introns: Annotated introns for splice detection; empty list to
            skip the splice step entirely.
        blast_chrm_hit: True if this read's right-clip hit the ChrM
            BLAST DB (translocation → TL=1).
        blast_cdna_hit: True if this read's right-clip hit the cDNA
            BLAST DB (PCR chimera → route to chimeric output).

    Returns:
        :class:`CorrectionResult` with the new CIGAR and tag set.
    """
    parsed = parse_cigar(cigar_str)
    rightclip_n = parsed.rightclip_n
    total_m = parsed.total_m
    total_d = parsed.total_d

    # cDNA hit → PCR chimera. Strip tags, return as-is. Matches
    # scripts/09_tail_correct.sh:172-177.
    if blast_cdna_hit:
        return CorrectionResult(
            kind=ReadKind.CHIMERIC,
            new_cigar=cigar_str,
            tags=[],
        )

    translocation = 1 if blast_chrm_hit else 0

    if rightclip_n == 0:
        return _compute_no_clip(
            cigar_str=cigar_str,
            query_seq=query_seq,
            aln_start=aln_start,
            ref_seq=ref_seq,
            total_m=total_m,
            total_d=total_d,
            rightclip_n=rightclip_n,
            translocation=translocation,
            pattern=pattern,
            count_pattern=count_pattern,
            introns=introns,
        )

    # With right-clip: walk correct
    rightclip_seq = query_seq[-rightclip_n:]
    # Ref position of the first clipped base (1-based) — matches
    # scripts/09_tail_correct.sh:184.
    ref_position = aln_start - 1 + total_m + total_d + 1
    match_counter = walk_correction(
        ref_seq, ref_position, rightclip_seq, known_variants
    )

    new_cigar, new_tail_s = rebuild_cigar(cigar_str, match_counter)

    # Call variants on the read sequence using the corrected CIGAR
    variants = call_variants(
        query_seq, new_cigar, ref_seq, aln_start, pattern, count_pattern
    )

    # Splice check + D→N conversion on the corrected CIGAR
    splice_result = None
    final_cigar = new_cigar
    if introns:
        splice_result = check_splice(new_cigar, aln_start, introns)
        final_cigar = convert_intron_d_to_n(new_cigar, aln_start, introns)

    # Metrics use post-splice new_total_m + ORIGINAL total_d (matches
    # scripts/09_tail_correct.sh:213-216).
    new_total_m = _sum_m_ops(final_cigar)
    terminus = aln_start - 1 + new_total_m + total_d
    matched_length = new_total_m + total_d
    doublesorter = terminus * 10000 + new_tail_s

    remaining_clip_seq = _extract_rightclip_seq(query_seq, new_tail_s)

    values = Step09TagValues(
        terminus=terminus,
        remaining_clip_n=new_tail_s,
        remaining_clip_seq=remaining_clip_seq,
        translocation=translocation,
        doublesorter=doublesorter,
        ec=variants.ec,
        sc=variants.sc if count_pattern else None,
        nc=variants.nc,
        matched_length=matched_length,
        variants_str=variants.variants_str,
        splice=splice_result,
    )
    return CorrectionResult(
        kind=ReadKind.CORRECTED,
        new_cigar=final_cigar,
        tags=build_tags(values),
    )


def _compute_no_clip(
    *,
    cigar_str: str,
    query_seq: str,
    aln_start: int,
    ref_seq: str,
    total_m: int,
    total_d: int,
    rightclip_n: int,
    translocation: int,
    pattern: str,
    count_pattern: str,
    introns: list[Intron],
) -> CorrectionResult:
    """No-right-clip fast path. Matches scripts/09_tail_correct.sh:114-152."""
    variants = call_variants(
        query_seq, cigar_str, ref_seq, aln_start, pattern, count_pattern
    )

    splice_result = None
    final_cigar = cigar_str
    if introns:
        splice_result = check_splice(cigar_str, aln_start, introns)
        final_cigar = convert_intron_d_to_n(cigar_str, aln_start, introns)

    # Metrics use ORIGINAL total_m + total_d (no walk happened)
    terminus = aln_start - 1 + total_m + total_d
    matched_length = total_m + total_d
    doublesorter = terminus * 10000 + rightclip_n  # rightclip_n == 0 here

    values = Step09TagValues(
        terminus=terminus,
        remaining_clip_n=rightclip_n,
        remaining_clip_seq="",
        translocation=translocation,
        doublesorter=doublesorter,
        ec=variants.ec,
        sc=variants.sc if count_pattern else None,
        nc=variants.nc,
        matched_length=matched_length,
        variants_str=variants.variants_str,
        splice=splice_result,
    )
    return CorrectionResult(
        kind=ReadKind.CORRECTED,
        new_cigar=final_cigar,
        tags=build_tags(values),
    )


# ============================================================================
# pysam I/O wrapper
# ============================================================================


def _load_reference(ref_file: Path) -> str:
    """Load a reference FASTA into a single uppercase string.

    Matches ``scripts/09_tail_correct.sh:57`` which concatenates all
    non-header lines via awk. For multi-chromosome references, references
    are concatenated in FAI order.
    """
    with pysam.FastaFile(str(ref_file)) as fasta:
        return "".join(fasta.fetch(ref).upper() for ref in fasta.references)


def _load_variants(var_file: Path | None) -> frozenset[str]:
    """Load editing variants into a frozenset of mismatch strings.

    Each line of the variant file is a mismatch string of the form
    ``"<1-based-pos><ref><alt>"`` (e.g., ``"123CT"``). Empty lines and
    lines starting with ``#`` are ignored.
    """
    if var_file is None or not var_file.is_file():
        return frozenset()
    variants: set[str] = set()
    with var_file.open() as fh:
        for raw in fh:
            line = raw.strip()
            if line and not line.startswith("#"):
                variants.add(line)
    return frozenset(variants)


def _collect_blast_queries(
    input_sam_path: Path,
    clip_thresh: int,
) -> list[tuple[int, str]]:
    """First pass through the SAM: collect BLAST candidate queries.

    Returns a list of ``(read_idx, rightclip_seq)`` for reads with
    ``rightclip_n > clip_thresh``. ``read_idx`` is 1-based to match the
    bash ``Rightclip_<idx>`` numbering.
    """
    queries: list[tuple[int, str]] = []
    with pysam.AlignmentFile(str(input_sam_path), "r") as fin:
        for idx, read in enumerate(fin, start=1):
            if read.cigarstring is None or read.query_sequence is None:
                continue
            parsed = parse_cigar(read.cigarstring)
            if parsed.rightclip_n > clip_thresh:
                clip_seq = read.query_sequence[-parsed.rightclip_n :]
                queries.append((idx, clip_seq))
    return queries


def _preserve_blast_outputs(
    blast_result: BatchBlastResult,
    output_dir: Path,
    prefix: str,
) -> None:
    """Copy raw BLAST outputs into the sample output dir for inspection.

    Matches ``scripts/09_tail_correct.sh:461-469``.
    """
    if blast_result.query_fasta_path and blast_result.query_fasta_path.exists():
        shutil.copy(
            blast_result.query_fasta_path,
            output_dir / f"{prefix}blast_rightclip_queries.fa",
        )
    if blast_result.chrm_raw_path and blast_result.chrm_raw_path.exists():
        shutil.copy(
            blast_result.chrm_raw_path,
            output_dir / f"{prefix}blast_chrm_results.txt",
        )
    if blast_result.cdna_raw_path and blast_result.cdna_raw_path.exists():
        shutil.copy(
            blast_result.cdna_raw_path,
            output_dir / f"{prefix}blast_cdna_results.txt",
        )


def tail_correct_sample(
    *,
    input_sam_path: Path,
    output_dir: Path,
    ref_seq: str,
    known_variants: frozenset[str],
    pattern: str,
    count_pattern: str,
    clip_thresh: int,
    chrm_db: Path | None,
    cdna_db: Path | None,
    introns: list[Intron],
) -> SampleStats:
    """Process one sample's mapped_only SAM into corrected + chimeric BAMs.

    Mirrors the per-sample body of ``scripts/09_tail_correct.sh:246-478``.
    Single-threaded — per-read parallelism deferred until the differential
    test passes and the benchmark shows it's needed.
    """
    rpi_name = input_sam_path.parent.name
    prefix = f"{rpi_name}_"
    output_dir.mkdir(parents=True, exist_ok=True)

    corrected_sam = output_dir / f"{prefix}corrected.sam"
    corrected_bam = output_dir / f"{prefix}corrected.bam"
    corrected_sort = output_dir / f"{prefix}corrected.sort.bam"
    chimeric_sam = output_dir / f"{prefix}chimeric_rightclip.sam"
    chimeric_sort = output_dir / f"{prefix}chimeric_rightclip.sort.bam"

    # BLAST pre-pass
    with tempfile.TemporaryDirectory() as tmp_str:
        tmp_dir = Path(tmp_str)
        blast_queries = _collect_blast_queries(input_sam_path, clip_thresh)
        blast_result = run_batch_blast(
            blast_queries, chrm_db, cdna_db, tmp_dir
        )
        _preserve_blast_outputs(blast_result, output_dir, prefix)
        chrm_hits = blast_result.chrm_hits
        cdna_hits = blast_result.cdna_hits

    # Main pass: iterate reads, process, write both output SAMs
    corrected_count = 0
    chimeric_count = 0
    total = 0
    with pysam.AlignmentFile(str(input_sam_path), "r") as fin:
        with (
            pysam.AlignmentFile(str(corrected_sam), "w", template=fin) as fout,
            pysam.AlignmentFile(str(chimeric_sam), "w", template=fin) as fchim,
        ):
            for idx, read in enumerate(fin, start=1):
                total += 1
                if read.cigarstring is None or read.query_sequence is None:
                    continue

                result = compute_correction(
                    cigar_str=read.cigarstring,
                    query_seq=read.query_sequence,
                    aln_start=read.reference_start + 1,
                    ref_seq=ref_seq,
                    known_variants=known_variants,
                    pattern=pattern,
                    count_pattern=count_pattern,
                    introns=introns,
                    blast_chrm_hit=idx in chrm_hits,
                    blast_cdna_hit=idx in cdna_hits,
                )

                if result.kind == ReadKind.CHIMERIC:
                    read.set_tags([])
                    fchim.write(read)
                    chimeric_count += 1
                else:
                    if result.new_cigar != read.cigarstring:
                        read.cigarstring = result.new_cigar
                    read.set_tags(result.tags)
                    fout.write(read)
                    corrected_count += 1

    # Convert corrected SAM → BAM → sort → index (matches bash flow)
    pysam.view("-bS", "-o", str(corrected_bam), str(corrected_sam), catch_stdout=False)
    pysam.sort("-o", str(corrected_sort), str(corrected_bam))
    pysam.index(str(corrected_sort))

    # Chimeric BAM only if non-empty (check for non-header data rows)
    if chimeric_count > 0:
        pysam.sort("-o", str(chimeric_sort), str(chimeric_sam))
        pysam.index(str(chimeric_sort))

    return SampleStats(
        total_reads=total,
        corrected_reads=corrected_count,
        chimeric_reads=chimeric_count,
        blast_queries=len(blast_queries),
    )


def tail_correct_directory(
    *,
    input_dir: Path,
    output_dir: Path,
    ref_file: Path,
    var_file: Path | None,
    pattern: str,
    count_pattern: str,
    clip_thresh: int,
    chrm_db: Path | None,
    cdna_db: Path | None,
    variants_dir: Path | None,
    introns_spec: str,
) -> None:
    """Iterate all barcode/rpi samples in ``input_dir`` and correct each.

    Mirrors ``scripts/09_tail_correct.sh:246-480`` outer loop.
    """
    _LOG.info("[Step 09py] Tail correction (python orchestrator)")

    ref_seq = _load_reference(ref_file)
    _LOG.info("    Reference loaded: %dbp", len(ref_seq))

    introns = parse_introns(introns_spec)
    if introns:
        _LOG.info("    Intron annotations loaded: %d intron(s)", len(introns))

    correct_root = output_dir / "09_correct"
    correct_root.mkdir(parents=True, exist_ok=True)

    for barcode_dir in sorted(input_dir.iterdir()):
        if not barcode_dir.is_dir():
            continue
        bname = barcode_dir.name

        for rpi_dir in sorted(barcode_dir.iterdir()):
            if not rpi_dir.is_dir():
                continue
            rpi_name = rpi_dir.name

            input_sam = rpi_dir / f"{rpi_name}_mapped_only.sam"
            if not input_sam.is_file():
                _LOG.warning(
                    "    No %s in %s/%s, skipping (run step 07 first)",
                    input_sam.name,
                    bname,
                    rpi_name,
                )
                continue

            # Resolve the active variant file (explicit --var or auto-detect)
            active_var_file = var_file
            if active_var_file is None or not active_var_file.is_file():
                if variants_dir is not None:
                    candidate = (
                        variants_dir / bname / rpi_name / "observed_variants.txt"
                    )
                    if candidate.is_file():
                        active_var_file = candidate
                        _LOG.info("    Using detected variants: %s", candidate)
            known_variants = _load_variants(active_var_file)
            if active_var_file is None or not active_var_file.is_file():
                _LOG.info(
                    "    No variant file available -- correction "
                    "will not tolerate editing mismatches"
                )

            sample_output_dir = correct_root / bname / rpi_name
            _LOG.info("  Processing %s / %s ...", bname, rpi_name)

            stats = tail_correct_sample(
                input_sam_path=input_sam,
                output_dir=sample_output_dir,
                ref_seq=ref_seq,
                known_variants=known_variants,
                pattern=pattern,
                count_pattern=count_pattern,
                clip_thresh=clip_thresh,
                chrm_db=chrm_db,
                cdna_db=cdna_db,
                introns=introns,
            )
            _LOG.info(
                "    %d reads → %d corrected, %d chimeric (BLAST queries: %d)",
                stats.total_reads,
                stats.corrected_reads,
                stats.chimeric_reads,
                stats.blast_queries,
            )

    _LOG.info("[Step 09py] Done. Output in %s", correct_root)


# ============================================================================
# CLI entry point
# ============================================================================


def main(argv: list[str] | None = None) -> int:
    """Command-line entry point — mirrors ``L3Rseq correct`` flags."""
    parser = argparse.ArgumentParser(
        prog="python -m l3rseq.tail_correct",
        description=(
            "Step 09 tail correction — pysam-based rewrite of "
            "scripts/09_tail_correct.sh"
        ),
    )
    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="Input dir containing {barcode}/{rpi}/ subdirs (the 07_map/ dir)",
    )
    parser.add_argument(
        "--outdir",
        required=True,
        type=Path,
        help="Output dir where 09_correct/ will be created",
    )
    parser.add_argument("--ref", required=True, type=Path, help="Reference FASTA")
    parser.add_argument(
        "--var",
        type=Path,
        default=None,
        help="Variant file (editing events to tolerate). Optional.",
    )
    parser.add_argument(
        "--variants-dir",
        type=Path,
        default=None,
        help="Directory with 08_variants output for per-sample auto-detect",
    )
    parser.add_argument(
        "--pattern",
        default="CT",
        help="Primary editing pattern(s), comma-separated (default: CT)",
    )
    parser.add_argument(
        "--count-pattern",
        default="",
        help="Optional secondary count pattern (e.g., TC for SLAM)",
    )
    parser.add_argument(
        "--clip-thresh",
        type=int,
        default=50,
        help="Min soft-clip length to trigger BLAST (default: 50)",
    )
    parser.add_argument(
        "--blast-db",
        type=Path,
        default=None,
        help="ChrM BLAST database path (without extension)",
    )
    parser.add_argument(
        "--blast-db2",
        type=Path,
        default=None,
        help="cDNA BLAST database path (without extension)",
    )
    parser.add_argument(
        "--introns", default="", help="Intron spec (shorthand, BED, or GFF3)"
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=1,
        help="Worker threads (currently unused; single-threaded)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable DEBUG logging"
    )

    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="[%(name)s] %(message)s",
    )

    tail_correct_directory(
        input_dir=args.input,
        output_dir=args.outdir,
        ref_file=args.ref,
        var_file=args.var,
        pattern=args.pattern,
        count_pattern=args.count_pattern,
        clip_thresh=args.clip_thresh,
        chrm_db=args.blast_db,
        cdna_db=args.blast_db2,
        variants_dir=args.variants_dir,
        introns_spec=args.introns,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
