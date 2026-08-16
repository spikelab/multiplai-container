#!/usr/bin/env bash
# gateway-test.sh — adversarial test harness for container-build-gateway.sh.
#
# Runs the gateway exactly as sshd would (SSH_ORIGINAL_COMMAND set, zsh
# interpreter) against a sandbox of stub commands, and asserts ALLOW/DENY
# outcomes plus the argv/cwd the stubs actually received.
#
# Requirements: zsh on PATH (macOS default). Override with GATEWAY_TEST_ZSH
# to point at another zsh (e.g. a static build inside the Linux container).
#
# Usage:  ./tests/gateway-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="$HERE/../container-build-gateway.sh"
ZSH_BIN="${GATEWAY_TEST_ZSH:-$(command -v zsh || true)}"
[ -n "$ZSH_BIN" ] || { echo "SKIP: zsh not found (set GATEWAY_TEST_ZSH)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; FAKE_HOME="$TMP/home"
mkdir -p "$STUB" "$FAKE_HOME"

# Stubs: print a marker, their argv (one per line, bracketed), and cwd.
for c in swift xcodebuild xcrun qmd curl pkill agent-browser; do
  cat > "$STUB/$c" <<EOF
#!/usr/bin/env bash
echo "STUB:$c cwd=\$PWD"
for a in "\$@"; do echo "ARG:[\$a]"; done
EOF
  chmod +x "$STUB/$c"
done
# xcsift stub: tags stdin so pipe attachment is observable.
cat > "$STUB/xcsift" <<'EOF'
#!/usr/bin/env bash
echo "STUB:xcsift args:$*"
sed 's/^/XCSIFT>/'
EOF
chmod +x "$STUB/xcsift"
# The gateway's final stage execs `zsh -lc`, resolved via PATH.
ln -s "$ZSH_BIN" "$STUB/zsh"

# multiplai-gh-token is the one verb whose branch REWRITES argv[0] to an absolute
# host path ($HOME/.local/bin/...), because ~/.local/bin is not on the login PATH.
# So the stub has to live there — not on $STUB — and it echoes $0 so a test can
# prove the rewrite happened rather than trusting it.
mkdir -p "$FAKE_HOME/.local/bin"
cat > "$FAKE_HOME/.local/bin/multiplai-gh-token" <<'EOF'
#!/usr/bin/env bash
echo "STUB:multiplai-gh-token argv0=$0 cwd=$PWD"
for a in "$@"; do echo "ARG:[$a]"; done
EOF
chmod +x "$FAKE_HOME/.local/bin/multiplai-gh-token"

# multiplai-docker.py — same argv[0]-rewrite deal as gh-token: the container
# types `multiplai-docker`, the gateway pins the absolute .py path. The stub
# echoes $0 so a test can prove the rewrite rather than trusting it.
cat > "$FAKE_HOME/.local/bin/multiplai-docker.py" <<'EOF'
#!/usr/bin/env bash
echo "STUB:multiplai-docker argv0=$0 cwd=$PWD"
for a in "$@"; do echo "ARG:[$a]"; done
EOF
chmod +x "$FAKE_HOME/.local/bin/multiplai-docker.py"

# The declared workspace. Path-taking commands are denied without it (fail
# closed), so almost every test below needs one — the cases that assert the
# denial remove it explicitly and put it back.
#
# The cd-prefix directories live INSIDE it, because a `cd` prefix that leaves
# the workspace is now itself a denial. `$TMP/outside-ws` is deliberately not.
WS_DIR="$TMP/ws"
WS_DECL="$FAKE_HOME/.local/state/multiplai/workspace"
mkdir -p "$WS_DIR" "$FAKE_HOME/.local/state/multiplai"
echo "$WS_DIR" > "$WS_DECL"

# Dirs exercising the cd prefix.
mkdir -p "$WS_DIR/gw test dir" "$WS_DIR/gw (paren) dir" "$WS_DIR/plain"
mkdir -p "$TMP/outside-ws"

PASS=0; FAIL=0
run_gw() {  # $1 = SSH_ORIGINAL_COMMAND; sets OUT, ERR, RC
  OUT="$(SSH_ORIGINAL_COMMAND="$1" HOME="$FAKE_HOME" PATH="$STUB:$PATH" \
        "$ZSH_BIN" "$GATEWAY" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL- $1"; echo "        rc=$RC out=$OUT err=$ERR"; }

expect_allow() {  # $1 name, $2 cmd, $3 required output substring
  run_gw "$2"
  if [ "$RC" -eq 0 ] && [[ "$OUT" == *"$3"* ]]; then ok "$1"; else bad "$1"; fi
}
expect_deny() {   # $1 name, $2 cmd [, $3 required stderr substring]
  run_gw "$2"
  if [ "$RC" -ne 0 ] && [[ "$ERR" == DENIED:* ]] && [[ "$ERR" == *"${3:-}"* ]]; then
    ok "$1"
  else bad "$1"; fi
}

echo "# baseline allows"
expect_allow "plain swift build"           'swift build'                       "STUB:swift"
expect_allow "plain qmd query"             'qmd query hello'                   "STUB:qmd"
expect_allow "curl loopback"               'curl http://localhost:8000/api'    "STUB:curl"
expect_allow "pkill simulator"             'pkill -f Simulator'                "STUB:pkill"

echo "# cd prefix: escaped/quoted paths must reach cd unquoted"
expect_allow "cd escaped space"   "cd $WS_DIR/gw\\ test\\ dir && swift build"       "cwd=$WS_DIR/gw test dir"
expect_allow "cd escaped parens"  "cd $WS_DIR/gw\\ \\(paren\\)\\ dir && swift build" "cwd=$WS_DIR/gw (paren) dir"
expect_allow "cd single-quoted"   "cd '$WS_DIR/gw test dir' && swift build"          "cwd=$WS_DIR/gw test dir"
expect_allow "cd plain"           "cd $WS_DIR/plain && swift build"                  "cwd=$WS_DIR/plain"

echo "# escaped metachars in argv are data, not shell"
expect_allow "escaped paren scheme is one argv word" \
  'xcodebuild -scheme MyApp\ \(Dev\) build' 'ARG:[MyApp (Dev)]'

echo "# smuggling attempts stay denied"
# The single quotes are the point: these payloads must reach the gateway as
# literal text so it can refuse them. If the shell expanded `$(…)` or a backtick
# here, the test would be checking that the gateway rejects the *result* of the
# injection — after this harness had already run it.
expect_deny "semicolon chain"           'swift build; rm -rf /tmp/x'          "metacharacter"
expect_deny "&& chain after cd"         "cd $WS_DIR/plain && rm -rf /tmp/x && swift build" "metacharacter"
# shellcheck disable=SC2016  # literal payload, see above
expect_deny "command substitution"      'swift build $(touch /tmp/pwned)'     "metacharacter"
# shellcheck disable=SC2016  # literal payload, see above
expect_deny "backtick substitution"     'swift build `touch /tmp/pwned`'      "metacharacter"
expect_deny "pipe to shell"             'swift build | sh'                    "metacharacter"
expect_deny "redirect"                  'swift build > /tmp/x'                "metacharacter"
expect_deny "unescaped paren"           'swift build (dev)'                   "metacharacter"
expect_deny "newline smuggle"           $'swift build\nrm -rf /tmp/x'         "metacharacter"
expect_deny "escaped-backslash + live semicolon" 'swift build \\; rm -rf /tmp/x' "metacharacter"
expect_deny "not allowlisted"           'rm -rf /tmp/x'                       "not in allowlist"
expect_deny "cd unescaped space (two words)" "cd $WS_DIR/gw test dir && swift build" "malformed cd prefix"
expect_deny "cd to metachar dir fails at cd" 'cd /tmp\ \&\&\ rm && swift build' "cd failed"
expect_deny "interactive shell"         ''                                    "interactive"

echo "# xcsift suffix: scoped to build heads, exact-match only"
expect_allow "xcsift on swift"      'swift build 2>&1 | xcsift --format toon --quiet'      "XCSIFT>STUB:swift"
expect_allow "xcsift on xcodebuild" 'xcodebuild test 2>&1 | xcsift --format toon --quiet'  "XCSIFT>STUB:xcodebuild"
expect_deny  "xcsift on qmd"        'qmd query foo 2>&1 | xcsift --format toon --quiet'    "xcsift pipe only allowed"
expect_deny  "xcsift on curl"       'curl http://localhost:8000/ 2>&1 | xcsift --format toon --quiet' "xcsift pipe only allowed"
expect_deny  "double xcsift suffix" 'swift build 2>&1 | xcsift --format toon --quiet 2>&1 | xcsift --format toon --quiet' "metacharacter"
expect_deny  "trailing cmd after xcsift suffix" 'swift build 2>&1 | xcsift --format toon --quiet; rm -rf /tmp/x' "metacharacter"
expect_deny  "near-miss suffix (extra flag)" 'swift build 2>&1 | xcsift --format json --quiet' "metacharacter"

echo "# multiplai-gh-token: at most a leading --json/--check plus one app name"
expect_allow "gh-token bare"          'multiplai-gh-token'                 "STUB:multiplai-gh-token"
expect_allow "gh-token app"           'multiplai-gh-token myapp'           "ARG:[myapp]"
expect_allow "gh-token --check app"   'multiplai-gh-token --check myapp'   "ARG:[--check]"
expect_allow "gh-token --json app"    'multiplai-gh-token --json myapp'    "ARG:[--json]"
# The branch pins argv[0] to the absolute install path: the verb must not depend
# on ~/.local/bin being on the login PATH (it isn't).
expect_allow "gh-token runs from the absolute install path" \
  'multiplai-gh-token myapp' "argv0=$FAKE_HOME/.local/bin/multiplai-gh-token"
expect_deny  "gh-token path traversal as app name" \
  'multiplai-gh-token ../../etc/passwd'          "invalid app name"
expect_deny  "gh-token unknown short flag"    'multiplai-gh-token -x'      "flag not allowed"
expect_deny  "gh-token unknown long flag"     'multiplai-gh-token --exec'  "flag not allowed"
expect_deny  "gh-token too many arguments"    'multiplai-gh-token a b c'   "at most 2 arguments"
expect_deny  "gh-token flag after app name"   'multiplai-gh-token myapp --check' "flag must come first"
expect_deny  "gh-token metacharacter chain"   'multiplai-gh-token myapp; rm -rf /tmp/x' "metacharacter"
expect_deny  "gh-token via xcsift pipe" \
  'multiplai-gh-token 2>&1 | xcsift --format toon --quiet' "xcsift pipe only allowed"

echo "# multiplai-docker: fixed verb list, label-shaped arguments, no flags"
expect_allow "docker up"            'multiplai-docker up dolce'                  "STUB:multiplai-docker"
expect_allow "docker up --instance" 'multiplai-docker up dolce --instance wt1'   "ARG:[wt1]"
expect_allow "docker down"          'multiplai-docker down dolce --instance a'   "ARG:[down]"
expect_allow "docker ps"            'multiplai-docker ps dolce'                  "ARG:[ps]"
expect_allow "docker ls bare"       'multiplai-docker ls'                        "ARG:[ls]"
expect_allow "docker ls profile"    'multiplai-docker ls dolce'                  "ARG:[dolce]"
expect_allow "docker logs with n"   'multiplai-docker logs dolce engine 200'     "ARG:[200]"
expect_allow "docker restart"       'multiplai-docker restart dolce celery-beat' "ARG:[celery-beat]"
expect_allow "docker build"         'multiplai-docker build dolce engine'        "ARG:[build]"
expect_allow "docker reap"          'multiplai-docker reap-older-than 12'        "ARG:[12]"
expect_allow "docker exec guest argv" \
  'multiplai-docker exec dolce engine --instance wt1 -- python manage.py showmigrations' \
  "ARG:[showmigrations]"
# The branch pins argv[0] to the absolute install path (~/.local/bin is not on
# the login PATH), and the installed name carries the .py suffix.
expect_allow "docker runs from the absolute install path" \
  'multiplai-docker up dolce' "argv0=$FAKE_HOME/.local/bin/multiplai-docker.py"

# freeze is the trust step: host terminal only, never over the bridge.
expect_deny "docker freeze denied at the gateway" \
  'multiplai-docker freeze dolce -f /tmp/docker-compose.yml' "verb not allowed"
expect_deny "docker unknown verb"     'multiplai-docker foo dolce'         "verb not allowed"
expect_deny "docker no verb"          'multiplai-docker'                   "verb not allowed"
expect_deny "docker profile slash"    'multiplai-docker up dolce/evil'     "invalid profile name"
expect_deny "docker profile dotdot"   'multiplai-docker up ../../etc'      "invalid profile name"
expect_deny "docker profile uppercase" 'multiplai-docker up Dolce'         "invalid profile name"
expect_deny "docker profile too long" \
  'multiplai-docker up aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "invalid profile name"
expect_deny "docker instance slash"   'multiplai-docker up dolce --instance a/b' "invalid instance name"
expect_deny "docker instance dotdot"  'multiplai-docker up dolce --instance ..'  "invalid instance name"
expect_deny "docker instance uppercase" 'multiplai-docker up dolce --instance WT1' "invalid instance name"
expect_deny "docker instance missing value" \
  'multiplai-docker up dolce --instance'                 "--instance needs a value"
expect_deny "docker leading-dash flag" 'multiplai-docker up dolce --volume /:/host' "flag not allowed"
expect_deny "docker build ssh flag"    'multiplai-docker build dolce engine --ssh default' "flag not allowed"
expect_deny "docker service token with slash" \
  'multiplai-docker logs dolce ../engine'                "invalid token"
expect_deny "docker guest flag after --" \
  'multiplai-docker exec dolce engine -- python --version' "may not start with"
expect_deny "docker guest charset after --" \
  'multiplai-docker exec dolce engine -- python "a b"'    "guest argument not allowed"
expect_deny "docker -- outside exec" \
  'multiplai-docker up dolce -- whoami'                  "only for exec"
# Core invariant regression: the metachar gate still fires before this branch.
expect_deny "docker metacharacter chain" \
  'multiplai-docker up dolce; rm -rf /tmp/x'             "metacharacter"
# shellcheck disable=SC2016  # literal payload, see above
expect_deny "docker command substitution" \
  'multiplai-docker up $(whoami)'                        "metacharacter"
expect_deny "docker via xcsift pipe" \
  'multiplai-docker up dolce 2>&1 | xcsift --format toon --quiet' "xcsift pipe only allowed"

echo "# host browser is opt-in — the flag is a host file the container cannot write"
HOST_BROWSER_FLAG="$FAKE_HOME/.local/state/multiplai/host-browser-enabled"

expect_deny "ab denied with no flag" \
  'agent-browser snapshot'                          "host browser is not enabled"
expect_deny "ab open denied with no flag" \
  'agent-browser open https://example.com'          "host browser is not enabled"
# A deny that does not say how to undo itself is a dead end for the host owner.
expect_deny "the deny names the flag path" \
  'agent-browser snapshot'                          ".local/state/multiplai/host-browser-enabled"
# The gate must come first: a file: URL with the browser off is refused as
# "not enabled", never as a scheme problem, or the message teaches the wrong fix.
expect_deny "gate precedes the file: check" \
  'agent-browser open file:///etc/passwd'           "host browser is not enabled"

mkdir -p "$(dirname "$HOST_BROWSER_FLAG")"
touch "$HOST_BROWSER_FLAG"

expect_allow "ab allowed once the flag exists"      'agent-browser snapshot'              "STUB:agent-browser"
expect_allow "ab open allowed once enabled"         'agent-browser open https://example.com' "STUB:agent-browser"
# The pre-existing file:-scheme block must survive the new gate in front of it.
expect_deny "file: still blocked when enabled" \
  'agent-browser open file:///etc/passwd'           "file: URL not allowed"
expect_deny "file: blocked on goto too" \
  'agent-browser goto file:///Users/x/.ssh/id_ed25519' "file: URL not allowed"
# Non-navigation verbs never carried the file: block and must not start now.
expect_allow "non-navigation verb is untouched"     'agent-browser type hello'            "STUB:agent-browser"

rm -f "$HOST_BROWSER_FLAG"
expect_deny "removing the flag closes it again" \
  'agent-browser snapshot'                          "host browser is not enabled"

echo "# workspace jail: cwd is pinned, and a cd may not leave the workspace"
# The reported escape: the forced command ran with cwd = the host user's HOME,
# so `mlx_whisper --output-dir .` wrote into ~ on the Mac. With a declared
# workspace and no explicit cd prefix, cwd must be the workspace.
expect_allow "cwd is pinned to the declared workspace" \
  'swift build'                                     "cwd=$WS_DIR"
expect_allow "cd inside the workspace still works" \
  "cd $WS_DIR/plain && swift build"                 "cwd=$WS_DIR/plain"
expect_deny  "cd outside the workspace is denied" \
  "cd $TMP/outside-ws && swift build"               "outside the declared workspace"
expect_deny  "cd to the host home is denied" \
  "cd $FAKE_HOME && swift build"                    "outside the declared workspace"
expect_deny  "cd to / is denied" \
  'cd / && swift build'                             "outside the declared workspace"
# A string-prefix test would pass a sibling whose name merely starts with the
# workspace path.
mkdir -p "${WS_DIR}-evil"
expect_deny  "sibling sharing the workspace prefix is denied" \
  "cd ${WS_DIR}-evil && swift build"                "outside the declared workspace"
# ...and a symlink out of the workspace must not launder the check.
ln -sfn "$TMP/outside-ws" "$WS_DIR/escape-link"
expect_deny  "symlink out of the workspace is denied" \
  "cd $WS_DIR/escape-link && swift build"           "outside the declared workspace"

echo "# workspace jail: a malformed declaration is not a declaration"
echo "not/an/absolute/path" > "$WS_DECL"
expect_deny "relative path in the declaration is refused" \
  'swift build'                                     "not an existing absolute path"
echo "/nonexistent/workspace/$$" > "$WS_DECL"
expect_deny "declared path that does not exist is refused" \
  'swift build'                                     "not an existing absolute path"
echo "$WS_DIR" > "$WS_DECL"

echo "# workspace jail: fail closed when nothing is declared"
mv "$WS_DECL" "$WS_DECL.bak"
# Path-taking commands stop.
expect_deny "swift denied with no workspace declared" \
  'swift build'                                     "no workspace declared"
expect_deny "xcodebuild denied with no workspace declared" \
  'xcodebuild -scheme App build'                    "no workspace declared"
expect_deny "mlx-whisper denied with no workspace declared" \
  'mlx-whisper --output-dir . audio.m4a'            "no workspace declared"
expect_deny "qmd denied with no workspace declared" \
  'qmd query hello'                                 "no workspace declared"
expect_deny "xcrun denied with no workspace declared" \
  'xcrun simctl list'                               "no workspace declared"
# Commands that cannot express a path keep working — the upgrade must not take
# the bridge diagnostic down with it.
expect_allow "command -v survives with no workspace" \
  'command -v swift'                                ""
expect_allow "pkill survives with no workspace" \
  'pkill -f Simulator'                              "STUB:pkill"
expect_allow "curl survives with no workspace" \
  'curl http://localhost:8000/api'                  "STUB:curl"
expect_allow "gh-token survives with no workspace" \
  'multiplai-gh-token --check myapp'                "STUB:multiplai-gh-token"
expect_allow "multiplai-docker survives with no workspace" \
  'multiplai-docker ps dolce'                       "STUB:multiplai-docker"
mv "$WS_DECL.bak" "$WS_DECL"
expect_allow "restoring the declaration reopens it" \
  'swift build'                                     "STUB:swift"

echo "# workspace jail: no sandbox-exec on this host degrades to cwd pinning"
# sandbox-exec is macOS-only and pinned to /usr/bin by the gateway, so on Linux
# the wrap is skipped. The command must still run, and still run confined to the
# workspace by cwd — the layer that fixes the reported escape.
if [ ! -x /usr/bin/sandbox-exec ]; then
  expect_allow "runs without sandbox-exec present" 'swift build' "cwd=$WS_DIR"
else
  echo "  skip- sandbox-exec present; wrap is exercised on the host"
fi

echo
echo "gateway-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
