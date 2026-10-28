# TMUX FZF Claude Window Switch

![preview img](/img/preview.png)

## Features

This is a customized tmux session/window/pane switcher optimized for Claude Code workflows:

1. **Chord-based filtering**: `Ctrl+K` is a chord prefix — press a sub-key to filter by window name
   - `Ctrl+K` → `c` — panes in windows named `claude`
   - `Ctrl+K` → `s` — panes in windows named `server`
   - `Ctrl+K` → `i` — panes in windows named `index`
   - `Ctrl+K` → `t` — panes in windows named `test`
   - `Ctrl+K` → `h` — [hub mode](#hub-mode)
   - Any other key after `Ctrl+K` — silently exits (tmux default behavior)
2. **Pane-level switching**: Switch directly to specific panes, not just windows
3. **Clean display format**: aligned columns with Claude's working/idle status and time since the last message
   - Example: `working  12s ago  dictaphone  0.1  Project Structure`
4. **No-prefix keybinding**: Default is `Ctrl+K` (no prefix required)
5. **Fuzzy search** with fzf for fast navigation
6. **Create new sessions** if the name doesn't exist
7. **Hub mode**: `Ctrl+K` → `h` opens the [cc-hub](#hub-mode) picker (projects, coordinators, threads) in a popup
   - Claude panes that belong to a hub project get a dim `hub:<project>` or `hub:<project>/<thread>` tag
     in the `Ctrl+K` → `c` switcher
   - Panes of [archived](#archived-projects) hub projects are hidden; `ctrl-r` shows them

### Why this fork?

This fork is specifically designed for Claude Code users who:
- Work with multiple tmux sessions running Claude, servers, or test runners
- Want instant access to any specific window type across all sessions
- Prefer a cleaner, more focused display showing only relevant windows
- Need a fast, keyboard-driven workflow without prefix keys

### Display Format

The switcher shows one pane per row under a pinned column header. Claude panes are sorted by most recent
activity; other panes follow with the first two columns blank:
```
STATUS   LAST MSG  SESSION                 PANE  TITLE
working  12s ago   tmux-fzf-claude-switch  5.1   Claude pane message timer
idle     4m ago    tmux-wrangler           4.1   Tmux session name collision
idle     1h ago    iv-pro-baby             4.1   Push remaining changes
```

- `STATUS`: `working` (yellow) while Claude is running, `idle` (dim) when it is waiting for you.
- `LAST MSG`: time since the last user or assistant message (green under 10m, dim past 1h).
- `SESSION`: each tmux session gets its own colour, the same in every popup.
- `PANE`: `<window-index>.<pane-index>` within the session.

Press `ctrl-s` to switch the order between `recent` (Claude panes by last activity) and `session`
(alphabetical); the prompt shows the active order. While you type, fzf ranks rows by match quality instead.
With hub installed, `ctrl-r` shows or hides the panes of [archived hub projects](#archived-projects)
(the prompt then reads `recent +archived ❯`).

The status and age come from Claude Code's session registry (`~/.claude/sessions/<pid>.json`, whose `tmux` field
records the pane ID) and the tail of that session's transcript (`~/.claude/projects/*/<sessionId>.jsonl`).
`CLAUDE_CONFIG_DIR` is respected. The `session:window.pane` switch target is carried in a hidden fzf field, so
it is not shown or searched.

## Hub mode

`hub` is a CLI that runs Claude Code "projects": a coordinator session plus background thread
sessions that share a memory. Bare `hub` opens an fzf picker of every project with its
coordinator and threads, in the style of `claude agents`.

Press `Ctrl+K` then `h` (the same chord as `c`/`s`/`i`/`t`) from anywhere in tmux to open that
picker in a popup.
The popup runs `hub --tmux`: choosing a session switches to the tmux pane where it is already
open, or opens a new tmux window running it, and the popup closes.

- Needs a `hub` that supports `--tmux` (its `hub help` lists `--tmux`). hub is looked up on the
  popup's `PATH`, then at `$CLAUDE_HUB/bin/hub` and `~/claude-hub/bin/hub`. If it is missing or
  too old, the popup says so and waits for a key.
- The popup is sized to the picker. `hub --tmux-size <maxcols> <maxrows>` is asked how much room the
  picker needs (inside the border) and the popup is opened at that size, never larger than the
  width/height options below, which are maximums. A hub without `--tmux-size` (not in its `hub help`),
  or one that fails, prints something unexpected or takes over 2 seconds, gets the maximum size.
- `CLAUDE_HUB` (the hub root, default `~/claude-hub`) is passed through, including when it is only
  set in the tmux environment (`tmux set-environment -g CLAUDE_HUB ...`).
- In the `Ctrl+K` → `c` switcher, a Claude pane whose session is a hub coordinator (`<project>-coord`)
  is tagged `hub:<project>`, a thread (`<project>--<slug>`) `hub:<project>/<slug>`, and any other
  session started inside `$CLAUDE_HUB/projects/<project>` `hub:<project>`. The tag is dim, sits at
  the start of the title and can be searched (type `hub:`). Without a hub install nothing changes.

### Archived projects

A hub project is archived when the file `$CLAUDE_HUB/projects/<project>/.archived` exists. hub's
`hub archive <project>` and `hub unarchive <project>` (in hub versions that have them) create and
remove it; `touch` and `rm` do the same by hand. Only the file's existence matters (hub writes the
date into it).

Archiving only hides. In the `Ctrl+K` switchers (`c`, and `s`/`i`/`t` when a Claude pane sits in
such a window), the panes of an archived project's coordinator, threads and other sessions are left
out. Nothing is stopped, killed, renamed or moved, and other rows keep their order and colours. To
reach them:

- Press `ctrl-r` in the switcher to show archived rows, and again to hide them. Shown, a row is dim
  and tagged `hub:<project> archived` (type `archived` to find them). `ctrl-s` keeps the choice.
- Or set `@fzf-claude-show-archived` to `on` to show them every time the switcher opens (`ctrl-r`
  still hides them). It is read each time the popup opens, so no reload is needed.

If every row is archived, the popup still opens (empty, with the `ctrl-r` hint) instead of closing
straight away.

Hub mode (`Ctrl+K` → `h`) is not filtered by the plugin: `hub --tmux` decides what its picker shows.

Options (defaults shown):

```bash
set -g @fzf-claude-show-archived 'off'         # 'on' lists archived hub projects' panes in the switcher
set -g @fzf-claude-hub-key 'h'                 # '' or 'off' disables hub mode
set -g @fzf-claude-hub-table 'chord'           # chord: Ctrl+K then the key; prefix: prefix + key;
                                               # root: the key alone, no prefix
set -g @fzf-claude-hub-autosize 'on'           # 'off' always opens the popup at the maximum size
set -g @fzf-claude-hub-width '90%'             # maximum popup width: a % of the client or columns
set -g @fzf-claude-hub-height '85%'            # maximum popup height: a % of the client or rows
```

In the chord table, pick a key other than `c`, `s`, `i` and `t`, or hub mode replaces that filter.
`@fzf-claude-hub-without-prefix 'true'`, from earlier versions, still works and means `root`; an
explicit `@fzf-claude-hub-table` wins over it. To keep the old `prefix + h`:

```bash
set -g @fzf-claude-hub-table 'prefix'
```

On each load the plugin first removes the hub binding it made before (in any of the three tables),
so changing the key or table, turning hub mode off, or upgrading from `prefix + h` leaves nothing
stale behind. A key of your own (one that does not run this plugin's hub scripts) is never
unbound. The key options need a plugin reload (`tmux source ~/.tmux.conf` or `prefix + I`). The
size options are read each time you press the key.

## Requirements

- [Tmux >= 3.3a](https://github.com/brokenricefilms/tmux-fzf-session-switch/pull/5/files) `pop-up menu`
- [fzf >= 0.53](https://github.com/junegunn/fzf) (for `--highlight-line`)

## Getting started

- Install the [tpm](https://github.com/tmux-plugins/tpm) Tmux Plugin Manager.
- Put `set -g @plugin 'yourusername/tmux-fzf-claude-switch'` into your tmux config
- Use tpm to install this plugin. Default you can press `prefix + I` (`I` is
  `shift + i` = I)
- **Default keybinding**: `Ctrl + K` (chord prefix, no tmux prefix required)
  - Press `Ctrl + K` to enter the chord, then press a sub-key:
    | Sub-key | Filter |
    |---------|--------|
    | `c` | windows named `claude` |
    | `s` | windows named `server` |
    | `i` | windows named `index` |
    | `t` | windows named `test` |
    | `h` | [hub mode](#hub-mode) (the cc-hub picker) |
    | any other key | exits silently |
  - Type to fuzzy search through the filtered list
  - Press Enter to switch to the selected pane
- If you type a name that doesn't exist, you will be prompted to create it.

> If this name conflicts with another session name -> add a double/single quotes `'example'`

## Tests

`tests/run.sh` drives the plugin in throwaway tmux servers (sockets `hubmodetest` and
`hubmodetest-outer`, `-f /dev/null`), so your own tmux server and config are not touched. It checks
the key bindings, `hub_mode.sh` with stub `hub` executables, real `Ctrl+K` `h`/`c`/`s` presses through
an attached client, the hub tag and archived projects (hidden, `--list ... on`, `ctrl-r`/`ctrl-s`,
`@fzf-claude-show-archived`; with the real fzf too when it is installed) against a fake `CLAUDE_CONFIG_DIR`. Run it with both bashes, since tmux
`run-shell` may use macOS's bash 3.2:

```bash
bash tests/run.sh
/bin/bash tests/run.sh
```

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
