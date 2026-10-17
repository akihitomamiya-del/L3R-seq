# Troubleshooting

Common issues and solutions for the L3Rseq pipeline.

---

## Conda activation errors

**Symptom**: `CondaError: environment not found` or `ModuleNotFoundError` when
running pipeline steps.

**Cause**: Conda environments are pre-built in the Docker image and are
read-only. Do not attempt to create, modify, or reinstall them.

**Solution**: Use the correct environment name. Available environments:
`longread_umi`, `cutadaptenv`, `NanoporeMap`, `LoFreq`, `UMIC-seq`, `Entrez`,
`analysis`. The `L3Rseq` dispatcher activates them automatically -- you only
need manual activation when running tools outside the pipeline:

```bash
conda activate NanoporeMap && samtools view file.bam
```

---

## Network restrictions in the devcontainer

**Symptom**: `apt-get install`, `pip install`, or `curl` to external URLs fails
with connection timeout or refused errors.

**Cause**: The container runs behind a firewall that blocks most outbound
traffic. Only GitHub (`github.com`, `ghcr.io`), npm (`registry.npmjs.org`), and
Anthropic APIs are allowed.

**Solution**: All required tools are pre-installed in the Docker image. If you
need an additional package, add it to the Dockerfile and rebuild the image
rather than installing at runtime.

---

## Viewer not starting

**Symptom**: `http://localhost:8080` returns connection refused or blank page.

**Cause**: Port 8080 occupied by a stale process, or the server crashed.

**Solution**:

```bash
L3Rseq viewer --stop                    # kill stale process
L3Rseq viewer --dir tests/output/demo   # restart
cat /tmp/igv-server.log                 # check for errors
```

In Codespaces or VS Code Remote, check the Ports tab for port 8080 forwarding.

---

## racon SIGILL on Apple Silicon

**Symptom**: `racon` crashes with `Illegal instruction (core dumped)` on Macs
with Apple Silicon (M1/M2/M3).

**Cause**: The pre-built racon binary uses x86_64 instructions that are
incompatible with ARM under emulation.

**Solution**: Rebuild the Docker image with explicit platform targeting:

```bash
docker build --platform linux/amd64 -t l3rseq .
```

Or use a native ARM build of racon if available in your conda channels.

---

## BLAST database setup

**Symptom**: Step 09 skips BLAST or reports `BLAST database not found`.

**Cause**: Large BLAST databases (TAIR10) are not in the repo -- build locally.

**Solution**:

```bash
# From TAIR10 (requires Entrez env)
conda activate Entrez && bash scripts/setup_blast_db.sh

# From a custom genome FASTA
conda activate longread_umi
makeblastdb -in my_genome.fasta -dbtype nucl -out resources/blast/mydb/mydb_db
```

Pass `--blast-db resources/blast/mydb/mydb_db` to `L3Rseq run` or `L3Rseq correct`.
Mock databases for testing are in `resources/blast/mock_chrm/` and `mock_cdna/`.

---

## Empty pipeline output

**Symptom**: Pipeline steps complete but output directories are empty or contain
no reads.

**Cause**: Usually an input directory structure mismatch. The pipeline expects
the barcode/RPI hierarchy created by steps 01-03.

**Solution**:

1. Verify input structure: `<outdir>/03_demux_all/<barcode>/<RPI>/reads.fastq.gz`
2. Check the RPI barcode file matches your library prep
3. For re-runs, `rm -rf runs/MyRun` first -- leftover `03_demux_all/` breaks
   RPI filtering
4. Check the log file (`l3rseq_*.log` in the output directory)

---

## Many molecules lost at step 06 (consensus starts inside or after the primer)

**Symptom**: For some genes, step 06 (target extraction) keeps only a fraction
of the UMI consensus sequences (e.g. 30-60%), while other genes keep >95%. The
discarded consensus sequences map to the target, but their 5' ends start at a
fixed position just inside or after the `target_fwd` primer.

**Cause**: racon's default consensus end-trimming (step 05). Each read is
aligned to the seed from its first shared minimizer, so the first bases of the
seed look uncovered and racon trims them; repeated polishing rounds can cut
further. The cut position depends only on the sequence, so it is the same for
every molecule of a gene. Step 06 requires the primer at the 5' end
(`^target_fwd`), so those molecules are discarded. The raw reads are fine.

**Check**: map the step-05 consensus to the reference and look at the 5' start
positions; or compare `05_consensus` counts with `06_extract` counts per RPI.

**Solution**: disable racon's trimming and re-run from step 05:

```yaml
consensus_racon_args: "--no-trimming"
```

(`L3Rseq consensus --racon-args --no-trimming` for the standalone subcommand.)
The consensus body is unchanged; only the trimmed ends are kept.

---

## Editing sites missing from step 08 on spliced genes

**Symptom**: For an intron-containing gene mapped with `splice:hq`, the step-08
site list (`08_variants/<bc>/<rpi>/observed_variants.txt`) lacks sites that
many molecules clearly carry (compare with the `All_mismatches` column of the
step-10 CSV).

**Cause**: LoFreq's BAQ (base alignment quality) recalibration on alignments
that contain `N` (intron) operations down-weights real mismatches.

**Effect**: Per-molecule editing counts and `All_mismatches` are computed from
the alignments and are not affected. Step 09's tail correction uses the step-08
list to tolerate edited bases in the 3' soft clip, so molecules ending just
before a missed site can get an overstated 3' tail.

**Solution**: disable BAQ and re-run from step 08:

```yaml
lofreq_args: "--no-baq"
```

(`L3Rseq variants --lofreq-args --no-baq` for the standalone subcommand.) On
unspliced genes this changes the site list little or not at all.

---

## Reads assigned to the wrong RPI of a close pair

**Symptom**: none visible — step 03 reports nothing unusual. A few reads per
sample carry a barcode that is one edit from two RPIs.

**Cause**: `demux_error_rate: 1` allows one edit, insertions and deletions
included. The 36 standard RPIs differ at 3 or more positions, but 12 pairs are
only 2 edits apart once indels count (RPI_1/RPI_9, RPI_7/RPI_31, RPI_8/RPI_12,
RPI_8/RPI_25, RPI_11/RPI_24, RPI_13/RPI_15, RPI_14/RPI_27, RPI_25/RPI_31,
RPI_26/RPI_34, RPI_29/RPI_32, RPI_29/RPI_36, RPI_33/RPI_34). Example: RPI_1
(index `CGTGAT`) with its G deleted and RPI_9 (`CTGATC`) with its C deleted
both read `ACGAGATCTGATGTGACTG`. cutadapt gives such a read to the RPI listed
first in `rpi_fasta`.

**Effect**: only libraries that use both RPIs of a pair. On PacBio HiFi data
0.03-0.31% of reads were tied. With `umi_size_thresh` >= 2 a misassigned read
is usually a singleton UMI in the wrong sample and is dropped, so molecule
counts barely change; read-level and UMI-bin statistics shift slightly.

**Solution**: set `demux_drop_ambiguous: true` (`L3Rseq demux --drop-ambiguous`
for the standalone subcommand) and re-run from step 03. Tied reads go to
`03_demux/<bc>/<bc>_unclassified_ambiguous.fastq`, counted per RPI in
`<bc>_ambiguous_report.tsv`. `cutadapt --no-indels` also removes the ties but
discards every read with a barcode indel (~4.4% of HiFi reads).

---

## "Unknown option" errors

**Symptom**: `ERROR: unknown option --foo` when running a subcommand.

**Cause**: Options vary by subcommand. Using a flag with the wrong subcommand
triggers this error.

**Solution**: Check the help for the specific subcommand:

```bash
L3Rseq run --help
L3Rseq count --help
L3Rseq regions --help
L3Rseq viewer --help
```

Common mistakes:
- `--pattern` is for `L3Rseq run` / `L3Rseq variants`, not `L3Rseq count`
- `--regions` is for `L3Rseq count`, not `L3Rseq run`
- `--method` is for `L3Rseq run` / `L3Rseq umi`, not other subcommands
- `--dir` is for `L3Rseq viewer`, not `L3Rseq run` (use `--outdir` instead)

---

## Viewer shows no tracks / "No BAM files found"

The viewer discovers datasets by scanning for directories containing `07_map/`
or `09_correct/`. BAM files must be sorted and indexed (`.sort.bam` +
`.sort.bam.bai`). Verify files exist, restart the viewer with `L3Rseq viewer
--stop && L3Rseq viewer --dir <outdir>`, and check what the server sees via
`curl http://localhost:8080/api/datasets`.
