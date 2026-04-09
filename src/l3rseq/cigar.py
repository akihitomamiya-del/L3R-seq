"""CIGAR string parsing and rebuilding for L3Rseq tail correction.

Replaces ``scripts/09a_parse_cigar.sh`` (parse) and
``scripts/09d_rebuild_cigar.sh`` (rebuild). The bash versions used a mix of
single-pass awk and grep+sed; this module uses simple regex tokenization,
which is faster, easier to test, and removes the need for the worker-level
``set +e`` / ``_require_int`` validation guards in the bash pipeline.

Both functions are pure (no I/O, no side effects) and operate only on CIGAR
strings. SAM-line field extraction is intentionally NOT in this module — that
becomes ``pysam.AlignedSegment`` attribute access in Phase 1b.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# CIGAR operation tokenizer: matches "<length><op>" where op is one of MIDNSHP=X.
# This is the standard SAM CIGAR alphabet (SAMv1 §1.4.6).
_CIGAR_OP_RE = re.compile(r"(\d+)([MIDNSHP=X])")

# Trailing "<n>M<m>S" pattern used by rebuild_cigar to find the right-clip site.
# Anchored to end-of-string ($) so we only match the LAST M+S pair, never an
# internal one — this matches the bash version (09d_rebuild_cigar.sh:13).
_TRAILING_MS_RE = re.compile(r"(\d+)M(\d+)S$")


@dataclass(frozen=True)
class ParsedCigar:
    """Result of :func:`parse_cigar`.

    Attributes:
        rightclip_n: Length of the trailing soft-clip operation (0 if the
            CIGAR does not end in S). Leading or internal S operations are
            intentionally ignored — only the trailing S is the right-clip
            that step 09 corrects.
        total_m: Sum of all M operations across the entire CIGAR.
        total_d: Sum of all D operations across the entire CIGAR.
    """

    rightclip_n: int
    total_m: int
    total_d: int


def parse_cigar(cigar_str: str) -> ParsedCigar:
    """Parse a CIGAR string into total M, total D, and trailing soft-clip length.

    Mirrors ``scripts/09a_parse_cigar.sh:20-34``. Single-pass tokenization
    (no per-op subprocess invocations like the bash version uses).

    Args:
        cigar_str: SAM CIGAR string, e.g., ``"500M55S"`` or
            ``"10M1I20D300M120S"``. Empty strings are accepted and produce
            an all-zero result.

    Returns:
        :class:`ParsedCigar` with ``rightclip_n``, ``total_m``, ``total_d``.
    """
    ops = _CIGAR_OP_RE.findall(cigar_str)
    if not ops:
        return ParsedCigar(rightclip_n=0, total_m=0, total_d=0)

    total_m = 0
    total_d = 0
    for length_str, op in ops:
        length = int(length_str)
        if op == "M":
            total_m += length
        elif op == "D":
            total_d += length

    # Trailing S only — last operation must be S, otherwise rightclip_n = 0.
    last_length_str, last_op = ops[-1]
    rightclip_n = int(last_length_str) if last_op == "S" else 0

    return ParsedCigar(rightclip_n=rightclip_n, total_m=total_m, total_d=total_d)


def rebuild_cigar(cigar_str: str, match_counter: int) -> tuple[str, int]:
    """Rebuild a CIGAR string after right-clip walk correction.

    Mirrors ``scripts/09d_rebuild_cigar.sh:8-37`` exactly. The function moves
    ``match_counter`` bases from the trailing soft-clip into the trailing M
    operation, clamping the new soft-clip to 0 if it would go negative. When
    the new soft-clip becomes 0, it is dropped entirely (no ``0S`` suffix).

    The input is expected to end in ``"<n>M<m>S"`` — the standard shape for
    an aligned read with a right soft-clip. Inputs without that pattern are
    returned unchanged with ``new_tail_s=0``; that branch is not normally
    exercised by the pipeline because the caller (step 09 worker) only invokes
    this function when ``rightclip_n > 0``.

    Args:
        cigar_str: Original CIGAR string. Should end in ``"<n>M<m>S"``.
        match_counter: Number of right-clip bases that were validated by the
            walk algorithm and should be promoted to M. Must be non-negative.

    Returns:
        Tuple ``(new_cigar, new_tail_s)``: the rebuilt CIGAR string and the
        clamped new soft-clip length.

    Examples:
        >>> rebuild_cigar("500M55S", 12)
        ('512M43S', 43)
        >>> rebuild_cigar("15M10S", 10)
        ('25M', 0)
        >>> rebuild_cigar("5M3S", 5)
        ('10M', 0)
    """
    match = _TRAILING_MS_RE.search(cigar_str)
    if match is None:
        return cigar_str, 0

    old_m = int(match.group(1))
    old_s = int(match.group(2))
    new_m = old_m + match_counter
    new_s = max(0, old_s - match_counter)

    body = cigar_str[: match.start()]
    if new_s == 0:
        return f"{body}{new_m}M", 0
    return f"{body}{new_m}M{new_s}S", new_s
