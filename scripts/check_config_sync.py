#!/usr/bin/env python3
"""Verify config.yaml and config.sh stay in sync.

These two files are both sources of truth for L3Rseq pipeline defaults:
- config.sh — sourced by the bash dispatcher (`L3Rseq run ...`)
- config.yaml — read by the Snakefile (`snakemake --configfile config.yaml`)

They must contain the same values for the same parameters. This script
maps each YAML key to its bash DEFAULT_* counterpart and reports any
mismatch. Run from CI to catch drift before it ships.

Usage:
    python3 scripts/check_config_sync.py [--repo-root <path>]
    Exit 0 if everything matches, 1 if any drift is detected.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Map: YAML key → bash variable name in config.sh.
# Add new entries here when introducing a new parameter to either file.
# A YAML key with no bash counterpart (or vice versa) is allowed but
# silently ignored — this map only enforces *overlap* sync.
YAML_TO_BASH = {
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


def parse_bash_defaults(config_sh: Path) -> dict[str, str]:
    """Extract DEFAULT_* assignments from config.sh.

    Handles single-quoted, double-quoted, and unquoted values. Strips
    inline shell comments after the value.
    """
    out: dict[str, str] = {}
    pattern = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")
    for raw in config_sh.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = pattern.match(line)
        if not m:
            continue
        name, raw_value = m.group(1), m.group(2)
        # Strip inline trailing comment (only if not inside quotes)
        # Simple heuristic: if value starts with ' or ", find matching quote
        # then ignore everything after.
        if raw_value.startswith("'"):
            end = raw_value.find("'", 1)
            value = raw_value[1:end] if end > 0 else raw_value[1:]
        elif raw_value.startswith('"'):
            end = raw_value.find('"', 1)
            value = raw_value[1:end] if end > 0 else raw_value[1:]
        else:
            # Strip any trailing # comment
            value = raw_value.split("#", 1)[0].strip()
        out[name] = value
    return out


def parse_yaml_simple(config_yaml: Path) -> dict[str, str]:
    """Minimal YAML parser for the flat key:value structure of config.yaml.

    We avoid the PyYAML dependency so this script can run in any env.
    Only handles the keys we care about — flat scalars at top level.
    Strings may be unquoted, single-quoted, double-quoted. Inline `#`
    comments are stripped.
    """
    out: dict[str, str] = {}
    in_threads_block = False
    for raw in config_yaml.read_text().splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        # Skip lines inside the `threads:` nested block (handled separately)
        if line.startswith("threads:"):
            in_threads_block = True
            continue
        if in_threads_block:
            if line.startswith(" ") or line.startswith("\t"):
                continue
            in_threads_block = False
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        value = rest.strip()
        # Strip inline trailing comment
        if "#" in value:
            # Simple split — assumes no '#' inside string values (they don't
            # appear in our config.yaml).
            value = value.split("#", 1)[0].rstrip()
        # Strip surrounding quotes
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        out[key] = value
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", type=Path,
                        help="Repository root (default: cwd)")
    args = parser.parse_args()

    config_sh = args.repo_root / "config.sh"
    config_yaml = args.repo_root / "config.yaml"

    if not config_sh.exists():
        print(f"ERROR: {config_sh} not found", file=sys.stderr)
        return 2
    if not config_yaml.exists():
        print(f"ERROR: {config_yaml} not found", file=sys.stderr)
        return 2

    bash_vars = parse_bash_defaults(config_sh)
    yaml_keys = parse_yaml_simple(config_yaml)

    drift: list[str] = []
    missing_in_yaml: list[str] = []
    missing_in_bash: list[str] = []

    for yaml_key, bash_name in YAML_TO_BASH.items():
        if yaml_key not in yaml_keys:
            missing_in_yaml.append(f"  {yaml_key} (expected in config.yaml)")
            continue
        if bash_name not in bash_vars:
            missing_in_bash.append(f"  {bash_name} (expected in config.sh)")
            continue
        y = yaml_keys[yaml_key]
        b = bash_vars[bash_name]
        if y != b:
            drift.append(
                f"  {yaml_key} / {bash_name}: yaml={y!r}  bash={b!r}"
            )

    if not drift and not missing_in_yaml and not missing_in_bash:
        print(f"OK: {len(YAML_TO_BASH)} parameter(s) match between config.yaml and config.sh")
        return 0

    print("FAIL: config.yaml and config.sh have drifted", file=sys.stderr)
    if drift:
        print("\nValue mismatches:", file=sys.stderr)
        for d in drift:
            print(d, file=sys.stderr)
    if missing_in_yaml:
        print("\nMissing in config.yaml:", file=sys.stderr)
        for m in missing_in_yaml:
            print(m, file=sys.stderr)
    if missing_in_bash:
        print("\nMissing in config.sh:", file=sys.stderr)
        for m in missing_in_bash:
            print(m, file=sys.stderr)
    print(
        "\nFix by editing both files in lockstep, then re-running this script.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
