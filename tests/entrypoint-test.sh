#!/usr/bin/env bash
# entrypoint-test.sh — stub harness for the pi and Codex blocks of
# venv-sync-entrypoint.sh: the weekly self-updating copies kept in the mounted
# ~/.pi-cli and ~/.codex folders.
#
# There is no daemon inside a Claude session container, so nothing here starts
# a container. The harness runs the real entrypoint with a temporary $HOME and
# stubs first on PATH: `curl` hands out stub copies of the two vendor
# installers, the stub pi launcher implements `pi update`, and `pi`/`codex`
# stand in for the copies baked into the image. The stubs copy the vendor
# behaviour the entrypoint depends on (read from pi.dev/install.sh and
# chatgpt.com/codex/install.sh, 2026-10-14):
#   * pi's installer refuses to install while a pi it does not manage is on
#     PATH, and links pi into ~/.local/bin when that comes first on PATH;
#   * Codex's installer writes a PATH block into ~/.bashrc when its bin dir
#     is not on PATH, and treats its own lock as stale after 600 s;
#   * both clean up the staging a killed run left behind.
#
# One named case per row S1–S7 and S9 of the plan's "Stop and resume states"
# table. Stopped states are produced for real: the entrypoint is SIGKILLed
# while the stub installer is mid-download, so no trap gets to run. Each case
# then compares what the next start leaves behind — the files under $HOME,
# PATH, and the printed [entrypoint] lines — with a run that never stopped.
#
# Requirements: bash, coreutils, findutils, setsid (util-linux). No docker,
# no network.
#
# Usage:  ./tests/entrypoint-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../venv-sync-entrypoint.sh"
[ -f "$SRC" ] || { echo "SKIP: venv-sync-entrypoint.sh not found at $SRC"; exit 2; }

# shellcheck source=tests/harness.sh disable=SC1091  # followed when CI passes harness.sh too
. "$HERE/harness.sh"

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"      # curl
BAKED="$TMP/baked"      # stand-ins for /usr/local/bin/pi and /usr/local/bin/codex
STUB_DIR="$TMP/payload" # installer scripts curl hands out, hold/release files
STUB_LOG="$TMP/calls.log"
mkdir -p "$STUBS" "$BAKED" "$STUB_DIR"

# --- stubs --------------------------------------------------------------------

cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
# The entrypoint calls `curl -fsSL <url>`; the URL is the last argument.
for url in "$@"; do :; done
echo "curl $url" >> "$STUB_LOG"
[ "${STUB_OFFLINE:-0}" = 1 ] && exit 6
if [ "${STUB_CURL_STALL:-0}" = 1 ]; then
    # A network that accepts the connection and then sends nothing. Real curl
    # gives up (exit 28) only when given both a connect and a total time
    # limit; without them it waits, so this stub waits too.
    case " $* " in
        *" --connect-timeout "*) case " $* " in *" --max-time "*) exit 28 ;; esac ;;
    esac
    sleep 20
    exit 28
fi
case "$url" in
    https://pi.dev/install.sh) cat "$STUB_DIR/pi-install.sh" ;;
    https://chatgpt.com/codex/install.sh) cat "$STUB_DIR/codex-install.sh" ;;
    *) exit 22 ;;
esac
EOF

cat > "$BAKED/pi" <<'EOF'
#!/bin/sh
[ "${1:-}" = --version ] && echo 1.2.0
EOF

cat > "$BAKED/codex" <<'EOF'
#!/bin/sh
[ "${1:-}" = --version ] && echo "codex-cli 0.159.2"
EOF

# hold — shared by the installer stubs. With STUB_HOLD=1 the stub records its
# pid and blocks until the harness creates $STUB_DIR/release (or kills it):
# that is the moment the stop cases interrupt. The caller sets HOLD_POINT;
# the stub holds only where it equals STUB_HOLD_AT (default: download).
cat > "$STUB_DIR/hold.sh" <<'EOF'
if [ "${STUB_HOLD:-0}" = 1 ] && [ "${STUB_HOLD_AT:-download}" = "$HOLD_POINT" ]; then
    echo $$ > "$STUB_DIR/hold.pid"
    n=0
    while [ ! -e "$STUB_DIR/release" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n+1)); done
fi
EOF

# pi.dev/install.sh, reduced to what the entrypoint relies on. Like the real
# run_managed_install_pi, it writes the launcher before current-version, so a
# kill between the two (STUB_HOLD_AT=launcher) leaves a launcher that cannot
# run.
cat > "$STUB_DIR/pi-install.sh" <<'EOF'
set -eu
agent="${PI_CODING_AGENT_DIR:?PI_CODING_AGENT_DIR not set}"
echo "pi-installer $agent" >> "$STUB_LOG"
existing="$(command -v pi 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "$agent/bin/pi" ]; then
    echo "Managed install refused to replace Pi at $existing. Uninstall it first." >&2
    exit 1
fi
[ "${STUB_PI_INSTALL_FAIL:-0}" = 1 ] && exit 1
[ "${STUB_PI_INSTALL_NOOP:-0}" = 1 ] && exit 0
root="$agent/install"
rm -rf "$root/staging"
mkdir -p "$root/staging"
echo partial > "$root/staging/download.part"
HOLD_POINT=download; . "$STUB_DIR/hold.sh"
mkdir -p "$root/releases/$STUB_PI_LATEST"
rm -f "$root/staging/download.part"
mkdir -p "$agent/bin"
cp "$STUB_DIR/pi-launcher.sh" "$agent/bin/pi"
chmod 755 "$agent/bin/pi"
HOLD_POINT=launcher; . "$STUB_DIR/hold.sh"
printf '%s\n' "$STUB_PI_LATEST" > "$root/current-version"
# The real installer links pi from the first of these dirs it finds on PATH.
IFS=:
for d in $PATH; do
    case "$d" in
        "$agent/bin") break ;;
        "$HOME/.local/bin") mkdir -p "$d"; ln -sf "$agent/bin/pi" "$d/pi"; break ;;
    esac
done
EOF

# The launcher the pi installer writes, with `pi update`.
cat > "$STUB_DIR/pi-launcher.sh" <<'EOF'
#!/bin/sh
set -eu
agent="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)"
root="$agent/install"
# The real launcher reads current-version before it does anything else.
if [ ! -r "$root/current-version" ]; then
    echo "Could not read managed Pi version from $root/current-version." >&2
    exit 1
fi
case "${1:-}" in
    --version) cat "$root/current-version" ;;
    update)
        echo "pi-update ${PI_CODING_AGENT_DIR:-}" >> "$STUB_LOG"
        if [ "${PI_CODING_AGENT_DIR:-}" != "$agent" ]; then
            echo "PI_CODING_AGENT_DIR is not this install" >&2; exit 1
        fi
        [ "${STUB_OFFLINE:-0}" = 1 ] && exit 1
        # pi's cleanupManagedInstall: its own update lock and staging from a
        # killed run are removed before the next one.
        rm -rf "$root/update" "$root/staging"
        mkdir -p "$root/staging" "$root/update"
        echo partial > "$root/staging/download.part"
        HOLD_POINT=download; . "$STUB_DIR/hold.sh"
        mkdir -p "$root/releases/$STUB_PI_LATEST"
        rm -f "$root/staging/download.part"
        printf '%s\n' "$STUB_PI_LATEST" > "$root/current-version"
        rmdir "$root/update"
        ;;
    *) exit 2 ;;
esac
EOF

# chatgpt.com/codex/install.sh, reduced the same way.
cat > "$STUB_DIR/codex-install.sh" <<'EOF'
set -eu
home="${CODEX_HOME:?CODEX_HOME not set}"
bin="${CODEX_INSTALL_DIR:?CODEX_INSTALL_DIR not set}"
echo "codex-installer $home $bin" >> "$STUB_LOG"
case "${CODEX_NON_INTERACTIVE:-}" in 1|true|yes) ;; *) echo "would prompt" >&2; exit 1 ;; esac
[ "${STUB_CODEX_FAIL:-0}" = 1 ] && exit 1
root="$home/packages/standalone"
lock="$root/install.lock.d"
mkdir -p "$root/releases"
if [ -d "$lock" ]; then
    if [ -n "$(find "$lock" -maxdepth 0 -mmin -10)" ]; then echo "install in progress" >&2; exit 1; fi
    rmdir "$lock"
fi
mkdir "$lock"
find "$root/releases" -mindepth 1 -maxdepth 1 -name '.staging.*' -exec rm -rf {} +
mkdir -p "$root/releases/.staging.1"
HOLD_POINT=download; . "$STUB_DIR/hold.sh"
rmdir "$root/releases/.staging.1"
rel="$root/releases/$STUB_CODEX_LATEST-stub"
mkdir -p "$rel/bin"
printf '#!/bin/sh\necho "codex-cli %s"\n' "$STUB_CODEX_LATEST" > "$rel/bin/codex"
chmod 755 "$rel/bin/codex"
ln -sfn "$rel" "$root/current"
mkdir -p "$bin"
ln -sfn "$root/current/bin/codex" "$bin/codex"
case ":$PATH:" in
    *":$bin:"*) ;;
    *) printf '# >>> Codex installer >>>\nexport PATH="%s:$PATH"\n# <<< Codex installer <<<\n' "$bin" >> "$HOME/.bashrc" ;;
esac
rmdir "$lock"
EOF

chmod 755 "$STUBS/curl" "$BAKED/pi" "$BAKED/codex"

# --- running the entrypoint -----------------------------------------------------

# What the entrypoint execs at the end: report what a session would see.
# shellcheck disable=SC2016  # expanded by the probe shell, not here
PROBE='printf "PATH=%s\n" "$PATH"
for c in pi codex; do printf "%s=%s %s\n" "$c" "$(command -v "$c")" "$("$c" --version 2>/dev/null)"; done'

ep_env() {  # $1 = HOME; the rest = extra VAR=value overrides
    local home="$1"; shift
    env -i HOME="$home" PATH="$STUBS:$BAKED:/usr/bin:/bin" \
        STUB_DIR="$STUB_DIR" STUB_LOG="$STUB_LOG" \
        STUB_PI_LATEST=1.3.0 STUB_CODEX_LATEST=0.170.0 "$@"
}

# run_ep <out> <home> [VAR=value…] — one container start, output to <out>.
run_ep() {
    local out="$1"; shift
    ep_env "$@" bash "$SRC" bash -c "$PROBE" > "$out" 2>&1
}

# kill_mid_step <home> [VAR=value…] — start the entrypoint, wait until the stub
# installer is mid-download, then SIGKILL everything: no trap runs, so the
# entrypoint's lock and the installer's partial staging stay on disk.
kill_mid_step() {
    local pid n=0
    rm -f "$STUB_DIR/hold.pid" "$STUB_DIR/release"
    # setsid: its own process group, so one kill reaches every process in it.
    # The pi installer runs in a session of its own (setsid -w in the
    # entrypoint), which is why the stub's pid is killed separately below.
    # shellcheck disable=SC2016  # expanded by the inner bash
    setsid bash -c 'src="$0" probe="$1"; shift; "$@" bash "$src" bash -c "$probe" >/dev/null 2>&1' \
        "$SRC" "$PROBE" env -i HOME="$1" PATH="$STUBS:$BAKED:/usr/bin:/bin" \
        STUB_DIR="$STUB_DIR" STUB_LOG="$STUB_LOG" \
        STUB_PI_LATEST=1.3.0 STUB_CODEX_LATEST=0.170.0 STUB_HOLD=1 "${@:2}" &
    pid=$!
    while [ ! -s "$STUB_DIR/hold.pid" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n+1)); done
    kill -KILL -- "-$pid" 2>/dev/null
    [ -s "$STUB_DIR/hold.pid" ] && kill -KILL "$(cat "$STUB_DIR/hold.pid")" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$STUB_DIR/hold.pid"
}

# state <home> <out> — everything a case compares: the printed [entrypoint]
# lines, what the session sees, and the tree under $HOME (symlink targets and
# installed versions included; stamp contents are dates, so only presence).
state() {
    local home="$1" out="$2"
    {
        grep '^\[entrypoint\]' "$out"
        grep -E '^(PATH|pi|codex)=' "$out"
        (cd "$home" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
            if [ -L "$p" ]; then echo "$p -> $(readlink "$p")"
            elif [ -d "$p" ]; then echo "$p/"
            else echo "$p"; fi
        done)
        find "$home" -name current-version -exec cat {} \;
    } | sed "s#$home#~#g"
}

lines() { grep '^\[entrypoint\]' "$1"; }

age() {  # age <minutes> <path…>
    local m="$1"; shift
    touch -d "$m minutes ago" "$@"
}

new_home() {  # new_home <name> [pi] [codex] — a $HOME with the named mounts
    local h="$TMP/home-$1"; shift
    mkdir -p "$h"
    for m in "$@"; do
        case "$m" in pi) mkdir -p "$h/.pi-cli" ;; codex) mkdir -p "$h/.codex" ;; esac
    done
    echo "$h"
}

# seed_old <home> <tool> — an installed copy one release back whose stamp is
# 8 days old, so the next start runs the weekly update.
seed_old() {
    case "$2" in
        pi) run_ep "$TMP/seed.out" "$1" STUB_PI_LATEST=1.2.0
            age $((8*24*60)) "$1/.pi-cli/.last-update" ;;
        codex) run_ep "$TMP/seed.out" "$1" STUB_CODEX_LATEST=0.160.0
            age $((8*24*60)) "$1/.codex/.last-update" ;;
    esac
}

# expect_same <name> <home> <out> <baseline-state-file>
expect_same() {
    local d
    if d="$(diff <(state "$2" "$3") "$4")"; then
        ok "$1"
    else
        local IFS=$'\n'
        # shellcheck disable=SC2086  # one detail line per diff line
        fail "$1" "differs from the run that never stopped (< this run, > baseline):" $d
    fi
}

expect_lines() {  # expect_lines <name> <out> <expected lines…>
    local name="$1" out="$2"; shift 2
    local want got
    want="$(printf '%s\n' "$@")"
    got="$(lines "$out")"
    if [ "$got" = "$want" ]; then ok "$name"; else fail "$name" "want: $want" "got:  $got"; fi
}

expect() {  # expect <name> <test…>
    local name="$1"; shift
    if "$@"; then ok "$name"; else fail "$name" "check failed: $*"; fi
}

has_line() { grep -qxF -- "$2" "$1"; }

calls() { grep -c "^$1" "$STUB_LOG" 2>/dev/null || true; }

reset_log() { : > "$STUB_LOG"; }

# --- baselines: runs that never stopped --------------------------------------

echo "== baselines (no stop)"

H="$(new_home base-pi-install pi)"
run_ep "$TMP/base-pi-install.out" "$H"
state "$H" "$TMP/base-pi-install.out" > "$TMP/BASE_PI_INSTALL"
expect_lines "pi first install prints its version" "$TMP/base-pi-install.out" \
    "[entrypoint] Installing pi ..." "[entrypoint] pi: 1.3.0"
expect "pi first install puts the launcher first on PATH" \
    has_line "$TMP/base-pi-install.out" "PATH=$H/.pi-cli/agent/bin:$STUBS:$BAKED:/usr/bin:/bin"
expect "pi first install: the session runs the launcher" \
    has_line "$TMP/base-pi-install.out" "pi=$H/.pi-cli/agent/bin/pi 1.3.0"
expect "pi first install writes the stamp" test -f "$H/.pi-cli/.last-update"
expect "pi first install leaves no lock" test ! -e "$H/.pi-cli/.update-lock"
expect "pi first install writes nothing outside the mount" test ! -e "$H/.local"

H="$(new_home base-pi-update pi)"
seed_old "$H" pi
run_ep "$TMP/base-pi-update.out" "$H"
state "$H" "$TMP/base-pi-update.out" > "$TMP/BASE_PI_UPDATE"
expect_lines "pi weekly update prints the new version" "$TMP/base-pi-update.out" \
    "[entrypoint] Updating pi (every 7d) ..." "[entrypoint] pi: 1.3.0"
expect "pi weekly update leaves no lock" test ! -e "$H/.pi-cli/.update-lock"

H="$(new_home base-codex-install codex)"
run_ep "$TMP/base-codex-install.out" "$H"
state "$H" "$TMP/base-codex-install.out" > "$TMP/BASE_CODEX_INSTALL"
expect_lines "codex first install prints its version" "$TMP/base-codex-install.out" \
    "[entrypoint] Installing codex ..." "[entrypoint] codex: 0.170.0"
expect "codex first install puts ~/.codex/bin first on PATH" \
    has_line "$TMP/base-codex-install.out" "PATH=$H/.codex/bin:$STUBS:$BAKED:/usr/bin:/bin"
expect "codex first install: the session runs the installed codex" \
    has_line "$TMP/base-codex-install.out" "codex=$H/.codex/bin/codex codex-cli 0.170.0"
expect "codex first install writes no PATH block into ~/.bashrc" test ! -e "$H/.bashrc"
expect "codex first install writes the stamp" test -f "$H/.codex/.last-update"

H="$(new_home base-codex-update codex)"
seed_old "$H" codex
run_ep "$TMP/base-codex-update.out" "$H"
state "$H" "$TMP/base-codex-update.out" > "$TMP/BASE_CODEX_UPDATE"
expect_lines "codex weekly update prints the new version" "$TMP/base-codex-update.out" \
    "[entrypoint] Updating codex (every 7d) ..." "[entrypoint] codex: 0.170.0"

H="$(new_home fresh pi codex)"
run_ep "$TMP/fresh1.out" "$H"
reset_log
run_ep "$TMP/fresh2.out" "$H"
expect_lines "a stamp younger than the interval: no update, nothing printed" "$TMP/fresh2.out"
expect "a stamp younger than the interval: no installer runs" test ! -s "$STUB_LOG"
expect "a stamp younger than the interval: both copies still first on PATH" \
    has_line "$TMP/fresh2.out" "PATH=$H/.codex/bin:$H/.pi-cli/agent/bin:$STUBS:$BAKED:/usr/bin:/bin"

H="$(new_home forced pi)"
run_ep "$TMP/forced1.out" "$H"
# GNU find counts a stamp written in the same second as matching -mtime -0.
age 5 "$H/.pi-cli/.last-update"
run_ep "$TMP/forced2.out" "$H" MULTIPLAI_CLI_UPDATE_DAYS=0
expect_lines "MULTIPLAI_CLI_UPDATE_DAYS=0 forces the update" "$TMP/forced2.out" \
    "[entrypoint] Updating pi (every 0d) ..." "[entrypoint] pi: 1.3.0"

H="$(new_home no-mount)"
reset_log
run_ep "$TMP/nomount.out" "$H"
expect_lines "no mounted folders: nothing printed" "$TMP/nomount.out"
expect "no mounted folders: no installer runs" test ! -s "$STUB_LOG"
expect "no mounted folders: the baked pi runs" has_line "$TMP/nomount.out" "pi=$BAKED/pi 1.2.0"
expect "no mounted folders: the baked codex runs" \
    has_line "$TMP/nomount.out" "codex=$BAKED/codex codex-cli 0.159.2"

# --- S1: pi first install, installer killed mid-download --------------------

echo "== S1 pi first install killed mid-download"
H="$(new_home s1 pi)"
kill_mid_step "$H"
expect "S1: the kill leaves the lock" test -d "$H/.pi-cli/.update-lock"
expect "S1: the kill leaves partial staging" test -e "$H/.pi-cli/agent/install/staging/download.part"
expect "S1: the kill leaves no launcher" test ! -e "$H/.pi-cli/agent/bin/pi"
run_ep "$TMP/s1-young.out" "$H"
expect_lines "S1 lock younger than 30 min: skip, baked pi" "$TMP/s1-young.out" \
    "[entrypoint] pi install in progress elsewhere — using baked pi"
expect "S1 lock younger than 30 min: the baked pi runs" has_line "$TMP/s1-young.out" "pi=$BAKED/pi 1.2.0"
age 31 "$H/.pi-cli/.update-lock"
run_ep "$TMP/s1.out" "$H"
expect_same "S1 lock older than 30 min: resume matches a clean install" "$H" "$TMP/s1.out" "$TMP/BASE_PI_INSTALL"

echo "== S1 pi first install killed after the launcher, before current-version"
# pi.dev/install.sh writes the launcher, then current-version. A kill between
# the two leaves a launcher that exits 1 on every command, `pi update`
# included: the copy is not installed, and the resume is the installer again.
H="$(new_home s1l pi)"
kill_mid_step "$H" STUB_HOLD_AT=launcher
expect "S1 launcher: the kill leaves the launcher" test -x "$H/.pi-cli/agent/bin/pi"
expect "S1 launcher: the kill leaves no current-version" \
    test ! -e "$H/.pi-cli/agent/install/current-version"
run_ep "$TMP/s1l-young.out" "$H"
expect_lines "S1 launcher, lock younger than 30 min: skip, baked pi" "$TMP/s1l-young.out" \
    "[entrypoint] pi install in progress elsewhere — using baked pi"
expect "S1 launcher, lock younger than 30 min: the baked pi runs, not the broken launcher" \
    has_line "$TMP/s1l-young.out" "pi=$BAKED/pi 1.2.0"
age 31 "$H/.pi-cli/.update-lock"
run_ep "$TMP/s1l.out" "$H"
expect_same "S1 launcher, lock older than 30 min: resume matches a clean install" \
    "$H" "$TMP/s1l.out" "$TMP/BASE_PI_INSTALL"

# --- S2: pi first install fails (offline) -----------------------------------

echo "== S2 pi first install fails"
H="$(new_home s2 pi)"
run_ep "$TMP/s2-fail.out" "$H" STUB_OFFLINE=1
expect_lines "S2: one line naming the baked pi and its version" "$TMP/s2-fail.out" \
    "[entrypoint] Installing pi ..." \
    "[entrypoint] pi install failed (offline?) — using baked pi 1.2.0"
expect "S2: the lock is removed" test ! -e "$H/.pi-cli/.update-lock"
expect "S2: no launcher" test ! -e "$H/.pi-cli/agent/bin/pi"
expect "S2: no stamp" test ! -e "$H/.pi-cli/.last-update"
expect "S2: the baked pi runs" has_line "$TMP/s2-fail.out" "pi=$BAKED/pi 1.2.0"
run_ep "$TMP/s2.out" "$H"
expect_same "S2: the next start matches a clean install" "$H" "$TMP/s2.out" "$TMP/BASE_PI_INSTALL"

H="$(new_home s2b pi)"
run_ep "$TMP/s2b.out" "$H" STUB_PI_INSTALL_FAIL=1
expect_lines "S2: an installer that exits non-zero online is the same failure" "$TMP/s2b.out" \
    "[entrypoint] Installing pi ..." \
    "[entrypoint] pi install failed (offline?) — using baked pi 1.2.0"

H="$(new_home s2c pi)"
run_ep "$TMP/s2c.out" "$H" STUB_PI_INSTALL_NOOP=1
expect_lines "S2: an installer that exits 0 but leaves no launcher is the same failure" "$TMP/s2c.out" \
    "[entrypoint] Installing pi ..." \
    "[entrypoint] pi install failed (offline?) — using baked pi 1.2.0"
expect "S2: no stamp without a launcher" test ! -e "$H/.pi-cli/.last-update"

# --- S3: weekly pi update killed mid-update ---------------------------------

echo "== S3 weekly pi update killed"
H="$(new_home s3 pi)"
seed_old "$H" pi
kill_mid_step "$H"
expect "S3: the kill leaves our lock" test -d "$H/.pi-cli/.update-lock"
expect "S3: the kill leaves pi's own update lock" test -d "$H/.pi-cli/agent/install/update"
run_ep "$TMP/s3-young.out" "$H"
expect_lines "S3 lock younger than 30 min: skip, installed pi" "$TMP/s3-young.out" \
    "[entrypoint] pi update in progress elsewhere — using installed pi"
expect "S3: the old release stays valid meanwhile" \
    has_line "$TMP/s3-young.out" "pi=$H/.pi-cli/agent/bin/pi 1.2.0"
age 31 "$H/.pi-cli/.update-lock"
run_ep "$TMP/s3.out" "$H"
expect_same "S3 lock older than 30 min: resume matches a clean update" "$H" "$TMP/s3.out" "$TMP/BASE_PI_UPDATE"

# --- S4: weekly pi update fails ---------------------------------------------

echo "== S4 weekly pi update fails"
H="$(new_home s4 pi)"
seed_old "$H" pi
run_ep "$TMP/s4-fail.out" "$H" STUB_OFFLINE=1
expect_lines "S4: one line, the old release kept" "$TMP/s4-fail.out" \
    "[entrypoint] Updating pi (every 7d) ..." \
    "[entrypoint] pi update failed (offline?) — using installed pi 1.2.0"
expect "S4: the old release still runs" has_line "$TMP/s4-fail.out" "pi=$H/.pi-cli/agent/bin/pi 1.2.0"
expect "S4: no new stamp" test -z "$(find "$H/.pi-cli/.last-update" -mtime -7)"
run_ep "$TMP/s4.out" "$H"
expect_same "S4: the next start matches a clean update" "$H" "$TMP/s4.out" "$TMP/BASE_PI_UPDATE"

# --- S5: Codex install killed -----------------------------------------------

echo "== S5 codex install killed"
H="$(new_home s5 codex)"
kill_mid_step "$H"
expect "S5: the kill leaves our lock" test -d "$H/.codex/.update-lock"
expect "S5: the kill leaves Codex's own lock" test -d "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s5-young.out" "$H"
expect_lines "S5 lock younger than 30 min: skip, baked codex" "$TMP/s5-young.out" \
    "[entrypoint] codex install in progress elsewhere — using baked codex"
expect "S5: the baked codex runs meanwhile" \
    has_line "$TMP/s5-young.out" "codex=$BAKED/codex codex-cli 0.159.2"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s5.out" "$H"
expect_same "S5 locks older than 30 min: resume matches a clean install" "$H" "$TMP/s5.out" "$TMP/BASE_CODEX_INSTALL"

echo "== S5 codex weekly update killed"
H="$(new_home s5u codex)"
seed_old "$H" codex
kill_mid_step "$H"
expect "S5 update: the kill leaves our lock" test -d "$H/.codex/.update-lock"
expect "S5 update: the kill leaves Codex's own lock" \
    test -d "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s5u-young.out" "$H"
expect_lines "S5 update, lock younger than 30 min: skip, installed codex" "$TMP/s5u-young.out" \
    "[entrypoint] codex update in progress elsewhere — using installed codex"
expect "S5 update: the old binary runs meanwhile" \
    has_line "$TMP/s5u-young.out" "codex=$H/.codex/bin/codex codex-cli 0.160.0"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s5u.out" "$H"
expect_same "S5 update, locks older than 30 min: resume matches a clean update" \
    "$H" "$TMP/s5u.out" "$TMP/BASE_CODEX_UPDATE"

# --- S6: Codex install or update fails --------------------------------------

echo "== S6 codex install or update fails"
H="$(new_home s6 codex)"
run_ep "$TMP/s6-fail.out" "$H" STUB_OFFLINE=1
expect_lines "S6 install: one line naming the baked codex" "$TMP/s6-fail.out" \
    "[entrypoint] Installing codex ..." \
    "[entrypoint] codex install failed (offline?) — using baked codex 0.159.2"
expect "S6 install: no stamp" test ! -e "$H/.codex/.last-update"
run_ep "$TMP/s6.out" "$H"
expect_same "S6 install: the next start matches a clean install" "$H" "$TMP/s6.out" "$TMP/BASE_CODEX_INSTALL"

H="$(new_home s6u codex)"
seed_old "$H" codex
run_ep "$TMP/s6u-fail.out" "$H" STUB_CODEX_FAIL=1
expect_lines "S6 update: one line, the old binary kept" "$TMP/s6u-fail.out" \
    "[entrypoint] Updating codex (every 7d) ..." \
    "[entrypoint] codex update failed (offline?) — using installed codex 0.160.0"
expect "S6 update: the old binary still runs" \
    has_line "$TMP/s6u-fail.out" "codex=$H/.codex/bin/codex codex-cli 0.160.0"
run_ep "$TMP/s6u.out" "$H"
expect_same "S6 update: the next start matches a clean update" "$H" "$TMP/s6u.out" "$TMP/BASE_CODEX_UPDATE"

# --- S7: two containers start at once ----------------------------------------

echo "== S7 two containers start at once"
# s7_pair <case> <home> <expected line of the second container>
# Container A takes the lock and holds mid-download; B starts meanwhile and
# must not wait or run an installer. Then A finishes.
s7_pair() {
    local name="$1" h="$2" want="$3" pid n=0 start elapsed
    rm -f "$STUB_DIR/hold.pid" "$STUB_DIR/release"
    reset_log
    ep_env "$h" STUB_HOLD=1 bash "$SRC" bash -c "$PROBE" > "$TMP/$name-a.out" 2>&1 &
    pid=$!
    while [ ! -s "$STUB_DIR/hold.pid" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n+1)); done
    start=$SECONDS
    run_ep "$TMP/$name-b.out" "$h"
    elapsed=$((SECONDS - start))
    touch "$STUB_DIR/release"
    wait "$pid"
    rm -f "$STUB_DIR/release" "$STUB_DIR/hold.pid"
    expect_lines "$name: the second container skips" "$TMP/$name-b.out" "$want"
    expect "$name: the second container does not wait (${elapsed}s)" test "$elapsed" -le 2
    expect "$name: only the first container ran the installer" \
        test "$(( $(calls pi-installer) + $(calls pi-update) + $(calls codex-installer) ))" -eq 1
}

H="$(new_home s7 pi)"
s7_pair "S7 first install" "$H" "[entrypoint] pi install in progress elsewhere — using baked pi"
expect "S7 first install: the second container runs the baked pi" \
    has_line "$TMP/S7 first install-b.out" "pi=$BAKED/pi 1.2.0"
expect_same "S7 first install: the first container matches a clean install" \
    "$H" "$TMP/S7 first install-a.out" "$TMP/BASE_PI_INSTALL"

H="$(new_home s7u pi)"
seed_old "$H" pi
s7_pair "S7 update" "$H" "[entrypoint] pi update in progress elsewhere — using installed pi"
expect "S7 update: the second container runs the existing launcher" \
    has_line "$TMP/S7 update-b.out" "pi=$H/.pi-cli/agent/bin/pi 1.2.0"
expect_same "S7 update: the first container matches a clean update" \
    "$H" "$TMP/S7 update-a.out" "$TMP/BASE_PI_UPDATE"

H="$(new_home s7c codex)"
s7_pair "S7 codex first install" "$H" "[entrypoint] codex install in progress elsewhere — using baked codex"
expect "S7 codex first install: the second container runs the baked codex" \
    has_line "$TMP/S7 codex first install-b.out" "codex=$BAKED/codex codex-cli 0.159.2"
expect_same "S7 codex first install: the first container matches a clean install" \
    "$H" "$TMP/S7 codex first install-a.out" "$TMP/BASE_CODEX_INSTALL"

H="$(new_home s7cu codex)"
seed_old "$H" codex
s7_pair "S7 codex update" "$H" "[entrypoint] codex update in progress elsewhere — using installed codex"
expect "S7 codex update: the second container runs the existing binary" \
    has_line "$TMP/S7 codex update-b.out" "codex=$H/.codex/bin/codex codex-cli 0.160.0"
expect_same "S7 codex update: the first container matches a clean update" \
    "$H" "$TMP/S7 codex update-a.out" "$TMP/BASE_CODEX_UPDATE"

# --- S9: the same step stopped twice in a row ---------------------------------

echo "== S9 same step stopped twice"
H="$(new_home s9 pi)"
kill_mid_step "$H"
age 31 "$H/.pi-cli/.update-lock"
kill_mid_step "$H"
expect "S9: the second kill leaves a lock again" test -d "$H/.pi-cli/.update-lock"
age 31 "$H/.pi-cli/.update-lock"
run_ep "$TMP/s9.out" "$H"
expect_same "S9: resume after two stops matches a clean install" "$H" "$TMP/s9.out" "$TMP/BASE_PI_INSTALL"

H="$(new_home s9u pi)"
seed_old "$H" pi
kill_mid_step "$H"
age 31 "$H/.pi-cli/.update-lock"
kill_mid_step "$H"
age 31 "$H/.pi-cli/.update-lock"
run_ep "$TMP/s9u.out" "$H"
expect_same "S9: resume after two stopped updates matches a clean update" "$H" "$TMP/s9u.out" "$TMP/BASE_PI_UPDATE"

H="$(new_home s9c codex)"
kill_mid_step "$H"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
kill_mid_step "$H"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s9c.out" "$H"
expect_same "S9: resume after two stopped codex installs matches a clean install" \
    "$H" "$TMP/s9c.out" "$TMP/BASE_CODEX_INSTALL"

H="$(new_home s9cu codex)"
seed_old "$H" codex
kill_mid_step "$H"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
kill_mid_step "$H"
age 31 "$H/.codex/.update-lock" "$H/.codex/packages/standalone/install.lock.d"
run_ep "$TMP/s9cu.out" "$H"
expect_same "S9: resume after two stopped codex updates matches a clean update" \
    "$H" "$TMP/s9cu.out" "$TMP/BASE_CODEX_UPDATE"

# --- failures that must not hold up the start ---------------------------------

echo "== a download that stalls"
# The container start must not wait on a network that never answers: the
# entrypoint gives curl its own time limits, so the start fails over to the
# baked copies well inside this harness's 15 s limit.
H="$(new_home stall pi codex)"
start=$SECONDS
# shellcheck disable=SC2016  # expanded by the inner bash
timeout -k 1 15 bash -c 'out="$1"; shift; "$@" bash "$0" bash -c "$PROBE" > "$out" 2>&1' \
    "$SRC" "$TMP/stall.out" env -i HOME="$H" PATH="$STUBS:$BAKED:/usr/bin:/bin" \
    STUB_DIR="$STUB_DIR" STUB_LOG="$STUB_LOG" PROBE="$PROBE" \
    STUB_PI_LATEST=1.3.0 STUB_CODEX_LATEST=0.170.0 STUB_CURL_STALL=1
rc=$?
expect "a stalled download does not hold up the start (rc=$rc, $((SECONDS - start))s)" test "$rc" -eq 0
expect_lines "a stalled download: one failure line per tool, naming the baked copy" "$TMP/stall.out" \
    "[entrypoint] Installing pi ..." \
    "[entrypoint] pi install failed (offline?) — using baked pi 1.2.0" \
    "[entrypoint] Installing codex ..." \
    "[entrypoint] codex install failed (offline?) — using baked codex 0.159.2"

echo "== a mounted folder that is not writable"
# Docker creates a missing bind-mount source as root, so uid 501 cannot write
# to it. That must not be reported as another container holding the lock.
if [ "$(id -u)" -eq 0 ]; then
    echo "  skip - running as root, which can write to a mode-555 folder"
else
    H="$(new_home ro pi codex)"
    chmod 555 "$H/.pi-cli" "$H/.codex"
    reset_log
    run_ep "$TMP/ro.out" "$H"
    expect_lines "a folder that is not writable: one line each, naming why and the baked copy" "$TMP/ro.out" \
        "[entrypoint] $H/.pi-cli is not writable — using baked pi 1.2.0" \
        "[entrypoint] $H/.codex is not writable — using baked codex 0.159.2"
    expect "a folder that is not writable: no installer runs" test ! -s "$STUB_LOG"
    expect "a folder that is not writable: the baked pi runs" has_line "$TMP/ro.out" "pi=$BAKED/pi 1.2.0"
    chmod 755 "$H/.pi-cli" "$H/.codex"

    H="$(new_home ro-old pi)"
    seed_old "$H" pi
    chmod 555 "$H/.pi-cli"
    run_ep "$TMP/ro-old.out" "$H"
    expect_lines "a folder that is not writable, with an installed copy: that copy is named" "$TMP/ro-old.out" \
        "[entrypoint] $H/.pi-cli is not writable — using installed pi 1.2.0"
    expect "a folder that is not writable, with an installed copy: it stays first on PATH" \
        has_line "$TMP/ro-old.out" "pi=$H/.pi-cli/agent/bin/pi 1.2.0"
    chmod 755 "$H/.pi-cli"
fi

finish entrypoint-test
