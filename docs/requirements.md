[README](../README.md) | [Advanced](advanced.md) | **Requirements** | [Code Overview](code-overview.md) | [Development](development.md)

---

# Requirements

L3Rseq runs inside a Docker container where all dependencies are pre-installed. You need [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS, Windows) or Docker Engine (Linux). The pipeline is CPU-only and does not require a GPU. An NVIDIA GPU is recommended for basecalling with dorado (SUP model).

## Platform support

The pre-built Docker image is multi-arch (amd64 + arm64):

| Platform | Status |
|---|---|
| macOS — Apple Silicon (M1/M2/M3/M4) | Tested |
| Linux (x86_64) | Tested |
| GitHub Codespaces | Tested |
| macOS — Intel / Windows (WSL2) | Should work (untested) |

## Conda environments

The conda environments listed below are managed automatically — no manual activation is needed when using `L3Rseq run`.

| Environment | Tools | Used by |
|---|---|---|
| longread_umi | vsearch, racon, minimap2, bwa, samtools, cutadapt | Steps 04, 05 |
| cutadaptenv | cutadapt | Steps 02, 03, 06 |
| NanoporeMap | minimap2, samtools, BLAST+ | Steps 07, 09, filter |
| LoFreq | lofreq, bcftools | Step 08 |
| UMIC-seq | Python, UMIC-seq scripts | Step 04 (with `--method umic-seq`) |
| analysis | matplotlib, numpy | Plotting scripts (`plot_umi_bins.py`) |
| Entrez | efetch, esearch | Fetching NCBI reference sequences |

---

[README](../README.md) | [Advanced](advanced.md) | **Requirements** | [Code Overview](code-overview.md) | [Development](development.md)
