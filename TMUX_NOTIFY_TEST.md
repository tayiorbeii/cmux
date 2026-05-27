# Testing Claude Notifications Through tmux

This guide tests the **cmux notification passthrough** pipeline end-to-end:
Claude Code → hooks → `cmux hooks feed` → OSC 777 → DCS tmux passthrough → macOS notification.

## Prerequisites

1. **Tagged build running** — launch the tagged app:
   ```
   open "/Users/taylor/Library/Developer/Xcode/DerivedData/cmux-tmux-native-notify-passthrough/Build/Products/Debug/cmux DEV tmux-native-notify-passthrough.app"
   ```

2. **tmux installed** — `which tmux`

3. **Claude Code hooks must include a Notification entry**. Currently your `~/.claude/settings.json` does **not** have one configured. You need to add it.

---

## Step 1: Add a Notification hook to Claude Code

Add this to `~/.claude/settings.json` under the `"hooks"` key:

```json
"Notification": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "/tmp/cmux-cli hooks feed --source claude"
      }
    ]
  }
]
```

This tells Claude Code: whenever a notification fires (input needed, task complete, error, etc.), pipe the JSON to `cmux hooks feed --source claude`.

If you want to keep the existing `alertTab()` behavior from `Notification.ts`, use this instead:

```json
"Notification": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "bash -c '/tmp/cmux-cli hooks feed --source claude; bun run ~/.claude/hooks/Notification.ts'"
      }
    ]
  }
]
```

---

## Step 2: Start tmux inside the tagged cmux build

In the tagged cmux app's terminal:

```bash
# Verify the tagged CLI is active
/tmp/cmux-cli --version

# Start a tmux session
tmux new -s notify-test
```

Now you're **inside tmux, inside the tagged cmux build**.

---

## Step 3: Verify the passthrough escape works manually

Before testing Claude, confirm the raw OSC 777 passthrough works through tmux:

```bash
# This should produce a macOS notification titled "Test"
printf '\033Ptmux;\033\033]777;notify;Test;Hello from tmux\033\033\\\033\\'
```

If you see a macOS notification → the DCS passthrough pipeline is working. Proceed to Step 4.

If you do **not** see a notification:
- Confirm you're in the tagged build (check the app title bar)
- Check that the Ghostty DCS handler compiled: `grep -c tmux_passthrough /Users/taylor/Library/Developer/Xcode/DerivedData/cmux-tmux-native-notify-passthrough/Build/Products/Debug/cmux\ DEV\ tmux-native-notify-passthrough.app/Contents/Frameworks/GhosttyKit.framework/Versions/A/Resources/ghostty 2>/dev/null || echo "binary check failed"`

---

## Step 4: Test `cmux hooks feed` directly

Simulate what Claude Code's Notification hook would send:

```bash
# Permission request (should show "Permission" subtitle)
echo '{"hook_event_name":"Notification","event":"permission_prompt","message":"Allow access to ~/projects?"}' | /tmp/cmux-cli hooks feed --source claude
```

```bash
# Task completed (should show "Completed" subtitle)
echo '{"hook_event_name":"Notification","message":"Task completed successfully"}' | /tmp/cmux-cli hooks feed --source claude
```

```bash
# Waiting for input (should show "Waiting" subtitle)
echo '{"hook_event_name":"Notification","event":"idle","message":"Waiting for your input"}' | /tmp/cmux-cli hooks feed --source claude
```

```bash
# Error notification (should show "Error" subtitle)
echo '{"hook_event_name":"Notification","message":"Build failed with exit code 1"}' | /tmp/cmux-cli hooks feed --source claude
```

Each should produce a macOS notification through the DCS passthrough pipeline.

---

## Step 5: Test the full Claude Code → notification flow

Now run Claude Code inside tmux and trigger a real notification:

```bash
# Inside the tmux session in the tagged cmux:
claude
```

Then do something that triggers a notification. The easiest ways:

### Option A: Let Claude finish and stop
Send Claude a simple task like:
```
> say "hello" and stop
```
When Claude stops, the **Stop** hook fires `printf '\a'` (bell), and if Claude also sends a Notification event, the new hook fires too.

### Option B: Trigger a permission prompt
Send Claude something that requires a tool permission you haven't pre-approved:
```
> run: curl https://example.com
```
This should trigger a permission notification.

### Option C: Use the Notification hook explicitly
If Claude's agent SDK supports it, trigger a notification by having Claude call the notification API directly.

---

## Step 6: Verify the `cmux notify` tmux fallback

Test that `cmux notify` falls back to terminal escape when the socket is unavailable:

```bash
# With a fake dead socket, cmux notify should fall back to OSC 777
CMUX_SOCKET_PATH=/tmp/nonexistent-test.sock /tmp/cmux-cli notify --title "Fallback Test" --body "No socket needed"
```

This should produce a macOS notification even though the socket doesn't exist.

---

## Step 7: Verify deduplication

Rapid identical notifications should be deduplicated (1s cooldown):

```bash
# These should produce only ONE notification
printf '\033Ptmux;\033\033]777;notify;Dedup;Test\033\033\\\033\\'
printf '\033Ptmux;\033\033]777;notify;Dedup;Test\033\033\\\033\\'
printf '\033Ptmux;\033\033]777;notify;Dedup;Test\033\033\\\033\\'
```

Wait 1 second, then send again — should produce a second notification.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No notification from raw printf | Not in tagged cmux build, or GhosttyKit didn't rebuild |
| `cmux hooks feed` outputs `{}` | No socket + not inside tmux, or the JSON didn't match Notification event |
| `cmux notify` says "socket not found" | Expected inside tmux — should auto-fallback to OSC 777 |
| Claude notifications don't appear | Notification hook not configured in `~/.claude/settings.json` |
| Duplicate notifications | Dedup is keyed by tab+title — same title from different tabs won't dedup |

---

## Cleanup

Remove the test tmux session:
```bash
tmux kill-session -t notify-test
```

Remove the Notification hook from `~/.claude/settings.json` if you don't want it permanently.
