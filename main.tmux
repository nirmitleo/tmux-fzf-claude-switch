#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_key_bindings_goto="C-k"
default_width=70
default_height=20
default_without_prefix=true

tmux_claude_option_goto="@fzf-claude-goto-session"
tmux_claude_option_goto_without_prefix="@fzf-claude-goto-session-without-prefix"
tmux_claude_option_width="@fzf-claude-goto-win-width"
tmux_claude_option_height="@fzf-claude-goto-win-height"

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

	if [ "$without_prefix" = true ]; then
		local key
		for key in $key_bindings; do
			tmux bind -n "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh"
		done
	else
		local key
		for key in $key_bindings; do
			tmux bind "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh"
		done
	fi
}

function main {
	set_goto_session_bindings
}
main
