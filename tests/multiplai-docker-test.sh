#!/usr/bin/env bash
# multiplai-docker-test.sh — stub-docker harness for multiplai-docker.py.
#
# Docker cannot be exercised from inside a Claude session container (no daemon,
# no socket, and the host bridge does not allowlist `docker`). So this harness
# does what the kit's evals/unit/test_claude_sh_env.py does for claude.sh: puts
# a stub `docker` first on PATH that records the argv it was handed, and asserts
# on the DECISIONS the tool makes — which compose file, which project name,
# which flags — never on what a real daemon would do.
#
# Requirements: python3 (the tool) and bash. No daemon, no network.
#
# Usage:  ./tests/multiplai-docker-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../multiplai-docker.py"
PY="${MULTIPLAI_DOCKER_TEST_PYTHON:-$(command -v python3 || true)}"
[ -n "$PY" ] || { echo "SKIP: python3 not found"; exit 2; }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # resolve /tmp symlinks: the tool realpaths its inputs
trap 'rm -rf "$TMP"' EXIT

STUB="$TMP/bin"
FAKE_HOME="$TMP/home"
PROJ="$TMP/proj"
WT="$TMP/.worktrees"
ARGV="$TMP/argv.log"
CAPTURED="$TMP/captured.json"
CONFIG_JSON="$TMP/config.json"
PS_ROWS="$TMP/ps.tsv"
PROFILES="$FAKE_HOME/.local/share/multiplai/docker-profiles"

mkdir -p "$STUB" "$FAKE_HOME" "$PROJ/app" "$PROJ/logs" "$WT/wt1/app" \
  "$WT/wt2/app" "$WT/wt3" "$TMP/outside" "$TMP/tmp"
# A bind source that is a FILE: it cannot be invented, so a worktree missing it
# is still a clean failure (wt2). wt1 has one; wt2 deliberately does not.
# wt3 has no app/ at all: the BUILD CONTEXT is missing, which must fail before
# the bind loop can auto-create the directory and defer the error to docker.
# outside/ holds a bind source that BIND_ROOT does not cover: never rewritten,
# reported at freeze time and warned about on worktree `up`.
touch "$PROJ/.env" "$WT/wt1/.env" "$TMP/outside/shared.conf"
touch "$PROJ/app/Dockerfile" "$WT/wt1/app/Dockerfile" "$WT/wt2/app/Dockerfile"
: > "$ARGV"
: > "$PS_ROWS"

# The compose sources. Their CONTENT is irrelevant — the stub `docker compose
# config` returns the canned resolution below — but they must exist, because
# freeze stats them and hashes them for the drift check.
printf 'services: {}\n' > "$PROJ/docker-compose.yml"
printf 'services: {}\n' > "$PROJ/docker-compose.dev.yml"

# What the stub's `compose config --format json` returns: published ports (which
# freeze must strip), a bind under BIND_ROOT and a NAMED volume beside it (which
# the worktree rewrite must leave alone — Gate A: the resolved list mixes both).
cat > "$CONFIG_JSON" <<EOF
{
  "name": "dolceengine",
  "services": {
    "mysql": {
      "image": "mysql:8",
      "ports": [{"mode": "ingress", "target": 3306, "published": "3306", "protocol": "tcp"}]
    },
    "engine": {
      "image": "engine:dev",
      "build": {"context": "$PROJ/app", "dockerfile": "$PROJ/app/Dockerfile"},
      "ports": [{"mode": "ingress", "target": 8000, "published": "8000", "protocol": "tcp"}],
      "labels": {"pre.existing": "keep"},
      "volumes": [
        {"type": "bind", "source": "$PROJ/app", "target": "/app"},
        {"type": "bind", "source": "$PROJ/logs", "target": "/app/logs"},
        {"type": "bind", "source": "$PROJ/.env", "target": "/app/.env"},
        {"type": "bind", "source": "$TMP/outside/shared.conf", "target": "/etc/shared.conf"},
        {"type": "volume", "source": "engine_static", "target": "/static"}
      ]
    },
    "celery-beat": {"image": "engine:dev"}
  },
  "volumes": {
    "engine_static": {"name": "dolceengine_engine_static"},
    "shared": {"external": true, "name": "shared_prod"}
  },
  "networks": {"default": {"name": "dolceengine_default"}}
}
EOF

cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
# Record the full argv, one invocation per line.
printf '%s\n' "\$*" >> "$ARGV"
# Snapshot whatever file was passed as -f, so a test can inspect a temp compose
# file the tool deletes as soon as we return.
prev=""
for a in "\$@"; do
  [ "\$prev" = "-f" ] && cp "\$a" "$CAPTURED" 2>/dev/null
  prev="\$a"
done
for a in "\$@"; do
  [ "\$a" = "config" ] && { cat "$CONFIG_JSON"; exit 0; }
done
[ "\${1:-}" = "ps" ] && { cat "$PS_ROWS"; exit 0; }
exit \${DOCKER_STUB_RC:-0}
EOF
chmod +x "$STUB/docker"

# The frozen JSON assertions live in files rather than heredocs so they can be
# run as ordinary commands by assert() below.
cat > "$TMP/check_frozen.py" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
svcs = data["services"]
assert not any("ports" in s for s in svcs.values()), "ports survived the freeze"
assert svcs["engine"]["labels"]["multiplai.profile"] == "dolce"
assert svcs["engine"]["labels"]["pre.existing"] == "keep", "freeze dropped an existing label"
assert svcs["mysql"]["labels"]["multiplai.profile"] == "dolce"
# The stripped host ports survive as metadata, so `up` can print URLs.
assert svcs["engine"]["x-multiplai-ports"] == [8000], svcs["engine"]
assert "x-multiplai-ports" not in svcs["celery-beat"], "invented ports for a portless service"
# `compose config` resolves volume/network names against the SOURCE project;
# frozen as-is, every instance would share one volume set and one network.
assert "name" not in data["volumes"]["engine_static"], "project-scoped volume name survived"
assert "name" not in data["networks"]["default"], "project-scoped network name survived"
# …but an external volume names something the stack does not own: keep it.
assert data["volumes"]["shared"]["name"] == "shared_prod", "dropped an external volume's name"
EOF
cat > "$TMP/check_rewrite.py" <<'EOF'
import json, sys
import os
engine = json.load(open(sys.argv[1]))["services"]["engine"]
vols = engine["volumes"]
binds = {v["target"]: v["source"] for v in vols if v["type"] == "bind"}
named = [v for v in vols if v["type"] == "volume"]
wt, outside = sys.argv[2], sys.argv[3]
assert binds["/app"] == wt + "/app", binds
assert binds["/app/.env"] == wt + "/.env", binds
# gitignored artifact dir: absent from the worktree, created rather than refused
assert binds["/app/logs"] == wt + "/logs", binds
assert os.path.isdir(wt + "/logs"), "the missing bind directory was not created"
# a bind outside BIND_ROOT cannot follow the worktree: left at the live path
assert binds["/etc/shared.conf"] == outside + "/shared.conf", binds
# images are part of the instance: build context and dockerfile follow too
assert engine["build"]["context"] == wt + "/app", engine["build"]
assert engine["build"]["dockerfile"] == wt + "/app/Dockerfile", engine["build"]
assert len(named) == 1 and named[0]["source"] == "engine_static", named
EOF

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL- $1"; echo "        rc=$RC"; echo "        out=$OUT"; echo "        err=$ERR"; }

md() {  # run the tool; sets OUT, ERR, RC
  # TMPDIR is pinned into the sandbox so a test can find (and prove the removal
  # of) the temp compose file the worktree rewrite writes.
  OUT="$(HOME="$FAKE_HOME" PATH="$STUB:$PATH" TMPDIR="$TMP/tmp" \
        env -u SSH_CONNECTION -u SSH_ORIGINAL_COMMAND \
        "$PY" "$TOOL" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
last_argv() { tail -n 1 "$ARGV"; }
# `up` is followed by the `docker ps` that print_urls runs, so the compose argv
# under test is the last `up -d` line, not the last line.
up_argv()   { grep -e ' up -d --wait ' "$ARGV" | tail -n 1; }

# Predicates, so every assertion is a COMMAND (keeps `$?`-after-a-condition,
# and the subtle overwrite bug behind it, out of the harness entirely).
# shellcheck disable=SC2053  # the right-hand side is a glob on purpose
like()     { [[ "$1" == $2 ]]; }
# shellcheck disable=SC2053
unlike()   { [[ "$1" != $2 ]]; }
mode_is()  { [ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = "$2" ]; }
argv_is()  { [ "$(last_argv)" = "$1" ]; }

assert() {  # $1 name, rest: a command whose exit status IS the assertion
  local name="$1"; shift
  if "$@"; then ok "$name"
  else FAIL=$((FAIL+1)); echo "  FAIL- $name"; echo "        last argv: $(last_argv)"; fi
}
expect_ok() {   # $1 name, rest: tool argv
  local name="$1"; shift
  md "$@"
  if [ "$RC" -eq 0 ]; then ok "$name"; else bad "$name"; fi
}
expect_fail() { # $1 name, $2 required stderr substring, rest: tool argv
  local name="$1" want="$2"; shift 2
  md "$@"
  if [ "$RC" -ne 0 ] && [[ "$ERR" == *"$want"* ]]; then ok "$name"; else bad "$name"; fi
}
expect_argv() { # $1 name, $2 expected full argv line
  if [ "$(last_argv)" = "$2" ]; then ok "$1"
  else FAIL=$((FAIL+1)); echo "  FAIL- $1"; echo "        want: $2"; echo "        got : $(last_argv)"; fi
}
expect_up_argv() { # $1 name, $2 expected full argv line for the compose `up`
  if [ "$(up_argv)" = "$2" ]; then ok "$1"
  else FAIL=$((FAIL+1)); echo "  FAIL- $1"; echo "        want: $2"; echo "        got : $(up_argv)"; fi
}

FROZEN="$PROFILES/dolce.json"
CONF="$PROFILES/dolce.conf"

echo "# freeze — the trust step"
expect_ok "freeze writes a profile" freeze dolce \
  -f "$PROJ/docker-compose.yml" -f "$PROJ/docker-compose.dev.yml"
assert "freeze wrote <name>.json"      test -f "$FROZEN"
assert "freeze wrote <name>.conf"      test -f "$CONF"
assert "frozen json is mode 600"       mode_is "$FROZEN" 600
assert "profile conf is mode 600"      mode_is "$CONF" 600
assert "freeze strips ports from every service and labels them" \
  "$PY" "$TMP/check_frozen.py" "$FROZEN"
assert "conf records the service list" grep -q "^SERVICES=celery-beat engine mysql$" "$CONF"
assert "conf derives WORKTREE_ROOT from the tree" grep -q "^WORKTREE_ROOT=$WT$" "$CONF"
assert "conf derives BIND_ROOT from the project dir" grep -q "^BIND_ROOT=$PROJ$" "$CONF"
assert "freeze counts the paths BIND_ROOT does not cover" \
  like "$OUT" '*NOTE: 1 path(s) fall outside BIND_ROOT*'
assert "freeze names the out-of-root bind and its service" \
  like "$OUT" "*$TMP/outside/shared.conf (bind, service engine)*"
assert "freeze points at the --bind-root remedy" like "$OUT" '*--bind-root*'

echo "# freeze is a host-terminal act"
OUT=""; RC=0
ERR="$(SSH_CONNECTION='127.0.0.1 1 127.0.0.1 22' HOME="$FAKE_HOME" PATH="$STUB:$PATH" \
      "$PY" "$TOOL" freeze dolce -f "$PROJ/docker-compose.yml" 2>&1 >/dev/null)" || RC=1
assert "freeze refuses when it can see it came over SSH" \
  like "$RC|$ERR" '1|*not reachable over SSH*'

echo "# up/down/ps — the frozen file, verbatim, when no worktree matches"
# print_urls reads `docker ps` for the container names; the stub replays this.
printf 'dolce-main-engine-1\tengine\ndolce-main-celery-beat-1\tcelery-beat\n' > "$PS_ROWS"
expect_ok "up succeeds" up dolce
assert "no out-of-root warning when no worktree is involved" \
  unlike "$ERR" '*outside BIND_ROOT*'
expect_up_argv "up argv is exactly the frozen file + project" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main up -d --wait --wait-timeout 600"
assert "up prints the hostname URL for a service that had published ports" \
  like "$OUT" '*http://dolce-main-engine-1.orb.local:8000*'
assert "up prints no URL for a service that had none" \
  unlike "$OUT" '*celery-beat-1.orb.local*'
assert "up warns that first boot is slow, not hung" like "$OUT" '*not a hang*'

# `up` returning must mean the stack is USABLE: a container reaches `running` in
# seconds while a migrating entrypoint needs minutes, and an exec into that gap
# reads a half-migrated schema as a data bug.
DOCKER_STUB_RC=1 md up dolce
assert "a failed wait is a non-zero exit" [ "$RC" -ne 0 ]
assert "a failed wait points at ps/logs rather than just failing" \
  like "$ERR" '*multiplai-docker logs dolce <service>*'
assert "a failed wait prints no URLs" unlike "$OUT" '*orb.local*'
: > "$PS_ROWS"
expect_ok "down succeeds" down dolce --instance b
expect_argv "down passes -v and the per-instance project" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-b down -v"
expect_ok "ps succeeds" ps dolce --instance b
expect_argv "ps argv" "compose -f $FROZEN --project-directory $PROJ -p dolce-b ps"

echo "# the one runtime transform: worktree rewrite (binds + build paths)"
expect_ok "up in a worktree instance" up dolce --instance wt1
WT_COMPOSE="$(up_argv)"; WT_COMPOSE="${WT_COMPOSE#compose -f }"; WT_COMPOSE="${WT_COMPOSE%% *}"
assert "worktree instance warns about the bind BIND_ROOT does not cover" \
  like "$ERR" '*outside BIND_ROOT*LIVE tree*'
assert "the warning names the live path" like "$ERR" "*$TMP/outside/shared.conf*"
assert "worktree instance runs against a TEMP compose file, not the frozen one" \
  like "$WT_COMPOSE" "$TMP/tmp/multiplai-docker-dolce-wt1-*.json"
assert "worktree instance keeps the per-instance project name" \
  like "$(up_argv)" '*-p dolce-wt1 up -d --wait*'
assert "binds and build paths under BIND_ROOT are re-prefixed; named volume and out-of-root bind untouched" \
  "$PY" "$TMP/check_rewrite.py" "$CAPTURED" "$WT/wt1" "$TMP/outside"
assert "the temp compose file is cleaned up" test ! -e "$WT_COMPOSE"
expect_fail "a bind with no counterpart in the worktree fails cleanly" \
  "bind source" up dolce --instance wt2
expect_fail "a missing build context fails cleanly, before the bind loop invents the directory" \
  "build context" up dolce --instance wt3
expect_ok "a non-worktree instance still uses the frozen file" up dolce --instance b
expect_up_argv "non-worktree instance argv" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-b up -d --wait --wait-timeout 600"

echo "# logs / restart / build"
expect_ok "logs default tail" logs dolce engine
expect_argv "logs defaults to 200, no colour, never --follow" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main logs --no-color --tail 200 engine"
expect_ok "logs explicit tail" logs dolce engine 50
expect_argv "logs honours a numeric tail" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main logs --no-color --tail 50 engine"
expect_ok "logs huge tail" logs dolce engine 999999
expect_argv "logs caps the tail at 2000" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main logs --no-color --tail 2000 engine"
expect_fail "logs rejects a non-numeric tail" "must be a number" logs dolce engine abc
expect_fail "logs rejects a service not in the profile" "is not in profile" logs dolce nope
expect_ok "restart" restart dolce celery-beat
expect_argv "restart argv" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main restart celery-beat"
expect_ok "build" build dolce engine
expect_argv "build argv carries no --ssh/--secret/--allow/--network" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main build engine"
expect_fail "build refuses a caller-supplied flag" "flag not allowed" \
  build dolce engine --ssh default
expect_fail "build refuses --network=host" "flag not allowed" \
  build dolce engine --network=host

echo "# exec — guest argv reaches the guest, never Docker"
expect_ok "exec" exec dolce engine -- python manage.py showmigrations
expect_argv "exec runs -T and forwards the guest argv" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main exec -T engine python manage.py showmigrations"
expect_fail "exec rejects a leading-dash guest argument" "may not start with" \
  exec dolce engine -- python --version
expect_fail "exec rejects a guest argument outside the charset" "not allowed" \
  exec dolce engine -- 'python;id'
expect_fail "exec needs a command after --" "needs a command after" exec dolce engine --
expect_fail "exec needs a --" "exec needs" exec dolce engine

echo "# profile / instance validation"
expect_fail "profile with a slash"      "invalid profile name" up "dolce/evil"
expect_fail "profile traversal"         "invalid profile name" up "../../etc/passwd"
expect_fail "uppercase profile"         "invalid profile name" up "Dolce"
expect_fail "unknown profile"           "no such profile"      up "absent"
expect_fail "instance with a slash"     "invalid instance"     up dolce --instance "a/b"
expect_fail "instance traversal"        "invalid instance"     up dolce --instance ".."
expect_fail "uppercase instance"        "invalid instance"     up dolce --instance "WT1"
expect_fail "instance too long"         "invalid instance"     up dolce --instance aaaaaaaaaaaaaaaaa
expect_fail "unknown verb exits non-zero" "unknown verb"       foo dolce
expect_fail "up takes no extra arguments" "no extra arguments" up dolce extra

echo "# ls / reap read back profile + compose-project labels"
# The fresh row's timestamp is generated, never hardcoded: a literal date makes
# the reap test pass only within N hours of the day it was written, then fail
# for reasons that have nothing to do with the code (it did, 2026-08-06).
NOW_STAMP="$(date -u '+%Y-%m-%d %H:%M:%S +0000 UTC')"
{
  printf 'abc123\tdolce\tdolce-wt1\tengine\t%s\tUp 2 hours\n' "$NOW_STAMP"
  printf 'def456\tdolce\tdolce-old\tmysql\t2000-01-01 00:00:00 +0000 UTC\tUp 5 years\n'
} > "$PS_ROWS"
expect_ok "ls" ls
assert "ls derives the instance from the project name" like "$OUT" '*dolce*wt1*dolce-wt1*'
assert "ls filters on the multiplai.profile label" \
  argv_is 'ps -a --filter label=multiplai.profile --format {{.ID}}	{{.Label "multiplai.profile"}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.service"}}	{{.CreatedAt}}	{{.Status}}'
expect_ok "ls <profile>" ls dolce
assert "ls <profile> narrows the filter" like "$(last_argv)" '*label=multiplai.profile=dolce*'
expect_fail "reap needs numeric hours" "must be a number" reap-older-than soon
expect_ok "reap" reap-older-than 24
assert "reap tears down only the stale instance, with -v" \
  argv_is "compose -f $FROZEN --project-directory $PROJ -p dolce-old down -v"
: > "$PS_ROWS"

echo "# drift warns, never fails"
GOOD_SHA="$(grep '^SOURCE_SHA256=' "$CONF")"
sed -i.bak 's/^SOURCE_SHA256=.*/SOURCE_SHA256=deadbeef/' "$CONF" && rm -f "$CONF.bak"
expect_ok "up proceeds against a stale profile" up dolce
assert "up warns on drift" like "$ERR" '*is stale*'
expect_up_argv "a stale profile still runs the frozen file" \
  "compose -f $FROZEN --project-directory $PROJ -p dolce-main up -d --wait --wait-timeout 600"
sed -i.bak "s|^SOURCE_SHA256=.*|$GOOD_SHA|" "$CONF" && rm -f "$CONF.bak"
md up dolce
assert "no warning once the hashes match again" unlike "$ERR" '*is stale*'

echo "# profile files must be trustworthy"
chmod g+w "$CONF"
expect_fail "a group-writable profile is refused" "group/world-writable" up dolce
chmod 600 "$CONF"
chmod o+w "$FROZEN"
expect_fail "a world-writable frozen file is refused" "group/world-writable" up dolce
chmod 600 "$FROZEN"
ln -sf /etc/passwd "$PROFILES/escape.conf"
expect_fail "a profile symlinked out of the directory is refused" \
  "escapes the profile directory" up escape
rm -f "$PROFILES/escape.conf"
ln -sf "$CONF" "$PROFILES/inside.conf"   # stays in the dir: caught by lstat, not by realpath
expect_fail "a symlinked profile is refused even when it points inside" "symlink" up inside
rm -f "$PROFILES/inside.conf"
expect_ok "still fine after the trust checks" up dolce

echo
echo "multiplai-docker-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
