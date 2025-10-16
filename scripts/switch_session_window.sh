#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function main {
  local sessions
  local session
  local query
  local sess_arr
  local retval
  sessions=$(tmux list-panes -a -F "#{session_name}:#{window_index}:#{pane_index}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}" | \
    grep '|claude|' | \
    awk -F'|' '{split($1, parts, ":"); print parts[1] ":" parts[2] ":[" parts[3] "]: " $3 " [" $4 "]"}' | \
    fzf --exit-0 --print-query --reverse)
  retval=$?

  IFS=$'\n' read -rd '' -a sess_arr <<<"$sessions"

  session=$(echo ${sess_arr[1]} | sed 's/:\[.*//g')
  query=${sess_arr[0]}

  if [ $retval == 0 ]; then
    if [ "$session" == "" ]; then
        session=$(echo "$query" | sed 's/:\[.*//g')
    fi
    tmux switch-client -t "$session"
  elif [ $retval == 1 ]; then
    tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
      "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
  fi
}
main
