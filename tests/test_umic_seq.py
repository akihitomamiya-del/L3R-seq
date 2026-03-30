"""Unit tests for UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py functions.

The module requires Bio, skbio, numpy, and matplotlib at import time.
All tests are skipped if these dependencies are unavailable.
"""
import os
import sys
import unittest
from unittest.mock import patch, MagicMock


def _load_umic_module():
    """Import UMIC-seq_fastq_v2.py without triggering its execution blocks.

    The module calls parser.parse_args() at import time. We patch it to
    return mode=None so none of the UMIextract/clustertest/clusterfull
    blocks run.
    """
    import importlib.util

    mock_args = MagicMock()
    mock_args.mode = None
    mock_args.threads = 4

    mod_path = os.path.join(
        os.path.dirname(__file__), '..', 'UMIC-seq_L3Rseq', 'UMIC-seq_fastq_v2.py')
    spec = importlib.util.spec_from_file_location('umic_seq', mod_path)
    mod = importlib.util.module_from_spec(spec)

    with patch('argparse.ArgumentParser.parse_args', return_value=mock_args):
        spec.loader.exec_module(mod)

    return mod


# Load once — None if dependencies (Bio, skbio, numpy, matplotlib) are missing
umic = None
_skip_reason = "Requires Bio, skbio, numpy, and matplotlib"
try:
    umic = _load_umic_module()
except ImportError as e:
    _skip_reason = f"Missing dependency: {e}"
except Exception as e:
    _skip_reason = f"Failed to load module: {e}"

if umic is not None:
    from Bio.Seq import Seq
    from Bio.SeqRecord import SeqRecord


def _mock_aln(target_begin, target_end_optimal):
    """Create a mock alignment result object."""
    aln = MagicMock()
    aln.target_begin = target_begin
    aln.target_end_optimal = target_end_optimal
    return aln


@unittest.skipIf(umic is None, _skip_reason)
class TestExtractLeft(unittest.TestCase):
    """extract_left: UMI coordinates upstream of probe alignment."""

    def test_basic(self):
        umic.umi_len = 18
        begin, end = umic.extract_left(_mock_aln(target_begin=50, target_end_optimal=100))
        self.assertEqual(begin, 32)
        self.assertEqual(end, 50)
        self.assertEqual(end - begin, 18)

    def test_umi_at_read_start(self):
        umic.umi_len = 18
        begin, end = umic.extract_left(_mock_aln(target_begin=18, target_end_optimal=60))
        self.assertEqual(begin, 0)
        self.assertEqual(end, 18)

    def test_short_umi(self):
        umic.umi_len = 5
        begin, end = umic.extract_left(_mock_aln(target_begin=20, target_end_optimal=50))
        self.assertEqual(begin, 15)
        self.assertEqual(end, 20)

    def test_negative_begin_when_too_close_to_start(self):
        umic.umi_len = 18
        begin, end = umic.extract_left(_mock_aln(target_begin=10, target_end_optimal=50))
        self.assertEqual(begin, -8)
        self.assertEqual(end, 10)


@unittest.skipIf(umic is None, _skip_reason)
class TestExtractRight(unittest.TestCase):
    """extract_right: UMI coordinates downstream of probe alignment."""

    def test_basic(self):
        umic.umi_len = 18
        begin, end = umic.extract_right(_mock_aln(target_begin=10, target_end_optimal=60))
        self.assertEqual(begin, 61)
        self.assertEqual(end, 79)
        self.assertEqual(end - begin, 18)

    def test_short_umi(self):
        umic.umi_len = 5
        begin, end = umic.extract_right(_mock_aln(target_begin=10, target_end_optimal=40))
        self.assertEqual(begin, 41)
        self.assertEqual(end, 46)

    def test_symmetry_with_extract_left(self):
        """Right end of extract_left == target_begin, left end of extract_right == target_end + 1."""
        umic.umi_len = 10
        aln = _mock_aln(target_begin=30, target_end_optimal=70)
        l_begin, l_end = umic.extract_left(aln)
        r_begin, r_end = umic.extract_right(aln)
        self.assertEqual(l_end, 30)       # ends at alignment start
        self.assertEqual(r_begin, 71)     # starts after alignment end


@unittest.skipIf(umic is None, _skip_reason)
class TestWithinClusterAnalysis(unittest.TestCase):
    """within_cluster_analysis: intra-cluster similarity scoring."""

    def test_single_member_returns_zero(self):
        labels = [0, 1, 1]
        umis = [SeqRecord(Seq("ATCGATCG")) for _ in range(3)]
        score, size = umic.within_cluster_analysis(0, labels, umis)
        self.assertEqual(score, 0.0)
        self.assertEqual(size, 1)

    def test_no_members_returns_zero(self):
        labels = [0, 0]
        umis = [SeqRecord(Seq("ATCG")), SeqRecord(Seq("ATCG"))]
        score, size = umic.within_cluster_analysis(5, labels, umis)
        self.assertEqual(score, 0.0)
        self.assertEqual(size, 0)

    def test_identical_sequences_high_similarity(self):
        labels = [0, 0, 0]
        umis = [SeqRecord(Seq("ATCGATCGATCGATCG")) for _ in range(3)]
        score, size = umic.within_cluster_analysis(0, labels, umis)
        self.assertEqual(size, 3)
        self.assertGreater(score, 0)

    def test_different_sequences_lower_similarity(self):
        labels = [0, 0]
        umis = [
            SeqRecord(Seq("AAAAAAAAAAAAAAAA")),
            SeqRecord(Seq("TTTTTTTTTTTTTTTT")),
        ]
        score_diff, _ = umic.within_cluster_analysis(0, labels, umis)

        labels2 = [0, 0]
        umis2 = [
            SeqRecord(Seq("ATCGATCGATCGATCG")),
            SeqRecord(Seq("ATCGATCGATCGATCG")),
        ]
        score_same, _ = umic.within_cluster_analysis(0, labels2, umis2)

        self.assertGreater(score_same, score_diff)


@unittest.skipIf(umic is None, _skip_reason)
class TestAveragesWithinCluster(unittest.TestCase):
    """averages_withincluster: aggregate stats across clusters."""

    def test_single_cluster(self):
        labels = [0, 0, 0]
        umis = [SeqRecord(Seq("ATCGATCGATCG")) for _ in range(3)]
        avg_sim, avg_len, med_len = umic.averages_withincluster(1, labels, umis)
        self.assertGreater(avg_sim, 0)
        self.assertAlmostEqual(avg_len, 3.0)
        self.assertAlmostEqual(med_len, 3.0)

    def test_multiple_clusters(self):
        labels = [0, 0, 1, 1, 1]
        umis = [SeqRecord(Seq("ATCGATCG")) for _ in range(5)]
        avg_sim, avg_len, med_len = umic.averages_withincluster(2, labels, umis)
        self.assertGreater(avg_sim, 0)
        # Cluster 0 has 2 members, cluster 1 has 3 → avg 2.5, median 2.5
        self.assertAlmostEqual(avg_len, 2.5)
        self.assertAlmostEqual(med_len, 2.5)


if __name__ == '__main__':
    unittest.main()
