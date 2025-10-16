# Remove Dead Code and Add Pane-Level Switching

## Overview

Clean up unreachable code in `main.tmux` by removing the session-only search option (which is always false), and enhance `switch_session_window.sh` to switch to specific panes instead of just windows.

## Current State Analysis

### Dead Code in main.tmux
- `default_search_session_only` is hardcoded to `false` (main.tmux:9)
- The `@fzf-claude-goto-session-only` option is defined but never actually used effectively
- Lines 47-59 in `main.tmux` contain unreachable code (the else branch for when `search_session_only=true`)
- The `scripts/switch_session.sh` file is referenced in the dead code block but never executed

### Current Pane Display vs Switching Mismatch
- `switch_session_window.sh:11-13` uses `tmux list-panes -a` to show pane-level information
- Display format: `session:window:[pane]: title [dimensions]`
- Example: `dictaphone:0:[1]: ✳ Project Structure [215x56]`
- However, the actual switching logic (line 26) only uses `session:window` format
- This means users see pane-specific information but can't actually switch to specific panes

## Desired End State

### Specification
After implementation:
1. `main.tmux` will have ~14 fewer lines of dead code
2. Only one code path for setting up goto session bindings
3. The `@fzf-claude-goto-session-only` option will be removed from documentation and code
4. File renamed: `switch_session_window.sh` → `switch_session_window_pane.sh`
5. Switching will use a two-step process: `tmux switch-client -t session:window` followed by `tmux select-pane -t session:window.pane`
6. Users can navigate directly to the exact pane they see in the fzf list

### Verification
- Run `tmux source-file main.tmux` successfully
- Press the keybinding and verify pane-level information displays correctly
- Select a pane and verify tmux switches to that exact pane (not just the window)
- Verify no errors in tmux command execution

## What We're NOT Doing

- Not adding new features beyond pane-level switching
- Not changing the fzf display format or filtering logic
- Not modifying the "create new session" workflow
- Not changing the default keybinding (Ctrl+K)
- Not removing `switch_session.sh` (it might be useful for users who want session-only switching in the future)

## Implementation Approach

This is a straightforward cleanup and enhancement task:
1. Remove dead code from `main.tmux`
2. Rename and update the switching script to handle pane-level targets
3. Update the main script to reference the new filename

## Phase 1: Remove Dead Code from main.tmux

### Overview
Simplify `main.tmux` by removing the unreachable `session_only=true` code path and related configuration options.

### Changes Required

#### 1. Remove session-only configuration
**File**: `main.tmux`
**Lines to remove**: 9, 15

```bash
# REMOVE these lines:
default_search_session_only=false
tmux_claude_option_search_session_only="@fzf-claude-goto-session-only"
```

#### 2. Simplify set_goto_session_bindings function
**File**: `main.tmux`
**Lines to modify**: 28-60

Replace the entire function with:

```bash
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
```

### Success Criteria

#### Automated Verification:
- [x] Syntax check passes: `bash -n main.tmux`
- [x] File has ~14 fewer lines of code
- [x] No references to `search_session_only` remain: `grep -n "search_session_only" main.tmux` returns empty

#### Manual Verification:
- [ ] `tmux source-file main.tmux` runs without errors
- [ ] Keybinding still triggers the popup

---

## Phase 2: Rename and Update Script for Pane-Level Switching

### Overview
Rename `switch_session_window.sh` to `switch_session_window_pane.sh` and update the switching logic to target specific panes.

### Changes Required

#### 1. Rename the script file
**Command**:
```bash
mv scripts/switch_session_window.sh scripts/switch_session_window_pane.sh
```

#### 2. Update pane extraction and switching logic
**File**: `scripts/switch_session_window_pane.sh`
**Lines to modify**: 6-10, 19, 24, 26

Currently the script extracts only `session:window`:
```bash
session=$(echo ${sess_arr[1]} | sed 's/:\[.*//g')
```

This removes everything from the first `[` onwards, losing the pane index.

**New approach**: Extract both the window target and the pane target separately, then perform a two-step switch.

**Complete updated function structure**:

The entire `main` function will be restructured. Here's the complete replacement:

```bash
function main {
  local sessions
  local query
  local sess_arr
  local retval
  local window_target
  local pane_target

  sessions=$(tmux list-panes -a -F "#{session_name}:#{window_index}:#{pane_index}|#{window_name}|#{pane_title}|#{pane_width}x#{pane_height}" | \
    grep '|claude|' | \
    awk -F'|' '{split($1, parts, ":"); print parts[1] ":" parts[2] ":[" parts[3] "]: " $3 " [" $4 "]"}' | \
    fzf --exit-0 --print-query --reverse)
  retval=$?

  IFS=$'\n' read -rd '' -a sess_arr <<<"$sessions"

  window_target=$(echo ${sess_arr[1]} | sed 's/:\[.*//g')
  pane_target=$(echo ${sess_arr[1]} | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/')
  query=${sess_arr[0]}

  if [ $retval == 0 ]; then
    # If user didn't select anything (just pressed Enter), use the query
    if [ "$window_target" == "" ]; then
      window_target=$(echo "$query" | sed 's/:\[.*//g')
      pane_target=$(echo "$query" | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/')
    fi

    # Validate window_target has session:window format before attempting switch
    # If user typed a new session name like "foo" or "foo.bar", redirect to create-new-session
    if [[ "$window_target" =~ ^[^:]+:[0-9]+$ ]]; then
      # Two-step switch: first to session/window, then to specific pane
      tmux switch-client -t "$window_target"

      # Only select pane if we have a valid pane target (must match session:window.pane pattern)
      # Regex validates: session_name:window_index.pane_index (e.g., "dictaphone:0.1")
      if [[ "$pane_target" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]]; then
        tmux select-pane -t "$pane_target"
      fi
    else
      # Invalid format: user typed a new session name, prompt to create it
      tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
        "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
    fi
  elif [ $retval == 1 ]; then
    tmux command-prompt -b -p "Press enter to create and go to [$query] session" \
      "run '$CURRENT_DIR/make_new_session.sh \"$query\" \"%1\"'"
  fi
}
```

**Changes summary**:
- **Removed**: `local session` variable (line 7 in original)
- **Added**: `local window_target` and `local pane_target` variables
- **Lines 19-26**: Completely rewritten with new variable extraction and conditional logic

**Key improvements in this rewrite:**

1. **Replaces `session` variable** with `window_target` and `pane_target` throughout
2. **Handles empty selection**: When user just presses Enter without selecting (empty `sess_arr[1]`), falls back to parsing the query string
3. **Validates window target format**: Only calls `switch-client` if `window_target` matches the pattern `^[^:]+:[0-9]+$`
   - Valid examples: `dictaphone:0`, `my-session:5` → calls `switch-client`
   - Invalid examples: `foo`, `foo.bar` → redirects to create-new-session prompt
   - This prevents "can't find session" errors when user types new session names
   - The regex ensures we have: `session_name:window_index` format
4. **Validates pane target format**: Only calls `select-pane` if `pane_target` matches the pattern `^[^:]+:[0-9]+\.[0-9]+$`
   - Valid examples: `dictaphone:0.1`, `my-session:5.2` → calls `select-pane`
   - Invalid examples: `foo`, `foo.bar`, `session:0` → skips `select-pane`
   - This prevents errors when user types new session names that happen to contain dots
   - The regex ensures we have: `session_name:window_index.pane_index` format
5. **Two-step switching** (only when window_target is valid):
   - First: `switch-client` to move to the correct session/window
   - Second: `select-pane` to focus the specific pane (only if pane format is valid)
6. **Graceful fallback**: When window_target is invalid, redirects to create-new-session workflow
7. **Preserves create-new-session flow** for both retval == 1 and invalid window_target cases

### Detailed Implementation Example

**Input from fzf** (line 13 output format):
```
dictaphone:0:[1]: ✳ Project Structure [215x56]
```

**Parsing strategy**:

For `window_target` (used by `switch-client`):
```bash
# From: "dictaphone:0:[1]: ✳ Project Structure [215x56]"
# To: "dictaphone:0"
sed 's/:\[.*//g'
```

For `pane_target` (used by `select-pane`):
```bash
# From: "dictaphone:0:[1]: ✳ Project Structure [215x56]"
# To: "dictaphone:0.1"
sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/'
```

The regex breakdown:
- `([^:]+)` - captures session name (dictaphone)
- `:` - literal colon
- `([^:]+)` - captures window index (0)
- `:\[` - literal `:[`
- `([^]]+)` - captures pane index (1)
- `\]:.*$` - matches the rest of the line
- Replacement: `\1:\2.\3` produces `session:window.pane`

### Success Criteria

#### Automated Verification:
- [x] File exists: `test -f scripts/switch_session_window_pane.sh`
- [x] Old file removed: `test ! -f scripts/switch_session_window.sh`
- [x] Syntax check passes: `bash -n scripts/switch_session_window_pane.sh`
- [x] Window target extraction works: `echo "dictaphone:0:[1]: test [100x50]" | sed 's/:\[.*//g'` outputs `dictaphone:0`
- [x] Pane target extraction works: `echo "dictaphone:0:[1]: test [100x50]" | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/'` outputs `dictaphone:0.1`
- [x] Invalid input doesn't transform: `echo "foo" | sed -E 's/^([^:]+):([^:]+):\[([^]]+)\]:.*$/\1:\2.\3/'` outputs `foo` (unchanged)
- [x] **Window target validation** - Regex validates valid window format: `[[ "dictaphone:0" =~ ^[^:]+:[0-9]+$ ]] && echo "valid"` outputs `valid`
- [x] **Window target validation** - Regex rejects simple name: `[[ "foo" =~ ^[^:]+:[0-9]+$ ]] || echo "invalid"` outputs `invalid`
- [x] **Window target validation** - Regex rejects name with dot: `[[ "foo.bar" =~ ^[^:]+:[0-9]+$ ]] || echo "invalid"` outputs `invalid`
- [x] **Pane target validation** - Regex validates valid pane format: `[[ "dictaphone:0.1" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]] && echo "valid"` outputs `valid`
- [x] **Pane target validation** - Regex rejects simple name: `[[ "foo" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]] || echo "invalid"` outputs `invalid`
- [x] **Pane target validation** - Regex rejects name with dot: `[[ "foo.bar" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]] || echo "invalid"` outputs `invalid`
- [x] **Pane target validation** - Regex rejects session without pane: `[[ "session:0" =~ ^[^:]+:[0-9]+\.[0-9]+$ ]] || echo "invalid"` outputs `invalid`

#### Manual Verification:
- [ ] Open tmux with multiple panes in a window
- [ ] Trigger the keybinding
- [ ] Select a specific pane from the list
- [ ] Verify tmux switches to the exact pane (not just the window)
- [ ] Verify the pane title matches what was displayed in fzf
- [ ] Test with panes in different windows and sessions
- [ ] **Test create-new-session (simple name)**: Type "mynewsession" and press Enter
  - Should show create-new-session prompt (no "can't find session" error)
  - Should NOT attempt switch-client or select-pane
- [ ] **Test create-new-session (name with dot)**: Type "foo.bar" and press Enter
  - Should show create-new-session prompt (no "can't find session" error)
  - Should NOT attempt switch-client or select-pane

---

## Phase 3: Update References and Documentation

### Overview
Update README.md to reflect the removal of the session-only option and document the new pane-level switching behavior.

### Changes Required

#### 1. Update README.md
**File**: `README.md`

Remove the "Search session only" section (lines 61-65):
```markdown
### Search session only

```bash
set-option -g @fzf-goto-session-only 'true'
```
```

Update the Features section to mention pane-level switching:
```markdown
## Features

This is a customized tmux session/window/pane switcher optimized for Claude Code workflows:

1. **Claude-focused filtering**: Shows only panes in windows named "claude" across all sessions
2. **Pane-level switching**: Switch directly to specific panes, not just windows
3. **Clean display format**: `<session-name>:<window-index>:[<pane-index>]: <pane-title> [dimensions]`
   - Example: `dictaphone:0:[1]: ✳ Project Structure [215x56]`
```

### Success Criteria

#### Automated Verification:
- [x] No references to `@fzf-goto-session-only` remain: `grep -r "session-only" README.md` returns empty
- [x] README mentions "pane-level switching"

#### Manual Verification:
- [ ] README accurately describes the current behavior
- [ ] Examples in README are correct
- [ ] No outdated configuration options documented

---

## Testing Strategy

### Unit-level Testing
Since these are bash scripts, testing is primarily through execution:
- Test sed regex patterns with sample input
- Verify file existence after renaming
- Check syntax with `bash -n`

### Integration Testing
- Test the full workflow in a live tmux session
- Create multiple sessions with multiple windows and panes
- Verify switching works correctly in all scenarios

### Manual Testing Steps

1. **Setup test environment**:
   ```bash
   # Create a test session with multiple panes
   tmux new-session -d -s test-session
   tmux split-window -h -t test-session
   tmux split-window -v -t test-session
   tmux rename-window -t test-session:0 "claude"

   # Create another session
   tmux new-session -d -s another-session
   tmux split-window -h -t another-session
   tmux rename-window -t another-session:0 "claude"
   ```

2. **Test pane switching**:
   - Attach to one session: `tmux attach -t test-session`
   - Trigger keybinding (default: Ctrl+K)
   - Verify all panes appear in the list with correct format
   - Select a pane from a different session
   - Verify switch goes to exact pane

3. **Test edge cases**:
   - Pane in current window (should still work)
   - Pane in different window of same session
   - Pane in different session entirely
   - Pane with special characters in title

4. **Test create new session flow**:
   - Type a non-existent session name
   - Verify prompt appears to create it
   - Create and verify switching works

## Performance Considerations

No performance impact expected:
- The sed regex is simple and runs once per selection
- File rename is a one-time operation
- Removing dead code slightly reduces script execution time

## Migration Notes

### For Existing Users

This is a backward-compatible change:
- Existing keybindings continue to work
- The behavior is enhanced (pane-level vs window-level) but not breaking
- Users don't need to change their configuration

### Deprecated Options

The `@fzf-goto-session-only` option is removed. If users have this in their tmux.conf:
- It will be silently ignored (no errors)
- Users can remove it from their config at their convenience
- No migration script needed

## References

- Main plugin file: `main.tmux`
- Switching script: `scripts/switch_session_window.sh` → `scripts/switch_session_window_pane.sh`
- Documentation: `README.md`
- Git history: Previous commit shows switch from `list-windows` to `list-panes` for better granularity (6749daa)
