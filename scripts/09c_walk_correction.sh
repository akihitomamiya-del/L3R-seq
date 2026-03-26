#!/bin/bash
# 09c_walk_correction.sh -- Base-by-base right-clip correction (optimized)
# Sourced by 09_tail_correct.sh. Defines run_walk_correction().
# Optimization: uses pre-loaded reference string + bash substring instead of
#   awk reading the FASTA file for every single base position.
# Input:  ref_position, rightclip_seq, ref_seq (pre-loaded string), ref_var file, pattern
# Output: RESULT_Match_counter

run_walk_correction() {
    local ref_position="$1"
    local rightclip_seq="$2"
    local ref_seq="$3"          # Pre-loaded reference sequence (not file path)
    local ref_var="$4"
    local pattern="$5"
    local rightclip_n="${#rightclip_seq}"

    local ref_base_char=""
    local clip_base_char=""
    local rightclip_position=0
    RESULT_Match_counter=0
    local stopper=0

    while [ "$stopper" -eq 0 ]; do

        if [ "$rightclip_position" -eq "$rightclip_n" ]; then
            break
        fi

        # Get reference base using bash substring (replaces per-base awk call)
        ref_base_char="${ref_seq:$((ref_position-1)):1}"

        # Get right-clip base at current position
        clip_base_char="${rightclip_seq:$rightclip_position:1}"

        if [ "$ref_base_char" = "$clip_base_char" ]; then
            # Nucleotide match
            ((RESULT_Match_counter++))
            ((rightclip_position++))
            ((ref_position++))
        else
            # Nucleotide mismatch -- check if it's a known editing variant
            local mismatch="${ref_position}${ref_base_char}${clip_base_char}"

            if [ -n "$ref_var" ] && [ -f "$ref_var" ] && grep -q "$mismatch" "$ref_var"; then
                # Known editing variant -- tolerate
                ((RESULT_Match_counter++))
                ((rightclip_position++))
                ((ref_position++))
            else
                # Real mismatch -- stop correction
                ((stopper++))
            fi
        fi
    done
}
