#!/bin/zsh
# Gateway script — only allows build-related commands from container SSH key.
# SSH passes the original command via SSH_ORIGINAL_COMMAND.
#
# Install on macOS host:
#   cp container-build-gateway.sh ~/.local/bin/container-build-gateway.sh
#   chmod +x ~/.local/bin/container-build-gateway.sh
#
# Then in ~/.ssh/authorized_keys, prefix the container key with:
#   command="~/.local/bin/container-build-gateway.sh" ssh-ed25519 AAAA... container-builds

CMD="$SSH_ORIGINAL_COMMAND"

if [ -z "$CMD" ]; then
  echo "DENIED: interactive shell not allowed" >&2
  exit 1
fi

# Allowlist of command prefixes
case "$CMD" in
  xcodebuild\ *|xcodebuild)                    exec zsh -lc "$CMD" ;;
  swift\ build*|swift\ run*|swift\ test*|swift\ package*)   exec zsh -lc "$CMD" ;;
  xcrun\ simctl\ *)                             exec zsh -lc "$CMD" ;;
  xcrun\ xcresulttool\ *)                       exec zsh -lc "$CMD" ;;
  xcrun\ devicectl\ *)                          exec zsh -lc "$CMD" ;;
  xcsift\ *|xcsift)                             exec zsh -lc "$CMD" ;;
  command\ -v\ *)                               exec zsh -lc "$CMD" ;;
  xcodegen\ *|xcodegen)                         exec zsh -lc "$CMD" ;;
  curl\ *://localhost*|curl\ *://127.0.0.1*|curl\ *://\[::1\]*)
    exec zsh -lc "$CMD" ;;
  pkill\ *|pkill)                                exec zsh -lc "$CMD" ;;
  open\ -a\ Simulator*)                          exec zsh -lc "$CMD" ;;
  mlx-whisper\ *|mlx_whisper\ *)                  exec zsh -lc "$CMD" ;;
  agent-browser\ *|agent-browser)                 exec zsh -lc "$CMD" ;;
  cd\ */\&\&\ *)
    # Allow "cd /path && <allowed cmd>" patterns — validate the command after cd
    AFTER_CD="${CMD#*&& }"
    case "$AFTER_CD" in
      xcodebuild\ *|swift\ *|xcrun\ *|xcsift\ *|command\ *|xcodegen\ *|curl\ *://localhost*|curl\ *://127.0.0.1*|curl\ *://\[::1\]*|pkill\ *|mlx-whisper\ *|mlx_whisper\ *) exec zsh -lc "$CMD" ;;
      *) echo "DENIED: command after cd not allowed: $AFTER_CD" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "DENIED: command not in allowlist: $CMD" >&2
    exit 1
    ;;
esac
