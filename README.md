# TMUX FZF Claude Window Switch

![preview img](/img/preview.png)

## Features

This is a customized tmux session/window/pane switcher optimized for Claude Code workflows:

1. **Claude-focused filtering**: Shows only panes in windows named "claude" across all sessions
2. **Pane-level switching**: Switch directly to specific panes, not just windows
3. **Clean display format**: `<session-name>:<window-index>:[<pane-index>]: <pane-title> [dimensions]`
   - Example: `dictaphone:0:[1]: ✳ Project Structure [215x56]`
4. **No-prefix keybinding**: Default is `Ctrl+K` (no prefix required)
5. **Fuzzy search** with fzf for fast navigation
6. **Create new sessions** if the name doesn't exist

### Why this fork?

This fork is specifically designed for Claude Code users who:
- Work with multiple tmux sessions running Claude
- Want instant access to any Claude window across all sessions
- Prefer a cleaner, more focused display showing only relevant windows
- Need a fast, keyboard-driven workflow without prefix keys

### Display Format

The switcher shows panes in this format:
```
<session-name>:<window-index>:[<pane-index>]: <pane-title> [widthxheight]
```

Example output:
```
dictaphone:0:[1]: ✳ Project Structure [215x56]
iv-pro-copilot-v45:0:[0]: take one [215x58]
iv-pro-media-router:1:[2]: just-commands [215x56]
```

## Requirements

- [Tmux >= 3.3a](https://github.com/brokenricefilms/tmux-fzf-session-switch/pull/5/files) `pop-up menu`
- [fzf](https://github.com/junegunn/fzf)

## Getting started

- Install the [tpm](https://github.com/tmux-plugins/tpm) Tmux Plugin Manager.
- Put `set -g @plugin 'yourusername/tmux-fzf-claude-switch'` into your tmux config
- Use tpm to install this plugin. Default you can press `prefix + I` (`I` is
  `shift + i` = I)
- **Default keybinding**: `Ctrl + K` (no prefix required)
  - Press `Ctrl + K` to open the popup showing all "claude" panes
  - Type to fuzzy search through the list
  - Press Enter to switch to the selected pane
- If you type a name that doesn't exist, you will be prompted to create it.

> If this name conflicts with another session name -> add a double/single quotes `'example'`

## Customize

> 🫰Thanks to [@erikw](https://github.com/erikw)

### Key binding

```bash
set -g @fzf-goto-session 'key binding'
```

> Eg. to override the default session switcher in tmux available at `prefix` + s`:

```bash
set -g @fzf-goto-session 's'
```

#### Without prefix

The default is now `true` (no prefix required). To require a prefix:

```bash
set -g @fzf-goto-session-without-prefix 'false'
```

### Window dimensions

```bash
set -g @fzf-goto-win-width WIDTH
set -g @fzf-goto-win-height HEIGHT
```

> Eg.

```bash
set -g @fzf-goto-win-width 70
set -g @fzf-goto-win-height 20
```

## Tips

### Use in command line

```bash
function tmuxSessionSwitch() {
  session=$(tmux list-windows -a | fzf | sed 's/: .*//g')
  tmux switch-client -t "$session"
}
```

```bash
function tmux_kill_uname_session() {
  echo "kill all unname tmux session"
  cd /tmp/
  tmux ls | awk '{print $1}' | grep -o '[0-9]\+' >/tmp/killAllUnnameTmuxSessionOutput.sh
  sed -i 's/^/tmux kill-session -t /' killAllUnnameTmuxSessionOutput.sh
  chmod +x killAllUnnameTmuxSessionOutput.sh
  ./killAllUnnameTmuxSessionOutput.sh
  cd -
  tmux ls
}
```

> use with `clear` command is the best

```
alias clear='tmux_kill_uname_session ; clear -x'
```

### Easy to press

- In my use case, I don't use this keybinding for switch sessions, I use `hold space + ;` mapping for `hold Ctrl + a + f`
- How can I use `hold space + ;` mapping?
  -> I use [input remapper](https://github.com/sezanzeb/input-remapper), also you can see [my dotfiles](https://github.com/brokenricefilms/dotfiles)

> config in GUI

```python
space: if_single(key(KEY_SPACE), ,timeout=10000)
space + semicolon: KEY_RIGHTCTRL+a+f
```

![input remapper][img_input_remapper]

[img_input_remapper]: ./img/input_remapper.png
