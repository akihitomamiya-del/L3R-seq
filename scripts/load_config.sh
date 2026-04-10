#!/bin/bash
# load_config.sh -- YAML config loader for the L3Rseq dispatcher.
#
# Sourced by the L3Rseq bash dispatcher at startup. Exposes two functions:
#
#   _fallback_defaults   -- writes hardcoded DEFAULT_* values to the current
#                           shell. This is the pure-bash safety net used when
#                           config.yaml is missing or the l3rseq_py env isn't
#                           installed. Values here MUST stay in sync with
#                           config.yaml — scripts/check_config_sync.py enforces
#                           this on every PR.
#
#   l3rseq_load_config   -- usage: eval "$(l3rseq_load_config [<yaml_path>])"
#                           Shells out to `python -m l3rseq.config` in the
#                           l3rseq_py env and emits bash assignments. Falls
#                           back silently if the env or file is unavailable,
#                           so the caller should always invoke
#                           _fallback_defaults first to guarantee a floor.
#
# Precedence in the dispatcher:
#     CLI flag > YAML value (YAML_*) > fallback DEFAULT_*
#
# The loader never crashes the dispatcher. Any error is reported to stderr
# and the fallback values remain active.

# ---------------------------------------------------------------------------
# _fallback_defaults — pure-bash defaults (the floor of the precedence stack)
#
# These values must match config.yaml. scripts/check_config_sync.py parses
# this function's body and compares each assignment against the YAML file.
# Edit both in lockstep, or extend YAML_TO_BASH in src/l3rseq/config.py if
# you are adding a new key.
# ---------------------------------------------------------------------------
_fallback_defaults() {
    # Step 02 — adapter trimming (cutadapt)
    DEFAULT_ADAPTER_FWD='CAAGCAGAAGACGGCATACGAGATNNNNNNGTGACTGGAGTTCCTTGGCACCCGAGAATTCCA;min_overlap=63'
    DEFAULT_ADAPTER_REV='TGGAATTCTCGGGTGCCAAGGAACTCCAGTCACNNNNNNATCTCGTATGCCGTCTTCTGCTTG;min_overlap=63'
    DEFAULT_ADAPTER_TRIM3='TGGAATTCTCGGGTGCCAAGGAACTCCAGTCACNNNNNNATCTCGTATGCCGTCTTCTGCTTG$'
    DEFAULT_ERROR_RATE=0.2

    # Step 03 — RPI demultiplexing
    DEFAULT_DEMUX_ERROR_RATE=1
    DEFAULT_DEMUX_MIN_OVERLAP=20

    # Step 04 — UMI extraction (UMIC-seq method)
    DEFAULT_UMI_LEN=15
    DEFAULT_UMI_LOC=down
    DEFAULT_MIN_PROBE_SCORE=33
    DEFAULT_ALN_THRESH=24
    DEFAULT_SIZE_THRESH=3
    DEFAULT_CLUSTER_STEPS='15 29 1'
    DEFAULT_SAMPLE_SIZE=50

    # Step 04 — UMI extraction (longread-umi method, default)
    DEFAULT_UMI_FLANK5=CTGAC
    DEFAULT_UMI_FLANK3=TGGAATTCTCGGGTGCCAAGGC
    DEFAULT_LONGREAD_SIZE_THRESH=3

    # Step 05 — consensus (racon)
    DEFAULT_CONSENSUS_ROUNDS=4
    DEFAULT_CONSENSUS_PRESET=lr:hq

    # Step 06 — target extraction (cutadapt)
    DEFAULT_TARGET_FWD=CTACGCGCAAATTCTCATTGG
    DEFAULT_TARGET_REV=CTGACNNNNNNNNNNNNNNNTGGAATTCTCGGGTGCCAAGGAACTCCAGTCA
    DEFAULT_TARGET_MIN_OVERLAP=52

    # Step 07 — mapping (minimap2)
    DEFAULT_MAP_PRESET=lr:hq

    # Step 08 — variants (LoFreq)
    DEFAULT_MIN_AF=0.01
    DEFAULT_PATTERN=CT

    # Step 09 — tail correction
    DEFAULT_CLIP_THRESH=50
}

# ---------------------------------------------------------------------------
# l3rseq_load_config — emit bash assignments parsed from a YAML file.
#
# Usage:   eval "$(l3rseq_load_config <yaml_path>)"
#
# On success: writes `DEFAULT_<KEY>=<value>` and `YAML_<KEY>=<value>` lines
# to stdout; the caller evals them to overlay defaults and expose run-scoped
# keys. On any failure (missing file, no l3rseq_py env, malformed YAML):
# writes nothing to stdout, logs a warning to stderr, and returns 0 so the
# dispatcher keeps running on fallback values.
# ---------------------------------------------------------------------------
l3rseq_load_config() {
    local yaml_path="${1:-}"
    if [ -z "$yaml_path" ] || [ ! -f "$yaml_path" ]; then
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local src_dir="$script_dir/src"

    # Prefer the l3rseq_py conda env's python if we can find it without
    # activating a whole subshell environment. Fall back to system python3
    # if the user set PYTHONPATH themselves. Either way, we only emit output
    # if the python helper exits 0.
    local py
    if [ -x "/opt/miniforge/envs/l3rseq_py/bin/python" ]; then
        py="/opt/miniforge/envs/l3rseq_py/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        py="python3"
    else
        echo "[load_config] python3 not found; staying on fallback defaults" >&2
        return 0
    fi

    local output
    if ! output="$(PYTHONPATH="$src_dir" "$py" -m l3rseq.config \
                    --config-file "$yaml_path" --mode bash 2>&1)"; then
        echo "[load_config] failed to parse $yaml_path:" >&2
        echo "$output" >&2
        return 0
    fi
    printf '%s\n' "$output"
}
