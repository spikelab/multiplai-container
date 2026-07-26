# multiplai-container

> Part of the **[Multiplai suite](https://github.com/spikelab/multiplai)** — what the suite is, how the five repos fit together, and which part you need.

A sandboxed Docker environment for running Claude Code with
`--dangerously-skip-permissions` safely — the container IS the sandbox.
Used by [multiplai-kit](https://github.com/spikelab/multiplai-kit), usable
standalone.

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
| `container-build-gateway.sh` | Host-side SSH forced-command gateway — allowlists what the container key may run on the Mac |
| `md2pdf` | Markdown→PDF wrapper baked into the image (`pandoc --pdf-engine=typst`) |
| `release.sh` | Maintainer release tool — build- and changelog-gated tag + kit pin bump (see [Releasing](#releasing-maintainers)) |
| `tests/gateway-test.sh` | ALLOW/DENY harness exercising the gateway's forced-command allowlist |
| `venv-sync-entrypoint.sh` | Entrypoint — syncs the Linux venv, then execs `claude` (or bash) |

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
mlx-whisper, driving Chrome via `ab`) over a key-restricted SSH gateway.

> **Security — enable only for containers you trust.** The gateway is an
> allowlist, but the tools it allows are powerful *by design*: `swift
> build/run/test` and `xcodebuild` execute build scripts and plugins from the
> project on the host, and `ab` drives the host's real Chrome, which can read
> any host file it can open. In other words, enabling the bridge grants the
> container the ability to **run host-side code and read host files** — not
> just "a locked-down SSH shell". Only enable it for containers running code
> you trust.

```bash
# On the Mac host:
ssh-keygen -t ed25519 -f ~/.ssh/build_key -N ''      # container's key
mkdir -p ~/.local/bin
cp container-build-gateway.sh ~/.local/bin/ && chmod +x ~/.local/bin/container-build-gateway.sh
# Prefix the PUBLIC key in ~/.ssh/authorized_keys with the forced command:
#   restrict,command="~/.local/bin/container-build-gateway.sh" ssh-ed25519 AAAA... container-builds
# (An absolute path — e.g. /Users/you/.local/bin/container-build-gateway.sh —
#  is more robust than "~", which sshd does not always expand in command=.)
# Enable System Settings ▸ General ▸ Sharing ▸ Remote Login.
```

Then set `SSH_BUILD_USER` (your Mac username) and `SSH_BUILD_KEY`
(`$HOME/.ssh/build_key`) in `.env`, and mount the key into the container:
`-v "$HOME/.ssh/build_key:/home/agent/.ssh/build_key:ro"`.

## Releasing (maintainers)

**This repo is consumed at an immutable tag, not `main`.** The kit
(`multiplai-kit/setup.sh`) pins it via `CONTAINER_REF` and fetches that tag
into its `container/` checkout. So **merging a fix to `main` delivers nothing**
on its own — a change reaches consumers only when a new tag is cut *and* the
kit's pin is bumped to it.

Do both in one gated step with `release.sh`:

```bash
./release.sh minor            # 0.4 → 0.5, tag v0.5
./release.sh patch            # 0.4 → 0.4.1
./release.sh 0.5              # explicit version
./release.sh minor --dry-run  # preview; no writes
```

It refuses unless `main` is clean and in sync with `origin`, **requires
`docker build` to pass** (you can't tag a broken image) and **requires notes
under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md)** (you can't tag an
undescribed change — there is no `--skip-changelog`), then tags + pushes and
**bumps `CONTAINER_REF` in the kit and pushes that too**. The release commit
carries the changelog section, renamed to the new version and dated. Consumers
pick it up
with `git pull && ./setup.sh`, which re-pins `container/`, rebuilds the image,
and reinstalls the host gateway.

Rules of the road:

- **Never hand-edit the kit's `container/` checkout.** It's a pinned,
  detached-HEAD checkout `setup.sh` re-aligns to the tag; edits there are
  transient (silently reverted next setup) and invisible to others.
- **Tags are immutable** — cut a new one; never move an existing tag. Keep old
  tags as rollback points (pin `CONTAINER_REF=v0.4` to roll back).
- Releasing against a fork or from another checkout: `--kit <path>` /
  `$MULTIPLAI_KIT` selects the kit to bump; `--no-kit` tags only.

## License

MIT — see [LICENSE](LICENSE).
