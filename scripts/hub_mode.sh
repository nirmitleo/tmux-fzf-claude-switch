#!/usr/bin/env bash
# Hub mode: runs the cc-hub picker (`hub --tmux`) inside the popup that prefix + h opens.
# `hub --tmux` switches to (or opens) the tmux pane of the chosen Claude session and exits,
# which closes the popup. If hub is missing or too old, say so and wait for a key, so the
# popup does not vanish before the message can be read.

DIM=$'\033[2m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hub_common.sh
. "$CURRENT_DIR/hub_common.sh"

# Prints its arguments as dim lines, then waits for any key
function show_and_wait {
  local line
  echo
  for line in "$@"; do
    printf '  %s%s%s\n' "$DIM" "$line" "$RESET"
  done
  echo
  printf '  %spress any key to close%s' "$DIM" "$RESET"
  read -rsn1 _ </dev/tty 2>/dev/null || read -rsn1 _
  echo
}

function main {
  local hub
  load_claude_hub_from_tmux

  if ! hub=$(find_hub); then
    show_and_wait \
      "${BOLD}hub is not installed${RESET}${DIM}" \
      "" \
      "Hub mode opens the cc-hub picker: your Claude Code projects, their" \
      "coordinators and threads. Install hub so that \`hub\` is on your PATH" \
      "(or at ~/claude-hub/bin/hub), then press prefix + h again."
    exit 1
  fi

  if ! hub_supports "$hub" --tmux; then
    show_and_wait \
      "${BOLD}update hub${RESET}${DIM}" \
      "" \
      "Hub mode needs \`hub --tmux\`, which this hub does not support:" \
      "$hub" \
      "Update hub, then press prefix + h again."
    exit 1
  fi

  exec "$hub" --tmux
}

main "$@"
