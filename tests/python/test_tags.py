"""Tests for src/l3rseq/tags.py — SAM tag construction.

The tag order is the critical property: the Phase 1b differential test
compares ``samtools view`` output byte-for-byte against the bash step 09, so
any reordering will fail that gate. These tests lock down the exact order
and conditional emission logic for SC and SJ/SI/IR.
"""

from __future__ import annotations

from l3rseq.splice import SpliceResult
from l3rseq.tags import Step09TagValues, build_tags


def _base_values(**overrides) -> Step09TagValues:
    """Return a Step09TagValues with sensible defaults, overridden per-test."""
    defaults = dict(
        terminus=1000,
        remaining_clip_n=0,
        remaining_clip_seq="",
        translocation=0,
        doublesorter=10000000,
        ec=0,
        sc=None,
        nc=0,
        matched_length=500,
        variants_str="",
        splice=None,
    )
    defaults.update(overrides)
    return Step09TagValues(**defaults)


class TestTagOrder:
    """Verify tags are emitted in the exact bash order (9, 10, 12, or 13 tags)."""

    def test_minimal_nine_tags_no_sc_no_splice(self) -> None:
        # No count_pattern, no introns → 9 mandatory tags
        tags = build_tags(_base_values())
        names = [t[0] for t in tags]
        assert names == ["3E", "RC", "RS", "TL", "DS", "EC", "NC", "mL", "VR"]

    def test_with_sc_inserts_between_ec_and_nc(self) -> None:
        # SC lives between EC and NC — exactly where the bash awk inserts it
        tags = build_tags(_base_values(sc=5))
        names = [t[0] for t in tags]
        assert names == ["3E", "RC", "RS", "TL", "DS", "EC", "SC", "NC", "mL", "VR"]

    def test_with_splice_appends_sj_si_ir(self) -> None:
        # Splice tags appended after VR, in SJ → SI → IR order
        splice = SpliceResult(sj_pattern="SR", si=1, ir=1)
        tags = build_tags(_base_values(splice=splice))
        names = [t[0] for t in tags]
        assert names == ["3E", "RC", "RS", "TL", "DS", "EC", "NC", "mL", "VR", "SJ", "SI", "IR"]

    def test_with_sc_and_splice_thirteen_tags(self) -> None:
        # Maximum: all 13 tags present
        splice = SpliceResult(sj_pattern="S", si=1, ir=0)
        tags = build_tags(_base_values(sc=3, splice=splice))
        names = [t[0] for t in tags]
        assert names == [
            "3E", "RC", "RS", "TL", "DS", "EC", "SC",
            "NC", "mL", "VR", "SJ", "SI", "IR",
        ]

    def test_sc_zero_is_still_emitted(self) -> None:
        # sc=0 is a valid count (no secondary mismatches) — must emit, not skip.
        # Only sc=None skips.
        tags = build_tags(_base_values(sc=0))
        names = [t[0] for t in tags]
        assert "SC" in names
        sc_tag = next(t for t in tags if t[0] == "SC")
        assert sc_tag[1] == 0


class TestTagTypes:
    """Integer tags use 'i', string tags use 'Z' — matches SAM spec."""

    def test_all_tag_types(self) -> None:
        splice = SpliceResult(sj_pattern="R", si=0, ir=1)
        tags = build_tags(_base_values(sc=2, splice=splice))
        types = {name: type_char for name, _, type_char in tags}
        assert types == {
            "3E": "i", "RC": "i", "RS": "Z", "TL": "i", "DS": "i",
            "EC": "i", "SC": "i", "NC": "i", "mL": "i", "VR": "Z",
            "SJ": "Z", "SI": "i", "IR": "i",
        }


class TestTagValues:
    """Values from Step09TagValues flow through unchanged."""

    def test_full_passthrough(self) -> None:
        splice = SpliceResult(sj_pattern="SRS", si=2, ir=1)
        values = Step09TagValues(
            terminus=12345,
            remaining_clip_n=7,
            remaining_clip_seq="ACGTACG",
            translocation=1,
            doublesorter=123450007,
            ec=10,
            sc=3,
            nc=2,
            matched_length=500,
            variants_str="100CT;200AG;",
            splice=splice,
        )
        tags = build_tags(values)
        tag_dict = {name: value for name, value, _ in tags}
        assert tag_dict["3E"] == 12345
        assert tag_dict["RC"] == 7
        assert tag_dict["RS"] == "ACGTACG"
        assert tag_dict["TL"] == 1
        assert tag_dict["DS"] == 123450007
        assert tag_dict["EC"] == 10
        assert tag_dict["SC"] == 3
        assert tag_dict["NC"] == 2
        assert tag_dict["mL"] == 500
        assert tag_dict["VR"] == "100CT;200AG;"
        assert tag_dict["SJ"] == "SRS"
        assert tag_dict["SI"] == 2
        assert tag_dict["IR"] == 1

    def test_empty_strings_for_no_clip(self) -> None:
        # When fully corrected: remaining_clip_n=0, remaining_clip_seq=""
        tags = build_tags(_base_values(remaining_clip_n=0, remaining_clip_seq=""))
        rs_tag = next(t for t in tags if t[0] == "RS")
        rc_tag = next(t for t in tags if t[0] == "RC")
        assert rs_tag == ("RS", "", "Z")
        assert rc_tag == ("RC", 0, "i")

    def test_translocation_flag_passthrough(self) -> None:
        tags = build_tags(_base_values(translocation=1))
        tl = next(t for t in tags if t[0] == "TL")
        assert tl == ("TL", 1, "i")


class TestConditionalEmission:
    """SC and SJ/SI/IR conditional logic mirrors the bash awk if-guards."""

    def test_sc_none_skipped(self) -> None:
        tags = build_tags(_base_values(sc=None))
        assert "SC" not in [t[0] for t in tags]

    def test_splice_none_skips_all_three(self) -> None:
        tags = build_tags(_base_values(splice=None))
        names = [t[0] for t in tags]
        assert "SJ" not in names
        assert "SI" not in names
        assert "IR" not in names

    def test_splice_with_all_zero_counts_still_emitted(self) -> None:
        # Empty splice pattern with zero counts is still a valid "introns
        # were configured but this read doesn't span any" result → emit.
        splice = SpliceResult(sj_pattern="", si=0, ir=0)
        tags = build_tags(_base_values(splice=splice))
        names = [t[0] for t in tags]
        assert "SJ" in names
        assert "SI" in names
        assert "IR" in names


class TestDsTagInt32Bounds:
    """DS tag is dropped when it would overflow pysam's 'i' (int32) format.

    Regression test for the crash reported running step 09 against a
    genome-wide reference (terminus * 10000 exceeds int32 max around
    terminus > 215_000). pysam.set_tags raises struct.error on the bare
    write; ``build_tags`` instead omits DS to keep the BAM writable.
    """

    INT32_MAX = 2_147_483_647

    def test_ds_at_max_int32_still_emitted(self) -> None:
        # Exactly at the boundary — should still fit and be present.
        tags = build_tags(_base_values(doublesorter=self.INT32_MAX))
        ds = next((t for t in tags if t[0] == "DS"), None)
        assert ds == ("DS", self.INT32_MAX, "i")

    def test_ds_above_int32_dropped(self) -> None:
        # 1 above max — DS should be dropped rather than crash pysam.
        tags = build_tags(_base_values(doublesorter=self.INT32_MAX + 1))
        names = [t[0] for t in tags]
        assert "DS" not in names

    def test_ds_below_int32_min_dropped(self) -> None:
        # Negative overflow (unlikely in real data but defended for symmetry).
        tags = build_tags(_base_values(doublesorter=-(self.INT32_MAX + 2)))
        names = [t[0] for t in tags]
        assert "DS" not in names

    def test_other_tags_unaffected_when_ds_dropped(self) -> None:
        # When DS is dropped, the remaining tag order matches the same
        # 9-tag sequence with a hole where DS was.
        tags = build_tags(_base_values(doublesorter=10**12))
        names = [t[0] for t in tags]
        assert names == ["3E", "RC", "RS", "TL", "EC", "NC", "mL", "VR"]

    def test_genome_wide_position_typical_overflow(self) -> None:
        # terminus = 31_000_000 (chr5 of MpTak_v7.1) → DS = 310_000_000_000.
        # Way above int32; DS dropped, no crash.
        terminus = 31_000_000
        clip = 5
        ds_raw = terminus * 10000 + clip
        assert ds_raw > self.INT32_MAX, "test premise: DS must overflow"
        tags = build_tags(
            _base_values(terminus=terminus, doublesorter=ds_raw, remaining_clip_n=clip)
        )
        # 3E and RC are still present (their values fit int32 individually).
        d = {t[0]: t[1] for t in tags}
        assert d["3E"] == terminus
        assert d["RC"] == clip
        assert "DS" not in d
