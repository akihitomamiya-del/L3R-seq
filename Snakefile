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
# Discover barcodes by listing the input directory directly. `glob_wildcards`
# with a trailing-slash pattern misses directories on some filesystems; a
# plain listdir is deterministic and obvious.
import os as _os
BARCODES = sorted(
    d for d in _os.listdir(INPUT_DIR)
    if _os.path.isdir(f"{INPUT_DIR}/{d}") and not d.startswith(".")
) if _os.path.isdir(INPUT_DIR) else []

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

rule all:
    input:
        # Force demux to run for every barcode up front. This lets all demux
        # checkpoints be scheduled in parallel rather than sequentially
        # discovered (Snakemake's `checkpoints.X.get()` short-circuits the
        # first time it hits an unresolved checkpoint in a list comprehension).
        expand(f"{OUTPUT_DIR}/03_demux/{{barcode}}", barcode=BARCODES),
        # Then the actual terminal targets — these defer through the
        # checkpoints that just ran above.
        all_targets,

# ---------------------------------------------------------------------------
# Conda env activation helper
# ---------------------------------------------------------------------------
# The pre-built conda envs in this container live under /opt/miniforge/envs/.
# Snakemake's `conda:` directive expects a YAML file or prefix path, so we
# activate envs manually inside `shell:` blocks using the same pattern as the
# dispatcher's `_conda_run`. The `_summary_append` no-op stub suppresses the
# "command not found" warnings from step scripts that normally see the
# dispatcher's summary-writer function.
def _shell_preamble(env):
    # Braces are doubled so Snakemake's {}-format pass leaves them literal.
    return (
        "set -euo pipefail; "
        "_summary_append() {{ :; }}; "
        "export -f _summary_append; "
        "source /opt/miniforge/etc/profile.d/conda.sh; "
        f"conda activate {env}; "
    )

# ---------------------------------------------------------------------------
# Step 01 — concat per-barcode fastq.gz
# ---------------------------------------------------------------------------
rule concat:
    input:
        lambda wc: sorted(glob(f"{INPUT_DIR}/{wc.barcode}/*.fastq.gz")),
    output:
        f"{OUTPUT_DIR}/01_concat/{{barcode}}.fastq.gz",
    params:
        prefix=config.get("concat_prefix", ""),
    shell:
        r"""
        set -euo pipefail
        _summary_append() {{ :; }}; export -f _summary_append
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT
        mkdir -p "$tmp/{wildcards.barcode}"
        for f in {input}; do ln -sf "$(readlink -f "$f")" "$tmp/{wildcards.barcode}/"; done
        source {SCRIPTS_DIR}/01_concat.sh
        run_step_01 "$tmp" "{OUTPUT_DIR}" "{params.prefix}"
        """

# ---------------------------------------------------------------------------
# Step 02 — 3-pass cutadapt adapter trimming
# ---------------------------------------------------------------------------
rule trim:
    input:
        rules.concat.output,
    output:
        f"{OUTPUT_DIR}/02_trim/{{barcode}}/{{barcode}}_trim3.fastq.gz",
    params:
        fwd=config["adapter_fwd"],
        rev=config["adapter_rev"],
        trim3=config["adapter_trim3"],
        er=config["error_rate"],
    shell:
        _shell_preamble(ENVS["cutadapt"]) + r"""
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT
        ln -sf "$(readlink -f {input})" "$tmp/{wildcards.barcode}.fastq.gz"
        source {SCRIPTS_DIR}/02_trim.sh
        run_step_02 "$tmp" "{OUTPUT_DIR}" '{params.fwd}' '{params.rev}' '{params.trim3}' '{params.er}'
        """

# ---------------------------------------------------------------------------
# Step 03 — RPI demultiplexing (CHECKPOINT — fans out {rpi} wildcard)
# ---------------------------------------------------------------------------
checkpoint demux:
    input:
        rules.trim.output,
    output:
        directory(f"{OUTPUT_DIR}/03_demux/{{barcode}}"),
    params:
        rpi_fasta=RPI_FASTA,
        er=config["demux_error_rate"],
        mo=config["demux_min_overlap"],
    shell:
        _shell_preamble(ENVS["cutadapt"]) + r"""
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT
        mkdir -p "$tmp/{wildcards.barcode}"
        ln -sf "$(readlink -f {input})" "$tmp/{wildcards.barcode}/{wildcards.barcode}_trim3.fastq.gz"
        source {SCRIPTS_DIR}/03_demultiplex.sh
        run_step_03 "$tmp" "{OUTPUT_DIR}" "{params.rpi_fasta}" "{params.er}" "{params.mo}"
        """

# ---------------------------------------------------------------------------
# Step 04 — UMI extraction/clustering (internally parallel via starcode)
# ---------------------------------------------------------------------------
rule umi:
    input:
        f"{OUTPUT_DIR}/03_demux/{{barcode}}/{{barcode}}_{{rpi}}.fastq",
    output:
        directory(f"{OUTPUT_DIR}/04_umi/{{barcode}}/{{rpi}}/UMIclusterfull"),
    params:
        method=config["umi_method"],
        umi_len=config["umi_len"],
        flank5=config["umi_flank5"],
        flank3=config["umi_flank3"],
        size_thresh=config["umi_size_thresh"],
        cluster_steps=config["umi_cluster_steps"],
        sample_size=config["umi_sample_size"],
        umi_loc=config["umi_loc"],
        min_probe=config["umi_min_probe_score"],
        aln_thresh=config["umi_aln_thresh"],
        probe=config.get("umi_probe", ""),
    threads: config["threads"]["umi"]
    shell:
        # env selected at runtime based on method
        r"""
        set -euo pipefail
        _summary_append() {{ :; }}; export -f _summary_append
        source /opt/miniforge/etc/profile.d/conda.sh
        if [ "{params.method}" = "longread-umi" ]; then
            conda activate longread_umi
        else
            conda activate UMIC-seq
        fi
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT
        mkdir -p "$tmp/{wildcards.barcode}"
        ln -sf "$(readlink -f {input})" "$tmp/{wildcards.barcode}/{wildcards.barcode}_{wildcards.rpi}.fastq"
        source {SCRIPTS_DIR}/04_umi.sh
        run_step_04 "$tmp" "{OUTPUT_DIR}" \
            "{params.probe}" "{params.umi_len}" "{params.umi_loc}" \
            "{params.min_probe}" "{params.aln_thresh}" "{params.size_thresh}" \
            "{params.cluster_steps}" "{params.sample_size}" "{params.method}" \
            "{params.flank5}" "{params.flank3}"
        """

# ---------------------------------------------------------------------------
# Step 05 — racon consensus calling
# ---------------------------------------------------------------------------
rule consensus:
    input:
        rules.umi.output,
    output:
        touch(f"{OUTPUT_DIR}/05_consensus/{{barcode}}/{{rpi}}/.done"),
    params:
        rounds=config["consensus_rounds"],
        preset=config["consensus_preset"],
    threads: config["threads"]["consensus"]
    shell:
        _shell_preamble(ENVS["longread_umi"]) + r"""
        tmp=$(mktemp -d)
        trap "rm -rf $tmp" EXIT
        mkdir -p "$tmp/{wildcards.barcode}/{wildcards.rpi}"
        ln -sfn "$(readlink -f {input})" "$tmp/{wildcards.barcode}/{wildcards.rpi}/UMIclusterfull"
        source {SCRIPTS_DIR}/05_consensus.sh
        run_step_05 "$tmp" "{OUTPUT_DIR}" "{threads}" "{params.rounds}" "{params.preset}"
        """

# ---------------------------------------------------------------------------
# Step 06 — target sequence extraction (has existing _process_sample_06 hook)
# ---------------------------------------------------------------------------
rule extract:
    input:
        rules.consensus.output,
    output:
        f"{OUTPUT_DIR}/06_extract/{{barcode}}/{{rpi}}/{{rpi}}_extracted_trimmed.fa",
    params:
        fwd=config["target_fwd"],
        rev=config["target_rev"],
        er=config["error_rate"],
        mo=config["target_min_overlap"],
        cons_dir=lambda wc: f"{OUTPUT_DIR}/05_consensus/{wc.barcode}/{wc.rpi}",
    shell:
        _shell_preamble(ENVS["cutadapt"]) + r"""
        source {SCRIPTS_DIR}/06_extract.sh
        _process_sample_06 "{wildcards.barcode}" "{wildcards.rpi}" "{params.cons_dir}" \
            "{OUTPUT_DIR}" '{params.fwd}' '{params.rev}' "{params.er}" "{params.mo}"
        """

# ---------------------------------------------------------------------------
# Step 07 — minimap2 mapping (has existing _process_sample_07 hook)
# ---------------------------------------------------------------------------
rule map:
    input:
        fa=rules.extract.output,
        ref=REF,
    output:
        f"{OUTPUT_DIR}/07_map/{{barcode}}/{{rpi}}/{{rpi}}_primary.sort.bam",
    params:
        preset=config["map_preset"],
        extract_dir=lambda wc: f"{OUTPUT_DIR}/06_extract/{wc.barcode}/{wc.rpi}",
    threads: config["threads"]["map"]
    shell:
        _shell_preamble(ENVS["map"]) + r"""
        source {SCRIPTS_DIR}/07_map.sh
        _process_sample_07 "{wildcards.barcode}" "{wildcards.rpi}" "{params.extract_dir}" \
            "{OUTPUT_DIR}" "{input.ref}" "{params.preset}"
        """

# ---------------------------------------------------------------------------
# Step 08 — LoFreq variant calling (has existing _process_sample_08 hook)
# ---------------------------------------------------------------------------
rule variants:
    input:
        bam=rules.map.output,
        ref=REF,
    output:
        f"{OUTPUT_DIR}/08_variants/{{barcode}}/{{rpi}}/observed_variants.txt",
    params:
        min_af=config["min_af"],
        pattern=config["pattern"],
        map_dir=lambda wc: f"{OUTPUT_DIR}/07_map/{wc.barcode}/{wc.rpi}",
    shell:
        _shell_preamble(ENVS["lofreq"]) + r"""
        source {SCRIPTS_DIR}/08_variants.sh
        _process_sample_08 "{wildcards.barcode}" "{wildcards.rpi}" "{params.map_dir}" \
            "{OUTPUT_DIR}" "{input.ref}" "{params.min_af}" "{params.pattern}"
        """

# ---------------------------------------------------------------------------
# Step 09 — Python-backed tail correction (no shell wrapper; direct module call)
# ---------------------------------------------------------------------------
rule correct:
    input:
        bam=rules.map.output,
        var=rules.variants.output,
        ref=REF,
    output:
        f"{OUTPUT_DIR}/09_correct/{{barcode}}/{{rpi}}/{{rpi}}_corrected.sort.bam",
    params:
        pattern=config["pattern"],
        count_pattern=config.get("count_pattern", ""),
        introns=config.get("introns", ""),
        clip_thresh=config["clip_thresh"],
        blast_db=config.get("blast_db", ""),
        blast_db2=config.get("blast_db2", ""),
        map_dir=lambda wc: f"{OUTPUT_DIR}/07_map/{wc.barcode}/{wc.rpi}",
    threads: config["threads"]["correct"]
    shell:
        _shell_preamble(ENVS["python"]) + r"""
        extra=""
        [ -n "{params.count_pattern}" ] && extra="$extra --count-pattern {params.count_pattern}"
        [ -n "{params.introns}"       ] && extra="$extra --introns {params.introns}"
        [ -n "{params.blast_db}"      ] && extra="$extra --blast-db {params.blast_db}"
        [ -n "{params.blast_db2}"     ] && extra="$extra --blast-db2 {params.blast_db2}"
        PYTHONPATH={SRC_DIR} python -m l3rseq.tail_correct \
            --input "{params.map_dir}" \
            --outdir "{OUTPUT_DIR}/09_correct/{wildcards.barcode}/{wildcards.rpi}" \
            --ref "{input.ref}" \
            --pattern "{params.pattern}" \
            --clip-thresh "{params.clip_thresh}" \
            --threads "{threads}" \
            $extra
        """

# ---------------------------------------------------------------------------
# Step 10 — CSV export (has existing _process_sample_10 hook)
# ---------------------------------------------------------------------------
rule export_csv:
    input:
        rules.correct.output,
    output:
        f"{OUTPUT_DIR}/10_csv/{{barcode}}_{{rpi}}.csv",
    params:
        corr_dir=lambda wc: f"{OUTPUT_DIR}/09_correct/{wc.barcode}/{wc.rpi}",
    shell:
        r"""
        set -euo pipefail
        _summary_append() {{ :; }}; export -f _summary_append
        source {SCRIPTS_DIR}/10_export_csv.sh
        _process_sample_10 "{wildcards.barcode}" "{wildcards.rpi}" "{params.corr_dir}" \
            "{OUTPUT_DIR}"
        """

# ---------------------------------------------------------------------------
# Step 11 — gene counting (aggregation; single rule, no per-sample wildcards)
# ---------------------------------------------------------------------------
rule count:
    input:
        corrected_bams,
    output:
        f"{OUTPUT_DIR}/11_count/gene_counts_all.tsv",
    params:
        regions=config.get("regions", ""),
        housekeeping=config.get("housekeeping", ""),
        min_frac=config["min_frac"],
        min_mapq=config["min_mapq"],
    shell:
        _shell_preamble(ENVS["map"]) + r"""
        source {SCRIPTS_DIR}/11_count.sh
        run_step_11 "{OUTPUT_DIR}" "{OUTPUT_DIR}" "{params.regions}" \
            "{params.housekeeping}" "{params.min_frac}" "{params.min_mapq}"
        """

