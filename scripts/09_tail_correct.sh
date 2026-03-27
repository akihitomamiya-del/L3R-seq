#!/bin/bash
# 09_tail_correct.sh -- Right-clip CIGAR correction (optimized + parallel)
# Called by L3Rseq dispatcher.
# Sources: 09{a-e}_*.sh subscript functions.
#
# Optimizations vs v1:
#   Phase 1a: O(N) single-pass SAM pre-split (was O(N²) per-read awk scan)
#   Phase 1b: Pre-load reference into bash variable (was per-base awk FASTA read)
#   Phase 1c: Single awk for SAM tag annotation (was 8 chained seds per read)
#   Phase 2a: Batch BLAST — one blastn call for all qualifying clips
#   Phase 3:  Read-level parallelism via chunked subshells + ordered merge
#
# Requires: INPUT_DIR, OUTPUT_DIR, REF_FILE, VAR_FILE, PATTERN,
#           BLAST_DB_PATH, BLAST_DB2_PATH, CLIP_THRESH, [VARIANTS_DIR], [THREADS]

set +e  # Step 09 handles errors manually due to complex control flow

run_step_09() {
    local input_dir="$1"
    local output_dir="$2"
    local ref_file="$3"
    local var_file="$4"
    local pattern="$5"
    local blast_db_path="$6"
    local blast_db2_path="$7"
    local clip_thresh="$8"
    local variants_dir="${9:-}"
    local threads="${10:-1}"
    local count_pattern="${11:-}"
    local introns="${12:-}"

    # Resolve script directory for sourcing subscripts
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Source v2 subscript functions
    source "$script_dir/09a_parse_cigar.sh"
    source "$script_dir/09b_blast_rightclip.sh"
    source "$script_dir/09c_walk_correction.sh"
    source "$script_dir/09d_rebuild_cigar.sh"
    source "$script_dir/09e_call_variants.sh"
    source "$script_dir/09f_splice_check.sh"

    # Parse intron annotations (if provided)
    parse_introns "$introns"
    if [ "$N_INTRONS" -gt 0 ]; then
        echo "    Intron annotations loaded: $N_INTRONS intron(s)"
    fi

    mkdir -p "$output_dir/09_correct"

    echo "[Step 09v2] Tail correction (optimized, threads=$threads) ..."

    # === Phase 1b: Pre-load reference sequence once (all samples share it) ===
    local ref_seq
    ref_seq=$(awk '/^>/{next} {gsub(/\r/,""); printf "%s", toupper($0)}' "$ref_file")
    echo "    Reference loaded: ${#ref_seq}bp"

    # -----------------------------------------------------------------
    # Worker function: process a single read
    # Accesses variables from the calling scope (dynamic scoping):
    #   tmp_dir, ref_seq, active_var_file,
    #   pattern, count_pattern, clip_thresh, blast_batched, blast_available
    # Writes results to:
    #   $tmp_dir/result_${read_idx}.status  (CORRECTED | ABNORMAL)
    #   $tmp_dir/result_${read_idx}.line    (annotated SAM line)
    # -----------------------------------------------------------------
    _process_one_read() {
        local read_idx="$1"
        set +e

        local read_line
        read_line=$(cat "$tmp_dir/read_${read_idx}.txt")

        # Get fields 1-11 for SAM file creation (matches v1 cut -f1-11 behavior)
        local read_line_11
        read_line_11=$(printf '%s\n' "$read_line" | cut -f1-11)

        # Parse CIGAR from read line (no samtools call)
        run_parse_cigar "$read_line"

        local translocation=0

        if [ "$RESULT_Rightclip_N" -eq 0 ]; then
            # --- No right-clip: call variants and annotate directly ---

            # CIGAR-walk variant calling (no bcftools, no SAM file needed)
            run_call_variants "$read_line" "$ref_seq" "$pattern" "$count_pattern"

            # Splice check (if introns annotated)
            local sj_tags=""
            local cigar_spliced=""
            if [ "$N_INTRONS" -gt 0 ]; then
                local cigar_field
                cigar_field=$(printf '%s\n' "$read_line" | cut -f6)
                check_splice "$cigar_field" "$RESULT_Aln_Start"
                sj_tags="SJ:Z:${RESULT_SJ}\tSI:i:${RESULT_SI}\tIR:i:${RESULT_IR}"
                # Convert intron D→N in CIGAR for proper SAM semantics
                convert_intron_d_to_n "$cigar_field" "$RESULT_Aln_Start"
                cigar_spliced="$RESULT_CIGAR_SPLICED"
            fi

            local terminus=$((RESULT_Aln_Start - 1 + RESULT_Total_M + RESULT_Total_D))
            local matched_length=$((RESULT_Total_M + RESULT_Total_D))
            local doublesorter=$((terminus * 10000 + RESULT_Rightclip_N))

            # Phase 1c: single awk replaces 8 chained seds
            local sc_tag=""
            [ -n "$count_pattern" ] && sc_tag="SC:i:${RESULT_SC}"
            printf '%s\n' "$read_line_11" | \
                awk -v OFS="\t" -v cigar_new="$cigar_spliced" \
                    -v t="$terminus" -v rc="$RESULT_Rightclip_N" \
                    -v rs="" -v tl="$translocation" -v ds="$doublesorter" \
                    -v ec="$RESULT_EC" -v sc_tag="$sc_tag" -v nc="$RESULT_NC" -v ml="$matched_length" -v vr="$RESULT_variants" \
                    -v sj_tags="$sj_tags" \
                    '{if (cigar_new != "") $6 = cigar_new; s = $0 "\t3E:i:" t "\tRC:i:" rc "\tRS:Z:" rs "\tTL:i:" tl "\tDS:i:" ds "\tEC:i:" ec; if (sc_tag != "") s = s "\t" sc_tag; s = s "\tNC:i:" nc "\tmL:i:" ml "\tVR:Z:" vr; if (sj_tags != "") s = s "\t" sj_tags; print s}' \
                > "$tmp_dir/result_${read_idx}.line"

            echo "CORRECTED" > "$tmp_dir/result_${read_idx}.status"
            return 0
        fi

        # --- Has right-clip: determine BLAST status ---
        local blast_status="SKIP"  # default: proceed to walk correction
        if [ "$RESULT_Rightclip_N" -gt "$clip_thresh" ]; then
            if [ "$blast_batched" -eq 1 ]; then
                # Phase 2a: lookup batch BLAST results
                if lookup_blast_result "$read_idx" "$tmp_dir"; then
                    blast_status="CHRM_HIT"
                elif lookup_cdna_result "$read_idx" "$tmp_dir"; then
                    blast_status="CDNA_HIT"
                else
                    blast_status="SKIP"  # no hit anywhere — retain (unidentified clip)
                fi
            elif [ "$blast_available" -eq 0 ]; then
                blast_status="SKIP"  # no DB available — proceed to walk correction
            fi
        fi

        if [ "$blast_status" = "CDNA_HIT" ]; then
            # PCR chimera — non-mitochondrial cDNA hit (rRNA, TE, etc.)
            echo "CHIMERIC" > "$tmp_dir/result_${read_idx}.status"
            printf '%s\n' "$read_line_11" > "$tmp_dir/result_${read_idx}.line"
            return 0
        fi

        if [ "$blast_status" = "CHRM_HIT" ]; then
            translocation=1
        fi

        # --- Walk correction (uses pre-loaded ref_seq, not file) ---
        local ref_position=$((RESULT_Aln_Start - 1 + RESULT_Total_M + RESULT_Total_D + 1))
        run_walk_correction "$ref_position" "$RESULT_Rightclip_seq" \
            "$ref_seq" "$active_var_file" "$pattern"

        # Rebuild CIGAR
        run_rebuild_cigar "$RESULT_Aln_CIGAR" "$RESULT_Match_counter"

        # CIGAR-walk variant calling on original alignment (no bcftools needed)
        run_call_variants "$read_line" "$ref_seq" "$pattern" "$count_pattern"

        # Splice check on corrected CIGAR (if introns annotated)
        local sj_tags=""
        if [ "$N_INTRONS" -gt 0 ]; then
            check_splice "$RESULT_New_CIGAR" "$RESULT_Aln_Start"
            sj_tags="SJ:Z:${RESULT_SJ}\tSI:i:${RESULT_SI}\tIR:i:${RESULT_IR}"
            # Convert intron D→N in corrected CIGAR
            convert_intron_d_to_n "$RESULT_New_CIGAR" "$RESULT_Aln_Start"
            RESULT_New_CIGAR="$RESULT_CIGAR_SPLICED"
        fi

        # Calculate metrics with corrected CIGAR
        local new_total_m
        new_total_m=$(echo "$RESULT_New_CIGAR" | grep -Eo '[0-9]+M' | grep -Eo '[0-9]+' | awk '{a+=$1} END{print a+0;}')
        local terminus=$((RESULT_Aln_Start - 1 + new_total_m + RESULT_Total_D))
        local matched_length=$((RESULT_Total_M + RESULT_Total_D))
        local doublesorter=$((terminus * 10000 + RESULT_CIGAR_Tail_new_S))

        # Get remaining right-clip sequence after correction
        local rightclip_seq_new=""
        if [ "$RESULT_CIGAR_Tail_new_S" -gt 0 ]; then
            local seq
            seq=$(printf '%s\n' "$read_line" | cut -f10)
            rightclip_seq_new=$(echo "$seq" | grep -Eio "[ATGC]{$RESULT_CIGAR_Tail_new_S}$" || true)
        fi

        # Phase 1c: single awk replaces CIGAR + 8 chained seds
        local sc_tag=""
        [ -n "$count_pattern" ] && sc_tag="SC:i:${RESULT_SC}"
        printf '%s\n' "$read_line_11" | \
            awk -v OFS="\t" -v c="$RESULT_New_CIGAR" \
                -v t="$terminus" -v rc="$RESULT_CIGAR_Tail_new_S" \
                -v rs="$rightclip_seq_new" -v tl="$translocation" -v ds="$doublesorter" \
                -v ec="$RESULT_EC" -v sc_tag="$sc_tag" -v nc="$RESULT_NC" -v ml="$matched_length" -v vr="$RESULT_variants" \
                -v sj_tags="$sj_tags" \
                '{$6 = c; s = $0 "\t3E:i:" t "\tRC:i:" rc "\tRS:Z:" rs "\tTL:i:" tl "\tDS:i:" ds "\tEC:i:" ec; if (sc_tag != "") s = s "\t" sc_tag; s = s "\tNC:i:" nc "\tmL:i:" ml "\tVR:Z:" vr; if (sj_tags != "") s = s "\t" sj_tags; print s}' \
            > "$tmp_dir/result_${read_idx}.line"

        echo "CORRECTED" > "$tmp_dir/result_${read_idx}.status"
        return 0
    }

    # =================================================================
    # Per-sample loop
    # =================================================================

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
            mkdir -p "$output_dir/09_correct/$bname/$rpi_name"
            local odir="$output_dir/09_correct/$bname/$rpi_name"
            local tmp_dir="$odir/Temp"
            mkdir -p "$tmp_dir"

            # Trap: clean up temp files on interruption
            trap "echo '  Interrupted — cleaning up temp files...'; rm -rf '$tmp_dir'; exit 130" INT TERM

            # Determine variant file (same logic as v1)
            local active_var_file="$var_file"
            if [ -z "$active_var_file" ] || [ ! -f "$active_var_file" ]; then
                if [ -n "$variants_dir" ]; then
                    local auto_var="$variants_dir/$bname/$rpi_name/observed_variants.txt"
                    if [ -f "$auto_var" ]; then
                        active_var_file="$auto_var"
                        echo "    Using detected variants from step 08: $auto_var"
                    fi
                fi
            fi
            if [ -z "$active_var_file" ] || [ ! -f "$active_var_file" ]; then
                active_var_file=""
                echo "    No variant file available -- correction will not tolerate editing mismatches"
            fi

            local nreads
            nreads=$(samtools view --no-header "$input_sam" | wc -l)
            echo "    $nreads reads to process"

            if [ "$nreads" -eq 0 ]; then
                samtools view -H "$input_sam" > "$odir/corrected.sam"
                samtools view -H "$input_sam" > "$odir/chimeric_rightclip.sam"
                samtools view -bS "$odir/corrected.sam" > "$odir/corrected.bam"
                samtools sort "$odir/corrected.bam" > "$odir/corrected.sort.bam"
                samtools index "$odir/corrected.sort.bam"
                rm -rf "$tmp_dir"
                continue
            fi

            local start_time
            start_time=$(date +%s)

            # =========================================================
            # Phase 1a: Pre-split SAM in one pass — O(N) not O(N²)
            # Also identifies BLAST candidates in the same pass.
            # =========================================================
            local header_file="$tmp_dir/header.sam"
            samtools view -H "$input_sam" > "$header_file"

            # Check BLAST DB availability
            local blast_available=0
            if [ -n "$blast_db_path" ] && ls "${blast_db_path}"* &>/dev/null; then
                blast_available=1
            fi

            # Combined pre-split + BLAST candidate collection (single awk pass)
            > "$tmp_dir/blast_batch.fa"
            samtools view --no-header "$input_sam" | \
                awk -F'\t' -v tmpdir="$tmp_dir" -v thresh="$clip_thresh" -v do_blast="$blast_available" '
                {
                    # Write each read to its own file
                    fname = tmpdir "/read_" NR ".txt"
                    print > fname
                    close(fname)

                    # Identify BLAST candidates (clips > threshold)
                    if (do_blast + 0 == 1) {
                        cigar = $6
                        if (match(cigar, /[0-9]+S$/)) {
                            rc_str = substr(cigar, RSTART, RLENGTH - 1)
                            rc_n = rc_str + 0
                            if (rc_n > thresh + 0) {
                                seq = $10
                                rc_seq = substr(seq, length(seq) - rc_n + 1)
                                bfa = tmpdir "/blast_batch.fa"
                                print ">Rightclip_" NR >> bfa
                                print rc_seq >> bfa
                            }
                        }
                    }
                }'

            # =========================================================
            # Phase 2a: Batch BLAST (single blastn call)
            # =========================================================
            local blast_batched=0

            if [ -s "$tmp_dir/blast_batch.fa" ]; then
                local blast_count
                blast_count=$(grep -c '^>' "$tmp_dir/blast_batch.fa")
                echo "    Batch BLAST: $blast_count reads with clips > ${clip_thresh}bp"
                run_batch_blast "$tmp_dir/blast_batch.fa" "$blast_db_path" "$blast_db2_path" "$tmp_dir"
                blast_batched=1
            elif [ "$blast_available" -eq 0 ]; then
                # Count candidates even when DB unavailable (for warning)
                # Re-check via a quick awk — only runs if DB is missing
                local candidate_count
                candidate_count=$(samtools view --no-header "$input_sam" | \
                    awk -F'\t' -v thresh="$clip_thresh" '
                    {
                        cigar = $6
                        if (match(cigar, /[0-9]+S$/)) {
                            rc_str = substr(cigar, RSTART, RLENGTH - 1)
                            if (rc_str + 0 > thresh + 0) count++
                        }
                    }
                    END { print count+0 }')
                if [ "$candidate_count" -gt 0 ]; then
                    echo "    WARNING: BLAST DB not found at $blast_db_path. $candidate_count reads with long clips will proceed without BLAST filtering."
                fi
            fi

            # Initialize output SAM files with headers
            samtools view -H "$input_sam" > "$odir/corrected.sam"
            samtools view -H "$input_sam" > "$odir/chimeric_rightclip.sam"

            # =========================================================
            # Phase 3: Process reads (sequential or parallel)
            # =========================================================
            echo "    Processing $nreads reads (threads=$threads) ..."

            if [ "$threads" -le 1 ]; then
                # Sequential mode
                for ((i=1; i<=nreads; i++)); do
                    _process_one_read "$i"
                done
            else
                # Parallel mode: split reads into chunks (one per thread)
                seq 1 "$nreads" > "$tmp_dir/indices.txt"
                local chunk_size=$(( (nreads + threads - 1) / threads ))
                split -l "$chunk_size" "$tmp_dir/indices.txt" "$tmp_dir/chunk_"

                local pids=()
                for chunk_file in "$tmp_dir"/chunk_*; do
                    (
                        while IFS= read -r idx; do
                            _process_one_read "$idx"
                        done < "$chunk_file"
                    ) &
                    pids+=($!)
                done

                # Wait for all worker subshells
                local failed=0
                for pid in "${pids[@]}"; do
                    wait "$pid" || failed=$((failed + 1))
                done
                if [ "$failed" -gt 0 ]; then
                    echo "    WARNING: $failed worker(s) returned non-zero exit"
                fi
            fi

            # =========================================================
            # Merge results (preserving read order for determinism)
            # =========================================================
            for ((i=1; i<=nreads; i++)); do
                local read_status
                read_status=$(cat "$tmp_dir/result_${i}.status" 2>/dev/null || echo "MISSING")
                if [ "$read_status" = "CORRECTED" ]; then
                    cat "$tmp_dir/result_${i}.line" >> "$odir/corrected.sam"
                elif [ "$read_status" = "CHIMERIC" ]; then
                    cat "$tmp_dir/result_${i}.line" >> "$odir/chimeric_rightclip.sam"
                else
                    echo "    WARNING: Missing result for read $i"
                fi
            done

            # Convert corrected SAM to sorted BAM
            samtools view -bS "$odir/corrected.sam" > "$odir/corrected.bam"
            samtools sort "$odir/corrected.bam" > "$odir/corrected.sort.bam"
            samtools index "$odir/corrected.sort.bam"

            # Convert chimeric SAM to sorted BAM (for IGV viewer)
            if [ -s "$odir/chimeric_rightclip.sam" ] && grep -qv '^@' "$odir/chimeric_rightclip.sam"; then
                samtools view -bS "$odir/chimeric_rightclip.sam" \
                    | samtools sort -o "$odir/chimeric_rightclip.sort.bam"
                samtools index "$odir/chimeric_rightclip.sort.bam"
            fi

            # Preserve BLAST results before cleanup
            if [ -s "$tmp_dir/blast_batch.fa" ]; then
                cp "$tmp_dir/blast_batch.fa" "$odir/blast_rightclip_queries.fa"
            fi
            if [ -s "$tmp_dir/batch_blast_chrm_raw.txt" ]; then
                cp "$tmp_dir/batch_blast_chrm_raw.txt" "$odir/blast_chrm_results.txt"
            fi
            if [ -s "$tmp_dir/batch_blast_cdna.txt" ]; then
                cp "$tmp_dir/batch_blast_cdna.txt" "$odir/blast_cdna_results.txt"
            fi

            # Clean up temp directory and reset trap
            rm -rf "$tmp_dir"
            trap - INT TERM

            local end_time
            end_time=$(date +%s)
            echo "    Done in $((end_time - start_time))s"

        done
    done

    set -e  # Restore errexit so subsequent pipeline steps are protected
    echo "[Step 09v2] Done. Output in $output_dir/09_correct/"
}
