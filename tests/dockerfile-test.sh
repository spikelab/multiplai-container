#!/usr/bin/env bash
# dockerfile-test.sh — static assertions over the Dockerfile's Playwright layer
# and the pinned pi and Codex fallbacks.
#
# There is no daemon inside a Claude session container, so nothing here builds
# the image; `release.sh` does that, and the in-build smoke check is what
# proves the browsers start. What this harness pins is that the smoke check,
# and the pieces it depends on, are still THERE: a later edit that drops the
# launch, splits the cleanup into its own layer, or forgets the browsers path
# would otherwise ship an image that builds green and fails in the first
# session that opens a browser.
#
# Assertions run over logical instructions — continuation lines joined the way
# Docker joins them — so "in the same RUN" means the same layer.
#
# Requirements: bash, awk, grep. No daemon, no network, no docker.
#
# Usage:  ./tests/dockerfile-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Dockerfile"
[ -f "$SRC" ] || { echo "SKIP: Dockerfile not found at $SRC"; exit 2; }

# shellcheck source=tests/harness.sh
. "$HERE/harness.sh"

# One logical instruction per line: a trailing backslash joins the next line.
# Comment lines are dropped first, as Docker drops them.
INSTRUCTIONS="$(grep -v '^[[:space:]]*#' "$SRC" | awk '
    { line = $0 }
    sub(/\\$/, "", line) { buf = buf line; next }
    { print buf line; buf = "" }
')"

# expect_line <name> <ERE> — some logical instruction matches.
expect_line() {
    if grep -Eq -- "$2" <<<"$INSTRUCTIONS"; then ok "$1"; else fail "$1" "no instruction matches: $2"; fi
}

expect_line "PLAYWRIGHT_VERSION is a pinned ARG" \
    '^ARG PLAYWRIGHT_VERSION=[0-9]+\.[0-9]+\.[0-9]+$'
expect_line "PLAYWRIGHT_BROWSERS_PATH is set as ENV" \
    '^ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright$'
expect_line "NODE_PATH exposes the global install to require()" \
    '^ENV NODE_PATH=/usr/lib/node_modules$'

# The one RUN that installs the browsers. Everything below must be in it.
LAYER="$(grep -E '^RUN .*playwright install' <<<"$INSTRUCTIONS")"
count="$(grep -c . <<<"$LAYER")"
if [ "$count" -eq 1 ]; then
    ok "exactly one RUN installs the Playwright browsers"
else
    fail "exactly one RUN installs the Playwright browsers" "found $count"
fi

# expect_layer <name> <ERE> — the install layer matches.
expect_layer() {
    if grep -Eq -- "$2" <<<"$LAYER"; then ok "$1"; else fail "$1" "install layer does not match: $2"; fi
}

expect_layer "the npm install uses the pinned version" \
    'npm install -g "?playwright@\$\{PLAYWRIGHT_VERSION\}'
expect_layer "browsers come with --with-deps, both chromium builds" \
    'playwright install --with-deps chromium chromium-headless-shell'
expect_layer "apt lists are cleaned in the same layer" \
    'rm -rf [^&]*/var/lib/apt/lists/\*'
expect_layer "the smoke check launches chromium" \
    'chromium\.launch\('
expect_layer "the smoke check covers the full chromium build too" \
    'channel: "chromium"'
expect_layer "the smoke check reads the rendered page back" \
    'textContent\("p"\)'
expect_layer "the smoke check fails the build on error" \
    'process\.exit\(1\)'
expect_layer "the smoke check runs as an unprivileged user" \
    'setpriv --reuid=[0-9]+'

# The smoke check must come after the browsers are installed, or it tests
# nothing (and fails for the wrong reason).
if awk '{ i = index($0, "playwright install"); j = index($0, "chromium.launch("); exit !(i && j && i < j) }' <<<"$LAYER"; then
    ok "the smoke check runs after the install"
else
    fail "the smoke check runs after the install"
fi

# --- pi and Codex: the baked fallbacks behind the entrypoint's weekly copies ---
# The entrypoint keeps a self-updating copy of each in a mounted folder; these
# baked copies are what a session runs when that folder is absent, the first
# install failed, or another container holds the update lock. An unpinned
# version here would make the fallback whatever was newest on build day.
expect_line "PI_VERSION is a pinned ARG" \
    '^ARG PI_VERSION=[0-9]+\.[0-9]+\.[0-9]+$'
expect_line "CODEX_VERSION is a pinned ARG" \
    '^ARG CODEX_VERSION=[0-9]+\.[0-9]+\.[0-9]+$'
expect_line "the pi layer installs the pinned version with npm" \
    '^RUN .*npm install -g .*@earendil-works/pi-coding-agent@\$\{PI_VERSION\}'
expect_line "the Codex layer pins its release to CODEX_VERSION" \
    '^RUN .*CODEX_RELEASE="?\$\{CODEX_VERSION\}'
expect_line "the Codex layer installs non-interactively" \
    '^RUN .*CODEX_NON_INTERACTIVE=1'
expect_line "the Codex layer puts the binary in /usr/local/bin" \
    '^RUN .*CODEX_INSTALL_DIR=/usr/local/bin'
expect_line "the Codex layer keeps its releases in /opt/codex" \
    '^RUN .*CODEX_HOME=/opt/codex'

finish dockerfile-test
