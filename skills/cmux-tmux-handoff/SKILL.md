---
name: cmux-tmux-handoff
description: "Relaunch a focused or targeted cmux terminal pane into local tmux. Use when the user says tmux handoff, hand off pane to tmux, relaunch in tmux, local tmux transfer, or remote handoff compatibility."
---

# cmux Tmux Handoff

Relaunch the focused (or explicitly targeted) cmux terminal pane so it runs a local tmux client in place.

## What it does

1. Resolves the focused or targeted cmux terminal pane.
2. Builds a local tmux launch command rooted at that pane's working directory.
3. Replaces/relaunches the pane in place with `tmux new-session -A -s <name>`.
4. Optionally prints/copies an `ssh <host> -t tmux attach -t <name>` line only when `--host` is explicitly passed.

No coding-agent snapshot detection is required. `--mode fork|handoff` is accepted for compatibility with older commands but does not change the local tmux relaunch behavior.

## Prerequisites

- **tmux must be installed** on the local machine. On macOS: `brew install tmux`.
- The target must be a terminal pane.

## Entrypoints

All entrypoints funnel through the same shared action — behavior is identical across surfaces.

### CLI (`cmux handoff`)

```bash
# Relaunch the focused terminal pane into local tmux
cmux handoff

# Also print/copy an explicit SSH attach line for that tmux session
cmux handoff --host desktop.local

# Target a specific pane
cmux handoff --name devbox --workspace workspace:1 --surface surface:2
```

### Command Palette

Open the Command Palette (default: `cmd+shift+p`) and type "Tmux Handoff". The action appears with the title "Tmux Handoff" and relaunches the focused terminal pane in local tmux.

### Window menu + keyboard shortcut

The Window menu has a "Tmux Handoff…" item. The action ships **unbound** by default — bind a shortcut in **Settings → Keyboard Shortcuts** (action: "Tmux Handoff…").

### Custom command (cmux.json)

Register the builtin in `~/.config/cmux/cmux.json` to surface it in the surface tab bar, plus-button menu, or with a keyboard shortcut:

```json
{
  "actions": {
    "handoff": {
      "builtin": "cmux.remoteHandoff",
      "palette": true
    }
  }
}
```

Aliases `remoteHandoff`, `cmux.tmuxHandoff`, and `tmuxHandoff` are also accepted.

## Flags and options

| Flag | Description |
|------|-------------|
| `--mode fork\|handoff` | Accepted for compatibility; no effect in the local tmux relaunch flow. |
| `--name <tmux-session>` | Override the tmux session name (default: `cmux-<workspace>-<surface>`). |
| `--host <ssh-host>` | Explicitly print/copy an `ssh … tmux attach` line. |
| `--workspace <id\|ref\|index>` | Target workspace (default: focused). |
| `--surface <id\|ref\|index>` | Target pane (default: focused). |
| `--panel <id\|ref\|index>` | Alias for `--surface`. |
| `--window <id\|ref\|index>` | Target window (default: current). |
| `--no-copy` | Don't copy the SSH attach line when `--host` is set. |
| `--json` | Emit machine-readable JSON. |

## Session name rules

- Default: `cmux-<workspace-prefix>-<surface-prefix>`.
- Custom names must not contain `.` or `:` (tmux restriction).
- Empty, whitespace-only, or invalid names are rejected.

## See also

- [Remote tmux (beta)](https://cmux.com/docs/remote-tmux) — the adjacent feature that mirrors a remote tmux session into cmux's native UI.
- [Keyboard shortcuts](https://cmux.com/docs/keyboard-shortcuts) — bind the Tmux Handoff action.
- [Custom commands](https://cmux.com/docs/custom-commands) — register `cmux.remoteHandoff` as a builtin action.
