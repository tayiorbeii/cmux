# Notifications

cmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

> For inline permission / plan / question approvals directly from the sidebar (Vibe Island-style), see **[Feed](feed.md)**. `cmux hooks setup` installs the Feed bridge alongside the notification hooks covered below.

## Quick Start

```bash
# Send a notification (if cmux is available)
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `cmux` CLI is available before using it:

```bash
# Shell
if command -v cmux &>/dev/null; then
    cmux notify --title "Hello"
fi

# One-liner with fallback
command -v cmux &>/dev/null && cmux notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("cmux"):
        subprocess.run(["cmux", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
cmux notify --title "Build Complete"

# With subtitle and body
cmux notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
cmux notify --title "Done" --tab 0 --panel 1
```

## Navigation

Use `Cmd+Shift+U` to jump to the latest unread notification. Use `Ctrl+Cmd+U` to mark the current item as oldest unread and jump to the next latest unread. Both shortcuts are configurable in Settings > Keyboard Shortcuts and in `~/.config/cmux/cmux.json`.

## Notification Hooks

`cmux.json` can define composable hooks that receive every notification policy as JSON on stdin and return updated JSON on stdout. Hooks are off by default; cmux only runs them when `notifications.hooks` contains at least one enabled hook. Hooks can filter native banners, sidebar history, sounds, custom commands, workspace reordering, and pane flashes.

```json
{
  "notifications": {
    "hooks": [
      {
        "id": "agent-filter",
        "command": "sed 's/\"desktop\":true/\"desktop\":false/'",
        "timeoutSeconds": 20
      }
    ]
  }
}
```

Hook input and output use this shape:

```json
{
  "version": 1,
  "notification": {
    "workspaceId": "3B3F0D83-...",
    "surfaceId": "7E9C1A02-...",
    "title": "Codex",
    "subtitle": "Waiting",
    "body": "Agent needs input"
  },
  "context": {
    "cwd": "/path/to/project",
    "configPath": "/path/to/project/.cmux/cmux.json",
    "hookId": "agent-filter",
    "appFocused": false,
    "focusedPanel": false
  },
  "effects": {
    "record": true,
    "markUnread": true,
    "reorderWorkspace": true,
    "desktop": true,
    "sound": true,
    "command": true,
    "paneFlash": true
  }
}
```

Global hooks from `~/.config/cmux/cmux.json` run first. Project hooks from parent directories to the current workspace append after that. Project hooks use the same trust prompt as other project `cmux.json` commands before they run. Feed approval banners also pass through these hooks; disabling `desktop` suppresses the native banner while keeping the Feed item available in cmux. Set `"hooksMode": "replace"` in a project `notifications` section to ignore inherited hooks. If any hook fails, times out, or returns invalid JSON, cmux uses the default notification behavior and posts a hook failure alert.

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### GitHub Copilot CLI

Copilot CLI supports [hooks](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks) that run shell commands at key lifecycle events. Add to `~/.copilot/config.json`:

```json
{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --body 'Done'; cmux set-status copilot_cli Idle; else osascript -e 'display notification \"Done\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --subtitle 'Error' --body \"$(cat | jq -r '.errorMessage // \"An error occurred\"' 2>/dev/null | head -c 100)\"; cmux set-status copilot_cli Error; else osascript -e 'display notification \"An error occurred\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}
```

Or for repo-level hooks, create `.github/hooks/notify.json`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v cmux &>/dev/null && cmux notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v cmux &>/dev/null && cmux notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

Create `.opencode/plugins/cmux-notify.js`:

```javascript
export const CmuxNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v cmux && cmux notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

> **Tip:** Set `hooksMode: "replace"` in a project `notifications` section to ignore inherited hooks.

## Tmux Alert Bridge

When you run tmux inside cmux, the **tmux alert bridge** forwards tmux activity alerts to cmux notifications. This is useful for AI agent workflows where you want to know when an agent finishes, needs input, or emits a bell.

### How It Works

Three tmux alert hooks are installed globally:

| Hook | Event | Trigger |
|------|-------|---------|
| `alert-bell` | **AI alert** | Bell character (`\a`) from any pane |
| `alert-activity` | **AI active** | Output detected after tmux silence period |
| `alert-silence` | **AI waiting** | No output for the monitor-silence interval |

Each hook calls `cmux hooks feed --source tmux-bridge` with pane+socket metadata, including tmux's pane title, window name, and current directory when available. The cmux socket routes each notification to the correct workspace, folds a concise pane/window context into the notification title, and includes the same context in the body.

For rich notification content from programs running inside tmux, prefer calling `cmux notify --title ... --body ...` directly. tmux consumes unwrapped OSC notification sequences such as `OSC 777`, so by the time cmux receives tmux's forwarded bell there is no title/body payload left to recover. The `cmux notify` CLI uses the cmux socket instead of terminal escape sequences and includes tmux pane metadata so notifications are routed back to the originating pane. When `--title` is omitted inside tmux, cmux uses concise tmux pane/window/command metadata as a title fallback instead of the generic "Notification" title; when `--subtitle` is omitted, it uses tmux session/window/pane location metadata. If no body is provided, cmux adds tmux command/directory context as a fallback body. These defaults are collected lazily in one tmux query only when a fallback is needed, keeping explicit direct notifications lightweight. For small shell scripts, `cmux notify --title "Build done" "All tests passed"` is equivalent to passing `--body`, `--body -`/`--message -` read piped or redirected stdin explicitly, `--body-file` reads from a log file, and piped stdin becomes the notification body when no body argument is provided. stdin/file bodies keep the last 16 KB by default before sending to the socket (configurable with `--body-max-bytes`, up to 64 KB) so accidental large logs stay lightweight while preserving the most recent output.

### Prerequisites

- You must run the install from a shell **inside cmux** (so `CMUX_SOCKET_PATH` is set).
- The installer embeds the current cmux socket path and prefers cmux's bundled CLI path when available, so the installed hooks keep working even if tmux's environment later loses `CMUX_SOCKET_PATH` or tmux's `PATH` does not resolve `cmux`.

### Install

```bash
# Install tmux bridge hooks
cmux hooks tmux install

# Or install everything at once (agents + tmux bridge)
cmux hooks setup
```

During `cmux hooks setup`, if tmux is detected on `PATH`, you're prompted to install the bridge. Pass `--yes` for unattended setup:

```bash
cmux hooks setup --yes
```

### What Gets Configured

`cmux hooks tmux install` sets these tmux session options and installs three hooks:

```
monitor-bell on
bell-action any
monitor-activity on
monitor-silence 15

alert-bell    → cmux hooks feed --source tmux-bridge --event bell ...
alert-activity → cmux hooks feed --source tmux-bridge --event activity ...
alert-silence  → cmux hooks feed --source tmux-bridge --event silence ...
```

### Test

1. Install the hooks: `cmux hooks tmux install`
2. Inside a tmux pane, send a bell: `printf '\a'`
3. You should see an "AI alert" notification in cmux's sidebar

To test activity/silence alerts, run a slow command (like `sleep 30`) and wait for the 15-second silence threshold.

### Verify

```bash
# Check all installed hooks
tmux show-hooks -g | grep cmux-tmux-bridge

# Check session options
tmux show-options -g | grep -E 'monitor-(bell|activity|silence)|bell-action'
```

### Uninstall

```bash
cmux hooks tmux uninstall
```

This removes only cmux-managed hooks (marked with `# cmux-tmux-bridge`) and leaves other hooks untouched.

## Environment Variables

cmux sets these in child shells:

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Path to control socket |
| `CMUX_TAB_ID` | UUID of the current tab |
| `CMUX_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
cmux notify --title <text> [--subtitle <text>] [--body <text|-> | --message <text|-> | --body-file <path|->] [--body-max-bytes <n>] [<body> | stdin] [--workspace <id|ref>] [--surface <id|ref>]
cmux list-notifications
cmux dismiss-notification (--id <notification-id> | --all-read)
cmux mark-notification-read (--id <notification-id> | --workspace <id|ref> [--surface <id|ref>] | --all)
cmux open-notification --id <notification-id>
cmux jump-to-unread
cmux clear-notifications
cmux set-status <key> <value>
cmux clear-status <key>
cmux ping
cmux hooks setup
cmux hooks tmux install
cmux hooks tmux uninstall
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
