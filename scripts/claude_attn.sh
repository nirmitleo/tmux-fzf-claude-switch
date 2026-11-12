#!/usr/bin/env bash
# Colours a window's entry in the tmux window list when a Claude Code session in that window needs
# you. It sets the window option @claude_attn, which main.tmux puts in window-status-format:
#
#   input  a session waits on you: a permission prompt, a question (AskUserQuestion) or another
#          dialog ("status":"waiting" in its registry file), or a background hub thread that is
#          blocked (its job state). Clears as soon as the session works again.
#   done   a session finished its turn (busy -> idle) while you were not looking at that window.
#          Clears when you open the window, or when that session works again or exits.
#   unset  nothing to show. Needs input wins over done when a window has both.
#
# The source is Claude's own registry: ~/.claude/sessions/<pid>.json (status, statusUpdatedAt,
# kind, tmux "session:@window.%pane", name, jobId) and, for background sessions,
# ~/.claude/jobs/<jobId>/state.json (tempo "blocked" on a permission prompt, state "blocked" when
# the thread ended its turn blocked on a decision). An interactive session maps to the window of
# its pane. A background session (claude --bg, "tmux":null) maps to every window that has a pane
# whose @hub_thread option is the session's name (hub tags its attach panes that way).
#
# "Done" needs no memory of earlier ticks: each window keeps @claude_attn_seen, the newest
# statusUpdatedAt of its sessions at the last moment you had the window in view (the active window
# of a session with a client attached). A window shows done when one of its sessions is idle with a
# newer statusUpdatedAt than that. A session that went idle at start-up (status change within 3 s
# of startedAt) never counts as done. A window seen for the first time records its current newest
# value without showing done, so starting the plugin does not turn every idle window green.
#
#   claude_attn.sh --start   start the loop in the background (main.tmux does this)
#   claude_attn.sh --loop    the loop: one tick every @fzf-claude-attn-interval seconds (default 2)
#                            while this process is the server's @claude_attn_pid
#   claude_attn.sh --tick    one pass (the window-change hooks run this)
#   claude_attn.sh --stop    stop the loop, unset @claude_attn and @claude_attn_seen everywhere
#
# A tick runs 2 tmux commands (one more only when an option changes), one ps, and awk over the
# registry files. It never runs once per window.

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
TAB=$'\t'
TTY_CACHE="" # " pid:startedAt=tty ..." kept across the loop's ticks

# Registry rows "S pid kind status statusUpdatedAt startedAt pane name jobId", tab-separated, "-"
# for a missing value. A file is joined into one string first, so it does not matter whether
# Claude writes it on one line or several.
read_registry() {
  set -- "$CLAUDE_DIR"/sessions/*.json
  [ -e "$1" ] || return 0
  awk '
      function jstr(s, key) {
        if (match(s, "\"" key "\":[ ]*\"[^\"]*\"")) {
          s = substr(s, RSTART, RLENGTH); sub(/^"[^"]*":[ ]*"/, "", s); sub(/"$/, "", s)
          return s == "" ? "-" : s
        }
        return "-"
      }
      function jnum(s, key) {
        if (match(s, "\"" key "\":[ ]*[0-9]+")) { s = substr(s, RSTART, RLENGTH); sub(/^.*:[ ]*/, "", s); return s }
        return "0"
      }
      # The live name is the "name" key followed by nameSource/nameSince; "formerNames" entries
      # also have a "name" key, so a plain match could pick an old one.
      function jname(s) {
        if (match(s, "\"name\":\"[^\"]*\",\"name(Source|Since)\"")) {
          s = substr(s, RSTART, RLENGTH); sub(/^"name":"/, "", s); sub(/","name(Source|Since)"$/, "", s)
          return s == "" ? "-" : s
        }
        return "-"
      }
      FNR == 1 && NR > 1 { emit(buf); buf = "" }
      { buf = buf $0 }
      END { if (NR > 0) emit(buf) }
      function emit(s,   pane, t) {
        t = jstr(s, "tmux"); pane = "-"
        if (t != "-" && match(t, /\.%[0-9]+$/)) pane = substr(t, RSTART + 1)
        printf "S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", jnum(s, "pid"), jstr(s, "kind"), jstr(s, "status"),
          jnum(s, "statusUpdatedAt"), jnum(s, "startedAt"), pane, jname(s), jstr(s, "jobId")
      }' "$@" 2>/dev/null
}

# One pass. With a pid argument (the loop), returns 1 when tmux is gone or another loop took over.
tick() {
  local want_pid=${1:-} panes first sessions jobs="" out line word
  local pid kind st sua started pane name job key t live="" need="" needkeys="" cache=""
  local -a cmds jf
  if ! panes=$(tmux list-panes -a -F "P${TAB}#{pane_id}${TAB}#{pane_tty}${TAB}#{window_id}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{@claude_attn}${TAB}#{@claude_attn_seen}${TAB}#{@hub_thread}${TAB}#{@claude_attn_pid}" 2>/dev/null) || [ -z "$panes" ]; then
    # No session yet ("no current target"): tpm loads the plugin from the config before the first
    # session exists. The server answers show-option then; a dead server does not.
    first=$(tmux show-option -gqv @claude_attn_pid 2>/dev/null) || return 1
    [ -z "$want_pid" ] || [ "$first" = "$want_pid" ] || return 1
    return 0
  fi
  if [ -n "$want_pid" ]; then
    first=${panes%%$'\n'*}
    [ "${first##*"$TAB"}" = "$want_pid" ] || return 1
  fi

  sessions=$(read_registry)
  if [ -n "$sessions" ]; then
    # Live sessions (kill -0, a shell builtin) and the tty of each one that names a pane. A process
    # keeps its tty, so the loop remembers it (key pid:startedAt, in case a pid is reused) and runs
    # ps (slow on macOS: ~45 ms) only when a new session shows up.
    while IFS="$TAB" read -r _ pid kind st sua started pane name job; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
      if [ "$pane" = "-" ]; then
        live="$live$pid -"$'\n'
      else
        key="$pid:$started"
        case "$TTY_CACHE " in
          *" $key="*)
            t=${TTY_CACHE#*" $key="}
            t=${t%% *}
            live="$live$pid $t"$'\n'
            cache="$cache $key=$t"
            ;;
          *)
            need="$need${need:+,}$pid"
            needkeys="$needkeys $key"
            ;;
        esac
      fi
      # Job state of a background session that has an attach pane (its name is a pane's @hub_thread)
      if [ "$kind" = bg ] && [ "$job" != "-" ] && [ -f "$CLAUDE_DIR/jobs/$job/state.json" ]; then
        case "$panes" in *"$TAB$name$TAB"*) jf[${#jf[@]}]="$CLAUDE_DIR/jobs/$job/state.json" ;; esac
      fi
    done <<<"$sessions"
    if [ -n "$need" ]; then
      while read -r pid t; do
        [ -n "$pid" ] || continue
        live="$live$pid $t"$'\n'
        for key in $needkeys; do
          [ "${key%%:*}" = "$pid" ] && cache="$cache $key=$t"
        done
      done <<<"$(ps -o pid=,tty= -p "$need" 2>/dev/null)"
    fi
    TTY_CACHE=$cache
    if [ "${#jf[@]}" -gt 0 ]; then
      # "J jobId state tempo" from the first "state" and "tempo" keys of each file
      jobs=$(awk '
          FNR == 1 { if (NR > 1) out(); id = FILENAME; sub(/\/state\.json$/, "", id); sub(/.*\//, "", id); st = "-"; te = "-" }
          st == "-" && match($0, /"state":[ ]*"[a-z_]+"/) { st = substr($0, RSTART, RLENGTH); gsub(/.*: *"|"/, "", st) }
          te == "-" && match($0, /"tempo":[ ]*"[a-z_]+"/) { te = substr($0, RSTART, RLENGTH); gsub(/.*: *"|"/, "", te) }
          function out() { printf "J\t%s\t%s\t%s\n", id, st, te }
          END { if (NR > 0) out() }' "${jf[@]}" 2>/dev/null)
    fi
  fi

  out=$(printf '%s\n' "$panes" "$sessions" "$live" "$jobs" | awk -F '\t' '
    # live sessions: "<pid> <tty>", tty "ttys009" (macOS), "pts/3" (Linux) or "-" (no pane)
    NF == 1 && $0 ~ /^ *[0-9]+ +[^ ]+ *$/ { split($0, a, " "); live[a[1]] = a[2]; next }
    $1 == "P" {
      w = $4; win[$2] = w; ptty[$2] = $3; wins[w] = 1
      if ($5 == 1 && $6 > 0) viewed[w] = 1
      cur[w] = $7; seen[w] = $8
      if ($9 != "") thr[$9] = thr[$9] " " w
      next
    }
    $1 == "S" { ns++; spid[ns] = $2; skind[ns] = $3; sst[ns] = $4; ssua[ns] = $5; sstart[ns] = $6; spane[ns] = $7; sname[ns] = $8; sjob[ns] = $9; next }
    $1 == "J" { jstate[$2] = $3; jtempo[$2] = $4; next }
    END {
      for (i = 1; i <= ns; i++) {
        if (!(spid[i] in live)) continue # stale registry file
        targets = ""
        p = spane[i]
        if (p != "-" && (p in win)) {
          # The registry has no tmux socket, so the same pane id can exist in another tmux
          # server. A session in one of our panes runs on that pane tty.
          t = live[spid[i]]
          if (ptty[p] == "/dev/" t || ptty[p] == t) targets = win[p]
        }
        if (sname[i] != "-" && (sname[i] in thr)) targets = targets thr[sname[i]]
        if (targets == "") continue
        st = sst[i]; j = sjob[i]
        input = (st == "waiting")
        if (skind[i] == "bg" && j != "-") {
          if (jtempo[j] == "blocked") input = 1
          if (jstate[j] == "blocked" && st == "idle") input = 1
        }
        n = split(targets, tw, " ")
        for (k = 1; k <= n; k++) {
          w = tw[k]
          if (input) inp[w] = 1
          if (ssua[i] + 0 > maxsua[w] + 0) maxsua[w] = ssua[i]
          if (st == "idle" && ssua[i] - sstart[i] > 3000 && ssua[i] + 0 > idlemax[w] + 0) idlemax[w] = ssua[i]
        }
      }
      for (w in wins) {
        s = seen[w]
        if (s == "") ns2 = maxsua[w] + 0
        else if (viewed[w] && maxsua[w] + 0 > s + 0) ns2 = maxsua[w] + 0
        else ns2 = s
        want = ""
        if (inp[w]) want = "input"
        else if (!viewed[w] && s != "" && idlemax[w] + 0 > s + 0) want = "done"
        if (want != cur[w]) {
          if (want == "") print "set-option -wu -t " w " @claude_attn"
          else print "set-option -w -t " w " @claude_attn " want
        }
        if (ns2 "" != s) printf "set-option -w -t %s @claude_attn_seen %.0f\n", w, ns2
      }
    }')
  [ -n "$out" ] || return 0

  # All changes in one tmux call: cmd \; cmd \; ...
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The words are tmux ids, option names and numbers: no spaces or globs
    [ "${#cmds[@]}" -gt 0 ] && cmds[${#cmds[@]}]=';'
    for word in $line; do cmds[${#cmds[@]}]=$word; done
  done <<<"$out"
  tmux "${cmds[@]}" 2>/dev/null
  return 0
}

clear_all() {
  local -a cmds
  local w
  for w in $(tmux list-windows -a -F '#{window_id}' 2>/dev/null | sort -u); do
    [ "${#cmds[@]}" -gt 0 ] && cmds[${#cmds[@]}]=';'
    cmds[${#cmds[@]}]=set-option; cmds[${#cmds[@]}]=-wu; cmds[${#cmds[@]}]=-t; cmds[${#cmds[@]}]=$w; cmds[${#cmds[@]}]=@claude_attn
    cmds[${#cmds[@]}]=';'
    cmds[${#cmds[@]}]=set-option; cmds[${#cmds[@]}]=-wu; cmds[${#cmds[@]}]=-t; cmds[${#cmds[@]}]=$w; cmds[${#cmds[@]}]=@claude_attn_seen
  done
  [ "${#cmds[@]}" -gt 0 ] && tmux "${cmds[@]}" 2>/dev/null
  return 0
}

# Stops the loop named in @claude_attn_pid, if that pid still runs this script's loop (a pid can be
# reused by another program after the loop died).
stop_old_loop() {
  local old cmd
  old=$(tmux show-option -gqv @claude_attn_pid 2>/dev/null)
  [ -n "$old" ] && [ "$old" != "$$" ] || return 0
  cmd=$(ps -o command= -p "$old" 2>/dev/null)
  case "$cmd" in *claude_attn.sh*--loop*) kill "$old" 2>/dev/null ;; esac
  return 0
}

loop() {
  local interval sleeper=""
  interval=$(tmux show-option -gqv @fzf-claude-attn-interval 2>/dev/null)
  case "$interval" in '' | *[!0-9.]* | .*) interval=2 ;; esac
  # One loop per server: the newest one stops the one before it. If two start at once, the one
  # whose pid is not in @claude_attn_pid sees that at its next tick and exits. A dead server ends
  # the loop at its next tick (tmux fails).
  stop_old_loop
  tmux set-option -g @claude_attn_pid "$$" || exit 0
  # sleep in the background + wait, so a kill ends the loop at once and takes the sleep with it
  trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
  while tick "$$"; do
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
  done
  exit 0
}

case "${1:-}" in
  --start)
    nohup "${BASH:-bash}" "$SELF" --loop >/dev/null 2>&1 </dev/null &
    ;;
  --loop) loop ;;
  --tick) tick ;;
  --stop)
    stop_old_loop
    tmux set-option -gu @claude_attn_pid 2>/dev/null
    clear_all
    ;;
  *)
    echo "usage: $0 --start | --loop | --tick | --stop" >&2
    exit 2
    ;;
esac
exit 0
