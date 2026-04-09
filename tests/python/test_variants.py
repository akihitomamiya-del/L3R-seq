"""Tests for src/l3rseq/variants.py — CIGAR-walk variant calling.

The bash equivalent (scripts/09e_call_variants.sh) has no standalone unit
tests in test_shell_functions.sh — it's only exercised end-to-end. These
pytest cases provide the unit-level coverage that was missing and document
the exact CIGAR-walk semantics.
"""

from __future__ import annotations

from l3rseq.variants import VariantResult, call_variants


class TestCallVariantsZeroMismatches:
    """Reads that match the reference perfectly produce no variants."""

    def test_all_match_returns_empty(self) -> None:
        result = call_variants("ACGT", "4M", "ACGT", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0
        assert result.sc == 0
        assert result.nc == 0

    def test_match_in_middle_of_reference(self) -> None:
        # Read aligns to ref starting at position 5 (1-based)
        result = call_variants("ACGT", "4M", "XXXXACGTYY", 5, "CT")
        assert result.variants_str == ""
        assert result.ec == 0


class TestCallVariantsPrimaryPattern:
    """Single-pattern EC counting (e.g., CT for RNA editing)."""

    def test_single_ct_variant(self) -> None:
        # ref ACAA, read ATAA → mismatch at pos 2: C→T = "2CT"
        result = call_variants("ATAA", "4M", "ACAA", 1, "CT")
        assert result.variants_str == "2CT;"
        assert result.ec == 1
        assert result.sc == 0
        assert result.nc == 0

    def test_non_matching_pattern_counts_as_noise(self) -> None:
        # ref AAAA, read AGAA → mismatch at pos 2: A→G = "2AG"
        # With pattern "CT", "2AG" is noise
        result = call_variants("AGAA", "4M", "AAAA", 1, "CT")
        assert result.variants_str == "2AG;"
        assert result.ec == 0
        assert result.nc == 1

    def test_multiple_ct_variants(self) -> None:
        # ref CCCC, read TTTC → 3 CT mismatches (positions 1, 2, 3)
        result = call_variants("TTTC", "4M", "CCCC", 1, "CT")
        assert result.variants_str == "1CT;2CT;3CT;"
        assert result.ec == 3
        assert result.nc == 0


class TestCallVariantsMultiPattern:
    """Comma-separated patterns (e.g., CT,AG for two editing types)."""

    def test_ct_and_ag_both_count_as_ec(self) -> None:
        # ref ACAA, read ATAG → 2CT and 4AG
        result = call_variants("ATAG", "4M", "ACAA", 1, "CT,AG")
        assert result.variants_str == "2CT;4AG;"
        assert result.ec == 2
        assert result.sc == 0
        assert result.nc == 0

    def test_only_ct_counts_when_pattern_is_ct_only(self) -> None:
        # Same input as above but pattern is just CT — AG is noise now
        result = call_variants("ATAG", "4M", "ACAA", 1, "CT")
        assert result.ec == 1
        assert result.nc == 1

    def test_pattern_with_whitespace_is_stripped(self) -> None:
        # User passes "CT, AG" with a space — should still work
        result = call_variants("ATAG", "4M", "ACAA", 1, "CT, AG")
        assert result.ec == 2


class TestCallVariantsSlamSeq:
    """SLAM-seq style: primary pattern (CT) + secondary count pattern (TC)."""

    def test_ct_primary_tc_secondary(self) -> None:
        # ref ACTA, read ATCA → 2CT (primary), 3TC (secondary), 0 noise
        result = call_variants("ATCA", "4M", "ACTA", 1, "CT", count_pattern="TC")
        assert result.variants_str == "2CT;3TC;"
        assert result.ec == 1
        assert result.sc == 1
        assert result.nc == 0

    def test_secondary_pattern_only(self) -> None:
        # No CT mismatches, only TC
        result = call_variants("CCAA", "4M", "TCAA", 1, "CT", count_pattern="TC")
        assert result.variants_str == "1TC;"
        assert result.ec == 0
        assert result.sc == 1
        assert result.nc == 0

    def test_no_count_pattern_disables_sc(self) -> None:
        # Same input as test_ct_primary_tc_secondary but no count_pattern
        result = call_variants("ATCA", "4M", "ACTA", 1, "CT")
        assert result.ec == 1
        assert result.sc == 0
        assert result.nc == 1  # the TC mismatch is now noise


class TestCallVariantsCigarOps:
    """CIGAR operations other than M produce no variants."""

    def test_insertion_does_not_emit_variant(self) -> None:
        # ref AAAA, read AAGAA (with insertion of G), cigar 2M1I2M
        # Walk: 2M matches, 1I skips read base, 2M matches
        result = call_variants("AAGAA", "2M1I2M", "AAAA", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0
        assert result.nc == 0

    def test_deletion_advances_ref_only(self) -> None:
        # ref AAACAAA (7bp), read AAAAAA (6bp), cigar 3M1D3M
        # Walk: 3M (read[0..2] vs ref[0..2]: A,A,A all match),
        # 1D (skip ref[3]=C), 3M (read[3..5] vs ref[4..6]: A,A,A all match)
        result = call_variants("AAAAAA", "3M1D3M", "AAACAAA", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0

    def test_soft_clip_does_not_emit_variant(self) -> None:
        # Leading 2S clips read[0..1]; ref starts at aln_start
        # ref AAAAA, read GGAAA, cigar 2S3M → 'GG' is clipped, 'AAA' matches
        result = call_variants("GGAAA", "2S3M", "AAAAA", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0

    def test_n_intron_skip_advances_ref_only(self) -> None:
        # ref AACGGAA (7bp), read AAAA (4bp), cigar 2M3N2M
        # Walk: 2M matches, 3N skips ref[2..4]=CGG, 2M matches
        result = call_variants("AAAA", "2M3N2M", "AACGGAA", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0

    def test_x_operation_treated_as_match_or_mismatch(self) -> None:
        # X is "alignment mismatch" — same walk semantics as M, but every X
        # base is by definition a mismatch (caller chooses X over M to mark
        # known mismatches). Our walker just checks the bases.
        # ref AT, read AC, cigar 2X → 1 match (A=A), 1 mismatch (T vs C)
        result = call_variants("AC", "2X", "AT", 1, "CT")
        assert result.variants_str == "2TC;"
        assert result.ec == 0  # TC is not the CT pattern
        assert result.nc == 1


class TestCallVariantsBoundaries:
    """Out-of-bounds reads/refs are tolerated without crashing."""

    def test_read_extends_past_ref(self) -> None:
        # ref is 3bp, read is 5bp aligned to position 1 with cigar 5M
        # Walk: 3 matches against ref bases, then 2 iterations where
        # rb is empty → no variant emitted (matches bash awk's
        # `if (rb != "" && qb != "")` guard)
        result = call_variants("ACGTA", "5M", "ACG", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0

    def test_aln_start_past_end_of_ref(self) -> None:
        # All comparisons fall off the end of ref → no variants
        result = call_variants("ACGT", "4M", "ACG", 10, "CT")
        assert result.variants_str == ""
        assert result.ec == 0

    def test_empty_read(self) -> None:
        result = call_variants("", "", "ACGT", 1, "CT")
        assert result.variants_str == ""
        assert result.ec == 0
        assert result.nc == 0


class TestVariantResultDataclass:
    """The result type is a frozen dataclass (immutable, hashable)."""

    def test_result_equality(self) -> None:
        # Two identical calls produce equal results
        a = call_variants("ATAA", "4M", "ACAA", 1, "CT")
        b = call_variants("ATAA", "4M", "ACAA", 1, "CT")
        assert a == b
        assert a == VariantResult(variants_str="2CT;", ec=1, sc=0, nc=0)
