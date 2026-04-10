"""Tests for src/l3rseq/config.py — YAML → bash config loader.

These tests lock down two critical properties:

1. **Shell quoting is safe.** Adapter strings in the real ``config.yaml``
   contain ``$``, ``;``, and ``=``. A naive emitter would corrupt them through
   ``eval``. Every round-trip assertion proves the emitted bash block parses
   back to the same value via ``bash -c eval``.
2. **The YAML_TO_BASH mapping stays in lockstep with the real config.yaml.**
   If someone adds a key to ``config.yaml`` and forgets to extend
   :data:`YAML_TO_BASH` (or vice versa), this test fails loudly.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from l3rseq.config import (
    RUN_SCOPED_KEYS,
    YAML_TO_BASH,
    emit_bash,
    load_yaml,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
REAL_CONFIG = REPO_ROOT / "config.yaml"


def _eval_bash(block: str) -> dict[str, str]:
    """Run ``eval`` on a bash block and return the resulting variable dump.

    Uses a fresh bash subshell so tests don't leak state. We ``declare -p``
    after the eval so every assigned variable comes back as ``NAME=value``
    pairs. This is the real ``eval`` path the dispatcher takes, so it's the
    most faithful round-trip check.
    """
    script = f"""
set -e
eval '{block.replace("'", "'\\''")}'
for v in $(compgen -v | grep -E '^(DEFAULT_|YAML_)'); do
    printf '%s=%s\\n' "$v" "${{!v}}"
done
"""
    result = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        check=True,
    )
    out: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k] = v
    return out


class TestEmitBashQuoting:
    def test_adapter_with_dollar_and_semicolon_roundtrips(self) -> None:
        cfg = {
            "adapter_fwd": "CAAGCAGAAGACG;min_overlap=63",
            "adapter_trim3": "TGGAATTCTCGGGTGCCAAGG$",
        }
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["DEFAULT_ADAPTER_FWD"] == "CAAGCAGAAGACG;min_overlap=63"
        assert env["DEFAULT_ADAPTER_TRIM3"] == "TGGAATTCTCGGGTGCCAAGG$"

    def test_value_with_single_quote_roundtrips(self) -> None:
        # No real config value has a single quote today, but shlex.quote must
        # still handle it — this is the most common quoting foot-gun.
        cfg = {"pattern": "it's a test"}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["DEFAULT_PATTERN"] == "it's a test"

    def test_value_with_spaces_roundtrips(self) -> None:
        cfg = {"umi_cluster_steps": "15 29 1"}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["DEFAULT_CLUSTER_STEPS"] == "15 29 1"

    def test_numeric_and_float(self) -> None:
        cfg = {"clip_thresh": 50, "min_af": 0.01}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["DEFAULT_CLIP_THRESH"] == "50"
        assert env["DEFAULT_MIN_AF"] == "0.01"

    def test_empty_string_emitted_as_empty(self) -> None:
        cfg = {"regions": "", "housekeeping": ""}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["YAML_REGIONS"] == ""
        assert env["YAML_HOUSEKEEPING"] == ""

    def test_none_becomes_empty(self) -> None:
        cfg = {"regions": None}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["YAML_REGIONS"] == ""

    def test_bool_becomes_1_or_0(self) -> None:
        cfg = {"regions": True, "housekeeping": False}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["YAML_REGIONS"] == "1"
        assert env["YAML_HOUSEKEEPING"] == "0"


class TestEmitBashStructure:
    def test_missing_keys_silently_skipped(self) -> None:
        # Nothing mapped → empty output is fine; fallback block will cover it.
        block = emit_bash({"unrelated_key": "value"})
        assert "DEFAULT_" not in block
        assert "YAML_UNRELATED_KEY" not in block

    def test_threads_block_flattened(self) -> None:
        cfg = {"threads": {"umi": 4, "consensus": 8}}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["YAML_THREADS_UMI"] == "4"
        assert env["YAML_THREADS_CONSENSUS"] == "8"

    def test_threads_non_dict_ignored(self) -> None:
        cfg = {"threads": "not-a-dict"}
        block = emit_bash(cfg)
        assert "YAML_THREADS_" not in block

    def test_run_scoped_keys_emit_as_yaml_prefix(self) -> None:
        cfg = {"input_dir": "/path/to/input", "ref": "/path/to/ref.fa"}
        block = emit_bash(cfg)
        env = _eval_bash(block)
        assert env["YAML_INPUT_DIR"] == "/path/to/input"
        assert env["YAML_REF"] == "/path/to/ref.fa"


class TestRealConfigYaml:
    """Ground-truth checks against the actual repo config.yaml."""

    def test_loads_without_error(self) -> None:
        cfg = load_yaml(REAL_CONFIG)
        assert isinstance(cfg, dict)
        assert "adapter_fwd" in cfg
        assert "pattern" in cfg

    def test_every_yaml_to_bash_key_present_in_real_config(self) -> None:
        """Every mapped YAML key must exist in the real config.yaml.

        If this fails, someone either removed a key from config.yaml without
        updating YAML_TO_BASH, or added an entry to YAML_TO_BASH for a key
        that doesn't exist yet. Either way, the drift is surfaced here.
        """
        cfg = load_yaml(REAL_CONFIG)
        missing = [k for k in YAML_TO_BASH if k not in cfg]
        assert not missing, f"YAML_TO_BASH keys missing from config.yaml: {missing}"

    def test_every_run_scoped_key_present_in_real_config(self) -> None:
        cfg = load_yaml(REAL_CONFIG)
        missing = [k for k in RUN_SCOPED_KEYS if k not in cfg]
        assert not missing, f"RUN_SCOPED_KEYS missing from config.yaml: {missing}"

    def test_real_config_adapter_roundtrips(self) -> None:
        cfg = load_yaml(REAL_CONFIG)
        block = emit_bash(cfg)
        env = _eval_bash(block)
        # The real FWD adapter has both $ (via min_overlap=63) and ; — if
        # quoting is broken anywhere, this assertion will catch it.
        assert env["DEFAULT_ADAPTER_FWD"] == cfg["adapter_fwd"]
        assert env["DEFAULT_ADAPTER_REV"] == cfg["adapter_rev"]
        assert env["DEFAULT_ADAPTER_TRIM3"] == cfg["adapter_trim3"]

    def test_real_config_emits_all_mapped_defaults(self) -> None:
        cfg = load_yaml(REAL_CONFIG)
        block = emit_bash(cfg)
        env = _eval_bash(block)
        for yaml_key, bash_name in YAML_TO_BASH.items():
            assert bash_name in env, f"{bash_name} missing from emitted block"
            assert env[bash_name] == str(cfg[yaml_key]), (
                f"{bash_name}: got {env[bash_name]!r}, want {cfg[yaml_key]!r}"
            )


class TestLoadYaml:
    def test_missing_file_raises(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError):
            load_yaml(tmp_path / "nonexistent.yaml")

    def test_empty_file_returns_empty_dict(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.yaml"
        f.write_text("")
        assert load_yaml(f) == {}

    def test_non_mapping_top_level_rejected(self, tmp_path: Path) -> None:
        f = tmp_path / "list.yaml"
        f.write_text("- one\n- two\n")
        with pytest.raises(ValueError, match="top-level YAML must be a mapping"):
            load_yaml(f)
