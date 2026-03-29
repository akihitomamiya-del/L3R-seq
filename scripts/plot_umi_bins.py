#!/usr/bin/env python3
"""
plot_umi_bins.py — Generate UMI bin analysis plots from L3Rseq step 04 output.

Reads the TSV files produced by longread-umi binning and (optionally) the
step 10 CSV to compute per-bin-size quality metrics.

Usage:
    # Single sample — bin size histogram only (step 04 data)
    python3 scripts/plot_umi_bins.py runs/E230426_barcode48 \
        --sample barcode48/barcode48_RPI_3

    # Single sample — full analysis with quality (needs step 10 CSV)
    python3 scripts/plot_umi_bins.py runs/E230426_barcode48 \
        --sample barcode48/barcode48_RPI_3 --quality

    # All samples in a run directory
    python3 scripts/plot_umi_bins.py runs/E230426_barcode48 --quality

    # Compare two runs (e.g., longread-umi vs UMIC-seq)
    python3 scripts/plot_umi_bins.py runs/E230426_barcode48 \
        --compare runs/E230426_barcode48_UMICseq \
        --sample barcode48/barcode48_RPI_3 --quality

Output: PNG saved next to step 04 data or in --outdir.
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

def require_matplotlib():
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.gridspec as gridspec
        import numpy as np
        return plt, gridspec, np
    except ImportError:
        print("ERROR: matplotlib and numpy are required.", file=sys.stderr)
        print("       pip install matplotlib numpy", file=sys.stderr)
        sys.exit(1)


def _is_umic_seq(run_dir, sample):
    """Detect if sample was processed with UMIC-seq (has UMIclusterfull.log)."""
    return (Path(run_dir) / "04_umi" / sample / "UMIclusterfull.log").exists()


def find_samples(run_dir):
    """Find all barcode/RPI sample directories under 04_umi/."""
    samples = []
    umi_dir = Path(run_dir) / "04_umi"
    if not umi_dir.exists():
        return samples
    for bc_dir in sorted(umi_dir.iterdir()):
        if not bc_dir.is_dir():
            continue
        for rpi_dir in sorted(bc_dir.iterdir()):
            if not rpi_dir.is_dir():
                continue
            # Accept either longread-umi (read_binning/) or UMIC-seq (UMIclusterfull.log)
            has_lr = (rpi_dir / "read_binning" / "umi_cluster_stats.tsv").exists()
            has_um = (rpi_dir / "UMIclusterfull.log").exists()
            if has_lr or has_um:
                samples.append(f"{bc_dir.name}/{rpi_dir.name}")
    return samples


def _parse_umic_log(run_dir, sample):
    """Parse UMIclusterfull.log to extract cluster sizes."""
    path = Path(run_dir) / "04_umi" / sample / "UMIclusterfull.log"
    sizes = []
    if not path.exists():
        return sizes
    with open(path) as f:
        for line in f:
            m = re.findall(r'Cluster \d+: (\d+) entries', line)
            sizes.extend(int(x) for x in m)
    return sizes


def load_cluster_stats(run_dir, sample):
    """Load cluster stats — longread-umi TSV or UMIC-seq log."""
    # Try longread-umi format first
    path = Path(run_dir) / "04_umi" / sample / "read_binning" / "umi_cluster_stats.tsv"
    if path.exists():
        stats = {}
        with open(path) as f:
            reader = csv.DictReader(f, delimiter='\t')
            for row in reader:
                stats[f"{row['stage']}_{row['metric']}"] = row['value']
        return stats

    # Fall back to UMIC-seq: build stats from cluster log
    sizes = _parse_umic_log(run_dir, sample)
    if not sizes:
        return {}
    min_bin = 3
    kept = [s for s in sizes if s >= min_bin]
    small = [s for s in sizes if s < min_bin]
    return {
        'bins_total_bins': str(len(sizes)),
        'bins_kept_bins': str(len(kept)),
        'bins_small_bins': str(len(small)),
        'bins_reads_in_kept_bins': str(sum(kept)),
        'bins_reads_assigned': str(sum(sizes)),
        'bins_min_bin_size': str(min_bin),
        'dedup_max_cluster_size': str(max(sizes)) if sizes else '0',
        'dedup_mean_cluster_size': f'{sum(sizes)/len(sizes):.1f}' if sizes else '0',
    }


def load_cluster_size_dist(run_dir, sample):
    """Load bin size distribution — final read counts per bin.

    For longread-umi: prefers umi_binning_stats.txt (post-BWA assignment)
    over umi_cluster_size_dist.tsv (pre-assignment UMI cluster sizes).
    The BWA step reassigns reads from removed singletons to nearby bins,
    so the final bin sizes can be larger than the initial cluster sizes.

    For UMIC-seq: parses UMIclusterfull.log (no remapping step).
    """
    # longread-umi: prefer final bin sizes from umi_binning_stats.txt
    stats_path = Path(run_dir) / "04_umi" / sample / "read_binning" / "umi_binning_stats.txt"
    if stats_path.exists():
        dist = defaultdict(int)
        with open(stats_path) as f:
            reader = csv.DictReader(f, delimiter='\t')
            for row in reader:
                dist[int(row['read_count'])] += 1
        return dict(dist)

    # longread-umi fallback: umi_cluster_size_dist.tsv (older pipeline versions)
    tsv_path = Path(run_dir) / "04_umi" / sample / "read_binning" / "umi_cluster_size_dist.tsv"
    if tsv_path.exists():
        dist = {}
        with open(tsv_path) as f:
            reader = csv.DictReader(f, delimiter='\t')
            for row in reader:
                dist[int(row['cluster_size'])] = int(row['count'])
        return dist

    # UMIC-seq: parse cluster sizes from log
    sizes = _parse_umic_log(run_dir, sample)
    if not sizes:
        return {}
    dist = defaultdict(int)
    for s in sizes:
        dist[s] += 1
    return dict(dist)


def load_bin_size_dist(run_dir, sample):
    """Load umi_bin_size_dist.tsv → list of (bin_name, reads, status)."""
    path = Path(run_dir) / "04_umi" / sample / "read_binning" / "umi_bin_size_dist.tsv"
    bins = []
    if not path.exists():
        return bins
    with open(path) as f:
        reader = csv.DictReader(f, delimiter='\t')
        for row in reader:
            bins.append((row['bin_name'], int(row['reads']), row['status']))
    return bins


def load_csv_quality(run_dir, sample):
    """Load step 10 CSV, return per-read (bin_size, editing_count, noise_count, matched_length)."""
    # Find CSV — naming: barcode_rpi.csv at 10_csv/
    bc, rpi = sample.split('/')
    csv_dir = Path(run_dir) / "10_csv"
    candidates = list(csv_dir.glob(f"*{rpi}*.csv")) if csv_dir.exists() else []
    if not candidates:
        # Try subdirectory pattern
        csv_dir2 = Path(run_dir) / "10_csv" / bc / rpi
        candidates = list(csv_dir2.glob("*.csv")) if csv_dir2.exists() else []
    if not candidates:
        return None

    csv_path = candidates[0]

    # Build bin_name → bin_size lookup from umi_binning_stats.txt
    stats_path = Path(run_dir) / "04_umi" / sample / "read_binning" / "umi_binning_stats.txt"
    bin_sizes = {}
    if stats_path.exists():
        with open(stats_path) as f:
            reader = csv.DictReader(f, delimiter='\t')
            for row in reader:
                name = row['umi_name'].split(';')[0]  # "umi286" from "umi286;size=11"
                bin_sizes[name] = int(row['read_count'])

    records = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            qname = row['QNAME']
            # QNAME format: "umi642bins;ubs=6"
            bin_name_match = re.match(r'(umi\d+)bins', qname)
            ubs_match = re.search(r'ubs=(\d+)', qname)
            if not bin_name_match:
                continue

            bin_name = bin_name_match.group(1)
            bin_size = int(ubs_match.group(1)) if ubs_match else bin_sizes.get(bin_name, 0)

            ec_raw = row.get('editing_count', '0')
            nc_raw = row.get('noise_count', '0')
            ml_raw = row.get('matched_length', '0')

            # Strip SAM tag prefix if present
            ec = int(re.sub(r'.*:', '', str(ec_raw)) or 0)
            nc = int(re.sub(r'.*:', '', str(nc_raw)) or 0)
            ml = int(re.sub(r'.*:', '', str(ml_raw)) or 0)

            records.append((bin_size, ec, nc, ml))

    return records


def compute_quality_by_binsize(records):
    """Group records by bin_size, return per-size metrics."""
    by_size = defaultdict(list)
    for bs, ec, nc, ml in records:
        if bs > 0:
            by_size[bs].append((ec, nc, ml))

    result = {}
    for size in sorted(by_size):
        entries = by_size[size]
        n = len(entries)
        error_free = sum(1 for _, nc, _ in entries if nc == 0)
        total_noise = sum(nc for _, nc, _ in entries)
        total_ml = sum(ml for _, _, ml in entries)
        noise_per_1k = (total_noise / total_ml * 1000) if total_ml > 0 else 0
        result[size] = {
            'reads': n,
            'error_free_pct': error_free / n * 100 if n > 0 else 0,
            'noise_per_1k': noise_per_1k,
        }
    return result


def compute_threshold_table(records, min_bin=1, cluster_dist=None):
    """Compute quality at each bin size threshold, starting from min_bin.

    Thresholds below min_bin are omitted because those bins were already
    excluded at step 04 and never entered the pipeline.

    If cluster_dist is provided (dict of {size: count} from step 04),
    each row also includes the number of bins that entered the pipeline
    and the survival rate to step 10.
    """
    rows = []
    for thresh in range(min_bin, min_bin + 5):
        subset = [(ec, nc, ml) for bs, ec, nc, ml in records if bs >= thresh]
        n = len(subset)
        if n == 0:
            continue
        error_free = sum(1 for _, nc, _ in subset if nc == 0)
        total_noise = sum(nc for _, nc, _ in subset)
        total_ml = sum(ml for _, _, ml in subset)
        noise_per_1k = (total_noise / total_ml * 1000) if total_ml > 0 else 0
        row = {
            'threshold': f'n >= {thresh}',
            'reads': n,
            'error_free_pct': error_free / n * 100,
            'noise_per_1k': noise_per_1k,
        }
        if cluster_dist is not None:
            bins = sum(c for s, c in cluster_dist.items() if s >= thresh)
            row['bins'] = bins
            row['survival_pct'] = n / bins * 100 if bins > 0 else 0
        rows.append(row)
    return rows


def plot_single(run_dir, sample, quality_records, outpath, method_label="longread-umi"):
    """Generate a bin analysis plot for a single sample."""
    plt, gridspec, np = require_matplotlib()

    stats = load_cluster_stats(run_dir, sample)
    cluster_dist = load_cluster_size_dist(run_dir, sample)
    bin_dist = load_bin_size_dist(run_dir, sample)

    if not cluster_dist:
        print(f"  WARNING: No cluster distribution data for {sample}", file=sys.stderr)
        return

    has_quality = quality_records is not None and len(quality_records) > 0
    nrows = 4 if has_quality else 1  # extra row for threshold table
    fig_h = 20 if has_quality else 6

    fig = plt.figure(figsize=(10, fig_h))
    fig.patch.set_facecolor('white')

    min_bin = int(stats.get('bins_min_bin_size', 3))
    total_bins = int(stats.get('bins_total_bins', 0))
    kept_bins = int(stats.get('bins_kept_bins', 0))
    small_bins = int(stats.get('bins_small_bins', 0))
    reads_kept = int(stats.get('bins_reads_in_kept_bins', 0))

    sample_label = sample.replace('/', ' / ')
    fig.suptitle(f'{sample_label} ({method_label}): UMI Bin Analysis',
                 fontsize=16, fontweight='bold', y=0.98)

    if has_quality:
        gs = gridspec.GridSpec(nrows, 1, figure=fig,
                               height_ratios=[3, 3, 3, 2],
                               hspace=0.40, left=0.10, right=0.92, top=0.93, bottom=0.05)
    else:
        gs = gridspec.GridSpec(1, 1, figure=fig,
                               left=0.10, right=0.92, top=0.88, bottom=0.12)

    # ── Panel 1: Bin size histogram ──────────────────────────────────────────

    ax1 = fig.add_subplot(gs[0])

    sizes = sorted(cluster_dist.keys())
    max_size = max(sizes)
    x_range = range(1, max_size + 1)

    survived = []
    filtered = []
    for s in x_range:
        count = cluster_dist.get(s, 0)
        if s >= min_bin:
            survived.append(count)
            filtered.append(0)
        else:
            survived.append(0)
            filtered.append(count)

    ax1.bar(list(x_range), survived, color='#55A868', edgecolor='black', linewidth=0.3,
            label=f'Survived ({kept_bins:,})', alpha=0.85)
    ax1.bar(list(x_range), filtered, color='#C44E52', edgecolor='black', linewidth=0.3,
            label=f'Filtered ({small_bins:,})', alpha=0.85)
    ax1.axvline(x=min_bin - 0.5, color='navy', linestyle='--', linewidth=1.5,
                label=f'min_bin = {min_bin}')

    # Grey count labels above each bar
    for s in x_range:
        count = cluster_dist.get(s, 0)
        if count > 0:
            ax1.text(s, count, str(count), ha='center', va='bottom',
                     fontsize=7, color='grey')

    ax1.set_yscale('log')
    ax1.set_xlabel('Bin size (reads per UMI)', fontsize=12)
    ax1.set_ylabel('Number of bins (log)', fontsize=12)
    ax1.set_title('Bin Size Distribution (Step 04: UMI clustering)', fontsize=14, fontweight='bold')
    ax1.legend(fontsize=10, loc='upper right')

    # Annotation box
    ann = (f"Total bins: {total_bins:,}\n"
           f"Below n<{min_bin}: {small_bins:,} ({small_bins/total_bins*100:.0f}%)\n"
           f"Kept: {kept_bins:,}\n"
           f"Reads in kept bins: {reads_kept:,}")
    ax1.text(0.98, 0.55, ann, transform=ax1.transAxes, fontsize=9,
             verticalalignment='top', horizontalalignment='right',
             bbox=dict(boxstyle='round,pad=0.5', facecolor='lightyellow', alpha=0.9))

    if not has_quality:
        fig.savefig(outpath, dpi=150, bbox_inches='tight', facecolor='white')
        plt.close()
        return

    # ── Panel 2: Noise rate by bin size ──────────────────────────────────────

    qbs = compute_quality_by_binsize(quality_records)
    q_sizes = sorted(s for s in qbs if s >= min_bin)

    ax2 = fig.add_subplot(gs[1])
    noise_vals = [qbs[s]['noise_per_1k'] for s in q_sizes]
    colors_noise = ['#DD8452' if s >= min_bin else '#AAAAAA' for s in q_sizes]
    ax2.bar(q_sizes, noise_vals, color=colors_noise, edgecolor='black', linewidth=0.3)
    for s, nv in zip(q_sizes, noise_vals):
        ax2.text(s, nv, str(qbs[s]['reads']), ha='center', va='bottom',
                 fontsize=7, color='grey')
    ax2.set_xlabel('Bin size', fontsize=12)
    ax2.set_ylabel('Noise rate (per 1,000 bp)', fontsize=12)
    ax2.set_title('Noise Rate by Bin Size (Step 10: final reads)', fontsize=14, fontweight='bold')
    ax2.set_xticks(q_sizes)

    # ── Panel 3: Error-free rate by bin size ─────────────────────────────────

    ax3 = fig.add_subplot(gs[2])
    ef_vals = [qbs[s]['error_free_pct'] for s in q_sizes]
    colors_ef = ['#4C72B0' if s >= min_bin else '#AAAAAA' for s in q_sizes]
    ax3.bar(q_sizes, ef_vals, color=colors_ef, edgecolor='black', linewidth=0.3)
    for s, ev in zip(q_sizes, ef_vals):
        ax3.text(s, ev, str(qbs[s]['reads']), ha='center', va='bottom',
                 fontsize=7, color='grey')
    ax3.set_xlabel('Bin size', fontsize=12)
    ax3.set_ylabel('Error-free reads (%)', fontsize=12)
    ax3.set_title('Error-Free Rate (NC=0) by Bin Size (Step 10: final reads)',
                  fontsize=14, fontweight='bold')
    ax3.set_xticks(q_sizes)
    ax3.set_ylim(0, 105)
    ax3.axhline(y=90, color='green', linestyle=':', alpha=0.4, linewidth=1)

    # ── Panel 4: Threshold table ─────────────────────────────────────────────

    thresh_rows = compute_threshold_table(quality_records, min_bin, cluster_dist)
    if thresh_rows:
        ax_tbl = fig.add_subplot(gs[3])
        ax_tbl.axis('off')
        ax_tbl.set_title(f'Quality at Each Threshold (green = current setting n>={min_bin})',
                         fontsize=13, fontweight='bold')

        has_bins = 'bins' in thresh_rows[0]
        cell_text = []
        cell_colors = []
        for r in thresh_rows:
            is_current = r['threshold'] == f'n >= {min_bin}'
            row = [r['threshold']]
            if has_bins:
                row.append(f"{r['bins']:,}")
            row.extend([f"{r['reads']:,}",
                        f"{r['error_free_pct']:.1f}%",
                        f"{r['noise_per_1k']:.3f}"])
            if has_bins:
                row.append(f"{r['survival_pct']:.0f}%")
            cell_text.append(row)
            bg = '#d5f5e3' if is_current else '#ffffff'
            cell_colors.append([bg] * len(row))

        col_labels = ['Threshold']
        col_widths = [0.15]
        if has_bins:
            col_labels.append('04_umi bins')
            col_widths.append(0.13)
        col_labels.extend(['10_csv reads', 'Error-free', 'Noise (/1kbp)'])
        col_widths.extend([0.13, 0.13, 0.17])
        if has_bins:
            col_labels.append('Survival')
            col_widths.append(0.13)

        tbl = ax_tbl.table(
            cellText=cell_text,
            colLabels=col_labels,
            cellColours=cell_colors,
            cellLoc='center', loc='center',
            colWidths=col_widths,
        )
        tbl.auto_set_font_size(False)
        tbl.set_fontsize(10)
        tbl.scale(1.0, 1.8)
        for j in range(len(col_labels)):
            cell = tbl[0, j]
            cell.set_facecolor('#2C3E50')
            cell.set_text_props(color='white', fontweight='bold')

        # Footnote: explain lost bins if any threshold shows < 100% survival
        if has_bins:
            lost_sizes = []
            for r in thresh_rows:
                lost = r['bins'] - r['reads']
                if lost > 0 and r['threshold'] == f'n >= {min_bin}':
                    # Find which bin sizes lost reads
                    for sz in sorted(cluster_dist):
                        if sz >= min_bin:
                            bins_at_sz = cluster_dist.get(sz, 0)
                            from collections import Counter
                            reads_at_sz = Counter(bs for bs, _, _, _ in quality_records)
                            surviving = reads_at_sz.get(sz, 0)
                            if bins_at_sz > 0 and surviving == 0:
                                lost_sizes.append(sz)
            if lost_sizes:
                sizes_str = ', '.join(str(s) for s in lost_sizes)
                ax_tbl.text(0.5, -0.05,
                            f'Bins with size {sizes_str} produced 0 reads at Step 10'
                            f' (consensus requires multiple reads for error correction).',
                            transform=ax_tbl.transAxes, fontsize=9, color='#666666',
                            ha='center', va='top', style='italic')

    fig.savefig(outpath, dpi=150, bbox_inches='tight', facecolor='white')
    plt.close()


def plot_compare(run_dir1, run_dir2, sample, qrecs1, qrecs2, outpath,
                 label1="longread-umi", label2="UMIC-seq"):
    """Generate a side-by-side comparison plot for two methods."""
    plt, gridspec, np = require_matplotlib()

    stats1 = load_cluster_stats(run_dir1, sample)
    stats2 = load_cluster_stats(run_dir2, sample)
    dist1 = load_cluster_size_dist(run_dir1, sample)
    dist2 = load_cluster_size_dist(run_dir2, sample)

    if not dist1 and not dist2:
        print(f"  WARNING: No data for {sample} in either run", file=sys.stderr)
        return

    has_quality = (qrecs1 is not None and len(qrecs1) > 0 and
                   qrecs2 is not None and len(qrecs2) > 0)
    nrows = 4 if has_quality else 1
    fig_h = 24 if has_quality else 6

    fig = plt.figure(figsize=(16, fig_h))
    fig.patch.set_facecolor('white')

    sample_label = sample.replace('/', ' / ')
    fig.suptitle(f'{sample_label}: UMI Bin Analysis — {label1} vs {label2}',
                 fontsize=16, fontweight='bold', y=0.98)

    gs = gridspec.GridSpec(nrows, 2, figure=fig,
                           height_ratios=[3, 3, 3, 2] if has_quality else [1],
                           hspace=0.40, wspace=0.25,
                           left=0.07, right=0.95, top=0.93,
                           bottom=0.05 if has_quality else 0.12)

    for col, (run_dir, stats, dist, label, qrecs) in enumerate([
        (run_dir1, stats1, dist1, label1, qrecs1),
        (run_dir2, stats2, dist2, label2, qrecs2),
    ]):
        if not dist:
            continue

        min_bin = int(stats.get('bins_min_bin_size', 3))
        total_bins = int(stats.get('bins_total_bins', 0))
        kept_bins = int(stats.get('bins_kept_bins', 0))
        small_bins = int(stats.get('bins_small_bins', 0))
        reads_kept = int(stats.get('bins_reads_in_kept_bins', 0))

        sizes = sorted(dist.keys())
        max_size = max(sizes)
        x_range = range(1, max_size + 1)

        survived = []
        filtered = []
        for s in x_range:
            count = dist.get(s, 0)
            if s >= min_bin:
                survived.append(count)
                filtered.append(0)
            else:
                survived.append(0)
                filtered.append(count)

        # ── Histogram ────────────────────────────────────────────────────

        ax = fig.add_subplot(gs[0, col])
        ax.bar(list(x_range), survived, color='#55A868', edgecolor='black',
               linewidth=0.3, label=f'Survived ({kept_bins:,})', alpha=0.85)
        ax.bar(list(x_range), filtered, color='#C44E52', edgecolor='black',
               linewidth=0.3, label=f'Filtered ({small_bins:,})', alpha=0.85)
        ax.axvline(x=min_bin - 0.5, color='navy', linestyle='--', linewidth=1.5,
                   label=f'min_bin = {min_bin}')
        ax.set_yscale('log')
        ax.set_xlabel('Bin size (reads per UMI)', fontsize=11)
        ax.set_ylabel('Number of bins (log)', fontsize=11)
        # Grey count labels above each bar
        for s in x_range:
            count = dist.get(s, 0)
            if count > 0:
                ax.text(s, count, str(count), ha='center', va='bottom',
                        fontsize=6, color='grey')
        ax.set_title(f'{label} — Bin Size Distribution (Step 04)', fontsize=13, fontweight='bold')
        ax.legend(fontsize=9, loc='upper right')

        ann = (f"Total bins: {total_bins:,}\n"
               f"Below n<{min_bin}: {small_bins:,} ({small_bins/total_bins*100:.0f}%)\n"
               f"Kept: {kept_bins:,}\n"
               f"Reads in kept: {reads_kept:,}")
        ax.text(0.98, 0.50, ann, transform=ax.transAxes, fontsize=8,
                verticalalignment='top', horizontalalignment='right',
                bbox=dict(boxstyle='round,pad=0.4', facecolor='lightyellow', alpha=0.9))

        if not has_quality or qrecs is None:
            continue

        qbs = compute_quality_by_binsize(qrecs)
        q_sizes = sorted(s for s in qbs if s >= min_bin)
        if not q_sizes:
            continue

        # ── Noise rate ───────────────────────────────────────────────────

        ax2 = fig.add_subplot(gs[1, col])
        noise_vals = [qbs[s]['noise_per_1k'] for s in q_sizes]
        ax2.bar(q_sizes, noise_vals, color='#DD8452', edgecolor='black', linewidth=0.3)
        for s, nv in zip(q_sizes, noise_vals):
            ax2.text(s, nv, str(qbs[s]['reads']), ha='center', va='bottom',
                     fontsize=6, color='grey')
        ax2.set_xlabel('Bin size', fontsize=11)
        ax2.set_ylabel('Noise rate (per 1,000 bp)', fontsize=11)
        ax2.set_title(f'{label} — Noise Rate (Step 10)', fontsize=13, fontweight='bold')
        ax2.set_xticks(q_sizes)

        # ── Error-free rate ──────────────────────────────────────────────

        ax3 = fig.add_subplot(gs[2, col])
        ef_vals = [qbs[s]['error_free_pct'] for s in q_sizes]
        ax3.bar(q_sizes, ef_vals, color='#4C72B0', edgecolor='black', linewidth=0.3)
        for s, ev in zip(q_sizes, ef_vals):
            ax3.text(s, ev, str(qbs[s]['reads']), ha='center', va='bottom',
                     fontsize=6, color='grey')
        ax3.set_xlabel('Bin size', fontsize=11)
        ax3.set_ylabel('Error-free reads (%)', fontsize=11)
        ax3.set_title(f'{label} — Error-Free Rate (Step 10)',
                      fontsize=13, fontweight='bold')
        ax3.set_xticks(q_sizes)
        ax3.set_ylim(0, 105)
        ax3.axhline(y=90, color='green', linestyle=':', alpha=0.4, linewidth=1)

    # ── Row 4: Threshold comparison table ────────────────────────────────

    if has_quality and qrecs1 and qrecs2:
        min_bin1 = int(stats1.get('bins_min_bin_size', 3))
        min_bin2 = int(stats2.get('bins_min_bin_size', 3))
        t1 = compute_threshold_table(qrecs1, min_bin1, dist1)
        t2 = compute_threshold_table(qrecs2, min_bin2, dist2)

        ax_tbl = fig.add_subplot(gs[3, :])
        ax_tbl.axis('off')
        ax_tbl.set_title(f'Quality at Each Threshold (green = current setting n>={min_bin1})',
                         fontsize=13, fontweight='bold')

        has_bins = 'bins' in t1[0] if t1 else False
        cell_text = []
        cell_colors = []
        for r1, r2 in zip(t1, t2):
            is_current = r1['threshold'] == f'n >= {min_bin1}'
            bg = '#d5f5e3' if is_current else '#ffffff'
            row1 = [r1['threshold'], label1]
            row2 = ['', label2]
            if has_bins:
                row1.append(f"{r1['bins']:,}")
                row2.append(f"{r2.get('bins', 0):,}")
            row1.extend([f"{r1['reads']:,}",
                         f"{r1['error_free_pct']:.1f}%", f"{r1['noise_per_1k']:.3f}"])
            row2.extend([f"{r2['reads']:,}",
                         f"{r2['error_free_pct']:.1f}%", f"{r2['noise_per_1k']:.3f}"])
            if has_bins:
                row1.append(f"{r1['survival_pct']:.0f}%")
                row2.append(f"{r2.get('survival_pct', 0):.0f}%")
            cell_text.append(row1)
            cell_colors.append([bg] * len(row1))
            cell_text.append(row2)
            cell_colors.append([bg] * len(row2))

        col_labels = ['Threshold', 'Method']
        col_widths = [0.12, 0.14]
        if has_bins:
            col_labels.append('04_umi bins')
            col_widths.append(0.10)
        col_labels.extend(['10_csv reads', 'Error-free', 'Noise (/1kbp)'])
        col_widths.extend([0.10, 0.10, 0.14])
        if has_bins:
            col_labels.append('Survival')
            col_widths.append(0.10)

        tbl = ax_tbl.table(
            cellText=cell_text,
            colLabels=col_labels,
            cellColours=cell_colors,
            cellLoc='center', loc='center',
            colWidths=col_widths,
        )
        tbl.auto_set_font_size(False)
        tbl.set_fontsize(9)
        tbl.scale(1.0, 1.6)
        for j in range(len(col_labels)):
            cell = tbl[0, j]
            cell.set_facecolor('#2C3E50')
            cell.set_text_props(color='white', fontweight='bold')

    fig.savefig(outpath, dpi=150, bbox_inches='tight', facecolor='white')
    plt.close()


def main():
    parser = argparse.ArgumentParser(
        description='Generate UMI bin analysis plots from L3Rseq step 04 output.')
    parser.add_argument('run_dir', help='L3Rseq output directory (e.g., runs/E230426_barcode48)')
    parser.add_argument('--sample', help='Specific sample to plot (e.g., barcode48/barcode48_RPI_3). '
                        'If omitted, plots all samples found.')
    parser.add_argument('--compare', metavar='RUN_DIR2',
                        help='Second run directory for side-by-side comparison')
    parser.add_argument('--label1', default='longread-umi', help='Label for first run (default: longread-umi)')
    parser.add_argument('--label2', default='UMIC-seq', help='Label for second run (default: UMIC-seq)')
    parser.add_argument('--quality', action='store_true',
                        help='Include noise/error-free plots (requires step 10 CSV)')
    parser.add_argument('--outdir', help='Output directory for PNGs (default: next to step 04 data)')
    args = parser.parse_args()

    if args.sample:
        samples = [args.sample]
    else:
        samples = find_samples(args.run_dir)
        if not samples:
            print(f"ERROR: No samples found in {args.run_dir}/04_umi/", file=sys.stderr)
            sys.exit(1)
        print(f"Found {len(samples)} sample(s): {', '.join(samples)}")

    for sample in samples:
        print(f"  Plotting {sample} ...")

        if args.outdir:
            os.makedirs(args.outdir, exist_ok=True)
            out_base = args.outdir
        else:
            out_base = str(Path(args.run_dir))

        safe_name = sample.replace('/', '_')

        if args.compare:
            qrecs1 = load_csv_quality(args.run_dir, sample) if args.quality else None
            qrecs2 = load_csv_quality(args.compare, sample) if args.quality else None
            outpath = os.path.join(out_base, f"bin_analysis_{safe_name}_compare.png")
            plot_compare(args.run_dir, args.compare, sample, qrecs1, qrecs2,
                        outpath, args.label1, args.label2)
        else:
            qrecs = load_csv_quality(args.run_dir, sample) if args.quality else None
            outpath = os.path.join(out_base, f"bin_analysis_{safe_name}.png")
            plot_single(args.run_dir, sample, qrecs, outpath, args.label1)

        print(f"    Saved: {outpath}")


if __name__ == '__main__':
    main()
