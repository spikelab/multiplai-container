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
if [ -z "${CLAUDE_MULTIPLAI_HOME:-}" ]; then
    echo "[venv-sync] CLAUDE_MULTIPLAI_HOME not set — skipping kit venv sync (standalone mode)."
else

VENV_PATH="$CLAUDE_MULTIPLAI_HOME/.venv"
HASH_FILE="$VENV_PATH/.last-sync-hash"

# Kit requirements.txt lives at the kit project root (one level up from dotfiles/).
KIT_REQ_FILE="$CLAUDE_MULTIPLAI_HOME/requirements.txt"

# --- Create Linux venv if it doesn't exist yet ---
if [ ! -f "$VENV_PATH/bin/python3" ]; then
    echo "[venv-sync] Creating Linux venv at $VENV_PATH ..."
    python3 -m venv "$VENV_PATH"
    # Force a sync on fresh venv
    rm -f "$HASH_FILE"
fi

# --- Sync packages if requirements changed ---
if [ -f "$KIT_REQ_FILE" ]; then
    CURRENT_HASH=$(md5sum "$KIT_REQ_FILE" 2>/dev/null | cut -d' ' -f1)
    LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

    if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
        echo "[venv-sync] Requirements changed — syncing packages ..."

        # First pass: try batch install (fast path for all-compatible packages)
        if "$VENV_PATH/bin/pip" install --quiet -r "$KIT_REQ_FILE" >/dev/null 2>&1; then
            echo "[venv-sync] All packages installed successfully."
            echo "$CURRENT_HASH" > "$HASH_FILE"
        else
            # Second pass: install line-by-line. Distinguish platform-
            # incompatible packages (safe to skip and cache) from transient
            # failures like network errors (must NOT be cached as synced,
            # or the packages stay missing until requirements.txt changes).
            echo "[venv-sync] Batch install failed. Installing individually ..."
            SKIPPED=""
            HARD_FAIL=0
            while IFS= read -r line; do
                # Skip comments, blank lines, and pip options
                [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$|^- ]] && continue
                if ! PKG_ERR=$("$VENV_PATH/bin/pip" install --quiet "$line" 2>&1); then
                    PKG_NAME=$(echo "$line" | cut -d'=' -f1 | cut -d'>' -f1 | cut -d'<' -f1 | cut -d'[' -f1)
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
    else
        echo "[venv-sync] Packages up to date."
    fi
else
    echo "[venv-sync] WARNING: No requirements.txt found at $KIT_REQ_FILE. Hooks requiring Python packages will fail."
fi

fi  # end kit venv sync

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

exec "$@"
