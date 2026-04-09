"""Tests for src/l3rseq/splice.py — intron splice detection.

The check_splice and convert_intron_d_to_n cases mirror
tests/test_shell_functions.sh:130-216 verbatim — they are the source-of-truth
regression baseline for the bash implementation. parse_introns shorthand and
BED cases mirror tests/test_shell_functions.sh:88-122. GFF parsing tests are
net-new (the bash version's _parse_gff has limited test coverage).
"""

from __future__ import annotations

from pathlib import Path

from l3rseq.splice import (
    Intron,
    SpliceResult,
    check_splice,
    convert_intron_d_to_n,
    parse_introns,
)


# ============================================================================
# parse_introns — shorthand
# ============================================================================


class TestParseIntronsShorthand:
    """Shorthand format: 'start-end' or 'start-end,start-end,...'."""

    def test_single_intron(self) -> None:
        result = parse_introns("300-500")
        assert result == [Intron(start=300, end=500)]

    def test_multiple_introns(self) -> None:
        result = parse_introns("100-200,500-800")
        assert result == [Intron(start=100, end=200), Intron(start=500, end=800)]

    def test_empty_spec_returns_empty_list(self) -> None:
        assert parse_introns("") == []

    def test_invalid_entry_skipped(self) -> None:
        # Entries without "-" are skipped silently
        result = parse_introns("100-200,bogus,300-400")
        assert result == [Intron(start=100, end=200), Intron(start=300, end=400)]


# ============================================================================
# parse_introns — BED file
# ============================================================================


class TestParseIntronsBed:
    """BED format: tab-separated chrom\\tstart\\tend\\t[name], 0-based half-open."""

    def test_bed_with_two_entries_and_comment(self, tmp_path: Path) -> None:
        bed = tmp_path / "introns.bed"
        bed.write_text("#comment\ntest_gene\t300\t500\tintron1\ntest_gene\t800\t1000\tintron2\n")
        result = parse_introns(str(bed))
        assert result == [Intron(start=300, end=500), Intron(start=800, end=1000)]

    def test_bed_skips_blank_lines(self, tmp_path: Path) -> None:
        bed = tmp_path / "introns.bed"
        bed.write_text("\ntest\t100\t200\n\n")
        assert parse_introns(str(bed)) == [Intron(start=100, end=200)]

    def test_bed_skips_lines_with_too_few_fields(self, tmp_path: Path) -> None:
        bed = tmp_path / "introns.bed"
        bed.write_text("only\ttwo\ntest\t100\t200\n")
        # First line has only 2 fields → skipped
        assert parse_introns(str(bed)) == [Intron(start=100, end=200)]


# ============================================================================
# parse_introns — GFF3 file
# ============================================================================


class TestParseIntronsGff:
    """GFF3/GTF format: 1-based inclusive, converted to 0-based half-open."""

    def test_gff_with_explicit_intron_features(self, tmp_path: Path) -> None:
        # GFF position 301 (1-based) → 300 (0-based)
        gff = tmp_path / "introns.gff3"
        gff.write_text(
            "#gff-version 3\n"
            "test_gene\tx\tintron\t301\t500\t.\t+\t.\tID=intron1\n"
            "test_gene\tx\tintron\t801\t1000\t.\t+\t.\tID=intron2\n"
        )
        result = parse_introns(str(gff))
        assert result == [Intron(start=300, end=500), Intron(start=800, end=1000)]

    def test_gff_infers_introns_from_exon_gaps(self, tmp_path: Path) -> None:
        # Two exons 1-100 and 200-300 (1-based inclusive). Intron between is
        # positions 101-199 (1-based inclusive). Bash conversion to 0-based
        # half-open: Intron(start=100, end=199). The intron coordinates land
        # at the exon boundaries.
        gff = tmp_path / "exons_only.gff3"
        gff.write_text(
            "test_gene\tx\texon\t1\t100\t.\t+\t.\tID=exon1\n"
            "test_gene\tx\texon\t200\t300\t.\t+\t.\tID=exon2\n"
        )
        result = parse_introns(str(gff))
        assert result == [Intron(start=100, end=199)]

    def test_gff_explicit_introns_take_priority_over_exons(self, tmp_path: Path) -> None:
        # When explicit intron features are present, the exon gap inference
        # is NOT applied (matches bash early return).
        gff = tmp_path / "both.gff3"
        gff.write_text(
            "test\tx\texon\t1\t50\t.\t+\t.\tID=exon1\n"
            "test\tx\tintron\t51\t100\t.\t+\t.\tID=intron1\n"
            "test\tx\texon\t101\t200\t.\t+\t.\tID=exon2\n"
        )
        result = parse_introns(str(gff))
        assert result == [Intron(start=50, end=100)]

    def test_gff_with_only_comments_returns_empty(self, tmp_path: Path) -> None:
        gff = tmp_path / "empty.gff3"
        gff.write_text("##gff-version 3\n# nothing here\n")
        assert parse_introns(str(gff)) == []


# ============================================================================
# check_splice — mirrors tests/test_shell_functions.sh:130-184
# ============================================================================


class TestCheckSpliceSingleIntron:
    """Single intron at (300, 500). Cases ported from test_shell_functions.sh."""

    INTRONS = [Intron(start=300, end=500)]

    def test_spliced_read_with_matching_deletion(self) -> None:
        # 100M200D100M at pos 210: walk gives ref [209, 309) M, [309, 509) D, [509, 609) M
        # Deletion (309, 509) matches intron (300, 500) within ±10bp → S
        result = check_splice("100M200D100M", 210, self.INTRONS)
        assert result == SpliceResult(sj_pattern="S", si=1, ir=0)

    def test_retained_read_no_deletion(self) -> None:
        # 500M at pos 100: read covers [99, 599), spans intron, no deletion → R
        result = check_splice("500M", 100, self.INTRONS)
        assert result == SpliceResult(sj_pattern="R", si=0, ir=1)

    def test_short_read_does_not_span_intron(self) -> None:
        # 50M at pos 100: read covers [99, 149), ends well before intron → -
        result = check_splice("50M", 100, self.INTRONS)
        assert result == SpliceResult(sj_pattern="-", si=0, ir=0)

    def test_n_operator_treated_same_as_d(self) -> None:
        # 100M200N100M at pos 210: same as the spliced D test but with N
        result = check_splice("100M200N100M", 210, self.INTRONS)
        assert result == SpliceResult(sj_pattern="S", si=1, ir=0)

    def test_small_deletion_below_threshold_is_retained(self) -> None:
        # 200M40D300M at pos 100: 40D is below the 50bp threshold → not a
        # candidate splice junction. Read spans intron → R.
        result = check_splice("200M40D300M", 100, self.INTRONS)
        assert result == SpliceResult(sj_pattern="R", si=0, ir=1)


class TestCheckSpliceMultipleIntrons:
    """Multi-intron cases."""

    def test_two_introns_one_spliced_one_retained(self) -> None:
        # Introns at (300,500) and (800,1000). 100M200D800M at pos 210 has
        # one large deletion (309, 509) — matches the first intron.
        # The second intron has no matching deletion but the read spans it.
        introns = [Intron(start=300, end=500), Intron(start=800, end=1000)]
        result = check_splice("100M200D800M", 210, introns)
        assert result == SpliceResult(sj_pattern="SR", si=1, ir=1)


class TestCheckSpliceNoIntrons:
    """Empty intron list returns an empty result."""

    def test_no_introns_returns_empty(self) -> None:
        result = check_splice("500M", 100, [])
        assert result == SpliceResult(sj_pattern="", si=0, ir=0)


# ============================================================================
# convert_intron_d_to_n — mirrors tests/test_shell_functions.sh:189-216
# ============================================================================


class TestConvertIntronDToN:
    """D→N rewriting based on annotated intron positions."""

    INTRONS = [Intron(start=300, end=500)]

    def test_matching_d_converted_to_n(self) -> None:
        result = convert_intron_d_to_n("100M200D100M", 210, self.INTRONS)
        assert result == "100M200N100M"

    def test_small_d_unchanged(self) -> None:
        # 30D is below the 50bp threshold → stays as D
        result = convert_intron_d_to_n("100M30D100M", 210, self.INTRONS)
        assert result == "100M30D100M"

    def test_no_d_unchanged(self) -> None:
        result = convert_intron_d_to_n("300M", 100, self.INTRONS)
        assert result == "300M"

    def test_non_matching_d_unchanged(self) -> None:
        # Intron is far from the deletion → stays as D
        introns = [Intron(start=800, end=1000)]
        result = convert_intron_d_to_n("100M200D100M", 100, introns)
        assert result == "100M200D100M"

    def test_existing_n_preserved(self) -> None:
        # Existing N operations are preserved as N regardless of intron match
        result = convert_intron_d_to_n("100M200N100M", 210, [])
        assert result == "100M200N100M"

    def test_no_introns_returns_input_unchanged(self) -> None:
        # Empty intron list short-circuits — returns the input as-is
        result = convert_intron_d_to_n("100M200D100M", 210, [])
        assert result == "100M200D100M"
