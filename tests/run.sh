#!/usr/bin/env bash
# Tests for the plugin, driven in throwaway tmux servers. Your own tmux server and config are
# never touched: everything runs on the sockets "hubmodetest" and "hubmodetest-outer" with
# -f /dev/null, and both servers are killed at the end.
#
#   bash tests/run.sh          # with the bash on PATH
#   /bin/bash tests/run.sh     # with macOS bash 3.2, which tmux run-shell may use
#
# The plugin scripts are run with the same bash as this file ($BASH). Needs tmux, fzf is not used.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$BASH"
SOCK=hubmodetest
OUTER=hubmodetest-outer
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hubmodetest.XXXXXX")
TMP=$(cd "$TMP" && pwd) # TMPDIR often ends in "/", and the plugin sees the cd+pwd form
PASS=0
FAIL=0
SLEEPERS=""

T() { tmux -L "$SOCK" -f /dev/null "$@"; }
TO() { tmux -L "$OUTER" -f /dev/null "$@"; }

cleanup() {
  T kill-server 2>/dev/null
  TO kill-server 2>/dev/null
  [ -n "$SLEEPERS" ] && kill $SLEEPERS 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/        | /'; }
check() { # check <description> <command...>
  local desc=$1; shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! contains "$@"; }
strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }
# Polls up to ~5s for a command to succeed
wait_for() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "$@" && return 0; sleep 0.25; done; return 1; }

# A fresh inner server with one session; extra args are `set -g` option pairs, then the plugin is loaded
fresh_server() {
  T kill-server 2>/dev/null
  # A server that is still shutting down makes new-session fail ("server exited unexpectedly")
  wait_for T new-session -d -s t -x 200 -y 50 2>/dev/null
  while [ $# -ge 2 ]; do T set -g "$1" "$2"; shift 2; done
  T run-shell "$SH '$ROOT/main.tmux'"
}

# ---- stubs -------------------------------------------------------------------------------
# hub-new: supports --tmux (its help mentions it), logs args + CLAUDE_HUB, shows a marker, exits.
# hub-old: a hub whose help has no --tmux.
mkdir -p "$TMP/stub-new" "$TMP/stub-old" "$TMP/home" "$TMP/nohub"
LOG="$TMP/hub.log"
cat >"$TMP/stub-new/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then echo "  hub --tmux    the picker, for tmux popups"; exit 0; fi
echo "args=\$* CLAUDE_HUB=\${CLAUDE_HUB:-}" >>"$LOG"
echo "STUB-HUB-PICKER"
sleep 1.5
EOF
cat >"$TMP/stub-old/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then echo "  hub ls     list threads"; exit 0; fi
echo "args=\$* (old)" >>"$LOG"
EOF
chmod +x "$TMP/stub-new/hub" "$TMP/stub-old/hub"
BASEPATH="/usr/bin:/bin:/usr/sbin:/sbin"
TMUXDIR=$(dirname "$(command -v tmux)")

echo "== syntax"
for f in "$ROOT/main.tmux" "$ROOT"/scripts/*.sh "$ROOT/tests/run.sh"; do
  check "bash -n $(basename "$f") ($SH)" "$SH" -n "$f"
done

echo "== bindings"
fresh_server
k=$(T list-keys -T prefix h 2>&1)
check "prefix + h bound by default" contains "$k" 'display-popup -E -T " hub " -b rounded -h "85%" -w "90%"'
check "prefix + h runs hub_mode.sh" contains "$k" "$ROOT/scripts/hub_mode.sh"
check "no root-table h by default" test -z "$(T list-keys -T root h 2>/dev/null)"

fresh_server @fzf-claude-hub-key H @fzf-claude-hub-width 70 @fzf-claude-hub-height 60%
k=$(T list-keys -T prefix H 2>&1)
check "@fzf-claude-hub-key/-width/-height change key and size" contains "$k" '-h "60%" -w 70'
check "custom key leaves prefix + h unbound" test -z "$(T list-keys -T prefix h 2>/dev/null)"

fresh_server @fzf-claude-hub-key M-h @fzf-claude-hub-without-prefix true
k=$(T list-keys -T root M-h 2>&1)
check "@fzf-claude-hub-without-prefix true binds in the root table" contains "$k" "hub_mode.sh"
check "  ... and not in the prefix table" test -z "$(T list-keys -T prefix M-h 2>/dev/null)"

fresh_server @fzf-claude-hub-key off
check "@fzf-claude-hub-key off: no hub binding" test -z "$(T list-keys 2>/dev/null | grep hub_mode)"
fresh_server @fzf-claude-hub-key ''
check "@fzf-claude-hub-key '': no hub binding" test -z "$(T list-keys 2>/dev/null | grep hub_mode)"

# The Ctrl+K chord must be exactly what origin/main binds (modulo the plugin path)
mkdir -p "$TMP/base"
if git -C "$ROOT" show origin/main:main.tmux >"$TMP/base/main.tmux" 2>/dev/null; then
  fresh_server
  ours=$( { T list-keys -T root C-k; T list-keys -T fzf-claude-switch; } | sed "s|$ROOT|ROOT|g")
  T kill-server 2>/dev/null; T new-session -d -s t
  T run-shell "$SH '$TMP/base/main.tmux'"
  base=$( { T list-keys -T root C-k; T list-keys -T fzf-claude-switch; } | sed "s|$TMP/base|ROOT|g")
  if [ "$ours" = "$base" ]; then ok "Ctrl+K chord bindings identical to origin/main"
  else bad "Ctrl+K chord bindings identical to origin/main" "$(diff <(echo "$base") <(echo "$ours"))"; fi
  check "  ... C-k enters the chord table, c/s/i/t open popups" test "$(printf '%s\n' "$ours" | grep -c 'popup')" = 4
else
  bad "could not read origin/main:main.tmux (git fetch?)"
fi

echo "== hub_mode.sh, run directly"
: >"$LOG"
out=$(env -i HOME="$TMP/home" PATH="$TMP/stub-new:$BASEPATH" "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null 2>&1)
check "hub with --tmux on PATH: execs 'hub --tmux'" contains "$(cat "$LOG")" "args=--tmux"
check "  ... its output is the picker's" contains "$out" "STUB-HUB-PICKER"

: >"$LOG"
out=$(env -i HOME="$TMP/home" PATH="$TMP/stub-old:$BASEPATH" "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null 2>&1)
rc=$?
check "hub without --tmux: says 'update hub'" contains "$out" "update hub"
check "  ... waits for a key and exits 1 without running hub" test "$rc" = 1 -a ! -s "$LOG"
check "  ... and says how to close" contains "$out" "press any key"

out=$(env -i HOME="$TMP/home" PATH="$BASEPATH" "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null 2>&1)
rc=$?
check "no hub at all: says it is not installed" contains "$out" "hub is not installed"
check "  ... explains what hub is" contains "$out" "cc-hub picker"
check "  ... exits 1" test "$rc" = 1

mkdir -p "$TMP/home2/claude-hub/bin"; cp "$TMP/stub-new/hub" "$TMP/home2/claude-hub/bin/hub"
: >"$LOG"
env -i HOME="$TMP/home2" PATH="$BASEPATH" "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null >/dev/null 2>&1
check "hub not on PATH but at ~/claude-hub/bin/hub: uses it" contains "$(cat "$LOG")" "args=--tmux"

mkdir -p "$TMP/hubroot/bin"; cp "$TMP/stub-new/hub" "$TMP/hubroot/bin/hub"
: >"$LOG"
env -i HOME="$TMP/home" PATH="$BASEPATH" CLAUDE_HUB="$TMP/hubroot" "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null >/dev/null 2>&1
check "hub at \$CLAUDE_HUB/bin/hub: uses it and passes CLAUDE_HUB" contains "$(cat "$LOG")" "args=--tmux CLAUDE_HUB=$TMP/hubroot"

fresh_server
T set-environment -g CLAUDE_HUB /from/tmux/global
TMUX_VAL="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
: >"$LOG"
env -i HOME="$TMP/home" PATH="$TMP/stub-new:$BASEPATH:$TMUXDIR" TMUX="$TMUX_VAL" \
  "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null >/dev/null 2>&1
check "CLAUDE_HUB set only in the tmux environment is passed to hub" \
  contains "$(cat "$LOG")" "CLAUDE_HUB=/from/tmux/global"
: >"$LOG"
env -i HOME="$TMP/home" PATH="$TMP/stub-new:$BASEPATH:$TMUXDIR" TMUX="$TMUX_VAL" CLAUDE_HUB=/from/shell \
  "$SH" "$ROOT/scripts/hub_mode.sh" </dev/null >/dev/null 2>&1
check "  ... but an exported CLAUDE_HUB wins" contains "$(cat "$LOG")" "CLAUDE_HUB=/from/shell"

echo "== prefix + h through a real client (nested throwaway servers)"
# The inner server's global PATH decides which stub the popup finds. An outer server's pane
# runs a client attached to the inner one, so send-keys to it is a real key press.
T kill-server 2>/dev/null
env -i HOME="$TMP/home" PATH="$TMP/stub-new:$BASEPATH:$TMUXDIR" TERM=xterm-256color \
  tmux -L "$SOCK" -f /dev/null new-session -d -s t -x 120 -y 40
T run-shell "$SH '$ROOT/main.tmux'"
# Popups run through default-shell -c; a login shell's rc (zshenv, ...) could rebuild PATH
T set -g default-shell /bin/sh
TO kill-server 2>/dev/null
TO new-session -d -s o -x 120 -y 40 "env -u TMUX tmux -L $SOCK attach -t t"
attached() { test -n "$(T list-clients 2>/dev/null)"; }
wait_for attached || bad "inner client did not attach"
screen() { TO capture-pane -p -t o; }
popup_open() { contains "$(screen)" "$1"; }
popup_closed() { ! contains "$(screen)" "$1"; }

: >"$LOG"
TO send-keys -t o C-b h
check "prefix + h opens a ' hub ' popup running hub --tmux" wait_for popup_open "STUB-HUB-PICKER"
check "  ... popup is titled ' hub '" contains "$(screen)" " hub "
check "  ... hub got --tmux" contains "$(cat "$LOG")" "args=--tmux"
check "  ... popup closes when hub exits" wait_for popup_closed "STUB-HUB-PICKER"

T set-environment -g PATH "$TMP/stub-old:$BASEPATH"
: >"$LOG"
TO send-keys -t o C-b h
check "old hub: popup shows 'update hub'" wait_for popup_open "update hub"
sleep 0.5
check "  ... and stays open" popup_open "update hub"
TO send-keys -t o q
check "  ... until a key is pressed" wait_for popup_closed "update hub"

T set-environment -g PATH "$BASEPATH"
TO send-keys -t o C-b h
check "no hub: popup shows the install message" wait_for popup_open "hub is not installed"
TO send-keys -t o Enter
check "  ... and closes on a key" wait_for popup_closed "hub is not installed"
TO kill-server 2>/dev/null

echo "== hub tag in the Claude switcher (--list)"
# Fake Claude registry + hub root. Every session file needs a live pid, a pane in a window
# named "claude", and a transcript with a timestamped user message, or it is not a Claude row.
CFG="$TMP/claude"; HUBROOT="$TMP/hubroot2"
mkdir -p "$CFG/sessions" "$CFG/projects/p" "$HUBROOT/projects/cc-hub" "$HUBROOT/projects/ent/files"
fresh_server
T rename-window -t t claude
for n in 1 2 3 4 5; do T split-window -t t:claude; T select-layout -t t:claude tiled; done
T new-window -d -t t -n server
# Two hours ago, so the LAST MSG column ("2h ago") cannot tick between two runs being compared
OLD=$(($(date +%s) - 7200))
NOW_ISO=$(date -u -r "$OLD" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$OLD" +%Y-%m-%dT%H:%M:%S.000Z)
i=0
make_session() { # make_session <pane index> <json extra fields> <title>
  local pane_id sid pid
  pane_id=$(T display -p -t "t:claude.$1" '#{pane_id}')
  sleep 600 & pid=$!; disown "$pid"; SLEEPERS="$SLEEPERS $pid"
  i=$((i + 1)); sid="0000000$i-aaaa-bbbb-cccc-dddddddddddd"
  printf '{"pid":%s,"sessionId":"%s",%s,"tmux":"t:@1.%s","status":"idle","updatedAt":1}\n' \
    "$pid" "$sid" "$2" "$pane_id" >"$CFG/sessions/$pid.json"
  printf '{"type":"user","uuid":"u%s","timestamp":"%s"}\n' "$i" "$NOW_ISO" >"$CFG/projects/p/$sid.jsonl"
  T select-pane -t "t:claude.$1" -T "$3"
}
make_session 0 '"cwd":"/w","name":"cc-hub-coord","nameSource":"peer"' "coord title"
make_session 1 '"cwd":"/w","name":"cc-hub--tmux-hub-mode","nameSince":1,"agent":"thread-worker"' "thread title"
make_session 2 '"cwd":"/w","name":"plain session","nameSince":1,"formerNames":[{"name":"cc-hub--old","until":1}]' "former title"
make_session 3 '"cwd":"/w","name":"foo--bar","nameSource":"peer"' "nodir title"
make_session 4 "\"cwd\":\"$HUBROOT/projects/ent/files\",\"name\":\"x\",\"nameSource\":\"derived\"" "cwd title"
T select-pane -t t:claude.5 -T "not claude"

TMUX_VAL="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
list() { # list <script> [CLAUDE_HUB]
  env TMUX="$TMUX_VAL" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_HUB="${2:-$HUBROOT}" "$SH" "$1" --list claude recent
}
rows=$(list "$ROOT/scripts/switch_session_window_pane.sh" | strip_ansi)
row() { printf '%s\n' "$rows" | grep -F "$1"; }
check "coordinator row tagged hub:cc-hub" contains "$(row 'coord title')" "hub:cc-hub  coord title"
check "thread row tagged hub:cc-hub/tmux-hub-mode" contains "$(row 'thread title')" "hub:cc-hub/tmux-hub-mode  thread title"
check "session under \$CLAUDE_HUB/projects/ent tagged hub:ent" contains "$(row 'cwd title')" "hub:ent  cwd title"
check "formerNames are ignored (no tag)" lacks "$(row 'former title')" "hub:"
check "a--b name without a hub project: no tag" lacks "$(row 'nodir title')" "hub:"
check "non-Claude pane: no tag" lacks "$(row 'not claude')" "hub:"
check "the tag is dim" contains "$(list "$ROOT/scripts/switch_session_window_pane.sh" | grep -F 'thread title')" \
  $'\033[2mhub:cc-hub/tmux-hub-mode\033[0m  thread title'

# Against origin/main's switcher: same rows, same order, once the tags are taken out
if git -C "$ROOT" show origin/main:scripts/switch_session_window_pane.sh >"$TMP/base/switch.sh" 2>/dev/null; then
  base=$(list "$TMP/base/switch.sh")
  ours=$(list "$ROOT/scripts/switch_session_window_pane.sh" | sed $'s/\033\\[2mhub:[^\033]*\033\\[0m  //')
  check "rows, columns and order unchanged apart from the tag" test "$base" = "$ours"
  ours=$(list "$ROOT/scripts/switch_session_window_pane.sh" "$TMP/no-such-hub")
  check "hub not installed: output identical to origin/main" test "$base" = "$ours"
  ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
  t0=$(ms); for n in 1 2 3 4 5 6 7 8 9 10; do list "$TMP/base/switch.sh" >/dev/null; done; t1=$(ms)
  for n in 1 2 3 4 5 6 7 8 9 10; do list "$ROOT/scripts/switch_session_window_pane.sh" >/dev/null; done; t2=$(ms)
  echo "  info  --list with 5 Claude sessions, mean of 10: origin/main $(((t1 - t0) / 10))ms, this branch $(((t2 - t1) / 10))ms"
fi

echo
echo "$PASS passed, $FAIL failed ($SH: $("$SH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" = 0 ]
