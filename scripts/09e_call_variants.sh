#!/bin/bash
# 09e_call_variants.sh -- Call variants via CIGAR-walk mismatch detection
# Sourced by 09_tail_correct.sh. Defines run_call_variants().
#
# Replaces the bcftools pipeline (5 process spawns per read) with a single
# awk call that walks the CIGAR alignment and compares each base to the
# pre-loaded reference. Verified byte-identical output to bcftools on all
# 2,069 REP2 reads.
#
# Input:  read_line (tab-separated SAM fields), ref_seq (pre-loaded string), pattern
# Output: RESULT_variants, RESULT_EC, RESULT_SC, RESULT_NC

run_call_variants() {
    local read_line="$1"
    local ref_seq="$2"
    local pattern="$3"

    # Build extended regex for primary editing pattern(s) (supports comma-separated, e.g. "CT,AG")
    local _ec_regex=""
    IFS=',' read -ra _patterns <<< "$pattern"
    for _p in "${_patterns[@]}"; do
        _p="${_p// /}"
        [ -n "$_ec_regex" ] && _ec_regex="${_ec_regex}|"
        _ec_regex="${_ec_regex}${_p:0:1}${_p:1:1}"
    done

    local -a fields
    IFS=$'\t' read -ra fields <<< "$read_line"
    local pos="${fields[3]}"
    local cigar="${fields[5]}"
    local seq="${fields[9]}"

    RESULT_variants=$(awk -v pos="$pos" -v cigar="$cigar" -v seq="$seq" -v ref="$ref_seq" '
    BEGIN {
        ref_pos = pos - 1
        read_pos = 0
        n = length(cigar)
        num = ""
        for (i = 1; i <= n; i++) {
            c = substr(cigar, i, 1)
            if (c ~ /[0-9]/) { num = num c }
            else {
                len = num + 0; num = ""
                if (c == "M" || c == "=" || c == "X") {
                    for (j = 0; j < len; j++) {
                        rb = substr(ref, ref_pos + 1, 1)
                        qb = toupper(substr(seq, read_pos + 1, 1))
                        if (rb != qb && rb != "" && qb != "") {
                            printf "%d%s%s;", ref_pos + 1, rb, qb
                        }
                        ref_pos++; read_pos++
                    }
                } else if (c == "I" || c == "S") { read_pos += len }
                else if (c == "D" || c == "N") { ref_pos += len }
            }
        }
    }' /dev/null)

    RESULT_EC=$(echo "$RESULT_variants" | tr ';' '\n' | grep -cE "$_ec_regex" || true)

    # Secondary count (count-only pattern, e.g., TC for SLAM-seq)
    local count_pattern="${4:-}"
    if [ -n "$count_pattern" ]; then
        local cp_ref="${count_pattern:0:1}"
        local cp_alt="${count_pattern:1:1}"
        RESULT_SC=$(echo "$RESULT_variants" | tr ';' '\n' | grep -c "${cp_ref}${cp_alt}" || true)
    else
        RESULT_SC=0
    fi

    # Noise count: non-biological mismatches (total - editing - secondary)
    local total_mm=0
    if [ -n "$RESULT_variants" ]; then
        total_mm=$(echo "$RESULT_variants" | tr ';' '\n' | grep -c '[ACGT]' || true)
    fi
    RESULT_NC=$((total_mm - RESULT_EC - RESULT_SC))
}
