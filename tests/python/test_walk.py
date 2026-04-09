"""Tests for src/l3rseq/walk.py — right-clip walk correction.

The walk algorithm is the per-base inner loop of step 09 tail correction.
The bash equivalent (scripts/09c_walk_correction.sh) has no standalone unit
tests in test_shell_functions.sh — it is only exercised end-to-end by the
integration tests. These pytest cases provide the unit-level coverage that
was missing.
"""

from __future__ import annotations

from l3rseq.walk import walk_correction


class TestWalkBasicMatching:
    """Direct nucleotide matching with no variants."""

    def test_full_extend_when_clip_matches_ref(self) -> None:
        # Clip is identical to ref starting at position 1 → walk consumes all
        ref = "ACGTACGT" + "N" * 100
        result = walk_correction(ref, 1, "ACGT", frozenset())
        assert result == 4

    def test_stop_on_first_mismatch(self) -> None:
        # Ref starts with ACGT then A, clip is ACGTG → mismatch at clip[4]
        ref = "ACGTAAAA" + "N" * 100
        result = walk_correction(ref, 1, "ACGTG", frozenset())
        assert result == 4

    def test_no_match_at_first_base(self) -> None:
        # First clip base disagrees → counter = 0
        ref = "AAAAAA" + "N" * 100
        result = walk_correction(ref, 1, "TAAA", frozenset())
        assert result == 0

    def test_walk_starting_mid_reference(self) -> None:
        # ref_position = 4 means start at ref[3] (0-based)
        ref = "XXXACGTYYY"
        result = walk_correction(ref, 4, "ACGT", frozenset())
        assert result == 4


class TestWalkWithVariants:
    """Mismatches that are in known_variants are tolerated."""

    def test_single_tolerated_variant_extends_walk(self) -> None:
        # Ref:  A C G T A A A A
        # Clip: A C G T G       — mismatch at position 5 (1-based)
        # Variant "5AG" tolerates the A→G edit, walk continues to end-of-clip
        ref = "ACGTAAAA" + "N" * 100
        result = walk_correction(ref, 1, "ACGTG", frozenset({"5AG"}))
        assert result == 5

    def test_consecutive_variants(self) -> None:
        # Ref:  A C A A
        # Clip: A T A G — mismatches at positions 2 (C→T) and 4 (A→G)
        # Both in variants → walk consumes all 4
        ref = "ACAA" + "N" * 100
        result = walk_correction(ref, 1, "ATAG", frozenset({"2CT", "4AG"}))
        assert result == 4

    def test_variant_then_real_mismatch_stops_at_real(self) -> None:
        # Ref:  A C A A
        # Clip: A T A C — pos 2 is tolerated (2CT), pos 4 is NOT (4AC)
        ref = "ACAA" + "N" * 100
        result = walk_correction(ref, 1, "ATAC", frozenset({"2CT"}))
        assert result == 3  # walks 3, stops at unmatched 4AC

    def test_empty_variants_treats_all_mismatches_as_real(self) -> None:
        # Same ref+clip as test_single_tolerated_variant_extends_walk but
        # without the variant in the set → stops at the first mismatch
        ref = "ACGTAAAA" + "N" * 100
        result = walk_correction(ref, 1, "ACGTG", frozenset())
        assert result == 4

    def test_variant_position_must_match_one_based(self) -> None:
        # Variant string uses 1-based position; off-by-one would mis-match
        ref = "ACGT" + "N" * 100
        result = walk_correction(ref, 1, "ACGN", frozenset({"4TN"}))
        assert result == 4  # 4 is the 1-based position of the T in ACGT


class TestWalkBoundaryConditions:
    """Edge cases at the start/end of the walk."""

    def test_empty_clip_returns_zero(self) -> None:
        ref = "ACGT" + "N" * 100
        result = walk_correction(ref, 1, "", frozenset())
        assert result == 0

    def test_walk_exhausts_clip_without_mismatch(self) -> None:
        # Single-base clip that matches → result = 1
        ref = "A" + "N" * 100
        result = walk_correction(ref, 1, "A", frozenset())
        assert result == 1

    def test_walk_past_end_of_reference_treats_as_mismatch(self) -> None:
        # ref_seq has only 3 bases; ref_position 1 means walk starts at ref[0]
        # Clip is 7 bases. Walk exhausts ref at clip position 3 → empty ref
        # base != clip base → mismatch → stop. Result = 3.
        ref = "ACG"
        result = walk_correction(ref, 1, "ACGTAAA", frozenset())
        assert result == 3

    def test_walk_starting_past_end_of_reference(self) -> None:
        # ref_position is beyond ref_seq length from the start → first base
        # comparison fails immediately
        ref = "ACG"
        result = walk_correction(ref, 10, "ACGT", frozenset())
        assert result == 0

    def test_clip_longer_than_remaining_ref(self) -> None:
        # ref has 5 chars, walk starts at position 4 → only 2 ref bases left
        ref = "AAAAC"
        result = walk_correction(ref, 4, "AC", frozenset())
        assert result == 2  # ref[3]='A' matches clip[0]='A', ref[4]='C' matches clip[1]='C'
