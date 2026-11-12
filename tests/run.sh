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
# Every test server inherits this, so the attention loop (claude_attn.sh, started by main.tmux)
# reads an empty Claude registry instead of your real ~/.claude
export CLAUDE_CONFIG_DIR="$TMP/claude-empty"

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
# hub-tidy:  a hub whose help lists `hub tidy`. `hub tidy` logs its args, TMUX_PANE and CLAUDE_HUB,
#            then prints two lines and exits 0, or with $TMP/tidy-mode "fail" says boom and exits 2.
mkdir -p "$TMP/stub-tidy"
cat >"$TMP/stub-tidy/hub" <<EOF
#!/bin/sh
if [ "\$1" = help ]; then printf '  hub --tmux           the picker\n  hub tidy [<project>]  rebuild the layout\n'; exit 0; fi
if [ "\$1" = tidy ]; then
  echo "tidy-args=\$* pane=\${TMUX_PANE:-} CLAUDE_HUB=\${CLAUDE_HUB:-}" >>"$LOG"
  if [ "\$(cat "$TMP/tidy-mode" 2>/dev/null)" = fail ]; then echo "boom: no coordinator pane"; exit 2; fi
  echo "Tidied \$2: 2 thread panes on the right."
  echo "  Closed 1 finished pane."
  exit 0
fi
echo "args=\$*" >>"$LOG"
EOF
chmod +x "$TMP/stub-tidy/hub"
# fzf (for the C-k c / s switcher popups): shows a marker with its prompt on the popup, logs how
# many rows it got and its arguments, then exits 130 as if Esc was pressed, so nothing is switched
# or created.
cat >"$TMP/stub-new/fzf" <<EOF
#!/bin/sh
cat >"$TMP/fzf-in"
n=\$(wc -l <"$TMP/fzf-in" | tr -d ' ')
echo "fzf-rows=\$n" >>"$LOG"
echo "fzf-first=\$(head -n 1 "$TMP/fzf-in")" >>"$LOG"
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
hub_keys() { T list-keys 2>/dev/null | grep -E 'hub_(popup|mode)'; } # every hub mode binding, in any table
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

tidy_keys() { T list-keys 2>/dev/null | grep hub_tidy; }
fresh_server
k=$(T list-keys -T $CHORD l 2>&1)
check "C-k l: tidy key bound in the chord table by default, to run-shell -b" contains "$k" "run-shell -b"
check "  ... running hub_tidy.sh with this client and pane" \
  contains "$k" "$ROOT/scripts/hub_tidy.sh\\\" '#{client_name}' '#{pane_id}'"
check "  ... exactly one tidy binding, none in prefix or root" test "$(tidy_keys | wc -l)" -eq 1
fresh_server @fzf-claude-tidy-key L
check "@fzf-claude-tidy-key changes the key (C-k L)" contains "$(T list-keys -T $CHORD L 2>&1)" "hub_tidy.sh"
check "  ... and C-k l is left unbound" test -z "$(T list-keys -T $CHORD l 2>/dev/null)"
fresh_server @fzf-claude-tidy-key off
check "@fzf-claude-tidy-key off: no tidy binding" test -z "$(tidy_keys)"
fresh_server @fzf-claude-tidy-key ''
check "@fzf-claude-tidy-key '': no tidy binding" test -z "$(tidy_keys)"
check "  ... hub mode still bound" test "$(hub_keys | wc -l)" -eq 1
fresh_server @fzf-claude-hub-key off
check "@fzf-claude-hub-key off leaves the tidy key bound" test "$(tidy_keys | wc -l)" -eq 1
fresh_server
T set -g @fzf-claude-tidy-key L; T run-shell "$SH '$ROOT/main.tmux'"
check "reload after changing the tidy key: only C-k L" \
  test "$(tidy_keys | wc -l)" -eq 1 -a -z "$(T list-keys -T $CHORD l 2>/dev/null)"
T set -g @fzf-claude-tidy-key off; T run-shell "$SH '$ROOT/main.tmux'"
check "reload after turning the tidy key off: no tidy binding left" test -z "$(tidy_keys)"
fresh_server @fzf-claude-tidy-key off
T bind -T $CHORD l display-message mytidy; T run-shell "$SH '$ROOT/main.tmux'"
check "a C-k l of your own is kept when the tidy key is off" contains "$(T list-keys -T $CHORD l 2>&1)" "display-message mytidy"

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
  # Apart from the new h (hub mode) and l (tidy) lines, which origin/main binds as prefix + h instead
  ours=$( { T list-keys -T root C-k; T list-keys -T fzf-claude-switch; } | grep -vE 'hub_(popup|tidy)\.sh' | sed "s|$ROOT|ROOT|g")
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

echo "== resolved hub projects are not special in the switcher (\$CLAUDE_HUB/projects/<p>/.archived)"
# Project "old" is resolved (hub's marker file exists), and so is "ent", whose row is tagged from
# the session's cwd. The switcher does not read the marker: hub resolve closes a resolved project's
# panes, and any that are still open are listed like the rest, with the plain hub:<p> tag.
mkdir -p "$HUBROOT/projects/old"
echo 2026-10-28 >"$HUBROOT/projects/old/.archived"
touch "$HUBROOT/projects/ent/.archived"
T new-session -d -s a-old-proj -n claude -x 200 -y 50
T split-window -t a-old-proj:claude
make_session 0 '"cwd":"/w","name":"old-coord","nameSource":"peer"' "old coord title" a-old-proj
make_session 1 '"cwd":"/w","name":"old--x","nameSince":1' "old thread title" a-old-proj
SWITCH="$ROOT/scripts/switch_session_window_pane.sh"
list_sort() { # list_sort <sort> [extra --list argument] -> the --list rows, ANSI kept
  env TMUX="$TMUX_VAL" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_HUB="$HUBROOT" "$SH" "$SWITCH" --list claude "$@"
}
raw=$(list_sort recent)
rows=$(printf '%s\n' "$raw" | strip_ansi)
check "pane of a resolved project shows normally: coordinator tagged hub:old" contains "$rows" "hub:old  old coord title"
check "  ... and its thread, hub:old/x" contains "$rows" "hub:old/x  old thread title"
check "  ... resolved project found from the cwd (hub:ent) shows normally" contains "$rows" "hub:ent  cwd title"
check "  ... the plain dim tag" contains "$raw" $'\033[2mhub:old\033[0m  old coord title'
check "  ... no 'resolved' text in any row" lacks "$rows" "resolved"
check "  ... the column header row as usual" contains "$(printf '%s\n' "$rows" | head -n 1)" "STATUS   LAST MSG  SESSION"
check "  ... active project rows still listed" contains "$rows" "hub:cc-hub  coord title"
check "  ... non-hub rows still listed" contains "$rows" "former title"
check "  ... session order lists them too" contains "$(list_sort session | strip_ansi)" "hub:old  old coord title"
check "  ... a leftover 3rd --list argument (the removed 'resolved' view) is ignored" \
  test "$(list_sort recent resolved)" = "$raw"
for d in old ent; do mv "$HUBROOT/projects/$d/.archived" "$TMP/$d.archived"; done
check "removing .archived changes nothing" test "$(list_sort recent)" = "$raw"
for d in old ent; do mv "$TMP/$d.archived" "$HUBROOT/projects/$d/.archived"; done
# Against the switcher with hub tags but before any resolved-project feature (6074d77, PR #3)
if git -C "$ROOT" show 6074d77:scripts/switch_session_window_pane.sh >"$TMP/base/switch-pre-resolved.sh" 2>/dev/null; then
  pre() { env TMUX="$TMUX_VAL" CLAUDE_CONFIG_DIR="$CFG" CLAUDE_HUB="$HUBROOT" "$SH" "$TMP/base/switch-pre-resolved.sh" --list claude "$1"; }
  check "--list identical to 6074d77 (before resolved projects), .archived present, recent" test "$(pre recent)" = "$raw"
  check "  ... and in session order" test "$(pre session)" = "$(list_sort session)"
else
  bad "could not read 6074d77:scripts/switch_session_window_pane.sh"
fi

# ctrl-s handler: the prompt holds the sort order
tr_out() { env FZF_PROMPT="$1" "$SH" "$SWITCH" --transform "$2" claude; }
reload() { printf 'reload("%s" --list "claude" %s)' "$SWITCH" "$1"; }
check "ctrl-s from 'recent ❯ ': session order" \
  test "$(tr_out 'recent ❯ ' sort)" = "change-prompt(session ❯ )+$(reload session)"
check "ctrl-s from 'session ❯ ': back to recent" \
  test "$(tr_out 'session ❯ ' sort)" = "change-prompt(recent ❯ )+$(reload recent)"
check "  ... no header change and no 'resolved' in the action" lacks "$(tr_out 'recent ❯ ' sort)" "header"
check "an old 'resolved · recent ❯ ' prompt (popup open across an upgrade): ctrl-s just flips the sort" \
  test "$(tr_out 'resolved · recent ❯ ' sort)" = "change-prompt(session ❯ )+$(reload session)"
check "the removed ctrl-r handler (--transform archived) prints nothing (no fzf action)" \
  test -z "$(tr_out 'recent ❯ ' archived)"

echo "== no resolved features through C-k c in a real client"
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
n_rows=$(log_value fzf-rows); args=$(log_value fzf-args)
check "C-k c: no ctrl-r binding" lacks "$args" "ctrl-r"
check "  ... header is just the ctrl-s hint" contains "$args" "--header=ctrl-s: switch sort (recent / session) "
# The plugin path is taken out first: a checkout's folder name may contain the word
check "  ... no 'resolved' text in the header or prompt" lacks "$(printf '%s' "$args" | sed "s#$ROOT##g")" "resolved"
check "  ... prompt 'recent ❯ '" contains "$args" "--prompt=recent ❯  "
check "  ... fzf runs with --exit-0" contains "$args" "--exit-0"
check "  ... the resolved project's panes are passed to fzf" grep -q 'hub:old.*old coord title' "$TMP/fzf-in"
T set -g @fzf-claude-show-resolved on
T set -g @fzf-claude-show-archived on
press_c
check "@fzf-claude-show-resolved / -archived on: ignored, same rows" test "$(log_value fzf-rows)" -eq "$n_rows"
check "  ... and the same fzf arguments" test "$(log_value fzf-args)" = "$args"
check "  ... no error from tmux" lacks "$(T show-messages 2>/dev/null)" "returned"
T set -gu @fzf-claude-show-resolved
T set -gu @fzf-claude-show-archived
T set-environment -g CLAUDE_HUB "$TMP/no-such-hub"
press_c
check "no hub installed: the same fzf arguments" test "$(log_value fzf-args)" = "$args"
T set-environment -g CLAUDE_HUB "$HUBROOT"

# The same with the real fzf, when it is installed: ctrl-r is unbound, so it changes nothing
REALFZF=$(PATH="${PATH#"$TMP/stub-new:"}" command -v fzf 2>/dev/null)
if [ -n "$REALFZF" ]; then
  T set-environment -g PATH "$(dirname "$REALFZF"):$BASEPATH:$TMUXDIR"
  TO send-keys -t o C-k c
  check "real fzf: C-k c lists the resolved project's coordinator, plain tag" wait_for popup_open "hub:old  old coord title"
  check "  ... and the active cc-hub coordinator" contains "$(screen)" "hub:cc-hub  coord title"
  check "  ... and hub:ent" contains "$(screen)" "hub:ent  cwd title"
  # Only fzf's own lines (prompt, header, rows): the pane behind the popup may show a path
  fzf_lines() { screen | grep -E '❯|ctrl-|STATUS|hub:|title'; }
  check "  ... no 'resolved' text in the popup" lacks "$(fzf_lines)" "resolved"
  check "  ... no ctrl-r hint" lacks "$(screen)" "ctrl-r"
  before=$(screen)
  TO send-keys -t o C-r
  sleep 1
  check "  ... ctrl-r does nothing: the popup is unchanged" test "$(screen)" = "$before"
  TO send-keys -t o C-s
  check "  ... ctrl-s still switches to session order" wait_for popup_open "session ❯"
  check "  ... rows still there" contains "$(screen)" "hub:old  old coord title"
  TO send-keys -t o C-g
  check "  ... C-g closes the popup" wait_for popup_closed "session ❯"
else
  echo "  skip  real fzf checks (fzf not installed)"
fi
TO kill-server 2>/dev/null

echo "== tidy (C-k l, hub_tidy.sh)"
# The registry and hub root from the sections above: pane "coord title" runs the Claude session
# cc-hub-coord, projects cc-hub, ent and old exist. Extra panes and windows carry the other cases.
T kill-session -t a-old-proj 2>/dev/null
P_COORD=$(T list-panes -t t:claude -F '#{pane_id} #{pane_title}' | sed -n 's/ coord title$//p')
T new-window -d -t t -n work
P_THREAD=$(T display -p -t t:work '#{pane_id}')
T set -p -t "$P_THREAD" @hub_thread cc-hub--layout
P_ANCHOR=$(T split-window -d -P -F '#{pane_id}' -t "$P_THREAD")
P_SIB=$(T split-window -d -P -F '#{pane_id}' -t "$P_ANCHOR")
T set -p -t "$P_SIB" @hub_thread ent--y; T set -p -t "$P_SIB" @hub_coord "$P_ANCHOR"
P_WIN=$(T new-window -d -P -F '#{pane_id}' -t t -n ent--z)
P_NOPE=$(T new-window -d -P -F '#{pane_id}' -t t -n nope--z)
P_PLAIN=$(T display -p -t t:server '#{pane_id}')
T new-session -d -s old-coord -x 120 -y 40
P_SESS=$(T display -p -t old-coord '#{pane_id}')
T set -g default-shell /bin/sh
T set-environment -g CLAUDE_CONFIG_DIR "$CFG"
T set-environment -g CLAUDE_HUB "$HUBROOT"
T set-environment -g PATH "$TMP/stub-tidy:$BASEPATH:$TMUXDIR"
TO kill-server 2>/dev/null
TO new-session -d -s o -x 120 -y 40 "env -u TMUX tmux -L $SOCK attach -t t"
wait_for attached || bad "inner client did not attach"
CLIENT=$(T list-clients -F '#{client_name}' | head -n 1)
TMUX_VAL="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
last_msg() { T show-messages 2>/dev/null | grep -m 1 ' message: '; } # the log lists newest first
tidy() { # tidy <stub dir or ""> <pane>: runs hub_tidy.sh directly; sets RC
  : >"$LOG"
  env -i HOME="$TMP/home" PATH="${1:+$1:}$BASEPATH:$TMUXDIR" TMUX="$TMUX_VAL" \
    CLAUDE_HUB="$HUBROOT" CLAUDE_CONFIG_DIR="$CFG" "$SH" "$ROOT/scripts/hub_tidy.sh" "$CLIENT" "$2" </dev/null >/dev/null 2>&1
  RC=$?
}
logged() { log_value tidy-args; }
rm -f "$TMP/tidy-mode"
tidy "$TMP/stub-tidy" "$P_THREAD"
check "pane tagged @hub_thread cc-hub--layout: runs 'hub tidy cc-hub'" test "$(logged)" = "tidy cc-hub pane=$P_THREAD CLAUDE_HUB=$HUBROOT"
check "  ... shows hub's output as one message" contains "$(last_msg)" "Tidied cc-hub: 2 thread panes on the right. · Closed 1 finished pane."
check "  ... exits 0" test "$RC" = 0
tidy "$TMP/stub-tidy" "$P_ANCHOR"
check "untagged pane that a thread pane's @hub_coord names: its thread's project (ent)" contains "$(logged)" "tidy ent pane=$P_ANCHOR "
tidy "$TMP/stub-tidy" "$P_COORD"
check "pane running the Claude session cc-hub-coord: cc-hub" contains "$(logged)" "tidy cc-hub pane=$P_COORD "
tidy "$TMP/stub-tidy" "$P_WIN"
check "window named ent--z: ent" contains "$(logged)" "tidy ent pane=$P_WIN "
tidy "$TMP/stub-tidy" "$P_SESS"
check "session named old-coord: old" contains "$(logged)" "tidy old pane=$P_SESS "
tidy "$TMP/stub-tidy" "$P_NOPE"
check "window nope--z, but no hub project 'nope': not run" test -z "$(logged)"
check "  ... says the pane is not part of a hub project" contains "$(last_msg)" "not part of a hub project"
tidy "$TMP/stub-tidy" "$P_PLAIN"
check "plain pane: not run, same message, exit 0" test -z "$(logged)" -a "$RC" = 0
check "  ... message shown" contains "$(last_msg)" "not part of a hub project"
tidy "$TMP/stub-new" "$P_THREAD"
check "hub without 'hub tidy' in its help: not run" test -z "$(logged)$(cat "$LOG")"
check "  ... says 'update hub: hub tidy not available'" contains "$(last_msg)" "update hub: hub tidy not available"
check "  ... exits 0" test "$RC" = 0
tidy "" "$P_THREAD"
check "no hub: says hub is not installed, exits 0" test "$RC" = 0
check "  ... message shown" contains "$(last_msg)" "hub is not installed"
echo fail >"$TMP/tidy-mode"
tidy "$TMP/stub-tidy" "$P_THREAD"
check "hub tidy fails: says so with its output" contains "$(last_msg)" "hub tidy cc-hub failed (exit 2): boom: no coordinator pane"
check "  ... and still exits 0" test "$RC" = 0
rm -f "$TMP/tidy-mode"

# Real key presses on the attached client
T select-window -t t:work; T select-pane -t "$P_THREAD"
: >"$LOG"
TO send-keys -t o C-k l
has_log() { test -n "$(logged)"; }
check "C-k l in the cc-hub thread pane runs hub tidy cc-hub" wait_for has_log
check "  ... for that pane" contains "$(logged)" "tidy cc-hub pane=$P_THREAD "
check "  ... the message is on the status line" wait_for popup_open "Tidied cc-hub"
sleep 0.3
check "  ... pane not in view-mode" test -z "$(T display -p -t "$P_THREAD" '#{pane_mode}')"
T set-environment -g PATH "$TMP/stub-new:$BASEPATH:$TMUXDIR"
: >"$LOG"
TO send-keys -t o C-k l
check "C-k l with an old hub: 'update hub' message" wait_for popup_open "update hub: hub tidy not available"
sleep 0.3
check "  ... pane not in view-mode" test -z "$(T display -p -t "$P_THREAD" '#{pane_mode}')"
TO send-keys -t o C-k c
check "  ... and the next key works (C-k c opens the switcher)" wait_for popup_open "STUB-FZF-SWITCHER"
wait_for popup_closed "STUB-FZF-SWITCHER"
T set-environment -g PATH "$TMP/stub-tidy:$BASEPATH:$TMUXDIR"
echo fail >"$TMP/tidy-mode"
T select-window -t t:server
TO send-keys -t o C-k l
check "C-k l on a plain pane: 'not part of a hub project'" wait_for popup_open "not part of a hub project"
sleep 0.3
check "  ... pane not in view-mode" test -z "$(T display -p -t "$P_PLAIN" '#{pane_mode}')"
T select-window -t t:work
TO send-keys -t o C-k l
check "C-k l when hub tidy fails: the failure message" wait_for popup_open "failed (exit 2)"
sleep 0.3
check "  ... pane not in view-mode" test -z "$(T display -p -t "$P_THREAD" '#{pane_mode}')"
rm -f "$TMP/tidy-mode"
TO kill-server 2>/dev/null

echo "== attention colours in the window list (claude_attn.sh)"
# Stand-in Claude processes run in panes (an interactive session must run on its pane tty); their
# registry files are in $ACFG. The loop runs every 60 s here, so each change below comes from an
# explicit tick or a window-change hook. status-interval 0: a colour on the screen shows that tmux
# redrew because the option changed, not because of a timer.
ATTN="$ROOT/scripts/claude_attn.sh"
ACFG="$TMP/attn-claude"
mkdir -p "$ACFG/sessions" "$ACFG/jobs/job1" "$ACFG/jobs/job2"
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
T kill-server 2>/dev/null
TO kill-server 2>/dev/null
wait_for T new-session -d -s t -x 120 -y 20 -n home 2>/dev/null
T set-environment -g CLAUDE_CONFIG_DIR "$ACFG"
T set -g status-interval 0
T set -g @fzf-claude-attn-interval 60
USER_FMT='#I|#W|mine'
USER_CUR='#[bold]#I|#W|cur'
T set -gw window-status-format "$USER_FMT"
T set -gw window-status-current-format "$USER_CUR"
standin() { printf "sh -c 'echo \$\$ >\"%s\"; exec sleep 600'" "$1"; } # the pane process writes its pid
T new-window -d -t t: -n solo "$(standin "$TMP/pid-a")"
T new-window -d -t t: -n pair "$(standin "$TMP/pid-b")"
T split-window -d -t t:pair "$(standin "$TMP/pid-c")"
T new-window -d -t t: -n thread # the attach pane of a background hub thread
T set -p -t t:thread @hub_thread cc-hub--t1
T new-window -d -t t: -n other
for f in pid-a pid-b pid-c; do wait_for test -s "$TMP/$f"; done
check "test windows home solo pair thread other exist" test "$(T list-windows -t t -F '#W' | tr '\n' ' ')" = "home solo pair thread other "
PA=$(cat "$TMP/pid-a"); PB=$(cat "$TMP/pid-b"); PC=$(cat "$TMP/pid-c")
pane_of() { T display -p -t "$1" '#{pane_id}'; }
PANE_A=$(pane_of t:solo.0); PANE_B=$(pane_of t:pair.0); PANE_C=$(pane_of t:pair.1); PANE_OTHER=$(pane_of t:other)
sleep 600 & PD=$!; disown "$PD"; SLEEPERS="$SLEEPERS $PD" # the background thread (no tty)
sleep 600 & PE2=$!; disown "$PE2"; SLEEPERS="$SLEEPERS $PE2"
sh -c 'exit 0' & PDEAD=$!; wait "$PDEAD"
# The client: an outer server pane attached to the inner server, sitting on window "home"
TO new-session -d -s o -x 120 -y 20 "env -u TMUX tmux -L $SOCK attach -t t"
TO new-window -d -t o "$(standin "$TMP/pid-e1")" # a process on a tty of another tmux server
wait_for test -s "$TMP/pid-e1"; PE1=$(cat "$TMP/pid-e1")

reg() { # reg <pid> <kind> <tmux value|null> <name> <status> <statusUpdatedAt> [startedAt] [extra json]
  local tm=$3
  [ "$tm" = null ] || tm="\"$tm\""
  printf '{"pid":%s,"sessionId":"s-%s","kind":"%s","tmux":%s,"name":"%s","nameSource":"peer","status":"%s","statusUpdatedAt":%s,"startedAt":%s%s}\n' \
    "$1" "$1" "$2" "$tm" "$4" "$5" "$6" "${7:-1000}" "${8:-}" >"$ACFG/sessions/$1.json"
}
job() { # job <state> <tempo> [job id, default job1]
  printf '{\n  "state": "%s",\n  "detail": "stand-in",\n  "tempo": "%s",\n  "name": "stand-in"\n}\n' "$1" "$2" >"$ACFG/jobs/${3:-job1}/state.json"
}
OLD=$(($(ms) - 600000))
# A's tmux value names a window it is no longer in (@99): the pane decides, not the stored window
reg "$PA" interactive "t:@99.$PANE_A" a idle "$OLD"
reg "$PB" interactive "t:@2.$PANE_B" b idle "$OLD"
reg "$PC" interactive "t:@2.$PANE_C" c idle "$OLD"
reg "$PD" bg null cc-hub--t1 idle "$OLD" 1000 ',"jobId":"job1"'
job working idle
reg "$PE1" interactive "x:@1.$PANE_OTHER" e1 waiting "$(ms)"
reg "$PE2" interactive "x:@1.$PANE_OTHER" e2 waiting "$(ms)"
reg "$PDEAD" interactive "t:@1.$PANE_A" dead waiting "$(ms)"

T run-shell "$SH '$ROOT/main.tmux'"
wait_for attached || bad "inner client did not attach"
ATMUX="$(T display -p '#{socket_path}'),$(T display -p '#{pid}'),0"
tick() { env TMUX="$ATMUX" CLAUDE_CONFIG_DIR="$ACFG" "$SH" "$ATTN" --tick; }
attn() { T show-option -wqv -t "t:$1" @claude_attn; }
is_attn() { test "$(attn "$1")" = "$2"; }
seen() { T show-option -wqv -t "t:$1" @claude_attn_seen; }
seen_is() { test "$(seen "$1")" = "$2"; }
status_line() { TO capture-pane -e -p -t o | tail -n 1; }
# sgr_at <label>: the effective style just before a label, replaying every escape from the start of
# the line ("fg=37 bg=41 bold=1"), so a style that leaks from an earlier entry shows up too
sgr_at() {
	status_line | LABEL="$1" perl -ne '
		next unless /^(.*?)\Q$ENV{LABEL}\E/; my $pre = $1; my ($fg, $bg, $b) = ("", "", 0);
		while ($pre =~ /\e\[([0-9;]*)m/g) {
			my @p = split /;/, ($1 eq "" ? "0" : $1);
			while (@p) { my $c = shift @p;
				if ($c == 38 || $c == 48) { my $m = shift @p; my @v = splice(@p, 0, $m == 5 ? 1 : 3);
					my $s = join ";", $c, $m, @v; if ($c == 38) { $fg = $s } else { $bg = $s } }
				elsif ($c == 0) { ($fg, $bg, $b) = ("", "", 0) } elsif ($c == 1) { $b = 1 } elsif ($c == 22) { $b = 0 }
				elsif (($c >= 30 && $c <= 37) || $c == 39 || ($c >= 90 && $c <= 97)) { $fg = $c }
				elsif (($c >= 40 && $c <= 47) || $c == 49 || ($c >= 100 && $c <= 107)) { $bg = $c } } }
		print "fg=$fg bg=$bg bold=$b"; exit;'
}
# The default styles are hex. A client with true colour (the RGB feature; the test client has it)
# gets them exactly: white 38;2;255;255;255 on red 48;2;215;0;0 or on blue 48;2;0;95;215.
WHITE_FG='38;2;255;255;255'; RED_BG='48;2;215;0;0'; BLUE_BG='48;2;0;95;215'
red() { test "$(sgr_at "$1")" = "fg=$WHITE_FG bg=$RED_BG bold=1"; }   # input: bg=#d70000,fg=#ffffff,bold
blue() { test "$(sgr_at "$1")" = "fg=$WHITE_FG bg=$BLUE_BG bold=1"; } # done: bg=#005fd7,fg=#ffffff,bold
plain() { local s; s=$(sgr_at "$1"); test -n "$s" && lacks "$s" "fg=$WHITE_FG " && lacks "$s" "bg=$RED_BG " && lacks "$s" "bg=$BLUE_BG "; }
closed() { plain "$1" && contains "$(sgr_at "$1")" "bold=0"; } # plain and not bold: nothing leaked in
key() { TO send-keys -t o C-b "$1"; sleep 0.3; } # a real prefix + <n> through the client
SOLO='1|solo|mine'; PAIR='2|pair|mine'; THREAD='3|thread|mine'; OTHER='4|other|mine'

PREFIX='#{?#{==:#{@claude_attn},input},#[bg=#d70000#,fg=#ffffff#,bold],#{?#{==:#{@claude_attn},done},#[bg=#005fd7#,fg=#ffffff#,bold],}}'
check "window-status-format = colour prefix + your own format" test "$(T show -gwv window-status-format)" = "$PREFIX$USER_FMT"
check "window-status-current-format = colour prefix + your own format" test "$(T show -gwv window-status-current-format)" = "$PREFIX$USER_CUR"
check "hooks in slots 71/72 of session-window-changed" test "$(T show-hooks -g 2>/dev/null | grep -c 'session-window-changed\[7[12]\]')" = 2
tick
check "first check: no colour on any window" test -z "$(attn solo)$(attn pair)$(attn thread)$(attn other)"
check "  ... each window recorded its newest status time" seen_is solo "$OLD"
check "  ... status line shows the entries plain" plain "$SOLO"

reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"; tick
check "needs input (status waiting): @claude_attn=input" is_attn solo input
check "  ... entry is red, bold white text, on the status line" wait_for red "$SOLO"
check "  ... only that entry" closed "$PAIR"
reg "$PA" interactive "t:@99.$PANE_A" a busy "$(ms)"; tick
check "answered (status busy): input clears" is_attn solo ""
check "  ... entry back to plain" wait_for plain "$SOLO"
SUA=$(ms); reg "$PA" interactive "t:@99.$PANE_A" a idle "$SUA"; tick
check "finished (idle) in a window you are not on: @claude_attn=done" is_attn solo done
check "  ... entry is blue, bold white text" wait_for blue "$SOLO"
check "  ... the style closes: the next entry is plain (no bold or colour leak)" closed "$PAIR"
key 1
check "opening the window clears done at once (hook, no loop tick)" wait_for is_attn solo ""
check "  ... and records that you saw it" wait_for seen_is solo "$SUA"
check "  ... current entry is plain" wait_for plain '1|solo|cur'
check "  ... the pane is not in view-mode (the hook printed nothing)" test -z "$(T display -p -t t:solo '#{pane_mode}')"
key 0; tick
check "after leaving, done does not come back" is_attn solo ""

key 1
reg "$PA" interactive "t:@99.$PANE_A" a busy "$(ms)"; tick
reg "$PA" interactive "t:@99.$PANE_A" a idle "$(ms)"; tick
check "finished while you look at the window: no done" is_attn solo ""
key 0; tick
check "  ... and none after you leave" is_attn solo ""
reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"; key 1; tick
check "needs input still shows on the current window" is_attn solo input
check "  ... current entry red" wait_for red '1|solo|cur'
key 0
NOW=$(ms); reg "$PA" interactive "t:@99.$PANE_A" a idle "$NOW" "$((NOW - 40))"; tick
check "a session that is idle since start-up is not done" is_attn solo ""

reg "$PB" interactive "t:@2.$PANE_B" b waiting "$(ms)"
reg "$PC" interactive "t:@2.$PANE_C" c idle "$(ms)"; tick
check "one window with needs input + done: needs input wins" is_attn pair input
check "  ... entry red" wait_for red "$PAIR"
reg "$PB" interactive "t:@2.$PANE_B" b busy "$(ms)"; tick
check "  ... input answered, that session works: no done while it works" is_attn pair ""
check "  ... entry plain" wait_for plain "$PAIR"
reg "$PB" interactive "t:@2.$PANE_B" b idle "$(ms)"; tick
check "  ... it finishes too: done" is_attn pair done
check "  ... entry blue" wait_for blue "$PAIR"
key 2
check "  ... opening the window clears it" wait_for is_attn pair ""
key 0

reg "$PD" bg null cc-hub--t1 idle "$(ms)" 1000 ',"jobId":"job1"'; job blocked idle; tick
check "hub thread blocked (job state): its attach pane window needs input" is_attn thread input
check "  ... entry red" wait_for red "$THREAD"
reg "$PD" bg null cc-hub--t1 busy "$(ms)" 1000 ',"jobId":"job1"'; job working active; tick
check "  ... thread works again: clears" is_attn thread ""
job working blocked; tick
check "hub thread on a permission prompt (job tempo blocked): needs input" is_attn thread input
reg "$PD" bg null cc-hub--t1 idle "$(ms)" 1000 ',"jobId":"job1"'; job done idle; tick
check "hub thread finished: done" is_attn thread done
check "  ... entry blue" wait_for blue "$THREAD"
check "another tmux server's session on the same pane id: no colour" is_attn other ""
check "  ... entry plain" plain "$OTHER"
check "a registry file whose pid is gone: ignored" test "$(attn solo)" = ""

# A hub coordinator window: the coordinator's own pane (interactive) and the attach pane of one of
# its background threads (@hub_thread). The coordinator replies (idle) while the thread still works.
T new-window -d -t t: -n coord "$(standin "$TMP/pid-f")"
T split-window -d -t t:coord
T set -p -t t:coord.1 @hub_thread cc-hub--t2
wait_for test -s "$TMP/pid-f"; PF=$(cat "$TMP/pid-f"); PANE_F=$(pane_of t:coord.0)
sleep 600 & PG=$!; disown "$PG"; SLEEPERS="$SLEEPERS $PG" # the thread (no tty)
COORD='5|coord|mine'
gone_pid() { ! kill -0 "$1" 2>/dev/null; }
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord idle "$OLD"
reg "$PG" bg null cc-hub--t2 busy "$OLD" 1000 ',"jobId":"job2"'; job working active job2; tick
check "coordinator window (coordinator + thread attach pane): no colour at first" is_attn coord ""
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord idle "$(ms)"; tick
check "coordinator finished, its thread still busy in the same window: no done" is_attn coord ""
check "  ... entry plain" wait_for plain "$COORD"
reg "$PG" bg null cc-hub--t2 idle "$(ms)" 1000 ',"jobId":"job2"'; job done idle job2; tick
check "  ... the thread finishes too: done" is_attn coord done
check "  ... entry blue" wait_for blue "$COORD"
reg "$PG" bg null cc-hub--t2 busy "$(ms)" 1000 ',"jobId":"job2"'; job working active job2; tick
check "a blue window clears when any session in it starts working" is_attn coord ""
reg "$PG" bg null cc-hub--t2 shell "$(ms)" 1000 ',"jobId":"job2"'; job working idle job2
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord idle "$(ms)"; tick
check "thread ended its turn with a background task running (status shell): no done" is_attn coord ""
job done idle job2; tick
check "  ... shell, but its job is done (a task left behind): done" is_attn coord done
job blocked idle job2; tick
check "  ... shell with job state blocked: needs input" is_attn coord input
reg "$PG" bg null cc-hub--t2 idle "$(ms)" 1000 ',"jobId":"job2"'; job done idle job2
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord shell "$(ms)"; tick
check "coordinator with a background task (interactive, status shell), its thread finished: no done" is_attn coord ""
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord idle "$(ms)"; tick
check "  ... the coordinator's follow-up turn ends (idle): done" is_attn coord done
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord waiting "$(ms)"
reg "$PG" bg null cc-hub--t2 busy "$(ms)" 1000 ',"jobId":"job2"'; job working active job2; tick
check "coordinator waits on you while the thread works: needs input" is_attn coord input
check "  ... entry red" wait_for red "$COORD"
reg "$PF" interactive "t:@5.$PANE_F" cc-hub-coord idle "$(ms)"; tick
check "  ... answered and finished, thread still busy: no done" is_attn coord ""
kill "$PG" 2>/dev/null; wait_for gone_pid "$PG"; tick
check "  ... the busy thread's process is gone: done" is_attn coord done
key 5
check "  ... opening the window clears it" wait_for is_attn coord ""
key 0

# A client without true colour: tmux uses the nearest of the 256 colours. For the default hex
# styles these are the same colours: red 160 (#d70000), blue 26 (#005fd7), white 231 (#ffffff).
red256() { test "$(sgr_at "$1")" = "fg=38;5;231 bg=48;5;160 bold=1"; }
blue256() { test "$(sgr_at "$1")" = "fg=38;5;231 bg=48;5;26 bold=1"; }
reattach() { TO respawn-pane -k -t o:0.0 "env -u TMUX tmux -L $SOCK attach -t t"; wait_for attached; }
reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"; tick
T set -sa terminal-overrides ',*:RGB@:Tc@:setrgbf@:setrgbb@'; reattach
check "no true colour (RGB off): needs input is colour 160, bold white 231" wait_for red256 "$SOLO"
check "  ... done is colour 26, bold white 231" wait_for blue256 "$THREAD"
T set -su terminal-overrides; reattach
check "  ... RGB back on: true colour again" wait_for red "$SOLO"
reg "$PA" interactive "t:@99.$PANE_A" a busy "$(ms)"; tick

T run-shell "$SH '$ROOT/main.tmux'"
check "reload: formats keep one prefix" test "$(T show -gwv window-status-format)" = "$PREFIX$USER_FMT"
T set -g @fzf-claude-attn-input-style 'bg=magenta'
T run-shell "$SH '$ROOT/main.tmux'"
fmt=$(T show -gwv window-status-format)
check "new input style: the old prefix is replaced, not stacked" test "$(printf '%s' "$fmt" | grep -o '@claude_attn' | wc -l | tr -d ' ')" = 2
check "  ... new style in it, your format after it" contains "$fmt" "#[bg=magenta],#{?"
check "  ... your format still at the end" test "${fmt%"$USER_FMT"}" != "$fmt"
T set -gu @fzf-claude-attn-input-style
T set -g @fzf-claude-attn-format off
T run-shell "$SH '$ROOT/main.tmux'"
check "@fzf-claude-attn-format off: formats are exactly yours" test "$(T show -gwv window-status-format)|$(T show -gwv window-status-current-format)" = "$USER_FMT|$USER_CUR"
reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"; tick
check "  ... @claude_attn is still kept up to date" is_attn solo input
T set -gu @fzf-claude-attn-format
T set -g @fzf-claude-attn-interval 0.3
# The loop writes @claude_attn_pid a moment after main.tmux returns: wait for a new, live pid
LOOP=""
new_loop() { # new_loop <previous pid>: sets LOOP once @claude_attn_pid names another live process
  local p
  p=$(T show -gqv @claude_attn_pid 2>/dev/null)
  [ -n "$p" ] && [ "$p" != "$1" ] && kill -0 "$p" 2>/dev/null && LOOP=$p
}
gone() { ! kill -0 "$1" 2>/dev/null; }
L0=$(T show -gqv @claude_attn_pid)
check "the loop started by main.tmux runs" kill -0 "${L0:-none}"
T run-shell "$SH '$ROOT/main.tmux'"
check "format on again: prefix back" test "$(T show -gwv window-status-format)" = "$PREFIX$USER_FMT"
check "reload: a new loop (pid in @claude_attn_pid)" wait_for new_loop "$L0"
L1=$LOOP
check "  ... the old loop is stopped at once, though it sleeps 60 s" wait_for gone "${L0:-none}"
reg "$PA" interactive "t:@99.$PANE_A" a busy "$(ms)"
check "  ... and updates on its own (input clears without a manual tick)" wait_for is_attn solo ""
reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"
check "  ... and sets it again" wait_for is_attn solo input
T run-shell "$SH '$ROOT/main.tmux'"
check "reload again: another new loop" wait_for new_loop "$L1"
L2=$LOOP
check "  ... the old one exits" wait_for gone "${L1:-none}"
check "  ... one loop for this server" test "$(ps ax -o command= | grep -F "$ATTN --loop" | grep -vc grep)" = 1

T set -g @fzf-claude-attn off
T run-shell "$SH '$ROOT/main.tmux'"
check "@fzf-claude-attn off: formats are exactly yours again" test "$(T show -gwv window-status-format)|$(T show -gwv window-status-current-format)" = "$USER_FMT|$USER_CUR"
check "  ... hooks removed" test "$(T show-hooks -g 2>/dev/null | grep -c '\[7[12]\]')" = 0
check "  ... @claude_attn removed from every window" test -z "$(T list-windows -a -F '#{@claude_attn}' | tr -d '\n')"
check "  ... the loop exits" wait_for gone "${L2:-none}"
check "  ... @claude_attn_pid unset" test -z "$(T show -gqv @claude_attn_pid)"
reg "$PA" interactive "t:@99.$PANE_A" a waiting "$(ms)"; sleep 0.8
check "  ... nothing sets a colour any more" is_attn solo ""
T set -gu @fzf-claude-attn
T run-shell "$SH '$ROOT/main.tmux'"
check "on again: loop back" wait_for new_loop "$L2"
L3=$LOOP
T kill-server 2>/dev/null
TO kill-server 2>/dev/null
check "server killed: its loop exits" wait_for gone "${L3:-none}"
# tpm loads the plugin from the config, before the first session exists
printf '%s\n' 'set -g @fzf-claude-attn-interval 0.3' "run-shell \"$SH '$ROOT/main.tmux'\"" 'run-shell "sleep 1"' >"$TMP/cold.conf"
tmux -L "$SOCK" -f "$TMP/cold.conf" new-session -d -s t 2>/dev/null
sleep 1.5
L4=$(T show -gqv @claude_attn_pid)
check "plugin loaded from the config before any session: the loop keeps running" kill -0 "${L4:-none}"
T kill-server 2>/dev/null
check "  ... and exits with its server" wait_for gone "${L4:-none}"
leaked() { test -z "$(ps ax -o command= | grep -F "$ATTN --loop" | grep -v grep)"; }
check "no loop left from any test server" wait_for leaked

echo
echo "$PASS passed, $FAIL failed ($SH: $("$SH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" = 0 ]
