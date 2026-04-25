# REP3 Comparison — Limitations From Missing Reference

Captured: 2026-04-24. Context: running `/workspace/REP3_E201015_2_read_processing`
through the current L3Rseq pipeline (longread-umi method on ext4 parallel
strategy) and comparing against the stored old UMIC-seq output in the
same directory.

## What's missing

The old REP3 analysis mapped consensus reads against
**`ccb3CDS+downstream.fasta`** — a 7717 bp custom target reference.
The old minimap2 log (embedded in BAM headers) shows the original path:

```
/home/N3Rseq_Inputs/Run_N3Rseq/ccb3CDS+downstream.fasta
```

That path was on a different machine; the file was never copied into
this repo. Searched thoroughly:

- `/workspace/resources/references/` — no match
- `/workspace/resources/probes/` — no match
- `/workspace/REP3_E201015_2_read_processing/` — no match (only
  `cutadapt_ccb3/` subdirs holding per-RPI trimmed reads, not the ref)
- Broad `find /workspace -name 'ccb3*.fa*'` — only the trimmed-read
  outputs, no reference

## Attempted workaround (failed)

Tried reconstructing the reference from mapped reads using
`samtools merge` + `samtools consensus` across all 18 REP3 BAMs:

| | |
|---|---|
| Merged reads | 35,582 primary alignments |
| Positions with ≥1 read | 846 / 7717 |
| Reconstructable fraction | ~11% |

The ccb3 amplicon only covers a narrow window of the 7717 bp reference,
so `samtools consensus` can reconstruct just the covered region, not
the flanking sequence. A partial 846-bp reconstruction is stored at
`/tmp/ccb3_recon.fa` for in-session use but is not suitable as the
target reference for a rerun because:

- Step 07 minimap2 output won't be byte-comparable to the old BAMs
  (different reference length, different @SQ length field).
- Read coordinates in the output BAMs would shift — the reconstructed
  reference covers offset ~N through ~N+846, not the full 7717 bp span.
- If the old UMIC-seq comparison was built against positions in the
  original reference, numbers won't line up.

## What we CAN confirm without the reference

Steps 04 (UMI binning) and 05 (consensus) do **not** require the
target reference. Meaningful comparisons possible:

| Comparison | Metric | Meaning |
|---|---|---|
| Old UMIC-seq vs new longread-umi | consensus count per RPI | Shape/scale of recovery under different UMI methods |
| Old UMIC-seq vs new longread-umi | total consensus across all RPIs | Overall pipeline throughput |
| Old UMIC-seq vs new longread-umi | per-RPI correlation | Whether high-yield samples track the same way |
| new UMIC-seq vs new longread-umi | same as above | Isolates method effect (same codebase) |
| old UMIC-seq vs new UMIC-seq | consensus count per RPI | Isolates pipeline-version effect |

The user's stated expectation: *"the output will slightly differ… the
overall results should look the same"* — meaning we're looking for
correlation and same shape, not byte-identical output. The
reference-free comparison captures that adequately.

## What we CANNOT confirm without the reference

The following comparisons were planned but **skipped or deferred**:

### Step 06 — Target region extraction

- Old pipeline's `cutadapt_ccb3` step extracted the ccb3 amplicon using
  primer sequences (not the reference fasta — but the reference was
  needed downstream, see Step 07).
- Without the primers used for the original library prep, step 06 can't
  be reliably parameterized.
- Workaround: the `.fa` files in `cutadapt_ccb3/` hold the old extracted
  reads and could be used as a reference-free quality check, but aren't
  directly comparable to new step-06 output.

### Step 07 — Mapping to reference

- Requires ccb3CDS+downstream.fasta.
- Metrics we couldn't produce:
  - Primary-mapped read count per RPI (old totals: 406-4232 per RPI)
  - `pipeline_summary.tsv` `07 mapped_reads` rows
  - BAM header vs old BAM header (chromosome list, length)
  - Per-position coverage shape
- **Action item for future:** once the reference is found, re-run with
  `L3Rseq run --ref <ccb3.fasta> --start-at 6 --stop-at 7` on the
  existing `05_consensus/` output. Step 06 may still need primer info;
  if just `--no-target-fwd` the consensus reads feed into step 07
  directly.

### Step 08-09 — Variant calling + tail correction

- Step 09 is the pythonized algorithmic core we want to validate on
  real data.
- Needs the reference (step 08 uses `LoFreq`, step 09 uses CIGAR walks).
- **Deferred until reference is available.**

### Step 10-11 — Export + gene counting

- Gene counting requires regions.tsv derived from a GFF. The old REP3
  run predates the gene-counting feature, so there's no stored
  comparison target anyway — even with the reference, this would be a
  one-sided measurement, not a comparison.

## Recommended action items

1. **Locate `ccb3CDS+downstream.fasta`** — probably on the original
   analysis machine (`/home/N3Rseq_Inputs/Run_N3Rseq/`). Ask whoever
   ran the original analysis.
2. Once found, add it to `resources/references/` (or a sibling
   untracked location).
3. Rerun the current longread-umi output through steps 06-07-(09):
   ```bash
   L3Rseq run --input /home/vscode/runs/rep3_test \
              --outdir /home/vscode/runs/rep3_test \
              --ref resources/references/ccb3CDS+downstream.fasta \
              --no-target-fwd \
              --start-at 6 --stop-at 9
   ```
4. Diff mapped-read counts vs the old `pipeline_summary.tsv`-style
   extraction (the old output didn't use that format; derive from BAM
   flagstats).

## Cross-references

- `docs/pipeline_speed_investigation.md` — FS + parallelism findings
  from the LibCheck session, same infrastructure used here.
- `docs/pipeline_fast_storage_plan.md` — storage rollout plan.
- `runs/step04_fs_benchmarks.tsv` — benchmark log (REP3 timings will
  be appended once this run completes).
- `/home/vscode/runs/rep3_test/` — the ext4 output dir being compared
  against the stored old output.
