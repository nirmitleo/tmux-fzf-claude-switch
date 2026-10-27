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

# Hub mode: prefix + h opens the cc-hub picker (`hub --tmux`) in a popup. Its size options
# (@fzf-claude-hub-width / -height / -autosize) are read by scripts/hub_popup.sh at each press.
default_hub_key="h"
default_hub_without_prefix=false

tmux_claude_option_hub_key="@fzf-claude-hub-key"
tmux_claude_option_hub_without_prefix="@fzf-claude-hub-without-prefix"

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
			tmux bind -n "$key" switch-client -T fzf-claude-switch
		done
	else
		local key
		for key in $key_bindings; do
			tmux bind "$key" switch-client -T fzf-claude-switch
		done
	fi

	# Bind sub-keys in the custom key table
	tmux bind -T fzf-claude-switch c popup -b rounded -T " claude " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh claude"
	tmux bind -T fzf-claude-switch s popup -b rounded -T " server " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh server"
	tmux bind -T fzf-claude-switch i popup -b rounded -T " index " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh index"
	tmux bind -T fzf-claude-switch t popup -b rounded -T " test " -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh test"
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

function set_hub_bindings {
	local key=$(get_tmux_option_allow_empty "$tmux_claude_option_hub_key" "$default_hub_key")
	local without_prefix=$(get_tmux_option "$tmux_claude_option_hub_without_prefix" "$default_hub_without_prefix")

	# Empty or "off" disables hub mode. Nothing is unbound, so a key of your own is left alone.
	if [ -z "$key" ] || [ "$key" = off ]; then
		return
	fi

	local table_flag=""
	if [ "$without_prefix" = true ]; then
		table_flag="-n"
	fi
	# hub_popup.sh sizes the popup to the picker, then opens it on this client. run-shell expands
	# the formats; -b so tmux does not wait on it.
	tmux bind $table_flag "$key" run-shell -b "\"$CURRENT_DIR/scripts/hub_popup.sh\" '#{client_name}' '#{pane_id}'"
}

function main {
	set_goto_session_bindings
	set_hub_bindings
}
main
