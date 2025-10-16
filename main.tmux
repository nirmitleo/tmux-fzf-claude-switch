#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_key_bindings_goto="C-F"
default_width=70
default_height=20
default_without_prefix=true
default_search_session_only=false

tmux_option_goto="@fzf-goto-session"
tmux_option_goto_without_prefix="@fzf-goto-session-without-prefix"
tmux_option_width="@fzf-goto-win-width"
tmux_option_height="@fzf-goto-win-height"
tmux_option_search_session_only="@fzf-goto-session-only"

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
	local key_bindings=$(get_tmux_option "$tmux_option_goto" "$default_key_bindings_goto")
	local without_prefix=$(get_tmux_option "$tmux_option_goto_without_prefix" "$default_without_prefix")
	local width=$(get_tmux_option "$tmux_option_width" "$default_width")
	local height=$(get_tmux_option "$tmux_option_height" "$default_height")
	local search_session_only=$(get_tmux_option "$tmux_option_search_session_only" "$default_search_session_only")

	if [ "$search_session_only" = false ]; then
		if [ "$without_prefix" = true ]; then
			local key
			for key in $key_bindings; do
				tmux bind -n "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window.sh"
			done
		else
			local key
			for key in $key_bindings; do
				tmux bind "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window.sh"
			done
		fi
	else
		if [ "$without_prefix" = true ]; then
			local key
			for key in $key_bindings; do
				tmux bind -n "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session.sh"
			done
		else
			local key
			for key in $key_bindings; do
				tmux bind "$key" popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session.sh"
			done
		fi
	fi
}

function main {
	set_goto_session_bindings
}
main
