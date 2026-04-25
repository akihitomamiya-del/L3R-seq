#!/bin/bash
# 04_umi.sh -- UMI extraction and clustering
# Called by L3Rseq dispatcher.
# Supports --method umic-seq (UMIC-seq, default) and --method longread-umi.
# Requires: INPUT_DIR, OUTPUT_DIR, PROBE_FILE, UMI_LEN, UMI_LOC,
#           MIN_PROBE_SCORE, ALN_THRESH, SIZE_THRESH, CLUSTER_STEPS,
#           SAMPLE_SIZE, METHOD, UMI_FLANK5, UMI_FLANK3

set -euo pipefail

run_step_04() {
    local input_dir="$1"
    local output_dir="$2"
    local probe_file="$3"
    local umi_len="$4"
    local umi_loc="$5"
    local min_probe_score="$6"
    local aln_thresh="$7"
    local size_thresh="$8"
    local cluster_steps="$9"
    local sample_size="${10}"
    local method="${11:-umic-seq}"
    local umi_flank5="${12:-CTGAC}"
    local umi_flank3="${13:-TGGAATTCTCGGGTGCCAAGGC}"

    mkdir -p "$output_dir/04_umi"

    # input_dir should point directly to the demux (or filter) directory
    # containing barcode subdirectories with .fastq files
    local demux_base="$input_dir"

    if [ "$method" = "longread-umi" ]; then
        # ---- longread-umi method ----
        echo "[Step 04] UMI extraction and clustering (method: longread-umi) ..."

        # Resolve umi_binning_single.sh path (workspace → conda fallback)
        local _script_dir _umi_script _longread_umi_path
        _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _umi_script="$_script_dir/../longread_umi_L3Rseq/scripts/umi_binning_single.sh"
        _longread_umi_path="$_script_dir/../longread_umi_L3Rseq"
        if [ ! -f "$_umi_script" ]; then
            _umi_script="$CONDA_PREFIX/longread_umi/scripts/umi_binning_single.sh"
            _longread_umi_path="$CONDA_PREFIX/longread_umi"
        fi

        # Build task list: bname<TAB>fq<TAB>fname
        local _tasks
        _tasks=$(mktemp)
        trap "rm -f '$_tasks'" RETURN
        local _step04_count=0
        for barcode_dir in "$demux_base"/*/; do
            [ -d "$barcode_dir" ] || continue
            local bname
            bname=$(basename "$barcode_dir")
            for fq in "$barcode_dir"/*.fastq; do
                [ -f "$fq" ] || continue
                local fname
                fname=$(basename "$fq" .fastq)
                [[ "$fname" == *"unclassified"* ]] && continue
                printf '%s\t%s\t%s\n' "$bname" "$fq" "$fname" >> "$_tasks"
                _step04_count=$((_step04_count + 1))
            done
        done

        if [ "$_step04_count" -eq 0 ]; then
            echo "  WARNING: No input FASTQs found in $demux_base. Check --input path." >&2
            echo "[Step 04] Done. Output in $output_dir/04_umi/"
            return 0
        fi

        # Parallelism across RPIs. UMI_PARALLEL_JOBS > 1 uses GNU parallel;
        # threads are divided evenly so total concurrent thread usage stays
        # near the user's --threads budget. Defaults to serial (1) to preserve
        # previous behavior exactly.
        local _jobs="${UMI_PARALLEL_JOBS:-1}"
        local _total_threads="${THREADS:-$(nproc 2>/dev/null || echo 1)}"
        local _threads_per_job=$(( _total_threads / _jobs ))
        (( _threads_per_job < 1 )) && _threads_per_job=1

        # Per-RPI worker (also handles UMIclusterfull hardlink creation so it
        # is part of each parallel job, not a serial tail).
        _step04_process_one() {
            local bname="$1" fq="$2" fname="$3"
            local odir="$_step04_OUTPUT_DIR/04_umi/$bname/$fname"
            echo "  Processing $bname / $fname ..."
            LONGREAD_UMI_PATH="$_step04_LONGREAD_UMI_PATH" \
                bash "$_step04_UMI_SCRIPT" \
                -d "$fq" \
                -o "$odir" \
                -f "$_step04_UMI_FLANK5" \
                -r "$_step04_UMI_FLANK3" \
                -l "$_step04_UMI_LEN" \
                -n "$_step04_SIZE_THRESH" \
                -t "$_step04_THREADS_PER_JOB"
            # UMIclusterfull hardlinks for step 05 (see original rationale)
            if [ -d "$odir/read_binning/bins" ]; then
                rm -rf "$odir/UMIclusterfull"
                mkdir -p "$odir/UMIclusterfull"
                local _subdir _sname
                for _subdir in "$odir/read_binning/bins"/*/; do
                    [ -d "$_subdir" ] || continue
                    _sname=$(basename "$_subdir")
                    mkdir -p "$odir/UMIclusterfull/$_sname"
                    if ls "$_subdir"/*bins.fastq &>/dev/null; then
                        ln "$_subdir"/*bins.fastq "$odir/UMIclusterfull/$_sname/" 2>/dev/null || \
                            cp "$_subdir"/*bins.fastq "$odir/UMIclusterfull/$_sname/"
                    fi
                done
            fi
        }

        export _step04_OUTPUT_DIR="$output_dir"
        export _step04_UMI_SCRIPT="$_umi_script"
        export _step04_LONGREAD_UMI_PATH="$_longread_umi_path"
        export _step04_UMI_FLANK5="$umi_flank5"
        export _step04_UMI_FLANK3="$umi_flank3"
        export _step04_UMI_LEN="$umi_len"
        export _step04_SIZE_THRESH="$size_thresh"
        export _step04_THREADS_PER_JOB="$_threads_per_job"
        export -f _step04_process_one

        if [ "$_jobs" -gt 1 ] && command -v parallel >/dev/null 2>&1; then
            echo "  [parallel] $_jobs jobs × $_threads_per_job threads/job (UMI_PARALLEL_JOBS=$_jobs)"
            parallel --line-buffer -j "$_jobs" --colsep '\t' \
                _step04_process_one {1} {2} {3} < "$_tasks"
        else
            while IFS=$'\t' read -r bname fq fname; do
                _step04_process_one "$bname" "$fq" "$fname"
            done < "$_tasks"
        fi

        # Summary: report bins per RPI from stats files
        for _rdir in "$output_dir"/04_umi/*/*; do
            [ -d "$_rdir" ] || continue
            local _bname _rname _stats
            _bname=$(basename "$(dirname "$_rdir")")
            _rname=$(basename "$_rdir")
            _stats="$_rdir/read_binning/umi_cluster_stats.tsv"
            if [ -f "$_stats" ]; then
                local _bins _reads _mean
                _bins=$(awk -F'\t' '$2=="kept_bins"{print $3}' "$_stats")
                _reads=$(awk -F'\t' '$2=="reads_in_kept_bins"{print $3}' "$_stats")
                _mean=$(awk -F'\t' '$2=="mean_cluster_size"{print $3}' "$_stats")
                echo "    $_bname/$_rname: $_bins bins, $_reads reads in bins (mean cluster size $_mean)"
                _summary_append "$output_dir" "$_bname" "$_rname" "04" "bins_kept" "$_bins" || echo "  WARNING: Failed to write summary metric" >&2
                _summary_append "$output_dir" "$_bname" "$_rname" "04" "reads_in_bins" "$_reads" || echo "  WARNING: Failed to write summary metric" >&2
            fi
        done
        echo "[Step 04] Done. Output in $output_dir/04_umi/"
        return 0
    fi

    # ---- umic-seq method (default) ----
    echo "[Step 04] UMI extraction and clustering (method: $method) ..."

    # Prefer workspace source (UMIC-seq_L3Rseq/) over conda env copy,
    # so fixes take effect without rebuilding the Docker image.
    local _script_dir_umic
    _script_dir_umic="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local umic_py="$_script_dir_umic/../UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py"
    if [ ! -f "$umic_py" ]; then
        umic_py="$CONDA_PREFIX/UMIC-seq/UMIC-seq_fastq_v2.py"
    fi
    if [ ! -f "$umic_py" ]; then
        echo "[Step 04] ERROR: UMIC-seq script not found" >&2
        echo "         Checked: UMIC-seq_L3Rseq/ and $CONDA_PREFIX/UMIC-seq/" >&2
        return 1
    fi

    # Resolve probe_file to absolute path once so parallel subshells see
    # the same file regardless of cwd.
    local _probe_abs
    _probe_abs="$(cd "$(dirname "$probe_file")" && pwd)/$(basename "$probe_file")"

    # Build task list: bname<TAB>fq<TAB>fname
    local _tasks_umic
    _tasks_umic=$(mktemp)
    trap "rm -f '$_tasks_umic'" RETURN
    local _step04_umic_count=0
    for barcode_dir in "$demux_base"/*/; do
        [ -d "$barcode_dir" ] || continue
        local bname
        bname=$(basename "$barcode_dir")
        for fq in "$barcode_dir"/*.fastq; do
            [ -f "$fq" ] || continue
            local fname
            fname=$(basename "$fq" .fastq)
            [[ "$fname" == *"unclassified"* ]] && continue
            printf '%s\t%s\t%s\n' "$bname" "$fq" "$fname" >> "$_tasks_umic"
            _step04_umic_count=$((_step04_umic_count + 1))
        done
    done

    if [ "$_step04_umic_count" -eq 0 ]; then
        echo "  WARNING: No input FASTQs found in $demux_base. Check --input path." >&2
        echo "[Step 04] Done. Output in $output_dir/04_umi/"
        return 0
    fi

    # Parallelism across RPIs. Same env var + semantics as longread-umi branch.
    local _jobs="${UMI_PARALLEL_JOBS:-1}"
    local _total_threads="${THREADS:-$(nproc 2>/dev/null || echo 1)}"
    local _threads_per_job=$(( _total_threads / _jobs ))
    (( _threads_per_job < 1 )) && _threads_per_job=1

    _step04_umic_process_one() {
        local bname="$1" fq="$2" fname="$3"
        local odir="$_step04_UMIC_OUTPUT_DIR/04_umi/$bname/$fname"
        echo "  Processing $bname / $fname ..."
        mkdir -p "$odir"

        # NOTE: UMIC-seq argparse puts --threads at TOP level; it must come
        # BEFORE the subcommand name (UMIextract/clustertest/clusterfull).
        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" UMIextract \
            --input  "$fq" \
            --output "$odir/ExtractedUMIs.fasta" \
            --probe  "$_step04_UMIC_PROBE" \
            --umi_loc "$_step04_UMIC_UMI_LOC" --umi_len "$_step04_UMIC_UMI_LEN" \
            --min_probe_score "$_step04_UMIC_MIN_PROBE_SCORE" \
            2>&1 | tee "$odir/ExtractedUMIs.log"

        # cluster_steps is a "L R W" triple — keep unquoted (nargs=3)
        # shellcheck disable=SC2086
        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" clustertest \
            --input  "$odir/ExtractedUMIs.fasta" \
            --steps  $_step04_UMIC_CLUSTER_STEPS \
            --output "$odir/UMIclustertest" \
            --samplesize "$_step04_UMIC_SAMPLE_SIZE" \
            2>&1 | tee "$odir/UMIclustertest.log"

        python "$_step04_UMIC_PY" --threads "$_step04_UMIC_THREADS_PER_JOB" clusterfull \
            --input  "$odir/ExtractedUMIs.fasta" \
            --reads  "$fq" \
            --aln_thresh  "$_step04_UMIC_ALN_THRESH" \
            --size_thresh "$_step04_UMIC_SIZE_THRESH" \
            --output "$odir/UMIclusterfull" \
            --stop_thresh 0 \
            2>&1 | tee "$odir/UMIclusterfull.log"
    }

    export _step04_UMIC_OUTPUT_DIR="$output_dir"
    export _step04_UMIC_PY="$umic_py"
    export _step04_UMIC_PROBE="$_probe_abs"
    export _step04_UMIC_UMI_LOC="$umi_loc"
    export _step04_UMIC_UMI_LEN="$umi_len"
    export _step04_UMIC_MIN_PROBE_SCORE="$min_probe_score"
    export _step04_UMIC_CLUSTER_STEPS="$cluster_steps"
    export _step04_UMIC_SAMPLE_SIZE="$sample_size"
    export _step04_UMIC_ALN_THRESH="$aln_thresh"
    export _step04_UMIC_SIZE_THRESH="$size_thresh"
    export _step04_UMIC_THREADS_PER_JOB="$_threads_per_job"
    export -f _step04_umic_process_one

    # Locate GNU parallel. The UMIC-seq conda env doesn't ship it; fall back
    # to the longread_umi env's parallel binary or the system one.
    local _parallel=""
    if command -v parallel >/dev/null 2>&1; then
        _parallel="parallel"
    elif [ -x /opt/miniforge/envs/longread_umi/bin/parallel ]; then
        _parallel="/opt/miniforge/envs/longread_umi/bin/parallel"
    fi

    if [ "$_jobs" -gt 1 ] && [ -n "$_parallel" ]; then
        echo "  [parallel] $_jobs jobs × $_threads_per_job threads/job (UMI_PARALLEL_JOBS=$_jobs)"
        "$_parallel" --line-buffer -j "$_jobs" --colsep '\t' \
            _step04_umic_process_one {1} {2} {3} < "$_tasks_umic"
    else
        [ "$_jobs" -gt 1 ] && [ -z "$_parallel" ] && \
            echo "  WARNING: UMI_PARALLEL_JOBS=$_jobs requested but GNU parallel not found; falling back to serial" >&2
        while IFS=$'\t' read -r bname fq fname; do
            _step04_umic_process_one "$bname" "$fq" "$fname"
        done < "$_tasks_umic"
    fi

    # Summary: report bins per RPI for UMIC-seq
    for _rdir in "$output_dir"/04_umi/*/*; do
        [ -d "$_rdir" ] || continue
        local _bname _rname
        _bname=$(basename "$(dirname "$_rdir")")
        _rname=$(basename "$_rdir")
        local _nbins=0
        if [ -d "$_rdir/UMIclusterfull" ]; then
            _nbins=$(find "$_rdir/UMIclusterfull" -name '*bins.fastq' 2>/dev/null | wc -l)
        fi
        echo "    $_bname/$_rname: $_nbins bins"
        _summary_append "$output_dir" "$_bname" "$_rname" "04" "bins_kept" "$_nbins" || echo "  WARNING: Failed to write summary metric" >&2
    done
    echo "[Step 04] Done. Output in $output_dir/04_umi/"
}
