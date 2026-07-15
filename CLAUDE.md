# multiplai-container — repo guide

Host-side container tooling for the Multiplai kit: the Docker image the agent
runs in (`Dockerfile`), the host SSH forced-command gateway
(`container-build-gateway.sh`), the image build (`build.sh`), and helpers
(`ab`, `md2pdf`, `venv-sync-entrypoint.sh`).

## The release contract — READ THIS BEFORE "just merging a fix"

**This repo is consumed at an immutable git TAG, not `main`.** The runtime
(`multiplai-kit`) pins it via `CONTAINER_REF` in its `setup.sh` and fetches a
shallow, single-tag checkout into `~/.multiplai-runtimes/<inst>/container/`.

Consequences you must respect:

- **Merging to `main` delivers nothing.** A change reaches consumers only when
  a new tag is cut *and* the kit's `CONTAINER_REF` is bumped to it. `main` is
  the releasable line; **tags are the unit of delivery.**
- **Never hand-edit the kit's `container/` checkout.** It's a pinned,
  detached-HEAD checkout that `setup.sh` re-aligns to `CONTAINER_REF`. Any edit
  there is transient — the next `setup.sh` silently reverts it — and invisible
  to everyone else. (This is exactly how a fix got stranded once.)
- **Tags are immutable.** Cut a new one; never move an existing tag.

## How to release — `./release.sh`

One command does the whole chain — all local work first, then both pushes
last, back-to-back (so the only failure window is a single push):

```
./release.sh minor        # 0.4 → 0.5, tag v0.5
./release.sh patch        # 0.4 → 0.4.1
./release.sh 0.5          # explicit
./release.sh minor --dry-run   # preview, no writes
```

It refuses unless `main` is clean and in sync with origin, **requires
`docker build` to pass** (you cannot tag a broken image), tags + pushes, then
**bumps `CONTAINER_REF` in the kit and pushes that too** — closing the
two-repo seam by hand is what used to break. Consumers then get it via
`git pull && ./setup.sh`.

- Keep occasional tags as **rollback points**, not a burden — pin
  `CONTAINER_REF=v0.4` to roll back.
- Cutting a tag on a fork/other machine? `--kit <path>` or `$MULTIPLAI_KIT`
  tells `release.sh` which kit to bump; `--no-kit` tags only.

## Editing the gateway (`container-build-gateway.sh`)

It's the highest-value security boundary here — a host-side SSH forced command
that allowlists what the container key may run on the Mac. It never re-parses
untrusted input as a shell string; it receives already-tokenized argv and
allowlists by command. When widening the allowlist, preserve that invariant
(strip only known-safe literal wrappers, exec user argv as data). Ship changes
through `release.sh` like everything else.

## Standalone use

The repo works without the kit (`cp .env.example .env`, `./build.sh`). See
`README.md`.
