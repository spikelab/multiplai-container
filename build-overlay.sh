#!/usr/bin/env bash
# Build a project overlay image on top of the multiplai base image.
#
# An overlay is a small Dockerfile living in the CONSUMING project's repo — not
# here — that adds project-specific tooling (apt packages, locales, extra CLIs)
# without bloating the base image every consumer pulls. Contract for the
# overlay Dockerfile:
#
#   ARG BASE_IMAGE=claude-multiplai:local
#   FROM ${BASE_IMAGE}
#   USER root
#   RUN apt-get update && apt-get install -y --no-install-recommends ... \
#       && rm -rf /var/lib/apt/lists/*
#   USER agent            # the base image runs as agent; switch back
#   # ENTRYPOINT/CMD/ENV/WORKDIR are inherited — do not redefine them.
#
# The result is selected per launch by claude.sh: set
# IMAGE_NAME=<overlay tag> in an env.<profile> file (claude.sh applies its
# claude-multiplai:local default only after sourcing profiles, so the profile
# value wins).
#
# The built image is stamped with the base image's name and ID as labels, so
# claude.sh can warn when a base rebuild has left the overlay stale.
#
# Usage:
#   ./build-overlay.sh --dir <overlay-dir> --tag <image:tag> [--from <base-image>]

set -euo pipefail

usage() {
    echo "Usage: $0 --dir <overlay-dir> --tag <image:tag> [--from <base-image>]"
    echo "  --dir   Directory containing the overlay Dockerfile"
    echo "  --tag   Tag for the built overlay image (e.g. claude-multiplai-myproject:local)"
    echo "  --from  Base image to build on (default: claude-multiplai:local)"
}

BASE_IMAGE="claude-multiplai:local"
OVERLAY_DIR=""
TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    OVERLAY_DIR="$2"; shift 2 ;;
        --dir=*)  OVERLAY_DIR="${1#--dir=}"; shift ;;
        --tag)    TAG="$2"; shift 2 ;;
        --tag=*)  TAG="${1#--tag=}"; shift ;;
        --from)   BASE_IMAGE="$2"; shift 2 ;;
        --from=*) BASE_IMAGE="${1#--from=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$OVERLAY_DIR" ] || [ -z "$TAG" ]; then
    echo "Error: --dir and --tag are both required." >&2
    usage >&2
    exit 1
fi
if [ ! -f "$OVERLAY_DIR/Dockerfile" ]; then
    echo "Error: no Dockerfile in overlay dir: $OVERLAY_DIR" >&2
    exit 1
fi
# Building the overlay under the base's own tag would overwrite the base and
# make every later staleness check compare the image against itself.
if [ "$TAG" = "$BASE_IMAGE" ]; then
    echo "Error: --tag must differ from the base image ($BASE_IMAGE)." >&2
    exit 1
fi

# The base must exist locally: an overlay silently built on a docker-pulled or
# stale base is exactly the drift the labels below exist to catch.
if ! BASE_ID=$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE" 2>/dev/null); then
    echo "Error: base image '$BASE_IMAGE' not found locally." >&2
    echo "  Build it first: ./build.sh" >&2
    exit 1
fi

docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --label "multiplai.base-image-name=$BASE_IMAGE" \
    --label "multiplai.base-image-id=$BASE_ID" \
    -t "$TAG" \
    "$OVERLAY_DIR"

echo "Built $TAG on $BASE_IMAGE ($BASE_ID)"
echo "Select it per launch: IMAGE_NAME=$TAG in an env.<profile> file (see multiplai-kit docs/PROFILES.md)"
