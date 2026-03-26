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
        local _step04_count=0

        for barcode_dir in "$demux_base"/*/; do
            [ -d "$barcode_dir" ] || continue

            local bname
            bname=$(basename "$barcode_dir")

            for fq in "$barcode_dir"/*.fastq; do
                [ -f "$fq" ] || continue
                local fname
                fname=$(basename "$fq" .fastq)

                # Skip unclassified
                [[ "$fname" == *"unclassified"* ]] && continue

                _step04_count=$((_step04_count + 1))
                echo "  Processing $bname / $fname ..."
                local odir="$output_dir/04_umi/$bname/$fname"

                # Prefer workspace source (longread_umi_L3Rseq/) over conda env copy,
                # so fixes take effect without rebuilding the Docker image.
                # Fall back to conda env copy in production (no workspace source).
                local _script_dir
                _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                local _umi_script="$_script_dir/../longread_umi_L3Rseq/scripts/umi_binning_single.sh"
                local _longread_umi_path="$_script_dir/../longread_umi_L3Rseq"
                if [ ! -f "$_umi_script" ]; then
                    _umi_script="$CONDA_PREFIX/longread_umi/scripts/umi_binning_single.sh"
                    _longread_umi_path="$CONDA_PREFIX/longread_umi"
                fi

                LONGREAD_UMI_PATH="${LONGREAD_UMI_PATH:-$_longread_umi_path}" \
                    bash "$_umi_script" \
                    -d "$fq" \
                    -o "$odir" \
                    -f "$umi_flank5" \
                    -r "$umi_flank3" \
                    -l "$umi_len" \
                    -n "$size_thresh"

                # Create UMIclusterfull directory for step 05 compatibility.
                # consensus_racon uses 'find $IN -name umi*bins.fastq' without -L,
                # so symlinks don't work. Use hard links to avoid doubling disk usage.
                if [ -d "$odir/read_binning/bins" ]; then
                    rm -rf "$odir/UMIclusterfull"
                    mkdir -p "$odir/UMIclusterfull"
                    for _subdir in "$odir/read_binning/bins"/*/; do
                        [ -d "$_subdir" ] || continue
                        local _sname
                        _sname=$(basename "$_subdir")
                        mkdir -p "$odir/UMIclusterfull/$_sname"
                        ln "$_subdir"/*bins.fastq "$odir/UMIclusterfull/$_sname/" 2>/dev/null || \
                            cp "$_subdir"/*bins.fastq "$odir/UMIclusterfull/$_sname/"
                    done
                fi
            done
        done

        if [ "$_step04_count" -eq 0 ]; then
            echo "  WARNING: No input FASTQs found in $demux_base. Check --input path." >&2
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
                _summary_append "$output_dir" "$_bname" "$_rname" "04" "bins_kept" "$_bins" 2>/dev/null || true
                _summary_append "$output_dir" "$_bname" "$_rname" "04" "reads_in_bins" "$_reads" 2>/dev/null || true
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

    for barcode_dir in "$demux_base"/*/; do
        [ -d "$barcode_dir" ] || continue

        local bname
        bname=$(basename "$barcode_dir")

        for fq in "$barcode_dir"/*.fastq; do
            [ -f "$fq" ] || continue
            local fname
            fname=$(basename "$fq" .fastq)

            # Skip unclassified
            [[ "$fname" == *"unclassified"* ]] && continue

            echo "  Processing $bname / $fname ..."
            mkdir -p "$output_dir/04_umi/$bname/$fname"
            local odir="$output_dir/04_umi/$bname/$fname"

            # UMI extract
            python "$umic_py" UMIextract \
                --input "$fq" \
                --output "$odir/ExtractedUMIs.fasta" \
                --probe "$probe_file" \
                --umi_loc "$umi_loc" --umi_len "$umi_len" \
                --min_probe_score "$min_probe_score" \
                2>&1 | tee "$odir/ExtractedUMIs.log"

            # Cluster test
            # shellcheck disable=SC2086
            python "$umic_py" clustertest \
                --input "$odir/ExtractedUMIs.fasta" \
                --steps $cluster_steps \
                --output "$odir/UMIclustertest" \
                --samplesize "$sample_size" \
                2>&1 | tee "$odir/UMIclustertest.log"

            # Full clustering
            python "$umic_py" clusterfull \
                --input "$odir/ExtractedUMIs.fasta" \
                --reads "$fq" \
                --aln_thresh "$aln_thresh" \
                --size_thresh "$size_thresh" \
                --output "$odir/UMIclusterfull" \
                --stop_thresh 0 \
                2>&1 | tee "$odir/UMIclusterfull.log"

        done
    done

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
        _summary_append "$output_dir" "$_bname" "$_rname" "04" "bins_kept" "$_nbins" 2>/dev/null || true
    done
    echo "[Step 04] Done. Output in $output_dir/04_umi/"
}
