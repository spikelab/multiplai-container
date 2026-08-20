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

# The tag an overlay image is built (and selected at launch) under. One
# formula, used by the collision guard and the build loop below — if the
# scheme ever changes, both must follow or the guard silently disarms.
overlay_tag() { printf 'claude-multiplai-%s:local\n' "$1"; }

# --- overlays.conf: parse and validate ONCE, before building ----------------
# overlays.conf, next to the .env that configured this build, registers project
# overlay images as `name:path` lines (path to a directory with an overlay
# Dockerfile — see build-overlay.sh for the contract). One pass here does the
# trimming, the name:path split, and the validation, and stores the surviving
# entries (newline-separated, re-split on the first `:` — names are
# charset-checked, so they cannot contain one) for the build loop after the
# base build. A second parser would have to agree with this one on every rule;
# the two copies this replaces already disagreed on malformed lines.
#
# It also enforces the IMAGE_NAME guard: IMAGE_NAME names the tag this script
# gives the BASE image. If the .env points it at a registered overlay's tag (a
# launch-selection value that belongs in an env.<profile> file, not here), the
# tool-less base would be built UNDER the overlay's name — destroying the
# overlay image and poisoning the staleness labels of everything built on it.
# Refuse before building. The guard is the FIRST thing each line meets, ahead
# of the validation that `continue`s: an entry too broken to build still names
# a tag the base build would overwrite. tests/build-test.sh pins that ordering.
OVERLAYS_CONF="$ENV_DIR/overlays.conf"
OVERLAY_ENTRIES=""
OVERLAY_FAILURES=0
if [ -f "$OVERLAYS_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim surrounding whitespace without forking. Comments are whole
        # lines only — stripping from any mid-line `#` would silently
        # truncate a path that contains one.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|\#*) continue ;; esac
        # The IMAGE_NAME guard runs FIRST, on the raw `${line%%:*}`, before any
        # validation below can `continue` past it. A malformed or badly-named
        # entry is unbuildable, but IMAGE_NAME still names the tag it claims —
        # and that tag is what the base build is about to overwrite. Guarding
        # after the validation skips leaves exactly those lines unprotected.
        if [ "$(overlay_tag "${line%%:*}")" = "$IMAGE_NAME" ]; then
            echo "Error: IMAGE_NAME ($IMAGE_NAME) is the tag of overlay '${line%%:*}' registered in" >&2
            echo "  $OVERLAYS_CONF. IMAGE_NAME in .env names the base image this script builds;" >&2
            echo "  select an overlay per launch via IMAGE_NAME in an env.<profile> file instead" >&2
            echo "  (see multiplai-kit docs/PROFILES.md)." >&2
            exit 1
        fi
        name="${line%%:*}"
        path="${line#*:}"
        if [ "$name" = "$line" ] || [ -z "$name" ] || [ -z "$path" ]; then
            echo "WARNING: skipping malformed overlays.conf line (want name:path): $line" >&2
            OVERLAY_FAILURES=$((OVERLAY_FAILURES + 1))
            continue
        fi
        # Docker repository names must be lowercase, so the tag built from the
        # name would be rejected otherwise.
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
        OVERLAY_ENTRIES="$OVERLAY_ENTRIES$name:$path
"
    done < "$OVERLAYS_CONF"
fi

# The Dockerfile uses `COPY --chmod=`, which the classic builder does not
# understand. BuildKit is the default from Docker 23, but an inherited
# DOCKER_BUILDKIT=0 (or an older daemon) would fail the build on a directive
# the image genuinely needs — so ask for it explicitly rather than inheriting.
export DOCKER_BUILDKIT=1

docker build \
    --build-arg HOST_UID="$HOST_UID" \
    --build-arg HOST_GID="$HOST_GID" \
    --build-arg WORKSPACE="$WORKSPACE" \
    --build-arg SSH_BUILD_USER="$SSH_BUILD_USER" \
    -t "$IMAGE_NAME" \
    "$SCRIPT_DIR"

# --- Overlay images (optional) ---
# Each validated overlays.conf entry (parsed above) is rebuilt on top of the
# base image just built. Docker's layer cache makes an unchanged entry a no-op
# in seconds, and a changed base or changed overlay Dockerfile busts the cache
# by itself — so building every entry every time IS the "rebuild only what
# changed" behaviour, with no state to track.
#
# A failing overlay warns but does not fail this script: the base image and
# everything setup.sh gates on it (the host gateway install) are unaffected by
# one broken overlay, and claude.sh separately warns at launch when an overlay
# is left behind on an older base.
if [ -n "$OVERLAY_ENTRIES" ]; then
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        name="${entry%%:*}"
        path="${entry#*:}"
        tag="$(overlay_tag "$name")"
        echo ""
        echo "Building overlay '$name' ($tag) from $path ..."
        if ! "$SCRIPT_DIR/build-overlay.sh" --dir "$path" --tag "$tag" --from "$IMAGE_NAME" </dev/null; then
            echo "WARNING: overlay '$name' failed to build — the base image is unaffected." >&2
            OVERLAY_FAILURES=$((OVERLAY_FAILURES + 1))
        fi
    done <<<"$OVERLAY_ENTRIES"
fi
if [ "$OVERLAY_FAILURES" -gt 0 ]; then
    echo "" >&2
    echo "WARNING: $OVERLAY_FAILURES overlays.conf entries failed or were skipped (see above)." >&2
    echo "  Fix and re-run: cd container && ./build.sh" >&2
fi
