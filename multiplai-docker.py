#!/usr/bin/env python3
"""multiplai-docker — run allowlisted Docker Compose stacks on the macOS host.

A Claude session container reaches this script through the SSH gateway
(`container-build-gateway.sh`) and can start, inspect and tear down **named
parallel instances** of stacks the host owner froze in advance. The agent never
authors a Docker argument or a compose file: it supplies a profile name, a verb
from a fixed list, an instance name, a service name, a numeric tail and (for
`exec`) guarded guest argv. Nothing else, ever.

The trust step is `freeze`, run by the host owner in a terminal — never over the
bridge (the gateway does not allowlist it, and this script also refuses it when
it can see it was invoked over SSH). `freeze` resolves the workspace's compose
files once with `docker compose config --format json`, strips every published
port, stamps a `multiplai.profile` label on every service, and writes the result
outside every container mount. Because the compose input is frozen host-side,
there is no runtime validator to bypass and no TOCTOU window.

  ~/.local/share/multiplai/docker-profiles/     (mode 700)
    <name>.conf                                 KEY=VALUE, never eval'd (mode 600)
    <name>.json                                 the frozen compose config (mode 600)

Usage (the verbs reachable over the bridge):

  multiplai-docker up      <profile> [--instance <i>]
  multiplai-docker down    <profile> [--instance <i>]      # always `down -v`
  multiplai-docker ps      <profile> [--instance <i>]
  multiplai-docker ls      [<profile>]
  multiplai-docker logs    <profile> <service> [<n>] [--instance <i>]
  multiplai-docker restart <profile> <service> [--instance <i>]
  multiplai-docker build   <profile> <service> [--instance <i>]
  multiplai-docker exec    <profile> <service> [--instance <i>] -- <argv…>
  multiplai-docker reap-older-than <hours>

Host-terminal only:

  multiplai-docker freeze  <name> -f <compose> [-f <compose>…]
                           [--project-dir D] [--prefix P]
                           [--bind-root R] [--worktree-root W]

Instances are ephemeral by construction: the compose project is always
`<PROJECT_PREFIX>-<instance>`, so named volumes are per-instance too, and `down`
always passes `-v`. Agents `down` what they `up`; `reap-older-than` catches
leaks; `ls` shows what is live in the meantime.

Instance identity — a deliberate design note. The design allows exactly ONE
runtime transform of the frozen file (the worktree bind rewrite below), so the
per-instance label cannot be injected at run time. Instead `freeze` bakes
`multiplai.profile=<name>` onto every service, and the instance travels in the
compose project name, which Compose itself stamps on every container as
`com.docker.compose.project`. `ls` and `reap-older-than` read that pair back.
Same information, no extra transform, and `up` runs against the frozen file
byte-for-byte whenever no worktree is involved.

Exit codes: 0 ok · 1 usage/config error · 2 docker error
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

PROFILE_DIR = os.path.join(
    os.path.expanduser("~"), ".local", "share", "multiplai", "docker-profiles"
)

PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
INSTANCE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,15}$")
SERVICE_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
GUEST_ARG_RE = re.compile(r"^[A-Za-z0-9._:=/@,-]+$")

# Verbs the gateway may forward. `freeze` is deliberately absent.
BRIDGE_VERBS = (
    "up",
    "down",
    "ps",
    "ls",
    "logs",
    "restart",
    "build",
    "exec",
    "reap-older-than",
)
ALL_VERBS = BRIDGE_VERBS + ("freeze",)

CONF_KEYS_REQUIRED = ("FROZEN", "PROJECT_DIR", "PROJECT_PREFIX", "SERVICES")
CONF_KEYS_OPTIONAL = ("SOURCE_FILES", "SOURCE_SHA256", "BIND_ROOT", "WORKTREE_ROOT")

DEFAULT_TAIL = 200
MAX_TAIL = 2000

# `up` waits for healthchecks: "the command returned" must mean "the stack is
# usable". Containers reach `running` in seconds while an entrypoint that runs
# database migrations needs minutes, and an agent that execs into that gap gets
# errors from a half-migrated schema and misreads them as data bugs (seen
# 2026-08-06: loaddata hit `last_login cannot be null` because
# auth.0005_alter_user_last_login_null had not been applied yet).
# Bounded, because Compose's own default is to wait forever.
WAIT_TIMEOUT = 600


class Fail(Exception):
    """A usage/config error: message to stderr, exit 1."""

    def __init__(self, msg: str, code: int = 1):
        super().__init__(msg)
        self.code = code


def warn(msg: str) -> None:
    print("multiplai-docker: %s" % msg, file=sys.stderr)


# --------------------------------------------------------------------------
# profile loading — everything here runs on host-owned data only
# --------------------------------------------------------------------------


def _check_file_trust(path: str, what: str) -> None:
    """Refuse a profile file that someone other than the caller could rewrite."""
    try:
        st = os.lstat(path)
    except OSError as exc:
        raise Fail("%s: %s" % (what, exc))
    if stat.S_ISLNK(st.st_mode):
        raise Fail("%s is a symlink: %s" % (what, path))
    if not stat.S_ISREG(st.st_mode):
        raise Fail("%s is not a regular file: %s" % (what, path))
    if st.st_uid != os.getuid():
        raise Fail("%s is not owned by you: %s" % (what, path))
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise Fail("%s is group/world-writable: %s" % (what, path))


def _profile_path(name: str, suffix: str) -> str:
    """Resolve <name><suffix> inside PROFILE_DIR, refusing any escape."""
    if not PROFILE_RE.match(name):
        raise Fail("invalid profile name: %s" % name)
    path = os.path.join(PROFILE_DIR, name + suffix)
    parent = os.path.realpath(os.path.dirname(os.path.realpath(path)))
    if parent != os.path.realpath(PROFILE_DIR):
        raise Fail("profile path escapes the profile directory: %s" % path)
    return path


def load_profile(name: str) -> dict:
    path = _profile_path(name, ".conf")
    if not os.path.exists(path):
        raise Fail("no such profile: %s (expected %s)" % (name, path))
    _check_file_trust(path, "profile")

    conf: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise Fail("%s:%d: not KEY=VALUE: %s" % (path, lineno, line))
            key, _, value = line.partition("=")
            key = key.strip()
            if key not in CONF_KEYS_REQUIRED and key not in CONF_KEYS_OPTIONAL:
                raise Fail("%s:%d: unknown key: %s" % (path, lineno, key))
            if key in conf:
                raise Fail("%s:%d: duplicate key: %s" % (path, lineno, key))
            conf[key] = value.strip()

    for key in CONF_KEYS_REQUIRED:
        if not conf.get(key):
            raise Fail("%s: missing required key: %s" % (path, key))
    if not PROFILE_RE.match(conf["PROJECT_PREFIX"]):
        raise Fail("%s: invalid PROJECT_PREFIX: %s" % (path, conf["PROJECT_PREFIX"]))
    for svc in conf["SERVICES"].split():
        if not SERVICE_RE.match(svc):
            raise Fail("%s: invalid service name: %s" % (path, svc))
    if not os.path.isdir(conf["PROJECT_DIR"]):
        raise Fail("%s: PROJECT_DIR does not exist: %s" % (path, conf["PROJECT_DIR"]))
    _check_file_trust(conf["FROZEN"], "frozen compose file")

    conf["_name"] = name
    return conf


def check_drift(conf: dict) -> None:
    """Warn (never fail) when the workspace compose files moved since freeze."""
    files = [p for p in conf.get("SOURCE_FILES", "").split(":") if p]
    recorded = conf.get("SOURCE_SHA256", "")
    if not files or not recorded:
        return
    if source_digest(files) != recorded:
        warn(
            "profile '%s' is stale — workspace compose files changed since freeze; "
            "re-freeze on the Mac" % conf["_name"]
        )


def source_digest(paths: list[str]) -> str:
    """Hash the compose sources. Only ever used for the drift warning."""
    h = hashlib.sha256()
    for path in paths:
        h.update(path.encode("utf-8"))
        h.update(b"\0")
        try:
            with open(path, "rb") as fh:
                h.update(fh.read())
        except OSError:
            h.update(b"<missing>")
        h.update(b"\0")
    return h.hexdigest()


# --------------------------------------------------------------------------
# the one runtime transform: worktree bind rewrite
# --------------------------------------------------------------------------


def _worktree_for(conf: dict, instance: str) -> str | None:
    root = conf.get("WORKTREE_ROOT")
    if not root:
        return None
    cand = os.path.join(root, instance)
    if not os.path.isdir(cand):
        return None
    real_root = os.path.realpath(root)
    real_cand = os.path.realpath(cand)
    if real_cand != real_root and not real_cand.startswith(real_root + os.sep):
        raise Fail("worktree '%s' resolves outside WORKTREE_ROOT" % instance)
    return real_cand


def _rebase(source: str, bind_root: str, worktree: str) -> str | None:
    """Return the worktree-relative twin of `source`, or None if not under root."""
    if source == bind_root:
        return worktree
    if source.startswith(bind_root.rstrip(os.sep) + os.sep):
        return os.path.join(worktree, os.path.relpath(source, bind_root))
    return None


def compose_file_for(conf: dict, instance: str, stack: list) -> str:
    """The `-f` argument for this instance.

    Returns the frozen file untouched unless a worktree named after the instance
    exists, in which case every bind under BIND_ROOT is re-prefixed into it and
    the result is written to a mode-600 temp file (registered on `stack` for
    cleanup). Named volumes are never touched.
    """
    worktree = _worktree_for(conf, instance)
    bind_root = conf.get("BIND_ROOT")
    if worktree is None or not bind_root:
        return conf["FROZEN"]

    with open(conf["FROZEN"], "r", encoding="utf-8") as fh:
        data = json.load(fh)

    for svc in (data.get("services") or {}).values():
        for vol in svc.get("volumes") or []:
            if not isinstance(vol, dict) or vol.get("type") != "bind":
                continue
            src = vol.get("source")
            if not isinstance(src, str):
                continue
            new = _rebase(src, bind_root, worktree)
            if new is None:
                continue
            if not os.path.exists(new):
                raise Fail(
                    "worktree '%s' has no %s (bind source %s has no counterpart)"
                    % (instance, new, src)
                )
            vol["source"] = new

    fd, path = tempfile.mkstemp(
        prefix="multiplai-docker-%s-%s-" % (conf["_name"], instance), suffix=".json"
    )
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    stack.append(path)
    return path


# --------------------------------------------------------------------------
# docker plumbing
# --------------------------------------------------------------------------


def project_name(conf: dict, instance: str) -> str:
    return "%s-%s" % (conf["PROJECT_PREFIX"], instance)


def compose_base(conf: dict, compose_file: str, project: str) -> list[str]:
    # --project-directory is mandatory: without it Compose re-anchors relative
    # paths to the directory of the -f file (Gate A, 2026-08-05).
    return [
        "docker",
        "compose",
        "-f",
        compose_file,
        "--project-directory",
        conf["PROJECT_DIR"],
        "-p",
        project,
    ]


def frozen_ports(conf: dict) -> dict:
    """service -> [container ports], from the targets `freeze` stripped."""
    try:
        with open(conf["FROZEN"], "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    out = {}
    for svc, body in (data.get("services") or {}).items():
        ports = body.get("x-multiplai-ports") if isinstance(body, dict) else None
        if isinstance(ports, list) and ports:
            out[svc] = ports
    return out


def print_urls(conf: dict, project: str) -> None:
    """After `up`, name the reachable URLs.

    Host ports are stripped so instances can coexist, so the only route in is the
    per-container hostname. Ports come from the frozen file (what the compose
    author chose to publish), never from probing the container.
    """
    ports = frozen_ports(conf)
    if not ports:
        return
    proc = run(
        [
            "docker",
            "ps",
            "--filter",
            "label=com.docker.compose.project=" + project,
            "--format",
            '{{.Names}}\t{{.Label "com.docker.compose.service"}}',
        ],
        capture=True,
    )
    if proc.returncode != 0:
        return
    lines = []
    for line in (proc.stdout or "").splitlines():
        name, _, svc = line.partition("\t")
        for port in ports.get(svc, []):
            lines.append("  %-12s http://%s.orb.local:%d" % (svc, name, port))
    if lines:
        print("reachable (no host ports are published — use these hostnames):")
        for line in sorted(lines):
            print(line)


def run(argv: list[str], capture: bool = False) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(argv, capture_output=capture, text=True, check=False)
    except FileNotFoundError:
        raise Fail("docker not found on PATH", 2)


def run_or_die(argv: list[str]) -> int:
    proc = run(argv)
    return proc.returncode


def docker_ps(profile: str | None) -> list[dict]:
    """Every container this tool manages, newest first."""
    label = "multiplai.profile" + ("=" + profile if profile else "")
    fmt = (
        '{{.ID}}\t{{.Label "multiplai.profile"}}\t'
        '{{.Label "com.docker.compose.project"}}\t'
        '{{.Label "com.docker.compose.service"}}\t{{.CreatedAt}}\t{{.Status}}'
    )
    proc = run(
        ["docker", "ps", "-a", "--filter", "label=" + label, "--format", fmt],
        capture=True,
    )
    if proc.returncode != 0:
        raise Fail("docker ps failed: %s" % (proc.stderr or "").strip(), 2)
    rows = []
    for line in (proc.stdout or "").splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        cid, prof, project, service, created, status = parts
        rows.append(
            {
                "id": cid,
                "profile": prof,
                "project": project,
                "service": service,
                "created": parse_created(created),
                "created_raw": created,
                "status": status,
            }
        )
    return rows


def parse_created(value: str) -> datetime | None:
    """`docker ps` CreatedAt: '2026-08-05 20:00:00 +0200 CEST' (tz name ignored)."""
    parts = value.split()
    if len(parts) < 3:
        return None
    try:
        return datetime.strptime(" ".join(parts[:3]), "%Y-%m-%d %H:%M:%S %z")
    except ValueError:
        return None


def instance_of(row: dict, prefix_by_profile: dict) -> str:
    prefix = prefix_by_profile.get(row["profile"])
    project = row["project"]
    if prefix and project.startswith(prefix + "-"):
        return project[len(prefix) + 1 :]
    return project


# --------------------------------------------------------------------------
# freeze — the trust step
# --------------------------------------------------------------------------


def find_worktree_root(start: str) -> str | None:
    """Nearest ancestor containing a `.worktrees` directory."""
    cur = os.path.realpath(start)
    while True:
        cand = os.path.join(cur, ".worktrees")
        if os.path.isdir(cand):
            return cand
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def cmd_freeze(args: list[str]) -> int:
    if os.environ.get("SSH_ORIGINAL_COMMAND") or os.environ.get("SSH_CONNECTION"):
        raise Fail("freeze is a host-terminal command; it is not reachable over SSH")

    if not args:
        raise Fail("freeze needs a profile name")
    name = args.pop(0)
    if not PROFILE_RE.match(name):
        raise Fail("invalid profile name: %s" % name)

    files: list[str] = []
    project_dir = prefix = bind_root = worktree_root = None

    def value_for(flag: str) -> str:
        if not args:
            raise Fail("freeze: %s needs a value" % flag)
        return args.pop(0)

    while args:
        arg = args.pop(0)
        if arg in ("-f", "--file"):
            files.append(os.path.realpath(value_for(arg)))
        elif arg == "--project-dir":
            project_dir = os.path.realpath(value_for(arg))
        elif arg == "--prefix":
            prefix = value_for(arg)
        elif arg == "--bind-root":
            bind_root = os.path.realpath(value_for(arg))
        elif arg == "--worktree-root":
            worktree_root = os.path.realpath(value_for(arg))
        else:
            raise Fail("freeze: unexpected argument: %s" % arg)

    if not files:
        raise Fail("freeze needs at least one -f <compose file>")
    for path in files:
        if not os.path.isfile(path):
            raise Fail("no such compose file: %s" % path)

    project_dir = project_dir or os.path.dirname(files[0])
    prefix = prefix or name
    if not PROFILE_RE.match(prefix):
        raise Fail("invalid --prefix: %s" % prefix)
    bind_root = bind_root or project_dir
    if worktree_root is None:
        worktree_root = find_worktree_root(project_dir) or ""

    argv = ["docker", "compose"]
    for path in files:
        argv += ["-f", path]
    argv += ["--project-directory", project_dir, "config", "--format", "json"]
    proc = run(argv, capture=True)
    if proc.returncode != 0:
        raise Fail("docker compose config failed:\n%s" % (proc.stderr or "").strip(), 2)

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise Fail("docker compose config did not return JSON: %s" % exc, 2)

    services = data.get("services") or {}
    if not services:
        raise Fail("resolved compose config has no services")

    # Deterministic freeze-time transforms, and only these.
    for svc in services.values():
        # Parallel instances must not publish host ports. Keep the container-side
        # targets as metadata so `up` can print reachable per-instance URLs.
        targets = []
        for port in svc.pop("ports", None) or []:
            target = port.get("target") if isinstance(port, dict) else None
            if isinstance(target, int) and target not in targets:
                targets.append(target)
        if targets:
            svc["x-multiplai-ports"] = targets
        labels = svc.get("labels")
        if isinstance(labels, list):
            labels = {
                k: v
                for k, _, v in (item.partition("=") for item in labels)
            }
        elif not isinstance(labels, dict):
            labels = {}
        labels["multiplai.profile"] = name
        svc["labels"] = labels

    # `compose config` RESOLVES top-level volume and network names against the
    # source project ("dolceengine_mysql_data") and emits them as explicit
    # `name:` keys. Frozen as-is, every instance would share one volume set and
    # one network — no isolation at all. Drop the resolved name so Compose
    # re-derives `<project>_<key>` per instance. `external: true` entries name a
    # volume the stack does not own, so their name is meaningful: keep it.
    for section in ("volumes", "networks"):
        for entry in (data.get(section) or {}).values():
            if isinstance(entry, dict) and not entry.get("external"):
                entry.pop("name", None)

    json_path = _profile_path(name, ".json")
    conf_path = _profile_path(name, ".conf")
    os.makedirs(PROFILE_DIR, mode=0o700, exist_ok=True)
    os.chmod(PROFILE_DIR, 0o700)

    write_private(json_path, json.dumps(data, indent=2, sort_keys=True) + "\n")
    conf = [
        "FROZEN=%s" % json_path,
        "PROJECT_DIR=%s" % project_dir,
        "PROJECT_PREFIX=%s" % prefix,
        "SERVICES=%s" % " ".join(sorted(services)),
        "SOURCE_FILES=%s" % ":".join(files),
        "SOURCE_SHA256=%s" % source_digest(files),
        "BIND_ROOT=%s" % bind_root,
    ]
    if worktree_root:
        conf.append("WORKTREE_ROOT=%s" % worktree_root)
    write_private(conf_path, "\n".join(conf) + "\n")

    print("froze profile '%s'" % name)
    print("  %s" % json_path)
    print("  %s" % conf_path)
    print("  services: %s" % " ".join(sorted(services)))
    print("review the frozen JSON now — this is the trust step.")
    return 0


def write_private(path: str, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


# --------------------------------------------------------------------------
# bridge verbs
# --------------------------------------------------------------------------


def take_instance(args: list[str]) -> str:
    """Pull an optional `--instance <tok>` out of args; reject every other flag."""
    instance = "main"
    seen = False
    rest: list[str] = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--instance":
            if seen:
                raise Fail("--instance given twice")
            if i + 1 >= len(args):
                raise Fail("--instance needs a value")
            instance = args[i + 1]
            seen = True
            i += 2
            continue
        if arg.startswith("-"):
            raise Fail("flag not allowed: %s" % arg)
        rest.append(arg)
        i += 1
    if not INSTANCE_RE.match(instance):
        raise Fail("invalid instance name: %s" % instance)
    args[:] = rest
    return instance


def take_service(conf: dict, args: list[str]) -> str:
    if not args:
        raise Fail("a service name is required")
    svc = args.pop(0)
    if svc not in conf["SERVICES"].split():
        raise Fail(
            "service '%s' is not in profile '%s' (have: %s)"
            % (svc, conf["_name"], conf["SERVICES"])
        )
    return svc


def cmd_bridge(verb: str, args: list[str]) -> int:
    if verb == "reap-older-than":
        return cmd_reap(args)
    if verb == "ls":
        return cmd_ls(args)

    if not args:
        raise Fail("%s needs a profile name" % verb)

    # `exec` is the only verb with guest argv; split it off before flag checks so
    # the guest's own words are never mistaken for ours.
    guest: list[str] = []
    if verb == "exec":
        if "--" not in args:
            raise Fail("exec needs `-- <argv…>`")
        cut = args.index("--")
        guest = args[cut + 1 :]
        args = args[:cut]

    profile = args.pop(0)
    instance = take_instance(args)
    conf = load_profile(profile)
    project = project_name(conf, instance)

    stack: list[str] = []
    try:
        if verb in ("up", "build"):
            check_drift(conf)
        compose_file = compose_file_for(conf, instance, stack)
        base = compose_base(conf, compose_file, project)

        if verb == "up":
            if args:
                raise Fail("up takes no extra arguments: %s" % " ".join(args))
            print(
                "starting %s and waiting for healthchecks (up to %ds).\n"
                "  first boot runs migrations and can take minutes — this is not a hang.\n"
                "  watch from another session: multiplai-docker logs %s <service>"
                % (project, WAIT_TIMEOUT, conf["_name"])
            )
            rc = run_or_die(
                base + ["up", "-d", "--wait", "--wait-timeout", str(WAIT_TIMEOUT)]
            )
            if rc == 0:
                print_urls(conf, project)
            else:
                print(
                    "up did not reach a healthy state within %ds (or a container "
                    "exited).\n"
                    "  the stack may still be starting — check before assuming it "
                    "failed:\n"
                    "    multiplai-docker ps   %s\n"
                    "    multiplai-docker logs %s <service>"
                    % (WAIT_TIMEOUT, conf["_name"], conf["_name"]),
                    file=sys.stderr,
                )
            return rc

        if verb == "down":
            if args:
                raise Fail("down takes no extra arguments: %s" % " ".join(args))
            # Always -v: instances are ephemeral, and their named volumes are
            # per-instance (Compose prefixes them with the project name).
            return run_or_die(base + ["down", "-v"])

        if verb == "ps":
            if args:
                raise Fail("ps takes no extra arguments: %s" % " ".join(args))
            return run_or_die(base + ["ps"])

        if verb == "logs":
            svc = take_service(conf, args)
            tail = DEFAULT_TAIL
            if args:
                raw = args.pop(0)
                if not raw.isdigit():
                    raise Fail("logs: <n> must be a number: %s" % raw)
                tail = min(int(raw), MAX_TAIL)
            if args:
                raise Fail("logs takes at most <service> <n>: %s" % " ".join(args))
            # Never --follow: the bridge call would never return.
            return run_or_die(
                base + ["logs", "--no-color", "--tail", str(tail), svc]
            )

        if verb == "restart":
            svc = take_service(conf, args)
            if args:
                raise Fail("restart takes only <service>: %s" % " ".join(args))
            return run_or_die(base + ["restart", svc])

        if verb == "build":
            svc = take_service(conf, args)
            if args:
                raise Fail("build takes only <service>: %s" % " ".join(args))
            # No --ssh, --secret, --allow or --network=host, ever. The guard is
            # that we construct this argv ourselves and take_instance() has
            # already refused every caller-supplied flag.
            return run_or_die(base + ["build", svc])

        if verb == "exec":
            svc = take_service(conf, args)
            if args:
                raise Fail("exec takes only <service> before `--`: %s" % " ".join(args))
            if not guest:
                raise Fail("exec needs a command after `--`")
            for word in guest:
                if word.startswith("-"):
                    raise Fail("exec: guest argument may not start with '-': %s" % word)
                if not GUEST_ARG_RE.match(word):
                    raise Fail("exec: guest argument not allowed: %s" % word)
            # -T: no TTY, so the argv reaches the guest entrypoint and never Docker.
            return run_or_die(base + ["exec", "-T", svc] + guest)

        raise Fail("unknown verb: %s" % verb)
    finally:
        for path in stack:
            try:
                os.unlink(path)
            except OSError:
                pass


def cmd_ls(args: list[str]) -> int:
    profile = None
    if args:
        profile = args.pop(0)
        if not PROFILE_RE.match(profile):
            raise Fail("invalid profile name: %s" % profile)
    if args:
        raise Fail("ls takes at most a profile name: %s" % " ".join(args))

    rows = docker_ps(profile)
    prefixes = prefix_map({r["profile"] for r in rows})
    seen: dict[tuple, dict] = {}
    for row in rows:
        key = (row["profile"], row["project"])
        entry = seen.setdefault(
            key,
            {
                "profile": row["profile"],
                "instance": instance_of(row, prefixes),
                "project": row["project"],
                "services": [],
                "created": row["created"],
            },
        )
        entry["services"].append(row["service"] or row["id"])
        if row["created"] and (
            entry["created"] is None or row["created"] < entry["created"]
        ):
            entry["created"] = row["created"]

    if not seen:
        print("no live instances" + (" for profile '%s'" % profile if profile else ""))
        return 0
    print("%-16s %-16s %-24s %s" % ("PROFILE", "INSTANCE", "PROJECT", "SERVICES"))
    for entry in sorted(seen.values(), key=lambda e: (e["profile"], e["instance"])):
        print(
            "%-16s %-16s %-24s %s"
            % (
                entry["profile"],
                entry["instance"],
                entry["project"],
                " ".join(sorted(entry["services"])),
            )
        )
    return 0


def prefix_map(profiles: set) -> dict:
    out = {}
    for name in profiles:
        if not name or not PROFILE_RE.match(name):
            continue
        try:
            out[name] = load_profile(name)["PROJECT_PREFIX"]
        except Fail:
            continue
    return out


def cmd_reap(args: list[str]) -> int:
    if not args:
        raise Fail("reap-older-than needs <hours>")
    raw = args.pop(0)
    if args:
        raise Fail("reap-older-than takes only <hours>: %s" % " ".join(args))
    try:
        hours = float(raw)
    except ValueError:
        raise Fail("reap-older-than: <hours> must be a number: %s" % raw)
    if hours < 0:
        raise Fail("reap-older-than: <hours> must not be negative")

    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    rows = docker_ps(None)
    prefixes = prefix_map({r["profile"] for r in rows})

    newest: dict[tuple, datetime] = {}
    for row in rows:
        if row["created"] is None:
            continue
        key = (row["profile"], row["project"])
        if key not in newest or row["created"] > newest[key]:
            newest[key] = row["created"]

    rc = 0
    for (profile, project), created in sorted(newest.items()):
        if created > cutoff:
            continue
        instance = instance_of(
            {"profile": profile, "project": project}, prefixes
        )
        try:
            conf = load_profile(profile)
        except Fail as exc:
            warn("cannot reap %s: %s" % (project, exc))
            rc = rc or 1
            continue
        print("reaping %s (instance %s, created %s)" % (project, instance, created))
        code = run_or_die(
            compose_base(conf, conf["FROZEN"], project) + ["down", "-v"]
        )
        rc = rc or code
    return rc


# --------------------------------------------------------------------------


def usage(stream=sys.stdout) -> None:
    print((__doc__ or "").strip(), file=stream)


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        usage()
        return 0
    verb = argv[0]
    args = list(argv[1:])
    if verb not in ALL_VERBS:
        raise Fail(
            "unknown verb: %s (expected one of: %s)" % (verb, " ".join(ALL_VERBS))
        )
    if verb == "freeze":
        return cmd_freeze(args)
    return cmd_bridge(verb, args)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as exc:
        print("multiplai-docker: %s" % exc, file=sys.stderr)
        sys.exit(exc.code)
    except KeyboardInterrupt:
        sys.exit(130)
