#!/bin/bash
# regions.sh — Region discovery/preparation for gene-level counting
# Part of the L3Rseq pipeline (standalone subcommand, not a pipeline step).
#
# Reads gene coordinates from GFF3, BED, or manual coordinates and writes
# a standardized regions TSV for use with `L3Rseq count`.
#
# Output format (1-based inclusive, matching samtools convention):
#   #gene_name	chr	start	end	strand	source
#   Mp1g00010	chr1	1000	5000	+	MpTak_v7.1.gff3
#
# Usage (called via L3Rseq dispatcher):
#   L3Rseq regions --gff <file> --output regions.tsv [--feature-type gene] [--span gene|cds|mrna]
#   L3Rseq regions --bed <file> --output regions.tsv
#   L3Rseq regions --coordinates "name:chr:start-end,..." --output regions.tsv

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse GFF3/GTF for gene regions
# Uses mawk-compatible attribute extraction (no 3-arg match).
# ---------------------------------------------------------------------------

# Shared awk function block for extracting GFF9 attribute values.
# Usage in awk: get_attr(attrs, "Name") → returns value or ""
AWK_GET_ATTR='
function get_attr(attrs, key,    pat, val, p, rest, before) {
    pat = key "="
    p = index(attrs, pat)
    # Ensure match is at start or after ";" (not a substring like "abcName=")
    while (p > 0) {
        if (p == 1 || substr(attrs, p - 1, 1) == ";") {
            rest = substr(attrs, p + length(pat))
            p = index(rest, ";")
            if (p > 0) val = substr(rest, 1, p - 1)
            else val = rest
            return val
        }
        # False match — search again after this position
        attrs = substr(attrs, p + 1)
        p = index(attrs, pat)
    }
    return ""
}
'

_parse_gff_regions() {
    local gff_file="$1"
    local feature_type="$2"
    local span_mode="$3"
    local name_pattern="$4"
    local chr_filter="$5"
    local source_name
    source_name=$(basename "$gff_file")

    if [ "$span_mode" = "gene" ]; then
        awk -F'\t' -v ft="$feature_type" -v src="$source_name" \
            -v npat="$name_pattern" -v chrf="$chr_filter" \
            "$AWK_GET_ATTR"'
        /^#/ { next }
        $3 == ft {
            chr = $1; start = $4; end = $5; strand = $7
            name = get_attr($9, "Name")
            if (name == "") name = get_attr($9, "ID")
            if (name == "") next
            if (chrf != "" && chr != chrf) next
            if (npat != "") {
                pat = npat; gsub(/\*/, ".*", pat); gsub(/\?/, ".", pat)
                if (name !~ "^" pat "$") next
            }
            print name "\t" chr "\t" start "\t" end "\t" strand "\t" src
        }
        ' "$gff_file"
    elif [ "$span_mode" = "cds" ]; then
        _parse_gff_cds_span "$gff_file" "$source_name" "$name_pattern" "$chr_filter"
    elif [ "$span_mode" = "mrna" ]; then
        awk -F'\t' -v src="$source_name" \
            -v npat="$name_pattern" -v chrf="$chr_filter" \
            "$AWK_GET_ATTR"'
        /^#/ { next }
        $3 == "mRNA" {
            chr = $1; start = $4; end = $5; strand = $7
            name = get_attr($9, "Name")
            if (name == "") name = get_attr($9, "ID")
            if (name == "") next
            if (chrf != "" && chr != chrf) next
            if (npat != "") {
                pat = npat; gsub(/\*/, ".*", pat); gsub(/\?/, ".", pat)
                if (name !~ "^" pat "$") next
            }
            print name "\t" chr "\t" start "\t" end "\t" strand "\t" src
        }
        ' "$gff_file"
    fi
}

# Extract CDS span (ATG→stop) per gene from GFF3.
# Parses gene→mRNA→CDS hierarchy. For each gene, takes the primary (longest)
# mRNA's CDS coordinates: min(start) to max(end).
_parse_gff_cds_span() {
    local gff_file="$1"
    local source_name="$2"
    local name_pattern="$3"
    local chr_filter="$4"

    awk -F'\t' -v src="$source_name" -v npat="$name_pattern" -v chrf="$chr_filter" \
        "$AWK_GET_ATTR"'
    BEGIN { OFS = "\t" }
    /^#/ { next }

    $3 == "gene" {
        id = get_attr($9, "ID")
        if (id == "") next
        gn = get_attr($9, "Name")
        gene_name[id] = (gn != "") ? gn : id
        gene_chr[id] = $1
        gene_strand[id] = $7
    }

    $3 == "mRNA" {
        mid = get_attr($9, "ID")
        parent = get_attr($9, "Parent")
        if (mid != "" && parent != "") mrna_parent[mid] = parent
    }

    $3 == "CDS" {
        parent = get_attr($9, "Parent")
        if (parent == "") next
        if (!(parent in cds_min) || $4 < cds_min[parent]) cds_min[parent] = $4
        if (!(parent in cds_max) || $5 > cds_max[parent]) cds_max[parent] = $5
        cds_span[parent] = cds_max[parent] - cds_min[parent] + 1
    }

    END {
        for (mid in mrna_parent) {
            gid = mrna_parent[mid]
            if (!(mid in cds_min)) continue
            if (!(gid in best_mrna) || cds_span[mid] > cds_span[best_mrna[gid]]) {
                best_mrna[gid] = mid
            }
        }
        for (gid in best_mrna) {
            mid = best_mrna[gid]
            name = gene_name[gid]
            chr = gene_chr[gid]
            strand = gene_strand[gid]
            s = cds_min[mid]
            e = cds_max[mid]
            if (chrf != "" && chr != chrf) continue
            if (npat != "") {
                pat = npat; gsub(/\*/, ".*", pat); gsub(/\?/, ".", pat)
                if (name !~ "^" pat "$") continue
            }
            print name "\t" chr "\t" s "\t" e "\t" strand "\t" src
        }
    }
    ' "$gff_file" | sort -k3,3n
}

# ---------------------------------------------------------------------------
# Parse BED file (0-based half-open → 1-based inclusive)
# ---------------------------------------------------------------------------
_parse_bed_regions() {
    local bed_file="$1"
    local source_name
    source_name=$(basename "$bed_file")

    awk -F'\t' -v src="$source_name" '
    /^#/ || /^$/ { next }
    {
        chr = $1
        start = $2 + 1  # 0-based → 1-based
        end = $3         # half-open → inclusive (end stays same)
        name = (NF >= 4 && $4 != "") ? $4 : chr ":" $2 "-" $3
        strand = (NF >= 6) ? $6 : "."
        print name "\t" chr "\t" start "\t" end "\t" strand "\t" src
    }
    ' "$bed_file"
}

# ---------------------------------------------------------------------------
# Parse manual coordinates string
# Format: "name:chr:start-end,name2:chr:start-end"
# Coordinates are 1-based inclusive (user-facing, same as samtools).
# Note: gene names must not contain colons (colon is the field separator).
# ---------------------------------------------------------------------------
_parse_coordinates() {
    local coords="$1"
    local IFS=","

    for entry in $coords; do
        local name chr range start end
        name="${entry%%:*}"
        local rest="${entry#*:}"
        chr="${rest%%:*}"
        range="${rest#*:}"
        start="${range%%-*}"
        end="${range##*-}"

        if [ -z "$name" ] || [ -z "$chr" ] || [ -z "$start" ] || [ -z "$end" ]; then
            echo "ERROR: Invalid coordinate format: '$entry'" >&2
            echo "       Expected: name:chr:start-end" >&2
            return 1
        fi

        printf "%s\t%s\t%s\t%s\t.\tmanual\n" "$name" "$chr" "$start" "$end"
    done
}

# ---------------------------------------------------------------------------
# Auto-discover gene regions from BAM read positions + GFF annotation.
# Scans all primary BAMs, extracts read midpoints, intersects with GFF genes,
# and returns genes with >= min_reads overlapping reads.
# ---------------------------------------------------------------------------
_discover_from_bams() {
    local bam_dir="$1"
    local gff_file="$2"
    local feature_type="$3"
    local min_reads="$4"
    local span_mode="$5"
    local name_pattern="$6"
    local chr_filter="$7"
    local source_name
    source_name=$(basename "$gff_file")

    local tmpdir
    tmpdir=$(mktemp -d)

    # 1. Extract all gene intervals from GFF (sorted by chr, start)
    echo "  Extracting gene intervals from $(basename "$gff_file") ..." >&2
    if [ "$span_mode" = "cds" ]; then
        _parse_gff_cds_span "$gff_file" "$source_name" "$name_pattern" "$chr_filter" \
            > "$tmpdir/genes_unsorted.tsv"
    elif [ "$span_mode" = "mrna" ]; then
        _parse_gff_regions "$gff_file" "mRNA" "gene" "$name_pattern" "$chr_filter" \
            > "$tmpdir/genes_unsorted.tsv"
    else
        _parse_gff_regions "$gff_file" "$feature_type" "gene" "$name_pattern" "$chr_filter" \
            > "$tmpdir/genes_unsorted.tsv"
    fi
    sort -t$'\t' -k2,2 -k3,3n "$tmpdir/genes_unsorted.tsv" > "$tmpdir/genes.tsv"
    local n_genes
    n_genes=$(wc -l < "$tmpdir/genes.tsv")
    echo "  Found $n_genes gene(s) in GFF" >&2

    # 2. Find all primary BAMs and extract read midpoints
    echo "  Scanning BAMs for read positions ..." >&2
    local bam_base="$bam_dir/07_map"
    if [ ! -d "$bam_base" ]; then
        # Allow passing 07_map dir directly
        if [ -d "$bam_dir" ]; then
            bam_base="$bam_dir"
        else
            echo "  ERROR: 07_map directory not found at $bam_dir/07_map" >&2
            rm -rf "$tmpdir"
            return 1  # intentional: fatal error, should stop the pipeline
        fi
    fi

    local n_reads=0
    find "$bam_base" -name "*_primary.sort.bam" -print0 | while IFS= read -r -d '' bam; do
        samtools view -F 0x904 "$bam" 2>/dev/null || true
    done | awk '
    {
        pos = $4; cigar = $6; reflen = 0; c = cigar
        while (match(c, /[0-9]+/)) {
            n = substr(c, RSTART, RLENGTH) + 0
            c = substr(c, RSTART + RLENGTH)
            op = substr(c, 1, 1); c = substr(c, 2)
            if (op=="M"||op=="D"||op=="N"||op=="="||op=="X") reflen += n
        }
        printf "%s\t%d\n", $3, int(pos + reflen/2)
    }' | sort -k1,1 -k2,2n > "$tmpdir/reads.tsv"

    n_reads=$(wc -l < "$tmpdir/reads.tsv")
    echo "  Found $n_reads read midpoint(s) across all BAMs" >&2

    if [ "$n_reads" -eq 0 ]; then
        echo "  WARNING: No mapped reads found" >&2
        rm -rf "$tmpdir"
        return 0  # return 0 so caller handles empty output via wc -l check
    fi

    # 3. Count reads per gene using sorted sweep (efficient O(reads + genes))
    # genes.tsv: name\tchr\tstart\tend\tstrand\tsource
    # reads.tsv: chr\tmidpoint
    awk -F'\t' -v min_reads="$min_reads" '
    NR == FNR {
        # Load genes (sorted by chr, start)
        ng++
        g_name[ng] = $1; g_chr[ng] = $2; g_start[ng] = $3
        g_end[ng] = $4; g_strand[ng] = $5; g_src[ng] = $6
        next
    }
    {
        # For each read midpoint, find overlapping genes
        chr = $1; pos = $2
        for (i = 1; i <= ng; i++) {
            if (g_chr[i] < chr) continue
            if (g_chr[i] > chr) break
            # Same chromosome
            if (g_start[i] > pos) break
            if (g_end[i] >= pos) counts[i]++
        }
    }
    END {
        for (i = 1; i <= ng; i++) {
            if (counts[i]+0 >= min_reads) {
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\n", \
                    g_name[i], g_chr[i], g_start[i], g_end[i], g_strand[i], g_src[i], counts[i]
            }
        }
    }
    ' "$tmpdir/genes.tsv" "$tmpdir/reads.tsv" | sort -t$'\t' -k7,7rn > "$tmpdir/hits.tsv"

    local n_hits
    n_hits=$(wc -l < "$tmpdir/hits.tsv")
    echo "  Discovered $n_hits gene(s) with >= $min_reads read(s)" >&2

    # Output: standard regions format (drop the count column, but show it in log)
    if [ "$n_hits" -gt 0 ]; then
        {
            echo ""
            echo "  Gene                 Chr    Start       End         Reads"
            echo "  ----                 ---    -----       ---         -----"
            awk -F'\t' '{ printf "  %-20s %-6s %-11s %-11s %s\n", $1, $2, $3, $4, $7 }' "$tmpdir/hits.tsv"
            echo ""
        } >&2
    fi

    # Write regions (without count column)
    cut -f1-6 "$tmpdir/hits.tsv"

    rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
run_regions() {
    local input="$1"
    local output_file="$2"
    local input_mode="$3"      # gff, bed, coordinates, or discover
    local feature_type="$4"
    local span_mode="$5"
    local name_pattern="$6"
    local chr_filter="$7"
    local append="${8:-0}"
    local discover_dir="${9:-}"
    local min_reads="${10:-1}"

    echo "[regions] Preparing gene regions ..."

    local tmpfile
    tmpfile=$(mktemp)

    case "$input_mode" in
        gff)
            if [ ! -f "$input" ]; then
                echo "ERROR: GFF file not found: $input" >&2
                rm -f "$tmpfile"
                return 1
            fi
            echo "  Parsing GFF: $(basename "$input") (feature=$feature_type, span=$span_mode)"
            _parse_gff_regions "$input" "$feature_type" "$span_mode" "$name_pattern" "$chr_filter" > "$tmpfile"
            ;;
        bed)
            if [ ! -f "$input" ]; then
                echo "ERROR: BED file not found: $input" >&2
                rm -f "$tmpfile"
                return 1
            fi
            echo "  Parsing BED: $(basename "$input")"
            _parse_bed_regions "$input" > "$tmpfile"
            ;;
        coordinates)
            echo "  Parsing coordinates: $input"
            _parse_coordinates "$input" > "$tmpfile"
            ;;
        discover)
            if [ ! -f "$input" ]; then
                echo "ERROR: GFF file not found: $input" >&2
                rm -f "$tmpfile"
                return 1
            fi
            if [ -z "$discover_dir" ]; then
                echo "ERROR: --discover-from requires a BAM directory" >&2
                rm -f "$tmpfile"
                return 1
            fi
            echo "  Auto-discovering gene regions from BAMs + GFF ..."
            _discover_from_bams "$discover_dir" "$input" "$feature_type" "$min_reads" \
                "$span_mode" "$name_pattern" "$chr_filter" > "$tmpfile"
            ;;
        *)
            echo "ERROR: Unknown input mode: $input_mode" >&2
            rm -f "$tmpfile"
            return 1
            ;;
    esac

    local count
    count=$(wc -l < "$tmpfile")

    if [ "$count" -eq 0 ]; then
        echo "  WARNING: No regions found." >&2
        rm -f "$tmpfile"
        return 1
    fi

    # Write output (with or without append)
    local out_dir
    out_dir=$(dirname "$output_file")
    mkdir -p "$out_dir"

    if [ "$append" -eq 1 ] && [ -f "$output_file" ]; then
        # Append mode: add new regions, skip header
        cat "$tmpfile" >> "$output_file"
        echo "  Appended $count region(s) to $output_file"
    else
        # Write fresh file with header
        printf "#gene_name\tchr\tstart\tend\tstrand\tsource\n" > "$output_file"
        cat "$tmpfile" >> "$output_file"
        echo "  Wrote $count region(s) to $output_file"
    fi

    rm -f "$tmpfile"
}
