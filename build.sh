#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Look for .env: the multiplai-kit root first (only if the parent actually IS
# a kit checkout — don't source a stranger's .env just because the clone
# happens to sit under a directory that has one), then this directory.
if [ -f "$PARENT_DIR/.env" ] && [ -f "$PARENT_DIR/claude.sh" ] && [ -d "$PARENT_DIR/dotfiles" ]; then
    # shellcheck disable=SC1091
    source "$PARENT_DIR/.env"
    ENV_DIR="$PARENT_DIR"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    ENV_DIR="$SCRIPT_DIR"
else
    echo "Error: No .env file found."
    echo "  cp .env.example .env   # next to this script, then fill in your values"
    echo "  (or run from a multiplai-kit checkout, whose root .env is used)"
    exit 1
fi

# Expand a leading ~ or $HOME in WORKSPACE without eval'ing .env content
WORKSPACE="${WORKSPACE:-}"
WORKSPACE="${WORKSPACE/#\~/$HOME}"
WORKSPACE="${WORKSPACE/#\$HOME/$HOME}"

: "${WORKSPACE:?WORKSPACE must be set in .env}"
# Guard against the .env.example placeholder and non-existent paths — a bad
# WORKSPACE bakes a useless mount point into the image and fails at runtime.
if [ "$WORKSPACE" = "$HOME/your-workspace" ]; then
    echo "Error: WORKSPACE is still the placeholder ($WORKSPACE)."
    echo "  Edit .env and set WORKSPACE to your real workspace path."
    exit 1
fi
if [ ! -d "$WORKSPACE" ]; then
    echo "Error: WORKSPACE directory does not exist: $WORKSPACE"
    exit 1
fi
IMAGE_NAME="${IMAGE_NAME:-claude-multiplai:local}"
HOST_UID="${HOST_UID:-$(id -u)}"
HOST_GID="${HOST_GID:-$(id -g)}"
SSH_BUILD_USER="${SSH_BUILD_USER:-$USER}"

docker build \
    --build-arg HOST_UID="$HOST_UID" \
    --build-arg HOST_GID="$HOST_GID" \
    --build-arg WORKSPACE="$WORKSPACE" \
    --build-arg SSH_BUILD_USER="$SSH_BUILD_USER" \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR"

# --- Overlay images (optional) ---
# overlays.conf, next to the .env that configured this build, registers project
# overlay images as `name:path` lines (path to a directory with an overlay
# Dockerfile — see build-overlay.sh for the contract). Each entry is rebuilt on
# top of the base image just built. Docker's layer cache makes an unchanged
# entry a no-op in seconds, and a changed base or changed overlay Dockerfile
# busts the cache by itself — so building every entry every time IS the
# "rebuild only what changed" behaviour, with no state to track.
#
# A failing overlay warns but does not fail this script: the base image and
# everything setup.sh gates on it (the host gateway install) are unaffected by
# one broken overlay, and claude.sh separately warns at launch when an overlay
# is left behind on an older base.
OVERLAYS_CONF="$ENV_DIR/overlays.conf"
if [ -f "$OVERLAYS_CONF" ]; then
    OVERLAY_FAILURES=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        # Trim surrounding whitespace without forking
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        name="${line%%:*}"
        path="${line#*:}"
        if [ "$name" = "$line" ] || [ -z "$name" ] || [ -z "$path" ]; then
            echo "WARNING: skipping malformed overlays.conf line (want name:path): $line" >&2
            OVERLAY_FAILURES=$((OVERLAY_FAILURES + 1))
            continue
        fi
        # Docker repository names must be lowercase, so the tag built from the
        # name below would be rejected otherwise.
        case "$name" in
            *[!a-z0-9_.-]*)
                echo "WARNING: skipping overlay with invalid name (allowed: a-z 0-9 _ . -): $name" >&2
                OVERLAY_FAILURES=$((OVERLAY_FAILURES + 1))
                continue ;;
        esac
        # Path: absolute, ~/$HOME-prefixed, or relative to WORKSPACE.
        path="${path/#\~/$HOME}"
        path="${path/#\$HOME/$HOME}"
        case "$path" in
            /*) ;;
            *) path="$WORKSPACE/$path" ;;
        esac
        tag="claude-multiplai-${name}:local"
        echo ""
        echo "Building overlay '$name' ($tag) from $path ..."
        if ! "$SCRIPT_DIR/build-overlay.sh" --dir "$path" --tag "$tag" --from "$IMAGE_NAME"; then
            echo "WARNING: overlay '$name' failed to build — the base image is unaffected." >&2
            OVERLAY_FAILURES=$((OVERLAY_FAILURES + 1))
        fi
    done < "$OVERLAYS_CONF"
    if [ "$OVERLAY_FAILURES" -gt 0 ]; then
        echo "" >&2
        echo "WARNING: $OVERLAY_FAILURES overlays.conf entries failed or were skipped (see above)." >&2
        echo "  Fix and re-run: cd container && ./build.sh" >&2
    fi
fi
