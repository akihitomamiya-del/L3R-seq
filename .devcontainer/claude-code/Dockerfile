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
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    jq \
    fzf \
    nano \
    vim \
    man-db \
    bsdmainutils \
    # Puppeteer browser libs (IGV viewer screenshots)
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
    libpango-1.0-0 libcairo2 libasound2 libxshmfence1 \
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

# Firewall script + passwordless sudo for it
COPY .devcontainer/claude-code/init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/vscode-firewall && \
    chmod 0440 /etc/sudoers.d/vscode-firewall

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
    -p fzf \
    -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
    -a "source /usr/share/doc/fzf/examples/completion.zsh" \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -x

# Re-initialize conda for zsh (zsh-in-docker overwrites ~/.zshrc)
RUN /opt/miniforge/bin/conda init zsh \
    && sed -i 's/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(user/POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(anaconda user/' ~/.zshrc

# Install Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
