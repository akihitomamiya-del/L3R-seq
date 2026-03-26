#!/bin/bash
# discover_introns.sh -- Discover candidate introns from mapped SAM files
# Called by L3Rseq discover-introns subcommand.
#
# Scans mapped SAM files for clusters of large deletions that indicate
# intron splicing. Outputs a candidate BED file and human-readable report.
#
# Requires: INPUT_DIR (07_map output), OUTPUT_DIR

set -euo pipefail

run_discover_introns() {
    local input_dir="$1"
    local output_dir="$2"
    local min_del_len="${3:-50}"       # minimum deletion length to consider
    local min_support_pct="${4:-5}"    # minimum % of reads supporting a candidate
    local boundary_tolerance="${5:-10}" # max bp deviation for clustering boundaries

    mkdir -p "$output_dir"

    echo "[discover-introns] Scanning mapped SAMs for candidate introns ..."

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            local input_sam="$rpi_dir/mapped_only.sam"
            if [ ! -f "$input_sam" ]; then
                echo "  WARNING: No mapped_only.sam in $bname/$rpi_name, skipping (run step 07 first)"
                continue
            fi

            echo "  Processing $bname / $rpi_name ..."

            local bed_file="$output_dir/${bname}_${rpi_name}_candidate_introns.bed"
            local report_file="$output_dir/${bname}_${rpi_name}_intron_discovery_report.txt"

            # Extract all large deletions from CIGARs with their reference positions
            # Then cluster them and assess confidence
            python3 -c "
import re, sys, collections

min_del = int('$min_del_len')
min_pct = float('$min_support_pct')
tolerance = int('$boundary_tolerance')
sam_file = '$input_sam'
bed_out = '$bed_file'
report_out = '$report_file'
label = '$bname / $rpi_name'

# Parse SAM: collect large deletions
deletions = []  # list of (start, end, length)
total_reads = 0
ref_name = ''

with open(sam_file) as f:
    for line in f:
        if line.startswith('@'):
            if line.startswith('@SQ'):
                # Extract reference name
                for field in line.strip().split('\t'):
                    if field.startswith('SN:'):
                        ref_name = field[3:]
            continue
        fields = line.strip().split('\t')
        if len(fields) < 6:
            continue
        total_reads += 1
        pos = int(fields[3]) - 1  # convert to 0-based
        cigar = fields[5]

        # Walk CIGAR
        ref_pos = pos
        for match in re.finditer(r'(\d+)([MIDNSHP=X])', cigar):
            length = int(match.group(1))
            op = match.group(2)
            if op in ('M', '=', 'X'):
                ref_pos += length
            elif op in ('D', 'N'):
                if length >= min_del:
                    deletions.append((ref_pos, ref_pos + length, length))
                ref_pos += length
            # I, S, H, P don't consume reference

if total_reads == 0:
    with open(report_out, 'w') as r:
        r.write('No mapped reads found.\n')
    with open(bed_out, 'w') as b:
        pass
    sys.exit(0)

# Cluster deletions by similar boundaries
# Sort by start position
deletions.sort()

clusters = []  # list of {'starts': [], 'ends': [], 'count': N}
for d_start, d_end, d_len in deletions:
    placed = False
    for cluster in clusters:
        # Check if this deletion matches the cluster (within tolerance)
        c_start = sum(cluster['starts']) / len(cluster['starts'])
        c_end = sum(cluster['ends']) / len(cluster['ends'])
        if abs(d_start - c_start) <= tolerance and abs(d_end - c_end) <= tolerance:
            cluster['starts'].append(d_start)
            cluster['ends'].append(d_end)
            cluster['count'] += 1
            placed = True
            break
    if not placed:
        clusters.append({'starts': [d_start], 'ends': [d_end], 'count': 1})

# Assess confidence and write results
candidates = []
for cluster in clusters:
    count = cluster['count']
    pct = 100 * count / total_reads
    median_start = sorted(cluster['starts'])[len(cluster['starts']) // 2]
    median_end = sorted(cluster['ends'])[len(cluster['ends']) // 2]
    intron_len = median_end - median_start

    # Boundary precision: stdev of start and end positions
    import statistics
    start_std = statistics.pstdev(cluster['starts']) if len(cluster['starts']) > 1 else 0
    end_std = statistics.pstdev(cluster['ends']) if len(cluster['ends']) > 1 else 0

    # Confidence assessment
    if intron_len < min_del:
        confidence = 'REJECTED (too short)'
    elif pct < min_pct:
        confidence = 'LOW (below {:.0f}% threshold)'.format(min_pct)
    elif start_std > tolerance or end_std > tolerance:
        confidence = 'LOW (fuzzy boundaries)'
    else:
        confidence = 'HIGH CONFIDENCE'

    candidates.append({
        'start': median_start,
        'end': median_end,
        'length': intron_len,
        'count': count,
        'pct': pct,
        'start_std': start_std,
        'end_std': end_std,
        'confidence': confidence,
    })

# Sort by position
candidates.sort(key=lambda c: c['start'])

# Write BED file (only high-confidence candidates)
with open(bed_out, 'w') as b:
    for i, c in enumerate(candidates):
        if 'HIGH' in c['confidence']:
            b.write(f\"{ref_name}\t{c['start']}\t{c['end']}\tintron{i+1}\t{c['count']}\n\")

# Write report
with open(report_out, 'w') as r:
    r.write(f'L3Rseq Intron Discovery Report: {label}\n')
    r.write('=' * 60 + '\n')
    if ref_name:
        r.write(f'Reference: {ref_name}\n')
    r.write(f'Mapped reads: {total_reads:,}\n')
    r.write(f'Large deletions found (>={min_del}bp): {len(deletions):,}\n')
    r.write(f'Clusters formed: {len(candidates)}\n')
    r.write('\n')

    if candidates:
        high = [c for c in candidates if 'HIGH' in c['confidence']]
        r.write(f'Candidate introns:\n')
        for i, c in enumerate(candidates):
            r.write(f\"  #{i+1}  Position {c['start']}-{c['end']} ({c['length']:,}bp)\")
            r.write(f\"    {c['count']}/{total_reads} reads ({c['pct']:.1f}%)  {c['confidence']}\n\")
            r.write(f\"      Start cluster: {c['start']} +/- {c['start_std']:.1f}bp\n\")
            r.write(f\"      End cluster:   {c['end']} +/- {c['end_std']:.1f}bp\n\")
        r.write('\n')
        if high:
            r.write(f'High-confidence candidates written to: {bed_out}\n')
            r.write('Review and use with: L3Rseq run --introns {}\n'.format(bed_out))
        else:
            r.write('No high-confidence intron candidates found.\n')
    else:
        r.write('No large deletion clusters found.\n')
" 2>&1

            if [ -f "$report_file" ]; then
                echo ""
                cat "$report_file"
                echo ""
            fi

        done
    done

    echo "[discover-introns] Done. Output in $output_dir/"
}
