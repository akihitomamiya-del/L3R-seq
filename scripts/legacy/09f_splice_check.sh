#!/bin/bash
# 09f_splice_check.sh -- Check read alignment for intron splicing
# Sourced by 09_tail_correct.sh. Defines check_splice().
#
# Input:  CIGAR string, alignment start (POS), intron coordinates
# Output: sets RESULT_SJ (per-intron pattern), RESULT_SI (spliced count),
#         RESULT_IR (retained count)
#
# Intron coordinates passed via INTRON_STARTS[] and INTRON_ENDS[] arrays.

# Parse intron specification into INTRON_STARTS and INTRON_ENDS arrays.
# Accepts:
#   "500-2100"           — single intron shorthand
#   "500-2100,3500-4200" — multiple introns shorthand
#   /path/to/file.bed    — BED file (0-based coords: chrom start end [name])
#   /path/to/file.gff3   — GFF3/GTF (1-based coords, extracts "intron" features
#                           or infers introns from gaps between "exon" features)
#   /path/to/file.gtf    — same as GFF3
parse_introns() {
    local spec="$1"
    INTRON_STARTS=()
    INTRON_ENDS=()
    N_INTRONS=0

    if [ -z "$spec" ]; then
        return 0
    fi

    if [ -f "$spec" ]; then
        local ext="${spec##*.}"
        case "$ext" in
            gff|gff3|gtf)
                # GFF3/GTF: try explicit intron features first, then infer from exons
                _parse_gff "$spec"
                ;;
            *)
                # BED file: tab-separated, columns: chrom start end [name]
                while IFS=$'\t' read -r _chrom _start _end _rest; do
                    [[ "$_chrom" == "#"* ]] && continue
                    [ -z "$_start" ] && continue
                    INTRON_STARTS+=("$_start")
                    INTRON_ENDS+=("$_end")
                done < "$spec"
                ;;
        esac
    else
        # Shorthand: "500-2100" or "500-2100,3500-4200"
        local IFS=','
        for entry in $spec; do
            local start="${entry%-*}"
            local end="${entry#*-}"
            INTRON_STARTS+=("$start")
            INTRON_ENDS+=("$end")
        done
    fi

    N_INTRONS=${#INTRON_STARTS[@]}
}

# Parse GFF3/GTF file for intron coordinates.
# WARNING: Only tested on simple synthetic GFF3 files. Real-world GFF3 from
# TAIR/Ensembl/NCBI may have multiple transcripts, non-standard features, etc.
# that could cause incorrect parsing. Use BED or shorthand for reliable results.
# Strategy: (1) use explicit "intron" features if present,
# (2) otherwise infer introns from gaps between sorted "exon" features.
# GFF uses 1-based inclusive coordinates; we convert to 0-based half-open.
_parse_gff() {
    local gff_file="$1"

    # Try explicit intron features first
    local found_introns=0
    while IFS=$'\t' read -r _seq _src _type _start _end _rest; do
        [[ "$_seq" == "#"* ]] && continue
        if [ "$_type" = "intron" ]; then
            # GFF is 1-based inclusive → convert to 0-based half-open
            INTRON_STARTS+=("$((_start - 1))")
            INTRON_ENDS+=("$_end")
            found_introns=1
        fi
    done < "$gff_file"

    if [ "$found_introns" -eq 1 ]; then
        return 0
    fi

    # No explicit intron features — infer from exon gaps
    # Collect exon coordinates, sort by start position
    local exon_coords
    exon_coords=$(awk -F'\t' '
        !/^#/ && $3 == "exon" { print $4, $5 }
    ' "$gff_file" | sort -k1,1n)

    if [ -z "$exon_coords" ]; then
        echo "  WARNING: No intron or exon features found in $gff_file" >&2
        return 0
    fi

    # Introns are the gaps between consecutive exons
    local prev_end=0
    while read -r _start _end; do
        if [ "$prev_end" -gt 0 ] && [ "$_start" -gt "$prev_end" ]; then
            # Gap between previous exon end and this exon start = intron
            # GFF is 1-based inclusive: prev exon ends at prev_end,
            # next exon starts at _start. Intron is prev_end..(_start-1) in 1-based
            # → (prev_end)..(start-1) in 0-based half-open
            INTRON_STARTS+=("$prev_end")
            INTRON_ENDS+=("$((_start - 1))")
        fi
        prev_end="$_end"
    done <<< "$exon_coords"
}

# Check one read's CIGAR for intron splicing.
# Sets: RESULT_SJ, RESULT_SI, RESULT_IR
check_splice() {
    local cigar="$1"
    local aln_start="$2"  # 1-based POS from SAM

    RESULT_SJ=""
    RESULT_SI=0
    RESULT_IR=0

    if [ "$N_INTRONS" -eq 0 ]; then
        return 0
    fi

    # Walk CIGAR to collect all deletions with their reference positions
    local ref_pos=$((aln_start - 1))  # convert to 0-based
    local read_end_ref=$ref_pos

    # Collect large deletions (>= 50bp) as "start:end" pairs
    local del_starts=()
    local del_ends=()

    local num=""
    local i
    for ((i=0; i<${#cigar}; i++)); do
        local c="${cigar:$i:1}"
        if [[ "$c" =~ [0-9] ]]; then
            num="${num}${c}"
        else
            local len=$((num + 0))
            num=""
            case "$c" in
                M|=|X)
                    ref_pos=$((ref_pos + len))
                    ;;
                D)
                    if [ "$len" -ge 50 ]; then
                        del_starts+=("$ref_pos")
                        del_ends+=("$((ref_pos + len))")
                    fi
                    ref_pos=$((ref_pos + len))
                    ;;
                I|S|H|P)
                    # These don't consume reference
                    ;;
                N)
                    # Skipped region (splice in some aligners)
                    if [ "$len" -ge 50 ]; then
                        del_starts+=("$ref_pos")
                        del_ends+=("$((ref_pos + len))")
                    fi
                    ref_pos=$((ref_pos + len))
                    ;;
            esac
        fi
    done
    read_end_ref=$ref_pos

    # For each annotated intron, determine if this read shows splicing
    local sj_pattern=""
    local aln_start_0=$((aln_start - 1))

    for ((j=0; j<N_INTRONS; j++)); do
        local intron_s="${INTRON_STARTS[$j]}"
        local intron_e="${INTRON_ENDS[$j]}"
        local intron_len=$((intron_e - intron_s))

        # Does this read span the intron region?
        # Read must cover at least 20bp before intron start AND 20bp after intron end
        if [ "$aln_start_0" -gt $((intron_s - 20)) ] || [ "$read_end_ref" -lt $((intron_e + 20)) ]; then
            sj_pattern="${sj_pattern}-"
            continue
        fi

        # Check if any large deletion matches this intron (within ±10bp tolerance)
        local found_splice=0
        for ((k=0; k<${#del_starts[@]}; k++)); do
            local ds="${del_starts[$k]}"
            local de="${del_ends[$k]}"
            local del_len=$((de - ds))

            # Check overlap: deletion boundaries within ±10bp of intron boundaries
            local start_diff=$((ds - intron_s))
            local end_diff=$((de - intron_e))
            [ "$start_diff" -lt 0 ] && start_diff=$((-start_diff))
            [ "$end_diff" -lt 0 ] && end_diff=$((-end_diff))

            if [ "$start_diff" -le 10 ] && [ "$end_diff" -le 10 ]; then
                # Deletion matches intron — check size (≥80% of intron length)
                if [ "$del_len" -ge $((intron_len * 80 / 100)) ]; then
                    found_splice=1
                    break
                fi
            fi
        done

        if [ "$found_splice" -eq 1 ]; then
            sj_pattern="${sj_pattern}S"
            RESULT_SI=$((RESULT_SI + 1))
        else
            sj_pattern="${sj_pattern}R"
            RESULT_IR=$((RESULT_IR + 1))
        fi
    done

    RESULT_SJ="$sj_pattern"
}

# Convert intron-matching D operations to N (SAM intron-skip) in the CIGAR.
# Must be called after check_splice(). Uses INTRON_STARTS[], INTRON_ENDS[], N_INTRONS.
# Sets RESULT_CIGAR_SPLICED (modified CIGAR string).
convert_intron_d_to_n() {
    local cigar="$1"
    local aln_start="$2"  # 1-based POS from SAM

    RESULT_CIGAR_SPLICED="$cigar"

    if [ "$N_INTRONS" -eq 0 ]; then
        return 0
    fi

    # Walk CIGAR, rebuild with D→N for intron-matching deletions
    local ref_pos=$(( aln_start - 1 ))  # 0-based
    local new_cigar=""
    local num=""
    local i c len
    for ((i=0; i<${#cigar}; i++)); do
        c="${cigar:$i:1}"
        if [[ "$c" =~ [0-9] ]]; then
            num="${num}${c}"
        else
            len=$((num + 0))
            num=""
            case "$c" in
                M|=|X)
                    new_cigar="${new_cigar}${len}${c}"
                    ref_pos=$((ref_pos + len))
                    ;;
                D)
                    local is_intron=0
                    if [ "$len" -ge 50 ]; then
                        local del_start=$ref_pos
                        local del_end=$((ref_pos + len))
                        local j start_diff end_diff intron_len
                        for ((j=0; j<N_INTRONS; j++)); do
                            intron_len=$((INTRON_ENDS[j] - INTRON_STARTS[j]))
                            start_diff=$((del_start - INTRON_STARTS[j]))
                            end_diff=$((del_end - INTRON_ENDS[j]))
                            [ "$start_diff" -lt 0 ] && start_diff=$((-start_diff))
                            [ "$end_diff" -lt 0 ] && end_diff=$((-end_diff))
                            if [ "$start_diff" -le 10 ] && [ "$end_diff" -le 10 ] && [ "$len" -ge $((intron_len * 80 / 100)) ]; then
                                is_intron=1
                                break
                            fi
                        done
                    fi
                    if [ "$is_intron" -eq 1 ]; then
                        new_cigar="${new_cigar}${len}N"
                    else
                        new_cigar="${new_cigar}${len}D"
                    fi
                    ref_pos=$((ref_pos + len))
                    ;;
                I|S|H|P)
                    new_cigar="${new_cigar}${len}${c}"
                    ;;
                N)
                    new_cigar="${new_cigar}${len}N"
                    ref_pos=$((ref_pos + len))
                    ;;
                *)
                    new_cigar="${new_cigar}${len}${c}"
                    ;;
            esac
        fi
    done

    RESULT_CIGAR_SPLICED="$new_cigar"
}
