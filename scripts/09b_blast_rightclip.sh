#!/bin/bash
# 09b_blast_rightclip.sh -- Batch BLAST right-clips against reference databases
# Sourced by 09_tail_correct.sh.
# Optimization: collects all qualifying clips, runs blastn once, then lookups.
#
# Functions:
#   init_blast_batch    -- Initialize batch FASTA file
#   collect_blast_query -- Add a clip sequence to the batch
#   run_batch_blast     -- Run blastn once on collected sequences
#   lookup_blast_result -- Check if a read had a ChrM hit (exit code 0=hit, 1=no hit)
#   lookup_cdna_result  -- Check if a read had a cDNA hit (exit code 0=hit, 1=no hit)

init_blast_batch() {
    local batch_fasta="$1"
    > "$batch_fasta"
}

collect_blast_query() {
    local read_idx="$1"
    local rightclip_seq="$2"
    local batch_fasta="$3"
    printf '>Rightclip_%s\n%s\n' "$read_idx" "$rightclip_seq" >> "$batch_fasta"
}

run_batch_blast() {
    local batch_fasta="$1"
    local blast_db_path="$2"
    local blast_db2_path="$3"
    local tmp_dir="$4"

    # Skip if no sequences to BLAST
    if [ ! -s "$batch_fasta" ]; then
        > "$tmp_dir/blast_chrm_hits.txt"
        return 0
    fi

    # BLAST against ChrM (single invocation for all clips)
    # Full tabular output retained for downstream inspection
    blastn -task megablast \
        -db "$blast_db_path" \
        -query "$batch_fasta" \
        -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore" \
        -out "$tmp_dir/batch_blast_chrm_raw.txt" 2>/dev/null || true

    # Extract unique read IDs that had ChrM hits (for fast lookup)
    if [ -f "$tmp_dir/batch_blast_chrm_raw.txt" ] && [ -s "$tmp_dir/batch_blast_chrm_raw.txt" ]; then
        cut -f1 "$tmp_dir/batch_blast_chrm_raw.txt" | sort -u > "$tmp_dir/blast_chrm_hits.txt"
    else
        > "$tmp_dir/blast_chrm_hits.txt"
    fi

    # Run cDNA BLAST for reads without ChrM hits (identifies PCR chimeras)
    > "$tmp_dir/blast_cdna_hits.txt"
    if [ -n "$blast_db2_path" ] && ls "${blast_db2_path}"* &>/dev/null; then
        grep '^>' "$batch_fasta" | sed 's/^>//' | sort > "$tmp_dir/all_blast_queries.txt"
        comm -23 "$tmp_dir/all_blast_queries.txt" "$tmp_dir/blast_chrm_hits.txt" \
            > "$tmp_dir/no_chrm_reads.txt"

        if [ -s "$tmp_dir/no_chrm_reads.txt" ]; then
            # Extract non-ChrM sequences into separate FASTA for cDNA search
            awk 'NR==FNR{ids[$1]; next}
                 /^>/{name=substr($0,2); p=(name in ids)}
                 p' "$tmp_dir/no_chrm_reads.txt" "$batch_fasta" \
                > "$tmp_dir/batch_no_chrm.fa"

            if [ -s "$tmp_dir/batch_no_chrm.fa" ]; then
                blastn -task megablast \
                    -db "$blast_db2_path" \
                    -query "$tmp_dir/batch_no_chrm.fa" \
                    -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore stitle" \
                    -out "$tmp_dir/batch_blast_cdna.txt" 2>/dev/null || true
            fi

            # Extract unique read IDs with cDNA hits (for chimera detection)
            if [ -f "$tmp_dir/batch_blast_cdna.txt" ] && [ -s "$tmp_dir/batch_blast_cdna.txt" ]; then
                cut -f1 "$tmp_dir/batch_blast_cdna.txt" | sort -u > "$tmp_dir/blast_cdna_hits.txt"
            fi
        fi
    fi
}

# Returns via exit code: 0=ChrM hit (translocation), 1=no hit
lookup_blast_result() {
    local read_idx="$1"
    local tmp_dir="$2"

    if grep -q "^Rightclip_${read_idx}$" "$tmp_dir/blast_chrm_hits.txt" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Returns via exit code: 0=cDNA hit (PCR chimera), 1=no hit
lookup_cdna_result() {
    local read_idx="$1"
    local tmp_dir="$2"

    if grep -q "^Rightclip_${read_idx}$" "$tmp_dir/blast_cdna_hits.txt" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}
