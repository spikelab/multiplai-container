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

# Only URLs to the local host over http/https are allowed for curl; file:// and
# any non-loopback host are rejected. Applied to every argument, not just one.
url_ok() {
  case "$1" in
    file:*) return 1 ;;
    *://*) ;;
    *) return 0 ;;   # not a URL argument — nothing to check
  esac
  case "$1" in
    http://localhost|http://localhost[:/]*|https://localhost|https://localhost[:/]*|\
    http://127.0.0.1|http://127.0.0.1[:/]*|https://127.0.0.1|https://127.0.0.1[:/]*|\
    http://\[::1\]|http://\[::1\][:/]*|https://\[::1\]|https://\[::1\][:/]*) return 0 ;;
    *) return 1 ;;
  esac
}

allow=0
case "$c1" in
  xcodebuild|xcsift|xcodegen|mlx-whisper|mlx_whisper) allow=1 ;;
  agent-browser)
    # SECURITY: `ab` drives the host's REAL Chrome, which can open file:/// URLs
    # and read ANY host file Chrome can reach — the exact host-file exfiltration
    # the curl url_ok()/file: guard exists to block. Apply the same file:-scheme
    # block to navigation verbs so `ab open file:///etc/passwd` is denied.
    # (Note: the bridge still lets the container drive the host browser at large;
    # see README ▸ macOS host bridge for the trust caveat.)
    if [[ "$c2" == (open|goto|navigate) ]]; then
      i=3
      while (( i <= ${#words} )); do
        [[ "${(L)words[i]}" == file:* ]] && deny "agent-browser file: URL not allowed: ${words[i]}"
        (( i++ ))
      done
    fi
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
  command) [[ "$c2" == "-v" ]] && allow=1 ;;
  open)    [[ "$c2" == "-a" && "${words[3]}" == Simulator* ]] && allow=1 ;;
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
      Simulator|com.apple.CoreSimulator.*|xcodebuild|swift|swift-frontend|XCTest|testmanagerd) allow=1 ;;
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
    words[1]="$HOME/.local/bin/multiplai-docker.py"
    allow=1
    ;;
  curl)
    # Loopback-only URLs (checked below) plus a flag allowlist: reject any flag
    # that could write/read host files or reach a non-URL transport
    # (-o/-O/--output/-T/--upload-file/--data @file/-K/--config/--unix-socket).
    seen=0
    i=2
    while (( i <= ${#words} )); do
      u="${words[i]}"
      case "$u" in
        -o|-O|--output|--output-dir|--create-dirs|-T|--upload-file|\
        -K|--config|--unix-socket|--abstract-unix-socket|-D|--dump-header|\
        --trace|--trace-ascii|--cookie-jar|-c)
          deny "curl flag not allowed: $u" ;;
        --data*|-d|--data-binary|--data-raw|--data-urlencode)
          # data may not reference a file (@) or be read from stdin (@-)
          next="${words[i+1]:-}"
          [[ "$u" == *=@* || "$next" == @* ]] && deny "curl @file data not allowed"
          ;;
      esac
      url_ok "$u" || deny "curl target not allowed: $u"
      [[ "$u" == *://* ]] && seen=1
      (( i++ ))
    done
    (( seen )) && allow=1
    ;;
esac

(( allow )) || deny "command not in allowlist: $CMD"

# Run in a login shell for PATH, but pass argv as data: the inner `exec "$@"`
# receives the already-tokenized words and never re-parses them. Prepend
# inside the inner shell (after login init, so path_helper can't reorder):
#   - nvm's node 24 bin: qmd's better-sqlite3 native module is built for
#     ABI 137 (node 24); homebrew's node on the login PATH drifts ahead on
#     brew upgrade. Any v24.x matches (ABI is per-major). nvm only loads in
#     .zshrc, so login shells never see it otherwise.
#   - ~/.bun/bin: bun-installed tools (qmd itself) live there.
# This widens lookup for allowlisted commands only, not the allowlist.
if [ -n "$WORKDIR" ]; then
  cd -- "$WORKDIR" 2>/dev/null || deny "cd failed: $WORKDIR"
fi
if (( XCSIFT )); then
  # Trusted, fixed pipeline: the user words run as argv data via "$@"; the
  # xcsift stage is a hardcoded constant (never from client input). pipefail so
  # the build/test exit status wins over xcsift's. Can't use the final `exec`
  # here — a pipeline needs the shell to stay alive to wire both stages.
  exec zsh -lc 'path=($HOME/.nvm/versions/node/v24*/bin(N) "$HOME/.bun/bin" $path); set -o pipefail; "$@" 2>&1 | xcsift --format toon --quiet' zsh "${words[@]}"
fi
exec zsh -lc 'path=($HOME/.nvm/versions/node/v24*/bin(N) "$HOME/.bun/bin" $path); exec -- "$@"' zsh "${words[@]}"
