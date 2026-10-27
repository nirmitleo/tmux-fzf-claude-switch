#!/usr/bin/env bash
# Opens the hub mode popup, sized to the picker's content.
#
#   hub_popup.sh <client> <pane>     (prefix + h runs it with run-shell -b)
#
# @fzf-claude-hub-width / -height (default 90% / 85% of the client) are the MAXIMUM popup size.
# With @fzf-claude-hub-autosize on (the default) and a hub whose `hub help` lists --tmux-size,
# `hub --tmux-size <maxcols> <maxrows>` gets the largest content size (the popup minus its
# border) and prints the size it needs as "<cols> <rows>". The popup is that plus the border,
# never more than the maximum. Anything else (no hub, an older hub, an error, bad output, a hang)
# opens the popup at the maximum size, as before. hub_mode.sh then runs inside the popup.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hub_common.sh
. "$CURRENT_DIR/hub_common.sh"

BORDER=2           # a rounded border takes one cell on each side
SIZE_TIMEOUT=2     # seconds `hub --tmux-size` may take before the maximum is used

function get_tmux_option {
  local value
  value=$(tmux show-option -gqv "$1")
  echo "${value:-$2}"
}

# to_cells <spec> <total>: "<n>%" of total, or a plain number of cells, clamped to 1..total.
# A spec that is neither means the whole client.
function to_cells {
  local spec=$1 total=$2 n
  case "$spec" in
    *%) n=${spec%\%} ;;
    *) n=$spec ;;
  esac
  case "$n" in
    "" | *[!0-9]*) n=$total ;;
    *) n=$((10#$n)) ;;
  esac
  case "$spec" in *%) n=$((total * n / 100)) ;; esac
  [ "$n" -gt "$total" ] && n=$total
  [ "$n" -lt 1 ] && n=1
  echo "$n"
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

# Sets POPUP_W / POPUP_H from `hub --tmux-size`, within 1+BORDER..max. Fails, leaving them
# alone, when hub cannot say.
function hub_content_size {
  local max_w=$1 max_h=$2 hub out cols rows rc
  hub=$(find_hub) || return 1
  hub_supports "$hub" --tmux-size || return 1
  [ "$max_w" -gt "$BORDER" ] && [ "$max_h" -gt "$BORDER" ] || return 1
  # Output goes to a file, not $(...): after a timeout, a child of hub that still holds a pipe
  # open would keep $(...) waiting
  out=$(mktemp "${TMPDIR:-/tmp}/hub-size.XXXXXX") || return 1
  run_with_timeout "$SIZE_TIMEOUT" "$hub" --tmux-size $((max_w - BORDER)) $((max_h - BORDER)) \
    </dev/null >"$out" 2>/dev/null
  rc=$?
  read -r cols rows _ <"$out"
  rm -f "$out"
  [ "$rc" = 0 ] || return 1
  case "$cols$rows" in "" | *[!0-9]*) return 1 ;; esac
  [ -n "$cols" ] && [ -n "$rows" ] || return 1
  cols=$((10#$cols + BORDER))
  rows=$((10#$rows + BORDER))
  [ "$cols" -gt "$max_w" ] && cols=$max_w
  [ "$rows" -gt "$max_h" ] && rows=$max_h
  [ "$cols" -lt $((1 + BORDER)) ] && cols=$((1 + BORDER))
  [ "$rows" -lt $((1 + BORDER)) ] && rows=$((1 + BORDER))
  POPUP_W=$cols
  POPUP_H=$rows
}

function main {
  local client=$1 pane=$2 client_w client_h max_w max_h autosize
  local target=()
  [ -n "$client" ] && target+=(-c "$client")
  [ -n "$pane" ] && target+=(-t "$pane")

  load_claude_hub_from_tmux

  read -r client_w client_h <<<"$(tmux display -p ${target[@]+"${target[@]}"} '#{client_width} #{client_height}')"
  case "$client_w$client_h" in "" | *[!0-9]*) client_w=80; client_h=24 ;; esac

  max_w=$(to_cells "$(get_tmux_option @fzf-claude-hub-width 90%)" "$client_w")
  max_h=$(to_cells "$(get_tmux_option @fzf-claude-hub-height 85%)" "$client_h")
  POPUP_W=$max_w
  POPUP_H=$max_h

  autosize=$(get_tmux_option @fzf-claude-hub-autosize on)
  case "$autosize" in
    off | false | no | 0) ;;
    *) hub_content_size "$max_w" "$max_h" ;;
  esac

  tmux display-popup ${target[@]+"${target[@]}"} -E -b rounded -T " hub " -w "$POPUP_W" -h "$POPUP_H" \
    "\"$CURRENT_DIR/hub_mode.sh\""
}

main "$@"
