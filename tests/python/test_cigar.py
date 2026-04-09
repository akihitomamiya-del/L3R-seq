"""Tests for src/l3rseq/cigar.py — CIGAR parsing and rebuilding.

The :class:`TestRebuildCigar` cases mirror ``tests/test_shell_functions.sh:44-80``
verbatim — they are the source of truth for the bash implementation's semantics
and the regression baseline for the Python rewrite.
"""

from __future__ import annotations

from l3rseq.cigar import ParsedCigar, parse_cigar, rebuild_cigar


# ============================================================================
# parse_cigar
# ============================================================================


class TestParseCigar:
    """parse_cigar() — extract rightclip_n, total_m, total_d from a CIGAR."""

    def test_simple_match_only(self) -> None:
        assert parse_cigar("100M") == ParsedCigar(rightclip_n=0, total_m=100, total_d=0)

    def test_match_with_rightclip(self) -> None:
        assert parse_cigar("500M55S") == ParsedCigar(rightclip_n=55, total_m=500, total_d=0)

    def test_match_with_deletion(self) -> None:
        # 100M5D50M → total_m=150, total_d=5
        assert parse_cigar("100M5D50M") == ParsedCigar(rightclip_n=0, total_m=150, total_d=5)

    def test_complex_cigar(self) -> None:
        # 10M1I20D300M120S → total_m=310, total_d=20, rightclip=120
        assert parse_cigar("10M1I20D300M120S") == ParsedCigar(
            rightclip_n=120, total_m=310, total_d=20
        )

    def test_leading_softclip_not_counted_as_rightclip(self) -> None:
        # Leading S exists but is not the trailing operation → rightclip_n = 0
        assert parse_cigar("5S100M") == ParsedCigar(rightclip_n=0, total_m=100, total_d=0)

    def test_internal_softclip_not_counted(self) -> None:
        # Internal S (unusual but legal) → rightclip_n = 0
        assert parse_cigar("50M5S50M") == ParsedCigar(rightclip_n=0, total_m=100, total_d=0)

    def test_empty_cigar(self) -> None:
        assert parse_cigar("") == ParsedCigar(rightclip_n=0, total_m=0, total_d=0)

    def test_multiple_m_ops_summed(self) -> None:
        # 50M10D50M → both M ops contribute to total_m
        assert parse_cigar("50M10D50M") == ParsedCigar(rightclip_n=0, total_m=100, total_d=10)

    def test_only_trailing_softclip(self) -> None:
        # Pathological but legal: just an S
        assert parse_cigar("10S") == ParsedCigar(rightclip_n=10, total_m=0, total_d=0)


# ============================================================================
# rebuild_cigar — these mirror tests/test_shell_functions.sh:44-80 verbatim
# ============================================================================


class TestRebuildCigar:
    """rebuild_cigar() — port of run_rebuild_cigar shell test cases.

    Each test corresponds to a hand-verified case in
    tests/test_shell_functions.sh:44-80. The Python output must match the
    bash output exactly to keep the differential test (Phase 1b) passing.
    """

    def test_normal_tail_update(self) -> None:
        # 500M55S + 12 matches → 512M43S
        new_cigar, new_s = rebuild_cigar("500M55S", 12)
        assert new_cigar == "512M43S"
        assert new_s == 43

    def test_multi_op_body(self) -> None:
        # 10M20D5M10S + 3 → 10M20D8M7S
        new_cigar, new_s = rebuild_cigar("10M20D5M10S", 3)
        assert new_cigar == "10M20D8M7S"
        assert new_s == 7

    def test_s_becomes_zero(self) -> None:
        # 15M10S + 10 → 25M (no S suffix)
        new_cigar, new_s = rebuild_cigar("15M10S", 10)
        assert new_cigar == "25M"
        assert new_s == 0

    def test_s_clamped_from_negative(self) -> None:
        # 5M3S + 5 → clamp to 0, "10M"
        new_cigar, new_s = rebuild_cigar("5M3S", 5)
        assert new_cigar == "10M"
        assert new_s == 0

    def test_zero_counter(self) -> None:
        # 5M8S + 0 → unchanged
        new_cigar, new_s = rebuild_cigar("5M8S", 0)
        assert new_cigar == "5M8S"
        assert new_s == 8

    def test_complex_body(self) -> None:
        # 10M1I20D300M120S + 60 → 10M1I20D360M60S
        new_cigar, new_s = rebuild_cigar("10M1I20D300M120S", 60)
        assert new_cigar == "10M1I20D360M60S"
        assert new_s == 60

    def test_full_correction(self) -> None:
        # 450M60S + 60 → 510M (all S absorbed)
        new_cigar, new_s = rebuild_cigar("450M60S", 60)
        assert new_cigar == "510M"
        assert new_s == 0


class TestRebuildCigarEdgeCases:
    """Edge cases not directly in test_shell_functions.sh.

    These document Python-side guarantees that don't have a bash counterpart
    (the bash version's behavior on these inputs is undefined / has latent bugs
    that are masked because the worker only calls rebuild_cigar when
    rightclip_n > 0).
    """

    def test_no_trailing_softclip_returns_unchanged(self) -> None:
        # Bash version produces invalid "100M5M" here; Python returns unchanged.
        # This branch is not exercised by the real pipeline (caller guards
        # with rightclip_n > 0) so the deviation is safe.
        new_cigar, new_s = rebuild_cigar("100M", 5)
        assert new_cigar == "100M"
        assert new_s == 0

    def test_match_counter_larger_than_old_s(self) -> None:
        # Excess match_counter is silently absorbed (S clamps to 0).
        new_cigar, new_s = rebuild_cigar("100M10S", 20)
        assert new_cigar == "120M"
        assert new_s == 0
