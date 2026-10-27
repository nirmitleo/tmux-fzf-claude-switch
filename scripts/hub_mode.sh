#!/usr/bin/env bash
# Hub mode: runs the cc-hub picker (`hub --tmux`) inside the popup that prefix + h opens.
# `hub --tmux` switches to (or opens) the tmux pane of the chosen Claude session and exits,
# which closes the popup. If hub is missing or too old, say so and wait for a key, so the
# popup does not vanish before the message can be read.

DIM=$'\033[2m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Popups get the tmux environment, not your shell rc. If CLAUDE_HUB is set there (session
# first, then global) but not here, pick it up. show-environment prints "-NAME" when unset.
function load_claude_hub_from_tmux {
  [ -n "$CLAUDE_HUB" ] && return
  [ -n "$TMUX" ] || return
  local line scope
  for scope in "" "-g"; do
    line=$(tmux show-environment $scope CLAUDE_HUB 2>/dev/null) || continue
    case "$line" in
      CLAUDE_HUB=?*)
        export CLAUDE_HUB="${line#CLAUDE_HUB=}"
        return
        ;;
    esac
  done
}

# Prints the hub executable: the one on PATH, else the default install location
function find_hub {
  local candidate
  candidate=$(command -v hub 2>/dev/null)
  if [ -n "$candidate" ]; then
    echo "$candidate"
    return 0
  fi
  for candidate in "${CLAUDE_HUB:-$HOME/claude-hub}/bin/hub" "$HOME/claude-hub/bin/hub"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

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

  if ! "$hub" help 2>&1 | grep -q -- '--tmux'; then
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
