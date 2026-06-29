---
name: cmux-tmux-handoff
description: "Hand off a coding agent conversation to a detached tmux session over SSH. Use when the user says tmux handoff, hand off agent to tmux, resume agent over ssh, ssh handoff, or remote handoff."
---

# cmux Tmux Handoff

Hand off the coding agent running in a focused cmux pane to a detached tmux session so the conversation can be SSH'd into from another machine.

## What it does

1. Detects the coding agent running in the focused (or targeted) cmux pane.
2. Creates a named, detached tmux session rooted at that conversation's working directory.
3. Resumes (or forks) the conversation inside the tmux session.
4. Prints (and copies to clipboard) an `ssh <host> -t tmux attach -t <name>` line.

**Fork is the default** — the original conversation is left untouched and a new branch session is created inside tmux. Pass `--mode handoff` to resume the original session in place.

## Prerequisites

- **tmux must be installed** on both the local machine (creates the session) and the remote host (attach target). On macOS: `brew install tmux`.
- The target pane must have a detectable coding agent running (Claude Code, Codex, pi, OpenCode, Gemini CLI, Cursor Agent, etc.).

## Entrypoints

All entrypoints funnel through the same shared action — behavior is identical across surfaces.

### CLI (`cmux handoff`)

```bash
# Fork the focused pane's agent into a tmux session
cmux handoff

# Hand off in place (resume, don't fork)
cmux handoff --mode handoff --host desktop.local

# Target a specific pane
cmux handoff --name myagent --workspace workspace:1 --surface surface:2
```

### Command Palette

Open the Command Palette (default: `cmd+shift+p`) and type "Tmux Handoff". The action appears with the title "Tmux Handoff" and subtitle "Hand off this agent to a tmux session over ssh".

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

Aliases `cmux.tmuxHandoff` and `tmuxHandoff` are also accepted.

## Flags and options

| Flag | Description |
|------|-------------|
| `--mode fork\|handoff` | `fork` (default): branch a new session, original untouched. `handoff`: resume in place. |
| `--name <tmux-session>` | Override the tmux session name (default: `<agent>-<first8 of session id>`). |
| `--host <ssh-host>` | Host printed in the `ssh … tmux attach` line. |
| `--workspace <id\|ref\|index>` | Target workspace (default: focused). |
| `--surface <id\|ref\|index>` | Target pane (default: focused). |
| `--panel <id\|ref\|index>` | Alias for `--surface`. |
| `--window <id\|ref\|index>` | Target window (default: current). |
| `--no-copy` | Don't copy the ssh line to the clipboard. |
| `--json` | Emit machine-readable JSON. |

## Session name rules

- Default: `<agentID>-<first8 of sessionId>` (e.g. `pi-a1b2c3d4`).
- Custom names must not contain `.` or `:` (tmux restriction).
- Empty, whitespace-only, or invalid names are rejected.

## See also

- [Remote tmux (beta)](https://cmux.com/docs/remote-tmux) — the thematically adjacent feature that mirrors a remote tmux session into cmux's native UI.
- [Keyboard shortcuts](https://cmux.com/docs/keyboard-shortcuts) — bind the Tmux Handoff action.
- [Custom commands](https://cmux.com/docs/custom-commands) — register `cmux.remoteHandoff` as a builtin action.
