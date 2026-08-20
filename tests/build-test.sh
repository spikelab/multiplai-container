#!/usr/bin/env bash
# build-test.sh — stub-docker harness for build.sh's overlays.conf handling.
#
# There is no daemon inside a Claude session container and the host bridge does
# not allowlist `docker`, so this harness does what multiplai-docker-test.sh
# does: a stub `docker` first on PATH records the argv it was handed, and the
# assertions are about the DECISION build.sh makes — does it refuse, does it
# build, under which tag — never about what a real build would produce.
#
# What it exists to pin: the IMAGE_NAME/overlay collision guard. IMAGE_NAME
# names the tag build.sh gives the BASE image. If .env points it at a
# registered overlay's tag, the tool-less base is built UNDER the overlay's
# name, destroying that overlay image. The guard must refuse BEFORE any
# `docker build` runs — including for overlays.conf lines that are themselves
# malformed or badly named, which is precisely when a build.sh that validates
# first and guards second stops seeing the entry it is meant to protect.
#
# Requirements: bash. No daemon, no network, no docker.
#
# Usage:  ./tests/build-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../build.sh"
[ -f "$SRC" ] || { echo "SKIP: build.sh not found at $SRC"; exit 2; }

# shellcheck source=tests/harness.sh
. "$HERE/harness.sh"

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/bin"
DIR="$TMP/container"     # build.sh's SCRIPT_DIR: holds .env and overlays.conf
WS="$TMP/ws"             # a real directory, so the WORKSPACE check passes
ARGV="$TMP/docker-argv.log"
OVERLAY_ARGV="$TMP/overlay-argv.log"

mkdir -p "$STUB" "$DIR" "$WS" "$WS/overlays/dolce"

# The stub docker: record argv, succeed. Never reached on a guard refusal,
# which is the whole point of the assertions below.
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_ARGV_LOG"
exit 0
EOF
chmod +x "$STUB/docker"

# build.sh delegates each overlay to build-overlay.sh next to itself.
cat > "$DIR/build-overlay.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OVERLAY_ARGV_LOG"
exit 0
EOF
chmod +x "$DIR/build-overlay.sh"

cp "$SRC" "$DIR/build.sh"
chmod +x "$DIR/build.sh"

# run <image_name> <overlays.conf content> — returns build.sh's exit status,
# leaving stdout+stderr in $OUT and the two argv logs freshly truncated.
OUT=""
run() {
    local image="$1" conf="$2"
    : > "$ARGV"
    : > "$OVERLAY_ARGV"
    printf 'WORKSPACE=%s\nIMAGE_NAME=%s\n' "$WS" "$image" > "$DIR/.env"
    if [ -n "$conf" ]; then printf '%s\n' "$conf" > "$DIR/overlays.conf"
    else rm -f "$DIR/overlays.conf"; fi
    OUT="$(PATH="$STUB:$PATH" DOCKER_ARGV_LOG="$ARGV" OVERLAY_ARGV_LOG="$OVERLAY_ARGV" \
        "$DIR/build.sh" 2>&1)"
}

docker_ran() { [ -s "$ARGV" ]; }

# expect_refused <name> <image> <conf> — build.sh must exit non-zero AND must
# not have invoked docker. Refusing after the base build has already clobbered
# the overlay tag would be worthless, so both halves are asserted.
expect_refused() {
    local name="$1" image="$2" conf="$3" status
    run "$image" "$conf"; status=$?
    if [ "$status" -eq 0 ]; then
        fail "$name" "expected non-zero exit, got 0" "output: $OUT"
    elif docker_ran; then
        fail "$name" "refused (exit $status) but docker had already run:" "$(cat "$ARGV")"
    elif ! printf '%s' "$OUT" | grep -q 'is the tag of overlay'; then
        fail "$name" "exit $status but not the collision-guard message" "output: $OUT"
    else
        ok "$name"
    fi
}

expect_built() {
    local name="$1" image="$2" conf="$3" status
    run "$image" "$conf"; status=$?
    if [ "$status" -ne 0 ]; then
        fail "$name" "expected exit 0, got $status" "output: $OUT"
    elif ! grep -q -- "-t $image" "$ARGV"; then
        fail "$name" "docker was not asked to build -t $image" "argv: $(cat "$ARGV")"
    else
        ok "$name"
    fi
}

echo "build.sh overlays.conf handling"

# 1. The baseline the guard was written for: a well-formed entry whose tag
#    IMAGE_NAME has been pointed at.
expect_refused "well-formed colliding entry is refused before any build" \
    "claude-multiplai-dolce:local" "dolce:overlays/dolce"

# 2. The same collision on a line that is ALSO malformed (no `:path` — a
#    truncated edit or a stray newline). A malformed line is skipped with a
#    warning, but the tag it names is still about to be overwritten, so the
#    guard must fire first. This is the case that regresses when the guard is
#    folded in after the validation `continue`s.
expect_refused "colliding entry is refused even when the line is malformed" \
    "claude-multiplai-dolce:local" "dolce"

# 3. And on a line whose name fails the lowercase charset rule. Same reasoning:
#    the entry is unbuildable, but IMAGE_NAME still names its tag.
expect_refused "colliding entry is refused even when the name is invalid" \
    "claude-multiplai-Dolce:local" "Dolce:overlays/dolce"

# 4. No collision: the base build proceeds under IMAGE_NAME as normal.
expect_built "non-colliding overlays.conf builds the base image" \
    "claude-multiplai:local" "dolce:overlays/dolce"

# 5. No overlays.conf at all: nothing to collide with.
expect_built "absent overlays.conf builds the base image" \
    "claude-multiplai-dolce:local" ""

# 6. Comments and blank lines are not entries, so they cannot trip the guard.
#    `claude-multiplai-:local` is the tag a guard reading an empty name would
#    compute — asserting it builds pins that no such name is derived.
expect_built "comments and blank lines are not overlay entries" \
    "claude-multiplai-:local" "# dolce:overlays/dolce

  # indented comment"

finish "build-test"
