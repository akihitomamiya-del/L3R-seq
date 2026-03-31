#!/bin/bash
# run_tests.sh — Run L3Rseq pipeline tests on synthetic data
#
# Tests the full pipeline (steps 01-10) with CT and CT,AG patterns using
# --method longread-umi, then validates SLAM, splice, BLAST, walk correction,
# and the IGV viewer API.
#
# Usage: bash tests/run_tests.sh [--skip-preprocess] [--quick] [--no-viewer]
#   Default:              tests all steps 01-10, starts IGV viewer after tests
#   With --skip-preprocess: skips steps 01-03 (faster, for core pipeline testing)
#   With --quick:           minimal smoke test for CI (~13 sec)
#                           runs Test 1c, Test 2 (1 sample only), Test 3, Test 4, Test 5
#                           implies --skip-preprocess
#   With --no-viewer:       skip IGV viewer after tests complete
#
# Timing reference (108 checks, all steps 01-10):
#
#   Codespaces 4-core (AMD EPYC 7763, 4 vCPU / 32 GB RAM):
#     Full run:  ~90s
#       Test 1+1b steps 01-03     ~7s
#       Test 1c negative tests    ~2s
#       Test 2  steps 04-10      ~67s  (dominant — UMI clustering + racon consensus)
#       Demo    viewer data        ~5s
#       Test 3  SLAM-seq           ~3s
#       Test 4  splice + discover  ~3s
#       Test 5  BLAST + walk       ~3s
#     --skip-preprocess:  ~83s
#     --quick:            ~13s
#
#   Codespaces 4-core (AMD EPYC 7763, 4 vCPU / 16 GB RAM):
#     Full run:  ~2 min 13s
#       Test 1  steps 01-03        ~9s
#       Test 1b filter             ~3s
#       Test 1c negative tests     ~3s
#       Test 2  steps 04-10       ~96s  (dominant — UMI clustering + racon consensus)
#       Demo    viewer data         ~9s
#       Test 3  SLAM-seq            ~3s
#       Test 4  splice + discover   ~4s
#       Test 5  BLAST + walk        ~6s
#     --skip-preprocess:  ~2 min
#     --quick:            ~13s
#
# Requirements: all conda environments must be available (longread_umi,
#   cutadaptenv, NanoporeMap, LoFreq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$SCRIPT_DIR/data"
EXPECTED_DIR="$SCRIPT_DIR/expected"
OUTPUT_DIR="$SCRIPT_DIR/output"
REF="$PIPELINE_DIR/resources/references/test_gene.fasta"

PASS=0
FAIL=0
WARN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

check_exact() {
    local label="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$label: $got (expected $expected)"
    else
        fail "$label: got $got, expected $expected"
    fi
}

check_range() {
    local label="$1" got="$2" expected="$3" tolerance="$4"
    local lo hi
    lo=$(echo "$expected $tolerance" | awk '{printf "%.0f", $1 * (1 - $2)}')
    hi=$(echo "$expected $tolerance" | awk '{printf "%.0f", $1 * (1 + $2)}')
    if [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; then
        pass "$label: $got (expected $expected ±${tolerance})"
    else
        fail "$label: got $got, expected $expected ±${tolerance} (range $lo-$hi)"
    fi
}

count_csv_rows() { echo $(( $(wc -l < "$1") - 1 )); }
count_fasta_seqs() { local n; n=$(grep -c '^>' "$1" 2>/dev/null) || n=0; echo "$n"; }
count_sam_reads() { local n; n=$(grep -cv '^@' "$1" 2>/dev/null) || n=0; echo "$n"; }
sum_ec_tags() { grep -v '^@' "$1" 2>/dev/null | grep -oE 'EC:i:[0-9]+' | sed 's/EC:i://' | awk '{s+=$1} END{print s+0}'; }
sum_sc_tags() { grep -v '^@' "$1" 2>/dev/null | grep -oE 'SC:i:[0-9]+' | sed 's/SC:i://' | awk '{s+=$1} END{print s+0}'; }
count_csv_cols() { head -1 "$1" | awk -F',' '{print NF}'; }

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

SKIP_PREPROCESS=0
QUICK=0
START_VIEWER=1
for arg in "$@"; do
    case "$arg" in
        --skip-preprocess) SKIP_PREPROCESS=1 ;;
        --quick)           QUICK=1 ;;
        --viewer)          START_VIEWER=1 ;;
        --no-viewer)       START_VIEWER=0 ;;
    esac
done
# --quick implies --skip-preprocess
if [ "$QUICK" -eq 1 ]; then SKIP_PREPROCESS=1; fi

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

eval "$(conda shell.bash hook)"

if [ ! -f "$REF" ]; then
    echo "ERROR: Reference not found at $REF"
    exit 1
fi

# Pre-flight: verify racon can actually polish (not just print --version).
# The bioconda arm64 binary crashes with SIGILL on Apple Silicon Docker Desktop
# when spoa's SIMD code runs.  Catch this early with a clear message.
conda activate longread_umi 2>/dev/null
_racon_ok=0
echo ">t" > /tmp/_racon_test.fa; echo "ACGTACGT" >> /tmp/_racon_test.fa
printf "@r\nACGTACGT\n+\nIIIIIIII\n" > /tmp/_racon_test.fq
printf "r\t0\tt\t1\t255\t8M\t*\t0\t0\tACGTACGT\tIIIIIIII\n" > /tmp/_racon_test.sam
if racon /tmp/_racon_test.fq /tmp/_racon_test.sam /tmp/_racon_test.fa > /dev/null 2>&1; then
    _racon_ok=1
fi
rm -f /tmp/_racon_test.fa /tmp/_racon_test.fq /tmp/_racon_test.sam
conda deactivate 2>/dev/null
if [ "$_racon_ok" -eq 0 ]; then
    echo "ERROR: racon crashes during polishing (likely SIGILL on arm64)."
    echo "  The container image needs rebuilding — see Dockerfile comments."
    echo "  Quick fix: rebuild racon from source inside the container:"
    echo "    sudo bash -c 'cd /tmp && curl -fsSL https://github.com/lbcb-sci/racon/archive/refs/tags/1.5.0.tar.gz | tar xz && cd racon-1.5.0 && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=\"-march=armv8-a\" -Dspoa_optimize_for_native=OFF .. && make -j\$(nproc) && cp bin/racon /opt/miniforge/envs/longread_umi/bin/racon'"
    exit 1
fi

echo "========================================"
echo "L3Rseq Pipeline Tests"
echo "========================================"
echo ""

# System specs
if [ "$(uname -s)" = "Darwin" ]; then
    echo "CPU:  $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
    echo "CPUs: $(sysctl -n hw.logicalcpu 2>/dev/null || echo '?')"
    _mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo "RAM:  $(( _mem_bytes / 1073741824 ))G"
else
    echo "CPU:  $(lscpu 2>/dev/null | grep 'Model name' | sed 's/.*: *//' || echo 'unknown')"
    echo "CPUs: $(nproc 2>/dev/null || echo '?')"
    echo "RAM:  $(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo '?')"
fi
echo "Disk: $(df -h / | awk 'NR==2{print $2 " total, " $4 " avail"}')"
echo ""

SUITE_START=$SECONDS

# Clean previous output
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Test 1: Steps 01-03 (optional, with --full)
# ---------------------------------------------------------------------------

if [ "$SKIP_PREPROCESS" -eq 0 ]; then
    T_START=$SECONDS
    echo "[TEST 1] Steps 01-03: concat, trim, demux"
    echo ""

    "$PIPELINE_DIR/L3Rseq" run \
        --input "$DATA_DIR/raw_fastq" \
        --outdir "$OUTPUT_DIR/full_preprocess" \
        --ref "$REF" \
        --rpi-fasta "$PIPELINE_DIR/resources/rpi_barcodes/RPI_Barcode_20nt.fasta" \
        --method longread-umi \
        --pattern CT \
        --keep-intermediates \
        --start-at 1 --stop-at 3 \
        --threads 4 > "$OUTPUT_DIR/test1.log" 2>&1

    # Check concat: 3440 reads per barcode (2 RPIs × 1720)
    for bc in barcode01 barcode02; do
        got=$(gzip -dc "$OUTPUT_DIR/full_preprocess/01_concat/${bc}.fastq.gz" | awk 'NR%4==1' | wc -l)
        check_exact "Step 01 concat $bc" "$got" "3440"
    done

    # Check trim: trim3 should have fewer reads than concat (chimeric reads removed)
    for bc in barcode01 barcode02; do
        trim3="$OUTPUT_DIR/full_preprocess/02_trim/$bc/${bc}_trim3.fastq.gz"
        if [ -f "$trim3" ]; then
            got=$(gzip -dc "$trim3" | awk 'NR%4==1' | wc -l)
            # Expect ~3330 after trimming (3440 - chimeric/no-adapter reads)
            check_range "Step 02 trim $bc" "$got" "3330" "0.10"
        else
            fail "Step 02 trim3 missing for $bc"
        fi
    done

    # Check demux: reads assigned to RPI_1 and RPI_2
    for bc in barcode01 barcode02; do
        for rpi in RPI_1 RPI_2; do
            got=$(( $(wc -l < "$OUTPUT_DIR/full_preprocess/03_demux/$bc/${bc}_${rpi}.fastq") / 4 ))
            # Expect ~1530 after trimming+demux (errors in adapters reduce yield)
            check_range "Step 03 demux $bc/$rpi" "$got" "1530" "0.10"
        done
    done
    # Test filter step: run on demux output, check reads retained
    echo "[TEST 1b] Optional filter step"
    echo ""

    "$PIPELINE_DIR/L3Rseq" filter \
        --input "$OUTPUT_DIR/full_preprocess/03_demux" \
        --outdir "$OUTPUT_DIR/full_preprocess" \
        --ref "$REF" > "$OUTPUT_DIR/test1b.log" 2>&1

    # Filter should retain most reads but remove non-mapping ones.
    # Each RPI has 20 non-mapping reads with valid adapters — filter should remove these.
    for bc in barcode01 barcode02; do
        if [ -d "$OUTPUT_DIR/full_preprocess/filter/$bc" ]; then
            for rpi_label in RPI_1 RPI_2; do
                rpi_fq="$OUTPUT_DIR/full_preprocess/filter/$bc/${bc}_${rpi_label}.fastq"
                [ -f "$rpi_fq" ] || { fail "Filter output missing for $bc/$rpi_label"; continue; }
                filtered=$(( $(wc -l < "$rpi_fq") / 4 ))
                demuxed=$(( $(wc -l < "$OUTPUT_DIR/full_preprocess/03_demux/$bc/${bc}_${rpi_label}.fastq") / 4 ))
                removed=$(( demuxed - filtered ))
                if [ "$filtered" -gt 0 ] && [ "$filtered" -lt "$demuxed" ]; then
                    pass "Filter $bc/$rpi_label: $filtered/$demuxed retained ($removed removed)"
                elif [ "$filtered" -eq "$demuxed" ]; then
                    warn "Filter $bc/$rpi_label: no reads filtered (expected some non-mapping removal)"
                else
                    fail "Filter $bc/$rpi_label: $filtered/$demuxed (unexpected)"
                fi
            done
        else
            fail "Filter output missing for $bc"
        fi
    done
    echo "  ⏱ Test 1+1b: $(( SECONDS - T_START ))s"
    echo ""
fi

# ---------------------------------------------------------------------------
# Test 1c: Negative tests (error handling)
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "[TEST 1c] Negative tests (error handling)"
echo ""

# Missing --ref should fail at step 07
if "$PIPELINE_DIR/L3Rseq" run \
    --input "$DATA_DIR/demux" \
    --outdir "$OUTPUT_DIR/neg_test" \
    --method longread-umi --pattern CT \
    --start-at 7 --stop-at 7 \
    --threads 4 > /dev/null 2>&1; then
    fail "Missing --ref should error"
else
    pass "Missing --ref errors correctly"
fi

# Non-existent --ref file should fail
if "$PIPELINE_DIR/L3Rseq" run \
    --input "$DATA_DIR/demux" \
    --outdir "$OUTPUT_DIR/neg_test" \
    --ref "/nonexistent/ref.fa" \
    --method longread-umi --pattern CT \
    --start-at 7 --stop-at 7 \
    --threads 4 > /dev/null 2>&1; then
    fail "Non-existent --ref should error"
else
    pass "Non-existent --ref errors correctly"
fi

# Non-existent --rpi-fasta should fail
if "$PIPELINE_DIR/L3Rseq" run \
    --input "$DATA_DIR/demux" \
    --outdir "$OUTPUT_DIR/neg_test" \
    --ref "$REF" \
    --rpi-fasta "/nonexistent/rpi.fasta" \
    --method longread-umi --pattern CT \
    --start-at 3 --stop-at 3 \
    --threads 4 > /dev/null 2>&1; then
    fail "Non-existent --rpi-fasta should error"
else
    pass "Non-existent --rpi-fasta errors correctly"
fi

# UMIC-seq without --probe should fail
if "$PIPELINE_DIR/L3Rseq" run \
    --input "$DATA_DIR/demux" \
    --outdir "$OUTPUT_DIR/neg_test" \
    --method umic-seq \
    --start-at 4 --stop-at 4 \
    --threads 4 > /dev/null 2>&1; then
    fail "UMIC-seq without --probe should error"
else
    pass "UMIC-seq without --probe errors correctly"
fi
echo "  ⏱ Test 1c: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 2: Steps 04-10 with CT pattern
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "[TEST 2] Steps 04-10: longread-umi, CT pattern"
echo "  ⏳ Running pipeline (this is the longest test) ..."

mkdir -p "$OUTPUT_DIR/pipeline_CT"

"$PIPELINE_DIR/L3Rseq" run \
    --input "$DATA_DIR/demux" \
    --outdir "$OUTPUT_DIR/pipeline_CT" \
    --ref "$REF" \
    --method longread-umi \
    --pattern CT \
    --keep-intermediates \
    --start-at 4 --stop-at 10 \
    --threads 4 2>&1 | tee "$OUTPUT_DIR/test2.log" | \
    awk '/\[Step [0-9]/ && !/Done\./ { printf "  %s\n", $0; fflush() }'
echo ""

OUT="$OUTPUT_DIR/pipeline_CT"

if [ "$QUICK" -eq 1 ]; then
    TEST2_BARCODES="barcode01"
    TEST2_RPIS="barcode01_RPI_1"
else
    TEST2_BARCODES="barcode01 barcode02"
fi

for bc in $TEST2_BARCODES; do
    if [ "$QUICK" -eq 1 ]; then
        rpi_list="$TEST2_RPIS"
    else
        rpi_list="${bc}_RPI_1 ${bc}_RPI_2"
    fi
    for rpi in $rpi_list; do
        echo "  --- $bc/$rpi ---"

        # Expected final reads from CSV (steps 07-10 should match this)
        expected_final=$(count_csv_rows "$EXPECTED_DIR/csv_CT/${bc}_${rpi}.csv")

        # Step 04: bin count (≥ final reads — some get dropped in extraction)
        got_bins=$(find "$OUT/04_umi/$bc/$rpi/read_binning/bins" -name '*bins.fastq' 2>/dev/null | wc -l)
        if [ "$got_bins" -ge "$expected_final" ]; then
            pass "Step 04 bins: $got_bins (>= $expected_final final reads)"
        else
            fail "Step 04 bins: $got_bins (expected >= $expected_final)"
        fi

        # Step 05: consensus count (same as bins)
        got_cons=$(count_fasta_seqs "$OUT/05_consensus/$bc/$rpi/consensus_${rpi}.fa")
        check_exact "Step 05 consensus seqs" "$got_cons" "$got_bins"

        # Step 06: extracted sequence count (≥ final reads)
        got_extracted=$(count_fasta_seqs "$OUT/06_extract/$bc/$rpi/extracted_trimmed.fa")
        check_exact "Step 06 extracted seqs" "$got_extracted" "$expected_final"

        # Step 07: mapped reads (exact match with final)
        got_mapped=$(count_sam_reads "$OUT/07_map/$bc/$rpi/mapped_only.sam")
        check_exact "Step 07 mapped reads" "$got_mapped" "$expected_final"

        # Step 09: EC total (tolerant)
        got_ec=$(sum_ec_tags "$OUT/09_correct/$bc/$rpi/corrected.sam")
        ec_col=$(head -1 "$EXPECTED_DIR/csv_CT/${bc}_${rpi}.csv" | tr ',' '\n' | grep -n 'editing_count' | cut -d: -f1)
        expected_ec=0
        if [ -n "$ec_col" ]; then
            expected_ec=$(tail -n +2 "$EXPECTED_DIR/csv_CT/${bc}_${rpi}.csv" | awk -F',' -v c="$ec_col" '{v=$c; gsub(/[^0-9]/,"",v); s+=v+0} END{print s+0}')
        fi
        if [ "$expected_ec" -gt 10 ]; then
            check_range "Step 09 EC total" "$got_ec" "$expected_ec" "0.10"
        else
            check_range "Step 09 EC total" "$got_ec" "$expected_ec" "2.0"
        fi

        # Step 09: NC tag present on all reads
        nc_count=$(grep -v '^@' "$OUT/09_correct/$bc/$rpi/corrected.sam" 2>/dev/null | grep -c 'NC:i:' || true)
        check_exact "Step 09 NC tag present" "$nc_count" "$got_mapped"

        # Step 09: no SC tag when --count-pattern not used
        sc_count=$(grep -v '^@' "$OUT/09_correct/$bc/$rpi/corrected.sam" 2>/dev/null | grep -c 'SC:i:' || true)
        check_exact "Step 09 no SC tag (no count-pattern)" "$sc_count" "0"

        # Step 10: CSV row count (exact match)
        got_rows=$(count_csv_rows "$OUT/10_csv/${bc}_${rpi}.csv")
        check_exact "Step 10 CSV rows" "$got_rows" "$expected_final"

        # Step 10: CSV has 20 columns (with noise_count, no secondary_editing_count)
        got_cols=$(count_csv_cols "$OUT/10_csv/${bc}_${rpi}.csv")
        check_exact "Step 10 CSV columns" "$got_cols" "20"

        # Step 10: quality report generated
        if [ -f "$OUT/10_csv/${bc}_${rpi}_quality_report.txt" ]; then
            pass "Step 10 quality report exists"
        else
            fail "Step 10 quality report missing"
        fi

        # Step 08: observed variants file exists
        if [ -f "$OUT/08_variants/$bc/$rpi/observed_variants.txt" ]; then
            pass "Step 08 variants file exists"
        else
            fail "Step 08 variants file missing"
        fi

        # Step 05: consensus sequence identity.
        # Pipeline is deterministic on a given container (racon -t1, deterministic
        # seed selection).  However, racon links the system libm, so switching
        # containers (different glibc) can change consensus.  Use --regen to
        # update expected files for a new container.
        exp_fa="$EXPECTED_DIR/consensus_CT/${bc}.${rpi}.fa"
        got_fa="$OUT/05_consensus/$bc/$rpi/consensus_${rpi}.fa"
        if [ -f "$exp_fa" ] && [ -f "$got_fa" ]; then
            exp_seqs=$(count_fasta_seqs "$exp_fa")
            got_seqs=$(count_fasta_seqs "$got_fa")
            if [ "$exp_seqs" = "$got_seqs" ]; then
                match_pct=$(python3 -c "
rc_tab = str.maketrans('ACGTacgt', 'TGCAtgca')
def parse_fa(path):
    seqs = []
    for line in open(path):
        line = line.strip()
        if line.startswith('>'):
            seqs.append('')
        else:
            seqs[-1] += line
    return seqs
def ident(a, b):
    n = min(len(a), len(b))
    return sum(x == y for x, y in zip(a[:n], b[:n])) / n if n else 0
exp_seqs = parse_fa('$exp_fa')
got_seqs = parse_fa('$got_fa')
total_pct = 0
for es in exp_seqs:
    es_rc = es.translate(rc_tab)[::-1]
    best = max(max(ident(es, gs), ident(es_rc, gs)) for gs in got_seqs)
    total_pct += best
print(f'{total_pct / len(exp_seqs) * 100:.1f}')
")
                threshold_ok=$(python3 -c "print(1 if float('$match_pct') >= 99.0 else 0)")
                if [ "$threshold_ok" = "1" ]; then
                    pass "Step 05 sequence identity: ${match_pct}%"
                else
                    fail "Step 05 sequence identity: ${match_pct}% (expected >=99%)"
                fi
            else
                warn "Step 05 sequence count mismatch (exp=$exp_seqs got=$got_seqs), skipping identity check"
            fi
        fi
    done
done

# pipeline_summary.tsv should exist and have rows for all steps
if [ -f "$OUT/pipeline_summary.tsv" ]; then
    pass "pipeline_summary.tsv exists"
    tsv_rows=$(tail -n +2 "$OUT/pipeline_summary.tsv" | wc -l)
    if [ "$tsv_rows" -ge 20 ]; then
        pass "pipeline_summary.tsv has $tsv_rows data rows"
    else
        fail "pipeline_summary.tsv has only $tsv_rows rows (expected >=20)"
    fi
else
    fail "pipeline_summary.tsv missing"
fi
echo "  ⏱ Test 2: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 2b: Steps 08-10 with CT,AG dual pattern (reuses 04-07 from Test 2)
# ---------------------------------------------------------------------------

if [ "$QUICK" -eq 0 ]; then
    T_START=$SECONDS
    echo "[TEST 2b] Steps 08-10: CT,AG dual pattern"
    echo "  ⏳ Running steps 08-10 with --pattern CT,AG ..."

    OUT_CTAG="$OUTPUT_DIR/pipeline_CTAG"
    mkdir -p "$OUT_CTAG"

    # Symlink pattern-independent steps from pipeline_CT
    ln -sfn "$(cd "$OUT" && pwd)/04_umi" "$OUT_CTAG/04_umi"
    ln -sfn "$(cd "$OUT" && pwd)/05_consensus" "$OUT_CTAG/05_consensus"
    ln -sfn "$(cd "$OUT" && pwd)/06_extract" "$OUT_CTAG/06_extract"
    ln -sfn "$(cd "$OUT" && pwd)/07_map" "$OUT_CTAG/07_map"

    "$PIPELINE_DIR/L3Rseq" run \
        --input "$DATA_DIR/demux" \
        --outdir "$OUT_CTAG" \
        --ref "$REF" \
        --method longread-umi \
        --pattern CT,AG \
        --keep-intermediates \
        --start-at 8 --stop-at 10 \
        --threads 4 2>&1 | tee "$OUTPUT_DIR/test2b.log" | \
        awk '/\[Step [0-9]/ && !/Done\./ { printf "  %s\n", $0; fflush() }'
    echo ""

    for bc in barcode01 barcode02; do
        for rpi in ${bc}_RPI_1 ${bc}_RPI_2; do
            echo "  --- $bc/$rpi (CT,AG) ---"
            expected_final_ctag=$(count_csv_rows "$EXPECTED_DIR/csv_CTAG/${bc}_${rpi}.csv")

            # EC total under dual pattern
            got_ec_ctag=$(sum_ec_tags "$OUT_CTAG/09_correct/$bc/$rpi/corrected.sam")
            ec_col_ctag=$(head -1 "$EXPECTED_DIR/csv_CTAG/${bc}_${rpi}.csv" | tr ',' '\n' | grep -n 'editing_count' | cut -d: -f1)
            expected_ec_ctag=0
            if [ -n "$ec_col_ctag" ]; then
                expected_ec_ctag=$(tail -n +2 "$EXPECTED_DIR/csv_CTAG/${bc}_${rpi}.csv" | awk -F',' -v c="$ec_col_ctag" '{v=$c; gsub(/[^0-9]/,"",v); s+=v+0} END{print s+0}')
            fi
            if [ "$expected_ec_ctag" -gt 10 ]; then
                check_range "CT,AG EC total ($rpi)" "$got_ec_ctag" "$expected_ec_ctag" "0.10"
            else
                check_range "CT,AG EC total ($rpi)" "$got_ec_ctag" "$expected_ec_ctag" "2.0"
            fi

            # CSV row count
            got_rows_ctag=$(count_csv_rows "$OUT_CTAG/10_csv/${bc}_${rpi}.csv")
            check_exact "CT,AG CSV rows ($rpi)" "$got_rows_ctag" "$expected_final_ctag"
        done
    done
    echo "  ⏱ Test 2b: $(( SECONDS - T_START ))s"
    echo ""
fi

# ---------------------------------------------------------------------------
# Demo viewer: separate dataset with 3 tracks (raw bin, consensus, corrected).
# Uses pipeline intermediates for raw bin + consensus, then generates a mixed
# track of walk-corrected + long edited reads showing C→T at position 606.
# ---------------------------------------------------------------------------

T_START=$SECONDS
DEMO_DIR="$OUTPUT_DIR/demo"
mkdir -p "$DEMO_DIR"
cat > "$DEMO_DIR/description.txt" <<'EOF'
Walk correction demo — Top two tracks: raw UMI-bin reads and their racon consensus for a single bin. Bottom two tracks: bulk walk correction on 120 synthetic reads with C→T editing at positions 580, 606–607. Compare step 07 (mapping) vs step 09 (corrected) — look for soft-clips (colored tails) shrinking after correction as the walk algorithm extends alignments through the editing sites into the poly-A tail.
EOF

DEMO_BC="barcode01"
DEMO_RPI="barcode01_RPI_1"
DEMO_BIN_DIR="$OUT/04_umi/$DEMO_BC/$DEMO_RPI/UMIclusterfull/0"
DEMO_CONS_FA="$OUT/05_consensus/$DEMO_BC/$DEMO_RPI/consensus_${DEMO_RPI}.fa"

# Find the largest bin FASTQ (most reads for clear visualization)
LARGEST_BIN=""
MAX_READS=0
if [ -d "$DEMO_BIN_DIR" ]; then
    for fq in "$DEMO_BIN_DIR"/*.fastq; do
        [ -f "$fq" ] || continue
        nreads=$(awk 'NR%4==1' "$fq" | wc -l)
        if [ "$nreads" -gt "$MAX_READS" ]; then
            MAX_READS=$nreads
            LARGEST_BIN="$fq"
        fi
    done
fi

if [ -n "$LARGEST_BIN" ] && [ "$MAX_READS" -gt 0 ]; then
    conda activate NanoporeMap 2>/dev/null

    BIN_NAME=$(basename "$LARGEST_BIN" .fastq)
    RAW_DIR="$DEMO_DIR/01_raw_bin/$DEMO_BC/$DEMO_RPI"
    CONS_OUT_DIR="$DEMO_DIR/02_consensus/$DEMO_BC/$DEMO_RPI"
    mkdir -p "$RAW_DIR" "$CONS_OUT_DIR"

    # Map raw bin reads to reference (full adapter structure → soft-clips in IGV)
    minimap2 -a "$REF" "$LARGEST_BIN" 2>/dev/null | \
        samtools sort > "$RAW_DIR/raw_reads.sort.bam" 2>/dev/null
    samtools index "$RAW_DIR/raw_reads.sort.bam" 2>/dev/null

    # Extract and map ONLY the consensus for the selected bin
    if [ -f "$DEMO_CONS_FA" ]; then
        BIN_HEADER=$(grep "^>${BIN_NAME};" "$DEMO_CONS_FA" | head -1 | sed 's/^>//')
        if [ -n "$BIN_HEADER" ]; then
            SINGLE_FA="$CONS_OUT_DIR/single_bin.fa"
            awk -v hdr="$BIN_HEADER" '
                /^>/ { found = ($0 == ">" hdr) }
                found { print }
            ' "$DEMO_CONS_FA" > "$SINGLE_FA"
            minimap2 -a "$REF" "$SINGLE_FA" 2>/dev/null | \
                samtools sort > "$CONS_OUT_DIR/consensus.sort.bam" 2>/dev/null
            samtools index "$CONS_OUT_DIR/consensus.sort.bam" 2>/dev/null
        fi
    fi

    # Generate walk correction demo input (07_map SAM + variant file)
    python3 "$SCRIPT_DIR/generators/generate_demo_data.py" "$DEMO_DIR"

    # Run the actual walk correction program (step 09) on the demo data
    "$PIPELINE_DIR/L3Rseq" run \
        --input "$DEMO_DIR" \
        --outdir "$DEMO_DIR" \
        --ref "$REF" \
        --pattern CT \
        --start-at 9 --stop-at 9 \
        --threads 4 > "$OUTPUT_DIR/demo.log" 2>&1

    RAW_COUNT=$(samtools view -c "$RAW_DIR/raw_reads.sort.bam" 2>/dev/null)
    CONS_COUNT=$(samtools view -c "$CONS_OUT_DIR/consensus.sort.bam" 2>/dev/null)
    WALK_MAP=$(samtools view -c "$DEMO_DIR/07_map/demo/demo_demo_RPI_1/aligned.sort.bam" 2>/dev/null)
    WALK_COR=$(samtools view -c "$DEMO_DIR/09_correct/demo/demo_demo_RPI_1/corrected.sort.bam" 2>/dev/null)
    echo "  Demo viewer: raw_bin=$RAW_COUNT reads ($BIN_NAME), consensus=$CONS_COUNT seq, walk=$WALK_MAP→$WALK_COR reads"

    conda deactivate 2>/dev/null
fi
echo "  ⏱ Demo: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Pipeline viewer: corrected reads for all samples.
# Creates a "pipeline" tab in the IGV viewer with every barcode/RPI from
# the Test 2 pipeline_CT run, showing only the step 09 corrected tracks.
# ---------------------------------------------------------------------------

PIPE_DIR="$OUTPUT_DIR/pipeline"
mkdir -p "$PIPE_DIR"
cat > "$PIPE_DIR/description.txt" <<'EOF'
CT-pattern pipeline — tail-corrected reads (step 09) for all samples. barcode01/RPI_1 has C→T editing (high EC); barcode01/RPI_2 has A→G (not counted, appears as noise); barcode02/RPI_1 has CT+AG (only CT counted); barcode02/RPI_2 has T→C editing (not counted, appears as noise). Try "Group by EC" to see the difference.

Command: L3Rseq run --pattern CT --method longread-umi --start-at 4 --stop-at 10
EOF
ln -sfn "$OUT/09_correct" "$PIPE_DIR/09_correct"
echo "  Pipeline CT viewer: linked corrected BAMs for all samples"

# CT+AG dual-pattern viewer tab
if [ -d "$OUTPUT_DIR/pipeline_CTAG/09_correct" ]; then
    PIPE_DUAL_DIR="$OUTPUT_DIR/pipeline_dual"
    mkdir -p "$PIPE_DUAL_DIR"
    cat > "$PIPE_DUAL_DIR/description.txt" <<'EOF'
CT+AG dual-pattern pipeline — same reads, but both C→T and A→G count as editing (EC). Compare with CT tab: barcode01/RPI_2 (AG only) now shows high EC; barcode02/RPI_1 (CT+AG) shows combined EC from both patterns. barcode02/RPI_2 (T→C editing) is unchanged because TC is not in the pattern.

Command: L3Rseq run --pattern CT,AG --method longread-umi --start-at 8 --stop-at 10
EOF
    ln -sfn "$(cd "$OUTPUT_DIR/pipeline_CTAG" && pwd)/09_correct" "$PIPE_DUAL_DIR/09_correct"
    echo "  Pipeline CT+AG viewer: linked corrected BAMs for all samples"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 3: Synthetic SLAM-seq validation (CT + count-pattern TC)
# ---------------------------------------------------------------------------
# Validates step 09-10 on synthetic SLAM-seq data using test_gene.fasta.
# 40 reads with fixed C->T editing sites and graduated T->C SLAM labeling.
#   Pattern: CT, count-pattern: TC
# Expected: 40 reads, EC=96, SC=590, NC=101

T_START=$SECONDS
echo "[TEST 3] Synthetic SLAM-seq validation (steps 09-10)"
echo ""

SLAM_DATA="$DATA_DIR/slam_test"
SLAM_OUT="$OUTPUT_DIR/pipeline_SLAM"
mkdir -p "$SLAM_OUT"
cat > "$SLAM_OUT/description.txt" <<'EOF'
SLAM-seq validation — synthetic reads with C→T editing (EC tag) and T→C SLAM labeling (SC tag). 40 reads, EC=96, SC=590, NC=101. Try "Group by EC" or "Group by SC" to see editing vs labeling gradients.

Command: L3Rseq run --pattern CT --count-pattern TC --start-at 9 --stop-at 10
EOF

"$PIPELINE_DIR/L3Rseq" run \
    --input "$SLAM_DATA" \
    --outdir "$SLAM_OUT" \
    --ref "$REF" \
    --method longread-umi \
    --pattern CT \
    --count-pattern TC \
    --start-at 9 --stop-at 10 \
    --threads 4 > "$OUTPUT_DIR/test4b.log" 2>&1

SLAM_SAM="$SLAM_OUT/09_correct/slam/slam_RPI_5/corrected.sam"
SLAM_CSV="$SLAM_OUT/10_csv/slam_slam_RPI_5.csv"

# Read count
slam_reads=$(count_sam_reads "$SLAM_SAM")
check_exact "SLAM reads" "$slam_reads" "40"

# EC total (C->T editing at fixed sites)
slam_ec=$(sum_ec_tags "$SLAM_SAM")
check_exact "SLAM EC total (C->T)" "$slam_ec" "96"

# SC total (T->C secondary, SLAM-seq gradient: 0/low/medium/high)
slam_sc=$(sum_sc_tags "$SLAM_SAM")
check_exact "SLAM SC total (T->C)" "$slam_sc" "590"

# NC total (noise)
slam_nc=$(grep -v '^@' "$SLAM_SAM" | grep -oE 'NC:i:[0-9]+' | sed 's/NC:i://' | awk '{s+=$1} END{print s+0}')
check_exact "SLAM NC total (noise)" "$slam_nc" "101"

# CSV export
slam_csv_rows=$(count_csv_rows "$SLAM_CSV")
check_exact "SLAM CSV rows" "$slam_csv_rows" "40"

# CSV has secondary_editing_count column (21 columns)
slam_csv_cols=$(count_csv_cols "$SLAM_CSV")
check_exact "SLAM CSV columns" "$slam_csv_cols" "21"

# Quality report exists
if [ -f "$SLAM_OUT/10_csv/slam_slam_RPI_5_quality_report.txt" ]; then
    pass "SLAM quality report exists"
else
    fail "SLAM quality report missing"
fi

echo "  ⏱ Test 3: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 5: Intron splicing support (--introns flag)
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "[TEST 4] Splicing annotation + discovery"
echo ""

SPLICE_DIR="$DATA_DIR/splice_test"

# Run step 09 with --introns
mkdir -p "$OUTPUT_DIR/pipeline_splice"
cat > "$OUTPUT_DIR/pipeline_splice/description.txt" <<'EOF'
Splice annotation test — reads with known introns annotated with SJ tags (S=spliced, R=retained, –=not spanned). Use "Color by SJ" to visualize splice status.

Command: L3Rseq run --pattern CT --introns introns.bed --start-at 9 --stop-at 10
EOF

"$PIPELINE_DIR/L3Rseq" run \
    --input "$SPLICE_DIR" \
    --outdir "$OUTPUT_DIR/pipeline_splice" \
    --ref "$PIPELINE_DIR/resources/references/test_gene_with_intron.fasta" \
    --method longread-umi \
    --pattern CT \
    --introns "$SPLICE_DIR/introns.bed" \
    --start-at 9 --stop-at 10 \
    --threads 4 > "$OUTPUT_DIR/test5.log" 2>&1

SPLICE_SAM="$OUTPUT_DIR/pipeline_splice/09_correct/barcode_splice/barcode_splice_RPI_1/corrected.sam"

# SJ tags should be present on all reads
sj_count=$(grep -v '^@' "$SPLICE_SAM" | grep -c 'SJ:Z:') || sj_count=0
total_reads=$(count_sam_reads "$SPLICE_SAM")
check_exact "SJ tag present on all reads" "$sj_count" "$total_reads"

# Count splice patterns
spliced=$(grep -v '^@' "$SPLICE_SAM" | grep -c 'SJ:Z:S') || spliced=0
unspliced=$(grep -v '^@' "$SPLICE_SAM" | grep -c 'SJ:Z:R') || unspliced=0
unknown=$(grep -v '^@' "$SPLICE_SAM" | grep -c 'SJ:Z:-') || unknown=0

check_exact "Spliced reads (SJ:Z:S)" "$spliced" "15"
check_exact "Unspliced reads (SJ:Z:R)" "$unspliced" "10"
check_exact "Unknown reads (SJ:Z:-)" "$unknown" "5"

# EC tags should reflect C-to-T editing at 8 exon sites (~70% rate)
splice_ec=$(grep -v '^@' "$SPLICE_SAM" | grep -oP 'EC:i:\K[0-9]+' | awk '{s+=$1} END{print s+0}')
check_range "Splice EC total (C->T)" "$splice_ec" "162" "0.10"

# NC tags (background noise) should be present
splice_nc_count=$(grep -v '^@' "$SPLICE_SAM" | grep -c 'NC:i:') || splice_nc_count=0
check_exact "Splice NC tag present" "$splice_nc_count" "$total_reads"

# CSV should have splice columns
SPLICE_CSV="$OUTPUT_DIR/pipeline_splice/10_csv/barcode_splice_barcode_splice_RPI_1.csv"
if head -1 "$SPLICE_CSV" | grep -q 'splice_pattern'; then
    pass "CSV has splice_pattern column"
else
    fail "CSV missing splice_pattern column"
fi

# Discovery should find the intron
"$PIPELINE_DIR/L3Rseq" discover-introns \
    --input "$SPLICE_DIR/07_map" \
    --outdir "$OUTPUT_DIR/discover_splice" > "$OUTPUT_DIR/test5_discover.log" 2>&1

DISCOVER_BED="$OUTPUT_DIR/discover_splice/barcode_splice_barcode_splice_RPI_1_candidate_introns.bed"
if [ -f "$DISCOVER_BED" ] && [ -s "$DISCOVER_BED" ]; then
    # Check the discovered intron is at position 300-500
    disc_start=$(head -1 "$DISCOVER_BED" | cut -f2)
    disc_end=$(head -1 "$DISCOVER_BED" | cut -f3)
    if [ "$disc_start" = "300" ] && [ "$disc_end" = "500" ]; then
        pass "Discovery found intron at 300-500"
    else
        fail "Discovery found wrong position: $disc_start-$disc_end (expected 300-500)"
    fi
else
    fail "Discovery BED file missing or empty"
fi
echo "  ⏱ Test 4: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 6: BLAST + Walk Correction
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "========================================"
echo "[TEST 5] BLAST + walk correction"
echo "========================================"
echo ""

BLAST_DATA="$DATA_DIR/blast_test"

MOCK_BLAST_DIR="$PIPELINE_DIR/resources/blast"

# Run steps 09-10 with mock BLAST databases
mkdir -p "$OUTPUT_DIR/pipeline_blast"
cat > "$OUTPUT_DIR/pipeline_blast/description.txt" <<'EOF'
BLAST + walk correction test — validates soft-clip extension via BLAST alignment, chimeric read removal, poly-A detection, and translocation tagging (TL:i:1). Try "Group by TL" to separate translocations (TL=1) from normal reads (TL=0), and "Sort by DS" to order by double-sorter priority.

Command: L3Rseq run --pattern CT --blast-db mock_chrm_db --blast-db2 mock_cdna_db --start-at 9 --stop-at 10
EOF

"$PIPELINE_DIR/L3Rseq" run \
    --input "$BLAST_DATA" \
    --outdir "$OUTPUT_DIR/pipeline_blast" \
    --ref "$REF" \
    --pattern CT \
    --blast-db "$MOCK_BLAST_DIR/mock_chrm/mock_chrm_db" \
    --blast-db2 "$MOCK_BLAST_DIR/mock_cdna/mock_cdna_db" \
    --start-at 9 --stop-at 10 \
    --threads 4 > "$OUTPUT_DIR/test6.log" 2>&1

BLAST_SAM="$OUTPUT_DIR/pipeline_blast/09_correct/barcode_blast/barcode_blast_RPI_1/corrected.sam"
CHIM_SAM="$OUTPUT_DIR/pipeline_blast/09_correct/barcode_blast/barcode_blast_RPI_1/chimeric_rightclip.sam"
BLAST_ODIR="$OUTPUT_DIR/pipeline_blast/09_correct/barcode_blast/barcode_blast_RPI_1"
BLAST_CSV="$OUTPUT_DIR/pipeline_blast/10_csv/barcode_blast_barcode_blast_RPI_1.csv"

# Read expected CIGARs from generator output
EXPECTED_CIGARS="$BLAST_DATA/expected_cigars.txt"

# --- Walk correction assertions ---
while IFS=$'\t' read -r qname orig expected; do
    short_name="${qname%%;*}"
    got=$(grep "$qname" "$BLAST_SAM" | cut -f6)
    if [ "$got" = "$expected" ]; then
        pass "$short_name CIGAR corrected: $orig → $got"
    else
        fail "$short_name CIGAR wrong: expected $expected, got $got (was $orig)"
    fi
done < "$EXPECTED_CIGARS"

# --- ChrM translocation assertions (4 reads: 2 cox1 + 2 nad1) ---
for r in chrm_cox1_head chrm_cox1_tail chrm_nad1_head chrm_nad1_mid; do
    if grep "$r" "$BLAST_SAM" | grep -q 'TL:i:1'; then
        pass "$r has TL:i:1 (translocation)"
    else
        fail "$r missing TL:i:1"
    fi
done

# --- Chimeric filtering assertions (4 reads: 2 rRNA + 1 28S + 1 Rubisco) ---
for r in chimeric_18S_head chimeric_18S_mid chimeric_28S chimeric_Rubisco; do
    if grep -q "$r" "$CHIM_SAM" && ! grep -q "$r" "$BLAST_SAM"; then
        pass "$r in chimeric_rightclip.sam (not in corrected)"
    else
        fail "$r classification wrong"
    fi
done

chimeric_count=$(grep -cv '^@' "$CHIM_SAM")
check_exact "Chimeric read count" "$chimeric_count" "4"

# --- Poly-A retention assertions (4 reads) ---
for r in polya_150 polya_80 polya_60 polya_100; do
    if grep "$r" "$BLAST_SAM" | grep -q 'TL:i:0'; then
        pass "$r retained in corrected (poly-A, TL:i:0)"
    else
        fail "$r not retained or wrong TL tag"
    fi
done

# --- Unidentified clip retention assertions (4 reads) ---
for r in unid_clip_70 unid_clip_90 unid_clip_55 unid_clip_110; do
    if grep -q "$r" "$BLAST_SAM"; then
        pass "$r retained in corrected (unidentified clip)"
    else
        fail "$r missing from corrected"
    fi
done

# --- Count and file assertions ---
corrected_count=$(grep -cv '^@' "$BLAST_SAM")
check_exact "Corrected read count" "$corrected_count" "28"

csv_rows=$(tail -n+2 "$BLAST_CSV" | wc -l | tr -d ' ')
check_exact "CSV row count" "$csv_rows" "28"

if [ -s "$BLAST_ODIR/blast_rightclip_queries.fa" ]; then
    pass "BLAST query FASTA exists and non-empty"
else
    fail "BLAST query FASTA missing or empty"
fi

control_count=$(grep -c 'control_' "$BLAST_SAM")
check_exact "Control reads in corrected" "$control_count" "8"

echo "  ⏱ Test 5: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 6: IGV viewer API
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "[TEST 6] IGV viewer API"
echo ""

# Start viewer on test output, wait for it to be ready
"$PIPELINE_DIR/L3Rseq" viewer --stop 2>/dev/null
"$PIPELINE_DIR/L3Rseq" viewer --dir "$OUTPUT_DIR" > /dev/null 2>&1
VIEWER_UP=0
for _i in 1 2 3 4 5; do
    if curl -sf http://localhost:8080/ > /dev/null 2>&1; then
        VIEWER_UP=1; break
    fi
    sleep 1
done

if [ "$VIEWER_UP" -eq 0 ]; then
    fail "Viewer failed to start"
else
    pass "Viewer started on port 8080"

    # /api/datasets — check dataset count and known names
    _ds_json=$(curl -sf http://localhost:8080/api/datasets 2>/dev/null)
    if [ -n "$_ds_json" ]; then
        _ds_count=$(echo "$_ds_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['datasets']))" 2>/dev/null)
        if [ "$_ds_count" -ge 6 ]; then
            pass "API /datasets: $_ds_count datasets (expected >=6)"
        else
            fail "API /datasets: $_ds_count datasets (expected >=6)"
        fi
        # Check key datasets exist
        for _ds_name in pipeline pipeline_dual pipeline_blast pipeline_SLAM pipeline_splice demo; do
            if echo "$_ds_json" | python3 -c "import json,sys; ds=json.load(sys.stdin)['datasets']; sys.exit(0 if any('$_ds_name' in d for d in ds) else 1)" 2>/dev/null; then
                pass "API /datasets: '$_ds_name' found"
            else
                fail "API /datasets: '$_ds_name' missing"
            fi
        done
        # Check descriptions present
        _desc_count=$(echo "$_ds_json" | python3 -c "import json,sys; print(sum(1 for d in json.load(sys.stdin).get('datasetInfo',[]) if d.get('description')))" 2>/dev/null)
        if [ "$_desc_count" -ge 6 ]; then
            pass "API /datasets: $_desc_count descriptions (expected >=6)"
        else
            fail "API /datasets: only $_desc_count descriptions (expected >=6)"
        fi
    else
        fail "API /datasets: no response"
    fi

    # /api/tracks — check pipeline tracks
    _tracks_json=$(curl -sf "http://localhost:8080/api/tracks?name=$(echo "$_ds_json" | python3 -c "import json,sys; ds=json.load(sys.stdin)['datasets']; print(next(d for d in ds if 'pipeline' == d.split('/')[-1]))" 2>/dev/null)" 2>/dev/null)
    if [ -n "$_tracks_json" ]; then
        _track_count=$(echo "$_tracks_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['tracks']))" 2>/dev/null)
        check_exact "API /tracks: pipeline track count" "$_track_count" "4"
    else
        fail "API /tracks: no response"
    fi

    # /api/pileup — check pileup has tag summaries (was silently broken before refactor)
    _pileup_ds=$(echo "$_ds_json" | python3 -c "import json,sys; ds=json.load(sys.stdin)['datasets']; print(next(d for d in ds if 'pipeline' == d.split('/')[-1]))" 2>/dev/null)
    _pileup=$(curl -sf "http://localhost:8080/api/pileup?name=$_pileup_ds" 2>/dev/null)
    if [ -n "$_pileup" ]; then
        _ec_lines=$(echo "$_pileup" | grep -c '  EC: total=' || true)
        if [ "$_ec_lines" -ge 2 ]; then
            pass "API /pileup: $_ec_lines tracks with EC summary"
        else
            fail "API /pileup: only $_ec_lines EC summaries (expected >=2)"
        fi
        _cigar_lines=$(echo "$_pileup" | grep -c '  CIGARs:' || true)
        check_exact "API /pileup: CIGAR summaries" "$_cigar_lines" "4"
    else
        fail "API /pileup: no response"
    fi

    # IGV.js patches — verify tag value 0 fixes survived
    _igv_path="$PIPELINE_DIR/igv_viewer/node_modules/igv/dist/igv.min.js"
    if grep -q 'e.tags()\[n\]??"' "$_igv_path" 2>/dev/null; then
        pass "IGV.js patch: tag value 0 in getTag"
    else
        fail "IGV.js patch: tag value 0 in getTag missing"
    fi
    if grep -q 'Tp(r,n,i)??"' "$_igv_path" 2>/dev/null; then
        pass "IGV.js patch: tag value 0 in group key"
    else
        fail "IGV.js patch: tag value 0 in group key missing"
    fi
    if grep -q 'this.groupBy&&n!==""){i.save()' "$_igv_path" 2>/dev/null; then
        pass "IGV.js patch: group label for value 0"
    else
        fail "IGV.js patch: group label for value 0 missing"
    fi

    "$PIPELINE_DIR/L3Rseq" viewer --stop 2>/dev/null
fi
echo "  ⏱ Test 6: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Test 7: Plot generation (analysis conda env + plot_umi_bins.py)
# ---------------------------------------------------------------------------

T_START=$SECONDS
echo "[TEST 7] Plot generation (analysis env)"
echo ""

# Check analysis env exists and has matplotlib/numpy
if conda run -n analysis python -c "import matplotlib; import numpy" 2>/dev/null; then
    pass "analysis env: matplotlib + numpy importable"
else
    fail "analysis env: matplotlib or numpy missing"
fi

# Generate plots for CT pipeline
PLOT_DIR="$OUTPUT_DIR/pipeline_CT/figures"
rm -rf "$PLOT_DIR"
if conda run -n analysis python3 "$PIPELINE_DIR/scripts/plot_umi_bins.py" \
    "$OUTPUT_DIR/pipeline_CT" --quality --pattern CT > "$OUTPUT_DIR/test7_ct.log" 2>&1; then
    pass "plot_umi_bins.py --pattern CT ran successfully"
else
    fail "plot_umi_bins.py --pattern CT failed (see test7_ct.log)"
fi

# Check PNGs were created (4 samples)
_plot_count=$(find "$PLOT_DIR" -name '*.png' 2>/dev/null | wc -l)
check_exact "CT plot PNGs generated" "$_plot_count" "4"

# Check plots have non-trivial size (>10KB = real content, not empty/error)
_small_plots=0
for _png in "$PLOT_DIR"/*.png; do
    [ -f "$_png" ] || continue
    _size=$(wc -c < "$_png")
    if [ "$_size" -lt 10000 ]; then
        _small_plots=$((_small_plots + 1))
    fi
done
check_exact "CT plots with valid size (>10KB)" "$_small_plots" "0"

# Generate plots for CT,AG pipeline
if [ -d "$OUTPUT_DIR/pipeline_CTAG/10_csv" ]; then
    PLOT_CTAG_DIR="$OUTPUT_DIR/pipeline_CTAG/figures"
    rm -rf "$PLOT_CTAG_DIR"
    if conda run -n analysis python3 "$PIPELINE_DIR/scripts/plot_umi_bins.py" \
        "$OUTPUT_DIR/pipeline_CTAG" --quality --pattern CT,AG > "$OUTPUT_DIR/test7_ctag.log" 2>&1; then
        pass "plot_umi_bins.py --pattern CT,AG ran successfully"
    else
        fail "plot_umi_bins.py --pattern CT,AG failed (see test7_ctag.log)"
    fi
    _plot_ctag_count=$(find "$PLOT_CTAG_DIR" -name '*.png' 2>/dev/null | wc -l)
    check_exact "CT,AG plot PNGs generated" "$_plot_ctag_count" "4"
fi

echo "  ⏱ Test 7: $(( SECONDS - T_START ))s"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

SUITE_ELAPSED=$(( SECONDS - SUITE_START ))
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "Total time: ${SUITE_ELAPSED}s"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "Some tests FAILED. Check $OUTPUT_DIR/test*.log for details."
    exit 1
fi

echo "All tests passed."

# ---------------------------------------------------------------------------
# Optional: start IGV viewer after tests
# ---------------------------------------------------------------------------

if [ "$START_VIEWER" -eq 1 ]; then
    echo ""
    echo "Starting IGV viewer..."
    "$PIPELINE_DIR/L3Rseq" viewer --stop 2>/dev/null
    "$PIPELINE_DIR/L3Rseq" viewer --dir "$OUTPUT_DIR"
fi
