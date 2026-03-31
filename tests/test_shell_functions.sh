#!/bin/bash
# test_shell_functions.sh — Isolated unit tests for shell functions.
# Tests individual functions from 09d_rebuild_cigar.sh, 09b_blast_rightclip.sh,
# and 09f_splice_check.sh without running the full pipeline.
#
# Usage: bash tests/test_shell_functions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

check_exact() {
    local label="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$label: $got"
    else
        fail "$label: got '$got', expected '$expected'"
    fi
}

# ============================================================================
# Source the scripts under test
# ============================================================================

source "$PIPELINE_DIR/scripts/09d_rebuild_cigar.sh"
source "$PIPELINE_DIR/scripts/09f_splice_check.sh"
source "$PIPELINE_DIR/scripts/09b_blast_rightclip.sh"

echo "========================================"
echo "Shell Function Unit Tests"
echo "========================================"
echo ""

# ============================================================================
# Test: run_rebuild_cigar()
# ============================================================================

echo "[CIGAR rebuild] run_rebuild_cigar()"
echo ""

# Normal tail update: 500M55S + 12 matches → 512M43S
run_rebuild_cigar "500M55S" 12
check_exact "Normal tail" "$RESULT_New_CIGAR" "512M43S"
check_exact "Normal tail S" "$RESULT_CIGAR_Tail_new_S" "43"

# Multi-op CIGAR with tail: 10M20D5M10S + 3 → 10M20D8M7S
run_rebuild_cigar "10M20D5M10S" 3
check_exact "Multi-op body" "$RESULT_New_CIGAR" "10M20D8M7S"
check_exact "Multi-op S" "$RESULT_CIGAR_Tail_new_S" "7"

# S goes to exactly zero: 15M10S + 10 → 25M (no S suffix)
run_rebuild_cigar "15M10S" 10
check_exact "S becomes 0" "$RESULT_New_CIGAR" "25M"
check_exact "S zero value" "$RESULT_CIGAR_Tail_new_S" "0"

# S would go negative: 5M3S + 5 → clamp to 0, 10M
run_rebuild_cigar "5M3S" 5
check_exact "S clamped from negative" "$RESULT_New_CIGAR" "10M"
check_exact "S clamped value" "$RESULT_CIGAR_Tail_new_S" "0"

# Zero match_counter: 5M8S + 0 → unchanged
run_rebuild_cigar "5M8S" 0
check_exact "Zero counter" "$RESULT_New_CIGAR" "5M8S"
check_exact "Zero counter S" "$RESULT_CIGAR_Tail_new_S" "8"

# Complex body: 10M1I20D300M120S + 60 → 10M1I20D360M60S
run_rebuild_cigar "10M1I20D300M120S" 60
check_exact "Complex body" "$RESULT_New_CIGAR" "10M1I20D360M60S"
check_exact "Complex body S" "$RESULT_CIGAR_Tail_new_S" "60"

# Full correction (all S absorbed): 450M60S + 60 → 510M
run_rebuild_cigar "450M60S" 60
check_exact "Full correction" "$RESULT_New_CIGAR" "510M"
check_exact "Full correction S" "$RESULT_CIGAR_Tail_new_S" "0"

echo ""

# ============================================================================
# Test: parse_introns()
# ============================================================================

echo "[Splice] parse_introns()"
echo ""

# Shorthand: single intron
parse_introns "300-500"
check_exact "Shorthand single N_INTRONS" "$N_INTRONS" "1"
check_exact "Shorthand single start" "${INTRON_STARTS[0]}" "300"
check_exact "Shorthand single end" "${INTRON_ENDS[0]}" "500"

# Shorthand: multiple introns
parse_introns "100-200,500-800"
check_exact "Shorthand multi N_INTRONS" "$N_INTRONS" "2"
check_exact "Shorthand multi start[0]" "${INTRON_STARTS[0]}" "100"
check_exact "Shorthand multi end[0]" "${INTRON_ENDS[0]}" "200"
check_exact "Shorthand multi start[1]" "${INTRON_STARTS[1]}" "500"
check_exact "Shorthand multi end[1]" "${INTRON_ENDS[1]}" "800"

# Empty spec
parse_introns ""
check_exact "Empty spec N_INTRONS" "$N_INTRONS" "0"

# BED file
TMP_BED=$(mktemp)
cat > "$TMP_BED" <<'BED'
#comment
test_gene	300	500	intron1
test_gene	800	1000	intron2
BED
parse_introns "$TMP_BED"
check_exact "BED N_INTRONS" "$N_INTRONS" "2"
check_exact "BED start[0]" "${INTRON_STARTS[0]}" "300"
check_exact "BED end[0]" "${INTRON_ENDS[0]}" "500"
check_exact "BED start[1]" "${INTRON_STARTS[1]}" "800"
check_exact "BED end[1]" "${INTRON_ENDS[1]}" "1000"
rm -f "$TMP_BED"

echo ""

# ============================================================================
# Test: check_splice()
# ============================================================================

echo "[Splice] check_splice()"
echo ""

# Setup: single intron at 300-500 (0-based)
INTRON_STARTS=(300)
INTRON_ENDS=(500)
N_INTRONS=1

# Spliced read: 200bp deletion matching intron (within tolerance)
check_splice "100M200D100M" 210
check_exact "Spliced read SJ" "$RESULT_SJ" "S"
check_exact "Spliced read SI" "$RESULT_SI" "1"
check_exact "Spliced read IR" "$RESULT_IR" "0"

# Retained read: spans intron but no large deletion
check_splice "500M" 100
check_exact "Retained read SJ" "$RESULT_SJ" "R"
check_exact "Retained read SI" "$RESULT_SI" "0"
check_exact "Retained read IR" "$RESULT_IR" "1"

# Read doesn't span intron (too short, ends before intron)
check_splice "50M" 100
check_exact "Short read SJ" "$RESULT_SJ" "-"
check_exact "Short read SI" "$RESULT_SI" "0"
check_exact "Short read IR" "$RESULT_IR" "0"

# N operator (splice junction in SAM) treated same as D
check_splice "100M200N100M" 210
check_exact "N operator SJ" "$RESULT_SJ" "S"
check_exact "N operator SI" "$RESULT_SI" "1"

# Small deletion (< 50bp, below threshold): read spans intron but deletion too small
check_splice "200M40D300M" 100
check_exact "Small deletion SJ" "$RESULT_SJ" "R"
check_exact "Small deletion IR" "$RESULT_IR" "1"

# Two introns, mixed results
INTRON_STARTS=(300 800)
INTRON_ENDS=(500 1000)
N_INTRONS=2

# Read spans both, deletion matches first only
check_splice "100M200D800M" 210
check_exact "Two introns SJ" "$RESULT_SJ" "SR"
check_exact "Two introns SI" "$RESULT_SI" "1"
check_exact "Two introns IR" "$RESULT_IR" "1"

# No introns configured
INTRON_STARTS=()
INTRON_ENDS=()
N_INTRONS=0
check_splice "500M" 100
check_exact "No introns SJ" "$RESULT_SJ" ""
check_exact "No introns SI" "$RESULT_SI" "0"

echo ""

# ============================================================================
# Test: convert_intron_d_to_n()
# ============================================================================

echo "[Splice] convert_intron_d_to_n()"
echo ""

# Setup: single intron at 300-500
INTRON_STARTS=(300)
INTRON_ENDS=(500)
N_INTRONS=1

# D matching intron → converted to N
convert_intron_d_to_n "100M200D100M" 210
check_exact "D to N conversion" "$RESULT_CIGAR_SPLICED" "100M200N100M"

# Small D (< 50bp) → stays as D
convert_intron_d_to_n "100M30D100M" 210
check_exact "Small D unchanged" "$RESULT_CIGAR_SPLICED" "100M30D100M"

# No D in CIGAR → unchanged
convert_intron_d_to_n "300M" 100
check_exact "No D unchanged" "$RESULT_CIGAR_SPLICED" "300M"

# D not matching any intron → stays as D
INTRON_STARTS=(800)
INTRON_ENDS=(1000)
N_INTRONS=1
convert_intron_d_to_n "100M200D100M" 100
check_exact "Non-matching D unchanged" "$RESULT_CIGAR_SPLICED" "100M200D100M"

echo ""

# ============================================================================
# Test: BLAST lookup functions
# ============================================================================

echo "[BLAST] collect_blast_query() + lookup functions"
echo ""

TMP_DIR=$(mktemp -d)
BATCH_FA="$TMP_DIR/batch.fa"

# Init and collect
init_blast_batch "$BATCH_FA"
if [ -f "$BATCH_FA" ] && [ ! -s "$BATCH_FA" ]; then
    pass "init_blast_batch creates empty file"
else
    fail "init_blast_batch failed"
fi

collect_blast_query "42" "ACGTACGTACGT" "$BATCH_FA"
collect_blast_query "99" "TTTTGGGG" "$BATCH_FA"
if grep -q '>Rightclip_42' "$BATCH_FA" && grep -q 'ACGTACGTACGT' "$BATCH_FA"; then
    pass "collect_blast_query writes FASTA"
else
    fail "collect_blast_query output wrong"
fi

got_seqs=$(grep -c '^>' "$BATCH_FA")
check_exact "Batch has 2 sequences" "$got_seqs" "2"

# Lookup with mock hit files
echo "Rightclip_42" > "$TMP_DIR/blast_chrm_hits.txt"
echo "Rightclip_99" > "$TMP_DIR/blast_cdna_hits.txt"

if lookup_blast_result "42" "$TMP_DIR"; then
    pass "lookup_blast_result finds ChrM hit"
else
    fail "lookup_blast_result missed ChrM hit"
fi

if ! lookup_blast_result "99" "$TMP_DIR"; then
    pass "lookup_blast_result: no ChrM hit for read 99"
else
    fail "lookup_blast_result: false ChrM hit for read 99"
fi

if lookup_cdna_result "99" "$TMP_DIR"; then
    pass "lookup_cdna_result finds cDNA hit"
else
    fail "lookup_cdna_result missed cDNA hit"
fi

if ! lookup_cdna_result "42" "$TMP_DIR"; then
    pass "lookup_cdna_result: no cDNA hit for read 42"
else
    fail "lookup_cdna_result: false cDNA hit for read 42"
fi

# Lookup against missing file
if ! lookup_blast_result "42" "/nonexistent"; then
    pass "lookup_blast_result handles missing file"
else
    fail "lookup_blast_result: false hit from missing file"
fi

rm -rf "$TMP_DIR"

echo ""

# ============================================================================
# Summary
# ============================================================================

echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
echo "All shell function tests passed."
