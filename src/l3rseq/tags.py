"""SAM tag construction for L3Rseq step 09 tail correction.

Produces the 13 tags that ``scripts/09_tail_correct.sh`` emits per read, in
bash-compatible order, as pysam-format tuples ``(tag_name, value, type_char)``.

Tag set
-------

==  ====  ==============================================================
ID  Type  Meaning
==  ====  ==============================================================
3E  i     3' end position on reference (``aln_start - 1 + M + D``)
RC  i     Remaining right-clip length after correction
RS  Z     Remaining right-clip sequence (empty string if fully corrected)
TL  i     Translocation flag (1 if ChrM BLAST hit, else 0)
DS  i     Double-sorter (``terminus * 10000 + remaining_clip_n``)
EC  i     Editing count (mismatches matching primary pattern)
SC  i     Secondary count — **optional**, only if ``count_pattern`` is set
NC  i     Noise count (non-editing, non-secondary mismatches)
mL  i     Matched length (``M + D`` after correction)
VR  Z     Variant string (semicolon-separated)
SJ  Z     Splice pattern — **optional**, only if introns are annotated
SI  i     Spliced intron count — emitted together with SJ
IR  i     Intron retained count — emitted together with SJ
==  ====  ==============================================================

The order and conditional logic mirrors
``scripts/09_tail_correct.sh:142-148`` and ``:229-235`` exactly. The
differential test in Phase 1b compares ``samtools view`` output byte-for-byte
against the bash version, so any reordering here will fail that gate.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

from l3rseq.splice import SpliceResult

#: pysam's tag tuple format: ``(tag_name, value, type_char)``. ``tag_name``
#: is a 2-character string. Value type depends on ``type_char`` (i=int,
#: Z=string, f=float). We only emit ``i`` and ``Z`` in step 09.
TagTuple = tuple[str, object, str]

#: Bounds for SAM ``i`` (signed 32-bit integer) tag values.
_INT32_MIN = -2_147_483_648
_INT32_MAX = 2_147_483_647

#: One-time warning flag for DS overflow (process-scoped).
#: ``build_tags`` is called once per read; we don't want to spam stderr.
_warned_ds_overflow = False


@dataclass(frozen=True)
class Step09TagValues:
    """Inputs to :func:`build_tags`. Populated by the step 09 orchestrator.

    Set ``sc`` to ``None`` to skip the SC tag (when no ``count_pattern`` is
    given — matches the bash ``[ -n "$count_pattern" ] && sc_tag="..."``).

    Set ``splice`` to ``None`` to skip all three SJ/SI/IR tags (when no
    introns are annotated — matches the bash ``if (sj_tags != "")``).

    Attributes:
        terminus: 3' end position on reference, 1-based.
        remaining_clip_n: Length of soft-clip remaining after correction.
        remaining_clip_seq: Nucleotide sequence of the remaining soft-clip.
            Empty string (not ``None``) when ``remaining_clip_n == 0``.
        translocation: 1 if the read's original right-clip BLASTed to
            the organellar reference (ChrM), else 0.
        doublesorter: ``terminus * 10000 + remaining_clip_n``, used by the
            IGV viewer for stable ordering.
        ec: Primary editing count.
        sc: Secondary count. ``None`` disables the SC tag entirely.
        nc: Noise count (mismatches that match neither EC nor SC patterns).
        matched_length: ``M + D`` length of the (possibly corrected) CIGAR.
        variants_str: Semicolon-separated variant string from
            :func:`l3rseq.variants.call_variants`.
        splice: Result from :func:`l3rseq.splice.check_splice` — ``None``
            when no introns are annotated.
    """

    terminus: int
    remaining_clip_n: int
    remaining_clip_seq: str
    translocation: int
    doublesorter: int
    ec: int
    sc: int | None
    nc: int
    matched_length: int
    variants_str: str
    splice: SpliceResult | None


def build_tags(values: Step09TagValues) -> list[TagTuple]:
    """Build the 13 step-09 SAM tags in bash-compatible order.

    Mirrors the awk tag append logic in ``scripts/09_tail_correct.sh:142-148``
    (no-right-clip path) and ``:229-235`` (with-right-clip path). Both paths
    emit the same tag set in the same order.

    Args:
        values: Populated :class:`Step09TagValues`.

    Returns:
        List of ``(tag_name, value, type_char)`` tuples suitable for
        ``pysam.AlignedSegment.tags = ...`` or ``set_tags(...)``. The list
        order matches the bash awk output exactly.

    Tag order::

        3E, RC, RS, TL, DS, EC, [SC], NC, mL, VR, [SJ, SI, IR]

    Where ``[SC]`` is emitted only if ``values.sc is not None``, and
    ``[SJ, SI, IR]`` are emitted together only if ``values.splice is not None``.
    """
    tags: list[TagTuple] = [
        ("3E", values.terminus, "i"),
        ("RC", values.remaining_clip_n, "i"),
        ("RS", values.remaining_clip_seq, "Z"),
        ("TL", values.translocation, "i"),
    ]
    # DS = terminus * 10000 + remaining_clip_n. For amplicon-scale references
    # this fits in int32 fine. For genome-wide references the multiplier
    # overflows around terminus > 215_000 (≈ chromosome positions in any
    # eukaryotic genome). pysam writes 'i' tags as signed int32, so the bare
    # set_tags() call would crash with struct.error. Drop DS when it would
    # overflow rather than crash; the IGV viewer falls back to its default
    # sort. One-time stderr notice on first overflow.
    if _INT32_MIN <= values.doublesorter <= _INT32_MAX:
        tags.append(("DS", values.doublesorter, "i"))
    else:
        global _warned_ds_overflow
        if not _warned_ds_overflow:
            print(
                "[step 09] WARNING: DS tag value "
                f"{values.doublesorter} exceeds int32 range; DS will be "
                "omitted for reads with reference positions > ~215kb. "
                "This is expected on genome-wide references and does not "
                "affect EC/3E/VR/SJ correctness.",
                file=sys.stderr,
            )
            _warned_ds_overflow = True
    tags.append(("EC", values.ec, "i"))
    if values.sc is not None:
        tags.append(("SC", values.sc, "i"))
    tags.extend(
        [
            ("NC", values.nc, "i"),
            ("mL", values.matched_length, "i"),
            ("VR", values.variants_str, "Z"),
        ]
    )
    if values.splice is not None:
        tags.append(("SJ", values.splice.sj_pattern, "Z"))
        tags.append(("SI", values.splice.si, "i"))
        tags.append(("IR", values.splice.ir, "i"))
    return tags
