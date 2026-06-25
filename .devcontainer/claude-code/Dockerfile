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

# Privileged helper scripts + RESTRICTED sudo.
# The base image (mcr.microsoft.com/devcontainers/base) ships the vscode user
# with blanket passwordless sudo (/etc/sudoers.d/vscode = "vscode ALL=(root)
# NOPASSWD:ALL"). That lets any code running as vscode flush the firewall
# (e.g. `sudo iptables -F`) and defeat the egress allowlist, so we REMOVE that
# file and grant sudo for ONLY two entrypoints: start-firewall.sh (the firewall
# wrapper) and fix-runs-perms.sh (a narrow /runs ownership fixer; the volume
# mounts root-owned). init-firewall.sh is deliberately NOT in the allowlist:
# start-firewall.sh invokes it internally as root, so a direct
# `sudo init-firewall.sh` grant would only hand vscode an on-demand
# firewall-flush (the script opens egress before rebuilding the allowlist) --
# exactly what this restriction prevents. Scripts are chmod 0755 (not
# group-writable) so they can never be tampered with from the vscode side.
COPY .devcontainer/claude-code/init-firewall.sh .devcontainer/claude-code/start-firewall.sh .devcontainer/claude-code/firewall-warning.sh .devcontainer/claude-code/fix-runs-perms.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/init-firewall.sh /usr/local/bin/start-firewall.sh /usr/local/bin/firewall-warning.sh /usr/local/bin/fix-runs-perms.sh && \
    rm -f /etc/sudoers.d/vscode && \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/start-firewall.sh, /usr/local/bin/fix-runs-perms.sh" > /etc/sudoers.d/vscode-firewall && \
    chmod 0440 /etc/sudoers.d/vscode-firewall

# Puppeteer Chrome (dev-only — headless screenshots for UI testing).
# Use the repo's package files (from build context) so the cached Chrome
# version matches what the repo's puppeteer expects at runtime.
COPY igv_viewer/package.json igv_viewer/package-lock.json /tmp/igv-puppeteer/
RUN cd /tmp/igv-puppeteer \
    && npm install --ignore-scripts \
    && PUPPETEER_CACHE_DIR=/opt/puppeteer-cache npx puppeteer browsers install chrome \
    && chmod -R a+rX /opt/puppeteer-cache \
    && rm -rf /tmp/igv-puppeteer
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

# Re-initialize conda for zsh (zsh-in-docker overwrites ~/.zshrc) and wire up
# the firewall status warning so every new shell sees it if the firewall
# failed to initialize.
RUN /opt/miniforge/bin/conda init zsh \
    && sed -i 's/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(user/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(anaconda user/' ~/.zshrc \
    && echo '' >> ~/.zshrc \
    && echo '# Firewall status banner (set by /usr/local/bin/start-firewall.sh)' >> ~/.zshrc \
    && echo '[ -f /usr/local/bin/firewall-warning.sh ] && . /usr/local/bin/firewall-warning.sh' >> ~/.zshrc

# Install Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
