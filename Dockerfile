# Pinned by digest for reproducible builds. To bump:
#   curl -s https://hub.docker.com/v2/repositories/library/ubuntu/tags/24.04 | jq -r .digest
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

# --- Build args for portability ---
ARG HOST_UID=501
ARG HOST_GID=20
ARG WORKSPACE=/workspace
ARG SSH_BUILD_USER=agent

# --- Tool versions (bump to update; each is referenced by its install step,
#     so changing one busts exactly that layer's cache) ---
ARG CLAUDE_VERSION=2.1.202
ARG UV_VERSION=0.11.26
ARG BUN_VERSION=1.3.14
ARG RUST_TOOLCHAIN=1.96.1
ARG PANDOC_VERSION=3.9
ARG TYPST_VERSION=0.15.0
ARG GITLEAKS_VERSION=8.29.0
# Per-arch SHA256 of the gitleaks release tarballs, from upstream's
# gitleaks_<version>_checksums.txt release asset. Bump together with
# GITLEAKS_VERSION — the build verifies before extraction, and CI greps
# GITLEAKS_SHA256_X64 out of this file for its own install.
ARG GITLEAKS_SHA256_X64=39e07ad810336fd0ae80d0bd61c60d0521f628173e7583583b5df4a38738522c
ARG GITLEAKS_SHA256_ARM64=4c811a7c23296c7163ebab166ec67cd8a31eb9922caf06a7cac4d6dd872e4159

# --- All apt packages in one layer, single cache cleanup ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates ripgrep jq unzip openssh-client tmux \
    python3 python3-pip python3-venv \
    ffmpeg \
    sqlite3 \
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

# Markdown → PDF: pandoc + typst, two static binaries, zero system deps.
# Canonical command: `pandoc input.md --pdf-engine=typst -o output.pdf`
# (GFM tables incl. alignment + syntax-highlighted code verified 2026-07-07,
# see knowhere INBOX research report of that date). Typst is pre-1.0 and the
# pandoc typst writer tracks it, so bump both versions together.
# Arch mapping: dpkg arm64/amd64 → typst aarch64/x86_64 musl targets.
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-${ARCH}.tar.gz" \
        | tar xz -C /usr/local/bin --strip-components=2 "pandoc-${PANDOC_VERSION}/bin/pandoc" \
    && TYPST_ARCH=$([ "$ARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${TYPST_ARCH}-unknown-linux-musl.tar.xz" \
        | tar xJ -C /usr/local/bin --strip-components=1 "typst-${TYPST_ARCH}-unknown-linux-musl/typst" \
    && pandoc --version | head -1 && typst --version

# md2pdf — wrapper encoding the canonical invocation, so sessions don't need
# to know the --pdf-engine flag (bare `pandoc -o x.pdf` defaults to pdflatex,
# which is deliberately NOT installed).
COPY md2pdf /usr/local/bin/md2pdf
RUN chmod +x /usr/local/bin/md2pdf

# Node.js 22 + GitHub CLI (share one apt-get update/cleanup cycle).
# Nodesource repo is configured via apt keyring directly (no setup_22.x
# curl|bash); gnupg is needed once for --dearmor and removed afterwards.
RUN apt-get update && apt-get install -y --no-install-recommends gnupg \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y nodejs gh \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager) — version-pinned installer
RUN curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
    && cp /root/.local/bin/uv /usr/local/bin/uv \
    && cp /root/.local/bin/uvx /usr/local/bin/uvx \
    && rm -rf /root/.local

# Bun (version-pinned; copy binary, clean installer artifacts)
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}" \
    && cp /root/.bun/bin/bun /usr/local/bin/bun \
    && cp /root/.bun/bin/bunx /usr/local/bin/bunx \
    && rm -rf /root/.bun

# Vite + ccusage + LSP servers globally (all version-pinned), clean npm cache
RUN npm install -g vite@8.1.3 ccusage@20.0.14 @usebruno/cli@3.5.1 \
        pyright@1.1.411 typescript-language-server@5.3.0 typescript@6.0.3 \
    && npm cache clean --force

# Claude Code — install.sh takes the version as its argument, so CLAUDE_VERSION
# both pins the installed CLI and busts this layer's cache when bumped.
# Installs to /root/.local/bin/ — copy to /usr/local/bin/ for agent user access.
# Cleanup lives in the same RUN: a separate `rm -rf` layer would leave the
# files in the previous layer and shrink nothing.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}" \
    && { cp /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null \
         || cp "$(find /root -name claude -type f -perm /111 2>/dev/null | head -1)" /usr/local/bin/claude; } \
    && rm -rf /root/.local /root/.npm /root/.cache /tmp/*

# gitleaks — secret scanner backing the container-wide git hooks below.
# Release assets name the architecture x64/arm64, not amd64/arm64, so the dpkg
# arch needs mapping. Static Go binary, no runtime deps.
# The tarball is verified against its pinned SHA256 before extraction: this
# binary runs on every commit and push in every repo, so a re-tagged release
# asset or a CDN compromise must fail the build, not go undetected.
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "arm64" ]; then \
           GL_ARCH=arm64; GL_SHA256="${GITLEAKS_SHA256_ARM64}"; \
       else \
           GL_ARCH=x64; GL_SHA256="${GITLEAKS_SHA256_X64}"; \
       fi \
    && curl -fsSL -o /tmp/gitleaks.tgz \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
    && echo "${GL_SHA256}  /tmp/gitleaks.tgz" | sha256sum -c - \
    && tar xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \
    && rm /tmp/gitleaks.tgz \
    && chmod +x /usr/local/bin/gitleaks \
    && gitleaks version

# Container-wide git hooks: scan every commit and every push for secrets.
#
# core.hooksPath is set in the SYSTEM config (/etc/gitconfig) rather than the
# agent user's ~/.gitconfig, because that file is written at runtime by
# `gh auth setup-git` — system config is out of its way, and precedence still
# works out (system < global < local, and nothing sets hooksPath higher up).
#
# One dispatcher, symlinked under each hook name. The names matter: hooksPath
# REPLACES .git/hooks entirely, so any hook name NOT present here is a
# repo-local hook silently disabled. The dispatcher chains to the repo's own
# hook, so listing a name preserves it. The receive-side names (pre-receive,
# update, post-receive, post-update, proc-receive) cover bare repos — system
# hooksPath applies there too, so a local bare remote's own vetoing
# pre-receive must still chain. push-to-checkout and fsmonitor-watchman get
# absent-hook special cases in the dispatcher (their mere presence changes
# git's behaviour, so a silent exit 0 would be wrong).
#
# check-hookspath is not a hook — it is the entrypoint's drift warning for
# repos that override core.hooksPath locally (which outranks this gate); it
# just ships in the same directory.
#
# Deliberately omitted: reference-transaction, pre-auto-gc, post-index-change.
# They fire on essentially every ref update and git housekeeping pass, and
# paying a process spawn each time is not worth it — no repo in this workspace
# uses them. Add the name here if one ever does.
COPY git-hooks/dispatch git-hooks/check-hookspath git-hooks/gitleaks.toml /usr/local/share/git-hooks/
RUN chmod 755 /usr/local/share/git-hooks/dispatch /usr/local/share/git-hooks/check-hookspath \
    && chmod 644 /usr/local/share/git-hooks/gitleaks.toml \
    && for h in applypatch-msg pre-applypatch post-applypatch \
                pre-commit pre-merge-commit prepare-commit-msg commit-msg \
                post-commit pre-rebase post-checkout post-merge pre-push \
                post-rewrite sendemail-validate \
                pre-receive update post-receive post-update proc-receive \
                push-to-checkout fsmonitor-watchman; do \
           ln -sf dispatch "/usr/local/share/git-hooks/$h"; \
       done \
    && git config --system core.hooksPath /usr/local/share/git-hooks \
    && test "$(git config --system --get core.hooksPath)" = /usr/local/share/git-hooks

# Create agent user with matching host UID/GID.
# ubuntu:24.04 ships a built-in `ubuntu` user at UID 1000; if HOST_UID collides
# with an existing user (the default on most Linux hosts), rename that user to
# `agent` instead of creating one. No `|| true`: a real useradd/usermod failure
# should fail the build here, not later at the first `USER agent` step.
RUN set -e; \
    getent group ${HOST_GID} >/dev/null || groupadd -g ${HOST_GID} hostgroup; \
    existing="$(getent passwd ${HOST_UID} | cut -d: -f1 || true)"; \
    if [ -n "$existing" ]; then \
        usermod -l agent -d /home/agent -m "$existing"; \
        usermod -g ${HOST_GID} agent; \
    else \
        useradd -m -u ${HOST_UID} -g ${HOST_GID} agent; \
    fi; \
    id agent

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

# Rust toolchain (installed as agent user → ~/.cargo), version-pinned
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN}" \
    && rm -rf /home/agent/.rustup/tmp

# Pre-seed minimal config to skip onboarding prompts.
# bypassPermissionsModeAccepted is safe HERE because the container is the sandbox;
# do not copy this .claude.json onto the host / --local path (no sandbox there).
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

# Marketplace skills detect "am I in the multiplai container?" from this flag
# (with /.dockerenv as a generic-Docker fallback) instead of inferring it from
# uname — a plain Linux box must never be mistaken for the container and told
# to configure the SSH bridge. Keep in sync with the skills' detection rule
# (multiplai-cc-mktplace docs/degradation-contract.md).
ENV MULTIPLAI_CONTAINER=1

# CLI updates are owned by the entrypoint (weekly npm refresh into the
# persistent ~/.claude-cli mount, lock-protected across containers). Claude
# Code's built-in auto-updater must stay off: the CLI is an npm-prefix install,
# so the updater targets the global npm prefix (/usr — root-owned here) and
# every session nags "Auto-update failed: no write permission to npm prefix".
ENV DISABLE_AUTOUPDATER=1

WORKDIR ${WORKSPACE}

ENTRYPOINT ["/usr/local/bin/venv-sync-entrypoint.sh"]
CMD ["claude"]
