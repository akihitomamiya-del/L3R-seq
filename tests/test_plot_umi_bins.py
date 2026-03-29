"""Unit tests for scripts/plot_umi_bins.py data-processing functions."""
import csv
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add scripts/ to import path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'scripts'))
import plot_umi_bins as pub


class TestIsUmicSeq(unittest.TestCase):
    def test_detects_umic_log(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.touch()
            self.assertTrue(pub._is_umic_seq(d, "bc1/rpi1"))

    def test_no_log(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(pub._is_umic_seq(d, "bc1/rpi1"))


class TestFindSamples(unittest.TestCase):
    def test_finds_longread_sample(self):
        with tempfile.TemporaryDirectory() as d:
            tsv = Path(d) / "04_umi" / "bc1" / "rpi1" / "read_binning" / "umi_cluster_stats.tsv"
            tsv.parent.mkdir(parents=True)
            tsv.touch()
            self.assertEqual(pub.find_samples(d), ["bc1/rpi1"])

    def test_finds_umic_sample(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.touch()
            self.assertEqual(pub.find_samples(d), ["bc1/rpi1"])

    def test_multiple_samples_sorted(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ["bc2/rpi2", "bc1/rpi1"]:
                log = Path(d) / "04_umi" / name / "UMIclusterfull.log"
                log.parent.mkdir(parents=True)
                log.touch()
            self.assertEqual(pub.find_samples(d), ["bc1/rpi1", "bc2/rpi2"])

    def test_empty_dir(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(pub.find_samples(d), [])

    def test_no_04_umi(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "other").mkdir()
            self.assertEqual(pub.find_samples(d), [])


class TestParseUmicLog(unittest.TestCase):
    def test_parses_cluster_entries(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.write_text(
                "Cluster 1: 15 entries.    Seq remaining: 100\n"
                "Cluster 2: 8 entries.    Seq remaining: 92\n"
                "Cluster 3: 3 entries.    Seq remaining: 89\n"
            )
            self.assertEqual(pub._parse_umic_log(d, "bc1/rpi1"), [15, 8, 3])

    def test_missing_log(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(pub._parse_umic_log(d, "bc1/rpi1"), [])

    def test_mixed_lines(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.write_text(
                "Starting clustering...\n"
                "Cluster 1: 10 entries.    Seq remaining: 50\n"
                "Some other output\n"
                "Cluster 2: 5 entries.    Seq remaining: 45\n"
                "Ended early due to small average cluster size.\n"
            )
            self.assertEqual(pub._parse_umic_log(d, "bc1/rpi1"), [10, 5])


class TestLoadClusterStats(unittest.TestCase):
    def test_longread_format(self):
        with tempfile.TemporaryDirectory() as d:
            tsv = Path(d) / "04_umi" / "bc1" / "rpi1" / "read_binning" / "umi_cluster_stats.tsv"
            tsv.parent.mkdir(parents=True)
            tsv.write_text(
                "stage\tmetric\tvalue\n"
                "bins\ttotal_bins\t50\n"
                "bins\tkept_bins\t40\n"
                "bins\tsmall_bins\t10\n"
            )
            stats = pub.load_cluster_stats(d, "bc1/rpi1")
            self.assertEqual(stats['bins_total_bins'], '50')
            self.assertEqual(stats['bins_kept_bins'], '40')
            self.assertEqual(stats['bins_small_bins'], '10')

    def test_umic_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.write_text(
                "Cluster 1: 10 entries.\n"
                "Cluster 2: 5 entries.\n"
                "Cluster 3: 2 entries.\n"
            )
            stats = pub.load_cluster_stats(d, "bc1/rpi1")
            self.assertEqual(stats['bins_total_bins'], '3')
            self.assertEqual(stats['bins_kept_bins'], '2')   # size >= 3
            self.assertEqual(stats['bins_small_bins'], '1')   # size < 3
            self.assertEqual(stats['bins_reads_in_kept_bins'], '15')
            self.assertEqual(stats['bins_reads_assigned'], '17')

    def test_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(pub.load_cluster_stats(d, "bc1/rpi1"), {})


class TestLoadClusterSizeDist(unittest.TestCase):
    def test_prefers_binning_stats(self):
        """umi_binning_stats.txt (post-BWA) is preferred over umi_cluster_size_dist.tsv."""
        with tempfile.TemporaryDirectory() as d:
            rb = Path(d) / "04_umi" / "bc1" / "rpi1" / "read_binning"
            rb.mkdir(parents=True)
            # Both files exist — binning_stats should win
            (rb / "umi_binning_stats.txt").write_text(
                "umi_name\tread_count\numi1;size=3\t5\numi2;size=3\t7\numi3;size=4\t5\n")
            (rb / "umi_cluster_size_dist.tsv").write_text(
                "cluster_size\tcount\n3\t20\n5\t15\n")
            dist = pub.load_cluster_size_dist(d, "bc1/rpi1")
            # Should reflect binning_stats: two bins of size 5, one of size 7
            self.assertEqual(dist, {5: 2, 7: 1})

    def test_falls_back_to_cluster_size_dist(self):
        """Falls back to umi_cluster_size_dist.tsv when binning_stats is absent."""
        with tempfile.TemporaryDirectory() as d:
            tsv = Path(d) / "04_umi" / "bc1" / "rpi1" / "read_binning" / "umi_cluster_size_dist.tsv"
            tsv.parent.mkdir(parents=True)
            tsv.write_text("cluster_size\tcount\n3\t20\n5\t15\n10\t5\n")
            self.assertEqual(pub.load_cluster_size_dist(d, "bc1/rpi1"), {3: 20, 5: 15, 10: 5})

    def test_umic_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "04_umi" / "bc1" / "rpi1" / "UMIclusterfull.log"
            log.parent.mkdir(parents=True)
            log.write_text(
                "Cluster 1: 5 entries.\n"
                "Cluster 2: 5 entries.\n"
                "Cluster 3: 3 entries.\n"
            )
            self.assertEqual(pub.load_cluster_size_dist(d, "bc1/rpi1"), {5: 2, 3: 1})

    def test_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(pub.load_cluster_size_dist(d, "bc1/rpi1"), {})


class TestLoadBinSizeDist(unittest.TestCase):
    def test_loads_tsv(self):
        with tempfile.TemporaryDirectory() as d:
            tsv = Path(d) / "04_umi" / "bc1" / "rpi1" / "read_binning" / "umi_bin_size_dist.tsv"
            tsv.parent.mkdir(parents=True)
            tsv.write_text("bin_name\treads\tstatus\numi1\t10\tkept\numi2\t2\tfiltered\n")
            bins = pub.load_bin_size_dist(d, "bc1/rpi1")
            self.assertEqual(len(bins), 2)
            self.assertEqual(bins[0], ("umi1", 10, "kept"))
            self.assertEqual(bins[1], ("umi2", 2, "filtered"))

    def test_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(pub.load_bin_size_dist(d, "bc1/rpi1"), [])


class TestComputeQualityByBinsize(unittest.TestCase):
    def test_basic(self):
        records = [
            (5, 2, 0, 1000),  # bin_size=5, ec=2, nc=0, ml=1000
            (5, 1, 1, 1000),  # bin_size=5, ec=1, nc=1, ml=1000
            (3, 0, 0, 500),   # bin_size=3, nc=0
            (3, 1, 2, 500),   # bin_size=3, nc=2
        ]
        result = pub.compute_quality_by_binsize(records)
        # bin_size=5: 2 reads, 1 error-free, noise = 1/2000*1000 = 0.5
        self.assertEqual(result[5]['reads'], 2)
        self.assertAlmostEqual(result[5]['error_free_pct'], 50.0)
        self.assertAlmostEqual(result[5]['noise_per_1k'], 0.5)
        # bin_size=3: 2 reads, 1 error-free, noise = 2/1000*1000 = 2.0
        self.assertEqual(result[3]['reads'], 2)
        self.assertAlmostEqual(result[3]['error_free_pct'], 50.0)
        self.assertAlmostEqual(result[3]['noise_per_1k'], 2.0)

    def test_all_error_free(self):
        records = [(4, 1, 0, 800), (4, 2, 0, 900)]
        result = pub.compute_quality_by_binsize(records)
        self.assertAlmostEqual(result[4]['error_free_pct'], 100.0)
        self.assertAlmostEqual(result[4]['noise_per_1k'], 0.0)

    def test_skips_zero_binsize(self):
        records = [(0, 1, 1, 500)]
        self.assertEqual(pub.compute_quality_by_binsize(records), {})

    def test_zero_matched_length(self):
        records = [(3, 0, 0, 0)]
        result = pub.compute_quality_by_binsize(records)
        self.assertAlmostEqual(result[3]['noise_per_1k'], 0.0)


class TestComputeThresholdTable(unittest.TestCase):
    def test_default_starts_at_1(self):
        records = [
            (1, 0, 0, 100),
            (2, 0, 1, 200),
            (3, 1, 0, 300),
            (4, 2, 2, 400),
            (5, 3, 0, 500),
        ]
        rows = pub.compute_threshold_table(records)
        self.assertEqual(len(rows), 5)
        self.assertEqual(rows[0]['threshold'], 'n >= 1')
        self.assertEqual(rows[0]['reads'], 5)
        self.assertEqual(rows[4]['threshold'], 'n >= 5')
        self.assertEqual(rows[4]['reads'], 1)
        self.assertAlmostEqual(rows[4]['error_free_pct'], 100.0)

    def test_starts_at_min_bin(self):
        records = [(i, 0, 0, 100) for i in range(3, 8)]
        rows = pub.compute_threshold_table(records, min_bin=3)
        self.assertEqual(rows[0]['threshold'], 'n >= 3')
        self.assertEqual(rows[0]['reads'], 5)
        self.assertEqual(rows[4]['threshold'], 'n >= 7')
        self.assertEqual(rows[4]['reads'], 1)

    def test_no_misleading_duplicates(self):
        # With min_bin=3, no data below 3 exists — table should not
        # show n>=1 or n>=2 rows that would be identical to n>=3.
        records = [(3, 0, 0, 100), (4, 0, 0, 100), (5, 0, 0, 100)]
        rows = pub.compute_threshold_table(records, min_bin=3)
        thresholds = [r['threshold'] for r in rows]
        self.assertNotIn('n >= 1', thresholds)
        self.assertNotIn('n >= 2', thresholds)
        self.assertEqual(thresholds[0], 'n >= 3')

    def test_cluster_dist_adds_bins_and_survival(self):
        records = [(3, 0, 0, 100), (3, 0, 0, 100), (4, 0, 0, 100)]
        cluster_dist = {1: 10, 2: 5, 3: 4, 4: 2}
        rows = pub.compute_threshold_table(records, min_bin=1, cluster_dist=cluster_dist)
        # n>=1: 21 bins, 3 reads
        self.assertEqual(rows[0]['bins'], 21)
        self.assertEqual(rows[0]['reads'], 3)
        self.assertAlmostEqual(rows[0]['survival_pct'], 3 / 21 * 100)
        # n>=3: 6 bins, 3 reads
        r3 = [r for r in rows if r['threshold'] == 'n >= 3'][0]
        self.assertEqual(r3['bins'], 6)
        self.assertEqual(r3['reads'], 3)

    def test_no_cluster_dist_omits_bins(self):
        records = [(3, 0, 0, 100)]
        rows = pub.compute_threshold_table(records, min_bin=3)
        self.assertNotIn('bins', rows[0])

    def test_decreasing_reads(self):
        records = [(i, 0, 0, 100) for i in range(1, 6)]
        rows = pub.compute_threshold_table(records)
        read_counts = [r['reads'] for r in rows]
        self.assertEqual(read_counts, [5, 4, 3, 2, 1])

    def test_empty(self):
        self.assertEqual(pub.compute_threshold_table([]), [])


class TestLoadCsvQuality(unittest.TestCase):
    def test_loads_csv_with_ubs(self):
        with tempfile.TemporaryDirectory() as d:
            csv_dir = Path(d) / "10_csv"
            csv_dir.mkdir()
            (csv_dir / "sample_rpi1.csv").write_text(
                "QNAME,editing_count,noise_count,matched_length\n"
                "umi1bins;ubs=5,2,0,1000\n"
                "umi2bins;ubs=3,1,1,800\n"
            )
            records = pub.load_csv_quality(d, "bc1/rpi1")
            self.assertIsNotNone(records)
            self.assertEqual(len(records), 2)
            self.assertEqual(records[0], (5, 2, 0, 1000))
            self.assertEqual(records[1], (3, 1, 1, 800))

    def test_sam_tag_prefix(self):
        with tempfile.TemporaryDirectory() as d:
            csv_dir = Path(d) / "10_csv"
            csv_dir.mkdir()
            (csv_dir / "sample_rpi1.csv").write_text(
                "QNAME,editing_count,noise_count,matched_length\n"
                "umi1bins;ubs=4,EC:i:3,NC:i:1,ML:i:500\n"
            )
            records = pub.load_csv_quality(d, "bc1/rpi1")
            self.assertIsNotNone(records)
            self.assertEqual(records[0], (4, 3, 1, 500))

    def test_no_csv(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(pub.load_csv_quality(d, "bc1/rpi1"))

    def test_skips_non_umi_qnames(self):
        with tempfile.TemporaryDirectory() as d:
            csv_dir = Path(d) / "10_csv"
            csv_dir.mkdir()
            (csv_dir / "sample_rpi1.csv").write_text(
                "QNAME,editing_count,noise_count,matched_length\n"
                "umi1bins;ubs=5,1,0,500\n"
                "not_a_umi_read,2,1,300\n"
            )
            records = pub.load_csv_quality(d, "bc1/rpi1")
            self.assertEqual(len(records), 1)


if __name__ == '__main__':
    unittest.main()
