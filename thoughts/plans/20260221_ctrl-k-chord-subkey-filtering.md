# Ctrl-K Chord: Sub-Key Filtering Implementation Plan

## Overview

Convert the single Ctrl-K binding into a chord prefix using tmux's custom key table, so that Ctrl-K then C filters for `claude` windows (current behavior) and Ctrl-K then S filters for `server` windows.

## Current State Analysis

- `main.tmux` binds `C-k` directly to a popup running `switch_session_window_pane.sh` (line 35)
- `switch_session_window_pane.sh` hard-codes `grep '|claude|'` on line 14
- The `set_goto_session_bindings` function reads 4 tmux options (key, without_prefix, width, height) and loops over key bindings
- `scripts/switch_session.sh` is dead code (not referenced anywhere)

## Desired End State

- Ctrl-K enters a custom key table `fzf-claude-switch`
- `c` in that table opens the fzf popup filtered to `claude` windows
- `s` in that table opens the fzf popup filtered to `server` windows
- Any other key silently exits the table (tmux default behavior)
- `switch_session_window_pane.sh` accepts a filter name as `$1`, defaulting to `claude`

### Verification

1. Press Ctrl-K, then C — fzf popup shows only panes in `claude` windows
2. Press Ctrl-K, then S — fzf popup shows only panes in `server` windows
3. Press Ctrl-K, then X (unmapped) — nothing happens, normal mode resumes
4. Tmux options `@fzf-claude-goto-session`, `@fzf-claude-goto-win-width`, `@fzf-claude-goto-win-height`, `@fzf-claude-goto-session-without-prefix` still work

## What We're NOT Doing

- No configurable sub-key mappings via tmux options (stretch goal deferred)
- No changes to `make_new_session.sh` or the session-creation flow
- No cleanup of `switch_session.sh` (dead code, separate concern)

## Code Path: Before (Current)

```
User presses Ctrl-K
       │
       ▼
 main.tmux: bind -n C-k
       │
       │  directly opens popup
       ▼
 ┌─────────────────────────────────┐
 │  tmux popup -E                  │
 │  switch_session_window_pane.sh  │
 │                                 │
 │  tmux list-panes -a             │
 │       │                         │
 │       ▼                         │
 │  grep '|claude|'  (hard-coded)  │
 │       │                         │
 │       ▼                         │
 │  awk (reformat)                 │
 │       │                         │
 │       ▼                         │
 │  fzf (user picks pane)          │
 │       │                         │
 │       ▼                         │
 │  tmux switch-client + select-pane│
 └─────────────────────────────────┘
```

## Code Path: After (New)

```
User presses Ctrl-K
       │
       ▼
 main.tmux: bind -n C-k
       │
       │  enters custom key table
       ▼
 switch-client -T fzf-claude-switch
       │
       ├── user presses C ──────────────────┐
       │                                     │
       ├── user presses S ───────────────┐   │
       │                                 │   │
       └── any other key ──► (no-op,     │   │
             returns to normal mode)     │   │
                                         │   │
          ┌──────────────────────────────┘   │
          │                                  │
          ▼                                  ▼
 ┌──────────────────────┐   ┌──────────────────────┐
 │  popup -E             │   │  popup -E             │
 │  ...script server     │   │  ...script claude     │
 │                       │   │                       │
 │  tmux list-panes -a   │   │  tmux list-panes -a   │
 │       │               │   │       │               │
 │       ▼               │   │       ▼               │
 │  grep '|server|'      │   │  grep '|claude|'      │
 │       │               │   │       │               │
 │       ▼               │   │       ▼               │
 │  awk ► fzf ► switch   │   │  awk ► fzf ► switch   │
 └──────────────────────┘   └──────────────────────┘
```

The key difference: a new **key table layer** sits between the initial keypress and the popup, routing to parameterized script invocations instead of a single hard-coded path.

## Implementation Approach

Two files change. The key table logic goes in `main.tmux`, and the script gets parameterized.

## Phase 1: Parameterize the Script

### Overview

Make `switch_session_window_pane.sh` accept a window name filter as its first argument.

### Changes Required

**File**: `scripts/switch_session_window_pane.sh`

Add a `FILTER_NAME` variable at the top of `main`, before the `sessions` assignment:

```bash
function main {
  local filter_name="${1:-claude}"
  local sessions
  # ...existing locals...
```

Replace the hard-coded grep:

```bash
  sessions=$(tmux list-panes -a -F "#{session_name}:#{window_index}:#{pane_index}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}" | \
    grep "|${filter_name}|" | \
    awk -F'|' '{split($1, parts, ":"); print parts[1] ":" parts[2] ":[" parts[3] "]: " $3 " [" $4 "]"}' | \
    fzf --exit-0 --print-query --reverse)
```

Pass `"$@"` from the script body into `main`:

```bash
main "$@"
```

### Success Criteria

- [x] `./scripts/switch_session_window_pane.sh claude` behaves identically to before
- [x] `./scripts/switch_session_window_pane.sh server` filters to `server` windows
- [x] Calling with no args defaults to `claude`

---

## Phase 2: Convert to Key Table in `main.tmux`

### Overview

Replace the direct popup binding with a custom key table chord.

### Changes Required

**File**: `main.tmux`

Replace `set_goto_session_bindings` with a new function that:

1. Reads the same tmux options (key, without_prefix, width, height)
2. Binds the key to `switch-client -T fzf-claude-switch` (respecting without_prefix)
3. Binds sub-keys `c` and `s` in the `fzf-claude-switch` table

```bash
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
	tmux bind -T fzf-claude-switch c popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh claude"
	tmux bind -T fzf-claude-switch s popup -w "$width" -h "$height" -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh server"
}
```

### Success Criteria

- [x] Ctrl-K then C opens fzf popup filtered to `claude`
- [x] Ctrl-K then S opens fzf popup filtered to `server`
- [x] Ctrl-K then any other key does nothing (returns to normal mode)
- [x] Custom width/height tmux options are respected
- [x] `without_prefix` setting is respected for the chord entry key
- [x] `tmux source-file` reloads cleanly

---

## References

- Ticket: `thoughts/tickets/ctrl-k-chord-subkey-filtering.md`
- tmux key tables: `bind-key -T` documentation
