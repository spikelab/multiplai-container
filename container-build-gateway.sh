#!/bin/zsh
# Gateway script — only allows build-related commands from the container SSH key.
# SSH passes the original command via SSH_ORIGINAL_COMMAND.
#
# Install on macOS host:
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

# Tokenize honoring quotes only. (z) splits like the shell parser but performs
# NO command/parameter/glob expansion, and the metachars above are already gone.
words=(${(z)CMD})
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
  xcodebuild|xcsift|xcodegen|pkill|agent-browser|mlx-whisper|mlx_whisper) allow=1 ;;
  swift)   [[ "$c2" == (build|run|test|package) ]] && allow=1 ;;
  xcrun)   [[ "$c2" == (simctl|xcresulttool|devicectl) ]] && allow=1 ;;
  command) [[ "$c2" == "-v" ]] && allow=1 ;;
  open)    [[ "$c2" == "-a" && "${words[3]}" == Simulator* ]] && allow=1 ;;
  curl)
    seen=0
    i=2
    while (( i <= ${#words} )); do
      u="${words[i]}"
      url_ok "$u" || deny "curl target not allowed: $u"
      [[ "$u" == *://* ]] && seen=1
      (( i++ ))
    done
    (( seen )) && allow=1
    ;;
esac

(( allow )) || deny "command not in allowlist: $CMD"

# Run in a login shell for PATH, but pass argv as data: the inner `exec "$@"`
# receives the already-tokenized words and never re-parses them.
if [ -n "$WORKDIR" ]; then
  cd -- "$WORKDIR" 2>/dev/null || deny "cd failed: $WORKDIR"
fi
exec zsh -lc 'exec -- "$@"' zsh "${words[@]}"
