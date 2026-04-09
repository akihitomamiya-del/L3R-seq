# L3Rseq Pipeline Modernization — Phase 0 + Phase 1a

## Persistence and continuity (read this first)

This plan spans **multiple sessions across a devcontainer rebuild**. Phase 1b cannot start until a new Docker image with the `l3rseq_py` env is published and the devcontainer is rebuilt. So everything in this plan must survive that rebuild.

**What persists across the rebuild:**
- `/workspace` — bind-mounted from the host, survives everything (verified: `mount` shows `/run/host_mark/Users on /workspace type fakeowner`). Anything committed to git on this branch is rock-solid persistent.
- `/home/vscode/.claude/` — Docker **named volume** `claude-code-config-${devcontainerId}` (`.devcontainer/claude-code/devcontainer.json:38`). Named volumes survive container rebuilds, but are tied to the devcontainer ID. If the ID changes (config edit, host migration, fresh Codespace), the next container mounts an empty volume.
- Memory files at `~/.claude/projects/-workspace/memory/` — same volume as above. Probably survives, not guaranteed.

**What does NOT persist:**
- Anything in the container's writable layer outside the volumes (e.g., `/tmp/`, conda envs that aren't from the image, packages installed at runtime).

**Persistence strategy for this plan:**
1. **The very first implementation commit is `docs/PIPELINE_MODERNIZATION.md`** — a verbatim copy of this plan file, committed to the branch. This is the canonical, durable copy. Anything that survives a `git fetch` survives the rebuild.
2. The original plan file at `/home/vscode/.claude/plans/sequential-foraging-waterfall.md` is the working draft for this session — it may or may not survive, but doesn't matter because the docs/ copy is the source of truth.
3. Save a memory entry pointing to `docs/PIPELINE_MODERNIZATION.md` so future Claude sessions discover it without having to re-derive the plan.
4. The branch name `pipeline-modernization` is itself a recovery anchor — `git checkout pipeline-modernization && cat docs/PIPELINE_MODERNIZATION.md` re-establishes full context after any rebuild.

## Context

L3Rseq's pipeline is bash-driven, with optimized but fragile per-read shell logic. Step 09 (`scripts/09_tail_correct.sh` + `09a–09f_*.sh`) is the worst offender: its per-read worker function runs under `set +e` with `_require_int` / `_require_str` validation guards that exist *because* the bash subscripts can fail silently under parallel chunked subshells, producing `BUG:` warnings and `FAILED` status files. Each per-read worker spawns 8–12 child processes (cat, cut, awk, grep, samtools, printf), which is the dominant runtime cost on large samples.

After reviewing `dritoshi/ai-biocode-kata`, the user identified two habits worth adopting:
1. **Use library equivalents (pysam, biopython, pyranges) instead of hand-rolled shell+awk** — eliminates per-read process spawning, removes the `set +e` workaround, makes algorithms unit-testable.
2. **Wrap the pipeline in Snakemake** — gets resume-from-failure, auto-parallelism, and per-rule conda envs without rewriting step bodies.

This plan establishes the foundation for both and rewrites the *algorithmic core* of step 09 (the parts that don't need pysam). The pysam I/O layer, dispatcher switch, and Snakefile follow in later sessions, after the Docker image rebuild lands.

**Why phased**: pysam, snakemake, ruff, mypy, pyranges are absent from every existing conda env (verified empirically — only `UMIC-seq` has biopython 1.83 + pytest 9.0.2). The devcontainer firewall blocks PyPI / conda-forge / bioconda at runtime (verified — all return curl exit 7). Adding new packages requires editing the Dockerfile and triggering a tagged release → CI image rebuild → devcontainer rebuild. That's an async multi-step flow. So this session writes the Dockerfile changes (so the rebuild can start) and the algorithmic Python modules that *don't* depend on pysam — those can be tested *now* using `pytest 9.0.2` from the existing `UMIC-seq` env.

## Performance expectation (the user's main concern)

Python+pysam is expected to be **2–5× faster** than the current bash step 09 on per-read work, not slower. Bash subprocess spawn overhead dominates today (~1 ms × ~10 spawns × N reads). `pysam.AlignmentFile` iterates BAM at htslib speed (~500k reads/s); the Python per-read inner loop avoids subprocess invocation entirely. Maintainability wins (testability, IDE support, exception propagation) come for free.

Validation: a benchmark runs in Phase 1b alongside the differential test against the bash output. If Python is unexpectedly slower, escape valves are: profile the hot path with `cProfile`, add `multiprocessing.Pool`, or fall back to bash for that one step.

## Decisions (confirmed with user)

| Decision | Choice | Rationale |
|---|---|---|
| Session scope | Phase 0 + Phase 1a | Foundation + algorithm core, both testable in this session. Phase 1b (pysam I/O) deferred until image rebuild. |
| Env strategy | New `l3rseq_py` env | Clean isolation from existing pipeline-tool envs. ~1 GB image cost acceptable; avoids conda resolver conflicts with longread_umi / NanoporeMap. |
| Bash-09 fate | Decide later | Defer until Phase 1b runs and differential test + benchmark numbers are in. |

## Files to create / modify

### Step 0 — Persistence anchor

| File | Action | Purpose |
|---|---|---|
| `docs/PIPELINE_MODERNIZATION.md` | create | Verbatim copy of this plan file. Committed FIRST so the plan survives any future devcontainer rebuild. The bind-mounted `/workspace` makes this rock-solid persistent. |

### Phase 0 — Foundation (no behavior change, no new code paths exercised yet)

| File | Action | Purpose |
|---|---|---|
| `.devcontainer/build/Dockerfile` | edit | Add new `RUN mamba create -y -n l3rseq_py ...` block after the existing 7 env blocks (~line 163). Packages: `python=3.12 pysam biopython pyranges snakemake-minimal pandas scipy pytest pytest-cov ruff mypy`. Channels: conda-forge + bioconda. |
| `pyproject.toml` | create (repo root) | Project metadata. `[project]` with name=l3rseq, deps documented (even though conda installs them). `[tool.ruff]` rules (E,W,F,I,B), line-length=100. `[tool.mypy]` strict, python_version=3.12. `[tool.pytest.ini_options]` testpaths=["tests/python"]. |
| `src/l3rseq/__init__.py` | create | Empty package marker. |
| `src/l3rseq/py.typed` | create | PEP 561 marker so mypy treats the package as typed. |
| `tests/python/__init__.py` | create | Empty (lets pytest import sibling test modules). |
| `tests/python/conftest.py` | create | Shared fixtures: sample SAM line strings, synthetic 1000bp ref, intron specs. |
| `config.sh` | edit | Add `ENV_PY="l3rseq_py"` after line 95 (end of conda env block). Used by `_conda_run` in Phase 1b; harmless to define now. |
| `.devcontainer/claude-code/CLAUDE.md` | edit | Document the new env, new test command (`conda activate l3rseq_py && pytest tests/python/`), src/ layout, and the development-time fallback (`/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/` until image rebuild). Per existing CLAUDE.md instructions, this is the canonical tracked copy. |
| `.github/workflows/test.yml` | edit | Add `python-test` job parallel to `quick-test`: activates `l3rseq_py`, runs `ruff check src/ tests/python/`, `mypy src/l3rseq/`, `pytest tests/python/ -v --cov=src/l3rseq --cov-report=term-missing`. Marked `continue-on-error: true` initially because the published `:latest` image won't have the new env until *after* this commit's tag triggers the rebuild. Removed in a follow-up commit once verified. |

### Phase 1a — Algorithm modules (pure Python, no pysam imports)

| File | Action | Replaces | Notes |
|---|---|---|---|
| `src/l3rseq/cigar.py` | create | `scripts/09a_parse_cigar.sh` + `scripts/09d_rebuild_cigar.sh` | `parse_cigar(cigar_str) -> ParsedCigar` dataclass with `rightclip_n, total_m, total_d, ops`. `rebuild_cigar(cigar_str, match_counter) -> tuple[str, int]` returning `(new_cigar, new_tail_s)`. Pure string manipulation; tail-S clamped to 0 (matches `09d_rebuild_cigar.sh:26-28`). |
| `src/l3rseq/walk.py` | create | `scripts/09c_walk_correction.sh` | `walk_correction(ref_seq: str, ref_position: int, rightclip_seq: str, known_variants: set[str]) -> int`. Returns match counter. `known_variants` is loaded once by the caller from the var file (eliminates per-base `grep` from the bash version). |
| `src/l3rseq/variants.py` | create | `scripts/09e_call_variants.sh` | `call_variants(read_seq, cigar_str, ref_seq, aln_start, pattern, count_pattern) -> VariantResult` dataclass with `.variants_str, .ec, .sc, .nc`. Mirrors the awk CIGAR-walk semantics in 09e exactly: M/=/X consume both, I/S consume read, D/N consume ref. |
| `src/l3rseq/splice.py` | create | `scripts/09f_splice_check.sh` | `parse_introns(spec: str) -> list[Intron]` (handles shorthand `"500-2100"`, `"500-2100,3500-4200"`, BED, GFF3 with explicit-intron-or-infer-from-exons fallback). `check_splice(cigar, aln_start, introns) -> SpliceResult` (sj_pattern, si, ir, ±10bp tolerance, ≥80% length match per `09f_splice_check.sh:200-202`). `convert_intron_d_to_n(cigar, aln_start, introns) -> str`. |
| `tests/python/test_cigar.py` | create | mirrors `tests/test_shell_functions.sh:44-80` | Port the 7 hand-verified `run_rebuild_cigar` test cases from the shell suite directly: normal tail (500M55S+12→512M43S), multi-op body, S→0, S clamped from negative, zero counter, complex body (10M1I20D300M120S+60), full correction (450M60S+60→510M). Plus parse_cigar tests for trailing-S detection. |
| `tests/python/test_walk.py` | create | new | Synthetic 100bp ref + 20bp clip cases: full extend through matches, stop on mismatch, tolerate known variant, end-of-clip terminator, ref boundary. |
| `tests/python/test_variants.py` | create | new | Synthetic SAM line fixtures + ref: zero-mismatch, one-CT, multi-pattern (`CT,AG`), SC counting (TC pattern for SLAM), indel handling (I and D operations don't produce variants). |
| `tests/python/test_splice.py` | create | mirrors `tests/test_shell_functions.sh` parse_introns/check_splice block | Shorthand parsing (single + multi), multi-intron splice detection, S/R/- pattern, ±10bp tolerance edge cases, ≥80% length match, D→N conversion fidelity. |

### Files explicitly NOT touched this session

- `scripts/09_tail_correct.sh` and `scripts/09a–09f_*.sh` — left untouched. The pipeline still runs through them via `cmd_correct` in `L3Rseq:457`. The Python modules are dormant until Phase 1b wires them in via the dispatcher.
- `L3Rseq` dispatcher — no change to `cmd_correct` or `_conda_run`.
- `tests/run_tests.sh` and `tests/test_shell_functions.sh` — no change. The bash test suite still drives end-to-end coverage and is the regression baseline.
- BLAST integration — Phase 1b will use `subprocess.run(["blastn", ...])` to wrap blastn the same way the bash version does. Skipped here because the algorithm modules don't need it.
- Snakefile — deferred to a future session (Phase 2).

## Reuse / existing patterns

- **Test cases for `cigar.py`**: `tests/test_shell_functions.sh:44-80` has 7 hand-verified `run_rebuild_cigar` cases. Port these directly to `test_cigar.py` — they are the source of truth for the rebuild semantics.
- **Test cases for `splice.py`**: `tests/test_shell_functions.sh` `parse_introns` block (~lines 88-110+) covers shorthand parsing — port directly.
- **Walk algorithm reference**: `scripts/09c_walk_correction.sh` is short (55 lines). The Python implementation should match its termination conditions exactly: stop at first mismatch that isn't in `known_variants`, advance both pointers on match, break at `rightclip_position == rightclip_n`.
- **CIGAR walk semantics for `variants.py`**: `scripts/09e_call_variants.sh:33-56` is the awk source of truth. M/=/X consume both ref and read; I and S consume read only; D and N consume ref only. Variants are emitted as `"<pos><ref><alt>"` joined by `;`.
- **Logging convention**: existing scripts use `[Step NN]` and `[script_name]` prefixes via plain `echo`. New Python modules use `logging.getLogger("l3rseq.cigar")` etc., with format `"[%(name)s] %(message)s"` to match the visual style. Don't configure handlers at module level — let the eventual CLI entry point own logging configuration.

## Implementation order

0. **Persistence anchor (FIRST commit, before any other changes)**
   - Copy this plan file verbatim to `docs/PIPELINE_MODERNIZATION.md`. This commits the plan to the branch so it survives the eventual devcontainer rebuild.
   - Save a memory entry (`reference` type) pointing at `docs/PIPELINE_MODERNIZATION.md` so future Claude sessions discover it without re-deriving the plan.
   - Verify: `git log --oneline -1` shows the new commit; `cat docs/PIPELINE_MODERNIZATION.md | head -20` shows the plan header.

1. **Phase 0 — single commit, zero behavior change**
   - Dockerfile env block, pyproject.toml, `src/l3rseq/` skeleton, `tests/python/` skeleton, `config.sh ENV_PY`, CLAUDE.md update, CI job (with `continue-on-error: true`).
   - Verify: `bash tests/run_tests.sh --quick --no-viewer` still passes (confirms no regression in the existing pipeline).
   - Verify: `git diff --stat` shows only the expected files.

2. **Phase 1a modules in dependency order, one commit per module-test pair**
   1. `cigar.py` + `test_cigar.py` (foundational; no internal deps).
   2. `walk.py` + `test_walk.py` (depends only on string slicing).
   3. `variants.py` + `test_variants.py` (uses CIGAR walk; can share helper from `cigar.py`).
   4. `splice.py` + `test_splice.py` (uses CIGAR walk; can share helper from `cigar.py`).

   After each commit, run `/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/test_<module>.py -v` to confirm tests pass before moving on.

3. **End-of-session verification** — full pytest run + full bash test suite (`tests/run_tests.sh --quick --no-viewer`) — confirms no regression and all new tests pass.

4. **Hand-off** — branch is ready to push. Tagging a release (`git tag v1.1.3 && git push origin v1.1.3`) triggers `.github/workflows/docker-publish.yml` and starts the image rebuild. That's an explicit user action, not done automatically by this plan.

## Verification

### After Phase 0
```bash
# 1. Dockerfile syntactic check (offline; no rebuild needed)
grep -n "mamba create -y -n l3rseq_py" .devcontainer/build/Dockerfile

# 2. No regression in existing tests
bash tests/run_tests.sh --quick --no-viewer

# 3. Shellcheck still clean
shellcheck -e SC1090 -e SC1091 -e SC2034 -e SC2154 -e SC2155 -e SC2188 -e SC2320 -S warning L3Rseq scripts/*.sh

# 4. Diff scan: no unexpected file changes
git diff --stat
```

### After each Phase 1a module
```bash
# Use UMIC-seq's pytest 9.0.2 — confirmed working, has biopython but no pysam (we don't need pysam yet)
/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/test_cigar.py -v
/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/test_walk.py -v
/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/test_variants.py -v
/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/test_splice.py -v
```

### End-of-session (must all pass before hand-off)
```bash
# 1. All new pytest tests pass
/opt/miniforge/envs/UMIC-seq/bin/pytest tests/python/ -v

# 2. Existing bash tests still pass (no regression)
bash tests/run_tests.sh --quick --no-viewer
bash tests/test_shell_functions.sh

# 3. Branch is clean
git status
```

## Out of scope (deferred to future sessions)

| Phase | Scope | Trigger to start |
|---|---|---|
| **Phase 1b** | pysam I/O wrapper (`tail_correct.py`), BLAST subprocess wrapper (`blast.py`), CLI entry point, dispatcher switch (`cmd_correct` → Python), differential test vs. bash output, performance benchmark | New Docker image with `l3rseq_py` env is published and devcontainer rebuilt |
| **Phase 1c** | Decide bash-09 fate based on differential test + benchmark: delete `scripts/09*.sh` or move to `scripts/legacy/` | Phase 1b results in hand |
| **Phase 2** | Snakefile wrapping all 11 steps as `shell:` rules with per-rule `conda:`, sample discovery via `glob_wildcards()` or config.yaml, optional HPC profile | After Phase 1b lands |
| **Phase 3** | Pythonize step 11 (gene counting) using pysam + pyranges (replaces current samtools+awk overlap calc). Optionally Pythonize step 10 (CSV export) | After Phase 2 lands |
| **Phase 4** | Centralize parameters into `config.yaml` (Snakemake configfile) with three-tier override (CLI > YAML > defaults). Migrate `echo` → `logging` in all Python modules | After Phase 3 |

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Plan file lost when devcontainer rebuilds (Phase 1b session can't find it) | Step 0 of implementation commits a copy to `docs/PIPELINE_MODERNIZATION.md` on the bind-mounted `/workspace`. Branch name `pipeline-modernization` is also a recovery anchor. Memory entry pointing at the doc gives Claude a discoverable handle. |
| Python algorithm modules drift from bash semantics | Port the existing `tests/test_shell_functions.sh` cases verbatim to pytest. The differential test in Phase 1b will catch any remaining drift before the dispatcher switches. |
| `pytest 9.0.2` from UMIC-seq env is incompatible with our test code (very new major version) | Stick to vanilla pytest features (no advanced fixtures, no parameterize edge cases). If something breaks, fall back to a smaller test runner or wait for image rebuild. |
| New CI job fails on first push because the published image still has the old envs | `continue-on-error: true` on the new job. Remove that flag in a follow-up commit after image rebuild is verified. |
| Image rebuild adds ~1 GB and slows Codespaces first-pull | Acceptable cost per user decision (Q2). If too painful later, can split into runtime + dev envs (Phase 4 candidate). |
| `09e_call_variants.sh` awk uses `/dev/null` as sentinel (line 57) — easy to misread when porting | The Python port doesn't need this trick (no awk lookahead). Use a straightforward index-based loop. |
