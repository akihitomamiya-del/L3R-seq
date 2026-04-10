"""Tests for l3rseq.count — gene counting CIGAR overlap + splice extraction.

Mirrors the Phase 1 test style (test_cigar.py): class-per-function, inline
synthetic data, hand-computed expected values for every edge case.
"""

from __future__ import annotations

from pathlib import Path

from l3rseq.count import (
    Region,
    compute_region_overlap,
    extract_splice_pattern,
    load_regions,
)

# ---------------------------------------------------------------------------
# TestComputeRegionOverlap
# ---------------------------------------------------------------------------

class TestComputeRegionOverlap:
    """Mirrors the awk CIGAR walk in scripts/11_count.sh:55-71."""

    def test_read_fully_inside_region(self) -> None:
        """100M read at pos 100, region [50, 500] → overlap = 100."""
        ops = [(100, "M")]
        assert compute_region_overlap(ops, 100, 50, 500) == 100

    def test_read_spanning_region_start(self) -> None:
        """100M read at pos 1, region [50, 500] → overlap = 51 (pos 50..100)."""
        ops = [(100, "M")]
        assert compute_region_overlap(ops, 1, 50, 500) == 51

    def test_read_spanning_region_end(self) -> None:
        """100M read at pos 450, region [50, 500] → overlap = 51 (pos 450..500)."""
        ops = [(100, "M")]
        assert compute_region_overlap(ops, 450, 50, 500) == 51

    def test_read_fully_upstream(self) -> None:
        """100M read at pos 1, region [200, 500] → overlap = 0."""
        ops = [(100, "M")]
        assert compute_region_overlap(ops, 1, 200, 500) == 0

    def test_read_fully_downstream(self) -> None:
        """100M read at pos 600, region [50, 500] → overlap = 0."""
        ops = [(100, "M")]
        assert compute_region_overlap(ops, 600, 50, 500) == 0

    def test_n_op_skips_region_interior(self) -> None:
        """50M 200N 50M at pos 100, region [100, 400].

        First 50M covers 100–149: overlap with [100,400] = 50.
        200N covers 150–349: no overlap (intron skip).
        Second 50M covers 350–399: overlap with [100,400] = 50.
        Total overlap = 100.
        """
        ops = [(50, "M"), (200, "N"), (50, "M")]
        assert compute_region_overlap(ops, 100, 100, 400) == 100

    def test_d_op_consumes_ref_and_counts(self) -> None:
        """50M 10D 40M at pos 100, region [100, 250].

        50M: 100–149, overlap = 50.
        10D: 150–159, overlap = 10.
        40M: 160–199, overlap = 40.
        Total = 100.
        """
        ops = [(50, "M"), (10, "D"), (40, "M")]
        assert compute_region_overlap(ops, 100, 100, 250) == 100

    def test_insertion_does_not_move_ref(self) -> None:
        """50M 5I 50M at pos 100, region [100, 250].

        50M: 100–149, overlap = 50.
        5I: no ref movement.
        50M: 150–199, overlap = 50.
        Total = 100.
        """
        ops = [(50, "M"), (5, "I"), (50, "M")]
        assert compute_region_overlap(ops, 100, 100, 250) == 100

    def test_soft_clip_ignored(self) -> None:
        """10S 80M 10S at pos 100, region [100, 250] → overlap = 80.

        S does not move ref; only the 80M counts.
        """
        ops = [(10, "S"), (80, "M"), (10, "S")]
        assert compute_region_overlap(ops, 100, 100, 250) == 80


# ---------------------------------------------------------------------------
# TestExtractSplicePattern
# ---------------------------------------------------------------------------

class TestExtractSplicePattern:
    """Mirrors scripts/11_count.sh:76-82."""

    def test_no_n_ops(self) -> None:
        ops = [(100, "M")]
        assert extract_splice_pattern(ops, 100) == "none"

    def test_one_n_op(self) -> None:
        """50M 200N 50M at pos 100.

        After 50M: rpos = 150. N at rpos 150 with len 200 → "150:200".
        """
        ops = [(50, "M"), (200, "N"), (50, "M")]
        assert extract_splice_pattern(ops, 100) == "150:200"

    def test_two_n_ops(self) -> None:
        """30M 100N 30M 200N 30M at pos 100.

        After 30M: rpos=130. N1 at 130 len 100 → rpos=230.
        After 30M: rpos=260. N2 at 260 len 200 → rpos=460.
        Pattern: "130:100,260:200".
        """
        ops = [(30, "M"), (100, "N"), (30, "M"), (200, "N"), (30, "M")]
        assert extract_splice_pattern(ops, 100) == "130:100,260:200"

    def test_n_position_uses_aln_start(self) -> None:
        """50M 100N 50M at pos 500.

        After 50M: rpos=550. N at 550 len 100.
        """
        ops = [(50, "M"), (100, "N"), (50, "M")]
        assert extract_splice_pattern(ops, 500) == "550:100"


# ---------------------------------------------------------------------------
# TestLoadRegions
# ---------------------------------------------------------------------------

class TestLoadRegions:
    """Mirrors region loading in scripts/11_count.sh:130-145."""

    def test_standard_tsv(self, tmp_path: Path) -> None:
        f = tmp_path / "regions.tsv"
        f.write_text(
            "#gene_name\tchr\tstart\tend\tstrand\tsource\n"
            "geneA\tchr1\t100\t500\t+\tmanual\n"
            "geneB\tchr2\t200\t800\t-\tgff\n"
        )
        regions = load_regions(f)
        assert len(regions) == 2
        assert regions[0] == Region("geneA", "chr1", 100, 500)
        assert regions[1] == Region("geneB", "chr2", 200, 800)

    def test_skips_comments_and_blank_lines(self, tmp_path: Path) -> None:
        f = tmp_path / "regions.tsv"
        f.write_text(
            "# comment line\n"
            "\n"
            "gene\tchr\tstart\tend\n"  # non-# header variant
            "geneA\tchr1\t100\t500\n"
        )
        regions = load_regions(f)
        assert len(regions) == 1
        assert regions[0].name == "geneA"

    def test_empty_file(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.tsv"
        f.write_text("")
        regions = load_regions(f)
        assert regions == []


# ---------------------------------------------------------------------------
# TestRegion
# ---------------------------------------------------------------------------

class TestRegion:
    def test_length(self) -> None:
        r = Region("g", "c", 100, 200)
        assert r.length == 101
