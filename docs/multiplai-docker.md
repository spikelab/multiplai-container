# `multiplai-docker` — host setup

A Claude session container can start, inspect and tear down **parallel named
instances** of an allowlisted set of Docker Compose stacks on the Mac,
mid-session, over the existing SSH bridge — without ever authoring a Docker
argument or a compose file.

```
ssh host.docker.internal multiplai-docker up   dolce --instance wt1
ssh host.docker.internal multiplai-docker ls   dolce
ssh host.docker.internal multiplai-docker ps   dolce --instance wt1
ssh host.docker.internal multiplai-docker logs dolce engine 200 --instance wt1
ssh host.docker.internal multiplai-docker exec dolce engine --instance wt1 -- python manage.py showmigrations
ssh host.docker.internal multiplai-docker down dolce --instance wt1
```

## How it is safe — by construction, not by validation

A **profile** is a compose configuration *you* resolved and froze on the Mac,
stored in `~/.local/share/multiplai/docker-profiles/` — outside every container
mount. At run time the host script feeds Compose that frozen file and nothing
else. The container supplies only **labels**:

| Input | Constraint |
|---|---|
| verb | one of `up down ps ls logs restart build exec reap-older-than` |
| profile | `^[a-z0-9][a-z0-9_-]{0,31}$`, must name an existing profile |
| instance | `^[a-z0-9][a-z0-9-]{0,15}$`, default `main` |
| service | must appear in the profile's `SERVICES` |
| log tail | digits, capped at 2000 |
| guest argv (`exec` only) | non-empty, no leading `-`, each word `^[A-Za-z0-9._:=/@,-]+$` |

Because agent input never reaches Compose, there is **no runtime validator to
bypass and no TOCTOU window**. There is no way to ask for an arbitrary bind, a
`privileged` container, the Docker socket, or host networking — those properties
are fixed in the frozen file you reviewed.

`freeze` is the one place trust is established, and it is a **host-terminal**
act: the SSH gateway does not allowlist it (bridge callers are denied before the
script runs), and the script additionally refuses when it can see it was invoked
over SSH.

## Freezing a profile

```bash
multiplai-docker freeze dolce \
  -f ~/Documents/knowhere/PROJECTS/DolceBot/DolceEngine/docker-compose.yml \
  -f ~/Documents/knowhere/PROJECTS/DolceBot/DolceEngine/docker-compose.dev.yml
```

This runs `docker compose -f … config --format json` and applies exactly two
deterministic transforms:

1. **strips every service's `ports:`** — parallel instances must not publish host
   ports, and stripping them is what makes three simultaneous stacks possible.
   Reach services by their OrbStack hostnames instead.
2. **stamps `multiplai.profile=<name>`** on every service, so `ls` and
   `reap-older-than` can find what this tool owns.

It writes two mode-600 files:

```
~/.local/share/multiplai/docker-profiles/dolce.json     the frozen compose config
~/.local/share/multiplai/docker-profiles/dolce.conf     KEY=VALUE, never eval'd
```

**Review `dolce.json` once, now.** That is the trust step — everything a session
can subsequently start is in that file.

The `.conf` records:

```
FROZEN=…/dolce.json
PROJECT_DIR=…/DolceEngine          # always passed as --project-directory
PROJECT_PREFIX=dolce               # compose project is <prefix>-<instance>
SERVICES=celery celery-beat engine front mysql redis
SOURCE_FILES=…yml:…dev.yml         # hashed for the drift warning only
SOURCE_SHA256=…
BIND_ROOT=…/DolceEngine            # binds under here follow the worktree
WORKTREE_ROOT=…/knowhere/.worktrees
```

`PROJECT_DIR`/`BIND_ROOT` default to the first `-f` file's directory;
`WORKTREE_ROOT` to the nearest ancestor holding a `.worktrees/` directory;
`PROJECT_PREFIX` to the profile name. Override any of them with
`--project-dir`, `--bind-root`, `--worktree-root`, `--prefix`.

Re-run `freeze` whenever the workspace compose files change. Sessions cannot:
when the recorded hash no longer matches, `up`/`build` print a **stderr warning**
("profile … is stale — re-freeze on the Mac") and proceed against the frozen
file. Drift never fails and never causes a fallback to the workspace copy.

## Instances, worktrees and cleanup

The compose project is always `<PROJECT_PREFIX>-<instance>`, so named volumes are
per-instance too. Instances are therefore **ephemeral by design** and `down`
always runs `down -v`.

If a directory named after the instance exists under `WORKTREE_ROOT`, the tool
applies its **one runtime transform**: every `type: bind` volume whose source
sits under `BIND_ROOT` is re-prefixed into that worktree, and the result is
written to a mode-600 temp file passed as `-f`. Named volumes are never touched;
a rewritten source that does not exist is a clean failure. So three agents in
three worktrees can run

```
multiplai-docker up dolce --instance wt1     # binds …/.worktrees/wt1/…
multiplai-docker up dolce --instance wt2
multiplai-docker up dolce --instance wt3
```

and get three isolated stacks, each running its own worktree's code.

Cleanup is unceremonious: agents `down` what they `up`, `ls` shows what is live,
and `multiplai-docker reap-older-than 12` tears down (with `-v`) any labelled
instance whose containers are all older than the threshold. There is no
session-lifetime coupling and no `claude.sh` involvement.

**Instance identity, deliberately.** Only one runtime transform of the frozen
file is allowed, so the per-instance label cannot be injected at run time.
`freeze` bakes `multiplai.profile` onto every service, and the instance travels
in the compose project name — which Compose itself stamps on every container as
`com.docker.compose.project`. `ls` and `reap-older-than` read that pair back.
Instance naming is **not** a security boundary: every session runs at the same
trust level, and the properties that matter are guaranteed by the frozen file.

## Install

`multiplai-kit/setup.sh` installs `multiplai-docker.py` into `~/.local/bin/` from
the pinned container checkout, alongside `container-build-gateway.sh` and
`multiplai-gh-token` — one gated loop, because the host script and the gateway
branch that allowlists it are two halves of one contract and must never ship
from different generations. No `authorized_keys` change is needed.

The container types the verb `multiplai-docker`; the gateway rewrites argv[0] to
the absolute path `$HOME/.local/bin/multiplai-docker.py` (`~/.local/bin` is not
on the gateway's login `PATH`), exactly as it does for `multiplai-gh-token`.

## Testing

`tests/multiplai-docker-test.sh` runs with a **stub `docker`** first on `PATH`
and asserts the argv the tool builds — no daemon, no network, so it runs in CI
and inside a session container. Docker itself cannot be exercised from a session
container (no daemon, no socket, and the bridge does not allowlist `docker`), so
a real stack launch is always the host owner's acceptance step.
