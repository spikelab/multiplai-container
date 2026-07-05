#!/usr/bin/env bash
# Entrypoint that syncs a Linux venv from kit requirements,
# then hands off to CMD (claude by default, or bash for dshell).
set -e

: "${CLAUDE_MULTIPLAI_HOME:?CLAUDE_MULTIPLAI_HOME environment variable must be set}"

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
        if "$VENV_PATH/bin/pip" install --quiet -r "$KIT_REQ_FILE" 2>/dev/null; then
            echo "[venv-sync] All packages installed successfully."
        else
            # Second pass: install line-by-line, skip platform-incompatible packages
            echo "[venv-sync] Some packages failed. Installing compatible ones individually ..."
            SKIPPED=""
            while IFS= read -r line; do
                # Skip comments, blank lines, and pip options
                [[ "$line" =~ ^[[:space:]]*#|^[[:space:]]*$|^- ]] && continue
                if ! "$VENV_PATH/bin/pip" install --quiet "$line" 2>/dev/null; then
                    PKG_NAME=$(echo "$line" | cut -d'=' -f1 | cut -d'>' -f1 | cut -d'<' -f1 | cut -d'[' -f1)
                    SKIPPED="$SKIPPED $PKG_NAME"
                fi
            done < "$KIT_REQ_FILE"
            if [ -n "$SKIPPED" ]; then
                echo "[venv-sync] Skipped (not available on Linux):$SKIPPED"
            fi
        fi

        echo "$CURRENT_HASH" > "$HASH_FILE"
        echo "[venv-sync] Done."
    else
        echo "[venv-sync] Packages up to date."
    fi
else
    echo "[venv-sync] WARNING: No requirements.txt found at $KIT_REQ_FILE. Hooks requiring Python packages will fail."
fi

exec "$@"
