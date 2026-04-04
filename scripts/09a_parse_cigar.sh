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

    # Single awk pass: extract right-clip (trailing S), total M, and total D
    read -r RESULT_Rightclip_N RESULT_Total_M RESULT_Total_D <<< "$(
        echo "$RESULT_Aln_CIGAR" | awk '{
            cigar = $0; rclip = 0; m = 0; d = 0
            while (match(cigar, /[0-9]+[MIDNSHP=X]/)) {
                n = substr(cigar, RSTART, RLENGTH - 1) + 0
                op = substr(cigar, RSTART + RLENGTH - 1, 1)
                rest = substr(cigar, RSTART + RLENGTH)
                if (op == "M") m += n
                else if (op == "D") d += n
                else if (op == "S" && rest == "") rclip += n
                cigar = rest
            }
            print rclip, m, d
        }'
    )"

    if [ "$RESULT_Rightclip_N" -gt 0 ]; then
        local seq="${fields[9]}"
        RESULT_Rightclip_seq="${seq: -$RESULT_Rightclip_N}"
    else
        RESULT_Rightclip_seq=""
    fi
}
