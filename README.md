# multiplai-container

> Part of the **[Multiplai suite](https://github.com/spikelab/multiplai)** — what the suite is, how the five repos fit together, and which part you need.

A sandboxed Docker environment for running Claude Code with
`--dangerously-skip-permissions` safely — the container IS the sandbox.
Used by [multiplai-kit](https://github.com/spikelab/multiplai-kit), usable
standalone.

## Use via multiplai-kit (recommended)

The kit's `setup.sh` fetches this repo (pinned tag) into `container/` and
builds the image; `./claude.sh` then launches sessions inside it. Nothing to
do manually.

## Use standalone

```bash
git clone https://github.com/spikelab/multiplai-container
cd multiplai-container
cp .env.example .env          # then set WORKSPACE to your workspace path
./build.sh

# Persist Claude auth across runs by mounting ~/.claude (otherwise you
# re-authenticate every `docker run`).
docker run -it --rm \
  -v "$HOME/your-workspace:$HOME/your-workspace" \
  -v "$HOME/.claude:/home/agent/.claude" \
  -e WORKSPACE="$HOME/your-workspace" \
  claude-multiplai:local \
  claude --dangerously-skip-permissions
```

The image's default `CMD` is plain `claude` — the premise of this container
(container-as-sandbox) is running with `--dangerously-skip-permissions`, so
append it as shown above. The kit launcher (`./claude.sh`) supplies the flag
for you; standalone `docker run` does not.

The kit venv sync is skipped automatically in standalone mode (it only runs
when `CLAUDE_MULTIPLAI_HOME` points at a multiplai-kit checkout).

Building directly with `docker build` (rather than `./build.sh`) on Linux
should pass `--build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g)` —
the Dockerfile defaults (`501`/`20`) are macOS-centric and will mismatch the
owner of your mounted workspace, making bind-mounted files unwritable.
`./build.sh` derives these from your current ids automatically.

The image exports `MULTIPLAI_CONTAINER=1`; marketplace skills use it to
detect the container explicitly (instead of guessing from `uname`) and to
decide whether bridge instructions are appropriate in error messages.

### What works with / without the host bridge

Without the bridge (bare `docker run`, any host OS), everything that is
container-native works: the multiplai-context plugin, buildme, code/security
review, deep-research, the writing and pm packs, youtube-transcript's
subtitle path, excalidraw, slack/gmail (with your tokens). What does **not**
work without a macOS host bridge is exactly the Mac-only tooling:
**transcribe** and screen-demo's transcription step (mlx-whisper needs Apple
Silicon), **swift-build** (Xcode), and **host-browser** (`ab` → real Chrome).
Those skills detect the missing bridge and say so — see the marketplace
[compatibility matrix](https://github.com/spikelab/multiplai-cc-mktplace#compatibility-matrix)
for the per-skill table.

### macOS host bridge (optional)

The bridge lets container skills run Mac-only tools (Xcode builds,
mlx-whisper, driving Chrome via `ab`) over a key-restricted SSH gateway. It
also provides `multiplai-gh-token`, which mints a 1-hour **GitHub App
installation token** on the host so the App's private key never enters a
container — see [docs/gh-app-token.md](docs/gh-app-token.md) — and
`multiplai-docker`, which runs **pre-frozen Docker Compose stacks** on the host
as parallel named instances (`multiplai-docker up dolce --instance wt1`). The
container never authors a Docker argument or a compose file: you freeze each
stack once on the Mac with `multiplai-docker freeze`, and sessions may only name
a profile, a verb, an instance and a service — see
[docs/multiplai-docker.md](docs/multiplai-docker.md).

> **Security — enable only for containers you trust.** The gateway is an
> allowlist, but the tools it allows are powerful *by design*: `swift
> build/run/test` and `xcodebuild` execute build scripts and plugins from the
> project on the host, and `ab` drives the host's real Chrome, which can read
> any host file it can open. In other words, enabling the bridge grants the
> container the ability to **run host-side code and read host files** — not
> just "a locked-down SSH shell". Only enable it for containers running code
> you trust.

#### The host browser is off by default

`ab` / `agent-browser` is the one allowlisted tool that reaches your **real
logged-in Chrome** — every cookie, every signed-in app. Enabling the bridge does
not enable it. The gateway refuses the verb unless a flag file exists on the
Mac:

```bash
mkdir -p ~/.local/state/multiplai
touch ~/.local/state/multiplai/host-browser-enabled     # on
rm ~/.local/state/multiplai/host-browser-enabled        # off
```

The flag is a host file precisely because **nothing in the container can create
it** — there is no route from a session to the Mac's home directory, and the
gateway does not read `$XDG_STATE_HOME`, so the location cannot be steered from
the side being gated. A blocked run prints the path and both commands, so a
session that needs the browser tells you exactly what to type.

Turning it on grants the whole capability, not a slice of it: once enabled, the
container drives Chrome at large. The one thing still refused is a `file:` URL
on a navigation verb (`open`/`goto`/`navigate`), which would otherwise read any
host file Chrome can reach.

#### The bridge confines commands to a declared workspace

The gateway is a command allowlist, and separately a **filesystem boundary**.
It pins the working directory to a workspace you declare on the Mac, refuses a
`cd` prefix that leaves it, refuses absolute path arguments pointing outside it,
and runs the command under `sandbox-exec` with the shipped `confine.sb` profile
(writes denied by default, allowed back under the workspace plus the caches
builds need; reads and network stay open).

**The workspace has to be declared host-side** — a boundary supplied by the
container is not a boundary — and path-taking commands (`swift`, `xcodebuild`,
`xcrun`, `xcodegen`, `xcsift`, `mlx-whisper`, `qmd`) are **denied until it
exists**. `./setup.sh` from a multiplai-kit checkout writes it and installs the
profile for you; the manual block below does the same by hand.

`/` and your home directory are both refused as workspace values — either would
switch the boundary off. A subdirectory of `$HOME` is the normal case.

```bash
# On the Mac host:
ssh-keygen -t ed25519 -f ~/.ssh/build_key -N ''      # container's key
mkdir -p ~/.local/bin ~/.local/state/multiplai
cp container-build-gateway.sh ~/.local/bin/ && chmod +x ~/.local/bin/container-build-gateway.sh

# Declare the workspace the bridge may write in (one absolute path, first line):
echo /absolute/path/to/your/workspace > ~/.local/state/multiplai/workspace

# Install the sandbox profile the gateway names. It is DATA, not a tool, so it
# goes in ~/.local/state/multiplai — not on $PATH — beside the declaration
# above. Without it the argv-level checks still apply, but a build's child
# processes are no longer confined at all.
cp confine.sb ~/.local/state/multiplai/ && chmod 644 ~/.local/state/multiplai/confine.sb

# Prefix the PUBLIC key in ~/.ssh/authorized_keys with the forced command:
#   restrict,command="~/.local/bin/container-build-gateway.sh" ssh-ed25519 AAAA... container-builds
# (An absolute path — e.g. /Users/you/.local/bin/container-build-gateway.sh —
#  is more robust than "~", which sshd does not always expand in command=.)
# Enable System Settings ▸ General ▸ Sharing ▸ Remote Login.
```

If a bridge command ever fails with an unexplained sandbox denial, take the
profile out of the loop with
`mv ~/.local/state/multiplai/confine.sb{,.off}` — the gateway treats a missing
profile as "that layer is off" and keeps the rest — and please open an issue.

Then set `SSH_BUILD_USER` (your Mac username) and `SSH_BUILD_KEY`
(`$HOME/.ssh/build_key`) in `.env`, and mount the key into the container:
`-v "$HOME/.ssh/build_key:/home/agent/.ssh/build_key:ro"`.

## What's in the image

- Ubuntu 24.04, non-root `agent` user mapped to your host UID/GID
- Claude Code CLI (Node.js 22), `uv` + Python, git, `gh`, ripgrep, jq
- Google Cloud SDK + Cloud SQL Auth Proxy v2 (for GCP workflows)
- SSH config for the **macOS host bridge** — skills inside the container can
  run tools that only work on the Mac (Xcode builds, mlx-whisper
  transcription, driving the real Chrome via `ab`) through a key-restricted
  SSH gateway

## Files

| File | Purpose |
|------|---------|
| `CHANGELOG.md` | What each tag changed, for consumers deciding whether to advance `CONTAINER_REF` |
| `CLAUDE.md` | Repo guide for agents — the release contract and the gateway's security invariant |
| `Dockerfile` | Image definition. Build args: `HOST_UID`, `HOST_GID`, `WORKSPACE`, `SSH_BUILD_USER` |
| `LICENSE` | MIT |
| `README.md` | This file |
| `SECURITY.md` | Threat model of the optional host bridge, supported versions, how to report |
| `VERSION` | Last released version; `release.sh` bumps it and tags `v<VERSION>` |
| `ab` | Drive Vercel `agent-browser` against the host's real Chrome over the SSH bridge |
| `apple-containers-experiment.sh` | Experimental: Apple `container` runtime instead of Docker |
| `build.sh` | Builds the image from `.env` config (kit root `.env`, or one next to this script) |
| `confine.sb` | `sandbox-exec` profile the gateway wraps path-taking commands in — installs to `~/.local/state/multiplai/confine.sb` (data, not a tool), takes the workspace as a `-D` parameter |
| `container-build-gateway.sh` | Host-side SSH forced-command gateway — allowlists what the container key may run on the Mac, and confines it to the declared workspace |
| `md2pdf` | Markdown→PDF wrapper baked into the image (`pandoc --pdf-engine=typst`) |
| `multiplai-docker.py` | Host-side runner for pre-frozen Docker Compose stacks — parallel named instances over the bridge, agent input never reaches Compose (setup: [docs/multiplai-docker.md](docs/multiplai-docker.md)) |
| `docs/multiplai-docker.md` | Host setup for `multiplai-docker`: freezing a profile, the verb list, worktree instances, threat model |
| `multiplai-gh-token` | Host-side minter for GitHub App installation tokens — the App key stays on the Mac, the container gets a 1-hour token over the bridge (setup: [docs/gh-app-token.md](docs/gh-app-token.md)) |
| `docs/gh-app-token.md` | Host setup for `multiplai-gh-token`: per-app credential layout, threat model, transcript hygiene, migration |
| `release.sh` | Maintainer release tool — build- and changelog-gated tag + kit pin bump (see [CLAUDE.md](CLAUDE.md)) |
| `tests/gateway-test.sh` | ALLOW/DENY harness exercising the gateway's forced-command allowlist |
| `tests/multiplai-docker-test.sh` | Stub-docker harness asserting the argv `multiplai-docker` hands Compose (no daemon needed) |
| `venv-sync-entrypoint.sh` | Entrypoint — syncs the Linux venv, then execs `claude` (or bash) |

**Releasing (maintainers):** this repo is consumed at an immutable tag, not `main` — the full release flow (`release.sh`, its build and changelog gates, the kit `CONTAINER_REF` pin bump, `--kit` semantics) is documented in [CLAUDE.md](CLAUDE.md).

## License

MIT — see [LICENSE](LICENSE).
