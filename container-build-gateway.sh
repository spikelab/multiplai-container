#!/bin/zsh
# Gateway script — only allows build-related commands from the container SSH key.
# SSH passes the original command via SSH_ORIGINAL_COMMAND.
#
# Install on macOS host:
#   mkdir -p ~/.local/bin
#   cp container-build-gateway.sh ~/.local/bin/container-build-gateway.sh
#   chmod +x ~/.local/bin/container-build-gateway.sh
#
# Then in ~/.ssh/authorized_keys, prefix the container key with restrict + command=:
#   restrict,command="~/.local/bin/container-build-gateway.sh" ssh-ed25519 AAAA... container-builds
# ("restrict" disables port/agent/X11 forwarding and pty allocation; command= pins
# every session to this gateway regardless of what the client asks to run.)
#
# Security model: we NEVER hand $SSH_ORIGINAL_COMMAND to a shell as a string.
# We reject shell metacharacters, tokenize into argv honoring quotes only (no
# expansion), validate argv[0] (+ subcommand) against the allowlist, then exec
# the argv array as data via `zsh -lc 'exec "$@"'` — the inner exec receives the
# words as positional parameters and does not re-parse them, so nothing in the
# command string can re-enter a shell.

emulate -L zsh
setopt no_glob no_nomatch

deny() { echo "DENIED: $1" >&2; exit 1; }

# Opt-in gate for the host browser. See the `agent-browser` branch below.
#
# The path is XDG's default state directory, but $XDG_STATE_HOME is deliberately
# NOT read: sshd can be configured to accept environment variables from the
# client, and a gate whose location the remote side might steer is not a gate.
# $HOME is the account this forced command already runs as.
HOST_BROWSER_FLAG="$HOME/.local/state/multiplai/host-browser-enabled"

# ---------------------------------------------------------------------------
# The filesystem boundary (issue mktplace#15)
# ---------------------------------------------------------------------------
#
# This gateway enforces a COMMAND ALLOWLIST. Until now it enforced no
# FILESYSTEM BOUNDARY, and those are different controls. The forced command
# runs with cwd = the host user's HOME and no branch inspected path arguments,
# so `mlx_whisper --output-dir .` wrote into ~ on the Mac — outside the
# workspace, invisible to the container. Every allowlisted command that takes
# an output path could be pointed anywhere the host user can write.
#
# The workspace cannot be supplied by the container: a value arriving from the
# side being confined is not a boundary. It has to be declared host-side, by
# the same reasoning (and in the same directory) as HOST_BROWSER_FLAG above —
# a file the container has no route to write.
#
# multiplai-kit's setup.sh writes it, because setup.sh already knows $WORKSPACE
# and already installs this gateway.
WORKSPACE_DECL="$HOME/.local/state/multiplai/workspace"

# The sandbox profile ships from this repo, but NOT through `install_host_tool`
# — it is data this script reads, not a tool on $PATH. multiplai-kit's setup.sh
# copies it with a sibling function, `install_host_state`, which lands it at
# ~/.local/state/multiplai/confine.sb (mode 644) beside the workspace
# declaration and the host-browser flag: one host-owned directory the container
# has no route to write. Same verification gate as install_host_tool (the
# container/ checkout must be verified at CONTAINER_REF and the image build must
# have passed), so a gateway and a profile from different generations cannot be
# installed together.
#
# RELEASE ORDERING, and it is load-bearing: install_host_state copies from the
# kit's PINNED container/ checkout. This repo must tag FIRST, then the kit's
# CONTAINER_REF must be bumped to that tag. A kit still pinned at a tag that
# predates confine.sb finds no source file, returns without copying, and prints
# nothing — the sandbox layer then silently never engages while every other
# layer looks healthy.
CONFINE_PROFILE="$HOME/.local/state/multiplai/confine.sb"

# The declared workspace, in two forms. WS_RAW is the string the host wrote;
# WS is that string with symlinks resolved. Everything that ENFORCES uses WS —
# see the resolution note below.
WS=""
WS_RAW=""
if [ -f "$WORKSPACE_DECL" ]; then
  # One absolute path, first line only. Anything else is a malformed
  # declaration and is treated as no declaration at all — a half-understood
  # boundary is worse than a known-absent one.
  WS_RAW="$(head -n 1 "$WORKSPACE_DECL" 2>/dev/null)"
  WS_RAW="${WS_RAW%%$'\r'}"
  if [[ "$WS_RAW" != /* ]] || [[ ! -d "$WS_RAW" ]]; then
    deny "workspace declaration at $WORKSPACE_DECL is not an existing absolute path.
        Re-run ./setup.sh on the Mac to rewrite it."
  fi

  # Resolve ONCE, here, and use the resolved value for every layer below.
  #
  # The two enforcement layers read the workspace differently: the `cd`
  # containment check compares symlink-RESOLVED paths (pwd -P), while
  # sandbox-exec matches `(subpath …)` against the kernel's resolved path.
  # Passing the raw string to one and the resolved string to the other makes
  # them disagree: declare /Users/you/ws when that is a symlink to
  # /Volumes/Data/ws and `cd /Users/you/ws && swift build` passes containment
  # while every write under it is denied by the profile, with no message that
  # names the cause. (That SBPL subpaths are not resolved for you is why this
  # profile has to list BOTH /tmp and /private/tmp.)
  WS="$(cd -P -- "$WS_RAW" 2>/dev/null && pwd -P)" \
    || deny "declared workspace is unreadable: $WS_RAW"

  # "Absolute and a directory" is not enough. `/` and $HOME both pass that test
  # while switching the boundary off: `cd` containment then admits everything
  # the host user can reach, and the profile's `(subpath (param "WORKSPACE"))`
  # hands back write access to the whole home directory — including ~/.ssh,
  # which the profile's closing comment claims is denied. A workspace INSIDE
  # $HOME is the normal case and stays fine; $HOME itself is not a workspace.
  if [[ "$WS" == "/" ]]; then
    deny "workspace declaration at $WORKSPACE_DECL is \`/\`, which is not a
        boundary — it would allow writes anywhere on the host. Declare the
        directory your projects live in.
        On the Mac: echo /absolute/path/to/your/workspace > $WORKSPACE_DECL"
  fi
  REAL_HOME="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || REAL_HOME="$HOME"
  if [[ "$WS" == "${REAL_HOME%/}" || "$WS_RAW" == "${HOME%/}" ]]; then
    deny "workspace declaration at $WORKSPACE_DECL is your home directory,
        which is not a boundary — it re-opens exactly the escape this control
        exists to close (writes into ~, ~/.ssh, ~/Library). Declare a
        subdirectory of it instead.
        On the Mac: echo \$HOME/some/workspace > $WORKSPACE_DECL"
  fi
fi

CMD="$SSH_ORIGINAL_COMMAND"
[ -z "$CMD" ] && deny "interactive shell not allowed"

# Optional leading "cd <dir> && <cmd>": handle the chdir ourselves so we never
# pass an "&&" to a shell. Split off the directory and keep the real command.
WORKDIR=""
if [[ "$CMD" == "cd "* ]]; then
  [[ "$CMD" == cd\ *\ "&&"\ * ]] || deny "malformed cd prefix"
  WORKDIR="${CMD#cd }"; WORKDIR="${WORKDIR%% && *}"
  CMD="${CMD#* && }"
fi

# Optional trailing xcsift pipe. The swift-build skill routes build/test output
# through xcsift for compact, token-efficient results by appending a FIXED,
# trusted suffix. We can't let a raw `|` through the metacharacter gate below —
# that would re-open shell-string evaluation of untrusted input, the exact thing
# this gateway exists to prevent. Instead we recognize ONLY this one exact
# literal suffix, strip it here (before the metachar check), and re-attach it
# host-side as a hardcoded constant at exec time. The user-supplied head command
# is still validated and exec'd as argv data — never re-parsed — so the "no
# untrusted shell string" invariant holds. Same shape as the `cd ... &&` prefix
# handling above: strip a known-safe wrapper, validate the rest, exec as data.
XCSIFT=0
XCSIFT_SUFFIX=' 2>&1 | xcsift --format toon --quiet'
if [[ "$CMD" == *"$XCSIFT_SUFFIX" ]]; then
  XCSIFT=1
  CMD="${CMD%"$XCSIFT_SUFFIX"}"
fi

# Reject every shell metacharacter that could chain, substitute, or redirect.
# After the cd handling above there is no legitimate reason for any of these.
#
# Escape-aware: the client %q-escapes arguments, so a path/scheme may contain
# `\(`, `\ `, etc. A backslash-escaped character is exactly what the (z)
# tokenizer below treats as a literal word character — it can never act as a
# separator, substitution, or redirect — and after (Q) it travels only as argv
# DATA (never re-parsed by a shell). So strip `\<char>` pairs first and run the
# deny-list on the residue: every unescaped metachar is still caught (same
# deny-by-default gate), while escaped ones pass as data. Raw newlines are
# denied on the ORIGINAL string — a backslash-newline could hide one from the
# residue. Quoted metachars (`"("`) remain in the residue and stay denied:
# conservative, and the %q client never produces them.
RESIDUE="${CMD//\\?/}${WORKDIR//\\?/}"
if [[ "$RESIDUE" == *[\;\|\&\<\>\`\$\(\)]* || "$CMD$WORKDIR" == *$'\n'* ]]; then
  deny "shell metacharacter in command"
fi

# Unquote the workdir the same way argv words are unquoted below, so a
# %q-escaped path (spaces, parens) cd's to its literal value. It must
# tokenize to exactly ONE word — anything else is a malformed prefix.
if [[ -n "$WORKDIR" ]]; then
  wd_words=(${(Q)${(z)WORKDIR}})
  (( ${#wd_words} == 1 )) || deny "malformed cd prefix: directory must be a single (escaped) word"
  WORKDIR="${wd_words[1]}"
fi

# Tokenize honoring quotes only. (z) splits like the shell parser; (Q) then
# strips one level of quoting from each word so a quoted argument arrives at
# the target as its literal value (e.g. `ab type "hello world"` -> one word
# `hello world`, not `hello\ world`). No command/parameter/glob expansion
# happens, and the metachars above are already rejected.
words=(${(Q)${(z)CMD}})
(( ${#words} )) || deny "empty command"
c1="${words[1]}"; c2="${words[2]}"

# The xcsift pipe exists solely to compact build/test output. Only the build
# tools may carry it — for every other allowlisted head (qmd, curl, …) the
# suffix is an anomaly, so keep deny-by-default and reject it.
if (( XCSIFT )); then
  case "$c1" in
    swift|xcodebuild|xcrun) ;;
    *) deny "xcsift pipe only allowed on build commands (swift/xcodebuild/xcrun), not: $c1" ;;
  esac
fi

# A URL target must be loopback http/https. This is an ALLOWLIST: anything that
# is not one of the forms below is refused, including an argument with no scheme
# at all.
#
# It used to return 0 for any argument lacking `://` ("not a URL — nothing to
# check"), which made it useless as a target test: `curl evil.com` and
# `--proxy evil.com:8080` both sailed through it, the second giving arbitrary
# outbound egress from the Mac while the URL itself stayed loopback. The caller
# is now responsible for calling this only on words that are meant to BE URLs
# (positional arguments and `--url`), which is what makes the strict form safe.
#
# It parses the authority out rather than prefix-matching the whole string,
# because a prefix match on `http://localhost` is not a host check:
# `http://localhost:8000@evil.com/` matched the old patterns (the character
# after `localhost` was a `:`) while curl reads `localhost:8000` as userinfo and
# connects to evil.com. The host has to be compared as a host.
url_ok() {
  local rest auth port
  case "$1" in
    http://*|https://*) rest="${1#*://}" ;;
    *) return 1 ;;               # no scheme, or a scheme we do not speak
  esac
  auth="${rest%%[/?#]*}"
  [[ -n "$auth" ]]      || return 1
  [[ "$auth" != *@* ]]  || return 1     # no userinfo — see above
  case "$auth" in
    localhost|127.0.0.1|\[::1\]) return 0 ;;
    localhost:*|127.0.0.1:*|\[::1\]:*)
      port="${auth##*:}"
      [[ -n "$port" && "${port//[0-9]/}" == "" ]] && return 0
      return 1 ;;
  esac
  return 1
}

# Value check for the curl flags that take one. The single thing every arm here
# is guarding is curl's `@file` convention: `-H @f`, `-d @f`, `--data-binary @f`
# and friends make curl READ a host file, and the bridge returns curl's stdout
# to the container — the same host-file exfiltration url_ok()'s file: refusal
# and the agent-browser file: block exist to prevent.
curl_value_ok() {  # $1 = flag (canonical form), $2 = value
  case "$1" in
    --url)
      url_ok "$2" ;;
    # --data-urlencode is the odd one out: its `name@file` spelling puts the @
    # in the MIDDLE, so a leading-@ test misses it. Refuse @ anywhere.
    --data-urlencode)
      [[ "$2" != *@* ]] ;;
    --header|-H|--data|-d|--data-ascii|--data-binary|--form-string)
      [[ "$2" != @* ]] ;;
    # --data-raw is the one -d spelling that does NOT honour @, but keeping the
    # rule uniform costs nothing and survives someone reshuffling this list.
    --data-raw)
      [[ "$2" != @* ]] ;;
    --user-agent|-A|--referer|-e)
      [[ "$2" != @* ]] ;;
    --max-time|-m|--connect-timeout|--retry|--retry-delay|--retry-max-time)
      [[ -n "$2" && "${2//[0-9.]/}" == "" ]] ;;
    --request|-X)
      [[ -n "$2" && "${2//[A-Za-z]/}" == "" ]] ;;
    --range|-r)
      [[ -n "$2" && "${2//[0-9,-]/}" == "" ]] ;;
    *) return 1 ;;   # deny-by-default: an unlisted flag never gets a value
  esac
}

# --- absolute/traversing path arguments ------------------------------------
#
# The command allowlist says nothing about the paths a command is handed.
# `xcodebuild -derivedDataPath /Users/you/x`, `mlx_whisper --output-dir
# /Users/you/Desktop x.m4a` and `swift build --scratch-path ../../..` are all
# outside the workspace, and NONE of them is touched by cwd pinning or by the
# `cd`-prefix check — those bound where the command STARTS, not where its
# arguments point. Whenever the sandbox layer is absent (an older kit pin, a
# profile moved aside) those arguments are the only thing left, and they are
# unbounded.
#
# Reads stay open on purpose (see confine.sb: SDKs, toolchains and model
# weights all live outside any workspace), so this cannot be a blanket "no
# absolute path outside the workspace" — that would refuse
# `-sdk /Applications/Xcode.app/…`. The rule is: an absolute path must be
# inside the workspace, or under one of the system/toolchain prefixes that are
# read-only-by-convention and that the profile already treats as fair game.
path_arg_ok() {  # $1 = candidate path, already lexically absolutised by caller
  local p="$1"
  # Inside the workspace, in either spelling. WS is the resolved value; WS_RAW
  # is what the host declared, and a caller who types the declared (symlinked)
  # spelling is not attacking anything.
  [[ "$p" == "$WS" || "$p" == "$WS"/* ]] && return 0
  [[ -n "$WS_RAW" && ( "$p" == "$WS_RAW" || "$p" == "$WS_RAW"/* ) ]] && return 0
  case "$p" in
    # Toolchains and SDKs — read paths a build legitimately names.
    /Applications/Xcode*.app|/Applications/Xcode*.app/*) return 0 ;;
    /Library/Developer|/Library/Developer/*) return 0 ;;
    /usr/*|/bin/*|/sbin/*|/System/*|/Library/Frameworks/*) return 0 ;;
    /opt/homebrew/*|/opt/local/*) return 0 ;;
    # Temporary directories the profile already allows writing to.
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) return 0 ;;
    /var/folders/*|/private/var/folders/*) return 0 ;;
    /dev/null|/dev/stdout|/dev/stderr|/dev/fd/*) return 0 ;;
  esac
  return 1
}

# Two per-command properties, both deny-by-default like everything else here.
#
#   NEEDS_WS  this command takes or writes paths, so it must not run without a
#             declared workspace. Absent declaration -> denied (fail closed).
#   SANDBOX   this command should additionally run inside sandbox-exec.
#
# A branch that clears either flag has to say why. "It probably doesn't write
# anything" is not a reason; "it takes no path argument and this branch already
# validates every word against a label charset" is.
NEEDS_WS=1
SANDBOX=1

case "$c1" in
  xcodebuild|xcsift|xcodegen|mlx-whisper|mlx_whisper) allow=1 ;;
  agent-browser)
    # OPT-IN, and this is the gate — not the skill's prose. `ab` drives the
    # host's REAL logged-in Chrome: every session it holds, every cookie, every
    # authenticated app. That is a capability a host owner should grant on
    # purpose, and until now the only thing standing between a session and it
    # was that the skill stopped advertising itself (kit #60), which is a hint,
    # not a control — anything that knows the verb still reached Chrome.
    #
    # The switch is a file on the Mac. It has to be something the container
    # cannot write, or the agent flips its own gate: there is no route from the
    # container to the host's $HOME, and an environment variable would arrive
    # from the side being gated. Absent flag, absent capability.
    if [[ ! -f "$HOST_BROWSER_FLAG" ]]; then
      deny "host browser is not enabled on this host.
        To turn it on, run this on the Mac:
          mkdir -p ~/.local/state/multiplai
          touch ~/.local/state/multiplai/host-browser-enabled
        To turn it off again: rm ~/.local/state/multiplai/host-browser-enabled
        It grants a session the real logged-in Chrome — every cookie and every
        signed-in app on this machine. Nothing in the container can set it."
    fi
    # SECURITY: `ab` drives the host's REAL Chrome, which can open file:/// URLs
    # and read ANY host file Chrome can reach — the exact host-file exfiltration
    # the curl url_ok()/file: guard exists to block. Apply the same file:-scheme
    # block to navigation verbs so `ab open file:///etc/passwd` is denied.
    # (Note: once enabled, the bridge lets the container drive the host browser
    # at large; see README ▸ macOS host bridge for the trust caveat.)
    if [[ "$c2" == (open|goto|navigate) ]]; then
      i=3
      while (( i <= ${#words} )); do
        [[ "${(L)words[i]}" == file:* ]] && deny "agent-browser file: URL not allowed: ${words[i]}"
        (( i++ ))
      done
    fi
    # Deliberately outside the workspace jail, and this is a stated gap, not an
    # oversight. `ab` drives a browser whose profile, cookie store and cache all
    # live under ~/Library/Application Support/Google/Chrome; confining it to
    # $WORKSPACE would either break it outright or require exempting the very
    # directories that hold the credentials. A jail that must exempt the thing
    # worth protecting is not a jail, so this capability keeps the control it
    # already has — the explicit host opt-in checked immediately above — rather
    # than gaining a second one that does not fit it.
    NEEDS_WS=0
    SANDBOX=0
    allow=1
    ;;
  swift)   [[ "$c2" == (build|run|test|package|--version) ]] && allow=1 ;;
  qmd)
    # Local markdown search over indexed collections (knowhere RESOURCES
    # retrieval hook). Search/read subcommands plus incremental index
    # maintenance only — no collection add/remove or init (index scope stays
    # a human decision on the host), no mcp server.
    [[ "$c2" == (query|search|vsearch|status|embed|update|ls|get|multi-get) ]] && allow=1
    ;;
  xcrun)   [[ "$c2" == (simctl|xcresulttool|devicectl) ]] && allow=1 ;;
  # Takes a command NAME and prints a path; writes nothing, reads no argument
  # as a path. Requiring a declared workspace for it would break the one probe
  # a session uses to find out whether the bridge works at all.
  command) [[ "$c2" == "-v" ]] && { NEEDS_WS=0; SANDBOX=0; allow=1; } ;;
  open)
    # Exactly three words: `open -a` and ONE app name matched literally.
    #
    # It used to be a prefix glob (`Simulator*`) with everything from words[4]
    # on unvalidated, and `open -a` takes a PATH as happily as a registered app
    # name — so `Simulator/../Evil.app` matched the pattern. With the workspace
    # bind-mounted read-write into the container, the container could write
    # $WS/Evil.app and send `cd $WS && open -a Simulator/../Evil.app`: the cd
    # passes containment, the glob passes, and LaunchServices launches the
    # bundle OUTSIDE the sandbox (this branch clears both flags). An exact
    # match is the whole fix — there is no path separator and no `..` to
    # traverse with. The only caller is the swift-build skill's literal
    # `open -a Simulator`.
    if [[ "$c2" == "-a" ]]; then
      (( ${#words} == 3 )) || deny "open takes exactly \`-a <app>\`: $CMD"
      case "${words[3]}" in
        Simulator|Simulator.app) NEEDS_WS=0; SANDBOX=0; allow=1 ;;
        *) deny "open -a app not allowed: ${words[3]}" ;;
      esac
    fi
    ;;
  pkill)
    # Only allow killing the simulator/build processes this gateway exists for,
    # by exact name — never a bare `pkill -f .` that could reap host processes.
    i=2; target=""
    while (( i <= ${#words} )); do
      w="${words[i]}"
      case "$w" in
        -f|-9|-15|-INT|-TERM|-KILL|-x) ;;               # accepted flags
        -*) deny "pkill flag not allowed: $w" ;;
        *) [[ -n "$target" ]] && deny "pkill: single target only"; target="$w" ;;
      esac
      (( i++ ))
    done
    case "$target" in
      # Signals a process by exact name — no path argument exists to confine,
      # and the target list above is already the boundary.
      Simulator|com.apple.CoreSimulator.*|xcodebuild|swift|swift-frontend|XCTest|testmanagerd)
        NEEDS_WS=0; SANDBOX=0; allow=1 ;;
      *) deny "pkill target not allowed: ${target:-<none>}" ;;
    esac
    ;;
  multiplai-gh-token)
    # Mints a 1-hour GitHub App installation token on the host; the App private
    # key never leaves the Mac. At most two arguments: an optional leading flag
    # (--json or --check) plus the app-profile name.
    #   --json  is REQUIRED by the container side: gh-tok caches .token together
    #           with .expires_at so it can decide at call time whether to re-mint.
    #           It exposes no secret the bare form doesn't; transcript hygiene
    #           comes from gh-tok redirecting into a mode-600 file, not from
    #           hiding a flag any caller could sidestep by dropping it.
    #   --check is a no-network credential diagnostic that prints no token.
    (( ${#words} <= 3 )) || deny "multiplai-gh-token takes at most 2 arguments"
    i=2; napp=0
    while (( i <= ${#words} )); do
      w="${words[i]}"
      if [[ "$w" == (--check|--json) ]]; then
        (( i == 2 )) || deny "multiplai-gh-token: flag must come first"
      elif [[ "$w" == -* ]]; then
        deny "multiplai-gh-token flag not allowed: $w"
      else
        (( napp == 0 )) || deny "multiplai-gh-token: single app name only"
        [[ "${w//[A-Za-z0-9._-]/}" == "" && "$w" == [A-Za-z0-9]* ]] \
          || deny "multiplai-gh-token: invalid app name: $w"
        napp=1
      fi
      (( i++ ))
    done
    # ~/.local/bin is NOT on the login PATH the gateway's `zsh -lc` resolves
    # through, so pin argv[0] to the absolute install path rather than making
    # the verb depend on the user's shell profile. This substitutes a HOST-SIDE
    # CONSTANT for argv[0] — no client string is re-parsed by a shell, so the
    # gateway's invariant (argv travels as data) is untouched.
    # Takes a flag and an app name validated to `[A-Za-z0-9._-]` above — no path
    # can be expressed. It reaches the Keychain, which needs a mach-lookup to
    # securityd and a write to the keychain file: both outside any workspace, so
    # a workspace jail is the wrong shape of control for it. Its boundary is the
    # argv validation directly above.
    NEEDS_WS=0
    SANDBOX=0
    words[1]="$HOME/.local/bin/multiplai-gh-token"
    allow=1
    ;;
  multiplai-docker)
    # Starts/inspects/tears down PRE-FROZEN Docker Compose stacks on the host.
    # The container never authors a Docker argument or a compose file: the host
    # script runs Compose against a config the host owner froze in advance, and
    # everything below is a label — a verb, a profile name, an instance name, a
    # service name, a numeric tail, or guarded guest argv for `exec`.
    #
    # `freeze` is the trust step and is deliberately NOT in this list: creating
    # or changing a profile is a host-terminal act, so bridge callers are denied
    # before the script even runs.
    case "$c2" in
      up|down|ps|ls|logs|restart|build|exec|reap-older-than) ;;
      *) deny "multiplai-docker verb not allowed: ${c2:-<none>}" ;;
    esac
    # words[3] is the profile for every verb that takes one (`ls` may omit it,
    # `reap-older-than` takes hours instead) — hold it to the profile regex the
    # host script enforces, so a bad name dies here too.
    if [[ "$c2" != "reap-older-than" && -n "${words[3]:-}" && "${words[3]}" != "--"* ]]; then
      p="${words[3]}"
      [[ "${p//[a-z0-9_-]/}" == "" && "$p" == [a-z0-9]* && ${#p} -le 32 ]] \
        || deny "multiplai-docker: invalid profile name: $p"
    fi
    i=3; past_ddash=0; want_instance=0
    while (( i <= ${#words} )); do
      w="${words[i]}"
      if (( past_ddash )); then
        # exec's guest argv: reaches the guest entrypoint via `compose exec -T`,
        # never Docker itself. Same charset the host script re-checks.
        [[ "$c2" == "exec" ]] || deny "multiplai-docker: '--' is only for exec"
        [[ "$w" == -* ]] && deny "multiplai-docker: guest argument may not start with '-': $w"
        [[ -n "$w" && "${w//[A-Za-z0-9._:=\/@,-]/}" == "" ]] \
          || deny "multiplai-docker: guest argument not allowed: $w"
      elif (( want_instance )); then
        [[ "${w//[a-z0-9-]/}" == "" && "$w" == [a-z0-9]* && ${#w} -le 16 ]] \
          || deny "multiplai-docker: invalid instance name: $w"
        want_instance=0
      elif [[ "$w" == "--" ]]; then
        past_ddash=1
      elif [[ "$w" == "--instance" ]]; then
        want_instance=1
      elif [[ "$w" == -* ]]; then
        deny "multiplai-docker flag not allowed: $w"
      else
        # profile / service / numeric tail — labels, never paths or flags.
        [[ "${w//[a-z0-9._-]/}" == "" && "$w" == [a-z0-9]* && ${#w} -le 64 ]] \
          || deny "multiplai-docker: invalid token: $w"
      fi
      (( i++ ))
    done
    (( want_instance )) && deny "multiplai-docker: --instance needs a value"
    # Same argv[0] pin as multiplai-gh-token: ~/.local/bin is not on the login
    # PATH, and this substitutes a HOST-SIDE CONSTANT — no client string is
    # re-parsed by a shell, so argv still travels as data.
    # Every word above is a label — verb, profile, instance, service, numeric
    # tail, charset-checked guest argv — and the compose file it runs is one the
    # host owner froze in advance. The container cannot express a path here. It
    # also needs the Docker socket, which no workspace jail can contain. Its
    # boundary is the frozen profile plus the argv validation above.
    NEEDS_WS=0
    SANDBOX=0
    words[1]="$HOME/.local/bin/multiplai-docker.py"
    allow=1
    ;;
  curl)
    # A REAL ALLOWLIST. This used to be a deny-list of six flags with a header
    # calling itself an allowlist, and the gap was not academic — verified
    # against curl 8.5.0, with real files created:
    #
    #   --stderr <f>        creates/truncates any path
    #   --libcurl <f>       writes ~1.7 KB including caller-controlled headers
    #   --etag-save/--hsts/--alt-svc <f>   write
    #   --remote-name-all   writes the body into $PWD under a SERVER-chosen
    #                       name (-O was denied; its per-URL twin was not)
    #   -w @<f>, -b <f>, --etag-compare <f>   READ a host file, and this
    #                       branch's stdout goes back to the container
    #   --proxy host:port   arbitrary outbound egress from the Mac while the
    #                       URL argument itself stays loopback
    #
    # Enumerating curl's file-touching flags is a game the gateway loses on the
    # next curl release. So the rule inverts: name the small set the bridge
    # actually needs (the only real caller is the host-browser skill's
    # `curl -s --max-time 5 http://127.0.0.1:9222/json/version`), and refuse
    # every other flag INCLUDING ones curl has not shipped yet.
    #
    # Both spellings are handled — `--flag value` and `--flag=value` — and
    # clustered short flags (`-sS`) are accepted only when every letter in the
    # cluster is value-less, so `-so /etc/x` cannot smuggle an -o past the
    # letter scan.
    seen=0
    i=2
    while (( i <= ${#words} )); do
      raw="${words[i]}"
      u="$raw"; val=""; has_val=0
      case "$u" in
        --*=*) val="${u#*=}"; has_val=1; u="${u%%=*}" ;;
      esac
      case "$u" in
        # Long flags that take NO value.
        --silent|--show-error|--fail|--fail-with-body|--location|--include|\
        --head|--verbose|--insecure|--compressed|--get|--no-buffer|--globoff|\
        --ipv4|--ipv6|--http1.1|--http2|--tcp-nodelay|--disable)
          (( has_val )) && deny "curl flag takes no value: $raw"
          ;;
        # Long flags that take a value. curl_value_ok is deny-by-default, so a
        # flag added here without an arm there is refused rather than waved on.
        --request|--header|--user-agent|--referer|--max-time|--connect-timeout|\
        --retry|--retry-delay|--retry-max-time|--range|--form-string|--url|\
        --data|--data-raw|--data-ascii|--data-binary|--data-urlencode)
          if (( ! has_val )); then
            (( i++ ))
            (( i <= ${#words} )) || deny "curl flag needs a value: $raw"
            val="${words[i]}"
          fi
          curl_value_ok "$u" "$val" || deny "curl value not allowed for $u: $val"
          # --url IS the target when it is used, so it counts towards `seen`.
          [[ "$u" == "--url" ]] && seen=1
          ;;
        --*) deny "curl flag not allowed: $raw" ;;
        -?*)
          rest="${u#-}"
          while [[ -n "$rest" ]]; do
            ch="${rest[1]}"; rest="${rest[2,-1]}"
            case "$ch" in
              s|S|f|L|i|I|v|k|g|N|G|4|6) ;;          # value-less short flags
              X|H|A|e|m|d|r)                          # short flags taking a value
                if [[ -n "$rest" ]]; then
                  val="$rest"; rest=""                # attached form: -m5
                else
                  (( i++ ))
                  (( i <= ${#words} )) || deny "curl flag needs a value: -$ch"
                  val="${words[i]}"
                fi
                curl_value_ok "-$ch" "$val" \
                  || deny "curl value not allowed for -$ch: $val"
                ;;
              *) deny "curl flag not allowed: -$ch (in $raw)" ;;
            esac
          done
          ;;
        *)
          # A non-flag word is a target, and a target must be a loopback URL.
          url_ok "$u" || deny "curl target not allowed: $u"
          seen=1
          ;;
      esac
      (( i++ ))
    done
    # Disable ~/.curlrc, host-side. This is a CONSTANT prepended by the gateway
    # (same shape as the argv[0] pins above — no client string is re-parsed), and
    # it has to be the first argument to take effect. Without it the allowlist
    # above is only half the story: a curlrc line saying `remote-name-all` or
    # `output = …` reintroduces the file write the allowlist just closed.
    words=("${words[1]}" "-q" "${(@)words[2,-1]}")
    # NEEDS_WS=0 is now justified by the allowlist directly above rather than by
    # a survey of dangerous flags: not one entry in it opens a host file for
    # reading or writing, every value form is checked by curl_value_ok, and any
    # unrecognised flag — including a future curl's — is denied. The command can
    # only write to the stdout it inherits, so there is no path for a workspace
    # to bound. (The old justification was the same claim reasoned from a
    # deny-list, which is how it came to be false.)
    #
    # SANDBOX=0 follows from the same fact. Setting it would be free
    # defence-in-depth on paper, but sandbox-exec is macOS-only and untestable
    # from a container: if the profile refused something curl needs, the failure
    # would land on the bridge's own reachability probe. Left at 0 deliberately;
    # revisit only with a host smoke test in hand.
    NEEDS_WS=0
    SANDBOX=0
    (( seen )) && allow=1
    ;;
esac

(( allow )) || deny "command not in allowlist: $CMD"

# --- the filesystem boundary, enforced -------------------------------------
#
# FAIL CLOSED. A path-taking command with no declared workspace is denied
# outright rather than run unconfined. Running unconfined and warning would
# leave the control off by default, which is the state that produced this bug;
# an announced break is the honest shape for a control that exists because the
# previous default was wrong.
if (( NEEDS_WS )) && [ -z "$WS" ]; then
  deny "no workspace declared on this host, so \`$c1\` is not allowed to run.
        This gateway confines path-taking commands to your workspace, and it
        cannot take that path from the container — the side being confined.
        On the Mac, run:
          ./setup.sh          (from your multiplai-kit checkout)
        or declare it by hand:
          mkdir -p ~/.local/state/multiplai
          echo /absolute/path/to/your/workspace > ~/.local/state/multiplai/workspace
        Commands that take no path (command -v, pkill, open -a Simulator,
        multiplai-gh-token, multiplai-docker, curl) keep working without it."
fi

if [ -z "$WORKDIR" ] && [ -n "$WS" ] && (( NEEDS_WS )); then
  # No explicit prefix: pin cwd to the workspace instead of inheriting the
  # host user's HOME. This alone fixes the escape the issue observed —
  # `mlx_whisper --output-dir .` resolved to ~ because that is where the
  # forced command started.
  WORKDIR="$WS"
fi

# CHECK AND USE MUST BE THE SAME cd. This used to probe the directory in a
# subshell (`$(cd -P … && pwd -P)`), compare the result, and then cd again for
# real further down. The workspace is bind-mounted READ-WRITE into the
# container, so between the two calls the container could replace an
# intermediate directory with a symlink pointing out of the workspace; the
# second cd resolves at syscall time and lands wherever the link now points.
# Microseconds wide, infinitely retriable from the container side, and entirely
# unmitigated whenever the sandbox layer is absent. So: cd -P ONCE, then verify
# the cwd we are actually standing in.
if [ -n "$WORKDIR" ]; then
  cd -P -- "$WORKDIR" 2>/dev/null || deny "cd failed: $WORKDIR"
  WORKDIR="$(pwd -P)"
  if [ -n "$WS" ] && [[ "$WORKDIR" != "$WS" && "$WORKDIR" != "$WS"/* ]]; then
    # An explicit `cd` prefix may not leave the workspace. The comparison is
    # between two physically-resolved paths, so a symlink inside the workspace
    # pointing out of it cannot launder the check — and because this reads the
    # cwd we already hold, nothing can be swapped underneath it afterwards.
    deny "cd target is outside the declared workspace.
        requested: $WORKDIR
        workspace: $WS"
  fi
fi

# --- path arguments, enforced ----------------------------------------------
#
# Runs for exactly the branches that did not clear NEEDS_WS — i.e. the ones
# that take paths — so a future branch inherits the check by default instead of
# having to remember it. Candidates are absolute words, `--flag=/abs` and
# `SETTING=/abs` (xcodebuild build settings), plus anything that traverses with
# `..`. Traversing candidates are absolutised against the cwd pinned above with
# zsh's `:a` (lexical: it normalises `..` without needing the path to exist,
# which matters because most of these are OUTPUT paths).
if (( NEEDS_WS )) && [ -n "$WS" ]; then
  i=2
  while (( i <= ${#words} )); do
    w="${words[i]}"
    cand=""
    case "$w" in
      /*)                       cand="$w" ;;
      ..|../*|*/..|*/../*)      cand="$w" ;;
      *=/*)                     cand="${w#*=}" ;;
      *=..|*=../*|*=*/..|*=*/../*) cand="${w#*=}" ;;
    esac
    if [[ -n "$cand" ]]; then
      path_arg_ok "${cand:a}" || deny "path argument is outside the declared workspace: $w
        resolves to: ${cand:a}
        workspace:   $WS
        The bridge confines where an allowlisted command may be pointed, not
        just where it starts. Reads of the system toolchain (/Applications/
        Xcode*.app, /Library/Developer, /usr, /opt/homebrew) and the temporary
        directories are still allowed."
    fi
    (( i++ ))
  done
fi

# Run in a login shell for PATH, but pass argv as data: the inner `exec "$@"`
# receives the already-tokenized words and never re-parses them. Prepend
# inside the inner shell (after login init, so path_helper can't reorder):
#   - nvm's node 24 bin: qmd's better-sqlite3 native module is built for
#     ABI 137 (node 24); homebrew's node on the login PATH drifts ahead on
#     brew upgrade. Any v24.x matches (ABI is per-major). nvm only loads in
#     .zshrc, so login shells never see it otherwise.
#   - ~/.bun/bin: bun-installed tools (qmd itself) live there.
# This widens lookup for allowlisted commands only, not the allowlist.

# The jail itself. `sandbox-exec` denies writes by default and allows them back
# under the declared workspace plus the caches a build genuinely needs; reads
# and network stay open (source, models, config, loopback CDP). `-D` passes the
# workspace as a parameter so the shipped profile carries no hardcoded path.
#
# Prepended INSIDE the argv, before `zsh -lc`, so the whole login shell and
# everything it spawns inherits the sandbox — wrapping only the final command
# would leave a build's child processes outside it.
#
# If the profile is not installed, cwd pinning, the WORKDIR containment check
# and the path-argument check above still apply — but say plainly what is lost,
# because "only this layer is missing" understates it. Without the profile
# nothing stops a build's CHILD processes from writing outside the workspace:
# `swift build` runs manifest and plugin code from the checkout by design
# (README ▸ macOS host bridge), and the checks above bound only the argv this
# gateway saw. Treat a missing profile as "the guardrail is off", not "one of
# three is off".
#
# And it is the state that ships FIRST: install_host_state copies the profile
# from the kit's pinned container/ checkout, so between this repo's tag and the
# kit's CONTAINER_REF bump every host runs without it. See CONFINE_PROFILE at
# the top.
#
# The degradation is still deliberate: a profile that turns out to be wrong for
# one tool can be moved aside on the host without losing the argv-level
# boundary, and the host owner can see which state they are in by whether the
# file exists. It is not a container-reachable switch — same directory, same
# trust model as the workspace declaration itself.
sandbox_prefix=()
if (( SANDBOX )) && [ -n "$WS" ] && [ -f "$CONFINE_PROFILE" ] \
   && [ -x /usr/bin/sandbox-exec ]; then
  # HOME is passed explicitly rather than relied on as a built-in: the profile
  # uses it for the per-tool cache paths, and sandbox-exec only defines the
  # parameters given here.
  sandbox_prefix=(
    /usr/bin/sandbox-exec
      -D "WORKSPACE=$WS"
      -D "HOME=$HOME"
      -f "$CONFINE_PROFILE"
  )
fi

if (( XCSIFT )); then
  # Trusted, fixed pipeline: the user words run as argv data via "$@"; the
  # xcsift stage is a hardcoded constant (never from client input). pipefail so
  # the build/test exit status wins over xcsift's. Can't use the final `exec`
  # here — a pipeline needs the shell to stay alive to wire both stages.
  exec "${sandbox_prefix[@]}" zsh -lc 'path=($HOME/.nvm/versions/node/v24*/bin(N) "$HOME/.bun/bin" $path); set -o pipefail; "$@" 2>&1 | xcsift --format toon --quiet' zsh "${words[@]}"
fi
exec "${sandbox_prefix[@]}" zsh -lc 'path=($HOME/.nvm/versions/node/v24*/bin(N) "$HOME/.bun/bin" $path); exec -- "$@"' zsh "${words[@]}"
