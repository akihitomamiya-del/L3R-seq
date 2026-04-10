#!/bin/bash
# config.sh -- Bash-only settings for the L3Rseq dispatcher.
#
# As of Phase 4 (config centralization), `config.yaml` is the single source
# of truth for pipeline step defaults. This file now holds only the values
# that don't make sense to put in YAML:
#
#   - Conda environment names (bash activates them directly)
#   - BLAST resource paths (derived from $SCRIPT_DIR at runtime)
#   - $(nproc)-derived thread defaults (bash-only, computed per-host)
#
# All other defaults (adapters, patterns, thresholds, ...) live in
# `config.yaml` and are loaded into the dispatcher via
# `scripts/load_config.sh` at startup. The pure-bash fallback block in
# `scripts/load_config.sh::_fallback_defaults` guarantees sensible values
# even if config.yaml is missing or the l3rseq_py env isn't available.
#
# Precedence in the dispatcher: CLI flag > config.yaml > _fallback_defaults.

# ---------------------------------------------------------------------------
# BLAST database paths (step 09 optional chimera detection)
# Resolved relative to $SCRIPT_DIR in L3Rseq after this file is sourced.
# ---------------------------------------------------------------------------
# DEFAULT_BLAST_DB_PATH and DEFAULT_BLAST_DB2_PATH are set in L3Rseq itself
# (they need $RESOURCES_DIR which is computed from $SCRIPT_DIR).

# ---------------------------------------------------------------------------
# Thread defaults derived from the host — not portable to YAML
# ---------------------------------------------------------------------------
DEFAULT_CONSENSUS_THREADS=$(nproc 2>/dev/null || echo 4)
DEFAULT_CORRECT_THREADS=$(nproc 2>/dev/null || echo 4)

# ---------------------------------------------------------------------------
# Conda environment names
# ---------------------------------------------------------------------------
ENV_CUTADAPT="cutadaptenv"        # steps 02, 03, 06
ENV_UMIC="UMIC-seq"              # step 04 (--method umic-seq)
ENV_LONGREAD_UMI="longread_umi"  # steps 04, 05 (--method longread-umi)
ENV_MAP="NanoporeMap"            # steps 07, 09, filter
ENV_LOFREQ="LoFreq"             # step 08
ENV_PY="l3rseq_py"               # Python algorithmic core (step 09 + step 11)
