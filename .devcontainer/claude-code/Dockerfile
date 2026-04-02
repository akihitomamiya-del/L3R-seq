# ============================================================
# Claude Code development layer
# Extends the published L3Rseq image (all bioinformatics tools
# included) with dev tooling, Claude CLI, and a network firewall
# for safe --dangerously-skip-permissions use.
# ============================================================
FROM ghcr.io/akihitomamiya-del/l3rseq:latest

ARG TZ
ENV TZ="${TZ:-America/Los_Angeles}"

USER root

# Firewall dependencies + dev tools not in the base image
# (Puppeteer browser libs are already in the base image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    jq \
    nano \
    vim \
    man-db \
    bsdmainutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# git-delta for better diffs
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Persist bash history across container rebuilds
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R vscode /commandhistory

ENV DEVCONTAINER=true

# Claude config directory + npm global directory
RUN mkdir -p /home/vscode/.claude /usr/local/share/npm-global && \
    chown -R vscode:vscode /home/vscode/.claude /usr/local/share/npm-global

# Firewall scripts + passwordless sudo
COPY .devcontainer/claude-code/init-firewall.sh .devcontainer/claude-code/start-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/start-firewall.sh && \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/start-firewall.sh" > /etc/sudoers.d/vscode-firewall && \
    chmod 0440 /etc/sudoers.d/vscode-firewall

# Puppeteer Chrome (dev-only — headless screenshots for UI testing).
# Runs as root so we can write to /opt; shared libs are in the base image.
RUN cd /workspace/igv_viewer \
    && PUPPETEER_CACHE_DIR=/opt/puppeteer-cache npx puppeteer browsers install chrome \
    && chmod -R a+rX /opt/puppeteer-cache
ENV PUPPETEER_CACHE_DIR=/opt/puppeteer-cache

# ============================================================
# User-level setup (vscode — matches base image user)
# ============================================================
USER vscode

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

# Powerlevel10k shell with plugins
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
    -p git \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -x

# Re-initialize conda for zsh (zsh-in-docker overwrites ~/.zshrc)
RUN /opt/miniforge/bin/conda init zsh \
    && sed -i 's/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(user/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(anaconda user/' ~/.zshrc

# Install Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
