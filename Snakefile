# L3Rseq pipeline — Snakemake orchestration
#
# Wraps the existing bash pipeline steps (scripts/01_*.sh .. scripts/11_*.sh)
# and the Python-backed step 09 (src/l3rseq/tail_correct.py) as per-sample
# Snakemake rules. The goal is resume-from-failure, DAG parallelism across
# {barcode, rpi} pairs, and per-rule conda env isolation — NOT a rewrite.
# Step bodies are unchanged; only inlined per-sample loops have been hoisted
# into `_process_sample_NN` functions so they can be called from `shell:`.
#
# See docs/PIPELINE_MODERNIZATION.md for the full Phase 2 plan.
#
# Usage (from repo root):
#   conda activate l3rseq_py
#   snakemake --cores 4 --use-conda --configfile config.yaml
#
# Dry-run the DAG without executing:
#   snakemake --cores 1 --configfile config.yaml --dry-run -p
#
# Run just through step 07:
#   snakemake --cores 4 --configfile config.yaml --until map
#
# Resume an interrupted run:
#   snakemake --cores 4 --configfile config.yaml  # same command, reuses checkpoints

from glob import glob
from pathlib import Path

configfile: "config.yaml"

# ---------------------------------------------------------------------------
# Paths + derived constants
# ---------------------------------------------------------------------------
REPO_DIR    = Path(workflow.basedir).resolve()
SCRIPTS_DIR = REPO_DIR / "scripts"
SRC_DIR     = REPO_DIR / "src"

INPUT_DIR  = config["input_dir"]
OUTPUT_DIR = config["output_dir"]
REF        = config["ref"]
RPI_FASTA  = config["rpi_fasta"]

# Conda env name map — mirrors config.sh ENV_*.
# Rule `conda:` directives use these names. Snakemake resolves them to
# /opt/miniforge/envs/<name> because these envs are pre-built in the
# devcontainer image (not created from an environment.yml at runtime).
ENVS = {
    "cutadapt":     "cutadaptenv",
    "umic_seq":     "UMIC-seq",
    "longread_umi": "longread_umi",
    "map":          "NanoporeMap",
    "lofreq":       "LoFreq",
    "python":       "l3rseq_py",
}

def umi_env(wildcards=None):
    """Pick the step-04 env based on config['umi_method']."""
    return ENVS["longread_umi"] if config["umi_method"] == "longread-umi" else ENVS["umic_seq"]

# ---------------------------------------------------------------------------
# Sample discovery
# ---------------------------------------------------------------------------
# Barcodes are known upfront from the input FASTQ tree.
# RPI names exist only AFTER step 03 has run — see `checkpoint demux` below.
BARCODES, = glob_wildcards(f"{INPUT_DIR}/{{barcode}}/")
# Deduplicate + sort for reproducible DAG rendering.
BARCODES = sorted({b for b in BARCODES if b and "/" not in b})

def rpis_for(barcode):
    """Return list of RPI names for a given barcode, triggering the demux
    checkpoint if needed."""
    ck = checkpoints.demux.get(barcode=barcode).output[0]
    _, rpis = glob_wildcards(f"{ck}/{{bc}}_{{rpi}}.fastq")
    return sorted(set(rpis))

def all_sample_pairs(wildcards=None):
    """Return dict of parallel lists {'barcode': [...], 'rpi': [...]} covering
    every (barcode, rpi) pair in the run. Used by `expand(..., zip, **)`."""
    pairs = [(b, r) for b in BARCODES for r in rpis_for(b)]
    return {"barcode": [p[0] for p in pairs], "rpi": [p[1] for p in pairs]}

def corrected_bams(wildcards=None):
    p = all_sample_pairs()
    return expand(
        f"{OUTPUT_DIR}/09_correct/{{barcode}}/{{rpi}}/{{rpi}}_corrected.sort.bam",
        zip, barcode=p["barcode"], rpi=p["rpi"],
    )

def csv_outputs(wildcards=None):
    p = all_sample_pairs()
    return expand(
        f"{OUTPUT_DIR}/10_csv/{{barcode}}_{{rpi}}.csv",
        zip, barcode=p["barcode"], rpi=p["rpi"],
    )

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------
# `rule all`'s input list determines what a bare `snakemake` invocation builds.
# We include the step-10 CSVs (per-sample terminal artifact) and, if a regions
# file is configured, the step-11 merged gene counts (run-wide terminal).
def all_targets(wildcards=None):
    targets = list(csv_outputs())
    if config.get("regions"):
        targets.append(f"{OUTPUT_DIR}/11_count/gene_counts_all.tsv")
    return targets

# NOTE: `rule all`'s input is [] until the demux checkpoint + downstream rules
# land (they're added in a follow-up commit on this branch). Once they exist,
# swap this to `input: all_targets,` to enable full-pipeline runs.
rule all:
    input:
        [],

# ---------------------------------------------------------------------------
# Rules are added incrementally, one step at a time. See the per-rule commits
# on the snakefile-wrap branch. Until all rules land, invoke specific targets
# with `snakemake <path>` to test the partial DAG.
# ---------------------------------------------------------------------------
