#!/usr/bin/env bash
# Tidies the hub layout of the current pane's project.
#
#   hub_tidy.sh <client> <pane>     (the tidy key, C-k l by default, runs it with run-shell -b)
#
# Finds the hub project of <pane>, then runs `hub tidy <project>`, which puts the project's
# coordinator on the left and its thread panes in one column on the right. What hub prints is
# shown as a tmux message. The project of a pane is, in this order:
#   1. its @hub_thread tag ("<p>--<slug>" or "<p>-coord"; hub sets it on the panes it splits off)
#   2. the @hub_thread of a pane whose @hub_coord is this pane (this pane is a coordinator that
#      hub split thread panes off)
#   3. the name of the Claude Code session running in it ("<p>-coord" or "<p>--<slug>")
#   4. its tmux window name, then its session name, in the same form
# A name only counts when $CLAUDE_HUB/projects/<p> exists. No project, no hub, or a hub whose
# `hub help` does not list `hub tidy`: a short message instead. This script always exits 0, since
# a run-shell that fails puts the pane in view-mode, which eats the next key.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hub_common.sh
. "$CURRENT_DIR/hub_common.sh"

TIDY_TIMEOUT=30   # seconds `hub tidy` may take
CLIENT=""

function message {
  local target=()
  [ -n "$CLIENT" ] && target=(-c "$CLIENT")
  tmux display-message ${target[@]+"${target[@]}"} -d 5000 "$1" 2>/dev/null
}

# project_of_name <name>: prints <p> for "<p>--<slug>" or "<p>-coord" when that hub project exists
function project_of_name {
  local name=$1 project=""
  case "$name" in
    ?*--?*) project=${name%%--*} ;;
    ?*-coord) project=${name%-coord} ;;
  esac
  case "$project" in
    "" | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -d "${CLAUDE_HUB:-$HOME/claude-hub}/projects/$project" ] || return 1
  echo "$project"
}

# The name of the live Claude Code session whose registry entry points at tmux pane $1
function claude_name_of_pane {
  local pane=$1 file pid
  for file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json; do
    [ -f "$file" ] || continue
    grep -q "\"tmux\":\"[^\"]*\\.$pane\"" "$file" 2>/dev/null || continue
    pid=$(basename "$file" .json)
    kill -0 "$pid" 2>/dev/null || continue
    # The live name is followed by nameSource/nameSince; "formerNames" entries are not
    sed -nE 's/.*"name":"([^"]*)","name(Source|Since)".*/\1/p' "$file"
    return 0
  done
  return 1
}

function project_of_pane {
  local pane=$1 tag id thread coord name
  tag=$(tmux display -p -t "$pane" '#{@hub_thread}' 2>/dev/null)
  project_of_name "$tag" && return 0
  while IFS='|' read -r id thread coord; do
    [ "$coord" = "$pane" ] && project_of_name "$thread" && return 0
  done < <(tmux list-panes -a -F '#{pane_id}|#{@hub_thread}|#{@hub_coord}' 2>/dev/null)
  name=$(claude_name_of_pane "$pane")
  [ -n "$name" ] && project_of_name "$name" && return 0
  for name in "$(tmux display -p -t "$pane" '#{window_name}' 2>/dev/null)" \
    "$(tmux display -p -t "$pane" '#{session_name}' 2>/dev/null)"; do
    project_of_name "$name" && return 0
  done
  return 1
}

# Runs a command, killing it after $1 seconds (perl's alarm survives exec; without perl, no limit)
function run_with_timeout {
  local secs=$1
  shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

function main {
  local pane=$2 hub project out text rc
  CLIENT=$1
  load_claude_hub_from_tmux
  [ -n "$pane" ] || pane=$(tmux display -p '#{pane_id}' 2>/dev/null)

  if ! hub=$(find_hub); then
    message "hub is not installed (tidy runs hub tidy)"
    return 0
  fi
  if ! hub_supports "$hub" "hub tidy"; then
    message "update hub: hub tidy not available"
    return 0
  fi
  if ! project=$(project_of_pane "$pane"); then
    message "tidy: this pane is not part of a hub project"
    return 0
  fi

  # Output goes to a file, not $(...): after a timeout, a child of hub that still holds a pipe
  # open would keep $(...) waiting. TMUX_PANE tells hub which pane the key was pressed in.
  out=$(mktemp "${TMPDIR:-/tmp}/hub-tidy.XXXXXX") || return 0
  TMUX_PANE=$pane run_with_timeout "$TIDY_TIMEOUT" "$hub" tidy "$project" </dev/null >"$out" 2>&1
  rc=$?
  # One line for the status line: hub's non-empty lines joined with " · "
  text=$(awk 'NF { sub(/^[ \t]+/, ""); printf "%s%s", (n++ ? " · " : ""), $0 }' "$out")
  rm -f "$out"
  if [ "$rc" = 0 ]; then
    message "${text:-hub tidy $project: done}"
  elif [ "$rc" = 142 ]; then
    message "hub tidy $project did not finish in ${TIDY_TIMEOUT}s"
  else
    message "hub tidy $project failed (exit $rc)${text:+: $text}"
  fi
  return 0
}

main "$@"
exit 0
