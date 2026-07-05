# multiplai-container

A sandboxed Docker environment for running Claude Code with
`--dangerously-skip-permissions` safely — the container IS the sandbox.
Part of the [Multiplai](https://github.com/spikelab/multiplai-kit) suite,
usable standalone.

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
| `Dockerfile` | Image definition. Build args: `HOST_UID`, `HOST_GID`, `WORKSPACE`, `SSH_BUILD_USER` |
| `build.sh` | Builds the image from `.env` config (kit root `.env`, or one next to this script) |
| `venv-sync-entrypoint.sh` | Entrypoint — syncs the Linux venv, then execs `claude` (or bash) |
| `ab` | Drive Vercel `agent-browser` against the host's real Chrome over the SSH bridge |
| `container-build-gateway.sh` | Host-side SSH forced-command gateway — allowlists what the container key may run on the Mac |
| `apple-containers-experiment.sh` | Experimental: Apple `container` runtime instead of Docker |

## Use via multiplai-kit (recommended)

The kit's `setup.sh` fetches this repo (pinned tag) into `container/` and
builds the image; `./claude.sh` then launches sessions inside it. Nothing to
do manually.

## Use standalone

```bash
git clone https://github.com/spikelab/multiplai-container
cd multiplai-container
cat > .env <<'ENV'
WORKSPACE="$HOME/your-workspace"
ENV
./build.sh
docker run -it --rm \
  -v "$HOME/your-workspace:$HOME/your-workspace" \
  -e WORKSPACE="$HOME/your-workspace" \
  claude-multiplai:local
```

For the macOS host bridge, install `container-build-gateway.sh` on the Mac
(instructions in the file header) and set `SSH_BUILD_USER`/`SSH_BUILD_KEY`
in `.env`.

## License

MIT — see [LICENSE](LICENSE).
