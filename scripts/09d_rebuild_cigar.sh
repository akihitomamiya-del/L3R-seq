#!/bin/bash
# 09d_rebuild_cigar.sh -- Reconstruct CIGAR after correction
# Sourced by 09_tail_correct.sh. Defines run_rebuild_cigar().
# (Same logic as v1 — already lightweight string manipulation)
# Input:  original CIGAR, match_counter
# Output: RESULT_New_CIGAR, RESULT_CIGAR_Tail_new_S

run_rebuild_cigar() {
    local aln_cigar="$1"
    local match_counter="$2"

    local cigar_tail_org
    cigar_tail_org=$(echo "$aln_cigar" | grep -Eo '[0-9]+M[0-9]+S$')

    local cigar_tail_org_m
    cigar_tail_org_m=$(echo "$cigar_tail_org" | grep -Eo '[0-9]+M' | grep -Eo '[0-9]+' | awk '{a+=$1} END{print a+0;}')

    local cigar_tail_org_s
    cigar_tail_org_s=$(echo "$cigar_tail_org" | grep -Eo '[0-9]+S$' | grep -Eo '[0-9]+' | awk '{a+=$1} END{print a+0;}')

    local cigar_tail_new_m
    cigar_tail_new_m=$((cigar_tail_org_m + match_counter))

    RESULT_CIGAR_Tail_new_S=$((cigar_tail_org_s - match_counter))

    local cigar_body
    cigar_body=$(echo "$aln_cigar" | sed "s/${cigar_tail_org}$//")

    if [ "$RESULT_CIGAR_Tail_new_S" -eq 0 ]; then
        RESULT_New_CIGAR="${cigar_body}${cigar_tail_new_m}M"
    else
        RESULT_New_CIGAR="${cigar_body}${cigar_tail_new_m}M${RESULT_CIGAR_Tail_new_S}S"
    fi
}
