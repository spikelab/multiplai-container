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
