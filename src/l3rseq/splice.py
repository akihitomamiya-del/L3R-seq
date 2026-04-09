"""Intron splicing detection and CIGAR D→N conversion for L3Rseq step 09.

Replaces ``scripts/09f_splice_check.sh``. Three public functions:

* :func:`parse_introns` — load intron coordinates from shorthand,
  BED, or GFF3/GTF.
* :func:`check_splice` — given a read's CIGAR and alignment start,
  classify each annotated intron as Spliced (``"S"``), Retained
  (``"R"``), or Not-spanned (``"-"``).
* :func:`convert_intron_d_to_n` — rewrite a CIGAR's deletion ops that
  match annotated intron coordinates as ``N`` (intron-skip) for proper
  SAM semantics.

All coordinates are stored internally in 0-based half-open form
(``[start, end)``), matching the bash version.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# Minimum length for a CIGAR D or N operation to be considered a candidate
# splice junction (matches scripts/09f_splice_check.sh:149).
_MIN_DEL_LEN = 50

# Tolerance (bp) on each side when matching a CIGAR deletion to an annotated
# intron (matches scripts/09f_splice_check.sh:200).
_BOUNDARY_TOL = 10

# Required length match: deletion must be at least this fraction of the
# annotated intron length (matches scripts/09f_splice_check.sh:202).
_MIN_LEN_RATIO_PCT = 80

# Minimum read coverage on each flank of an intron required for the read
# to be considered "spanning" the intron (matches scripts/09f_splice_check.sh:182).
_FLANK_REQUIRED = 20


@dataclass(frozen=True)
class Intron:
    """A single intron coordinate in 0-based half-open form.

    Attributes:
        start: 0-based start position (inclusive).
        end: 0-based end position (exclusive).
    """

    start: int
    end: int

    @property
    def length(self) -> int:
        """Length of the intron in bp."""
        return self.end - self.start


@dataclass(frozen=True)
class SpliceResult:
    """Per-read splice analysis result from :func:`check_splice`.

    Attributes:
        sj_pattern: One character per intron, in input order.
            ``"S"`` if the intron is spliced out (matching deletion found),
            ``"R"`` if retained (read spans but no matching deletion),
            ``"-"`` if the read does not span the intron.
            Empty string when ``introns`` is empty.
        si: Number of ``"S"`` characters in ``sj_pattern``.
        ir: Number of ``"R"`` characters in ``sj_pattern``.
    """

    sj_pattern: str
    si: int
    ir: int


# ============================================================================
# parse_introns
# ============================================================================


def parse_introns(spec: str) -> list[Intron]:
    """Parse an intron specification into a list of :class:`Intron` objects.

    Mirrors ``scripts/09f_splice_check.sh:19-58``. Three input formats:

    * **Shorthand**: ``"500-2100"`` or ``"500-2100,3500-4200"``. Numbers are
      taken as-is (already 0-based half-open).
    * **BED file**: tab-separated, columns ``chrom start end [name]``.
      Native BED is 0-based half-open. Lines starting with ``#`` are skipped.
    * **GFF3 / GTF file**: 1-based inclusive. Tries explicit ``intron``
      features first, then falls back to inferring introns from gaps between
      sorted ``exon`` features.

    Args:
        spec: One of the three formats above, or empty string.

    Returns:
        List of :class:`Intron`. Empty list when ``spec`` is empty or no
        introns could be parsed.
    """
    if not spec:
        return []

    spec_path = Path(spec)
    if spec_path.is_file():
        ext = spec.lower().rsplit(".", 1)[-1]
        if ext in ("gff", "gff3", "gtf"):
            return _parse_gff(spec_path)
        return _parse_bed(spec_path)

    # Shorthand: "start-end" or "start-end,start-end"
    introns: list[Intron] = []
    for entry in spec.split(","):
        if "-" not in entry:
            continue
        start_str, end_str = entry.split("-", 1)
        try:
            introns.append(Intron(start=int(start_str), end=int(end_str)))
        except ValueError:
            continue
    return introns


def _parse_bed(path: Path) -> list[Intron]:
    """Parse a BED file into Intron objects (0-based half-open, native BED)."""
    introns: list[Intron] = []
    with path.open() as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                start = int(parts[1])
                end = int(parts[2])
            except ValueError:
                continue
            introns.append(Intron(start=start, end=end))
    return introns


def _parse_gff(path: Path) -> list[Intron]:
    """Parse a GFF3/GTF file for introns.

    Tries explicit ``intron`` features first; if none are present, falls back
    to inferring introns from gaps between sorted ``exon`` features. GFF is
    1-based inclusive — converted to 0-based half-open by subtracting 1 from
    each start.
    """
    explicit: list[Intron] = []
    exons: list[tuple[int, int]] = []  # 1-based inclusive

    with path.open() as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 5:
                continue
            feature_type = parts[2]
            try:
                start = int(parts[3])
                end = int(parts[4])
            except ValueError:
                continue
            if feature_type == "intron":
                # GFF 1-based inclusive → 0-based half-open
                explicit.append(Intron(start=start - 1, end=end))
            elif feature_type == "exon":
                exons.append((start, end))

    if explicit:
        return explicit

    if not exons:
        return []

    # Infer introns from sorted exon gaps. Matches the bash logic in
    # scripts/09f_splice_check.sh:99-110.
    exons.sort(key=lambda pair: pair[0])
    inferred: list[Intron] = []
    prev_end = 0
    for start, end in exons:
        if prev_end > 0 and start > prev_end:
            inferred.append(Intron(start=prev_end, end=start - 1))
        prev_end = end
    return inferred


# ============================================================================
# check_splice
# ============================================================================


def check_splice(cigar_str: str, aln_start: int, introns: list[Intron]) -> SpliceResult:
    """Classify each annotated intron as spliced, retained, or not-spanned.

    Mirrors ``scripts/09f_splice_check.sh:115-219``.

    Walks the CIGAR to find large deletions (and N intron-skips) of length
    ``>= 50``, then for each annotated intron determines whether the read
    spans it (with at least 20bp on each flank) and whether any large
    deletion matches its boundaries within ±10 bp AND covers ≥ 80% of the
    intron's length.

    Args:
        cigar_str: SAM CIGAR string.
        aln_start: 1-based alignment start (POS field from SAM).
        introns: Annotated introns from :func:`parse_introns`. Empty list
            yields an empty result.

    Returns:
        :class:`SpliceResult` with ``sj_pattern``, ``si``, ``ir``.
    """
    if not introns:
        return SpliceResult(sj_pattern="", si=0, ir=0)

    # Walk CIGAR to collect large deletions and find the read's end on the ref
    ref_pos = aln_start - 1  # 0-based
    del_intervals: list[tuple[int, int]] = []
    num = ""

    for c in cigar_str:
        if c.isdigit():
            num += c
            continue
        length = int(num) if num else 0
        num = ""
        if c in ("M", "=", "X"):
            ref_pos += length
        elif c == "D":
            if length >= _MIN_DEL_LEN:
                del_intervals.append((ref_pos, ref_pos + length))
            ref_pos += length
        elif c == "N":
            # N is "skipped region" — most aligners use it for splice junctions.
            # Bash version treats N the same as D >= 50 here.
            if length >= _MIN_DEL_LEN:
                del_intervals.append((ref_pos, ref_pos + length))
            ref_pos += length
        # I, S, H, P: do not consume reference

    read_end_ref = ref_pos
    aln_start_0 = aln_start - 1

    sj_chars: list[str] = []
    si = 0
    ir = 0

    for intron in introns:
        # Spanning check: read must extend at least _FLANK_REQUIRED bp before
        # intron start AND _FLANK_REQUIRED bp after intron end. Matches the
        # bash conditions at scripts/09f_splice_check.sh:182.
        if (
            aln_start_0 > intron.start - _FLANK_REQUIRED
            or read_end_ref < intron.end + _FLANK_REQUIRED
        ):
            sj_chars.append("-")
            continue

        # Look for a matching deletion
        intron_len = intron.length
        min_del_len = (intron_len * _MIN_LEN_RATIO_PCT) // 100
        found = False
        for ds, de in del_intervals:
            del_len = de - ds
            if (
                abs(ds - intron.start) <= _BOUNDARY_TOL
                and abs(de - intron.end) <= _BOUNDARY_TOL
                and del_len >= min_del_len
            ):
                found = True
                break

        if found:
            sj_chars.append("S")
            si += 1
        else:
            sj_chars.append("R")
            ir += 1

    return SpliceResult(sj_pattern="".join(sj_chars), si=si, ir=ir)


# ============================================================================
# convert_intron_d_to_n
# ============================================================================


def convert_intron_d_to_n(
    cigar_str: str,
    aln_start: int,
    introns: list[Intron],
) -> str:
    """Rewrite intron-matching D operations as N for proper SAM semantics.

    Mirrors ``scripts/09f_splice_check.sh:224-291``.

    Walks the CIGAR; for each D operation of length ≥ 50, checks whether it
    matches an annotated intron (within ±10 bp on each side AND ≥ 80% of the
    intron's length) and if so, emits ``N`` instead of ``D``. Existing N
    operations are preserved as N. Other operations (I, S, H, P, M, =, X)
    are emitted unchanged.

    Args:
        cigar_str: Original CIGAR string.
        aln_start: 1-based alignment start (POS field from SAM).
        introns: Annotated introns. Empty list returns the input unchanged.

    Returns:
        Possibly-rewritten CIGAR string.
    """
    if not introns:
        return cigar_str

    new_parts: list[str] = []
    ref_pos = aln_start - 1
    num = ""

    for c in cigar_str:
        if c.isdigit():
            num += c
            continue
        length = int(num) if num else 0
        num = ""

        if c in ("M", "=", "X"):
            new_parts.append(f"{length}{c}")
            ref_pos += length
        elif c == "D":
            is_intron = False
            if length >= _MIN_DEL_LEN:
                del_start = ref_pos
                del_end = ref_pos + length
                for intron in introns:
                    intron_len = intron.length
                    min_del_len = (intron_len * _MIN_LEN_RATIO_PCT) // 100
                    if (
                        abs(del_start - intron.start) <= _BOUNDARY_TOL
                        and abs(del_end - intron.end) <= _BOUNDARY_TOL
                        and length >= min_del_len
                    ):
                        is_intron = True
                        break
            new_parts.append(f"{length}{'N' if is_intron else 'D'}")
            ref_pos += length
        elif c == "N":
            new_parts.append(f"{length}N")
            ref_pos += length
        elif c in ("I", "S", "H", "P"):
            new_parts.append(f"{length}{c}")
        else:
            new_parts.append(f"{length}{c}")

    return "".join(new_parts)
