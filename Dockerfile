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
# Consumers must pin the SAME version (e.g. `playwright==1.63.0` in the
# video-edit skill's pyproject.toml): each Playwright release looks only for
# the browser revision it was built against, so a mismatch makes it ask for a
# revision this image does not have, and launch() fails until it downloads one.
ARG PLAYWRIGHT_VERSION=1.63.0
# pi and Codex are baked as fallbacks only: the entrypoint keeps a weekly
# self-updating copy of each in a folder mounted from the Mac (~/.pi-cli,
# ~/.codex) and puts it first on PATH. These pins are what runs before that
# copy exists, or when its install failed.
ARG PI_VERSION=1.2.0
# Newest Codex release at least 14 days old when pinned: 0.159.2, released
# 2026-09-29 (github.com/openai/codex, tag rust-v0.159.2).
ARG CODEX_VERSION=0.159.2

# --- All apt packages in one layer, single cache cleanup ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates ripgrep jq unzip openssh-client tmux \
    python3 python3-pip python3-venv \
    ffmpeg \
    sqlite3 \
    build-essential pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Project-specific tooling (gcloud, cloud-sql-proxy, MySQL, …) does NOT belong
# here — it goes in an overlay image built on top of this one with
# build-overlay.sh, from a Dockerfile kept in the consuming project's repo.

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

# Vite + pnpm + ccusage + LSP servers + ast-grep globally (all version-pinned),
# clean npm cache.
#
# pnpm is here rather than in a project overlay because it is a package
# manager, not project tooling: a repo with a pnpm-lock.yaml cannot be
# installed by npm at all, so without it the agent's first move in such a repo
# fails. Corepack ships with Node 22 and is deliberately left unused: it
# fetches pnpm from the network on first use, at whatever version the repo
# names, with no pin of ours in the way. An explicit npm -g install is the
# pinned, offline-safe path.
#
# The pin is the newest 11.x line release; 12.x is not adopted yet. Move it
# forward, never backwards to match a consuming repo: pnpm honours a
# project's package.json "packageManager" field and downloads that version
# itself (verified: pnpm 11.23.0 reports 10.10.0 inside a repo declaring it),
# so what runs in a pinned repo is the repo's choice either way. This pin only
# governs repos that declare nothing, and those should get a current pnpm.
# Requires Node >= 22.13.
RUN npm install -g vite@8.1.3 pnpm@11.26.0 ccusage@20.0.14 @usebruno/cli@3.5.1 \
        pyright@1.1.411 typescript-language-server@5.3.0 typescript@6.0.3 \
    && npm cache clean --force

# pi — the baked fallback (see PI_VERSION above). It gets its own prefix,
# exposed by one symlink in /usr/local/bin, because of pi's installer, which
# the entrypoint runs to fill ~/.pi-cli: it refuses to install while a pi it
# does not manage is on PATH, and offers instead to `npm uninstall -g` that
# copy (verified against pi.dev/install.sh, 2026-10-14). At npm's default
# /usr prefix this copy would sit in /usr/bin beside node and npm, which the
# installer needs, so nothing could hide it. Here the entrypoint runs the
# installer with PATH=/usr/bin:/bin, which leaves this copy out.
# The version check runs as the session's uid, so a root-only file fails the
# build here instead of in a session.
RUN npm install -g --prefix /opt/pi "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && ln -s /opt/pi/bin/pi /usr/local/bin/pi \
    && chmod -R a+rX /opt/pi \
    && npm cache clean --force \
    && HOME=/tmp PI_OFFLINE=1 setpriv --reuid=${HOST_UID} --regid=${HOST_GID} --clear-groups \
       pi --version \
    && rm -rf /root/.npm /tmp/* /tmp/.[!.]*

# ast-grep gets its own prefix because @ast-grep/cli ships a second bin, `sg`,
# which collides with /usr/bin/sg (the setgroup utility from the login
# package) at npm's /usr global prefix — npm rightly refuses with EEXIST, and
# --force would overwrite a system binary. Only the ast-grep name is exposed;
# the `sg` shorthand is deliberately left buried.
RUN npm install -g --prefix /opt/ast-grep @ast-grep/cli@0.45.1 \
    && ln -s /opt/ast-grep/bin/ast-grep /usr/local/bin/ast-grep \
    && npm cache clean --force

# Playwright + its Chromium builds, so a session can render HTML, take
# screenshots and run browser tests locally instead of driving the Mac's
# browser over the SSH bridge (`ab` keeps that job for real websites).
# Chromium only: no Firefox, no WebKit.
#
# The browsers are baked in rather than fetched on first use because $HOME is
# not persisted between sessions — a download into ~/.cache/ms-playwright
# would be repeated, and lost, every session. PLAYWRIGHT_BROWSERS_PATH is set
# as ENV (not inline) so this install and every later Node or Python
# Playwright process read the one path. NODE_PATH makes the global install
# require()-able outside a project; a project's own node_modules still wins.
#
# System libraries come from `install --with-deps`, which apt-installs the
# list Playwright itself keeps per platform (ubuntu24.04-arm64 and -x64 are
# both in 1.63.0's table), so there is no hand-written package list here to
# drift from the browser revision. It runs `apt-get update` itself but leaves
# the lists behind, hence the cleanup in this same RUN. DEBIAN_FRONTEND keeps
# a tzdata-style debconf prompt from hanging the build.
#
# /dev/shm: claude.sh passes no --shm-size. Docker's documented default is
# 64 MB, though an OrbStack session measured 7.9 GB (2026-10-10). Neither
# matters: Playwright launches Chromium with --disable-dev-shm-usage
# unconditionally (chromiumSwitches in
# packages/playwright-core/src/server/chromium/chromiumSwitches.ts, bundled
# into playwright-core/lib/coreBundle.js:34867 in 1.63.0, and spread into
# every launch's arguments at coreBundle.js:43336), so Chromium writes its
# shared memory to /tmp instead.
#
# The directory is group-owned by HOST_GID with setgid directories, so a
# session (agent's primary group) can add another revision for its own
# lifetime if it needs one. The smoke check launches both builds as an
# unprivileged user (nobody, via setpriv — the agent user does not exist
# yet), so a missing library or a root-only permission fails the build here
# instead of in a session.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
ENV NODE_PATH=/usr/lib/node_modules
RUN npm install -g "playwright@${PLAYWRIGHT_VERSION}" \
    && DEBIAN_FRONTEND=noninteractive \
       playwright install --with-deps chromium chromium-headless-shell \
    && chgrp -R ${HOST_GID} /opt/ms-playwright \
    && chmod -R a+rX,g+w /opt/ms-playwright \
    && find /opt/ms-playwright -type d -exec chmod g+s {} + \
    && rm -rf /var/lib/apt/lists/* /root/.cache /root/.npm /tmp/* \
    && npm cache clean --force \
    && playwright --version \
    && HOME=/tmp setpriv --reuid=65534 --regid=65534 --clear-groups \
       node -e ' \
         const { chromium } = require("playwright"); \
         (async () => { \
           for (const opts of [{}, { channel: "chromium" }]) { \
             const browser = await chromium.launch(opts); \
             const page = await browser.newPage(); \
             await page.goto("data:text/html,<p>ok</p>"); \
             const text = await page.textContent("p"); \
             if (text !== "ok") throw new Error("smoke check read " + text); \
             console.log("playwright smoke ok:", opts.channel || "chromium-headless-shell", browser.version()); \
             await browser.close(); \
           } \
         })().catch((e) => { console.error(e); process.exit(1); });' \
    && rm -rf /tmp/*

# Claude Code — install.sh takes the version as its argument, so CLAUDE_VERSION
# both pins the installed CLI and busts this layer's cache when bumped.
# Installs to /root/.local/bin/ — copy to /usr/local/bin/ for agent user access.
# Cleanup lives in the same RUN: a separate `rm -rf` layer would leave the
# files in the previous layer and shrink nothing.
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}" \
    && { cp /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null \
         || cp "$(find /root -name claude -type f -perm /111 2>/dev/null | head -1)" /usr/local/bin/claude; } \
    && rm -rf /root/.local /root/.npm /root/.cache /tmp/*

# Codex CLI — the baked fallback (see CODEX_VERSION above), installed with
# OpenAI's own installer pinned to that release. The installer unpacks the
# release under CODEX_HOME=/opt/codex and links /usr/local/bin/codex to it.
# `sh` gets no pipefail here, so a failed download would pass silently; the
# version check after it is what fails the build. It runs as the session's
# uid, so a root-only file fails the build here instead of in a session.
#
# Auto-update: there is no DISABLE_AUTOUPDATER-style variable to set for
# Codex. Neither the installer nor the CLI reads an environment variable that
# turns off its own updates (checked 2026-10-14: install.sh's variables, and
# every CODEX_* name in the 0.159.2 binary). The only switch found is the
# `check_for_update_on_startup` key in ~/.codex/config.toml, which lives in
# the mounted folder, not in the image. The installer writes its
# auto-update-version marker only for CODEX_RELEASE=latest, so this pinned
# copy has none.
RUN curl -fsSL https://chatgpt.com/codex/install.sh \
        | CODEX_RELEASE="${CODEX_VERSION}" CODEX_NON_INTERACTIVE=1 \
          CODEX_INSTALL_DIR=/usr/local/bin CODEX_HOME=/opt/codex sh \
    && chmod -R a+rX /opt/codex \
    && HOME=/tmp setpriv --reuid=${HOST_UID} --regid=${HOST_GID} --clear-groups \
       codex --version \
    && rm -rf /tmp/* /tmp/.[!.]*

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

# Rust toolchain (installed as agent user → ~/.cargo), version-pinned
USER agent
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain "${RUST_TOOLCHAIN}" \
    && rm -rf /home/agent/.rustup/tmp
USER root

# --- Files from THIS repo, below every third-party install ------------------
# These are the files a maintainer actually iterates on, so they sit under all
# the expensive layers above (apt, npm, the Claude CLI, the rustup toolchain
# download): editing a hook or the entrypoint rebuilds only from here down,
# instead of re-downloading the world.

# md2pdf — wrapper encoding the canonical invocation, so sessions don't need
# to know the --pdf-engine flag (bare `pandoc -o x.pdf` defaults to pdflatex,
# which is deliberately NOT installed).
COPY --chmod=755 md2pdf /usr/local/bin/md2pdf

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
#
# The trailing `test -L` lines assert the two scanning hooks survived the
# loop: a typo there would otherwise ship an image whose secret gate simply
# never fires, with nothing failing anywhere.
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
    && test -L /usr/local/share/git-hooks/pre-commit \
    && test -L /usr/local/share/git-hooks/pre-push \
    && git config --system core.hooksPath /usr/local/share/git-hooks \
    && test "$(git config --system --get core.hooksPath)" = /usr/local/share/git-hooks

# Copy entrypoint into image (not dependent on volume mount)
COPY --chmod=755 venv-sync-entrypoint.sh /usr/local/bin/venv-sync-entrypoint.sh

USER agent

# Pre-seed minimal config to skip onboarding prompts.
# bypassPermissionsModeAccepted is safe HERE because the container is the sandbox;
# do not copy this .claude.json onto the host / --local path (no sandbox there).
RUN mkdir -p /home/agent/.local/bin /home/agent/.claude && \
    ln -s /usr/local/bin/claude /home/agent/.local/bin/claude && \
    echo '{"hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true}' > /home/agent/.claude.json

# agent-browser bridge wrapper — drives Vercel agent-browser on the macOS host
# over the SSH build bridge (host gateway allowlists `agent-browser`).
COPY --chown=${HOST_UID}:${HOST_GID} --chmod=755 ab /home/agent/.local/bin/ab

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
# Codex has no equivalent variable; see the comment on its install step.

WORKDIR ${WORKSPACE}

ENTRYPOINT ["/usr/local/bin/venv-sync-entrypoint.sh"]
CMD ["claude"]
