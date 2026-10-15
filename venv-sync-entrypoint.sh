#!/usr/bin/env bash
# Entrypoint that syncs a Linux venv from kit requirements,
# then hands off to CMD (claude by default, or bash for dshell).
set -euo pipefail

# Bridge host/container path mismatch for Claude Code session storage.
# Claude writes absolute paths into sessions-index.json using $HOME/.claude/...
# Host HOME (e.g., /Users/you) differs from container HOME (/home/agent),
# so sessions created on one side have broken paths on the other.
# Symlink the host path so both resolve to the same mounted directory.
if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "$HOME" ]; then
    HOST_CLAUDE_DIR="$HOST_HOME/.claude"
    if [ ! -e "$HOST_CLAUDE_DIR" ]; then
        mkdir -p "$(dirname "$HOST_CLAUDE_DIR")" 2>/dev/null || true
        ln -sfn "$HOME/.claude" "$HOST_CLAUDE_DIR" 2>/dev/null || true
    fi
fi

# --- Kit venv sync (only when launched via multiplai-kit) ---
# CLAUDE_MULTIPLAI_HOME points at the kit checkout (the kit's claude.sh sets
# it). Standalone `docker run` users don't have a kit, so when it's unset we
# skip the venv sync entirely instead of refusing to start.
sync_kit_venv() {
    if [ -z "${CLAUDE_MULTIPLAI_HOME:-}" ]; then
        echo "[venv-sync] CLAUDE_MULTIPLAI_HOME not set — skipping kit venv sync (standalone mode)."
        return 0
    fi

    local VENV_PATH="$CLAUDE_MULTIPLAI_HOME/.venv"
    local HASH_FILE="$VENV_PATH/.last-sync-hash"
    # Kit requirements.txt lives at the kit project root (one level up from dotfiles/).
    local KIT_REQ_FILE="$CLAUDE_MULTIPLAI_HOME/requirements.txt"

    # --- Create Linux venv if it doesn't exist yet ---
    if [ ! -f "$VENV_PATH/bin/python3" ]; then
        echo "[venv-sync] Creating Linux venv at $VENV_PATH ..."
        python3 -m venv "$VENV_PATH"
        # Force a sync on fresh venv
        rm -f "$HASH_FILE"
    fi

    # --- Sync packages if requirements changed ---
    if [ ! -f "$KIT_REQ_FILE" ]; then
        echo "[venv-sync] WARNING: No requirements.txt found at $KIT_REQ_FILE. Hooks requiring Python packages will fail."
        return 0
    fi
    local CURRENT_HASH LAST_HASH
    CURRENT_HASH=$(md5sum "$KIT_REQ_FILE" 2>/dev/null | cut -d' ' -f1)
    LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
    if [ "$CURRENT_HASH" = "$LAST_HASH" ]; then
        echo "[venv-sync] Packages up to date."
        return 0
    fi

    echo "[venv-sync] Requirements changed — syncing packages ..."
    # First pass: try batch install (fast path for all-compatible packages)
    # python -m pip, not bin/pip: the pip script's shebang hardcodes the
    # venv's creation path and breaks if the volume is mounted elsewhere.
    if "$VENV_PATH/bin/python" -m pip install --quiet -r "$KIT_REQ_FILE" >/dev/null 2>&1; then
        echo "[venv-sync] All packages installed successfully."
        echo "$CURRENT_HASH" > "$HASH_FILE"
    else
        # Second pass: install line-by-line. Distinguish platform-
        # incompatible packages (safe to skip and cache) from transient
        # failures like network errors (must NOT be cached as synced,
        # or the packages stay missing until requirements.txt changes).
        echo "[venv-sync] Batch install failed. Installing individually ..."
        local SKIPPED="" HARD_FAIL=0 line PKG_ERR PKG_NAME
        while IFS= read -r line; do
            # Skip comments, blank lines, and pip options
            [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$|^- ]] && continue
            if ! PKG_ERR=$("$VENV_PATH/bin/python" -m pip install --quiet "$line" 2>&1); then
                # Package name: everything before the first version/extras
                # marker (=, <, >, [).
                PKG_NAME="${line%%[=<>[]*}"
                if echo "$PKG_ERR" | grep -qiE 'no matching distribution|not supported on this platform|unsupported platform'; then
                    SKIPPED="$SKIPPED $PKG_NAME"
                else
                    HARD_FAIL=1
                    echo "[venv-sync] ERROR installing $PKG_NAME:"
                    echo "$PKG_ERR" | tail -3 | sed 's/^/[venv-sync]   /'
                fi
            fi
        done < "$KIT_REQ_FILE"
        if [ -n "$SKIPPED" ]; then
            echo "[venv-sync] Skipped (not available on Linux):$SKIPPED"
        fi
        if [ "$HARD_FAIL" -eq 1 ]; then
            echo "[venv-sync] WARNING: some installs failed (network?) — not caching; will retry next start."
        else
            echo "$CURRENT_HASH" > "$HASH_FILE"
        fi
    fi
    echo "[venv-sync] Done."
}
sync_kit_venv

# --- Claude Code CLI auto-update (persistent, survives container restarts) ---
# The image bakes a claude version at build time, but images go stale. When the
# launcher mounts a persistent dir at ~/.claude-cli, keep a self-updating copy
# there (npm prefix install, refreshed every MULTIPLAI_CLI_UPDATE_DAYS, default
# weekly) and prefer it on PATH. No mount → baked version, no update attempts.
CLI_DIR="$HOME/.claude-cli"
if [ -d "$CLI_DIR" ]; then
    UPDATE_DAYS="${MULTIPLAI_CLI_UPDATE_DAYS:-7}"
    STAMP="$CLI_DIR/.last-update"
    NEED_UPDATE=0
    if [ ! -x "$CLI_DIR/bin/claude" ]; then
        NEED_UPDATE=1
    elif [ ! -f "$STAMP" ] || ! find "$STAMP" -mtime -"$UPDATE_DAYS" 2>/dev/null | grep -q .; then
        NEED_UPDATE=1
    fi
    # mkdir is atomic: if another container sharing this mount is already
    # updating, skip this round rather than racing the npm install.
    if [ "$NEED_UPDATE" -eq 1 ] && mkdir "$CLI_DIR/.update-lock" 2>/dev/null; then
        trap 'rmdir "$CLI_DIR/.update-lock" 2>/dev/null || true' EXIT
        echo "[entrypoint] Updating Claude Code CLI (every ${UPDATE_DAYS}d) ..."
        if npm install -g --prefix "$CLI_DIR" @anthropic-ai/claude-code@latest >/dev/null 2>&1; then
            date > "$STAMP"
            echo "[entrypoint] Claude Code CLI: $("$CLI_DIR/bin/claude" --version 2>/dev/null || echo updated)"
        else
            echo "[entrypoint] CLI update failed (offline?) — using $(claude --version 2>/dev/null || echo 'baked version')"
        fi
        rmdir "$CLI_DIR/.update-lock" 2>/dev/null || true
        trap - EXIT
    fi
    if [ -x "$CLI_DIR/bin/claude" ]; then
        export PATH="$CLI_DIR/bin:$PATH"
    fi
fi

# --- pi and Codex CLI auto-update (persistent, survives container restarts) ---
# Same scheme as the Claude block above, for the other two agent CLIs. The
# image bakes a pinned copy of each (/usr/local/bin/pi, /usr/local/bin/codex);
# when the launcher mounts the folder below, a self-updating copy is kept
# there with the vendor's own installer and put first on PATH. No mount →
# baked copy, no install attempts.
#
#   pi     ~/.pi-cli/agent/bin/pi   pi.dev/install.sh once, then `pi update`
#   Codex  ~/.codex/bin/codex       chatgpt.com/codex/install.sh each time
#
# A refresh is skipped while its .last-update stamp is younger than
# MULTIPLAI_CLI_UPDATE_DAYS (default 7), and serialised across containers
# sharing the mount by a mkdir lock, .update-lock. A lock older than 30
# minutes is left by a container killed mid-update: it is removed and the
# refresh runs (each installer cleans its own staging). A younger one means
# another container is updating right now: this one neither waits nor
# retries, and uses whichever copy is already there.
#
# Each installer runs with PATH=<its bin dir>:/usr/bin:/bin. Leaving out
# /usr/local/bin hides the baked copies: pi's installer refuses to install
# while a pi it does not manage is on PATH, and offers to npm-uninstall it.
# Putting the bin dir first keeps both installers out of the rest of $HOME:
# pi's links itself from ~/.local/bin when that comes first on PATH, and
# Codex's appends a PATH block to ~/.bashrc when its bin dir is missing.
# pi also runs under `setsid -w`, with no controlling terminal: otherwise
# its installer opens /dev/tty, which a `docker run -it` session has, and
# waits at an interactive menu (pi.dev/install.sh, read 2026-10-14).
#
# A copy counts as installed only when it answers --version. pi's installer
# writes its launcher before install/current-version, and a launcher without
# that file exits 1 on every command, `pi update` included; a start killed
# between the two writes is resumed by running the installer again.
#
# Nothing here may stop the container from starting. A failure prints one
# [entrypoint] line naming the copy still in use, writes no stamp, and the
# next start retries.
CLI_INSTALLER_PATH="/usr/bin:/bin"
CLI_LOCK_STALE_MINUTES=30
CLI_LOCK_HELD=""

# cli_runs <bin> — <bin> is there and answers --version.
cli_runs() {
    [ -x "$1" ] && "$1" --version >/dev/null 2>&1
}

# cli_version <command> — the version `<command> --version` reports, without
# a program name in front (`codex-cli 0.159.2` → 0.159.2).
cli_version() {
    local v=""
    v="$("$1" --version 2>/dev/null | awk 'NR == 1 { print $NF }')" || true
    echo "${v:-unknown}"
}

# Fetching an install script gets its own time limits, so a network that drops
# packets or stalls mid-transfer cannot hold up the start: curl has no total
# limit by default. Both scripts are under 64 KiB (56 KB and 35 KB,
# 2026-10-14), so they fit in the pipe and curl is done before sh runs the
# slow part; the limit never cuts a script short.
CLI_CURL_LIMITS=(--connect-timeout 10 --max-time 120)

# These limits cover only the script. What the installer then downloads (pi's
# release and its npm dependencies, Codex's release archive), and all of
# `pi update`, is bounded by GNU timeout around the whole run: TERM after
# 600 s, KILL 10 s later for anything still running. 600 s is longer than
# Codex's own limits on its release downloads (30 s for the release list,
# 300 s for the archive; chatgpt.com/codex/install.sh, read 2026-10-14), so a
# download those limits would let finish is not cut short; its fallback
# fetch from GitHub has no limit of its own, and this is that limit. And
# 610 s is a third of the 30-minute rule above, so the lock of a refresh
# that is still running can never be taken for one a killed container left.
# A refresh stopped this way takes the ordinary failure path below.
#
# timeout runs without --foreground so that it signals its whole process
# group, not just its direct child: the processes the installer starts
# (curl, tar, npm) die with it. That group is the setsid session for pi; for Codex,
# timeout makes one of its own. Codex's installer is non-interactive here and
# never reads the terminal, so running it outside the terminal's foreground
# group cannot stop it.
CLI_RUN_LIMITS=(--kill-after=10 600)

pi_install() {  # $1 = ~/.pi-cli
    curl -fsSL "${CLI_CURL_LIMITS[@]}" https://pi.dev/install.sh \
        | setsid -w timeout "${CLI_RUN_LIMITS[@]}" \
              env PATH="$1/agent/bin:$CLI_INSTALLER_PATH" PI_CODING_AGENT_DIR="$1/agent" sh
}

pi_update() {  # $1 = ~/.pi-cli
    setsid -w timeout "${CLI_RUN_LIMITS[@]}" \
        env PATH="$1/agent/bin:$CLI_INSTALLER_PATH" PI_CODING_AGENT_DIR="$1/agent" \
        "$1/agent/bin/pi" update </dev/null
}

codex_install() {  # $1 = ~/.codex — installs, or updates an existing install
    curl -fsSL "${CLI_CURL_LIMITS[@]}" https://chatgpt.com/codex/install.sh \
        | timeout "${CLI_RUN_LIMITS[@]}" \
              env PATH="$1/bin:$CLI_INSTALLER_PATH" CODEX_HOME="$1" CODEX_INSTALL_DIR="$1/bin" \
              CODEX_NON_INTERACTIVE=1 sh
}

# refresh_cli <name> <dir> <bin> <install-fn> <update-fn> — install <bin> if
# it is missing or does not run, update it if its stamp is older than the
# interval, under the folder's lock. Returns 0 when <bin> is the copy to put
# first on PATH, 1 when the baked copy should run instead.
refresh_cli() {
    local name="$1" dir="$2" bin="$3" install_fn="$4" update_fn="$5"
    local days="${MULTIPLAI_CLI_UPDATE_DAYS:-7}"
    local stamp="$dir/.last-update" lock="$dir/.update-lock"
    local verb fn

    # The stamp is written only after a refresh that left <bin> running.
    if [ -x "$bin" ] && [ -f "$stamp" ] \
            && find "$stamp" -mtime -"$days" 2>/dev/null | grep -q .; then
        return 0
    fi
    if cli_runs "$bin"; then
        verb=update; fn="$update_fn"
    else
        verb=install; fn="$install_fn"
    fi

    if [ ! -w "$dir" ]; then
        if [ "$verb" = update ]; then
            echo "[entrypoint] $dir is not writable — using installed $name $(cli_version "$bin")"
            return 0
        fi
        echo "[entrypoint] $dir is not writable — using baked $name $(cli_version "$name")"
        return 1
    fi

    if find "$lock" -maxdepth 0 -mmin +"$CLI_LOCK_STALE_MINUTES" 2>/dev/null | grep -q .; then
        rmdir "$lock" 2>/dev/null || true
    fi
    if ! mkdir "$lock" 2>/dev/null; then
        if cli_runs "$bin"; then
            echo "[entrypoint] $name $verb in progress elsewhere — using installed $name"
            return 0
        fi
        echo "[entrypoint] $name $verb in progress elsewhere — using baked $name"
        return 1
    fi
    CLI_LOCK_HELD="$lock"
    trap 'rmdir "$CLI_LOCK_HELD" 2>/dev/null || true' EXIT

    if [ "$verb" = install ]; then
        echo "[entrypoint] Installing $name ..."
    else
        echo "[entrypoint] Updating $name (every ${days}d) ..."
    fi
    local rc=0
    if "$fn" "$dir" >/dev/null 2>&1 && cli_runs "$bin"; then
        date > "$stamp" 2>/dev/null || true
        echo "[entrypoint] $name: $(cli_version "$bin")"
    elif cli_runs "$bin"; then
        echo "[entrypoint] $name $verb failed (offline?) — using installed $name $(cli_version "$bin")"
    else
        echo "[entrypoint] $name $verb failed (offline?) — using baked $name $(cli_version "$name")"
        rc=1
    fi

    rmdir "$lock" 2>/dev/null || true
    trap - EXIT
    CLI_LOCK_HELD=""
    return "$rc"
}

PI_CLI_DIR="$HOME/.pi-cli"
if [ -d "$PI_CLI_DIR" ]; then
    if refresh_cli pi "$PI_CLI_DIR" "$PI_CLI_DIR/agent/bin/pi" pi_install pi_update; then
        export PATH="$PI_CLI_DIR/agent/bin:$PATH"
    fi
fi

CODEX_DIR="$HOME/.codex"
if [ -d "$CODEX_DIR" ]; then
    if refresh_cli codex "$CODEX_DIR" "$CODEX_DIR/bin/codex" codex_install codex_install; then
        export PATH="$CODEX_DIR/bin:$PATH"
    fi
fi

# --- Secret-gate drift warning (never blocks) ---
# The image gates every repo via core.hooksPath in /etc/gitconfig, but a
# repo-local core.hooksPath (husky/lefthook-style) outranks system config and
# silently un-gates that repo. Detection is the compensating control: warn at
# container start, keep going.
#
# Interactive `claude` sessions only ($1 is the command this entrypoint will
# exec; the launcher passes `claude …`, and the image's default CMD is
# `claude`). The same image also serves dshell (`bash`), hub driver
# containers (the hub's runner), and the launcher's post-exit drain container
# (`bash -c …` with stdio discarded) — a workspace walk whose warning nobody
# can see is a scan not worth paying for.
if [ "${1:-}" = claude ] && [ -x /usr/local/share/git-hooks/check-hookspath ]; then
    /usr/local/share/git-hooks/check-hookspath "${WORKSPACE:-}" || true
fi

exec "$@"
