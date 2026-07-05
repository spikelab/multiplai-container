FROM ubuntu:24.04

# --- Build args for portability ---
ARG HOST_UID=501
ARG HOST_GID=20
ARG WORKSPACE=/workspace
ARG SSH_BUILD_USER=agent

# --- All apt packages in one layer, single cache cleanup ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates ripgrep jq unzip openssh-client tmux \
    python3 python3-pip python3-venv \
    ffmpeg \
    build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Google Cloud SDK — key must be dearmored for signed-by to accept it.
# gnupg is needed once for `gpg --dearmor` and removed afterwards.
RUN apt-get update && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        google-cloud-cli \
        google-cloud-cli-gke-gcloud-auth-plugin \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Cloud SQL Auth Proxy v2 — standalone binary hosted on GCS, not as a GitHub
# release asset. GitHub's "latest" tag picks the legacy v1 line because Google
# still publishes both, so we pin v2 explicitly. Bump CSP_VERSION to update;
# release notes at https://github.com/GoogleCloudPlatform/cloud-sql-proxy/releases
ARG CSP_VERSION=v2.21.3
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /usr/local/bin/cloud-sql-proxy \
        "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/${CSP_VERSION}/cloud-sql-proxy.linux.${ARCH}" \
    && chmod +x /usr/local/bin/cloud-sql-proxy

# Node.js 22 + GitHub CLI (share one apt-get update/cleanup cycle)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y nodejs gh \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && cp /root/.local/bin/uv /usr/local/bin/uv \
    && cp /root/.local/bin/uvx /usr/local/bin/uvx \
    && rm -rf /root/.local

# Bun (copy binary, clean installer artifacts)
RUN curl -fsSL https://bun.sh/install | bash \
    && cp /root/.bun/bin/bun /usr/local/bin/bun \
    && cp /root/.bun/bin/bunx /usr/local/bin/bunx \
    && rm -rf /root/.bun

# Vite + ccusage + LSP servers globally, clean npm cache
RUN npm install -g vite ccusage@17 @usebruno/cli pyright typescript-language-server typescript && npm cache clean --force

# Claude Code (bump CLAUDE_VERSION to force update)
# Installs to /root/.local/bin/ — copy to /usr/local/bin/ for agent user access
ARG CLAUDE_VERSION=2.1.183
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null \
    || cp $(find /root -name claude -type f -perm +111 2>/dev/null | head -1) /usr/local/bin/claude
RUN rm -rf /root/.local /root/.npm /root/.cache /tmp/*

# Create agent user with matching host UID/GID
RUN getent group ${HOST_GID} >/dev/null 2>&1 || groupadd -g ${HOST_GID} hostgroup \
    && useradd -m -u ${HOST_UID} -g ${HOST_GID} agent 2>/dev/null || true

# Pre-create .venv mount point with agent ownership.
# Docker copies this ownership into new named volumes on first mount.
# Path MUST match the volume mount in claude.sh: -v "kit-venv:$SCRIPT_DIR/.venv"
# where SCRIPT_DIR = WORKSPACE/multiplai-runtime. Mismatch → root-owned volume → permission denied.
RUN mkdir -p ${WORKSPACE}/multiplai-runtime/.venv \
    && chown ${HOST_UID}:${HOST_GID} ${WORKSPACE}/multiplai-runtime/.venv

# Copy entrypoint into image (not dependent on volume mount)
COPY venv-sync-entrypoint.sh /usr/local/bin/venv-sync-entrypoint.sh
RUN chmod +x /usr/local/bin/venv-sync-entrypoint.sh

USER agent

# Rust toolchain (installed as agent user → ~/.cargo)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && rm -rf /home/agent/.rustup/tmp

# Pre-seed minimal config to skip onboarding prompts
RUN mkdir -p /home/agent/.local/bin /home/agent/.claude && \
    ln -s /usr/local/bin/claude /home/agent/.local/bin/claude && \
    echo '{"hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true}' > /home/agent/.claude.json

# agent-browser bridge wrapper — drives Vercel agent-browser on the macOS host
# over the SSH build bridge (host gateway allowlists `agent-browser`).
COPY --chown=${HOST_UID}:${HOST_GID} ab /home/agent/.local/bin/ab
RUN chmod +x /home/agent/.local/bin/ab

# SSH setup for host build bridge (Swift/Xcode builds + agent-browser via SSH to
# macOS host). ControlMaster multiplexes connections so a snapshot->act loop
# reuses one tunnel instead of a fresh handshake per call. %% escapes printf.
RUN mkdir -p /home/agent/.ssh && \
    chmod 700 /home/agent/.ssh && \
    printf "Host host.docker.internal\n  User %s\n  IdentityFile ~/.ssh/build_key\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  ControlMaster auto\n  ControlPath ~/.ssh/cm-%%r@%%h:%%p\n  ControlPersist 10m\n" "${SSH_BUILD_USER}" > /home/agent/.ssh/config && \
    chmod 600 /home/agent/.ssh/config

ENV PATH="${WORKSPACE}/multiplai-runtime/.venv/bin:/home/agent/.cargo/bin:/home/agent/.local/bin:${PATH}"
ENV WORKSPACE="${WORKSPACE}"

WORKDIR ${WORKSPACE}

ENTRYPOINT ["/usr/local/bin/venv-sync-entrypoint.sh"]
CMD ["claude"]
