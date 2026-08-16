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
`docker build` to pass** (you cannot tag a broken image) and **requires notes
under `## [Unreleased]` in `CHANGELOG.md`** (you cannot tag an undescribed
change — there is deliberately no `--skip-changelog`), tags + pushes, then
**bumps `CONTAINER_REF` in the kit and pushes that too** — closing the
two-repo seam by hand is what used to break. The release commit carries the
changelog section, renamed to the new version and dated. Consumers then get it
via `git pull && ./setup.sh`, which re-pins `container/`, rebuilds the image,
and reinstalls the host gateway.

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

**It enforces two independent controls, and a new branch must answer for both.**
The command allowlist says *what may run*; the workspace jail says *where it may
write*. Adding a `case` arm without thinking about the second one is the bug
mktplace#15 reported — the allowlist was complete and the boundary did not
exist.

Every branch therefore sets two flags, both deny-by-default:

- `NEEDS_WS` — the command takes or writes paths, so it must not run without a
  declared workspace. **Leave it at 1 unless the branch can state why no path
  is expressible**, and put that reason in the code. "Probably doesn't write
  anything" is not a reason; "every word is validated against a label charset
  above" is. The five branches that clear it (`command -v`, `pkill`, `open -a`,
  `multiplai-gh-token`, `multiplai-docker`, `curl`) each carry theirs.
- `SANDBOX` — additionally wrap in `sandbox-exec` with `confine.sb`.

**Host-owned state is the trust model, and `$XDG_STATE_HOME` is deliberately not
read.** The workspace declaration (`~/.local/state/multiplai/workspace`), the
host-browser flag, and the profile all live in one directory the container has
no route to write. A value arriving from the container is not a boundary, and
neither is a path the remote side could steer — sshd can be configured to accept
client environment variables.

**`confine.sb` and this script are one release.** The gateway names the profile;
the kit's `install_host_state` ships it beside the gateway's `install_host_tool`
for that reason. Never let them travel separately.

**What the harness can and cannot tell you.** `tests/gateway-test.sh` covers the
whole decision — 104 cases including the workspace jail — and runs on Linux
against a static zsh (`GATEWAY_TEST_ZSH=…`). It cannot tell you whether
`sandbox-exec` accepts the profile or whether a given tool still works under it:
that is macOS-only, and it is a host smoke test, once, per tool.

## Editing `multiplai-docker.py`

It lets a container run Compose stacks on the host, so its safety rests on one
property: **agent input never reaches Compose.** The compose configuration is
frozen host-side by `freeze` (the trust step, deliberately absent from the
gateway allowlist); at run time the container supplies only labels — a profile
name, a verb from the fixed list, an instance name, a service name, a numeric
tail, guarded guest argv. Invariants to preserve:

- **Exactly one runtime transform of the frozen file** — the worktree bind
  rewrite. Anything else (injecting labels, merging overrides, "just one flag")
  reopens the hole and breaks the `up` argv assertion in the harness.
- **Never fall back to the workspace compose files.** They are read only to hash
  them for the drift warning, which warns and proceeds — it must never fail, and
  must never make the tool read the unfrozen copy.
- **`down` always passes `-v`**, and the project is always
  `<PROJECT_PREFIX>-<instance>`. Instances are ephemeral; per-instance named
  volumes depend on that project name — **and on `freeze` stripping the
  resolved `name:` that `compose config` bakes into top-level volumes and
  networks.** Leave those in and every instance shares one database and one
  network while every argv assertion still passes; that is exactly how it
  shipped in v0.9. Keep `external: true` names, which the stack does not own.
  The stub fixture carries resolved names precisely so this cannot regress.
- **`up` waits (`--wait`), and that is load-bearing.** A returning `up` must mean
  a usable stack: containers are `running` in seconds, migrations take minutes,
  and a session that `exec`s into that gap misreads a half-migrated schema as a
  data bug. Keep the wait bounded — Compose's default is forever.
- Widening the verb list means widening the gateway branch too — the two are one
  contract, and `tests/multiplai-docker-test.sh` plus `tests/gateway-test.sh`
  cover the two halves. Both mutate-check cleanly; keep it that way.

Full design and host setup: [docs/multiplai-docker.md](docs/multiplai-docker.md).

## Editing the secret gate (`git-hooks/`)

The image installs `git-hooks/dispatch` as *every* git hook via
`core.hooksPath` in `/etc/gitconfig`, so it applies to every repo touched
inside the container. Invariants to preserve:

- **Never resolve the repo's own hooks with `git rev-parse --git-path hooks`.**
  That honours `core.hooksPath` and returns the dispatcher's own directory —
  the hook would exec itself forever. And never `--git-dir` either: a linked
  worktree's git dir (`.git/worktrees/<name>`) has no `hooks/`, so repo-local
  hooks silently stop running from worktrees. The one correct resolver is
  `git rev-parse --path-format=absolute --git-common-dir` + `/hooks` — the
  same call `check-hookspath` uses; keep the two in lockstep.
- **Keep chaining to `.git/hooks/<name>`.** `core.hooksPath` *replaces*
  `.git/hooks`; it is not additive. Any hook name missing from the symlink loop
  in the Dockerfile is a repo-local hook silently disabled — which is why
  `check-hookspath` reads the covered set from the dispatcher symlinks at
  runtime and warns about repo-local hooks outside it. Add a name to the
  Dockerfile loop and the check follows automatically; hardcode the list
  anywhere else and you have reintroduced the drift it exists to catch.
- **Never hand gitleaks a range you haven't proven walkable.** gitleaks exits
  0 when its underlying `git log` fails, so an invalid revision range scans
  nothing and passes — the dispatcher `git rev-list`-validates every pre-push
  range and fails closed on an unwalkable one. Keep that ordering.
- **The gate is system-level, and local config outranks it.** A repo-local
  `core.hooksPath` (husky/lefthook installs) bypasses the gate for that repo;
  that cannot be prevented from `/etc/gitconfig`. The compensating control is
  `git-hooks/check-hookspath`, which the entrypoint runs to warn (never
  block). Don't claim the gate is unbypassable in docs. Note that a repo
  pointing `core.hooksPath` at its *own* `.git/hooks` — a no-op that looks
  harmless — un-gates it just as completely; unset it and let the dispatcher
  chain there instead.
- **Never chain to a repo hook through a pipe.** Under `pipefail` a hook that
  exits without draining stdin makes the writer take SIGPIPE past the 64K pipe
  buffer, and `exit $?` turns that into a push rejected with no message. Use a
  here-string.

When bumping `GITLEAKS_VERSION`, also update `GITLEAKS_SHA256_X64` /
`GITLEAKS_SHA256_ARM64` from upstream's `gitleaks_<ver>_checksums.txt` release
asset — the build and CI both verify the tarball against them.

`git-hooks/gitleaks.toml` is gitleaks' default ruleset plus what it
demonstrably misses — chiefly the `sk-ant-*` family (Anthropic API keys, Claude
OAuth access/refresh tokens), which upstream gitleaks **does not detect in any
form**. That matters here specifically because the kit mounts the host's
`~/.claude/.credentials.json` into every session. Before trimming a rule, run
`tests/git-hooks-test.sh` — the `sk-ant-*` case is the canary for the whole
custom-config path. When bumping `GITLEAKS_VERSION`, re-run that harness (CI
reads the version straight out of the Dockerfile, so the two cannot drift).

## Standalone use

The repo works without the kit (`cp .env.example .env`, `./build.sh`). See
`README.md`.
