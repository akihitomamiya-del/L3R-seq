# Legacy bash scripts

These scripts were replaced by Python equivalents during the pipeline
modernization (see `docs/PIPELINE_MODERNIZATION.md`).

They are retained here for:
- `tests/benchmarks/diff_step09.sh` (differential test: bash vs Python)
- `tests/test_shell_functions.sh` (unit tests for the bash CIGAR/splice/BLAST helpers)
- Git blame / history browsing

## Step 09 (tail correction)

Replaced by `src/l3rseq/tail_correct.py` (Phase 1b, merged as PR #3).

| Legacy file | Python replacement |
|---|---|
| `09_tail_correct.sh` | `src/l3rseq/tail_correct.py` (orchestrator) |
| `09a_parse_cigar.sh` | `src/l3rseq/cigar.py` |
| `09b_blast_rightclip.sh` | `src/l3rseq/blast.py` |
| `09c_walk_correction.sh` | `src/l3rseq/walk.py` |
| `09d_rebuild_cigar.sh` | `src/l3rseq/cigar.py` |
| `09e_call_variants.sh` | `src/l3rseq/variants.py` |
| `09f_splice_check.sh` | `src/l3rseq/splice.py` |
