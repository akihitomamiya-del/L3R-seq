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
