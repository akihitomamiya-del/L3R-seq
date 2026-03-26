#!/bin/bash
# 09a_parse_cigar.sh -- Parse CIGAR string from pre-extracted read line
# Sourced by 09_tail_correct.sh. Defines run_parse_cigar().
# Optimization: works directly on the read line string — no samtools call.
# Input:  read line (tab-separated SAM fields)
# Output: RESULT_Rightclip_N, RESULT_Aln_Start, RESULT_Total_M, RESULT_Total_D,
#         RESULT_Aln_CIGAR, RESULT_Rightclip_seq

run_parse_cigar() {
    local read_line="$1"

    # Split read line into fields (avoids samtools view call)
    local -a fields
    IFS=$'\t' read -ra fields <<< "$read_line"

    RESULT_Aln_Start="${fields[3]}"
    RESULT_Aln_CIGAR="${fields[5]}"

    RESULT_Rightclip_N=$(echo "$RESULT_Aln_CIGAR" | grep -Po '[0-9]+S$' | grep -Po '^[0-9]+' | awk '{a+=$1} END{print a+0;}')
    RESULT_Total_M=$(echo "$RESULT_Aln_CIGAR" | grep -Po '[0-9]+M' | grep -Po '[0-9]+' | awk '{a+=$1} END{print a+0;}')
    RESULT_Total_D=$(echo "$RESULT_Aln_CIGAR" | grep -Po '[0-9]+D' | grep -Po '[0-9]+' | awk '{a+=$1} END{print a+0;}')

    if [ "$RESULT_Rightclip_N" -gt 0 ]; then
        local seq="${fields[9]}"
        RESULT_Rightclip_seq="${seq: -$RESULT_Rightclip_N}"
    else
        RESULT_Rightclip_seq=""
    fi
}
