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
for c in swift xcodebuild xcrun qmd curl pkill; do
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

# Dirs exercising the cd prefix.
mkdir -p "$TMP/gw test dir" "$TMP/gw (paren) dir" "$TMP/plain"

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
expect_allow "cd escaped space"   "cd $TMP/gw\\ test\\ dir && swift build"       "cwd=$TMP/gw test dir"
expect_allow "cd escaped parens"  "cd $TMP/gw\\ \\(paren\\)\\ dir && swift build" "cwd=$TMP/gw (paren) dir"
expect_allow "cd single-quoted"   "cd '$TMP/gw test dir' && swift build"          "cwd=$TMP/gw test dir"
expect_allow "cd plain"           "cd $TMP/plain && swift build"                  "cwd=$TMP/plain"

echo "# escaped metachars in argv are data, not shell"
expect_allow "escaped paren scheme is one argv word" \
  'xcodebuild -scheme MyApp\ \(Dev\) build' 'ARG:[MyApp (Dev)]'

echo "# smuggling attempts stay denied"
expect_deny "semicolon chain"           'swift build; rm -rf /tmp/x'          "metacharacter"
expect_deny "&& chain after cd"         "cd $TMP/plain && rm -rf /tmp/x && swift build" "metacharacter"
expect_deny "command substitution"      'swift build $(touch /tmp/pwned)'     "metacharacter"
expect_deny "backtick substitution"     'swift build `touch /tmp/pwned`'      "metacharacter"
expect_deny "pipe to shell"             'swift build | sh'                    "metacharacter"
expect_deny "redirect"                  'swift build > /tmp/x'                "metacharacter"
expect_deny "unescaped paren"           'swift build (dev)'                   "metacharacter"
expect_deny "newline smuggle"           $'swift build\nrm -rf /tmp/x'         "metacharacter"
expect_deny "escaped-backslash + live semicolon" 'swift build \\; rm -rf /tmp/x' "metacharacter"
expect_deny "not allowlisted"           'rm -rf /tmp/x'                       "not in allowlist"
expect_deny "cd unescaped space (two words)" "cd $TMP/gw test dir && swift build" "malformed cd prefix"
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

echo
echo "gateway-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
