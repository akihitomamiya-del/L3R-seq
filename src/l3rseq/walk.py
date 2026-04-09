"""Right-clip walk correction for L3Rseq tail correction (step 09).

Replaces ``scripts/09c_walk_correction.sh``. The bash version grep'd the
variant file once per right-clip base; this version takes a pre-loaded
frozenset of mismatch strings (loaded once by the caller), eliminating
~N grep invocations per read where N is the clip length.

This is the per-read inner loop that walks each soft-clipped base against
the reference, extending the matched region as long as bases match — or are
tolerated as known editing variants — and stopping at the first real mismatch.
"""

from __future__ import annotations


def walk_correction(
    ref_seq: str,
    ref_position: int,
    rightclip_seq: str,
    known_variants: frozenset[str],
) -> int:
    """Walk a right-clip sequence against the reference, returning matched bases.

    Mirrors ``scripts/09c_walk_correction.sh:9-55`` exactly. Walks base-by-base
    from the start of the right-clip and the corresponding reference position,
    advancing both pointers on a nucleotide match (or a tolerated editing
    variant) and stopping at the first real mismatch.

    The bash version's 5th positional argument (``pattern``) is intentionally
    omitted here — it was unused inside ``run_walk_correction`` and only
    mattered for the downstream variant caller (now in :mod:`l3rseq.variants`).

    Args:
        ref_seq: Pre-loaded reference sequence as a single uppercase string.
            Indexed 0-based internally; ``ref_position`` is converted at use.
        ref_position: 1-based reference position of the FIRST clipped base.
            The caller computes this as
            ``aln_start - 1 + total_m + total_d + 1``
            (see ``scripts/09_tail_correct.sh:184``).
        rightclip_seq: The right-clip nucleotide sequence (uppercase ATGC).
            Its length determines the maximum walk distance.
        known_variants: Frozen set of mismatch strings of the form
            ``"<1-based-pos><ref_base><alt_base>"`` — e.g., ``"123CT"`` for
            a C→T edit at position 123. These mismatches are tolerated as
            editing events instead of terminating the walk. Pass
            ``frozenset()`` if no variant file is configured (matches the
            bash behavior of an absent or unreadable ``ref_var`` file).

    Returns:
        Number of right-clip bases that were validated and should be
        promoted from S to M by :func:`l3rseq.cigar.rebuild_cigar`. Always
        non-negative; never exceeds ``len(rightclip_seq)``.

    Examples:
        >>> ref = "ACGTACGT" + "N" * 100
        >>> walk_correction(ref, 1, "ACGT", frozenset())
        4
        >>> walk_correction(ref, 1, "ACGTG", frozenset())  # mismatch at pos 5
        4
        >>> walk_correction(ref, 1, "ACGTG", frozenset({"5AG"}))  # tolerated
        5
    """
    rightclip_n = len(rightclip_seq)
    match_counter = 0
    rightclip_position = 0
    cur_ref_pos = ref_position  # 1-based throughout

    while rightclip_position < rightclip_n:
        # Get reference base at 1-based cur_ref_pos. Slicing returns "" on
        # out-of-bounds, matching the bash substring semantics
        # (scripts/09c_walk_correction.sh:30).
        ref_base = ref_seq[cur_ref_pos - 1 : cur_ref_pos]
        clip_base = rightclip_seq[rightclip_position]

        if ref_base == clip_base:
            # Direct nucleotide match — extend the matched region
            match_counter += 1
            rightclip_position += 1
            cur_ref_pos += 1
            continue

        # Mismatch — check if it's a known editing variant.
        # Mismatch encoding matches scripts/09c_walk_correction.sh:42:
        # "${ref_position}${ref_base_char}${clip_base_char}"
        mismatch = f"{cur_ref_pos}{ref_base}{clip_base}"
        if mismatch in known_variants:
            match_counter += 1
            rightclip_position += 1
            cur_ref_pos += 1
            continue

        # Real mismatch — stop correction (matches bash `stopper` increment)
        break

    return match_counter
