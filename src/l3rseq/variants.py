"""CIGAR-walk variant calling for L3Rseq tail correction (step 09).

Replaces ``scripts/09e_call_variants.sh``. The bash version is a single awk
pass that walks the CIGAR and compares each base to a pre-loaded reference,
emitting variant strings and counting editing events by pattern category.
This Python version does the same in pure Python — no awk subprocess, no
per-read shell-out.

The bash script's docstring (line 7) claims byte-identical output to bcftools
on all 2,069 REP2 reads, so this module's correctness is the gating constraint
for the differential test in Phase 1b.
"""

from __future__ import annotations

from dataclasses import dataclass

# CIGAR operations that consume both reference and read (and may produce variants)
_CIGAR_BOTH = frozenset({"M", "=", "X"})
# Operations that consume read only
_CIGAR_READ_ONLY = frozenset({"I", "S"})
# Operations that consume reference only
_CIGAR_REF_ONLY = frozenset({"D", "N"})


@dataclass(frozen=True)
class VariantResult:
    """Result of :func:`call_variants`.

    Attributes:
        variants_str: Semicolon-separated variant string in the format
            ``"<1-based-pos><ref><alt>;<pos><ref><alt>;..."``. Trailing
            ``";"`` is preserved to match the bash version's printf output
            (``scripts/09e_call_variants.sh:49``). Empty string if no
            variants were found.
        ec: Editing count — number of variant entries whose ref+alt suffix
            matches one of the comma-separated primary patterns.
        sc: Secondary count — number of variant entries matching the
            optional ``count_pattern`` (e.g., ``"TC"`` for SLAM-seq).
            Always 0 if ``count_pattern`` is empty.
        nc: Noise count — variant entries that match neither EC nor SC.
            May be negative in the pathological case where EC and SC
            patterns overlap (matches the bash arithmetic, which also
            produces negative values in this case).
    """

    variants_str: str
    ec: int
    sc: int
    nc: int


def call_variants(
    read_seq: str,
    cigar_str: str,
    ref_seq: str,
    aln_start: int,
    pattern: str,
    count_pattern: str = "",
) -> VariantResult:
    """Walk a read's CIGAR and call mismatch variants against the reference.

    Mirrors ``scripts/09e_call_variants.sh:33-77`` exactly. Single-pass CIGAR
    walk that emits variant strings and counts editing events by pattern
    category.

    CIGAR semantics (matches the bash awk in 09e):

    ===================  ============================================
    Operation            Behavior
    ===================  ============================================
    ``M``, ``=``, ``X``  Consume both ref and read; emit variant on mismatch
    ``I``, ``S``         Consume read only (no ref advance, no variant)
    ``D``, ``N``         Consume ref only (no read advance, no variant)
    Other (``H``, ``P``) No-op (consume neither)
    ===================  ============================================

    Args:
        read_seq: The read sequence (uppercase ATGC). Soft-clipped bases ARE
            present in the read sequence; the CIGAR's ``S`` operation
            advances the read pointer past them without emitting variants.
        cigar_str: The CIGAR string for this alignment.
        ref_seq: Pre-loaded reference sequence as a single string.
        aln_start: 1-based alignment start position (POS field from SAM).
        pattern: Primary editing pattern(s), comma-separated. Each pattern
            is exactly 2 characters: ``ref_base`` + ``alt_base``. Examples:
            ``"CT"`` (RNA editing), ``"CT,AG"`` (multiple), ``"AG"``.
            Patterns shorter than 2 characters are silently ignored
            (deviation from bash, which would loosely match single-char
            patterns; the pipeline never passes such patterns in practice).
        count_pattern: Optional secondary count-only pattern for things like
            SLAM-seq (``"TC"``). Empty string disables SC counting (sc = 0).

    Returns:
        :class:`VariantResult` with ``variants_str``, ``ec``, ``sc``, ``nc``.

    Examples:
        >>> result = call_variants("ATAA", "4M", "ACAA", 1, "CT")
        >>> result.variants_str
        '2CT;'
        >>> result.ec
        1
        >>> result.nc
        0
    """
    # Build EC pattern set: each entry is exactly 2 chars (ref+alt suffix)
    ec_patterns: set[str] = set()
    for p in pattern.split(","):
        p = p.strip()
        if len(p) >= 2:
            ec_patterns.add(p[:2])

    # SC pattern: single optional 2-char string
    sc_pattern = count_pattern.strip()[:2] if count_pattern else ""
    if len(sc_pattern) < 2:
        sc_pattern = ""

    # CIGAR walk: emit variants
    variant_parts: list[str] = []
    ref_pos = aln_start - 1  # convert to 0-based for slicing
    read_pos = 0
    num = ""

    for c in cigar_str:
        if c.isdigit():
            num += c
            continue

        length = int(num) if num else 0
        num = ""

        if c in _CIGAR_BOTH:
            for _ in range(length):
                rb = ref_seq[ref_pos : ref_pos + 1]
                qb = read_seq[read_pos : read_pos + 1].upper()
                # Skip if either base is missing (out-of-bounds slicing yields "")
                if rb and qb and rb != qb:
                    variant_parts.append(f"{ref_pos + 1}{rb}{qb};")
                ref_pos += 1
                read_pos += 1
        elif c in _CIGAR_READ_ONLY:
            read_pos += length
        elif c in _CIGAR_REF_ONLY:
            ref_pos += length
        # H, P, and any other ops: no-op (consume neither)

    variants_str = "".join(variant_parts)

    # Count EC and SC by inspecting each variant entry's 2-char ref+alt suffix.
    # This is equivalent to the bash `grep -cE "$_ec_regex"` because variant
    # entries always have the strict format "<digits><ref><alt>".
    ec = 0
    sc = 0
    if variants_str:
        entries = [e for e in variants_str.split(";") if e]
        for entry in entries:
            if len(entry) < 3:  # need at least 1 digit + ref + alt
                continue
            ref_alt = entry[-2:]
            if ref_alt in ec_patterns:
                ec += 1
            if sc_pattern and ref_alt == sc_pattern:
                sc += 1
        total_mm = len(entries)
        nc = total_mm - ec - sc
    else:
        nc = 0

    return VariantResult(variants_str=variants_str, ec=ec, sc=sc, nc=nc)
