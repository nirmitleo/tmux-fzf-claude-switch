# List All Panes in Claude Windows Implementation Plan

## Overview

Update the tmux-fzf-claude-switch tool to display ALL panes from windows named "claude" instead of showing just one pane per session. This will allow users to see and switch to any specific pane within any claude window across all sessions.

## Current State Analysis

The current implementation in `scripts/switch_session_window.sh:11-13`:
- Uses `tmux list-windows -a` to get windows
- Filters for windows named "claude"
- Shows only one pane per session (the first pane's title)
- Display format: `session: title [dimensions]`
- Example output: `dictaphone: ✳ Project Structure [215x56]`

### Key Current Behavior:
```bash
tmux list-windows -a -F "#{session_name}:#{window_index}|#{window_name}|#{pane_title}|#{window_width}x#{window_height}" | \
  grep '|claude|' | \
  awk -F'|' '{gsub(/:.*/, "", $1); print $1 ": " $3 " [" $4 "]"}'
```

This shows only the window's first pane, not all panes within the window.

## Desired End State

The tool should:
1. List ALL panes from ALL windows named "claude"
2. Display format: `session:window:[pane]: title [dimensions]`
3. Example output:
   ```
   dictaphone:3:[0]: ✳ Project Structure [107x55]
   dictaphone:3:[1]: codex-review [107x55]
   iv-pro-copilot-v45:3:[0]: thought pool [71x16]
   iv-pro-copilot-v45:3:[1]: ✳ Agent Backup Methods [71x16]
   ```
4. When a user selects a pane, switch to that session and window (not the specific pane)
5. Include the current pane in the list (don't filter it out)

### Verification:
To verify the implementation works:
```bash
# 1. Open tmux with multiple sessions, each having a "claude" window with multiple panes
# 2. Press Ctrl+K (or configured keybinding)
# 3. Verify you see ALL panes from ALL claude windows
# 4. Select any pane from the list
# 5. Verify tmux switches to the correct session:window
```

## What We're NOT Doing

- NOT filtering out the current pane
- NOT switching to specific panes (only to session:window)
- NOT changing the keybinding or popup dimensions
- NOT modifying the session-only switcher (`switch_session.sh`)
- NOT changing the create-new-session flow

## Implementation Approach

The change is minimal and focused. We need to:
1. Replace `tmux list-windows -a` with `tmux list-panes -a`
2. Update the format string to include pane information
3. Adjust the awk processing to format output as `session:window:[pane]: title [dimensions]`
4. Update the sed pattern to extract `session:window` instead of just `session`

## Phase 1: Update Pane Listing Command

### Overview
Replace the window listing command with a pane listing command that captures all panes from claude windows.

### Changes Required:

#### 1. scripts/switch_session_window.sh:11
**File**: `scripts/switch_session_window.sh`
**Changes**: Replace `tmux list-windows` with `tmux list-panes` and update format string

**Current code (line 11):**
```bash
sessions=$(tmux list-windows -a -F "#{session_name}:#{window_index}|#{window_name}|#{pane_title}|#{window_width}x#{window_height}" | \
```

**New code:**
```bash
sessions=$(tmux list-panes -a -F "#{session_name}:#{window_index}:#{pane_index}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}" | \
```

**Reasoning**:
- `list-panes -a` lists all panes across all sessions instead of just windows
- Added `:#{pane_index}` to capture the pane number
- Changed `#{window_width}x#{window_height}` to `#{pane_width}x#{pane_height}` since we're now listing panes

#### 2. scripts/switch_session_window.sh:13
**File**: `scripts/switch_session_window.sh`
**Changes**: Update awk command to format output as `session:window:[pane]: title [dimensions]`

**Current code (line 13):**
```bash
awk -F'|' '{gsub(/:.*/, "", $1); print $1 ": " $3 " [" $4 "]"}' | \
```

**New code:**
```bash
awk -F'|' '{split($1, parts, ":"); print parts[1] ":" parts[2] ":[" parts[3] "]: " $3 " [" $4 "]"}' | \
```

**Reasoning**:
- Split the first field (session:window:pane) on colons
- Format as `session:window:[pane]: title [dimensions]`
- `parts[1]` = session name
- `parts[2]` = window index
- `parts[3]` = pane index
- `$3` = pane title
- `$4` = pane dimensions

#### 3. scripts/switch_session_window.sh:19
**File**: `scripts/switch_session_window.sh`
**Changes**: Update sed pattern to extract `session:window` instead of just `session`

**Current code (line 19):**
```bash
session=$(echo ${sess_arr[1]} | sed 's/: .*//g')
```

**New code:**
```bash
session=$(echo ${sess_arr[1]} | sed 's/:\[.*//g')
```

**Reasoning**:
- Previous pattern `s/: .*//g` removed everything after `: ` (keeping only session name)
- New pattern `s/:\[.*//g` removes everything after `:[` (keeping `session:window`)
- This allows us to switch to the correct window: `tmux switch-client -t "session:window"`

#### 4. scripts/switch_session_window.sh:24
**File**: `scripts/switch_session_window.sh`
**Changes**: Update sed pattern for query extraction (same as line 19)

**Current code (line 24):**
```bash
session=$(echo "$query" | sed 's/: .*//g')
```

**New code:**
```bash
session=$(echo "$query" | sed 's/:\[.*//g')
```

**Reasoning**:
- Same pattern adjustment for consistency
- Handles case where user types a partial match

### Success Criteria:

#### Automated Verification:
- [x] Script has valid bash syntax: `bash -n scripts/switch_session_window.sh`
- [x] No shellcheck warnings: `shellcheck scripts/switch_session_window.sh` (if installed)

#### Manual Verification:
- [x] Create a tmux session with a "claude" window containing multiple panes
- [x] Press the configured keybinding (default: Ctrl+K)
- [x] Verify ALL panes from ALL claude windows are listed
- [x] Verify format is `session:window:[pane]: title [dimensions]`
- [x] Select a pane from a different session/window
- [x] Verify tmux switches to the correct session:window
- [x] Verify the current pane IS included in the list
- [x] Test with sessions that have multiple claude windows
- [ ] Test selection when no exact match exists (create new session flow)

## Testing Strategy

### Unit Tests:
This is a shell script with no existing test framework. Manual testing is the primary approach.

### Manual Testing Steps:

1. **Setup Test Environment:**
   ```bash
   # Create test sessions with multiple panes
   tmux new-session -d -s test1
   tmux new-window -t test1 -n claude
   tmux split-window -t test1:claude -h
   tmux split-window -t test1:claude -v

   tmux new-session -d -s test2
   tmux new-window -t test2 -n claude
   tmux split-window -t test2:claude -h
   ```

2. **Test Basic Listing:**
   - Press Ctrl+K
   - Verify you see all 5 panes (3 from test1, 2 from test2)
   - Verify format matches: `test1:1:[0]: ... [dimensions]`

3. **Test Switching:**
   - From test1, press Ctrl+K
   - Select a pane from test2
   - Verify you switched to test2:1 (the claude window)

4. **Test Current Pane Inclusion:**
   - Verify the current pane appears in the list
   - It should not be filtered out

5. **Test Edge Cases:**
   - Sessions with no claude windows (should show empty list)
   - Sessions with multiple claude windows (all panes from all claude windows should appear)
   - Panes with special characters in titles

6. **Cleanup:**
   ```bash
   tmux kill-session -t test1
   tmux kill-session -t test2
   ```

## Performance Considerations

- `tmux list-panes -a` may return more results than `tmux list-windows -a` if there are many panes
- fzf handles large lists efficiently, so performance impact should be minimal
- The grep filter `|claude|` reduces the list to only relevant items

## Migration Notes

This is a backwards-compatible change:
- No configuration changes required
- Keybindings remain the same
- Users will simply see more items in the list (all panes instead of just one per session)
- The selection behavior changes slightly: now targets `session:window` instead of just `session`, but this is transparent to the user

## References

- Original script: `scripts/switch_session_window.sh`
- Main plugin entry point: `main.tmux`
- Documentation: `README.md`
- tmux format variables: https://man7.org/linux/man-pages/man1/tmux.1.html#FORMATS
