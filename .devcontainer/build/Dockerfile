FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

# Locale + bioinformatics system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    locales \
    ncbi-blast+ \
    tmux \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ============================================================
# Miniforge (conda/mamba) — community installer, no licensing issues
# ============================================================
RUN arch=$(uname -m) \
    && curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh" \
       -o /tmp/miniforge.sh \
    && bash /tmp/miniforge.sh -b -p /opt/miniforge \
    && rm /tmp/miniforge.sh
ENV PATH="/opt/miniforge/bin:$PATH"

# ============================================================
# seqkit v2.9.0
# ============================================================
RUN ARCH=$(dpkg --print-architecture) \
    && wget -q "https://github.com/shenwei356/seqkit/releases/download/v2.9.0/seqkit_linux_${ARCH}.tar.gz" \
       -O /tmp/seqkit.tar.gz \
    && tar -xzf /tmp/seqkit.tar.gz -C /usr/local/bin/ \
    && rm /tmp/seqkit.tar.gz

# ============================================================
# longread_umi conda environment
# ============================================================
RUN mamba create -y -n longread_umi -c conda-forge -c bioconda \
    parallel=20260122 \
    racon=1.5.0 \
    minimap2=2.28 \
    gawk=5.3.1 \
    cutadapt=4.9 \
    bwa=0.7.18 \
    samtools=1.20 \
    vsearch=2.30.4 \
    && mamba clean -afy

# Install L3Rseq's bundled longread_umi scripts (modified from upstream)
COPY longread_umi_L3Rseq/ /tmp/longread_umi_L3Rseq/
RUN bash -c "source activate longread_umi \
    && cp -r /tmp/longread_umi_L3Rseq \$CONDA_PREFIX/longread_umi \
    && find \$CONDA_PREFIX/longread_umi/ -name '*.sh' -exec chmod +x {} \; \
    && ln -s \$CONDA_PREFIX/longread_umi/longread_umi.sh \$CONDA_PREFIX/bin/longread_umi \
    && rm -rf /tmp/longread_umi_L3Rseq"

# ============================================================
# UMIC-seq conda environment
# ============================================================
RUN mamba create -y -n UMIC-seq -c conda-forge -c bioconda \
    python=3.12.4 \
    biopython=1.83 \
    scikit-bio=0.6.1 \
    tqdm=4.66.4 \
    matplotlib=3.8.4 \
    && mamba clean -afy

RUN bash -c "source activate UMIC-seq \
    && git clone https://github.com/fhlab/UMIC-seq.git \$CONDA_PREFIX/UMIC-seq \
    && gunzip \$CONDA_PREFIX/UMIC-seq/example/example_clusterreads.fastq.gz"

COPY UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py /tmp/UMIC-seq_fastq_v2.py
RUN bash -c "source activate UMIC-seq \
    && cp /tmp/UMIC-seq_fastq_v2.py \$CONDA_PREFIX/UMIC-seq/"

# ============================================================
# cutadaptenv
# ============================================================
RUN mamba create -y -n cutadaptenv -c conda-forge -c bioconda cutadapt=4.9 \
    && mamba clean -afy

# ============================================================
# NanoporeMap conda environment
# ============================================================
RUN mamba create -y -n NanoporeMap -c conda-forge -c bioconda \
    python=3.12.3 \
    minimap2=2.28 \
    bcftools=1.20 \
    samtools=1.20 \
    && mamba clean -afy

RUN bash -c "source activate NanoporeMap \
    && mkdir -p \$CONDA_PREFIX/NanoporeMap/Refs"

# ============================================================
# LoFreq conda environment
# ============================================================
RUN mamba create -y -n LoFreq -c conda-forge -c bioconda \
    lofreq=2.1.5 \
    bcftools=1.21 \
    && mamba clean -afy

# ============================================================
# Entrez conda environment
# Not used by the pipeline itself, but useful for fetching reference
# sequences from NCBI (e.g., efetch -db nucleotide -id ... -format fasta).
# ============================================================
RUN mamba create -y -n Entrez -c conda-forge -c bioconda \
    entrez-direct=22.4 \
    && mamba clean -afy

# ============================================================
# Node.js (for IGV.js alignment viewer)
# ============================================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Data mount points for bind-mounted input/output
RUN mkdir -p /data/input /data/output && chmod 777 /data/output

# Allow arbitrary UIDs (from --user flag) to read conda environments
RUN chmod -R a+rX /opt/miniforge

# Add L3Rseq to PATH so it's callable without full path in docker run
ENV PATH="/workspace:$PATH"

# Pipeline code — standalone docker run / docker compose without workspace bind mount.
# In devcontainers the workspace bind-mount masks this layer.
WORKDIR /workspace
COPY L3Rseq config.sh ./
COPY scripts/ scripts/
COPY UMIC-seq_L3Rseq/ UMIC-seq_L3Rseq/
COPY resources/ resources/
COPY igv_viewer/ igv_viewer/
RUN cd igv_viewer && npm install --silent 2>/dev/null

# Initialize conda for the vscode user
USER vscode
RUN conda init zsh bash
