#!/usr/bin/env python3
"""Verify config.yaml and the bash _fallback_defaults() block stay in sync.

As of Phase 4 (config centralization), `config.yaml` is the canonical source
of truth for L3Rseq pipeline defaults. The pure-bash fallback block in
`scripts/load_config.sh::_fallback_defaults` is the safety net the dispatcher
uses when config.yaml is missing or the l3rseq_py env is unavailable. This
script verifies that every overlap key (defined by
``l3rseq.config.YAML_TO_BASH``) has the same value in both files.

Run from CI to catch drift before it ships. Requires the l3rseq_py env on
PYTHONPATH (or ``src/`` on PYTHONPATH) to import ``l3rseq.config``.

Usage:
    PYTHONPATH=src python3 scripts/check_config_sync.py [--repo-root <path>]
    Exit 0 if everything matches, 1 if any drift is detected.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Import YAML_TO_BASH from the single source of truth. If this fails, the
# environment isn't set up correctly — surface a clear error instead of a
# ModuleNotFoundError traceback.
try:
    from l3rseq.config import YAML_TO_BASH
except ImportError as exc:
    print(
        "ERROR: cannot import l3rseq.config — set PYTHONPATH=src or activate "
        "the l3rseq_py conda env before running this script.",
        file=sys.stderr,
    )
    print(f"       underlying error: {exc}", file=sys.stderr)
    sys.exit(2)


def parse_bash_fallback(load_config_sh: Path) -> dict[str, str]:
    """Extract DEFAULT_* assignments from the _fallback_defaults() function.

    Looks for assignments between ``_fallback_defaults() {`` and the matching
    closing brace, strips inline comments, and unwraps quoted values. This
    keeps the parser simple while matching the file's hand-written style.
    """
    text = load_config_sh.read_text()
    match = re.search(
        r"_fallback_defaults\s*\(\)\s*\{(.*?)^\}",
        text,
        re.DOTALL | re.MULTILINE,
    )
    if match is None:
        raise ValueError(
            f"{load_config_sh}: could not find _fallback_defaults() function body"
        )
    body = match.group(1)

    out: dict[str, str] = {}
    assign_re = re.compile(r"^\s*(DEFAULT_[A-Z0-9_]+)=(.*)$")
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        m = assign_re.match(line)
        if not m:
            continue
        name, raw_value = m.group(1), m.group(2)
        if raw_value.startswith("'"):
            end = raw_value.find("'", 1)
            value = raw_value[1:end] if end > 0 else raw_value[1:]
        elif raw_value.startswith('"'):
            end = raw_value.find('"', 1)
            value = raw_value[1:end] if end > 0 else raw_value[1:]
        else:
            value = raw_value.split("#", 1)[0].strip()
        out[name] = value
    return out


def parse_yaml_simple(config_yaml: Path) -> dict[str, str]:
    """Minimal YAML parser for the flat key:value structure of config.yaml.

    Avoids a PyYAML dependency so the drift check can run in any env. Only
    handles top-level scalar keys — nested blocks (``threads:``) are skipped.
    """
    out: dict[str, str] = {}
    in_nested = False
    for raw in config_yaml.read_text().splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if line.startswith("threads:"):
            in_nested = True
            continue
        if in_nested:
            if line.startswith((" ", "\t")):
                continue
            in_nested = False
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        value = rest.strip()
        if "#" in value:
            value = value.split("#", 1)[0].rstrip()
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

    load_config_sh = args.repo_root / "scripts" / "load_config.sh"
    config_yaml = args.repo_root / "config.yaml"

    if not load_config_sh.exists():
        print(f"ERROR: {load_config_sh} not found", file=sys.stderr)
        return 2
    if not config_yaml.exists():
        print(f"ERROR: {config_yaml} not found", file=sys.stderr)
        return 2

    bash_vars = parse_bash_fallback(load_config_sh)
    yaml_keys = parse_yaml_simple(config_yaml)

    drift: list[str] = []
    missing_in_yaml: list[str] = []
    missing_in_bash: list[str] = []

    for yaml_key, bash_name in YAML_TO_BASH.items():
        if yaml_key not in yaml_keys:
            missing_in_yaml.append(f"  {yaml_key} (expected in config.yaml)")
            continue
        if bash_name not in bash_vars:
            missing_in_bash.append(
                f"  {bash_name} (expected in scripts/load_config.sh::_fallback_defaults)"
            )
            continue
        y = yaml_keys[yaml_key]
        b = bash_vars[bash_name]
        if y != b:
            drift.append(
                f"  {yaml_key} / {bash_name}: yaml={y!r}  bash={b!r}"
            )

    if not drift and not missing_in_yaml and not missing_in_bash:
        print(
            f"OK: {len(YAML_TO_BASH)} parameter(s) match between "
            "config.yaml and scripts/load_config.sh::_fallback_defaults"
        )
        return 0

    print(
        "FAIL: config.yaml and scripts/load_config.sh have drifted",
        file=sys.stderr,
    )
    if drift:
        print("\nValue mismatches:", file=sys.stderr)
        for d in drift:
            print(d, file=sys.stderr)
    if missing_in_yaml:
        print("\nMissing in config.yaml:", file=sys.stderr)
        for m in missing_in_yaml:
            print(m, file=sys.stderr)
    if missing_in_bash:
        print("\nMissing in scripts/load_config.sh::_fallback_defaults:", file=sys.stderr)
        for m in missing_in_bash:
            print(m, file=sys.stderr)
    print(
        "\nFix by editing both files in lockstep, then re-running this script.\n"
        "To add a new parameter, also extend YAML_TO_BASH in src/l3rseq/config.py.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
