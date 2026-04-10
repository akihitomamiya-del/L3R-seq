"""Config loader for the L3Rseq bash dispatcher.

`config.yaml` is the canonical source of truth for L3Rseq pipeline defaults.
This module is the bridge between that YAML file and the bash `L3Rseq`
dispatcher, which needs `DEFAULT_*` shell variables at startup.

The dispatcher invokes ``python -m l3rseq.config --config-file config.yaml``
via `scripts/load_config.sh` and `eval`s the emitted assignments. Two flavors
of variable are produced:

1. ``DEFAULT_<KEY>=<value>`` for each key in :data:`YAML_TO_BASH` — these are
   the 26 overlap scalars that used to live in `config.sh`. Step-level defaults
   that the dispatcher reads when a CLI flag is absent.
2. ``YAML_<KEY>=<value>`` for each run-scoped key in :data:`RUN_SCOPED_KEYS`
   (``input_dir``, ``ref``, ``regions``, ...). These enable the dispatcher's
   ``CLI > YAML > fallback`` precedence for flags that used to have no YAML
   tier at all.

All values are emitted shell-quoted via :func:`shlex.quote`, so adapter strings
containing ``$``, ``;``, and ``=`` round-trip safely through ``eval``.
"""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Mapping: YAML key → bash DEFAULT_* variable name.
#
# This is the single source of truth for the overlap between config.yaml and
# the dispatcher's DEFAULT_* fallback block. Both `scripts/load_config.sh`
# (via `python -m l3rseq.config`) and `scripts/check_config_sync.py` import
# this dict.
# ---------------------------------------------------------------------------
YAML_TO_BASH: dict[str, str] = {
    # Step 02 — adapter trimming
    "adapter_fwd": "DEFAULT_ADAPTER_FWD",
    "adapter_rev": "DEFAULT_ADAPTER_REV",
    "adapter_trim3": "DEFAULT_ADAPTER_TRIM3",
    "error_rate": "DEFAULT_ERROR_RATE",
    # Step 03 — demultiplex
    "demux_error_rate": "DEFAULT_DEMUX_ERROR_RATE",
    "demux_min_overlap": "DEFAULT_DEMUX_MIN_OVERLAP",
    # Step 04 — UMI extraction
    "umi_len": "DEFAULT_UMI_LEN",
    "umi_loc": "DEFAULT_UMI_LOC",
    "umi_min_probe_score": "DEFAULT_MIN_PROBE_SCORE",
    "umi_aln_thresh": "DEFAULT_ALN_THRESH",
    "umi_size_thresh": "DEFAULT_LONGREAD_SIZE_THRESH",
    "umi_cluster_steps": "DEFAULT_CLUSTER_STEPS",
    "umi_sample_size": "DEFAULT_SAMPLE_SIZE",
    "umi_flank5": "DEFAULT_UMI_FLANK5",
    "umi_flank3": "DEFAULT_UMI_FLANK3",
    # Step 05 — consensus
    "consensus_rounds": "DEFAULT_CONSENSUS_ROUNDS",
    "consensus_preset": "DEFAULT_CONSENSUS_PRESET",
    # Step 06 — target extraction
    "target_fwd": "DEFAULT_TARGET_FWD",
    "target_rev": "DEFAULT_TARGET_REV",
    "target_min_overlap": "DEFAULT_TARGET_MIN_OVERLAP",
    # Step 07 — mapping
    "map_preset": "DEFAULT_MAP_PRESET",
    # Step 08 — variants
    "min_af": "DEFAULT_MIN_AF",
    "pattern": "DEFAULT_PATTERN",
    # Step 09 — tail correction
    "clip_thresh": "DEFAULT_CLIP_THRESH",
}

# Run-scoped YAML keys that are NOT in config.sh today. The dispatcher exposes
# these as ``YAML_<UPPER>=<value>`` so `cmd_*` functions can fall back to them
# when the corresponding CLI flag is absent. This is what enables genuine
# CLI > YAML > defaults precedence for paths, references, and step 11 params.
RUN_SCOPED_KEYS: tuple[str, ...] = (
    "input_dir",
    "output_dir",
    "ref",
    "rpi_fasta",
    "umi_method",
    "count_pattern",
    "introns",
    "umi_probe",
    "blast_db",
    "blast_db2",
    "regions",
    "housekeeping",
    "min_frac",
    "min_mapq",
)


def load_yaml(path: Path) -> dict[str, Any]:
    """Parse a YAML file with PyYAML.

    PyYAML is a transitive dependency of snakemake-minimal, which is already
    installed in the ``l3rseq_py`` conda env. This module is only ever invoked
    from within that env via `scripts/load_config.sh`, so the import is safe.
    """
    import yaml  # local import — keeps module importable without PyYAML

    with path.open() as fh:
        data = yaml.safe_load(fh)
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: top-level YAML must be a mapping, got {type(data).__name__}")
    return data


def _format_scalar(value: Any) -> str:
    """Convert a YAML scalar to its bash string representation.

    Booleans become ``1``/``0`` (bash convention), None becomes empty string,
    everything else is stringified. Quoting is applied separately by
    :func:`shlex.quote` in :func:`emit_bash`.
    """
    if value is None:
        return ""
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def emit_bash(config: dict[str, Any]) -> str:
    """Emit ``eval``-safe bash assignments for a loaded config dict.

    Produces two blocks:

    1. ``DEFAULT_*`` assignments for every key in :data:`YAML_TO_BASH` that is
       present in *config*. Missing keys are silently skipped — the bash
       ``_fallback_defaults`` block will cover them.
    2. ``YAML_*`` assignments for every key in :data:`RUN_SCOPED_KEYS` that is
       present in *config*. These enable dispatcher-side YAML fallback for
       run-scoped flags (input_dir, ref, regions, ...).

    The nested ``threads:`` block is flattened to ``YAML_THREADS_<NAME>``.

    All values are passed through :func:`shlex.quote`, so strings containing
    ``$``, ``;``, ``=``, single quotes, or whitespace round-trip safely.
    """
    lines: list[str] = []

    for yaml_key, bash_name in YAML_TO_BASH.items():
        if yaml_key not in config:
            continue
        lines.append(f"{bash_name}={shlex.quote(_format_scalar(config[yaml_key]))}")

    for yaml_key in RUN_SCOPED_KEYS:
        if yaml_key not in config:
            continue
        bash_name = f"YAML_{yaml_key.upper()}"
        lines.append(f"{bash_name}={shlex.quote(_format_scalar(config[yaml_key]))}")

    threads = config.get("threads")
    if isinstance(threads, dict):
        for name, value in threads.items():
            bash_name = f"YAML_THREADS_{str(name).upper()}"
            lines.append(f"{bash_name}={shlex.quote(_format_scalar(value))}")

    return "\n".join(lines) + ("\n" if lines else "")


def emit_json(config: dict[str, Any]) -> str:
    """Emit the parsed config as compact JSON (for tests and debugging)."""
    return json.dumps(config, sort_keys=True, default=str)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Emit bash DEFAULT_*/YAML_* assignments from config.yaml.",
    )
    parser.add_argument(
        "--config-file",
        type=Path,
        required=True,
        help="Path to config.yaml (or an alternate YAML file with the same schema).",
    )
    parser.add_argument(
        "--mode",
        choices=("bash", "json"),
        default="bash",
        help="Output format: 'bash' for eval-ready assignments, 'json' for the parsed dict.",
    )
    args = parser.parse_args(argv)

    if not args.config_file.exists():
        print(f"l3rseq.config: {args.config_file} not found", file=sys.stderr)
        return 2

    try:
        cfg = load_yaml(args.config_file)
    except Exception as exc:  # noqa: BLE001 — surface to bash, keep dispatcher running
        print(f"l3rseq.config: failed to parse {args.config_file}: {exc}", file=sys.stderr)
        return 3

    if args.mode == "bash":
        sys.stdout.write(emit_bash(cfg))
    else:
        sys.stdout.write(emit_json(cfg) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
