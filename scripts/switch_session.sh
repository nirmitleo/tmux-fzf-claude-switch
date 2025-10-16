#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function main {
  local sessions
  local session
  local query
  local sess_arr
  local retval
  sessions=$(tmux list-sessions -F "#{session_name}" |
    (grep -v "$(tmux display-message -p '#S')" || echo "") |
    fzf --exit-0 --print-query --reverse)
  retval=$?

  IFS=$'\n' read -rd '' -a sess_arr <<<"$sessions"

  session=${sess_arr[1]}
  query=${sess_arr[0]}

  if [ $retval == 0 ]; then
    if [ "$session" == "" ]; then
      session="$query"
    fi
    tmux switch-client -t "$session"
  elif [ $retval == 1 ]; then
    tmux new-session -d -s "$query" && tmux switch-client -t "$query"
  fi
}
main
