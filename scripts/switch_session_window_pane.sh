#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HUB_PROJECTS="${CLAUDE_HUB:-$HOME/claude-hub}/projects"

# ISO-8601 UTC timestamp (e.g. 2026-09-24T10:37:57.228Z) -> epoch seconds (GNU or BSD date)
function iso_to_epoch {
  local ts="${1%%.*}"
  ts="${ts%Z}"
  date -u -d "${ts}Z" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null
}

# Sets HUB_TAG to the cc-hub tag for a Claude session, or "-" when it is not part of a hub project
# (a variable rather than output, so the per-session loop does not fork a subshell):
#   hub:<project>         the project's coordinator (session named "<project>-coord")
#   hub:<project>/<slug>  one of its threads (session named "<project>--<slug>")
#   hub:<project>         any other session whose cwd is inside $CLAUDE_HUB/projects/<project>
# A tag is only given when $CLAUDE_HUB/projects/<project> exists, so random "a--b" names are
# ignored and nothing is tagged when hub is not installed.
# HUB_ARCHIVED is set to "a" when the project is archived ($CLAUDE_HUB/projects/<project>/.archived
# exists; only its existence matters, `hub archive` / `hub unarchive` create and remove it), else "-".
function hub_tag {
  local name=$1 cwd=$2 project="" slug=""
  case "$name" in
    ?*--?*) project=${name%%--*}; slug=${name#*--} ;;
    ?*-coord) project=${name%-coord} ;;
  esac
  if [ -z "$project" ] || [ ! -d "$HUB_PROJECTS/$project" ]; then
    slug=""
    case "$cwd" in
      "$HUB_PROJECTS"/?*) project=${cwd#"$HUB_PROJECTS"/}; project=${project%%/*} ;;
      *) project="" ;;
    esac
  fi
  case "$project$slug" in
    *[!A-Za-z0-9._-]*) project="" ;; # the tag must stay one space-free token
  esac
  if [ -n "$project" ] && [ -d "$HUB_PROJECTS/$project" ]; then
    HUB_TAG="hub:$project${slug:+/$slug}"
    if [ -e "$HUB_PROJECTS/$project/.archived" ]; then HUB_ARCHIVED=a; else HUB_ARCHIVED=-; fi
  else
    HUB_TAG="-"
    HUB_ARCHIVED=-
  fi
}

# Prints "<pane_id> <seconds> <status> <hub tag> <archived>" for every tmux pane running a live
# Claude Code session, where seconds is the time since the last user/assistant message in its
# transcript, status is Claude's own busy/idle state, the hub tag comes from hub_tag ("-" for none)
# and archived is "a" when that hub project is archived ("-" otherwise).
function claude_pane_ages {
  local now session_file pid pane_id session_id status transcript ts epoch name cwd tag archived line
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

    tag="-"; archived="-"
    if [ -d "$HUB_PROJECTS" ]; then
      # One sed prints "n<name>" and "c<cwd>". The live name is the "name" key followed by
      # nameSource/nameSince; a greedy match on "name" alone could pick one from "formerNames".
      name=""; cwd=""
      while IFS= read -r line; do
        case "$line" in n*) name=${line#n} ;; c*) cwd=${line#c} ;; esac
      done < <(sed -nE 'h; s/.*"name":"([^"]*)","name(Source|Since)".*/n\1/p; g; s/.*"cwd":"([^"]*)".*/c\1/p' "$session_file")
      hub_tag "$name" "$cwd"
      tag=$HUB_TAG; archived=$HUB_ARCHIVED
    fi

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
    echo "$pane_id $((now - epoch)) ${status:-idle} $tag $archived"
  done
}

# Emits a column-header row followed by one "<session:window.pane>\t<colored display line>" per
# pane in windows named $1. fzf only shows the second field. $2 picks the order:
#   recent  - Claude panes first, most recently active on top (default)
#   session - alphabetical by session name, then window/pane
# $3 is "on" to also list Claude panes of archived hub projects (dimmed and tagged "archived");
# by default ("off") they are left out.
function list_panes {
  local filter_name=$1
  local sort_mode=${2:-recent}
  local show_archived=${3:-off}
  tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_index}|#{window_name}|#{pane_title}|#{pane_id}" |
    awk -F'|' -v filter="$filter_name" -v mode="$sort_mode" -v show_archived="$show_archived" \
      -v ages="$(claude_pane_ages | tr '\n' ' ')" '
      function fmt_age(s) {
        if (s < 60) return s "s"
        if (s < 3600) return int(s / 60) "m"
        if (s < 86400) return int(s / 3600) "h"
        return int(s / 86400) "d"
      }
      # ages is "pane_id secs status hubtag archived ..." (BSD awk rejects newlines in -v values)
      BEGIN {
        n = split(ages, kv, " ")
        for (i = 1; i + 4 <= n; i += 5) {
          secs[kv[i]] = kv[i + 1]; state[kv[i]] = kv[i + 2]
          if (kv[i + 3] != "-") hub[kv[i]] = kv[i + 3]
          if (kv[i + 4] == "a") archived[kv[i]] = 1
        }
        RESET = "\033[0m"; DIM = "\033[2m"; BOLD = "\033[1m"
        GREEN = "\033[32m"; YELLOW = "\033[33m"
        # 256-colour session palette; avoids plain yellow/green, which the STATUS/LAST MSG columns use
        npal = split("39 170 81 208 141 204 75 180 111 211", pal, " ")
      }
      # Every session is collected (not just filtered ones) so colours match across popups
      !($1 in seen) { seen[$1] = 1; names[++nnames] = $1 }
      # Panes of archived hub projects are dropped here, before they count towards the SESSION
      # width; the colour list above still has their sessions, so other colours do not shift
      $4 == filter && (show_archived == "on" || !($6 in archived)) {
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
            # cc-hub sessions get a dim tag at the start of the title, where it is not cut off.
            # Archived ones (only listed when asked for) are dimmed whole and say so in the tag.
            if (p in archived) t = DIM hub[p] " archived  " t RESET
            else if (p in hub) t = DIM hub[p] RESET "  " t
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

# fzf prompt for a sort mode and archived state: "recent ❯ ", "session +archived ❯ ", ...
function prompt_for {
  local sort_mode=$1 show_archived=$2
  if [ "$show_archived" = on ]; then
    printf '%s +archived ❯ ' "$sort_mode"
  else
    printf '%s ❯ ' "$sort_mode"
  fi
}

# `--transform <sort|archived> <filter>`: run by fzf's ctrl-s / ctrl-r. Reads the current state from
# $FZF_PROMPT, flips one half of it and prints the fzf action that shows the new state and reloads
# the rows. The prompt is the only state, so each key keeps what the other one chose.
function transform {
  local what=$1 filter_name=$2
  local self="$CURRENT_DIR/$(basename "${BASH_SOURCE[0]}")"
  local sort_mode=recent show_archived=off
  case "$FZF_PROMPT" in session*) sort_mode=session ;; esac
  case "$FZF_PROMPT" in *+archived*) show_archived=on ;; esac
  case "$what" in
    sort) if [ "$sort_mode" = recent ]; then sort_mode=session; else sort_mode=recent; fi ;;
    archived) if [ "$show_archived" = on ]; then show_archived=off; else show_archived=on; fi ;;
  esac
  printf 'change-prompt(%s)+reload("%s" --list "%s" %s %s)\n' \
    "$(prompt_for "$sort_mode" "$show_archived")" "$self" "$filter_name" "$sort_mode" "$show_archived"
}

# @fzf-claude-show-archived: "on" lists archived hub projects' panes when the popup opens
function show_archived_default {
  case "$(tmux show-option -gqv @fzf-claude-show-archived 2>/dev/null)" in
    on | true | yes | 1) echo on ;;
    *) echo off ;;
  esac
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
  local show_archived=off
  local header='ctrl-s: switch sort (recent / session)'
  local -a archived_bind=() exit_0=(--exit-0)
  local rows

  # ctrl-s flips between the two sort modes and, with hub installed, ctrl-r shows or hides archived
  # hub projects; the prompt shows which mode is active
  if [ -d "$HUB_PROJECTS" ]; then
    show_archived=$(show_archived_default)
    header="$header  ctrl-r: show/hide archived"
    archived_bind=(--bind="ctrl-r:transform:\"$self\" --transform archived \"$filter_name\"")
  fi
  rows=$(list_panes "$filter_name" recent "$show_archived")
  # --exit-0 closes the popup at once when nothing is listed. If that is only because every row is
  # archived, keep it open, so ctrl-r (and the hint in the header) can still show them.
  if [ "$show_archived" = off ] && [ "$(printf '%s\n' "$rows" | wc -l)" -le 1 ] &&
    [ -n "${archived_bind[*]+set}" ] && [ "$(list_panes "$filter_name" recent on | wc -l)" -gt 1 ]; then
    exit_0=()
  fi
  sessions=$(printf '%s\n' "$rows" |
    fzf ${exit_0[@]+"${exit_0[@]}"} --print-query --reverse --ansi \
      --delimiter=$'\t' --with-nth=2.. --tiebreak=index \
      --prompt="$(prompt_for recent "$show_archived")" --pointer='▌' --info=inline-right --no-scrollbar --highlight-line \
      --header-lines=1 --header="$header" \
      --with-shell='bash -c' \
      --bind="ctrl-s:transform:\"$self\" --transform sort \"$filter_name\"" \
      ${archived_bind[@]+"${archived_bind[@]}"} \
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

# `--list <filter> <sort> [on|off]` only prints the rows (on: archived hub projects too); fzf's
# reloads use it. `--transform` is the ctrl-s / ctrl-r handler.
if [ "$1" == "--list" ]; then
  list_panes "$2" "$3" "$4"
elif [ "$1" == "--transform" ]; then
  transform "$2" "$3"
else
  main "$@"
fi
