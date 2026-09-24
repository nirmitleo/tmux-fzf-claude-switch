#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ISO-8601 UTC timestamp (e.g. 2026-09-24T10:37:57.228Z) -> epoch seconds (GNU or BSD date)
function iso_to_epoch {
  local ts="${1%%.*}"
  ts="${ts%Z}"
  date -u -d "${ts}Z" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null
}

# Prints "<pane_id> <seconds> <status>" for every tmux pane running a live Claude Code session,
# where seconds is the time since the last user/assistant message in its transcript and
# status is Claude's own busy/idle state.
function claude_pane_ages {
  local now session_file pid pane_id session_id status transcript ts epoch
  now=$(date +%s)
  for session_file in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$session_file" ] || continue
    pid=$(basename "$session_file" .json)
    kill -0 "$pid" 2>/dev/null || continue # stale registry entry

    # "tmux":"session:@window.%pane" -> %pane
    pane_id=$(sed -nE 's/.*"tmux":"[^"]*\.(%[0-9]+)".*/\1/p' "$session_file")
    session_id=$(sed -nE 's/.*"sessionId":"([^"]+)".*/\1/p' "$session_file")
    status=$(sed -nE 's/.*"status":"([^"]+)".*/\1/p' "$session_file")
    [ -n "$pane_id" ] && [ -n "$session_id" ] || continue

    transcript=$(ls "$CLAUDE_DIR"/projects/*/"$session_id".jsonl 2>/dev/null | head -n 1)
    [ -n "$transcript" ] || continue

    # Transcripts can be many MB; only scan the tail for the last main-thread message
    ts=$(tail -n 300 "$transcript" |
      grep -E '"type":"(user|assistant)"' |
      grep -v '"isSidechain":true' |
      tail -n 1 |
      sed -nE 's/.*"uuid":"[^"]*","timestamp":"([^"]+)".*/\1/p')
    [ -n "$ts" ] || continue

    epoch=$(iso_to_epoch "$ts")
    [ -n "$epoch" ] || continue
    echo "$pane_id $((now - epoch)) ${status:-idle}"
  done
}

# Emits a column-header row followed by one "<session:window.pane>\t<colored display line>" per
# pane in windows named $1. fzf only shows the second field. $2 picks the order:
#   recent  - Claude panes first, most recently active on top (default)
#   session - alphabetical by session name, then window/pane
function list_panes {
  local filter_name=$1
  local sort_mode=${2:-recent}
  tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_index}|#{window_name}|#{pane_title}|#{pane_id}" |
    awk -F'|' -v filter="$filter_name" -v mode="$sort_mode" -v ages="$(claude_pane_ages | tr '\n' ' ')" '
      function fmt_age(s) {
        if (s < 60) return s "s"
        if (s < 3600) return int(s / 60) "m"
        if (s < 86400) return int(s / 3600) "h"
        return int(s / 86400) "d"
      }
      # ages is "pane_id secs status ..." (BSD awk rejects newlines in -v values)
      BEGIN {
        n = split(ages, kv, " ")
        for (i = 1; i + 2 <= n; i += 3) { secs[kv[i]] = kv[i + 1]; state[kv[i]] = kv[i + 2] }
        RESET = "\033[0m"; DIM = "\033[2m"; BOLD = "\033[1m"
        GREEN = "\033[32m"; YELLOW = "\033[33m"
        # 256-colour session palette; avoids plain yellow/green, which the STATUS/LAST MSG columns use
        npal = split("39 170 81 208 141 204 75 180 111 211", pal, " ")
      }
      # Every session is collected (not just filtered ones) so colours match across popups
      !($1 in seen) { seen[$1] = 1; names[++nnames] = $1 }
      $4 == filter {
        count++
        sess[count] = $1; win[count] = $2; pane[count] = $3; title[count] = $5; id[count] = $6
        if (length($1) > width) width = length($1)
      }
      END {
        if (width > 28) width = 28
        if (width < 7) width = 7

        # Colour sessions by their alphabetical rank among all tmux sessions: distinct colours (up to
        # the palette size), identical in every popup, and independent of the sort order
        for (i = 2; i <= nnames; i++) {
          v = names[i]
          for (j = i - 1; j >= 1 && names[j] > v; j--) names[j + 1] = names[j]
          names[j + 1] = v
        }
        for (i = 1; i <= nnames; i++) colour[names[i]] = "\033[38;5;" pal[(i - 1) % npal + 1] "m"

        # Header row, printed before the sorted rows; fzf pins it via --header-lines=1
        printf "\t%s\n", DIM sprintf("%-7s  %-8s  %-" width "s  %-4s  %s", "STATUS", "LAST MSG", "SESSION", "PANE", "TITLE") RESET

        for (i = 1; i <= count; i++) {
          p = id[i]; t = title[i]
          if (p in secs) {
            # Claude prefixes its pane title with a status glyph (✳ or a spinner); the STATUS column replaces it
            sub(/^[^ -~]+ /, "", t)
            s = secs[p]
            busy = (state[p] == "busy")
            status_text = busy ? "working" : "idle"
            status_color = busy ? YELLOW : DIM
            age_text = fmt_age(s) " ago"
            age_color = (s < 600) ? GREEN : (s < 3600) ? "" : DIM
          } else {
            s = 9999999999
            status_text = ""; age_text = ""; status_color = ""; age_color = ""
          }
          place = sprintf("%s %05d %05d", sess[i], win[i], pane[i])
          key = (mode == "session") ? place : sprintf("%010d %s", s, place)

          # Pad before colouring so invisible escape codes do not break alignment
          display = status_color sprintf("%-7s", status_text) RESET "  " \
            age_color sprintf("%-8s", age_text) RESET "  " \
            BOLD colour[sess[i]] sprintf("%-" width "s", substr(sess[i], 1, width)) RESET "  " \
            DIM sprintf("%-4s", win[i] "." pane[i]) RESET "  " t
          printf "%s\t%s:%s.%s\t%s\n", key, sess[i], win[i], pane[i], display
        }
      }' |
    {
      IFS= read -r header
      printf '%s\n' "$header"
      LC_ALL=C sort -t $'\t' -k1,1 | cut -f2-
    }
}

function prompt_new_session {
  local query=$1
  tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
    "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
}

function main {
  local filter_name="${1:-claude}"
  local self="$CURRENT_DIR/$(basename "${BASH_SOURCE[0]}")"
  local sessions
  local query
  local selection
  local retval
  local window_target
  local pane_target

  # ctrl-s flips between the two sort modes; the prompt shows which one is active
  sessions=$(list_panes "$filter_name" recent |
    fzf --exit-0 --print-query --reverse --ansi \
      --delimiter=$'\t' --with-nth=2.. --tiebreak=index \
      --prompt='recent ❯ ' --pointer='▌' --info=inline-right --no-scrollbar --highlight-line \
      --header-lines=1 --header='ctrl-s: switch sort (recent / session)' \
      --with-shell='bash -c' \
      --bind="ctrl-s:transform:if [[ \$FZF_PROMPT == recent* ]]; then echo 'change-prompt(session ❯ )+reload(\"$self\" --list \"$filter_name\" session)'; else echo 'change-prompt(recent ❯ )+reload(\"$self\" --list \"$filter_name\" recent)'; fi" \
      --color='pointer:magenta,prompt:magenta,hl:yellow:bold,hl+:yellow:bold,info:8,header:8')
  retval=$?

  # --print-query output is "<query>\n<selected line>". Split by line number: the query line is
  # usually empty, and `read -a` with IFS=$'\n' would silently drop it and shift the selection.
  query=$(sed -n 1p <<<"$sessions")
  selection=$(sed -n 2p <<<"$sessions")
  # The selected line starts with the hidden "session:window.pane" target field
  pane_target=${selection%%$'\t'*}
  window_target=${pane_target%.*}

  if [ $retval == 0 ]; then
    # Validate the target format before switching; anything else (e.g. just pressing Enter on a
    # typed name that matched nothing) is treated as a request to create a new session
    if [[ "$pane_target" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]]; then
      # Two-step switch: first to session/window, then to specific pane
      tmux switch-client -t "$window_target"
      tmux select-pane -t "$pane_target"
    else
      prompt_new_session "$query"
    fi
  elif [ $retval == 1 ]; then
    prompt_new_session "$query"
  fi
}

# `--list <filter> <sort>` only prints the rows; fzf's ctrl-s reload uses it
if [ "$1" == "--list" ]; then
  list_panes "$2" "$3"
else
  main "$@"
fi
