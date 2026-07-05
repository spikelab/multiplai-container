#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Look for .env: kit root first, then container dir (backward compat)
if [ -f "$KIT_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$KIT_ROOT/.env"
elif [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
else
    echo "Error: No .env file found."
    echo "  cp .env.example .env   # in the kit root, then fill in your values"
    exit 1
fi

# Expand ~ and $HOME in WORKSPACE
WORKSPACE=$(eval echo "${WORKSPACE:-}")

: "${WORKSPACE:?WORKSPACE must be set in .env}"
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
