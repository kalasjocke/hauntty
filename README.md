# hauntty

hauntty is a macOS terminal for working in tmux with coding agents. It is
built on libghostty, the terminal core of [Ghostty](https://ghostty.org), so
it renders and reads its config the way Ghostty does.

## Why it exists

Running tmux inside a regular terminal gives you two sets of tabs: the
terminal's own and tmux's status bar. hauntty has only one. Each window holds
a single Ghostty surface running tmux, and the tab bar shows one native tab
per window of the session it shows. tmux owns all the state. Creating,
closing, renaming and reordering windows happens in tmux, and the tabs follow.
Detach, and the session keeps running for the next window or an ssh login.

A new window opens the session `hauntty`. Switch to another session in tmux,
with `switch-client` or `choose-tree`, and the tabs switch with it.

Coding agents such as Claude Code run for minutes at a time, usually several
at once in different windows. hauntty shows what each one is doing without
having to switch to it:

- A program reports its state by setting the `@state` window option, for
  example from a Claude Code hook: `tmux set -w @state working`. The states
  are `idle`, `working`, `done`, `blocked` and `error`, from the
  [OSC 7501 proposal](https://mitchellh.com/writing/program-status-osc7501).
  Each tab shows its window's state as a dot.
- A `done` state shows on background tabs only. hauntty clears it when you
  switch to the tab.
- A tab that runs Claude Code is titled with the name of the session it
  shows, from the pane title Claude Code sets.
- Each tab shows a tile per pane and an icon for the focused program.

Because the state lives in tmux, scripts and agents can read and set it with
plain tmux commands, and the tmux status bar can color itself from the same
option.

## Requirements

- macOS 26 or later.
- tmux.
- Zig, at the version the pinned Ghostty commit needs, to build libghostty.

## Build

```sh
git clone --recurse-submodules https://github.com/kalasjocke/hauntty
scripts/build-ghosttykit.sh   # builds vendor/GhosttyKit.xcframework
scripts/bundle.sh             # builds build/Hauntty.app
swift test
```

hauntty reads your Ghostty config from `~/.config/ghostty/config`. Its tab
bar replaces the tmux status bar, so hauntty turns the status bar off for
every session it shows.
