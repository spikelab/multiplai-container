#!/usr/bin/env bash
# git-hooks-test.sh — harness for git-hooks/dispatch, the container-wide
# secret-leak gate.
#
# Builds throwaway repos with core.hooksPath pointed at the real dispatcher
# (symlinked under each hook name exactly as the Dockerfile does) and asserts
# the behaviour that matters:
#
#   * a secret in the staged diff blocks the commit
#   * a secret in the pushed range blocks the push (the --no-verify backstop,
#     and the only gate private repos get)
#   * the secret VALUE never reaches stdout/stderr (redaction) — a leak report
#     that echoes the credential into scrollback and agent transcripts is its
#     own leak
#   * repo-local hooks still run, and pre-push still receives its stdin ref
#     lines — hooksPath replaces .git/hooks, so this delegation is the only
#     thing keeping existing per-repo hooks alive
#   * the dispatcher does not exec itself (hooksPath must not be resolved via
#     `git rev-parse --git-path hooks`)
#   * a missing gitleaks binary fails CLOSED
#   * a force-push whose replaced remote tip is absent from the local odb is
#     still scanned (gitleaks exits 0 on an invalid range — the fail-open this
#     pins), and a range that cannot be walked at all fails CLOSED as a scan
#     error, not a clean scan
#   * check-hookspath flags repos overriding core.hooksPath locally, warn-only
#
# Requirements: git and gitleaks on PATH. Override the binary with
# GITLEAKS_BIN=/path/to/gitleaks.
#
# Usage:  ./tests/git-hooks-test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$HERE/../git-hooks/dispatch"
[ -f "$DISPATCH" ] || { echo "missing: $DISPATCH"; exit 2; }

GITLEAKS_BIN="${GITLEAKS_BIN:-$(command -v gitleaks || true)}"
[ -n "$GITLEAKS_BIN" ] || { echo "SKIP: gitleaks not found (set GITLEAKS_BIN)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Test vectors, assembled at runtime from two halves on purpose: written whole,
# these literals would make gitleaks flag THIS FILE when it scans its own
# repository.
#
# SECRET is a GitHub PAT shape (github-pat, an upstream default rule).
# ANT_SECRET is a Claude OAuth access token shape — covered ONLY by the
# baseline gitleaks.toml this repo ships, so this vector is what proves the
# custom ruleset is actually loaded. Upstream gitleaks 8.29 defaults return
# "no leaks found" for it, which is the whole reason gitleaks.toml exists.
#
# Note the lengths: github-pat requires exactly 36 characters after ghp_, and a
# 35-character string silently does not match.
SECRET="ghp_""aB3dE6gH9jK2mN5pQ8sT1vW4xY7zA0bC3dEf"
ANT_SECRET="sk-ant-oat01-""9wE2rT5yU8iO1pA4sD7fG0hJ3kL6zXcVbNmQwErTyUiOpAsDfGhJkLzXcVbNmQwErTyUiOpQwErTyUiOpAsDfGhJkLzXAA"

# Hook dir mirroring the image layout: dispatcher, ruleset, symlinks per hook.
HOOKS="$TMP/git-hooks"
mkdir -p "$HOOKS"
cp "$DISPATCH" "$HOOKS/dispatch"
cp "$HERE/../git-hooks/gitleaks.toml" "$HOOKS/gitleaks.toml"
chmod 755 "$HOOKS/dispatch"
for h in pre-commit pre-push commit-msg post-commit; do
    ln -sf dispatch "$HOOKS/$h"
done

BIN="$TMP/bin"; mkdir -p "$BIN"
ln -sf "$GITLEAKS_BIN" "$BIN/gitleaks"
export PATH="$BIN:$PATH"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL- $1"; echo "        rc=$RC"; echo "        out=$OUT"; }
# Explicit if/else rather than `cond && ok || bad`, which shellcheck rightly
# flags (SC2015): with that form `bad` also runs whenever `ok` itself fails.
pass_if()  { if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }   # expect success
fail_if()  { if [ "$RC" -ne 0 ]; then ok "$1"; else bad "$1"; fi; }   # expect refusal

# A fresh repo with the shared hooks wired in. Commit identity and hooksPath go
# in local config so the harness never depends on the caller's git setup.
new_repo() {  # $1 = name; echoes the path
    local d="$TMP/$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email test@example.com
    git -C "$d" config user.name  "Hook Test"
    git -C "$d" config commit.gpgsign false
    git -C "$d" config core.hooksPath "$HOOKS"
    printf 'hello\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" -c core.hooksPath=/dev/null commit -qm init
    printf '%s' "$d"
}

run() {  # captures stdout+stderr and rc into OUT/RC
    OUT="$("$@" 2>&1)"; RC=$?
}

echo "== pre-commit"

R="$(new_repo clean)"
printf 'just some code\n' > "$R/app.py"
git -C "$R" add app.py
run git -C "$R" commit -qm "clean change"
pass_if "clean staged diff commits"

R="$(new_repo leaky)"
printf 'aws_key = "%s"\n' "$SECRET" > "$R/conf.py"
git -C "$R" add conf.py
run git -C "$R" commit -qm "oops"
fail_if "staged secret blocks the commit"

# The commit must not exist: this gate's value over server-side push protection
# is that there is no object to rewrite afterwards.
run git -C "$R" log --oneline
case "$OUT" in *oops*) bad "blocked commit left no commit object";; *) ok "blocked commit left no commit object";; esac

# Redaction. Re-run the blocked commit and search the whole output for the
# literal key.
OUT="$(git -C "$R" commit -qm "oops" 2>&1)"
case "$OUT" in *"$SECRET"*) bad "secret value is redacted from output";; *) ok "secret value is redacted from output";; esac

run git -C "$R" commit -qm "oops" --no-verify
pass_if "--no-verify bypasses the commit gate"

# The regression test that matters most. Upstream gitleaks defaults do NOT
# detect sk-ant-* tokens, so if the baseline gitleaks.toml stops being passed
# (or stops being shipped), this is the case that fails — and the credential it
# represents is mounted into every container session.
R="$(new_repo anthropic)"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$ANT_SECRET" > "$R/.credentials.json"
git -C "$R" add -f .credentials.json
run git -C "$R" commit -qm "creds"
fail_if "Claude OAuth token blocks the commit (custom ruleset live)"
case "$OUT" in *"$ANT_SECRET"*) bad "Claude OAuth token is redacted";; *) ok "Claude OAuth token is redacted";; esac

# False positives train people to bypass the gate, so the placeholder cases
# have to stay silent.
R="$(new_repo placeholders)"
{
    printf 'DATABASE_URL=postgresql://user:password@localhost:5432/db\n'
    # shellcheck disable=SC2016  # the literal ${...} is the test vector
    printf 'ALT_URL=postgres://admin:${DB_PASSWORD}@host/db\n'
    printf 'MY_URL=mysql://root:changeme@127.0.0.1/app\n'
} > "$R/env.example"
git -C "$R" add env.example
run git -C "$R" commit -qm "example env"
pass_if "placeholder DB URLs do not trip the gate"

# ...but a real-looking one must.
R="$(new_repo realdburl)"
printf 'DATABASE_URL = "postgresql://svc_user:Xk9mQ2vN7bL4pS8d@10.0.0.5:5432/prod"\n' > "$R/settings.py"
git -C "$R" add settings.py
run git -C "$R" commit -qm "db url"
fail_if "DB URL with a real inline password blocks the commit"

echo "== chaining to repo-local hooks"

# hooksPath replaces .git/hooks; the dispatcher must delegate. A repo-local
# pre-commit that exits 1 is the clearest probe: if it runs, the commit fails.
R="$(new_repo chain-commit)"
cat > "$R/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "REPO-LOCAL-PRECOMMIT-RAN"
exit 1
EOF
chmod +x "$R/.git/hooks/pre-commit"
printf 'clean\n' > "$R/ok.py"
git -C "$R" add ok.py
run git -C "$R" commit -qm "should hit repo hook"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *REPO-LOCAL-PRECOMMIT-RAN* ]]; then
    ok "repo-local pre-commit still runs and can veto"
else
    bad "repo-local pre-commit still runs and can veto"
fi

# Same file, exiting 0: proves the dispatcher does not recurse into itself.
# A hooksPath-resolving lookup would exec the dispatcher forever instead.
cat > "$R/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "REPO-LOCAL-PRECOMMIT-RAN"
exit 0
EOF
run git -C "$R" commit -qm "repo hook allows"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *REPO-LOCAL-PRECOMMIT-RAN* ]]; then
    ok "dispatcher chains once, no self-recursion"
else
    bad "dispatcher chains once, no self-recursion"
fi

echo "== pre-push"

# Bare repo as the remote so pushes are real.
REMOTE="$TMP/remote.git"; git init -q --bare -b main "$REMOTE"

R="$(new_repo pushclean)"
git -C "$R" remote add origin "$REMOTE"
run git -C "$R" push -q origin main
pass_if "clean history pushes"

# The backstop: a secret committed with --no-verify must still be caught on the
# way out. This is the path that covers private repos, where GitHub's free
# secret scanning and push protection do not apply at all.
printf 'aws_key = "%s"\n' "$SECRET" > "$R/leak.py"
git -C "$R" add leak.py
git -C "$R" commit -qm "sneak past" --no-verify >/dev/null 2>&1
run git -C "$R" push -q origin main
fail_if "secret in pushed range blocks the push"
case "$OUT" in *"$SECRET"*) bad "secret value is redacted from push output";; *) ok "secret value is redacted from push output";; esac

# New-branch case: remote_sha is all zeros, so the range must be computed from
# --not --remotes rather than a nonexistent baseline.
git -C "$R" checkout -q -b feature-leak
run git -C "$R" push -q origin feature-leak
fail_if "new branch with a secret blocks the push"

# pre-push stdin must survive being consumed for the scan and replayed to the
# repo's own hook — this is exactly multiplai-gui's archive/* ref guard.
R2="$(new_repo pushchain)"
git -C "$R2" remote add origin "$REMOTE"
cat > "$R2/.git/hooks/pre-push" <<'EOF'
#!/bin/sh
while read -r local_ref local_sha remote_ref remote_sha; do
  echo "REPO-LOCAL-PREPUSH-SAW:$local_ref:$remote_ref"
  case "$local_ref" in refs/heads/archive/*) exit 1;; esac
done
exit 0
EOF
chmod +x "$R2/.git/hooks/pre-push"
git -C "$R2" checkout -q -b allowed
run git -C "$R2" push -q origin allowed
if [ "$RC" -eq 0 ] && [[ "$OUT" == *REPO-LOCAL-PREPUSH-SAW:refs/heads/allowed* ]]; then
    ok "repo-local pre-push receives replayed stdin ref lines"
else
    bad "repo-local pre-push receives replayed stdin ref lines"
fi

git -C "$R2" checkout -q -b archive/private
run git -C "$R2" push -q origin archive/private
fail_if "repo-local pre-push can still veto (archive/* guard)"

# Empty stdin (git normally skips pre-push when nothing is pushed, but be
# strict): the repo-local hook must receive EOF, not one blank ref line.
# Invoke the dispatcher directly — real git cannot produce this case.
R3="$(new_repo emptystdin)"
cat > "$R3/.git/hooks/pre-push" <<'EOF'
#!/bin/sh
if IFS= read -r line; then
  echo "GOT-A-LINE:$line"
  exit 1
fi
exit 0
EOF
chmod +x "$R3/.git/hooks/pre-push"
OUT="$(cd "$R3" && "$HOOKS/pre-push" origin "$REMOTE" </dev/null 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" != *GOT-A-LINE* ]]; then
    ok "empty pre-push stdin replays as EOF, not a blank line"
else
    bad "empty pre-push stdin replays as EOF, not a blank line"
fi

echo "== pre-push fail-open regression (stale clone + force-push)"

# The blocker this pins: gitleaks 8.29.0 exits 0 when its underlying `git log`
# fails on an invalid revision range — it scans NOTHING and passes. The range
# "$remote_sha..$local_sha" is invalid exactly when the remote tip is absent
# from the local odb, i.e. after the history rewrite + force-push the leak
# banner itself recommends, done from a clone that never fetched that tip.
REMOTE2="$TMP/remote2.git"; git init -q --bare -b main "$REMOTE2"

# Seed the remote from one clone… (2>/dev/null: the empty-repo clone warning
# is expected and noise here)
SEED="$TMP/seed"; git clone -q "$REMOTE2" "$SEED" 2>/dev/null
git -C "$SEED" config user.email test@example.com
git -C "$SEED" config user.name  "Hook Test"
git -C "$SEED" config commit.gpgsign false
printf 'hello\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" -c core.hooksPath=/dev/null commit -qm init
git -C "$SEED" -c core.hooksPath=/dev/null push -q origin main

# …take a second clone, which will go stale…
STALE="$TMP/stale"; git clone -q "$REMOTE2" "$STALE"
git -C "$STALE" config user.email test@example.com
git -C "$STALE" config user.name  "Hook Test"
git -C "$STALE" config commit.gpgsign false
git -C "$STALE" config core.hooksPath "$HOOKS"

# …advance the remote from the seed clone (a commit the stale clone never
# fetches)…
printf 'more\n' >> "$SEED/README.md"
git -C "$SEED" -c core.hooksPath=/dev/null commit -qam advance
git -C "$SEED" -c core.hooksPath=/dev/null push -q origin main

# …then commit a secret in the stale clone and force-push. remote_sha is
# unknown locally; the dispatcher must fall back to a walkable range and
# still block.
printf 'aws_key = "%s"\n' "$SECRET" > "$STALE/leak.py"
git -C "$STALE" add leak.py
git -C "$STALE" commit -qm "rewritten" --no-verify >/dev/null 2>&1
run git -C "$STALE" push -q --force origin main
fail_if "force-push with unknown remote tip still scans (stale clone)"
run git -C "$REMOTE2" log --all --oneline
case "$OUT" in *rewritten*) bad "the secret never reached the remote";; *) ok "the secret never reached the remote";; esac

# When even the fallback range cannot be walked (here: a remote-tracking ref
# whose object does not exist locally), the push must fail CLOSED with an
# explicit scan-error message — not sail through unscanned, and not claim a
# finding.
BROKEN="$(new_repo brokenremote)"
git -C "$BROKEN" remote add origin "$REMOTE"
mkdir -p "$BROKEN/.git/refs/remotes/origin"
printf '%s\n' "0123456789abcdef0123456789abcdef01234567" > "$BROKEN/.git/refs/remotes/origin/bogus"
git -C "$BROKEN" checkout -q -b broken-branch
run git -C "$BROKEN" push -q origin broken-branch
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"SCAN ERROR"* ]]; then
    ok "unwalkable range fails closed as a scan error (not a finding)"
else
    bad "unwalkable range fails closed as a scan error (not a finding)"
fi

echo "== hooksPath drift warning (check-hookspath)"

CHECK="$HERE/../git-hooks/check-hookspath"
D="$TMP/drift-clean"; mkdir -p "$D"
git init -q "$D/plain-repo"
OUT="$("$CHECK" "$D" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "repos without a local hooksPath stay silent"
else
    bad "repos without a local hooksPath stay silent"
fi

# Every harness repo sets core.hooksPath locally (that is how the dispatcher
# gets wired in), so the scratch dir is a ready-made drift fixture.
OUT="$("$CHECK" "$TMP" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" == *core.hooksPath* ]]; then
    ok "local hooksPath overrides are flagged, warn-only (rc 0)"
else
    bad "local hooksPath overrides are flagged, warn-only (rc 0)"
fi

echo "== fail-closed"

# gitleaks missing means a broken image, not a licence to stop scanning.
R="$(new_repo noscanner)"
printf 'clean\n' > "$R/x.py"
git -C "$R" add x.py
OUT="$(PATH="$TMP/empty:/usr/bin:/bin" git -C "$R" commit -qm "no scanner" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"gitleaks not found"* ]]; then
    ok "missing gitleaks blocks the commit (fails closed)"
else
    bad "missing gitleaks blocks the commit (fails closed)"
fi

# A missing ruleset must be fatal too, not a silent fallback to defaults —
# falling back would reintroduce exactly the sk-ant-* blind spot.
HOOKS2="$TMP/git-hooks-noconfig"
mkdir -p "$HOOKS2"
cp "$DISPATCH" "$HOOKS2/dispatch"; chmod 755 "$HOOKS2/dispatch"
ln -sf dispatch "$HOOKS2/pre-commit"
R="$(new_repo noconfig)"
git -C "$R" config core.hooksPath "$HOOKS2"
printf 'clean\n' > "$R/y.py"
git -C "$R" add y.py
run git -C "$R" commit -qm "no ruleset"
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"ruleset missing"* ]]; then
    ok "missing ruleset blocks the commit (no silent fallback to defaults)"
else
    bad "missing ruleset blocks the commit (no silent fallback to defaults)"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
