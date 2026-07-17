#!/usr/bin/env bash
#
# release.sh — cut a build-gated, tagged release of multiplai-container and
# advance the multiplai-kit pin (CONTAINER_REF) to it, in one atomic step.
#
# Why this exists: the runtime consumes this repo at an IMMUTABLE TAG, pinned
# by multiplai-kit/setup.sh (CONTAINER_REF). Merging a fix to `main` is NOT a
# release — nothing reaches consumers until a tag is cut AND the kit pin is
# bumped. Doing those two steps by hand across two repos is how a fix gets
# stranded (and how someone ends up hand-editing the kit's pinned checkout,
# which the next setup.sh silently clobbers). This script makes the release
# one command: it does ALL local work first (build gate, tag, kit-pin commit)
# and pushes both repos LAST, back-to-back — so the only failure window is a
# single push, not a half-finished multi-step edit stranded across two repos:
#
#   main clean + up to date  →  docker build MUST pass  →  commit+tag (local)
#     →  commit kit pin (local)  →  push container tag  →  push kit pin
#
# You cannot tag a broken image. If the final kit push fails the recovery is a
# one-liner — `git -C <kit> push origin HEAD` — because everything else is
# already committed locally.
#
# Usage:
#   ./release.sh <major|minor|patch>     # bump from VERSION
#   ./release.sh <X.Y[.Z]>               # explicit version
#
# Options:
#   --dry-run        Show what would happen; make no commits/tags/pushes
#   --yes            Don't prompt before pushing
#   --skip-build     Skip the docker build gate (loud warning; use only if you
#                    truly cannot build here — defeats the point)
#   --no-kit         Tag only; don't touch the kit pin
#   --kit <path>     multiplai-kit checkout to bump (default: auto-detect,
#                    else $MULTIPLAI_KIT)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---- args ------------------------------------------------------------------
BUMP=""
DRY_RUN=false; ASSUME_YES=false; SKIP_BUILD=false; DO_KIT=true; KIT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --yes|-y)    ASSUME_YES=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --no-kit)    DO_KIT=false ;;
    --kit)       KIT_DIR="${2:?--kit needs a path}"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    major|minor|patch) BUMP="$1" ;;
    [0-9]*)      BUMP="$1" ;;
    *) echo "release: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$BUMP" ] || { echo "release: need a version or major|minor|patch (see --help)" >&2; exit 2; }

say()  { printf '  %s\n' "$*"; }
step() { printf '\n▸ %s\n' "$*"; }
die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
# Execute argv directly — arguments are never re-parsed by the shell, so a
# tag/version containing shell metachars can't inject.
run()  { if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---- preflight: clean, on main, up to date ---------------------------------
step "Preflight"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo"
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = "main" ] || die "must release from main (on '$BRANCH')"
[ -z "$(git status --porcelain)" ] || die "working tree not clean — commit or stash first"
git fetch --quiet origin main
LOCAL="$(git rev-parse @)"
REMOTE="$(git rev-parse @{u} 2>/dev/null)" || die "main has no upstream — set one with 'git branch --set-upstream-to=origin/main main'"
[ "$LOCAL" = "$REMOTE" ] || die "local main not in sync with origin/main — pull/push first"
say "on main, clean, in sync with origin ($(git rev-parse --short @))"

# ---- compute next version --------------------------------------------------
step "Version"
CUR="$(cat VERSION 2>/dev/null || echo 0.0.0)"
IFS='.' read -r MA MI PA <<<"$CUR"; MA=${MA:-0}; MI=${MI:-0}; PA=${PA:-0}
case "$BUMP" in
  major) NEW="$((MA+1)).0.0" ;;
  minor) NEW="${MA}.$((MI+1)).0" ;;
  patch) NEW="${MA}.${MI}.$((PA+1))" ;;
  *)     [[ "$BUMP" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "bad version '$BUMP'"; NEW="$BUMP" ;;
esac
# Existing tags are vMAJOR.MINOR; keep a .0 PATCH implicit for a clean tag name
# and a matching VERSION file (0.5.0 → 0.5). Only strip the trailing .0 when it
# is the patch component (X.Y.0) — never fold an explicit X.0 down to X, so
# `./release.sh 1.0` and `./release.sh major` both yield v1.0.
case "$NEW" in
  *.*.0) NORM="${NEW%.0}" ;;
  *)     NORM="$NEW" ;;
esac
TAG="v$NORM"
say "current VERSION=$CUR  →  new=$NORM  →  tag=$TAG"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"

# ---- build gate ------------------------------------------------------------
step "Build gate"
if $SKIP_BUILD; then
  say "!! --skip-build: NOT verifying the image builds. A broken tag can ship."
else
  say "docker build (via build.sh) — a tag is only cut if this passes"
  if $DRY_RUN; then say "[dry-run] ./build.sh"; else ./build.sh || die "build failed — refusing to tag a broken image"; fi
  say "image built OK"
fi

# ---- locate kit (before tagging, so we fail early) -------------------------
if $DO_KIT; then
  if [ -z "$KIT_DIR" ]; then
    PARENT="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [ -f "$PARENT/claude.sh" ] && [ -d "$PARENT/dotfiles" ] && [ -f "$PARENT/setup.sh" ]; then
      KIT_DIR="$PARENT"                       # we're the kit's container/ checkout
    elif [ -n "${MULTIPLAI_KIT:-}" ]; then
      KIT_DIR="$MULTIPLAI_KIT"
    fi
  fi
  [ -n "$KIT_DIR" ] && [ -f "$KIT_DIR/setup.sh" ] || die "kit not found — pass --kit <path>, set \$MULTIPLAI_KIT, or use --no-kit"
  grep -qE 'CONTAINER_REF:-v[0-9]' "$KIT_DIR/setup.sh" || die "no CONTAINER_REF default found in $KIT_DIR/setup.sh"
  [ -z "$(git -C "$KIT_DIR" status --porcelain setup.sh)" ] || die "kit setup.sh has uncommitted changes — resolve first"
  # Structural guard: the pin commit must land on the kit SOURCE's main and be
  # pushable to origin/main. This refuses runtime checkouts
  # (~/.multiplai-runtimes/*, which carry a local config-drift commit) and any
  # stale or diverged clone — publishing from those pushes the wrong history.
  KIT_BRANCH="$(git -C "$KIT_DIR" branch --show-current)"
  [ "$KIT_BRANCH" = "main" ] || die "kit at $KIT_DIR is on '${KIT_BRANCH:-<detached>}', not main — point --kit at the kit SOURCE clone (e.g. PROJECTS/multiplai-kit), never a runtime checkout"
  git -C "$KIT_DIR" fetch --quiet origin main || die "cannot fetch origin/main in kit at $KIT_DIR"
  KIT_LOCAL="$(git -C "$KIT_DIR" rev-parse @)"
  KIT_REMOTE="$(git -C "$KIT_DIR" rev-parse origin/main)"
  [ "$KIT_LOCAL" = "$KIT_REMOTE" ] || die "kit main ($(git -C "$KIT_DIR" rev-parse --short @)) not in sync with origin/main ($(git -C "$KIT_DIR" rev-parse --short origin/main)) — a runtime checkout carries a local drift commit and a stale clone misses history; expected flow: edit in the kit SOURCE, pull/push it, then release with --kit <kit-source>"
  say "kit: $KIT_DIR (main, in sync with origin)"
fi

# ---- confirm ---------------------------------------------------------------
step "Plan"
say "tag $TAG on $(git remote get-url origin)"
$DO_KIT && say "bump CONTAINER_REF → $TAG in $KIT_DIR/setup.sh, commit + push kit"
if ! $ASSUME_YES && ! $DRY_RUN; then
  printf '\nProceed? [y/N] '; read -r ans; [ "$ans" = "y" ] || { echo "aborted."; exit 1; }
fi

# ---- tag this repo (local only; pushes happen last, together) --------------
step "Tagging $TAG (local)"
if $DRY_RUN; then say "[dry-run] write VERSION=$NORM"; else printf '%s\n' "$NORM" > VERSION; fi
run git add VERSION
run git commit -q -m "chore(release): $TAG"
run git tag -a "$TAG" -m "Release $TAG"
say "committed + tagged locally"

# ---- bump kit pin (local only; pushed last) --------------------------------
if $DO_KIT; then
  step "Advancing kit pin → $TAG (local)"
  SETUP="$KIT_DIR/setup.sh"
  if $DRY_RUN; then
    say "[dry-run] sed CONTAINER_REF:-<old> → $TAG in $SETUP; commit (push deferred)"
  else
    tmp="$(mktemp)"
    sed -E "s#(CONTAINER_REF:-)v[0-9][0-9.]*#\1${TAG}#" "$SETUP" > "$tmp"
    grep -qF "CONTAINER_REF:-${TAG}}" "$tmp" || { rm -f "$tmp"; die "kit pin rewrite failed — CONTAINER_REF not updated"; }
    # Write content in place (keeps $SETUP's inode + mode). A `mv` from mktemp
    # replaced the file with a 0600 temp and silently dropped the executable
    # bit — that regression shipped with v0.5 (kit commit 6ad8f64).
    cat "$tmp" > "$SETUP"
    rm -f "$tmp"
    [ -x "$SETUP" ] || die "kit setup.sh is not executable after the pin rewrite — restore it (chmod +x, commit) and re-run"
    git -C "$KIT_DIR" add setup.sh
    git -C "$KIT_DIR" commit -q -m "chore(container): pin CONTAINER_REF to $TAG"
    say "kit pinned to $TAG (committed, not yet pushed)"
  fi
fi

# ---- publish: push both repos last, back-to-back ---------------------------
# Everything above is committed locally; deferring both pushes to here shrinks
# the window in which the container tag exists on origin but the kit pin has
# not shipped. If the kit push below fails, recover with a single
# `git -C "$KIT_DIR" push origin HEAD` — nothing else is left half-done.
step "Publishing"
# --atomic: main and the tag land together or not at all — a raced rejection
# of main can't leave an orphaned public tag behind.
run git push --atomic --quiet origin main "$TAG"
say "pushed container main + $TAG"
if $DO_KIT; then
  if $DRY_RUN; then
    say "[dry-run] git -C $KIT_DIR push origin HEAD"
  else
    git -C "$KIT_DIR" push --quiet origin HEAD
    say "pushed kit pin"
  fi
fi

# ---- done ------------------------------------------------------------------
step "Released $TAG"
say "Consumers get it with:  git pull   &&   ./setup.sh"
say "(setup.sh re-pins container/ to $TAG, rebuilds the image, installs the host gateway)"
$DO_KIT || say "NOTE: --no-kit — bump CONTAINER_REF in the kit manually to deliver this."
