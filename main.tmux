#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_key_bindings_goto="C-k"
default_width=90
default_height=20
default_without_prefix=true

tmux_claude_option_goto="@fzf-claude-goto-session"
tmux_claude_option_goto_without_prefix="@fzf-claude-goto-session-without-prefix"
tmux_claude_option_width="@fzf-claude-goto-win-width"
tmux_claude_option_height="@fzf-claude-goto-win-height"

# The chord table that the goto key (default C-k) enters; c/s/i/t (and h, hub mode) live in it
chord_table="fzf-claude-switch"

# Hub mode: C-k h (the hub key in the chord table) opens the cc-hub picker (`hub --tmux`) in a
# popup. @fzf-claude-hub-table moves the key to the prefix table (prefix + h) or the root table
# (no prefix). @fzf-claude-hub-without-prefix true is the older spelling of the root table. The
# size options (@fzf-claude-hub-width / -height / -autosize) are read by scripts/hub_popup.sh at
# each press.
default_hub_key="h"
default_hub_table="chord"

tmux_claude_option_hub_key="@fzf-claude-hub-key"
tmux_claude_option_hub_table="@fzf-claude-hub-table"
tmux_claude_option_hub_without_prefix="@fzf-claude-hub-without-prefix"

# Tidy: C-k l runs `hub tidy <project>` for the project of the current pane (scripts/hub_tidy.sh),
# which puts that project's coordinator on the left and its thread panes in one column on the right.
# @fzf-claude-tidy-key changes the key; '' or 'off' leaves it unbound.
default_tidy_key="l"
tmux_claude_option_tidy_key="@fzf-claude-tidy-key"

# Attention colours: a window's entry in the window list turns red while a Claude session in it
# needs input, and blue when one finished its turn while you were not looking (until you open the
# window). scripts/claude_attn.sh keeps the window option @claude_attn (input | done | unset);
# here a conditional style for it goes in front of window-status-format and
# window-status-current-format, so your own formats stay as they are after it.
#   @fzf-claude-attn              on | off   off stops it all and takes the style back out
#   @fzf-claude-attn-format       on | off   off keeps @claude_attn up to date but leaves the
#                                            formats alone (use #{@claude_attn} in your own)
#   @fzf-claude-attn-input-style  default "bg=#d70000,fg=#ffffff,bold"
#   @fzf-claude-attn-done-style   default "bg=#005fd7,fg=#ffffff,bold"
#                                 hex, not named red/blue: a terminal theme can redraw named colours
#                                 (Monokai Classic: blue = orange). Without RGB, tmux uses the
#                                 nearest 256 colour: 160 and 26, the same colours.
#   @fzf-claude-attn-interval     seconds between checks, default 2
tmux_claude_option_attn="@fzf-claude-attn"
tmux_claude_option_attn_format="@fzf-claude-attn-format"
tmux_claude_option_attn_input_style="@fzf-claude-attn-input-style"
tmux_claude_option_attn_done_style="@fzf-claude-attn-done-style"
default_attn_input_style="bg=#d70000,fg=#ffffff,bold"
default_attn_done_style="bg=#005fd7,fg=#ffffff,bold"
# The prefix this plugin put in front of the formats last time, so a reload can take it out again
attn_applied_option="@fzf-claude-attn-applied"
# Fixed slots in these hook arrays: a reload replaces our entries and leaves your own hooks alone
attn_hooks="session-window-changed client-session-changed client-attached"
attn_hook_slot=71

get_tmux_option() {
	local option=$1
	local default_value=$2
	local option_value=$(tmux show-option -gqv "$option")
	if [ -z "$option_value" ]; then
		echo "$default_value"
	else
		echo "$option_value"
	fi
}

function set_goto_session_bindings {
	local key_bindings=$(get_tmux_option "$tmux_claude_option_goto" "$default_key_bindings_goto")
	local without_prefix=$(get_tmux_option "$tmux_claude_option_goto_without_prefix" "$default_without_prefix")
	local width=$(get_tmux_option "$tmux_claude_option_width" "$default_width")
	local height=$(get_tmux_option "$tmux_claude_option_height" "$default_height")

	# Bind the chord entry key
	if [ "$without_prefix" = true ]; then
		local key
		for key in $key_bindings; do
			tmux bind -n "$key" switch-client -T "$chord_table"
		done
	else
		local key
		for key in $key_bindings; do
			tmux bind "$key" switch-client -T "$chord_table"
		done
	fi

	# Bind sub-keys in the custom key table
	tmux bind -T "$chord_table" c popup -b rounded -T " claude " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh claude"
	tmux bind -T "$chord_table" s popup -b rounded -T " server " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh server"
	tmux bind -T "$chord_table" i popup -b rounded -T " index " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh index"
	tmux bind -T "$chord_table" t popup -b rounded -T " test " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh test"
}

# Like get_tmux_option, but an option explicitly set to "" stays empty instead of falling back
# to the default (`show-option -gqv` prints nothing both when unset and when set to "").
get_tmux_option_allow_empty() {
	local option=$1
	local default_value=$2
	if [ -n "$(tmux show-option -gq "$option")" ]; then
		tmux show-option -gqv "$option"
	else
		echo "$default_value"
	fi
}

# Removes every hub and tidy binding this plugin made earlier (in the chord, prefix or root table),
# so a reload after changing a key or table, or after upgrading from prefix + h, leaves no stale
# binding behind. Only bindings that run this plugin's hub scripts are touched; a key of your own
# is left alone.
function unbind_old_hub_bindings {
	local table key
	for table in "$chord_table" prefix root; do
		tmux list-keys -T "$table" 2>/dev/null |
			grep -E '/scripts/hub_(popup|mode|tidy)\.sh' |
			awk -v t="$table" '{ for (i = 1; i < NF; i++) if ($i == "-T" && $(i + 1) == t) { print $(i + 2); break } }' |
			while read -r key; do
				[ -n "$key" ] && tmux unbind -T "$table" "$key" 2>/dev/null
			done
	done
}

function set_hub_bindings {
	local key=$(get_tmux_option_allow_empty "$tmux_claude_option_hub_key" "$default_hub_key")
	local table=$(get_tmux_option "$tmux_claude_option_hub_table" "")
	local without_prefix=$(get_tmux_option "$tmux_claude_option_hub_without_prefix" false)

	unbind_old_hub_bindings

	# Empty or "off" disables hub mode
	if [ -z "$key" ] || [ "$key" = off ]; then
		return
	fi

	# An explicit table wins; otherwise the older without-prefix option still means root
	if [ -z "$table" ]; then
		if [ "$without_prefix" = true ]; then
			table=root
		else
			table=$default_hub_table
		fi
	fi

	local -a where
	case "$table" in
		chord) where=(-T "$chord_table") ;;
		prefix) where=(-T prefix) ;;
		root) where=(-n) ;;
		*)
			tmux display-message "tmux-fzf-claude-switch: @fzf-claude-hub-table '$table' is not chord, prefix or root; using chord"
			where=(-T "$chord_table")
			;;
	esac
	# hub_popup.sh sizes the popup to the picker, then opens it on this client. run-shell expands
	# the formats; -b so tmux does not wait on it.
	tmux bind "${where[@]}" "$key" run-shell -b "\"$CURRENT_DIR/scripts/hub_popup.sh\" '#{client_name}' '#{pane_id}'"
}

# C-k <tidy key> (chord table only). Old tidy bindings were removed by unbind_old_hub_bindings.
function set_tidy_bindings {
	local key=$(get_tmux_option_allow_empty "$tmux_claude_option_tidy_key" "$default_tidy_key")
	if [ -z "$key" ] || [ "$key" = off ]; then
		return
	fi
	tmux bind -T "$chord_table" "$key" run-shell -b "\"$CURRENT_DIR/scripts/hub_tidy.sh\" '#{client_name}' '#{pane_id}'"
}

# Puts <prefix> in front of a global window format, after taking out the prefix of an earlier load
function attn_apply_format {
	local option=$1 prefix=$2 old current
	old=$(tmux show-option -gqv "$attn_applied_option")
	current=$(tmux show-option -gwv "$option")
	if [ -n "$old" ]; then
		case "$current" in
			"$old"*) current=${current#"$old"} ;;
		esac
	fi
	[ "$prefix$current" = "$(tmux show-option -gwv "$option")" ] || tmux set-option -gw "$option" "$prefix$current"
}

function set_attn {
	local enabled=$(get_tmux_option "$tmux_claude_option_attn" on)
	local format=$(get_tmux_option "$tmux_claude_option_attn_format" on)
	local script="$CURRENT_DIR/scripts/claude_attn.sh"
	local prefix="" input_style done_style hook

	if [ "$enabled" != off ] && [ "$format" != off ]; then
		input_style=$(get_tmux_option "$tmux_claude_option_attn_input_style" "$default_attn_input_style")
		done_style=$(get_tmux_option "$tmux_claude_option_attn_done_style" "$default_attn_done_style")
		# A comma inside #{?...} must be written #,
		prefix="#{?#{==:#{@claude_attn},input},#[${input_style//,/#,}],#{?#{==:#{@claude_attn},done},#[${done_style//,/#,}],}}"
	fi
	attn_apply_format window-status-format "$prefix"
	attn_apply_format window-status-current-format "$prefix"
	if [ -n "$prefix" ]; then
		tmux set-option -g "$attn_applied_option" "$prefix"
	else
		tmux set-option -gu "$attn_applied_option"
	fi

	if [ "$enabled" = off ]; then
		for hook in $attn_hooks; do
			tmux set-hook -gu "${hook}[$attn_hook_slot]"
			tmux set-hook -gu "${hook}[$((attn_hook_slot + 1))]"
		done
		"$script" --stop
		return
	fi

	# Opening a window clears its done colour at once (no wait for the next check), then a check
	# records that you saw it. No output and exit 0, or the pane would go into view-mode.
	for hook in $attn_hooks; do
		tmux set-hook -g "${hook}[$attn_hook_slot]" "if-shell -F '#{==:#{@claude_attn},done}' 'set-option -wu @claude_attn'"
		tmux set-hook -g "${hook}[$((attn_hook_slot + 1))]" "run-shell -b '\"$script\" --tick >/dev/null 2>&1 || true'"
	done
	"$script" --start
}

function main {
	set_goto_session_bindings
	set_hub_bindings
	set_tidy_bindings
	set_attn
}
main
