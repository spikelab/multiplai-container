# Security Policy

`multiplai-container` ships two things with security consequence: a Docker
image meant to be run with `claude --dangerously-skip-permissions` (the
container *is* the sandbox), and `container-build-gateway.sh` — a **host-side
SSH forced command** that the README instructs you to install into your Mac's
`~/.ssh/authorized_keys`. This file states what enabling that costs you, what
gets fixed, and how to report a problem.

## Threat model

### The container is the boundary, not the flag

The premise is that Claude Code runs unattended inside a container, so a bad
tool call damages a container instead of your machine. Everything you bind-mount
is inside the blast radius: the workspace is writable, and mounted credentials
(`~/.claude`, `gh` auth, cloud SDK config) are usable by anything running in
there. Mount only what the session needs.

### Enabling the macOS host bridge grants host code execution

The bridge (see [README ▸ macOS host bridge](README.md#macos-host-bridge-optional))
is optional and **off unless you install the forced-command key yourself**. The
gateway is a strict allowlist, but the tools it allows are powerful *by design*:

- `swift build` / `swift run` / `swift test` / `xcodebuild` **execute
  project-supplied build scripts, plugins and test code on the host**. Building
  an untrusted checkout over the bridge is running its code on your Mac.
- `ab` drives **the host's real, logged-in Chrome**. Anything that browser can
  reach or read — sessions, cookies, local files it can open — is reachable
  through it. (Navigation to `file:` URLs is blocked, and `curl` is restricted
  to http/https on loopback with a flag allowlist, precisely because these are
  the exfiltration paths. Treat those as hardening, not as a boundary.)

So: **enabling the bridge grants the container the ability to run host-side code
and read host files** — it is not "a locked-down SSH shell". Enable it only for
containers running code you trust, and use a dedicated key
(`restrict,command="…"` plus the forced command, as the README shows). Removing
the key from `authorized_keys` revokes it completely.

## The invariant contributors must preserve

Quoting [`CLAUDE.md`](CLAUDE.md) on `container-build-gateway.sh`:

> It never re-parses untrusted input as a shell string; it receives
> already-tokenized argv and allowlists by command. When widening the
> allowlist, preserve that invariant (strip only known-safe literal wrappers,
> exec user argv as data).

Concretely: unescaped shell metacharacters and raw newlines are denied, the
command is tokenized honouring quotes only (no expansion), `argv[0]` and the
subcommand are validated against the allowlist, an optional `cd DIR &&` prefix
is handled by the gateway itself, and the resulting argv array is exec'd as
data. A change that reintroduces string-level shell evaluation of client input
reintroduces the v0.2 RCE (see [CHANGELOG.md](CHANGELOG.md), `[0.2]`), whatever
else it fixes.

`tests/gateway-test.sh` is an ALLOW/DENY harness that runs the gateway the way
`sshd` does. Any allowlist change must add cases to it, and it must pass.

## Supported versions

This repo is consumed **only at an immutable tag**: `multiplai-kit/setup.sh`
pins `CONTAINER_REF` and fetches a shallow single-tag checkout.

- **Only the latest tag is supported.** Older tags exist as rollback points and
  receive no fixes.
- **Fixes ship as a new tag, never by moving an existing one.** A tag you have
  fetched will never change under you; upgrading is advancing `CONTAINER_REF`
  (`git pull && ./setup.sh` for kit users) after reading
  [CHANGELOG.md](CHANGELOG.md).
- `main` is the releasable line but is not what anyone runs — a merged fix
  delivers nothing until a tag is cut.

## Reporting a vulnerability

Email **security@spikelab.org** with the version/tag, your host OS, and the
smallest reproduction you have. Please do **not** open a public issue for
anything that lets container-side input reach host execution.

Expect an acknowledgement within a few days. This is a small personal project,
not a funded program: there is no bounty, and the remedy for a confirmed issue
is a fix plus a new tag, described in the changelog under `Security`.
