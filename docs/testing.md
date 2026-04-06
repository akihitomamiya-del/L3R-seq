# Testing

Internal reference for test suite structure, coverage gaps, and known issues.

## Running tests

```bash
bash tests/run_tests.sh --quick            # Smoke test (~26s) — good for CI
bash tests/run_tests.sh --skip-preprocess  # Skip steps 01-03 (~30s)
bash tests/run_tests.sh                    # Full suite, 156 checks (~45s)
bash tests/test_shell_functions.sh         # Unit tests only (~1s)
```

Use `--test N` or `--test NAME` to run a single test block.

## Test blocks

| Block | Scope | Skipped by |
|-------|-------|-----------|
| TEST 1 | Steps 01-03 (preprocess) | `--skip-preprocess` |
| TEST 1b | Filter step | `--skip-preprocess` |
| TEST 1c | Negative/error tests | never (always runs) |
| TEST 2 | Steps 04-10, CT pattern | never |
| TEST 2b | CT,AG dual pattern | `--quick` |
| TEST 3 | SLAM-seq + count-pattern | `--quick` |
| TEST 4 | Splicing + introns | `--quick` |
| TEST 5 | BLAST + walk correction | `--quick` |
| TEST 6 | IGV viewer API | `--quick` |
| TEST 7 | Plot generation | `--quick` |
| TEST 8 | Gene counting (step 11) + splice-aware counting (8f) | `--quick` |

## Coverage gaps (as of 2026-04-04)

### High impact — functional code never exercised

| # | Feature | Risk |
|---|---------|------|
| 1 | `--method umic-seq` with actual data | Entirely different UMI pipeline (`UMIC-seq` conda env). Only the missing-`--probe` error path is tested (Test 1c). |
| 2 | `--no-target-fwd` | Changes step 06 extraction to skip forward primer. Never invoked in any test. |
| 3 | `regions --gff` / `--discover-from` / `--append` | Major real-world features for gene counting. Only `--coordinates` and `--bed` are tested (Test 8). |
| 4 | `count --min-mapq` | MAPQ filtering for homologue families. Always defaults to 0 in tests. |
| 5 | Multi-gene counting (step 11) | Main pipeline test has 1 gene (`test_gene`). Test 8f adds splice-aware counting with 3 regions (exon1/intron/exon2) on the splice dataset. Real-world multi-gene with overlapping regions and cross-gene isoform discovery remain untested. |
| 6 | Multi-chromosome references | All tests use single-contig `test_gene.fasta`. Multi-chromosome FAI reference matching in the viewer and step 07 is untested. |
| 7 | `validate_introns()` | Input validation function (L3Rseq:120-163) for BED format, `start >= end`, bad extensions, empty files — never called in tests. |
| 8 | `--prefilter` inside `L3Rseq run` | Standalone `filter` is tested (Test 1b), but the `--prefilter` flag that runs it as part of `run` is never invoked. |

### Medium impact — standalone subcommand routing

All 10 standalone subcommands (`concat`, `trim`, `demux`, `umi`, `consensus`,
`extract`, `map`, `variants`, `correct`, `export`) are only tested via
`L3Rseq run`. Their standalone entry points (argument parsing, input
validation) are never exercised with actual data. Dispatcher `--help` tests
also miss 5 subcommands: `filter`, `umi`, `consensus`, `extract`,
`discover-introns`, `viewer`.

### Low impact — edge cases and defensive paths

| Feature | Notes |
|---------|-------|
| `--start-at > --stop-at` | Silent no-op, no validation or error |
| `--verbose` | Alters stderr routing only |
| Empty FASTQ / malformed BAM input | No defensive tests |
| Invalid `--pattern` values (e.g., "XY") | Passes through unchecked to LoFreq/step 09 |
| `--prefix`, `--target-fwd/rev`, `--var` overrides | Always use defaults in tests |
| DS:i: tag in SAM/CSV output | Never explicitly validated |
| Combined SLAM + splice + BLAST in one run | Each tested in isolation, never combined |
| Step 09 with `--introns` but zero spliced reads | Splice test always includes spliced reads |
| Step 10 TL column value validation | Column exists but values not checked in CSV |

## Dispatcher test coverage

The `L3Rseq` dispatcher (argument parsing, subcommand routing, `--help` output)
is tested in `tests/test_dispatcher.sh`. Remaining gaps:

- Invalid argument combinations (e.g., `--ref` without a file)
- `--start-at` / `--stop-at` range validation
- Help text for individual subcommands (`L3Rseq map --help`)

## Linting

Shell scripts are not currently linted. Adding shellcheck would catch common
bugs (unquoted variables, incorrect test operators, unreachable code).

```bash
# Manual shellcheck run (shellcheck must be installed)
shellcheck -x L3Rseq scripts/*.sh longread_umi_L3Rseq/scripts/*.sh
```

Known: `scripts/04_umi.sh` line 166 has one intentional `# shellcheck disable=SC2086`
for unquoted expansion.

## Known issues (as of 2026-04-04)

### Pipeline logic

| # | Severity | File : Line | Description |
|---|----------|-------------|-------------|
| P1 | Medium | `scripts/11_count.sh:96` | **Coverage depth ignores `--min-mapq`.** `samtools depth` is called without `-Q`, so low-MAPQ reads inflate coverage plots even when `--min-mapq` filters them from gene counts. Fix: pass `min_mapq` to `generate_coverage` and add `-Q "$min_mapq"`. |
| P2 | Low | `L3Rseq:937` | **Step 07 intermediate cleanup is a no-op.** After commit `53b478e` renamed outputs to include the RPI prefix, `rm -f aligned.sam aligned.bam` no longer matches `${rpi_name}_aligned.sam`. Intermediates are never cleaned. Fix: `rm -f "$_rpi_dir"/*_aligned.sam "$_rpi_dir"/*_aligned.bam`. |
| P3 | Low | `scripts/11_count.sh:148` | **Fallback BAM discovery uses old naming.** Globs for `*/primary.sort.bam` but post-rename files are `*_primary.sort.bam`. Only affects the edge case of passing a non-standard directory to `L3Rseq count`. Fix: `*/*_primary.sort.bam`. |

### Test suite

All items fixed in commit `5820e8f`.

| # | Status | Description |
|---|--------|-------------|
| T1 | **Fixed** | Variant check now sample-aware — RPI_1 asserts non-empty, RPI_2 accepts empty. |
| T2 | **Fixed** | `check_range` floors lower bound at 1 when expected > 0. |
| T3 | **Fixed** | Three `grep -c` calls guarded with `\|\| true`. |
| T4 | **Fixed** | Test 1b split into own `should_run 1b` block. |
| T5 | **Fixed** | `OUT` set as default before test blocks; `--test` without value errors. |
| T6 | **Fixed** | Row count uses `tail -n +2 \| wc -l` instead of `grep -cv '^gene'`. |

### Documentation

| # | File | Description |
|---|------|-------------|
| D1 | `.devcontainer/claude-code/CLAUDE.md:139` | Says "Step 09 uses `set +e` (not pipefail)" but since commit `e93b94c` the file uses `set -euo pipefail` with `set +e` only inside the per-read worker function. |
