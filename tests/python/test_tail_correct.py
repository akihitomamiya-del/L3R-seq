"""Unit tests for src/l3rseq/tail_correct.compute_correction.

These exercise the pure-Python per-read orchestration logic (the function
that wires cigar/walk/variants/splice together) without touching pysam.
The pysam I/O layer is exercised by the differential test in
tests/benchmarks/diff_step09.sh.
"""

from __future__ import annotations

from l3rseq.splice import Intron
from l3rseq.tail_correct import (
    CorrectionResult,
    ReadKind,
    _extract_rightclip_seq,
    _sum_m_ops,
    compute_correction,
)


def _kwargs(**overrides) -> dict:
    """Default compute_correction kwargs for tests; overrides merged in."""
    # A 200bp reference of repeating ACGT, so ACGTACGT... matches the start
    ref = "".join("ACGT"[i % 4] for i in range(200))
    defaults = dict(
        cigar_str="10M",
        query_seq="ACGTACGTAC",
        aln_start=1,
        ref_seq=ref,
        known_variants=frozenset(),
        pattern="CT",
        count_pattern="",
        introns=[],
    )
    defaults.update(overrides)
    return defaults


# ============================================================================
# Helpers
# ============================================================================


class TestSumMOps:
    def test_single_m(self) -> None:
        assert _sum_m_ops("100M") == 100

    def test_multiple_m(self) -> None:
        assert _sum_m_ops("50M10D50M") == 100

    def test_no_m(self) -> None:
        assert _sum_m_ops("20S5I") == 0

    def test_with_s_and_n(self) -> None:
        assert _sum_m_ops("5S100M50N50M10S") == 150


class TestExtractRightclipSeq:
    def test_all_atgc(self) -> None:
        assert _extract_rightclip_seq("ACGTACGT", 4) == "ACGT"

    def test_lowercase_preserved(self) -> None:
        # Matches bash grep -i: lowercase allowed, case preserved
        assert _extract_rightclip_seq("ACGTacgt", 4) == "acgt"

    def test_contains_n_returns_empty(self) -> None:
        # Ambiguous base 'N' in tail → bash grep fails → empty string
        assert _extract_rightclip_seq("ACGTACNT", 4) == ""

    def test_zero_length(self) -> None:
        assert _extract_rightclip_seq("ACGT", 0) == ""


# ============================================================================
# compute_correction — no-right-clip fast path
# ============================================================================


class TestComputeCorrectionNoClip:
    def test_perfect_match_no_mismatches(self) -> None:
        # 10bp match starting at position 1, read exactly matches ref
        result = compute_correction(**_kwargs(cigar_str="10M", query_seq="ACGTACGTAC"))
        assert result.kind == ReadKind.CORRECTED
        assert result.new_cigar == "10M"  # unchanged
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["EC"] == 0
        assert tag_dict["NC"] == 0
        assert tag_dict["RC"] == 0  # no right-clip
        assert tag_dict["RS"] == ""
        assert tag_dict["3E"] == 10  # terminus = 1 - 1 + 10 + 0 = 10
        assert tag_dict["mL"] == 10  # matched_length = 10 + 0
        assert tag_dict["VR"] == ""  # no variants

    def test_single_ct_edit_counted(self) -> None:
        # ref: A C G T A C G T A C
        # rd:  A T G T A C G T A C  (mismatch at pos 2: C→T = "2CT")
        result = compute_correction(**_kwargs(query_seq="ATGTACGTAC", pattern="CT"))
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["EC"] == 1
        assert tag_dict["NC"] == 0
        assert tag_dict["VR"] == "2CT;"

    def test_no_splice_when_introns_empty(self) -> None:
        result = compute_correction(**_kwargs(introns=[]))
        tag_names = {name for name, _, _ in result.tags}
        assert "SJ" not in tag_names
        assert "SI" not in tag_names
        assert "IR" not in tag_names

    def test_sc_tag_only_when_count_pattern_set(self) -> None:
        result_no_sc = compute_correction(**_kwargs(count_pattern=""))
        result_with_sc = compute_correction(**_kwargs(count_pattern="TC"))
        assert "SC" not in {n for n, _, _ in result_no_sc.tags}
        assert "SC" in {n for n, _, _ in result_with_sc.tags}


# ============================================================================
# compute_correction — with-right-clip walk path
# ============================================================================


class TestComputeCorrectionWithClip:
    def test_full_walk_extension_reduces_softclip(self) -> None:
        # ref covers the full span; read CIGAR is 5M4S but the 4 clipped
        # bases actually continue matching the reference → walk extends
        # to 9M0S.
        # ref position 1-9: ACGTACGTA
        # read seq 5M4S: ACGTA + CGTA (4 S at end)
        # Walk position 6: ref=C, clip[0]=C → match
        # Walk position 7: ref=G, clip[1]=G → match
        # Walk position 8: ref=T, clip[2]=T → match
        # Walk position 9: ref=A, clip[3]=A → match
        # match_counter = 4, new_cigar = 9M (0S clamped)
        result = compute_correction(
            **_kwargs(cigar_str="5M4S", query_seq="ACGTACGTA")
        )
        assert result.kind == ReadKind.CORRECTED
        assert result.new_cigar == "9M"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["RC"] == 0
        assert tag_dict["RS"] == ""
        # terminus = aln_start - 1 + new_total_m + total_d = 0 + 9 + 0 = 9
        assert tag_dict["3E"] == 9

    def test_partial_walk_then_mismatch_stops(self) -> None:
        # 5M4S, read = ACGTATCGA (first 5M match, clip = TCGA)
        # Walk:
        #   pos 6: ref=C, clip[0]=T → mismatch, not a variant → stop
        # match_counter = 0, new_cigar = 5M4S (unchanged)
        result = compute_correction(
            **_kwargs(cigar_str="5M4S", query_seq="ACGTATCGA")
        )
        assert result.new_cigar == "5M4S"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["RC"] == 4
        assert tag_dict["RS"] == "TCGA"

    def test_known_variant_tolerated_in_walk(self) -> None:
        # 5M4S, read = ACGTATGTA
        # Walk:
        #   pos 6: ref=C, clip[0]=T → "6CT" — IS in known_variants → extend
        #   pos 7: ref=G, clip[1]=G → match
        #   pos 8: ref=T, clip[2]=T → match
        #   pos 9: ref=A, clip[3]=A → match
        # match_counter = 4, new_cigar = 9M
        result = compute_correction(
            **_kwargs(
                cigar_str="5M4S",
                query_seq="ACGTATGTA",
                known_variants=frozenset({"6CT"}),
            )
        )
        assert result.new_cigar == "9M"

    def test_chrm_blast_hit_sets_tl_tag(self) -> None:
        result = compute_correction(
            **_kwargs(cigar_str="5M4S", query_seq="ACGTATCGA"),
            blast_chrm_hit=True,
        )
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["TL"] == 1
        # Walk correction still happens for ChrM hits
        assert result.kind == ReadKind.CORRECTED

    def test_cdna_blast_hit_marks_chimeric(self) -> None:
        result = compute_correction(
            **_kwargs(cigar_str="5M4S", query_seq="ACGTATCGA"),
            blast_cdna_hit=True,
        )
        assert result.kind == ReadKind.CHIMERIC
        # Chimeric reads have empty tag list (bash cut -f1-11 strips tags)
        assert result.tags == []
        # CIGAR unchanged (not walk-corrected)
        assert result.new_cigar == "5M4S"


class TestComputeCorrectionDoublesorter:
    """DS tag = terminus * 10000 + new_tail_s (or rightclip_n for no-clip)."""

    def test_no_clip_ds_is_terminus_times_10000(self) -> None:
        result = compute_correction(**_kwargs(cigar_str="10M"))
        tag_dict = {name: value for name, value, _ in result.tags}
        # terminus = 10, rightclip_n = 0 → DS = 100000
        assert tag_dict["DS"] == 100000

    def test_with_clip_ds_includes_new_tail_s(self) -> None:
        # 5M4S, no match → new_tail_s stays 4, terminus = 5
        result = compute_correction(
            **_kwargs(cigar_str="5M4S", query_seq="ACGTATCGA")
        )
        tag_dict = {name: value for name, value, _ in result.tags}
        # terminus = 5, new_tail_s = 4 → DS = 50000 + 4 = 50004
        assert tag_dict["DS"] == 50004


class TestComputeCorrectionSplice:
    """Splice detection and D→N conversion tests."""

    def test_intron_d_converted_to_n(self) -> None:
        # 200bp ref, read spans positions 1-500 via 100M200D200M
        # aln_start = 1, 200D spans ref [100, 300) in 0-based → intron
        # annotated at (100, 300)
        ref = "".join("ACGT"[i % 4] for i in range(600))
        introns = [Intron(start=100, end=300)]
        # Build a read seq that matches ref positions 1-100 and 301-500
        # = ref[:100] + ref[300:500]
        read_seq = ref[:100] + ref[300:500]
        result = compute_correction(
            cigar_str="100M200D200M",
            query_seq=read_seq,
            aln_start=1,
            ref_seq=ref,
            known_variants=frozenset(),
            pattern="CT",
            count_pattern="",
            introns=introns,
        )
        # D → N conversion
        assert result.new_cigar == "100M200N200M"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["SJ"] == "S"
        assert tag_dict["SI"] == 1
        assert tag_dict["IR"] == 0

    def test_no_introns_no_splice_tags(self) -> None:
        result = compute_correction(**_kwargs(introns=[]))
        tag_names = {name for name, _, _ in result.tags}
        assert "SJ" not in tag_names
        assert "SI" not in tag_names
        assert "IR" not in tag_names


class TestComputeCorrectionIntronAsN:
    """Introns written as N by a splice-aware aligner (minimap2 -x splice:hq).

    N advances the reference like D, so the 3' end (3E), the walk start and mL
    must include it; without it they land upstream by the intron length.
    """

    # exon 1 = ref 1-100, intron = 101-300 (all T), exon 2 = 301-400,
    # downstream = 401-420
    EXON1 = "ACGT" * 25
    INTRON = "T" * 200
    EXON2 = "CAGT" * 25
    DOWNSTREAM = "GGGGCCCC" + "A" * 12
    REF = EXON1 + INTRON + EXON2 + DOWNSTREAM

    def test_no_clip_terminus_includes_intron(self) -> None:
        result = compute_correction(
            **_kwargs(
                cigar_str="100M200N100M",
                query_seq=self.EXON1 + self.EXON2,
                ref_seq=self.REF,
            )
        )
        assert result.new_cigar == "100M200N100M"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["3E"] == 400  # not 200
        assert tag_dict["mL"] == 400
        assert tag_dict["DS"] == 4000000
        assert tag_dict["EC"] == 0
        assert tag_dict["NC"] == 0

    def test_walk_compares_clip_with_ref_after_the_intron(self) -> None:
        # The clip GGGG continues the reference at 401-404 and is absorbed.
        # Walking from 201 (inside the intron, all T) would leave it clipped.
        result = compute_correction(
            **_kwargs(
                cigar_str="100M200N100M4S",
                query_seq=self.EXON1 + self.EXON2 + "GGGG",
                ref_seq=self.REF,
            )
        )
        assert result.new_cigar == "100M200N104M"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["RC"] == 0
        assert tag_dict["3E"] == 404
        assert tag_dict["mL"] == 404

    def test_untemplated_tail_kept_after_spliced_alignment(self) -> None:
        # Poly(A) tail after exon 2: ref 401 is G, so nothing is absorbed.
        result = compute_correction(
            **_kwargs(
                cigar_str="100M200N100M5S",
                query_seq=self.EXON1 + self.EXON2 + "AAAAA",
                ref_seq=self.REF,
            )
        )
        assert result.new_cigar == "100M200N100M5S"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["3E"] == 400
        assert tag_dict["RC"] == 5
        assert tag_dict["RS"] == "AAAAA"
        assert tag_dict["DS"] == 4000005

    def test_insertions_not_counted(self) -> None:
        # Insertions (I) consume the read, not the reference: the 3' end is
        # the same with or without them; only the intron (N) is added.
        read = self.EXON1[:50] + "GGG" + self.EXON1[50:] + self.EXON2
        result = compute_correction(
            **_kwargs(cigar_str="50M3I50M200N100M", query_seq=read, ref_seq=self.REF)
        )
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["3E"] == 400  # 50 + 50 + 200 + 100, not + 3
        assert tag_dict["mL"] == 400

    def test_insertions_not_counted_without_intron(self) -> None:
        # Unspliced alignment with an insertion and a deletion: unchanged
        # behaviour, 3E = aln_start - 1 + M + D.
        read = self.EXON1[:50] + "GGG" + self.EXON1[50:60] + self.EXON1[62:100]
        result = compute_correction(
            **_kwargs(cigar_str="50M3I10M2D38M", query_seq=read, ref_seq=self.REF)
        )
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["3E"] == 100  # 50 + 10 + 2 + 38
        assert tag_dict["mL"] == 100

    def test_insertion_does_not_shift_walk_start(self) -> None:
        # Insertion before the intron, templated clip after exon 2: the walk
        # must still start at ref 401.
        read = self.EXON1[:50] + "GGG" + self.EXON1[50:] + self.EXON2 + "GGGG"
        result = compute_correction(
            **_kwargs(cigar_str="50M3I50M200N100M4S", query_seq=read, ref_seq=self.REF)
        )
        assert result.new_cigar == "50M3I50M200N104M"
        tag_dict = {name: value for name, value, _ in result.tags}
        assert tag_dict["3E"] == 404
        assert tag_dict["RC"] == 0

    def test_matches_d_intron_input_after_conversion(self) -> None:
        # The same molecule aligned with the intron as D (default lr:hq) and
        # converted by the intron annotation gets the same 3E and mL.
        introns = [Intron(start=100, end=300)]
        as_n = compute_correction(
            **_kwargs(
                cigar_str="100M200N100M",
                query_seq=self.EXON1 + self.EXON2,
                ref_seq=self.REF,
                introns=introns,
            )
        )
        as_d = compute_correction(
            **_kwargs(
                cigar_str="100M200D100M",
                query_seq=self.EXON1 + self.EXON2,
                ref_seq=self.REF,
                introns=introns,
            )
        )
        assert as_d.new_cigar == as_n.new_cigar == "100M200N100M"
        tags_n = {name: value for name, value, _ in as_n.tags}
        tags_d = {name: value for name, value, _ in as_d.tags}
        for tag in ("3E", "mL", "DS", "EC", "NC", "VR"):
            assert tags_n[tag] == tags_d[tag], tag


class TestCorrectionResultDataclass:
    def test_equality(self) -> None:
        a = compute_correction(**_kwargs())
        b = compute_correction(**_kwargs())
        assert a == b

    def test_result_kind_enum_values(self) -> None:
        assert ReadKind.CORRECTED.value == "corrected"
        assert ReadKind.CHIMERIC.value == "chimeric"

    def test_corrected_result_has_tags(self) -> None:
        result = compute_correction(**_kwargs())
        assert isinstance(result, CorrectionResult)
        assert result.kind == ReadKind.CORRECTED
        assert len(result.tags) >= 9  # at least the mandatory 9 tags
