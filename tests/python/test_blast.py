"""Tests for src/l3rseq/blast.py — BLAST subprocess wrapper.

subprocess.run is mocked throughout. Each mock simulates blastn by writing
a pre-canned tabular output file, so we can verify the hit-extraction
and flow logic without needing an actual BLAST installation.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from l3rseq.blast import BatchBlastResult, run_batch_blast


def _make_fake_blast_db(path: Path) -> None:
    """Create dummy sidecar files matching path.* so _blast_db_exists returns True."""
    path.parent.mkdir(parents=True, exist_ok=True)
    (path.parent / f"{path.name}.nhr").write_bytes(b"")
    (path.parent / f"{path.name}.nin").write_bytes(b"")
    (path.parent / f"{path.name}.nsq").write_bytes(b"")


def _tabular_line(read_idx: int, subject: str = "MT") -> str:
    """One row of blastn -outfmt 6 output for Rightclip_<idx>."""
    return (
        f"Rightclip_{read_idx}\t{subject}\t100.0\t50\t0\t0\t1\t50\t"
        f"1\t50\t1e-20\t100\n"
    )


def _make_blastn_mock(outputs_by_call: list[list[int]]):
    """Return a side_effect that writes per-call hit lists to the -out path.

    outputs_by_call[i] is the list of read indices to write on the i-th call.
    """
    call_idx = [0]

    def side_effect(cmd, **kwargs):
        out_path = Path(cmd[cmd.index("-out") + 1])
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w") as fh:
            for hid in outputs_by_call[call_idx[0]]:
                fh.write(_tabular_line(hid))
        call_idx[0] += 1

        class _MockResult:
            returncode = 0

        return _MockResult()

    return side_effect


class TestEmptyAndMissingDb:
    """Short-circuit paths that produce empty results without running blastn."""

    def test_empty_queries_returns_empty(self, tmp_path: Path) -> None:
        result = run_batch_blast(
            queries=[], chrm_db=None, cdna_db=None, workdir=tmp_path
        )
        assert result == BatchBlastResult(
            chrm_hits=frozenset(),
            cdna_hits=frozenset(),
            query_fasta_path=None,
            chrm_raw_path=None,
            cdna_raw_path=None,
        )

    def test_no_chrm_db_short_circuits_entirely(self, tmp_path: Path) -> None:
        # Matches bash: if ChrM DB is missing, no BLAST runs at all,
        # regardless of cDNA DB presence (scripts/09_tail_correct.sh:322).
        queries = [(1, "ACGT"), (2, "TTTT")]
        with patch("l3rseq.blast.subprocess.run") as mock_run:
            result = run_batch_blast(queries, None, None, tmp_path)
        mock_run.assert_not_called()
        assert result.chrm_hits == frozenset()
        assert result.cdna_hits == frozenset()
        assert result.query_fasta_path is None
        # FASTA should NOT have been written
        assert not (tmp_path / "blast_batch.fa").exists()

    def test_chrm_db_path_points_nowhere_short_circuits(self, tmp_path: Path) -> None:
        queries = [(1, "ACGT")]
        with patch("l3rseq.blast.subprocess.run") as mock_run:
            result = run_batch_blast(queries, tmp_path / "nonexistent", None, tmp_path)
        mock_run.assert_not_called()
        assert result.query_fasta_path is None


class TestChrmOnlySearch:
    """ChrM search with no cDNA fallback."""

    def test_chrm_hits_extracted_from_tabular(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        queries = [(1, "ACGT"), (2, "TTTT"), (3, "GGGG")]

        with patch(
            "l3rseq.blast.subprocess.run",
            side_effect=_make_blastn_mock([[1, 3]]),
        ):
            result = run_batch_blast(queries, chrm_db, None, tmp_path)

        assert result.chrm_hits == frozenset({1, 3})
        assert result.cdna_hits == frozenset()
        assert result.query_fasta_path == tmp_path / "blast_batch.fa"
        assert result.chrm_raw_path == tmp_path / "batch_blast_chrm_raw.txt"
        assert result.cdna_raw_path is None

    def test_query_fasta_format_matches_bash(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        queries = [(42, "AAATTTCCC"), (7, "GGGG")]

        with patch("l3rseq.blast.subprocess.run", side_effect=_make_blastn_mock([[]])):
            result = run_batch_blast(queries, chrm_db, None, tmp_path)

        assert result.query_fasta_path is not None
        content = result.query_fasta_path.read_text()
        # Exact byte match with bash `printf '>Rightclip_%s\n%s\n'`
        assert content == ">Rightclip_42\nAAATTTCCC\n>Rightclip_7\nGGGG\n"

    def test_no_hits_returns_empty_frozenset(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        queries = [(1, "ACGT"), (2, "TTTT")]

        with patch("l3rseq.blast.subprocess.run", side_effect=_make_blastn_mock([[]])):
            result = run_batch_blast(queries, chrm_db, None, tmp_path)

        assert result.chrm_hits == frozenset()
        # Query FASTA is still written even when no hits
        assert result.query_fasta_path is not None

    def test_blastn_command_line(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        queries = [(1, "ACGT")]

        with patch(
            "l3rseq.blast.subprocess.run",
            side_effect=_make_blastn_mock([[]]),
        ) as mock_run:
            run_batch_blast(queries, chrm_db, None, tmp_path, blastn="blastn")

        # Verify exact argv passed to blastn
        call_args = mock_run.call_args_list[0].args[0]
        assert call_args[0] == "blastn"
        assert "-task" in call_args and "megablast" in call_args
        assert "-db" in call_args and str(chrm_db) in call_args
        assert "-query" in call_args and str(tmp_path / "blast_batch.fa") in call_args


class TestCdnaFallback:
    """cDNA search runs only on queries that missed ChrM."""

    def test_cdna_searched_on_missed_chrm_queries(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        cdna_db = tmp_path / "cdna_db"
        _make_fake_blast_db(chrm_db)
        _make_fake_blast_db(cdna_db)

        queries = [(1, "AAA"), (2, "TTT"), (3, "CCC"), (4, "GGG")]

        # Call 1: ChrM hits 1 and 2
        # Call 2: cDNA hits 3 (4 misses both DBs)
        with patch(
            "l3rseq.blast.subprocess.run",
            side_effect=_make_blastn_mock([[1, 2], [3]]),
        ) as mock_run:
            result = run_batch_blast(queries, chrm_db, cdna_db, tmp_path)

        assert result.chrm_hits == frozenset({1, 2})
        assert result.cdna_hits == frozenset({3})
        # Two blastn invocations — one per DB
        assert mock_run.call_count == 2
        # cDNA call should have received the no-chrm FASTA
        cdna_call = mock_run.call_args_list[1].args[0]
        cdna_query = cdna_call[cdna_call.index("-query") + 1]
        assert cdna_query == str(tmp_path / "batch_no_chrm.fa")
        # And the no-chrm FASTA should only contain queries 3 and 4
        no_chrm_content = (tmp_path / "batch_no_chrm.fa").read_text()
        assert ">Rightclip_3" in no_chrm_content
        assert ">Rightclip_4" in no_chrm_content
        assert ">Rightclip_1" not in no_chrm_content
        assert ">Rightclip_2" not in no_chrm_content

    def test_cdna_skipped_when_all_queries_hit_chrm(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        cdna_db = tmp_path / "cdna_db"
        _make_fake_blast_db(chrm_db)
        _make_fake_blast_db(cdna_db)

        queries = [(1, "AAA"), (2, "TTT")]

        # ChrM hits everything → no cDNA queries left
        with patch(
            "l3rseq.blast.subprocess.run",
            side_effect=_make_blastn_mock([[1, 2]]),
        ) as mock_run:
            result = run_batch_blast(queries, chrm_db, cdna_db, tmp_path)

        assert result.chrm_hits == frozenset({1, 2})
        assert result.cdna_hits == frozenset()
        # Only one blastn call (ChrM)
        assert mock_run.call_count == 1

    def test_cdna_db_missing_skips_cdna_search(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        # cdna_db path exists but no BLAST sidecars → not a real DB
        cdna_db = tmp_path / "not_a_db"

        queries = [(1, "AAA")]
        with patch(
            "l3rseq.blast.subprocess.run",
            side_effect=_make_blastn_mock([[]]),
        ) as mock_run:
            result = run_batch_blast(queries, chrm_db, cdna_db, tmp_path)

        assert result.cdna_hits == frozenset()
        assert mock_run.call_count == 1  # ChrM only


class TestHitParser:
    """_parse_hits internals — exercised indirectly via the top-level function."""

    def test_malformed_qseqid_skipped(self, tmp_path: Path) -> None:
        chrm_db = tmp_path / "chrm_db"
        _make_fake_blast_db(chrm_db)
        queries = [(1, "AAA")]

        # Side effect writes a line with an unparseable qseqid
        def side_effect(cmd, **kwargs):
            out_path = Path(cmd[cmd.index("-out") + 1])
            out_path.write_text(
                "Rightclip_1\tMT\t100\n"
                "not_a_valid_id\tMT\t100\n"
                "Rightclip_notanumber\tMT\t100\n"
                "# a comment line\n"
            )

            class _MockResult:
                returncode = 0

            return _MockResult()

        with patch("l3rseq.blast.subprocess.run", side_effect=side_effect):
            result = run_batch_blast(queries, chrm_db, None, tmp_path)

        # Only Rightclip_1 parsed successfully
        assert result.chrm_hits == frozenset({1})
