# Research: tmux Notification and Alert Mechanisms

## Summary

tmux has **no native control mode notification for bells, activity, or silence**. Alerts flow through two paths only: (1) status-line flag markers (`#` for activity, `!` for bell), and (2) user-set hooks via `alert-bell`, `alert-activity`, `alert-silence` — which fire as tmux commands only (no control mode message emitted). For external consumers like cmux, the viable notification path is: **set a hook** (`set-hook -g alert-bell 'run-shell "..."'`) that outputs to a known file path or FIFO, or **poll session flags** via `#{session_bell_flag}`, `#{window_bell_flag}`, etc. The `%message` control mode notification exists but is only emitted by the `display-message` command, not automatically on alert events. OSC sequences for desktop notifications (OSC 9 legacy, OSC 777) are **not parsed or forwarded** by tmux — they pass through to the terminal byte-for-byte unmodified.

---

## Findings

### 1. BEL Character (0x07) — The Bell Path

The BEL character (`\007`) from a pane's output is handled in `input.c`:

```c
case '\007':	/* BEL */
    if (wp != NULL)
        alerts_queue(wp->window, WINDOW_BELL);
    break;
```
*(tmux input.c, `input_c0_dispatch`, ~line 1428)*

This calls `alerts_queue()` which:
- Sets `w->flags |= WINDOW_BELL`
- Adds the window to the deferred alerts check list
- Fires the deferred `alerts_callback` via `event_once()`

`alerts_queue()` also resets the silence timer, so activity and bell are mutually exclusive in the silence sense.

**Critically, the BEL is NOT forwarded to any attached terminal — it is consumed entirely by tmux's internal processing.** The character never reaches the real TTY. This means an external consumer cannot observe raw BEL characters arriving at a terminal from within tmux.

### 2. alerts.c — The Three Alert Types and Their Actions

Source: `alerts.c` (tmux master, ~2025-02-10)

Three alert flags: `WINDOW_BELL`, `WINDOW_ACTIVITY`, `WINDOW_SILENCE`.

Each `alerts_check_*` function follows the same pattern:

```
alerts_check_bell(w):
    if ~w->flags & WINDOW_BELL → return 0
    if !monitor-bell → return 0
    for each winlink:
        if !(current window && attached):
            wl->flags |= WINLINK_BELL
            server_status_session(s)     ← triggers status line redraw
        if alerts_action_applies(wl, "bell-action"):
            notify_winlink("alert-bell", wl)  ← fires hooks only, NO control mode msg
        if !session_alerted:
            alerts_set_message(wl, "Bell", "visual-bell")
    return WINDOW_BELL
```
*(tmux alerts.c, `alerts_check_bell`, ~line 201-230)*

The `activity-action`, `bell-action`, `silence-action` options control which windows trigger the hook/message:
- `any` (default for bell) — activity in any window triggers alert
- `none` — disabled
- `current` — only activity in current window
- `other` — only activity in non-current windows

#### `alerts_set_message` — What Happens to the Terminal

```c
static void alerts_set_message(struct winlink *wl, const char *type, const char *option) {
    int visual = options_get_number(wl->session->options, option);
    TAILQ_FOREACH(c, &clients, entry) {
        if (c->session != wl->session || c->flags & CLIENT_CONTROL)
            continue;  // <-- CONTROL CLIENTS ARE SKIPPED
        
        if (visual == VISUAL_OFF || visual == VISUAL_BOTH)
            tty_putcode(&c->tty, TTYC_BEL);  // physical bell on attached terminal
        if (visual == VISUAL_OFF) continue;
        
        // Set status line message: "Bell in window" / "Activity in window" / "Silence in window"
        status_message_set(c, -1, 1, 0, 0, "%s in %s window", type, ...);
    }
}
```
*(tmux alerts.c, `alerts_set_message`, ~line 285-320)*

**Key finding**: Control mode clients (`CLIENT_CONTROL` flag) are explicitly excluded from alert messages. No `%message`, `%bell`, or any `%` notification is emitted for bell/activity/silence events.

### 3. tmux Hooks — The Only Pluggable Notification Path

From the man page HOOKS section and `notify.c`:

**Alert hooks** (fired by `notify_winlink()` from alerts.c):
- `alert-activity` — Run when a window has activity (requires `monitor-activity on`)
- `alert-bell` — Run when a window has received a bell (requires `monitor-bell on`)
- `alert-silence` — Run when a window has been silent (requires `monitor-silence <interval>`)

**Other relevant hooks:**
- `pane-died` — Run when program in pane exits but `remain-on-exit` is on
- `pane-exited` — Run when program in pane exits
- `pane-focus-in` / `pane-focus-out` — Run when focus enters/exits a pane (requires `focus-events on`)
- `window-layout-changed` — Run when a window layout changes
- `window-linked` / `window-unlinked` — Run when a window is linked/unlinked
- `window-renamed` — Run when a window is renamed
- `session-created` / `session-closed` / `session-renamed` — Session lifecycle

**How hooks work** (`notify.c`, `notify_callback` function):

The `notify_callback()` function is called for every notification. It maps specific names to `control_notify_*` functions for control mode output:

```c
if (strcmp(ne->name, "pane-mode-changed") == 0)
    control_notify_pane_mode_changed(ne->pane);
if (strcmp(ne->name, "window-layout-changed") == 0)
    control_notify_window_layout_changed(ne->window);
if (strcmp(ne->name, "window-pane-changed") == 0)
    control_notify_window_pane_changed(ne->window);
// ... and so on for all other control-mode-notified names
```
*(tmux notify.c, `notify_callback`, ~line 75-105)*

**Critical: `"alert-bell"`, `"alert-activity"`, `"alert-silence"` do NOT appear in this mapping.** They only execute user-defined hook commands — no `control_notify_*` function exists for them. There is no code path in tmux that emits a control mode `%` message for alerts.

After calling `control_notify_*` (or not, in the case of alerts), `notify_callback` calls `notify_insert_hook()` which executes any user-defined hook commands.

### 4. Control Mode Protocol — Complete Message Set

Source: tmux man page CONTROL MODE section, `control-notify.c`, `control.c`

All `%` message types defined in the control mode protocol:

| Message | Trigger | Source |
|---------|---------|--------|
| `%begin <time> <cmd> <flags>` | Start of command output block | `control.c:control_write_buffer` |
| `%end <time> <cmd> <flags>` | Successful command completion | `control.c` |
| `%error <time> <cmd> <flags>` | Failed command | `control.c` |
| `%exit [reason]` | Client exiting | `control.c` |
| `%output <pane-id> <value>` | Pane output | `control.c:control_write_pending` |
| `%extended-output <pane-id> <age> ... : <value>` | Pane output (pause-after) | `control.c` |
| `%layout-change <win-id> <layout> <vis-layout> <flags>` | Window layout changed | `control-notify.c` |
| `%window-pane-changed <win-id> <pane-id>` | Active pane in window changed | `control-notify.c` |
| `%window-close <win-id>` | Window closed (linked) | `control-notify.c` |
| `%unlinked-window-close <win-id>` | Window closed (unlinked) | `control-notify.c` |
| `%window-add <win-id>` | Window linked to current session | `control-notify.c` |
| `%unlinked-window-add <win-id>` | Window added but not linked | `control-notify.c` |
| `%window-renamed <win-id>` | Window renamed | `control-notify.c` |
| `%unlinked-window-renamed <win-id>` | Unlinked window renamed | `control-notify.c` |
| `%sessions-changed` | Session created/destroyed | `control-notify.c` |
| `%session-changed <session-id> <name>` | Client attached to different session | `control-notify.c` |
| `%session-renamed <name>` | Current session renamed | `control-notify.c` |
| `%session-window-changed <session-id> <win-id>` | Session active window changed | `control-notify.c` |
| `%client-session-changed <client> <session-id> <name>` | Client session changed | `control-notify.c` |
| `%client-detached <client>` | Client detached | `control-notify.c` |
| `%pane-mode-changed <pane-id>` | Pane mode changed | `control-notify.c` |
| `%pause <pane-id>` | Pane paused (pause-after) | `control.c` |
| `%continue <pane-id>` | Pane continued | `control.c` |
| `%message <text>` | User ran `display-message` | `cmd-display-message.c` |
| `%paste-buffer-changed <name>` | Paste buffer changed | `notify.c` |
| `%paste-buffer-deleted <name>` | Paste buffer deleted | `notify.c` |
| `%config-error <error>` | Configuration error | `control.c` |
| `%subscription-changed <name> <session-id> <win-id> <pane-id> ... : <value>` | Format subscription | `control.c` |

**There is NO `%bell`, `%activity`, or `%silence` message type.** These events are invisible to control mode clients.

### 5. `control_write` Mechanism

```c
static void printflike(2, 0) control_vwrite(struct client *c, const char *fmt, va_list ap) {
    struct control_state *cs = c->control_state;
    char *s;
    xvasprintf(&s, fmt, ap);
    bufferevent_write(cs->write_event, s, strlen(s));
    bufferevent_write(cs->write_event, "\n", 1);
    bufferevent_enable(cs->write_event, EV_WRITE);
    free(s);
}
```
*(tmux control.c, `control_vwrite`, ~line 395)*

Messages go to the client's `bufferevent` output buffer. They are delimited by newlines. The control mode client reads these from the tmux process's stdout.

Each `control_notify_*` function in `control-notify.c` calls `control_write(c, "%%<message>", ...)`. The `%%` becomes a literal `%` in the output (printf format convention).

### 6. `%message` and `display-message`

When `display-message` is run with `-c <control-client>`:

```c
if (tc != NULL && (tc->flags & CLIENT_CONTROL)) {
    evb = evbuffer_new();
    evbuffer_add_printf(evb, "%%message %s", msg);
    server_client_print(tc, 0, evb);
    evbuffer_free(evb);
}
```
*(tmux cmd-display-message.c, `cmd_display_message_exec`, ~line 120)*

The `%message` notification is only emitted when a **user or script explicitly runs `display-message` targeting a control mode client**. It is never emitted automatically for bell/activity/silence events.

### 7. `%begin`/`%end`/`%error` Output Blocks

Every command execution emits an output block:
```
%begin <epoch> <cmd-num> <flags>
... command output lines ...
%end <epoch> <cmd-num> <flags>
```
or on failure:
```
%error <epoch> <cmd-num> <flags>
... error text ...
```

Notifications (`%window-pane-changed`, etc.) **never appear inside an output block** — they are interleaved between blocks. This is guaranteed by the protocol: "A notification will never occur inside an output block."

### 8. OSC Sequences — What tmux Handles vs. Passes Through

Tmux parses OSC sequences from pane content via `input_exit_osc()` (input.c, ~line 2628). Supported OSC numbers:

| OSC | Handler | Action |
|-----|---------|--------|
| 0, 2 | Set window title | `screen_set_title()`, fires `notify_pane("pane-title-changed")` |
| 4 | Set colour palette | `input_osc_4()` |
| 7 | Set current path | `screen_set_path()`, triggers status redraw |
| 8 | Hyperlinks | `input_osc_8()` |
| 9 | Progress bar | `input_osc_9()` - **OSC 9;4;... for progress bars only** |
| 10 | Foreground colour | `input_osc_10()` |
| 11 | Background colour | `input_osc_11()` |
| 12 | Cursor colour | `input_osc_12()` |
| 52 | Clipboard | `input_osc_52()` |
| 104 | Reset palette | `input_osc_104()` |
| 110-112 | Reset fg/bg/cursor | Respective handlers |
| 133 | Prompt markers | `input_osc_133()` |

**Sequences NOT handled by tmux** (pass through to terminal unmodified):
- **OSC 9 legacy (desktop notification)** — `\033]9;text\007` or `\033]9;text\033\\` — **NOT parsed**. The `input_osc_9` function only handles `OSC 9;4;...` (progress bar). Any other OSC 9 payload is logged as "bad OSC 9;4" and discarded.
- **OSC 777 (terminal-notifier)** — `\033]777;notify;title;body\007` — **NOT parsed**. Falls through to the `default:` case in `input_exit_osc`: `log_debug("%s:unknown '%u'", __func__, option)`.
- **OSC 99 (user-notification)** — NOT parsed.
- **OSC 1 (icon title)** — NOT parsed.

**All unhandled OSC sequences are discarded by tmux, not forwarded.** The BEL characters that terminate OSC sequences are consumed by the OSC parser state machine and never reach the terminal output.

### 9. Status-Line Alert Flags

tmux communicates alerts through the status line using format flags:

| Flag | Format Variable | Status Bar Symbol |
|------|-----------------|--------------------|
| Activity monitored + triggered | `#{window_activity_flag}` | `#` |
| Bell monitored + triggered | `#{window_bell_flag}` | `!` |
| Silence monitored + triggered | `#{window_silence_flag}` | `~` |
| Session has any alert | `#{session_alerts}` | List of window indexes |
| Session has activity | `#{session_activity_flag}` | 1 or 0 |
| Session has bell | `#{session_bell_flag}` | 1 or 0 |
| Session has silence | `#{session_silence_flag}` | 1 or 0 |

*(tmux man page, FORMATS section)*

These can be read via `tmux display-message -p -F '#{...}'` or through format subscriptions in control mode.

### 10. Control Mode Format Subscriptions

`refresh-client -B <name> <format>` creates a subscription. When the format value changes, control mode clients receive:

```
%subscription-changed <name> <session-id> <window-id> <window-index> <pane-id> ... : <value>
```
*(tmux man page CONTROL MODE section)*

This can be used to monitor `#{window_bell_flag}`, `#{window_activity_flag}`, etc. without polling. Example:
```
refresh-client -B bellwatch '#{window_bell_flag}'
```

This is the closest tmux provides to a push-based alert notification for control mode clients.

---

## Sources

### Kept
- **tmux source: `alerts.c`** — Core alert firing logic: `alerts_queue`, `alerts_check_bell`, `alerts_check_activity`, `alerts_check_silence`, `alerts_set_message`. Shows control mode clients are explicitly excluded.
- **tmux source: `input.c`** — BEL handling at ~line 1428, OSC dispatch at `input_exit_osc` (~line 2628), full handler implementations for OSC 4-133.
- **tmux source: `control-notify.c`** — All `control_notify_*` functions. Documents every control mode notification type except `%message`. Confirms no bell/activity/silence notification.
- **tmux source: `notify.c`** — The `notify_callback` function mapping between notification names and `control_notify_*` calls. Shows alert-* names are NOT mapped.
- **tmux source: `control.c`** — `control_write`/`control_vwrite` implementation, output queuing architecture, `%pause`/`%continue`/`%subscription-changed`.
- **tmux source: `cmd-display-message.c`** — Shows `%message` is only emitted by explicit `display-message` command.
- **tmux man page** — CONTROL MODE section (all 25+ notification types), HOOKS section (alert-activity, alert-bell, alert-silence, pane-died, etc.), FORMATS section (alert flag variables).
- **tmux source: `status.c`** — Line 246/259 confirms `CLIENT_CONTROL` clients are skipped in `status_message_set`.

### Dropped
- **tmux source: `tmux.c` / `window.c` / `tty.c` / `server-fn.c`** — Scanned but not directly relevant to notifications. `server-fn.c` contains `server_lock_*` and `server_redraw_*` functions but no control-notify involvement for alerts.

---

## Gaps

1. **No direct push notification bridge from tmux to cmux for alerts.** tmux explicitly excludes control mode clients from alert messages. The only reliable path for cmux to know about bell/activity/silence is:
   - **Option A**: Set a hook (`set-hook -g alert-bell 'run-shell "..."'`) that writes a marker to a FIFO or file that cmux monitors. Hook commands have access to format variables like `#{session_name}`, `#{window_index}`.
   - **Option B**: Use format subscriptions (`refresh-client -B bellflag '#{window_bell_flag}'`) to receive `%subscription-changed` messages when the bell flag changes. This requires the subscription to be set up on each target session/window.
   - **Option C**: Poll via `tmux display-message -p -F '#{window_bell_flag}'` — but this is polling, not push.

2. **OSC sequences for desktop notifications are not intercepted by tmux.** Applications running inside panes that emit OSC 9 (legacy) or OSC 777 (terminal-notifier) will have those sequences **silently discarded** by tmux's OSC parser. They do not reach the host terminal and do not trigger any action within tmux.

3. **There is no custom message pipe or out-of-band channel** in tmux for communicating arbitrary notifications from a pane to an external consumer. The `run-shell` hook mechanism is the closest, running shell commands synchronously within the tmux server process.

4. **`%message` is not a general notification mechanism** — it requires an explicit `display-message` command invocation and carries only the string from that command. It is not automatically emitted on any event.

### Suggested Next Steps for cmux

1. **Write a lightweight shell script** that a tmux hook can call, which writes to a FIFO or a file that cmux monitors:
   ```sh
   # .tmux.conf
   set-hook -g alert-bell 'run-shell "echo bell-%s-%w > /tmp/cmux-tmux-alerts"'
   ```
   
2. **Use format subscriptions** via `refresh-client -B` from the cmux control mode client to subscribe to `#{window_bell_flag}`, `#{window_activity_flag}`, `#{window_silence_flag}`.

3. **Parse `run-shell` output** in control mode — if cmux sends a `run-shell` command through control mode, the output comes back as a `%` block. Hooks running `run-shell` from within tmux's alert processing would send output through the status line, not through control mode.

4. **For pane-to-external-consumer messaging**, consider using tmux's `send-keys` to type into a pane (no help) or writing to a file the external consumer polls/watchs. There is no escape-sequence-based IPC channel through tmux.
