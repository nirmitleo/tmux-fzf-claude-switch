# Shared by hub_popup.sh and hub_mode.sh (sourced, not run).

# Popups and run-shell get the tmux environment, not your shell rc. If CLAUDE_HUB is set there
# (session first, then global) but not here, pick it up. show-environment prints "-NAME" when unset.
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

# Prints the hub executable: the one on PATH, else the default install locations
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

# hub_supports <hub> <flag>: true when `hub help` lists the flag (e.g. --tmux, --tmux-size). The
# flag must end at a non-flag character, so "--tmux-size" alone does not count as "--tmux".
function hub_supports {
  "$1" help 2>&1 | grep -qE -- "$2([^A-Za-z0-9_-]|\$)"
}
