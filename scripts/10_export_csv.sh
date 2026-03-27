#!/bin/bash
# 10_export_csv.sh -- SAM-to-CSV conversion + quality report
# Called by L3Rseq dispatcher. No conda environment needed.
# Requires: INPUT_DIR, OUTPUT_DIR

set -euo pipefail

# Quality report generator
_write_quality_report() {
    local sam_file="$1"
    local report_file="$2"
    local label="$3"

    python3 -c "
import re, math, sys, collections

label = '''$label'''
reads = []
sub_types = collections.Counter()

with open('$sam_file') as f:
    for line in f:
        if line.startswith('@'):
            continue
        fields = line.strip().split('\t')
        if len(fields) < 11:
            continue
        cigar = fields[5]
        tags = {}
        for fld in fields[11:]:
            parts = fld.split(':')
            if len(parts) >= 3:
                tags[parts[0]] = parts[2]

        ec = int(tags.get('EC', '0'))
        sc = int(tags.get('SC', '0'))
        nc = int(tags.get('NC', '0'))
        vr = tags.get('VR', '')

        # Count substitution types
        if vr:
            for v in vr.split(';'):
                v = v.strip()
                if not v: continue
                m = re.match(r'(\d+)([ACGT])([ACGT])', v)
                if m:
                    sub_types[m.group(2) + m.group(3)] += 1

        # CIGAR parsing (N = intron skip, excluded from error counting)
        ins_b = sum(int(n) for n in re.findall(r'(\d+)I', cigar))
        del_b = sum(int(n) for n in re.findall(r'(\d+)D', cigar))
        ins_e = len(re.findall(r'\d+I', cigar))
        del_e = len(re.findall(r'\d+D', cigar))
        match_b = sum(int(n) for n in re.findall(r'(\d+)M', cigar))
        intron_b = sum(int(n) for n in re.findall(r'(\d+)N', cigar))
        aligned = match_b + ins_b + del_b  # N (intron skip) excluded

        reads.append(dict(ec=ec, sc=sc, nc=nc, ins_b=ins_b, del_b=del_b,
                          ins_e=ins_e, del_e=del_e, intron_b=intron_b, aligned=aligned))

if not reads:
    with open('$report_file', 'w') as out:
        out.write('No reads found.\n')
    sys.exit(0)

n = len(reads)
S = lambda k: sum(r[k] for r in reads)
total_aligned = S('aligned')
total_ec = S('ec')
total_sc = S('sc')
total_nc = S('nc')
total_ins_b = S('ins_b')
total_del_b = S('del_b')
total_ins_e = S('ins_e')
total_del_e = S('del_e')
total_mm = sum(sub_types.values())
perfect = sum(1 for r in reads if r['nc'] + r['ins_b'] + r['del_b'] == 0)

err_sub = total_nc / total_aligned if total_nc > 0 else 0
err_all = (total_nc + total_ins_b + total_del_b) / total_aligned if (total_nc + total_ins_b + total_del_b) > 0 else 0
q_sub = -10 * math.log10(err_sub) if err_sub > 0 else 99
q_all = -10 * math.log10(err_all) if err_all > 0 else 99

# Separate editing vs noise substitution types
editing_types = set()
# The primary pattern is always EC's pattern — identify from most common type
# that accounts for EC count
sorted_types = sub_types.most_common()
# We can't know the pattern from the SAM alone, but we can identify
# the dominant type matching EC count
ec_type = sorted_types[0][0] if sorted_types and sorted_types[0][1] >= total_ec else ''

with open('$report_file', 'w') as out:
    w = out.write
    w(f'L3Rseq Quality Report: {label}\n')
    w('=' * 60 + '\n')
    w(f'  Reads:                    {n:,}\n')
    w(f'  Total aligned bases:      {total_aligned:,}\n')
    w(f'  Mean read length:         {total_aligned // n:,} bp\n')
    w('\n')
    w('  Substitution analysis\n')
    w('  ' + chr(9472) * 24 + '\n')
    w(f'  Total mismatches (VR):    {total_mm:,}\n')
    w(f'  RNA editing (EC):         {total_ec:,}\n')
    if total_sc > 0:
        w(f'  Secondary count (SC):     {total_sc:,}\n')
    w(f'  Noise substitutions (NC): {total_nc:,}\n')
    w('\n')
    w('  Indel analysis (from CIGAR)\n')
    w('  ' + chr(9472) * 28 + '\n')
    w(f'  Insertions:               {total_ins_b:,} bases  ({total_ins_e:,} events)\n')
    w(f'  Deletions:                {total_del_b:,} bases  ({total_del_e:,} events)\n')
    w('\n')
    w('  Aggregate accuracy (excluding biological editing)\n')
    w('  ' + chr(9472) * 50 + '\n')
    w(f'  Q (subs only):            Q{q_sub:.1f}  (error rate {err_sub:.6f})\n')
    w(f'  Q (subs + indels):        Q{q_all:.1f}  (error rate {err_all:.6f})\n')
    w(f'  Error-free reads:         {perfect:,} / {n:,}  ({100*perfect/n:.1f}%)\n')
    w('\n')
    w('  All substitution types\n')
    w('  ' + chr(9472) * 24 + '\n')
    for pair, count in sorted_types:
        marker = '  (editing)' if pair == ec_type else ''
        w(f'    {pair[0]}{chr(8594)}{pair[1]}:  {count:>6,}{marker}\n')

    # Splicing section (only if SJ tags present)
    sj_patterns = collections.Counter()
    sj_reads = 0
    for r_line in open('$sam_file'):
        if r_line.startswith('@'): continue
        flds = r_line.strip().split('\t')
        for fld in flds[11:]:
            if fld.startswith('SJ:Z:'):
                pat = fld[5:]
                if pat and pat != ('-' * len(pat)):
                    sj_patterns[pat] += 1
                sj_reads += 1
                break
    if sj_reads > 0:
        n_introns = len(next(iter(sj_patterns), ''))
        spanning = sum(sj_patterns.values())
        w('\n')
        w(f'  Splicing analysis ({n_introns} intron(s) annotated)\n')
        w('  ' + chr(9472) * 40 + '\n')
        w(f'  Reads spanning intron(s):  {spanning:,} / {sj_reads:,}\n')
        # Per-intron efficiency
        if n_introns > 0:
            w('\n  Per-intron splicing efficiency:\n')
            for idx in range(n_introns):
                s_count = sum(1 for p in sj_patterns for _ in range(sj_patterns[p]) if len(p) > idx and p[idx] == 'S')
                total_span = sum(1 for p in sj_patterns for _ in range(sj_patterns[p]) if len(p) > idx and p[idx] in 'SR')
                if total_span > 0:
                    w(f'    Intron {idx+1}:  spliced {s_count:,}/{total_span:,} ({100*s_count/total_span:.1f}%)\n')
        # Pattern distribution
        w('\n  Splice pattern distribution:\n')
        for pat, cnt in sj_patterns.most_common(10):
            pct = 100 * cnt / spanning if spanning > 0 else 0
            label_str = 'fully spliced' if all(c == 'S' for c in pat) else ('unspliced' if all(c == 'R' for c in pat) else '')
            w(f'    {pat}  {cnt:>6,}  ({pct:>5.1f}%)  {label_str}\n')
" 2>/dev/null || echo "  WARNING: Quality report generation failed (python3 required)"
}

run_step_10() {
    local input_dir="$1"
    local output_dir="$2"

    mkdir -p "$output_dir/10_csv"

    echo "[Step 10] Exporting CSV files ..."

    # Headers: NC is always present; SC and SJ are conditional
    local header_base="QNAME,FLAG,RNAME,POS,MAPQ,CIGAR,RNEXT,PNEXT,TLEN,SEQ,QUAL,ThreePrime_end,ThreePrime_tail_length,ThreePrime_tail_seq,translocation,double_sorter,editing_count"
    local header_tail="noise_count,matched_length,All_mismatches"
    local header_sj="splice_pattern,introns_spliced,introns_retained"

    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue

            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            local corrected_sam="$rpi_dir/corrected.sam"
            if [ ! -f "$corrected_sam" ]; then
                echo "  WARNING: No corrected.sam in $bname/$rpi_name, skipping (run step 09 first)"
                continue
            fi

            echo "  Exporting $bname / $rpi_name ..."

            local csv_file="$output_dir/10_csv/${bname}_${rpi_name}.csv"

            # Build header dynamically based on which tags are present
            local first_data
            # Use awk instead of grep|head to avoid SIGPIPE under pipefail
            first_data=$(awk '/^[^@]/{print; exit}' "$corrected_sam")
            local header="$header_base"
            if echo "$first_data" | grep -q 'SC:i:'; then
                header="${header},secondary_editing_count"
            fi
            header="${header},${header_tail}"
            if echo "$first_data" | grep -q 'SJ:Z:'; then
                header="${header},${header_sj}"
            fi

            # Strip SAM header, convert tabs to commas, add CSV header
            sed '/^@/d' "$corrected_sam" | sed 's/\t/,/g' > "$csv_file"
            { echo "$header"; cat "$csv_file"; } > "${csv_file}.tmp" && mv "${csv_file}.tmp" "$csv_file"

            # Generate quality report
            local report_file="$output_dir/10_csv/${bname}_${rpi_name}_quality_report.txt"
            _write_quality_report "$corrected_sam" "$report_file" "$bname / $rpi_name"

        done
    done

    # Summary: CSV rows + key stats from corrected SAM
    for _cdir in "$input_dir"/*/*; do
        [ -d "$_cdir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_cdir")")
        _rname=$(basename "$_cdir")
        local _csv="$output_dir/10_csv/${_bname}_${_rname}.csv"
        if [ -f "$_csv" ]; then
            local _nrows _ec_total
            _nrows=$(( $(wc -l < "$_csv") - 1 ))
            echo "    $_bname/$_rname: $_nrows rows exported"
            _summary_append "$output_dir" "$_bname" "$_rname" "10" "csv_rows" "$_nrows" 2>/dev/null || true
        fi
        local _sam="$_cdir/corrected.sam"
        if [ -f "$_sam" ]; then
            local _corrected _abnormal _ec_sum
            _corrected=$(grep -cv '^@' "$_sam")
            _chimeric=0
            if [ -f "$_cdir/chimeric_rightclip.sam" ]; then
                _chimeric=$(grep -cv '^@' "$_cdir/chimeric_rightclip.sam" 2>/dev/null) || _chimeric=0
            elif [ -f "$_cdir/abnormal_rightclip.sam" ]; then
                _chimeric=$(grep -cv '^@' "$_cdir/abnormal_rightclip.sam" 2>/dev/null) || _chimeric=0
            fi
            _ec_sum=$(grep -v '^@' "$_sam" | grep -oE 'EC:i:[0-9]+' | sed 's/EC:i://' | awk '{s+=$1} END{print s+0}')
            _summary_append "$output_dir" "$_bname" "$_rname" "09" "corrected_reads" "$_corrected" 2>/dev/null || true
            _summary_append "$output_dir" "$_bname" "$_rname" "09" "chimeric_clips" "$_chimeric" 2>/dev/null || true
            _summary_append "$output_dir" "$_bname" "$_rname" "09" "total_editing_count" "$_ec_sum" 2>/dev/null || true
        fi
    done
    echo "[Step 10] Done. Output in $output_dir/10_csv/"
}
