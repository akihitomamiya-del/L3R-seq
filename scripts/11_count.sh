#!/bin/bash
# 11_count.sh — Gene-level read counting from mapped BAMs
# Part of the L3Rseq pipeline (standalone subcommand, not integrated into cmd_run).
#
# Counts UMI-consensus molecules per gene region, discovers isoforms from
# CIGAR N operations, and optionally normalizes against housekeeping genes.
#
# Input: step 07 mapped BAMs + regions TSV (from L3Rseq regions)
# Output: per-sample counts, merged counts, isoform discovery, coverage, normalization

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# count_gene_reads — core awk-based counting with fractional overlap
#
# Counts primary alignments overlapping a gene region by >= min_frac of gene
# length. Also extracts splice patterns from CIGAR N operations.
#
# Output to stdout: "total\t<N>" and "pattern\t<splice>\t<count>" lines
# ---------------------------------------------------------------------------
count_gene_reads() {
    local bam="$1"
    local chr="$2"
    local start="$3"
    local end="$4"
    local min_frac="$5"
    local min_mapq="$6"

    # -F 0x904: exclude unmapped (0x4), secondary (0x100), supplementary (0x800)
    # -q: filter by mapping quality
    # Note: pipe through { ... || true; } to prevent pipefail from killing the
    # script when samtools returns non-zero (e.g., region chromosome not in BAM).
    { samtools view -F 0x904 -q "$min_mapq" "$bam" "${chr}:${start}-${end}" 2>/dev/null || true; } | awk \
        -v gs="$start" -v ge="$end" -v gene_len="$((end - start + 1))" -v min_frac="$min_frac" '
    # Parse CIGAR into parallel arrays of lengths and ops.
    # mawk-compatible: no 3-arg match(). Uses match() to find digit run,
    # then reads the op character at RSTART+RLENGTH.
    function parse_cigar(cig,    n, c, num) {
        n = 0; c = cig
        while (length(c) > 0 && match(c, /[0-9]+/)) {
            num = substr(c, RSTART, RLENGTH) + 0
            c = substr(c, RSTART + RLENGTH)
            n++
            cig_len[n] = num
            cig_op[n] = substr(c, 1, 1)
            c = substr(c, 2)
        }
        return n
    }
    {
        pos = $4; cigar = $6; reflen = 0
        nc = parse_cigar(cigar)
        for (i = 1; i <= nc; i++) {
            op = cig_op[i]
            if (op=="M"||op=="D"||op=="N"||op=="="||op=="X") reflen += cig_len[i]
        }
        aend = pos + reflen - 1

        # Compute overlap with gene region (fractional)
        ov_start = (pos > gs) ? pos : gs
        ov_end = (aend < ge) ? aend : ge
        overlap = (ov_end >= ov_start) ? (ov_end - ov_start + 1) : 0
        frac = overlap / gene_len

        if (frac >= min_frac) {
            # Extract splice pattern from N ops in CIGAR
            splice = ""; rpos = pos
            for (i = 1; i <= nc; i++) {
                op = cig_op[i]; oplen = cig_len[i]
                if (op == "N") splice = splice (splice != "" ? "," : "") rpos ":" oplen
                if (op=="M"||op=="D"||op=="N"||op=="="||op=="X") rpos += oplen
            }
            if (splice == "") splice = "none"
            patterns[splice]++
            total++
        }
    }
    END {
        print "total\t" total+0
        for (p in patterns) print "pattern\t" p "\t" patterns[p]
    }'
}

# ---------------------------------------------------------------------------
# generate_coverage — per-base depth across a gene region
# ---------------------------------------------------------------------------
generate_coverage() {
    local bam="$1"
    local chr="$2"
    local start="$3"
    local end="$4"
    local outfile="$5"

    # Use || true to handle missing chromosomes gracefully (empty output = no coverage)
    samtools depth -a -r "${chr}:${start}-${end}" "$bam" > "$outfile" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
run_step_11() {
    local map_dir="$1"
    local output_dir="$2"
    local regions_file="$3"
    local housekeeping="$4"
    local min_frac="$5"
    local min_mapq="$6"

    echo "[Step 11] Gene-level read counting ..."

    if [ ! -f "$regions_file" ]; then
        echo "ERROR: Regions file not found: $regions_file" >&2
        return 1
    fi

    local count_dir="$output_dir/11_count"
    local cov_dir="$count_dir/coverage"
    mkdir -p "$count_dir" "$cov_dir"

    # --- Read regions TSV into arrays ---
    local -a REGION_NAMES=() REGION_CHRS=() REGION_STARTS=() REGION_ENDS=()

    while IFS=$'\t' read -r name chr start end _strand _source; do
        [[ "$name" == "#"* ]] && continue
        [ -z "$name" ] && continue
        REGION_NAMES+=("$name")
        REGION_CHRS+=("$chr")
        REGION_STARTS+=("$start")
        REGION_ENDS+=("$end")
    done < "$regions_file"

    local n_regions=${#REGION_NAMES[@]}
    if [ "$n_regions" -eq 0 ]; then
        echo "  ERROR: No regions found in $regions_file" >&2
        return 1
    fi
    echo "  Loaded $n_regions gene region(s)"

    # --- Merged output header ---
    local merged_file="$count_dir/gene_counts_all.tsv"
    printf "gene\tsample\ttotal_count\tsplice_pattern\tpattern_count\n" > "$merged_file"

    # --- Loop barcode/RPI directories (same pattern as 07_map.sh) ---
    local map_base="$map_dir/07_map"
    if [ ! -d "$map_base" ]; then
        # Allow passing the 07_map dir directly
        if [ -d "$map_dir" ] && ls "$map_dir"/*/primary.sort.bam >/dev/null 2>&1; then
            map_base="$map_dir"
        else
            echo "  ERROR: 07_map directory not found at $map_dir/07_map" >&2
            return 1
        fi
    fi

    local sample_count=0

    for barcode_dir in "$map_base"/*/; do
        [ -d "$barcode_dir" ] || continue
        local bname
        bname=$(basename "$barcode_dir")

        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue
            local rpi_name
            rpi_name=$(basename "$rpi_dir")

            # Find primary BAM
            local bam="$rpi_dir/${rpi_name}_primary.sort.bam"
            if [ ! -f "$bam" ]; then
                echo "  WARNING: No ${rpi_name}_primary.sort.bam in $bname/$rpi_name, skipping"
                continue
            fi

            local sample_id="$bname/$rpi_name"
            echo "  Counting $sample_id ..."
            sample_count=$((sample_count + 1))

            # Per-sample output
            local sample_file="$count_dir/${bname}_${rpi_name}_gene_counts.tsv"
            printf "#gene\tchr\tstart\tend\ttotal_count\tsplice_patterns\n" > "$sample_file"

            for (( i=0; i<n_regions; i++ )); do
                local gene="${REGION_NAMES[$i]}"
                local chr="${REGION_CHRS[$i]}"
                local gs="${REGION_STARTS[$i]}"
                local ge="${REGION_ENDS[$i]}"

                # Count reads
                local count_output
                count_output=$(count_gene_reads "$bam" "$chr" "$gs" "$ge" "$min_frac" "$min_mapq")

                local total=0
                local patterns_str=""

                while IFS=$'\t' read -r tag val extra; do
                    case "$tag" in
                        total) total="${val// /}" ;;
                        pattern)
                            local pname="${val// /}"
                            local pcount="${extra// /}"
                            if [ -n "$patterns_str" ]; then
                                patterns_str="${patterns_str},$pname:$pcount"
                            else
                                patterns_str="$pname:$pcount"
                            fi
                            # Write to merged file
                            printf "%s\t%s\t%s\t%s\t%s\n" "$gene" "$sample_id" "$total" "$pname" "$pcount" >> "$merged_file"
                            ;;
                    esac
                done <<< "$count_output"

                # If no patterns (0 reads), write a zero row to merged
                if [ "$total" -eq 0 ]; then
                    printf "%s\t%s\t0\tnone\t0\n" "$gene" "$sample_id" >> "$merged_file"
                fi

                [ -z "$patterns_str" ] && patterns_str="none:0"
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$gene" "$chr" "$gs" "$ge" "$total" "$patterns_str" >> "$sample_file"

                # Generate coverage
                generate_coverage "$bam" "$chr" "$gs" "$ge" \
                    "$cov_dir/${bname}_${rpi_name}_${gene}.depth.tsv"
            done
        done
    done

    if [ "$sample_count" -eq 0 ]; then
        echo "  WARNING: No samples found with primary BAMs in $map_base" >&2
        return 1
    fi

    echo "  Counted $sample_count sample(s) x $n_regions gene(s)"

    # --- Pooled isoform discovery ---
    _generate_isoform_discovery "$merged_file" "$count_dir/isoform_discovery.tsv"

    # --- Housekeeping normalization ---
    if [ -n "$housekeeping" ]; then
        _normalize_counts "$merged_file" "$housekeeping" "$count_dir/gene_counts_normalized.tsv"
    fi

    echo "[Step 11] Done."
}

# ---------------------------------------------------------------------------
# Generate pooled isoform discovery table
# Aggregates splice patterns per barcode per gene (not across barcodes).
# Different barcodes often represent different libraries/experiments, so
# pooling should be within the same barcode family.
# ---------------------------------------------------------------------------
_generate_isoform_discovery() {
    local merged_file="$1"
    local output_file="$2"

    echo "  Generating pooled isoform discovery (per barcode) ..."

    awk -F'\t' '
    NR == 1 { next }
    {
        gene = $1; sample = $2; pattern = $4; pcount = $5 + 0
        # Extract barcode from sample (barcode/rpi → barcode)
        n = split(sample, sp, "/"); bc = sp[1]

        key = bc SUBSEP gene SUBSEP pattern
        pooled[key] += pcount
        gt_key = bc SUBSEP gene
        gene_total[gt_key] += pcount
        skey = key SUBSEP sample
        if (!(skey in seen)) {
            seen[skey] = 1
            n_samples[key]++
            if (key in sample_list) sample_list[key] = sample_list[key] "," sample
            else sample_list[key] = sample
        }
        if (!(key in key_bc)) { key_bc[key] = bc; key_gene[key] = gene; key_pat[key] = pattern }
    }
    END {
        for (key in pooled) {
            bc = key_bc[key]; gene = key_gene[key]; pattern = key_pat[key]
            pc = pooled[key]
            gt_key = bc SUBSEP gene
            gt = gene_total[gt_key]
            if (gt > 0) pct = sprintf("%.1f%%", (pc / gt) * 100)
            else pct = "0.0%"
            printf "%s\t%s\t%s\t%d\t%d\t%s\t%s\n", bc, gene, pattern, pc, n_samples[key], sample_list[key], pct
        }
    }
    ' "$merged_file" | sort -t'	' -k1,1 -k2,2 -k4,4rn > "${output_file}.tmp"

    printf "barcode\tgene\tsplice_pattern\tpooled_count\tn_samples\tsamples_with_pattern\tpct_of_gene\n" > "$output_file"
    cat "${output_file}.tmp" >> "$output_file"
    rm -f "${output_file}.tmp"
}

# ---------------------------------------------------------------------------
# Normalize counts against housekeeping gene(s)
# Computes ratios both per-gene-total and per-isoform.
# ---------------------------------------------------------------------------
_normalize_counts() {
    local merged_file="$1"
    local housekeeping="$2"
    local output_file="$3"

    echo "  Normalizing against housekeeping gene(s): $housekeeping ..."

    awk -F'\t' -v hk_genes="$housekeeping" '
    BEGIN {
        # Parse comma-separated housekeeping gene names
        n_hk = split(hk_genes, hk_arr, ",")
        for (i = 1; i <= n_hk; i++) is_hk[hk_arr[i]] = 1
    }
    NR == 1 { next }  # skip header
    {
        gene = $1; sample = $2; total = $3; pattern = $4; pcount = $5
        # Accumulate gene totals per sample
        gene_sample_total[gene, sample] += pcount
        # Store per-isoform rows
        idx++
        row_gene[idx] = gene
        row_sample[idx] = sample
        row_total[idx] = total
        row_pattern[idx] = pattern
        row_pcount[idx] = pcount
    }
    END {
        print "gene\tsample\tlevel\tsplice_pattern\tcount\thk_gene\thk_count\tratio"

        for (r = 1; r <= idx; r++) {
            gene = row_gene[r]
            sample = row_sample[r]
            pattern = row_pattern[r]
            pcount = row_pcount[r]
            gtotal = gene_sample_total[gene, sample]

            for (i = 1; i <= n_hk; i++) {
                hk = hk_arr[i]
                hk_count = gene_sample_total[hk, sample] + 0

                # Gene-total row (emit once per gene×sample×hk, on first pattern)
                key = gene SUBSEP sample SUBSEP hk
                if (!(key in emitted)) {
                    emitted[key] = 1
                    if (hk_count > 0) ratio = sprintf("%.3f", gtotal / hk_count)
                    else ratio = "NA"
                    printf "%s\t%s\tgene_total\t*\t%d\t%s\t%d\t%s\n", \
                        gene, sample, gtotal, hk, hk_count, ratio
                }

                # Per-isoform row
                if (hk_count > 0) ratio = sprintf("%.3f", pcount / hk_count)
                else ratio = "NA"
                printf "%s\t%s\tisoform\t%s\t%d\t%s\t%d\t%s\n", \
                    gene, sample, pattern, pcount, hk, hk_count, ratio
            }
        }
    }
    ' "$merged_file" > "$output_file"
}
