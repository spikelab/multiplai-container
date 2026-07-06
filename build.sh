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
elif [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
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
