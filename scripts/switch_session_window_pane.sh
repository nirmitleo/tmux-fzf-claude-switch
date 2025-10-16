#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function main {
  local sessions
  local query
  local sess_arr
  local retval
  local window_target
  local pane_target

  sessions=$(tmux list-panes -a -F "#{session_name}:#{window_index}:#{pane_index}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}" | \
    grep '|claude|' | \
    awk -F'|' '{split($1, parts, ":"); print parts[1] ":" parts[2] ":[" parts[3] "]: " $3 " [" $4 "]"}' | \
    fzf --exit-0 --print-query --reverse)
  retval=$?

  IFS=$'\n' read -rd '' -a sess_arr <<<"$sessions"

  window_target=$(echo ${sess_arr[1]} | sed 's/:\[.*//g')
  pane_target=$(echo ${sess_arr[1]} | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/')
  query=${sess_arr[0]}

  if [ $retval == 0 ]; then
    # If user didn't select anything (just pressed Enter), use the query
    if [ "$window_target" == "" ]; then
      window_target=$(echo "$query" | sed 's/:\[.*//g')
      pane_target=$(echo "$query" | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/')
    fi

    # Validate window_target has session:window format before attempting switch
    # If user typed a new session name like "foo" or "foo.bar", redirect to create-new-session
    if [[ "$window_target" =~ ^[^:]+:[0-9]+$ ]]; then
      # Two-step switch: first to session/window, then to specific pane
      tmux switch-client -t "$window_target"

      # Only select pane if we have a valid pane target (must match session:window.pane pattern)
      # Regex validates: session_name:window_index.pane_index (e.g., "dictaphone:0.1")
      if [[ "$pane_target" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]]; then
        tmux select-pane -t "$pane_target"
      fi
    else
      # Invalid format: user typed a new session name, prompt to create it
      tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
        "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
    fi
  elif [ $retval == 1 ]; then
    tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
      "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
  fi
}
main
