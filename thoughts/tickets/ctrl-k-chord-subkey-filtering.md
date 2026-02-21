# Ctrl-K Chord: Sub-Key Filtering by Window Name

## Problem

Currently, Ctrl-K is a single key binding that always filters panes to windows named `claude`. There is no way to quickly filter for other window names (e.g., `server`) without modifying the script. As usage grows, users need a fast way to switch between different categories of panes.

## Context

- **Key binding**: `main.tmux` binds `Ctrl-K` (no prefix) via `tmux bind -n C-k popup -E .../switch_session_window_pane.sh`
- **Filter logic**: `scripts/switch_session_window_pane.sh` line 14 hard-codes `grep '|claude|'` to filter `tmux list-panes -a` output
- **Architecture**: The script runs inside a `tmux popup -E` — it auto-closes when done
- **Key tables**: tmux supports custom key tables via `bind-key -T <table>`, which is the standard mechanism for chord/prefix key sequences

## Proposed Solution

Use a **tmux custom key table** to make Ctrl-K a chord prefix with sub-keys.

### 1. Define a custom key table in `main.tmux`

Instead of binding Ctrl-K directly to a popup, bind it to switch into a custom key table:

```bash
tmux bind -n C-k switch-client -T fzf-claude-switch
```

Then bind sub-keys within that table:

```bash
tmux bind -T fzf-claude-switch c popup -w 70 -h 20 -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh claude"
tmux bind -T fzf-claude-switch s popup -w 70 -h 20 -y 15 -E "$CURRENT_DIR/scripts/switch_session_window_pane.sh server"
```

### 2. Parameterize the filter in `switch_session_window_pane.sh`

Accept an argument for the window name filter instead of hard-coding `claude`:

```bash
FILTER_NAME="${1:-claude}"

sessions=$(tmux list-panes -a -F "..." | \
  grep "|${FILTER_NAME}|" | \
  awk ... | \
  fzf ...)
```

### 3. Make sub-keys configurable (optional stretch)

Allow users to define additional filter mappings via tmux options, e.g.:

```
set -g @fzf-claude-filter-c "claude"
set -g @fzf-claude-filter-s "server"
```

## Implementation Checklist

- [ ] Modify `main.tmux` to bind `C-k` to `switch-client -T fzf-claude-switch` instead of directly to the popup
- [ ] Add sub-key bindings in the custom key table (`c` for claude, `s` for server)
- [ ] Update `switch_session_window_pane.sh` to accept a filter name as `$1` (default to `claude` for backward compat)
- [ ] Replace the hard-coded `grep '|claude|'` with `grep "|${FILTER_NAME}|"`
- [ ] Update popup dimensions/position variables to be shared across sub-key bindings (DRY)
- [ ] Test: Ctrl-K then C shows only `claude` panes
- [ ] Test: Ctrl-K then S shows only `server` panes
- [ ] Test: Pressing an unmapped key after Ctrl-K returns to normal mode (tmux default behavior for custom key tables)

## Success Criteria

1. Pressing Ctrl-K, then C opens the fzf popup filtered to `claude` windows (identical to current behavior)
2. Pressing Ctrl-K, then S opens the fzf popup filtered to `server` windows
3. Pressing Ctrl-K, then any unmapped key does nothing and returns to normal mode
4. Existing tmux option overrides (`@fzf-claude-goto-session`, width, height, without-prefix) continue to work

## Notes

- **tmux custom key tables** auto-expire after one keypress — no timeout or cancel key needed. If the user presses an unbound key, tmux silently returns to the root table.
- The `without_prefix` option should apply to the initial Ctrl-K chord entry, not the sub-keys (sub-keys are always in the custom table).
- Future sub-keys can be added trivially (e.g., `d` for `docker`, `t` for `test`).
