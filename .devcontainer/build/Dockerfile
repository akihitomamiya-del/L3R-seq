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

# On arm64 the bioconda racon binary uses SIMD instructions unsupported by
# Docker Desktop's virtualisation on Apple Silicon.  Rebuild from source with
# baseline ARMv8 flags so it runs everywhere.  On amd64 the bioconda binary
# is fine, so this step is skipped.
# Uses curl + tar instead of git clone (BuildKit may block git).
#
# IMPORTANT: -Dspoa_optimize_for_native=OFF is required because spoa's
# CMakeLists.txt appends -march=native by default, which overrides the
# portable -march=armv8-a flag.  Without this, the CI runner's native
# march (e.g. Graviton) bakes in instructions that crash on Apple Silicon.
RUN if [ "$(uname -m)" = "aarch64" ]; then \
      apt-get update && apt-get install -y --no-install-recommends cmake g++ zlib1g-dev \
      && mkdir -p /tmp/racon-build \
      && curl -fsSL https://github.com/lbcb-sci/racon/archive/refs/tags/1.5.0.tar.gz \
         | tar -xz -C /tmp/racon-build --strip-components=1 \
      && for dep in \
           "vendor/spoa https://github.com/rvaser/spoa/archive/12f2ad2a76030ed25aaa616c3a171d149ca9fd13.tar.gz" \
           "vendor/thread_pool https://github.com/rvaser/thread_pool/archive/3f5aaacf1af7cb47cbc918812a7af42e290c7031.tar.gz" \
           "vendor/edlib https://github.com/martinsos/edlib/archive/ee36875e944b63abf6f9b9e14c010b445529427d.tar.gz" \
           "vendor/rampler https://github.com/rvaser/rampler/archive/4f2d91e4f3ce5ef61d14b319040a7d24f116aedd.tar.gz" \
         ; do \
           dir=$(echo "$dep" | cut -d' ' -f1); \
           url=$(echo "$dep" | cut -d' ' -f2); \
           mkdir -p /tmp/racon-build/$dir; \
           curl -fsSL "$url" | tar -xz -C /tmp/racon-build/$dir --strip-components=1; \
         done \
      && cd /tmp/racon-build && mkdir build && cd build \
      && cmake -DCMAKE_BUILD_TYPE=Release \
               -DCMAKE_C_FLAGS="-march=armv8-a" \
               -DCMAKE_CXX_FLAGS="-march=armv8-a" \
               -Dspoa_optimize_for_native=OFF \
               .. \
      && make -j$(nproc) \
      && cp bin/racon /opt/miniforge/envs/longread_umi/bin/racon \
      && printf ">t\nACGTACGT\n" > /tmp/t.fa \
      && printf "@r\nACGTACGT\n+\nIIIIIIII\n" > /tmp/r.fq \
      && printf "r\t0\tt\t1\t255\t8M\t*\t0\t0\tACGTACGT\tIIIIIIII\n" > /tmp/o.sam \
      && /opt/miniforge/envs/longread_umi/bin/racon /tmp/r.fq /tmp/o.sam /tmp/t.fa > /dev/null 2>&1 \
      && echo "racon arm64 rebuild: functional test passed" \
      && rm -f /tmp/t.fa /tmp/r.fq /tmp/o.sam \
      && rm -rf /tmp/racon-build \
      && apt-get purge -y --auto-remove cmake g++ zlib1g-dev \
      && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

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

COPY UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py /tmp/UMIC-seq_fastq_v2.py
RUN bash -c "source activate UMIC-seq \
    && mkdir -p \$CONDA_PREFIX/UMIC-seq \
    && curl -fsSL https://github.com/fhlab/UMIC-seq/archive/refs/heads/master.tar.gz \
       | tar -xz -C \$CONDA_PREFIX/UMIC-seq --strip-components=1 \
    && gunzip \$CONDA_PREFIX/UMIC-seq/example/example_clusterreads.fastq.gz \
    && cp /tmp/UMIC-seq_fastq_v2.py \$CONDA_PREFIX/UMIC-seq/ \
    && rm /tmp/UMIC-seq_fastq_v2.py"

# ============================================================
# analysis — lightweight env for plot_umi_bins.py
# ============================================================
RUN mamba create -y -n analysis -c conda-forge matplotlib numpy \
    && mamba clean -afy

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
# lofreq 2.1.5 may lack an arm64 bioconda build; fall back to
# pip install (builds from source via htslib bundled in the wheel).
# ============================================================
RUN mamba create -y -n LoFreq -c conda-forge -c bioconda \
    bcftools=1.21 \
    python=3.12 \
    && (mamba install -y -n LoFreq -c conda-forge -c bioconda lofreq=2.1.5 \
        || /opt/miniforge/envs/LoFreq/bin/pip install lofreq) \
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
RUN cd igv_viewer && npm install --silent

# Initialize conda for the vscode user
USER vscode
RUN conda init zsh bash
