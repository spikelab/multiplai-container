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

# Reject every shell metacharacter that could chain, substitute, or redirect.
# After the cd handling above there is no legitimate reason for any of these.
if [[ "$CMD$WORKDIR" == *[\;\|\&\<\>\`\$\(\)]* || "$CMD$WORKDIR" == *$'\n'* ]]; then
  deny "shell metacharacter in command"
fi

# Tokenize honoring quotes only. (z) splits like the shell parser; (Q) then
# strips one level of quoting from each word so a quoted argument arrives at
# the target as its literal value (e.g. `ab type "hello world"` -> one word
# `hello world`, not `hello\ world`). No command/parameter/glob expansion
# happens, and the metachars above are already rejected.
words=(${(Q)${(z)CMD}})
(( ${#words} )) || deny "empty command"
c1="${words[1]}"; c2="${words[2]}"

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
  swift)   [[ "$c2" == (build|run|test|package) ]] && allow=1 ;;
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
exec zsh -lc 'path=($HOME/.nvm/versions/node/v24*/bin(N) "$HOME/.bun/bin" $path); exec -- "$@"' zsh "${words[@]}"
