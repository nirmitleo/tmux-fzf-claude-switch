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
# hub-new:   supports --tmux (its help mentions it) but not --tmux-size. Logs args, CLAUDE_HUB and
#            its terminal size ("tty=<rows> <cols>": the popup minus its border), shows a marker, exits.
# hub-sized: also supports --tmux-size; what that prints is set by $TMP/size-mode (ok: the
#            contents of $TMP/size-out, err: exit 3, garbage, hang).
# hub-old:   a hub whose help has no --tmux.
mkdir -p "$TMP/stub-new" "$TMP/stub-sized" "$TMP/stub-old" "$TMP/home" "$TMP/nohub"
LOG="$TMP/hub.log"
cat >"$TMP/stub-new/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then echo "  hub --tmux    the picker, for tmux popups"; exit 0; fi
echo "args=\$* CLAUDE_HUB=\${CLAUDE_HUB:-}" >>"$LOG"
echo "tty=\$(stty size </dev/tty 2>/dev/null)" >>"$LOG"
echo "STUB-HUB-PICKER"
sleep 1.5
EOF
cat >"$TMP/stub-sized/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then printf '  hub --tmux           the picker\n  hub --tmux-size C R  its size\n'; exit 0; fi
if [ "\$1" = --tmux-size ]; then
  echo "size-args=\$2 \$3" >>"$LOG"
  case "\$(cat "$TMP/size-mode")" in
    ok) cat "$TMP/size-out" ;;
    err) echo boom >&2; exit 3 ;;
    garbage) echo "big tall" ;;
    hang) sleep 5; echo "60 8" ;;
  esac
  exit 0
fi
echo "args=\$* CLAUDE_HUB=\${CLAUDE_HUB:-}" >>"$LOG"
echo "tty=\$(stty size </dev/tty 2>/dev/null)" >>"$LOG"
echo "STUB-HUB-PICKER"
sleep 1.5
EOF
cat >"$TMP/stub-old/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then echo "  hub ls     list threads"; exit 0; fi
echo "args=\$* (old)" >>"$LOG"
EOF
# fzf (for the C-k c / s switcher popups): shows a marker with its prompt on the popup, logs how
# many rows it got and its arguments, then exits 130 as if Esc was pressed, so nothing is switched
# or created.
cat >"$TMP/stub-new/fzf" <<EOF
#!/bin/sh
n=\$(wc -l | tr -d ' ')
echo "fzf-rows=\$n" >>"$LOG"
echo "fzf-args=\$*" >>"$LOG"
echo "STUB-FZF-SWITCHER" >/dev/tty
sleep 1.5
exit 130
EOF
chmod +x "$TMP/stub-new/hub" "$TMP/stub-sized/hub" "$TMP/stub-old/hub" "$TMP/stub-new/fzf"
BASEPATH="/usr/bin:/bin:/usr/sbin:/sbin"
TMUXDIR=$(dirname "$(command -v tmux)")

echo "== syntax"
for f in "$ROOT/main.tmux" "$ROOT"/scripts/*.sh "$ROOT/tests/run.sh"; do
  check "bash -n $(basename "$f") ($SH)" "$SH" -n "$f"
done

echo "== bindings"
CHORD=fzf-claude-switch
hub_keys() { T list-keys 2>/dev/null | grep hub_; } # every hub binding, in any table
fresh_server
k=$(T list-keys -T $CHORD h 2>&1)
check "C-k h: hub key bound in the chord table by default, to run-shell -b" contains "$k" "run-shell -b"
check "  ... running hub_popup.sh with this client and pane" \
  contains "$k" "$ROOT/scripts/hub_popup.sh\\\" '#{client_name}' '#{pane_id}'"
check "  ... prefix + h is not bound" test -z "$(T list-keys -T prefix h 2>/dev/null)"
check "  ... no root-table h" test -z "$(T list-keys -T root h 2>/dev/null)"
check "  ... exactly one hub binding" test "$(hub_keys | wc -l)" -eq 1

fresh_server @fzf-claude-hub-key H
k=$(T list-keys -T $CHORD H 2>&1)
check "@fzf-claude-hub-key changes the key (C-k H)" contains "$k" "hub_popup.sh"
check "  ... and C-k h is left unbound" test -z "$(T list-keys -T $CHORD h 2>/dev/null)"

fresh_server @fzf-claude-hub-table prefix
k=$(T list-keys -T prefix h 2>&1)
check "@fzf-claude-hub-table prefix: prefix + h, as before" contains "$k" "hub_popup.sh"
check "  ... and not in the chord table" test -z "$(T list-keys -T $CHORD h 2>/dev/null)"
check "  ... exactly one hub binding" test "$(hub_keys | wc -l)" -eq 1

fresh_server @fzf-claude-hub-key M-h @fzf-claude-hub-table root
k=$(T list-keys -T root M-h 2>&1)
check "@fzf-claude-hub-table root: bound without any prefix" contains "$k" "hub_popup.sh"
check "  ... exactly one hub binding" test "$(hub_keys | wc -l)" -eq 1

fresh_server @fzf-claude-hub-key M-h @fzf-claude-hub-without-prefix true
k=$(T list-keys -T root M-h 2>&1)
check "@fzf-claude-hub-without-prefix true (older option) still means root" contains "$k" "hub_popup.sh"
check "  ... and not in the prefix or chord table" \
  test -z "$(T list-keys -T prefix M-h 2>/dev/null)$(T list-keys -T $CHORD M-h 2>/dev/null)"
fresh_server @fzf-claude-hub-without-prefix false
check "@fzf-claude-hub-without-prefix false: still the chord default" contains "$(T list-keys -T $CHORD h 2>&1)" "hub_popup.sh"
fresh_server @fzf-claude-hub-without-prefix true @fzf-claude-hub-table prefix
check "an explicit @fzf-claude-hub-table wins over without-prefix" contains "$(T list-keys -T prefix h 2>&1)" "hub_popup.sh"
check "  ... exactly one hub binding" test "$(hub_keys | wc -l)" -eq 1
fresh_server @fzf-claude-hub-table bogus
check "an unknown @fzf-claude-hub-table falls back to the chord table" contains "$(T list-keys -T $CHORD h 2>&1)" "hub_popup.sh"

fresh_server @fzf-claude-hub-key off
check "@fzf-claude-hub-key off: no hub binding" test -z "$(hub_keys)"
fresh_server @fzf-claude-hub-key ''
check "@fzf-claude-hub-key '': no hub binding" test -z "$(hub_keys)"
fresh_server @fzf-claude-hub-key off @fzf-claude-hub-table prefix
check "  ... off with a table set: still no hub binding" test -z "$(hub_keys)"

# Reloads: the plugin removes hub bindings it made earlier, never a binding of your own
fresh_server
T bind h run-shell -b "\"/old/plugin/scripts/hub_mode.sh\""   # what the previous version bound
T bind -n M-h run-shell -b "\"/old/plugin/scripts/hub_popup.sh\" x y"
T run-shell "$SH '$ROOT/main.tmux'"
check "reload after upgrading: the old prefix + h hub binding is removed" test -z "$(T list-keys -T prefix h 2>/dev/null)"
check "  ... and an old root hub binding too" test -z "$(T list-keys -T root M-h 2>/dev/null)"
check "  ... leaving only C-k h" test "$(hub_keys | wc -l)" -eq 1 -a -n "$(T list-keys -T $CHORD h 2>/dev/null)"
T set -g @fzf-claude-hub-table prefix; T run-shell "$SH '$ROOT/main.tmux'"
check "reload after switching to prefix: C-k h is removed, prefix + h bound" \
  test -z "$(T list-keys -T $CHORD h 2>/dev/null)" -a -n "$(T list-keys -T prefix h 2>/dev/null)"
T set -g @fzf-claude-hub-key off; T run-shell "$SH '$ROOT/main.tmux'"
check "reload after turning hub mode off: no hub binding left" test -z "$(hub_keys)"
fresh_server @fzf-claude-hub-key off
T bind h display-message mine; T bind -n M-h display-message mine2
T run-shell "$SH '$ROOT/main.tmux'"
check "a prefix + h of your own is kept" contains "$(T list-keys -T prefix h 2>&1)" "display-message mine"
check "  ... and a root key of your own" contains "$(T list-keys -T root M-h 2>&1)" "display-message mine2"
T set -gu @fzf-claude-hub-key; T run-shell "$SH '$ROOT/main.tmux'"
check "  ... also when hub mode is on (it uses C-k h)" contains "$(T list-keys -T prefix h 2>&1)" "display-message mine"

# The Ctrl+K chord must be exactly what origin/main binds (modulo the plugin path)
mkdir -p "$TMP/base"
if git -C "$ROOT" show origin/main:main.tmux >"$TMP/base/main.tmux" 2>/dev/null; then
  fresh_server
  # Apart from the new h (hub mode) line, which origin/main binds as prefix + h instead
  ours=$( { T list-keys -T root C-k; T list-keys -T fzf-claude-switch; } | grep -v hub_popup.sh | sed "s|$ROOT|ROOT|g")
  T kill-server 2>/dev/null; T new-session -d -s t
  T run-shell "$SH '$TMP/base/main.tmux'"
  base=$( { T list-keys -T root C-k; T list-keys -T fzf-claude-switch; } | grep -v 'hub_' | sed "s|$TMP/base|ROOT|g")
  if [ "$ours" = "$base" ]; then ok "Ctrl+K chord c/s/i/t bindings identical to origin/main"
  else bad "Ctrl+K chord c/s/i/t bindings identical to origin/main" "$(diff <(echo "$base") <(echo "$ours"))"; fi
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

echo "== C-k h (and C-k c / s) through a real client (nested throwaway servers)"
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
TO send-keys -t o C-k h
check "C-k h opens a ' hub ' popup running hub --tmux" wait_for popup_open "STUB-HUB-PICKER"
check "  ... popup is titled ' hub '" contains "$(screen)" " hub "
check "  ... hub got --tmux" contains "$(cat "$LOG")" "args=--tmux"
check "  ... popup closes when hub exits" wait_for popup_closed "STUB-HUB-PICKER"

: >"$LOG"
TO send-keys -t o C-b h
sleep 1
check "prefix + h no longer opens hub mode" lacks "$(screen)$(cat "$LOG")" "STUB-HUB-PICKER"

for sub in c:claude s:server; do
  : >"$LOG"
  TO send-keys -t o C-k "${sub%%:*}"
  check "C-k ${sub%%:*} still opens the ' ${sub#*:} ' switcher popup" wait_for popup_open "STUB-FZF-SWITCHER"
  check "  ... titled ' ${sub#*:} '" contains "$(screen)" " ${sub#*:} "
  check "  ... and closes on Esc (fzf exits 130)" wait_for popup_closed "STUB-FZF-SWITCHER"
  check "  ... fzf got the header row" grep -q 'fzf-rows=[1-9]' "$LOG"
done

echo "== popup size (hub --tmux-size)"
# hub_popup.sh is run directly with $SH (so both bashes are covered) on the attached client. The
# stub logs its terminal size, which is the popup's size minus the 2-cell border.
CLIENT=$(T list-clients -F '#{client_name}' | head -n 1)
read -r CW CH <<<"$(T display -p -c "$CLIENT" '#{client_width} #{client_height}')"
PANE=$(T display -p -t t '#{pane_id}')
TMUX_VAL="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
MAXW=$((CW * 90 / 100)); MAXH=$((CH * 85 / 100))
FULL="$((MAXH - 2)) $((MAXW - 2))" # content size of a max-size popup, as stty prints it
log_value() { sed -n "s/^$1=//p" "$LOG" | tail -n 1; }
logged_tty() { test -n "$(log_value tty)"; }
popup_done() { wait_for logged_tty && wait_for popup_closed "STUB-HUB-PICKER"; }
open_popup() { # open_popup <stub dir> [size-mode] [size-out]
  [ -n "${2:-}" ] && echo "$2" >"$TMP/size-mode"
  [ -n "${3:-}" ] && echo "$3" >"$TMP/size-out"
  : >"$LOG"
  env TMUX="$TMUX_VAL" PATH="$1:$BASEPATH:$TMUXDIR" HOME="$TMP/home" \
    "$SH" "$ROOT/scripts/hub_popup.sh" "$CLIENT" "$PANE"
  popup_done
}
tty_is() { test "$(log_value tty)" = "$1"; }
echo "  info  client ${CW}x${CH}, max popup ${MAXW}x${MAXH}"

T set-environment -g PATH "$TMP/stub-sized:$BASEPATH:$TMUXDIR"
open_popup "$TMP/stub-sized" ok "60 8"
check "--tmux-size gets the content max (popup max minus border)" \
  test "$(log_value size-args)" = "$((MAXW - 2)) $((MAXH - 2))"
check "popup is the reported size plus border (content 60x8)" tty_is "8 60"
check "  ... and hub --tmux still runs in it" contains "$(cat "$LOG")" "args=--tmux"
open_popup "$TMP/stub-sized" ok "500 200"
check "a reported size beyond the max is clamped to the max" tty_is "$FULL"
open_popup "$TMP/stub-sized" ok "0 0"
check "a reported 0x0 still gives a 1x1 content popup" tty_is "1 1"
open_popup "$TMP/stub-sized" err
check "--tmux-size exits non-zero: max size" tty_is "$FULL"
open_popup "$TMP/stub-sized" garbage
check "--tmux-size prints garbage: max size" tty_is "$FULL"
t0=$(date +%s)
open_popup "$TMP/stub-sized" hang
t1=$(date +%s)
check "--tmux-size hangs: max size" tty_is "$FULL"
check "  ... after the 2s timeout, not the 5s hang ($((t1 - t0))s incl. the stub's 1.5s)" test $((t1 - t0)) -lt 6
T set -g @fzf-claude-hub-autosize off
open_popup "$TMP/stub-sized" ok "60 8"
check "@fzf-claude-hub-autosize off: max size" tty_is "$FULL"
check "  ... and --tmux-size is not called" test -z "$(log_value size-args)"
T set -gu @fzf-claude-hub-autosize
T set -g @fzf-claude-hub-width 70; T set -g @fzf-claude-hub-height 20
open_popup "$TMP/stub-sized" ok "60 8"
check "custom max 70x20: --tmux-size gets 68 18" test "$(log_value size-args)" = "68 18"
check "  ... small content still sized to it" tty_is "8 60"
open_popup "$TMP/stub-sized" ok "100 100"
check "  ... large content clamped to 70x20" tty_is "18 68"
T set -g @fzf-claude-hub-width 999%; T set -g @fzf-claude-hub-height 500
open_popup "$TMP/stub-sized" ok "500 500"
check "a max larger than the client is clamped to the client" tty_is "$((CH - 2)) $((CW - 2))"
T set -gu @fzf-claude-hub-width; T set -gu @fzf-claude-hub-height
T set-environment -g PATH "$TMP/stub-new:$BASEPATH:$TMUXDIR"
open_popup "$TMP/stub-new"
check "hub with --tmux but no --tmux-size: max size, as before" tty_is "$FULL"
check "  ... --tmux-size is never called" lacks "$(cat "$LOG")" "tmux-size"
check "  ... and hub --tmux runs" contains "$(cat "$LOG")" "args=--tmux"

T set-environment -g PATH "$TMP/stub-sized:$BASEPATH:$TMUXDIR"
echo ok >"$TMP/size-mode"; echo "50 6" >"$TMP/size-out"; : >"$LOG"
TO send-keys -t o C-k h
popup_done
check "C-k h itself opens the autosized popup (content 50x6)" tty_is "6 50"

T set-environment -g PATH "$TMP/stub-old:$BASEPATH:$TMUXDIR"
: >"$LOG"
TO send-keys -t o C-k h
check "old hub: popup shows 'update hub'" wait_for popup_open "update hub"
sleep 0.5
check "  ... and stays open" popup_open "update hub"
TO send-keys -t o q
check "  ... until a key is pressed" wait_for popup_closed "update hub"
sleep 0.3
check "  ... and leaves the pane out of view-mode (no 'returned 1')" test -z "$(T display -p -t t '#{pane_mode}')"

T set-environment -g PATH "$BASEPATH:$TMUXDIR"
TO send-keys -t o C-k h
check "no hub: popup shows the install message" wait_for popup_open "hub is not installed"
TO send-keys -t o Enter
check "  ... and closes on a key" wait_for popup_closed "hub is not installed"
sleep 0.3
check "  ... and leaves the pane out of view-mode" test -z "$(T display -p -t t '#{pane_mode}')"
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
make_session() { # make_session <pane index> <json extra fields> <title> [tmux session, default t]
  local pane_id sid pid target="${4:-t}:claude.$1"
  pane_id=$(T display -p -t "$target" '#{pane_id}')
  sleep 600 & pid=$!; disown "$pid"; SLEEPERS="$SLEEPERS $pid"
  i=$((i + 1)); sid="0000000$i-aaaa-bbbb-cccc-dddddddddddd"
  printf '{"pid":%s,"sessionId":"%s",%s,"tmux":"t:@1.%s","status":"idle","updatedAt":1}\n' \
    "$pid" "$sid" "$2" "$pane_id" >"$CFG/sessions/$pid.json"
  printf '{"type":"user","uuid":"u%s","timestamp":"%s"}\n' "$i" "$NOW_ISO" >"$CFG/projects/p/$sid.jsonl"
  T select-pane -t "$target" -T "$3"
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

# Against the switcher before hub tags (81270c0, PR #2): same rows and order once the tags are taken out
if git -C "$ROOT" show 81270c0:scripts/switch_session_window_pane.sh >"$TMP/base/switch.sh" 2>/dev/null; then
  base=$(list "$TMP/base/switch.sh")
  ours=$(list "$ROOT/scripts/switch_session_window_pane.sh" | sed $'s/\033\\[2mhub:[^\033]*\033\\[0m  //')
  check "rows, columns and order unchanged apart from the tag" test "$base" = "$ours"
  ours=$(list "$ROOT/scripts/switch_session_window_pane.sh" "$TMP/no-such-hub")
  check "hub not installed: output identical to before hub tags" test "$base" = "$ours"
  ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
  t0=$(ms); for n in 1 2 3 4 5 6 7 8 9 10; do list "$TMP/base/switch.sh" >/dev/null; done; t1=$(ms)
  for n in 1 2 3 4 5 6 7 8 9 10; do list "$ROOT/scripts/switch_session_window_pane.sh" >/dev/null; done; t2=$(ms)
  echo "  info  --list with 5 Claude sessions, mean of 10: pre-hub $(((t1 - t0) / 10))ms, this branch $(((t2 - t1) / 10))ms"
fi

echo "== archived hub projects (\$CLAUDE_HUB/projects/<p>/.archived)"
# Project "old" is archived. Its coordinator and a thread run in a tmux session whose name sorts
# before "t" and is longer than the SESSION column's minimum, so a hidden row that still counted
# would widen that column, and dropping the session from the colour list would recolour "t".
mkdir -p "$HUBROOT/projects/old"
echo 2026-10-28 >"$HUBROOT/projects/old/.archived"
T new-session -d -s a-archived-proj -n claude -x 200 -y 50
T split-window -t a-archived-proj:claude
make_session 0 '"cwd":"/w","name":"old-coord","nameSource":"peer"' "old coord title" a-archived-proj
make_session 1 '"cwd":"/w","name":"old--x","nameSince":1' "old thread title" a-archived-proj
SWITCH="$ROOT/scripts/switch_session_window_pane.sh"
list_mode() { # list_mode <on|off|""> -> the --list rows, ANSI kept
  env TMUX="$TMUX_VAL" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_HUB="$HUBROOT" "$SH" "$SWITCH" --list claude recent $1
}
raw_off=$(list_mode off); raw_on=$(list_mode on)
rows=$(printf '%s\n' "$raw_off" | strip_ansi)
check "archived project: coordinator row hidden by default" lacks "$rows" "old coord title"
check "  ... thread row hidden too" lacks "$rows" "old thread title"
check "  ... also when --list is given no archived argument" test "$(list_mode "")" = "$raw_off"
check "non-archived hub project unaffected (hub:cc-hub coordinator)" contains "$(row 'coord title')" "hub:cc-hub  coord title"
check "  ... and its thread" contains "$rows" "hub:cc-hub/tmux-hub-mode  thread title"
check "  ... and hub:ent" contains "$rows" "hub:ent  cwd title"
check "  ... non-hub rows still listed" contains "$rows" "former title"
check "hidden rows do not widen the SESSION column" contains "$(printf '%s\n' "$rows" | head -n 1)" "SESSION  PANE"
check "  ... nor change session colours ('t' keeps the second palette colour)" \
  contains "$(printf '%s\n' "$raw_off" | grep -F 'coord title')" $'\033[38;5;170mt '
rows_on=$(printf '%s\n' "$raw_on" | strip_ansi)
check "on: archived coordinator listed, tagged 'hub:old archived'" contains "$rows_on" "hub:old archived  old coord title"
check "  ... and the thread, 'hub:old/x archived'" contains "$rows_on" "hub:old/x archived  old thread title"
check "  ... the whole title is dim" contains "$raw_on" $'\033[2mhub:old archived  old coord title\033[0m'
check "  ... non-archived rows exactly as with off" \
  test "$(printf '%s\n' "$rows_on" | grep -v 'archived' | sed 's/  */ /g')" = "$(printf '%s\n' "$rows" | sed 's/  */ /g')"
check "  ... 2 more rows than off" test "$(printf '%s\n' "$raw_on" | wc -l)" -eq $(($(printf '%s\n' "$raw_off" | wc -l) + 2))
touch "$HUBROOT/projects/ent/.archived"
check "archived project found from the session's cwd (hub:ent) is hidden" lacks "$(list_mode off | strip_ansi)" "cwd title"
rm "$HUBROOT/projects/ent/.archived"
check "  ... and back, untagged as archived, once .archived is removed" contains "$(list_mode off | strip_ansi)" "hub:ent  cwd title"
rm "$HUBROOT/projects/old/.archived"
check "unarchive (rm .archived): old rows back with a plain tag" contains "$(list_mode off | strip_ansi)" "hub:old  old coord title"
: >"$HUBROOT/projects/old/.archived"
check "only existence matters: an empty .archived hides too" lacks "$(list_mode off | strip_ansi)" "old coord title"
rm "$HUBROOT/projects/old/.archived"; mkdir "$HUBROOT/projects/old/.archived"
check "  ... and so does a directory named .archived" lacks "$(list_mode off | strip_ansi)" "old coord title"
rmdir "$HUBROOT/projects/old/.archived"; echo 2026-10-28 >"$HUBROOT/projects/old/.archived"

# ctrl-s / ctrl-r handler: the prompt holds both states, each key flips one and keeps the other
tr_out() { env FZF_PROMPT="$1" "$SH" "$SWITCH" --transform "$2" claude; }
reload() { printf 'reload("%s" --list "claude" %s)' "$SWITCH" "$1"; }
check "ctrl-r from 'recent ❯ ': shows archived" \
  test "$(tr_out 'recent ❯ ' archived)" = "change-prompt(recent +archived ❯ )+$(reload 'recent on')"
check "ctrl-s from 'recent +archived ❯ ': session order, archived kept" \
  test "$(tr_out 'recent +archived ❯ ' sort)" = "change-prompt(session +archived ❯ )+$(reload 'session on')"
check "ctrl-r from 'session +archived ❯ ': hides archived, session order kept" \
  test "$(tr_out 'session +archived ❯ ' archived)" = "change-prompt(session ❯ )+$(reload 'session off')"
check "ctrl-s from 'session ❯ ': back to recent, as before" \
  test "$(tr_out 'session ❯ ' sort)" = "change-prompt(recent ❯ )+$(reload 'recent off')"

echo "== archived, through C-k c in a real client"
# The popup gets the tmux global environment, so the fake registry, hub root and stub fzf go there
T set-environment -g PATH "$TMP/stub-new:$BASEPATH:$TMUXDIR"
T set-environment -g CLAUDE_CONFIG_DIR "$CFG"
T set-environment -g CLAUDE_HUB "$HUBROOT"
T set -g default-shell /bin/sh
TO kill-server 2>/dev/null
TO new-session -d -s o -x 120 -y 40 "env -u TMUX tmux -L $SOCK attach -t t"
wait_for attached || bad "inner client did not attach"
press_c() { : >"$LOG"; TO send-keys -t o C-k c; wait_for popup_open "STUB-FZF-SWITCHER"; wait_for popup_closed "STUB-FZF-SWITCHER"; }
press_c
n_off=$(log_value fzf-rows)
check "C-k c: header lists ctrl-r" contains "$(log_value fzf-args)" "ctrl-r: show/hide archived"
check "  ... prompt 'recent ❯ ' (archived hidden)" contains "$(log_value fzf-args)" "--prompt=recent ❯  "
T set -g @fzf-claude-show-archived on
press_c
n_on=$(log_value fzf-rows)
check "@fzf-claude-show-archived on: 2 more rows ($n_off -> $n_on)" test "$n_on" -eq $((n_off + 2))
check "  ... prompt starts as 'recent +archived ❯ '" contains "$(log_value fzf-args)" "--prompt=recent +archived ❯ "
T set -gu @fzf-claude-show-archived
T set-environment -g CLAUDE_HUB "$TMP/no-such-hub"
press_c
check "no hub installed: no ctrl-r key or hint" lacks "$(log_value fzf-args)" "ctrl-r"
T set-environment -g CLAUDE_HUB "$HUBROOT"

# The same with the real fzf, when it is installed: ctrl-r really reloads with archived rows
REALFZF=$(PATH="${PATH#"$TMP/stub-new:"}" command -v fzf 2>/dev/null)
if [ -n "$REALFZF" ]; then
  T set-environment -g PATH "$(dirname "$REALFZF"):$BASEPATH:$TMUXDIR"
  TO send-keys -t o C-k c
  check "real fzf: C-k c lists the cc-hub coordinator" wait_for popup_open "hub:cc-hub  coord title"
  check "  ... not the archived one" lacks "$(screen)" "old coord title"
  TO send-keys -t o C-r
  check "  ... ctrl-r shows it, tagged archived" wait_for popup_open "hub:old archived  old coord title"
  check "  ... and the prompt says +archived" contains "$(screen)" "recent +archived"
  TO send-keys -t o C-s
  check "  ... ctrl-s then keeps archived shown (session order)" wait_for popup_open "session +archived"
  check "  ... rows still there" contains "$(screen)" "old coord title"
  TO send-keys -t o C-r
  wait_for popup_open "session ❯"
  check "  ... ctrl-r again hides them (still session order)" lacks "$(screen)" "old coord title"
  TO send-keys -t o C-g
  check "  ... C-g closes the popup" wait_for popup_closed "session ❯"
else
  echo "  skip  real fzf checks (fzf not installed)"
fi
TO kill-server 2>/dev/null

echo
echo "$PASS passed, $FAIL failed ($SH: $("$SH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" = 0 ]
