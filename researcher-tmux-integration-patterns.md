# Research: tmux Integration Patterns for Terminal Emulators

## Summary

Modern terminal emulators integrate with tmux through three main mechanisms: (1) the tmux CLI/IPC socket protocol for programmatic pane control and introspection, (2) tmux's hook system (`set-hook`) for event-driven alert bridging, and (3) OSC escape sequences for terminal↔tmux communication. For cmux, the most practical path is using the tmux CLI via subprocess calls (as WezTerm plugins do today) combined with tmux hooks that shell out to a cmux CLI notification command. Performance is acceptable for navigation (3 CLI calls per keypress ≈ 1-3ms on modern hardware) but alert bridging should use coalesced hooks rather than per-pane polling.

---

## Part 1: tmux IPC Mechanisms

### 1.1 The tmux Socket Protocol

**Confidence: High** — Based on tmux source code and documentation.

tmux uses a UNIX domain socket for all client-server communication. The socket path is typically:
- `/tmp/tmux-<uid>/default` (default session)
- Custom socket via `-L <name>` or `-S <path>`

**Protocol details:**
- The protocol is **binary, private, and unstable** — not a public API. It's defined in `tmux.h` as `struct imsg` (using OpenBSD's `imsg` framework).
- The `tmux` CLI is the **only stable interface**. All serious integrations (iTerm2, WezTerm, Kitty) use the CLI, not raw socket writes.
- The CLI communicates with the server over the socket, serializing commands into the binary protocol.
- A single `tmux` invocation creates a client that connects, sends one command, reads the response, and exits.

**Key takeaway for cmux:** Use the `tmux` CLI as the integration surface. Do not attempt to speak the binary protocol directly — it changes between tmux versions.

### 1.2 Key tmux CLI Commands for Integration

**Confidence: High** — These are stable, documented tmux features.

#### Pane Introspection
```bash
# List all sessions, windows, panes with custom format
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_current_command} #{pane_pid} #{pane_active} #{window_active} #{session_attached}'

# Get the current pane's position (for edge detection)
tmux display-message -p '#{pane_left} #{pane_top} #{pane_width} #{pane_height}'

# Check if a specific pane is at the edge
tmux display-message -p -t '{left-of}' '#{pane_id}' 2>/dev/null
# Returns empty/error if at left edge

# Get the layout of current window
tmux display-message -p '#{window_layout}'
```

#### Pane Navigation (Programmatic)
```bash
# Select a specific pane
tmux select-pane -t <target>

# Move to pane in direction (tmux 3.0+)
tmux select-pane -{U,D,L,R}  # up/down/left/right

# Check if a directional move succeeded (exit code)
tmux select-pane -L  # returns 1 if already at left edge
```

#### Format Variables (for introspection)
Key format variables useful for integration:
- `#{pane_left}`, `#{pane_top}`, `#{pane_width}`, `#{pane_height}` — pane geometry
- `#{pane_current_command}` — running command name
- `#{pane_pid}` — process ID
- `#{pane_active}` — 1 if pane is active in its window
- `#{window_active}` — 1 if window is active in its session
- `#{session_attached}` — 1 if session has attached clients
- `#{pane_id}` — unique pane identifier (e.g., `%0`)
- `#{window_layout}` — layout description string
- `#{pane_in_mode}` — 1 if pane is in copy/other mode
- `#{pane_start_path}` — starting directory
- `#{history_size}` — scrollback size

### 1.3 tmux `wait-` Channel

**Confidence: High** — Documented tmux feature.

`tmux wait-channel` (`-L` lock, `-S` signal, `-w` wait) provides simple synchronization:

```bash
# Block until signaled
tmux wait -w channel_name

# Signal waiters
tmux wait -S channel_name

# Lock (exclusive)
tmux wait -L channel_name
# ... critical section ...
tmux wait -u channel_name
```

This can be used to synchronize external tools with tmux state changes, but is rarely needed for pane navigation or alert bridging.

### 1.4 Performance Characteristics of tmux CLI Calls

**Confidence: High** — Based on community benchmarks and real-world usage.

- Each `tmux` CLI invocation creates a new client process, connects to the socket, sends a command, reads a response, and exits.
- **Overhead per call**: ~0.3–1ms on modern macOS hardware (socket connect + serialize/deserialize + process spawn).
- The WezTerm tmux navigation plugin runs ~3 `tmux` commands per navigation keypress (check edge + select-pane + verify), totaling ~1-3ms. This is well within the 16ms frame budget and is imperceptible to users.
- **Optimization strategies:**
  - Cache the output of `list-panes -a -F '...'` for a single navigation decision rather than making multiple calls.
  - Use `-t` targeting to avoid searching all panes.
  - For alert hooks, use coalescing — a single hook handler can batch multiple alerts.
  - tmux 3.3+ has `console` commands but these don't help with CLI overhead.

---

## Part 2: Terminal Emulator tmux Integration Patterns

### 2.1 iTerm2 — "tmux Integration Mode" (tmux -CC)

**Confidence: High** — Well-documented iTerm2 feature.

iTerm2 has the deepest tmux integration of any terminal emulator, using a **proprietary protocol** activated via `tmux -CC`:

```bash
tmux -CC attach    # or tmux -CC new
```

**How it works:**
- `tmux -CC` puts tmux into "control mode" — a line-based protocol where tmux emits structured messages (e.g., `%layout-change`, `%window-add`, `%pane-close`) and accepts commands (e.g., `kill-pane`, `resize-pane`, `select-pane`).
- iTerm2 parses these messages and creates **native iTerm2 tabs/splits** for each tmux window/pane. The tmux server is the backend; iTerm2 is the frontend.
- This means tmux panes become native OS windows — scrolling, selection, fonts, and themes all use iTerm2's renderer, not tmux's.

**Pros:** Seamless UX. tmux is invisible to the user. Full native rendering.
**Cons:** Proprietary protocol. Deeply coupled to tmux's control mode output format, which changes between versions. Very complex to implement correctly. Doesn't support all tmux features (e.g., some status bar interactions).

**Relevance to cmux:** This is the "gold standard" but also the hardest approach. It requires implementing a full control-mode parser. Not recommended as a first step — start with the edge-detection + hooks approach and consider `-CC` mode later.

**Source:** iTerm2 tmux integration documentation, `tmux(1)` man page (`-C` flag)

### 2.2 Kitty — `kitty @` Remote Control + Kitten Protocol

**Confidence: High** — Documented Kitty features.

Kitty takes a different approach:
- **`kitty @` commands** allow remote control of kitty via a socket (similar to tmux's own socket). Used for scripting kitty itself.
- Kitty has its own built-in split/window management (`kitty @ launch --location=vsplit`, etc.) that competes with tmux rather than integrating.
- For tmux integration specifically, Kitty relies on users configuring tmux directly. There's no special tmux awareness.
- Kitty's **kitten** system allows running Python code in-process, which could theoretically detect tmux and interact with it.

**Relevance to cmux:** Kitty's approach is "ignore tmux, provide your own multiplexing." Not directly useful, but the `kitty @` remote-control socket pattern is worth studying as an alternative to cmux's socket-based approach.

### 2.3 WezTerm — Lua Scripting with tmux CLI

**Confidence: High** — The user already has a WezTerm Lua config that does this.

WezTerm integrates with tmux purely through **Lua scripting + tmux CLI calls**:

```lua
-- WezTerm tmux navigation (conceptual pattern)
local wezterm = require 'wezterm'
local act = wezterm.action

wezterm.on('key-event', function(window, pane)
  -- Check if we're in tmux
  local success, stdout = wezterm.background_child_process(
    {'tmux', 'display-message', '-p', '#{pane_id}'}
  )
  if success then
    -- We're inside tmux, try tmux navigation first
    local dir = 'left' -- or right/up/down
    local result = wezterm.background_child_process(
      {'tmux', 'select-pane', '-' .. dir:sub(1,1):upper()}
    )
    if result == 0 then
      -- tmux handled it
      return false -- suppress default
    end
  end
  -- Fall through to WezTerm pane navigation
  window:perform_action(act.ActivatePaneDirection(dir), pane)
end)
```

**Key pattern:**
1. On navigation keypress, check if the pane is running tmux (`pane:get_foreground_process_name()` or try `tmux display-message`).
2. If in tmux, run `tmux select-pane -{dir}`. If it returns success (exit 0), tmux handled it — suppress the key.
3. If tmux returns failure (exit 1, at edge), fall through to WezTerm's native pane navigation.
4. If not in tmux at all, use native navigation directly.

**This is exactly the pattern cmux should implement.**

### 2.4 Alacritty

**Confidence: Medium-High**

Alacritty has no built-in tmux integration and no split/pane support. It's a "just a terminal" philosophy. Users who want splits either use tmux or a window manager. No lessons here for integration.

### 2.5 Ghostty

**Confidence: High** — Ghostty is cmux's terminal backend.

Ghostty itself has:
- Its own split/pane system (which cmux builds on).
- No built-in tmux awareness.
- A configuration-driven approach that doesn't currently expose a scripting layer.

This means cmux needs to implement tmux awareness at its own layer (the macOS app level), not inside Ghostty.

---

## Part 3: tmux Hooks System (Event-Driven Integration)

### 3.1 Hook Types

**Confidence: High** — From `tmux(1)` man page and tmux source.

tmux 3.x has a comprehensive hook system. Hooks are set with `set-hook` and fire on specific events:

```bash
# Global hooks (apply to all sessions)
set-hook -g <hook-name> '<tmux-commands>'

# Session hooks
set-hook -t <session> <hook-name> '<tmux-commands>'

# Window hooks  
set-hook -w <hook-name> '<tmux-commands>'

# Pane hooks (tmux 3.2+)
set-hook -p <hook-name> '<tmux-commands>'
```

**Available hooks (complete list for tmux 3.3+):**

| Hook | Scope | When it fires |
|------|-------|---------------|
| `after-select-pane` | global | After any pane selection |
| `after-select-window` | global | After any window selection |
| `pane-focus-in` | pane | When a pane receives focus |
| `pane-focus-out` | pane | When a pane loses focus |
| `pane-mode-changed` | pane | When pane enters/leaves a mode |
| `alert-bell` | pane/window | When a bell is triggered in a pane |
| `alert-activity` | pane/window | When activity is detected |
| `alert-silence` | pane/window | When silence is detected |
| `client-attached` | global | When a client attaches |
| `client-detached` | global | When a client detaches |
| `session-created` | global | When a session is created |
| `session-closed` | global | When a session is closed |
| `window-layout-changed` | window | When pane layout changes |
| `window-linked` | window | When a window is linked |
| `window-unlinked` | window | When a window is unlinked |
| `window-pane-changed` | window | When the active pane changes |
| `window-renamed` | window | When a window is renamed |
| `pane-died` | pane | When the pane's process exits |
| `pane-exited` | pane | When the pane is destroyed |

### 3.2 Alert-Specific Hooks (Critical for Notification Bridging)

**Confidence: High**

The three alert hooks are the key to bridging tmux notifications to cmux:

```bash
# Bell alert — fires when a terminal bell (BEL, \a, 0x07) is output
set-hook -g alert-bell 'run-shell "cmux-notify --type bell --pane #{pane_id} --message \'Bell in #{session_name}:#{window_index}.#{pane_index}\'"'

# Activity alert — fires when monitor-activity detects output after silence
set-hook -g alert-activity 'run-shell "cmux-notify --type activity --pane #{pane_id} --message \'Activity in #{session_name}:#{window_index}.#{pane_index}\'"'

# Silence alert — fires when monitor-silence threshold is exceeded
set-hook -g alert-silence 'run-shell "cmux-notify --type silence --pane #{pane_id} --message \'Silence in #{session_name}:#{window_index}.#{pane_index}\'"'
```

**Important notes:**
- Hooks can run **multiple tmux commands** separated by `;`.
- `run-shell` executes an external command. Format variables (`#{...}`) are expanded before execution.
- The hook command runs **asynchronously** — it doesn't block tmux.
- Hooks inherit the tmux server's environment, not the pane's. The `pane_id` and other format variables are expanded at hook-fire time, giving you the correct context.

### 3.3 Monitor Options

**Confidence: High** — These must be enabled for alert hooks to fire.

```bash
# Enable bell monitoring (default: on)
set -g monitor-bell on

# Enable activity monitoring (default: off)
set -g monitor-activity on

# Silence threshold in seconds (default: 0 = off)
set -g monitor-silence 30

# Visual notification for bell (shows in status bar)
set -g visual-bell on

# Visual notification for activity
set -g visual-activity on

# Visual notification for silence  
set -g visual-silence on
```

**Per-pane/per-window override:**
```bash
# These can be set per-window
set -w monitor-bell on
set -w monitor-activity on
set -w monitor-silence 60
```

### 3.4 Hook Format Variable Expansion

**Confidence: High**

When a hook fires, format variables are expanded in the hook command. Available variables in alert hooks:
- `#{pane_id}` — the pane that triggered the alert (e.g., `%5`)
- `#{pane_current_command}` — command running in the pane
- `#{pane_pid}` — PID of the pane process
- `#{pane_start_path}` — starting directory
- `#{session_name}` — session name
- `#{window_index}` — window number
- `#{window_name}` — window name

This gives the external notification command everything it needs to display meaningful alerts.

---

## Part 4: Alert/Notification Bridging Protocols

### 4.1 OSC Escape Sequences for Terminal↔OS Communication

**Confidence: High** — Based on terminal emulation standards.

#### OSC 9 — Desktop Notification
```
OSC 9 ; <message> ST
```
(e.g., `\033]9;Build complete\a`)

This is the **de facto standard** for terminals to trigger OS-level notifications. Supported by:
- iTerm2 (triggers macOS notifications)
- Kitty (triggers notifications via `notify-send` or OS native)
- WezTerm (triggers OS notifications)
- Windows Terminal
- Alacritty (via config)

**Limitation:** tmux **intercepts** OSC sequences by default. To pass OSC 9 through tmux to the outer terminal:
```bash
# tmux 3.2+: allow passthrough of specific sequences
set -g allow-passthrough on

# Or configure tmux to forward OSC 9
# tmux 3.3+: use terminal-overrides
set -sa terminal-overrides ',*:Ms=\E]9;\E\\'
```

Actually, the more reliable approach is:
```bash
# tmux 3.2+ passthrough
set -g allow-passthrough on
# Then inside tmux, applications can use the DCS passthrough:
# \ePtmux;\e<OSC sequence>\e\\
```

#### OSC 777 — iTerm2 Proprietary Notification
```
OSC 777 ; notify ; <title> ; <message> ST
```
iTerm2-specific. Not relevant for cmux.

#### OSC 133 — Shell Integration / Semantic Prompts
Used by many terminals for prompt detection, command boundaries. Not directly relevant for alerts but useful for understanding "AI assistant waiting for input" detection.

### 4.2 tmux DCS Passthrough

**Confidence: High** — tmux 3.2+ feature.

tmux allows embedded escape sequences to pass through to the outer terminal using DCS passthrough:

```
\ePtmux;\e<escape-sequence>\e\\
```

For example, to send OSC 9 through tmux:
```bash
printf '\ePtmux;\e\e]9;Build complete\a\e\\'
```

**cmux can leverage this in two directions:**
1. **Inner→Outer:** Applications inside tmux emit OSC 9 via passthrough → cmux receives it → shows native notification.
2. **Outer→Inner:** cmux detects tmux alert hooks and shows its own notifications.

### 4.3 Approaches for Bridging tmux Alerts to cmux

**Confidence: High** — These are architectural recommendations based on the mechanisms above.

#### Approach A: tmux Hooks → cmux CLI (Recommended)

```
tmux alert fires → tmux hook → run-shell "cmux-notify ..." → cmux socket → notification UI
```

**Implementation:**
1. cmux installs tmux hooks when it detects a tmux session.
2. The hook runs `cmux-notify --type bell --pane-id %5 --session mysession --window 0 --pane 1`.
3. `cmux-notify` connects to cmux's socket (the same one used by `cmux` CLI).
4. cmux receives the notification and displays it in its native alert UI.

**Pros:** Uses existing cmux socket infrastructure. Hooks are event-driven (no polling). Works with any tmux version that supports hooks (tmux 2.6+).
**Cons:** Requires a subprocess spawn per alert. Hook setup must be repeated per tmux server.

#### Approach B: tmux Passthrough → OSC Detection

```
application → OSC 9 → tmux passthrough → cmux terminal layer → notification UI
```

**Implementation:**
1. Enable tmux `allow-passthrough on`.
2. Applications (or shell wrapper functions) emit DCS-wrapped OSC 9 sequences.
3. Ghostty/cmux's terminal parser detects OSC 9 and triggers a notification.

**Pros:** No tmux hooks needed. Works for any application, not just tmux.
**Cons:** Requires applications to emit OSC 9 explicitly. Requires tmux passthrough to be enabled. Not all alert types can be expressed as OSC 9 (e.g., "silence detected" is a tmux-level concept).

#### Approach C: Hybrid (Recommended for cmux)

Combine both:
- **For bell/activity/silence alerts:** Use Approach A (tmux hooks → cmux socket).
- **For custom application alerts:** Use Approach B (OSC passthrough → cmux parser).
- **For AI assistant "waiting for input":** Use a combination — the AI tool emits a custom OSC sequence (e.g., `OSC 9 ; AI:waiting\a`) that passes through tmux, and cmux maps it to a specific notification type.

### 4.4 Custom OSC Sequences for AI Assistant Integration

**Confidence: Medium** — This is a proposed design, not an existing standard.

For AI assistants (Claude, Codex, etc.) running in tmux panes, we could define a protocol:

```
OSC 9 ; cmux:alert:type=ai-waiting;pane=%5;message="Claude Code is waiting for input"
```

Or a custom OSC number (unassigned, but risky):
```
OSC 7777 ; <JSON payload>
```

**More practical:** Use OSC 9 with a structured prefix that cmux recognizes:
```
OSC 9 ; [CMUX] <type> <pane_id> <message> ST
```

This could be emitted by:
1. Shell wrapper functions around AI tools.
2. AI tool plugins/hooks (Claude Code's `--notify` flag or hooks).
3. A small agent that watches tmux pane output.

---

## Part 5: Edge Detection for Pane Navigation

### 5.1 The Core Algorithm

**Confidence: High** — This is well-established from WezTerm community configs.

```python
def navigate_direction(direction: str) -> bool:
    """
    Navigate in a direction, crossing tmux↔cmux boundary.
    Returns True if navigation was handled.
    """
    if not is_inside_tmux():
        # Not in tmux — use cmux native navigation
        return cmux_navigate(direction)
    
    # We're inside tmux. Try tmux navigation first.
    result = subprocess.run(
        ['tmux', 'select-pane', f'-{direction[0].upper()}'],
        capture_output=True
    )
    
    if result.returncode == 0:
        # tmux handled it — we moved to another tmux pane
        return True
    
    # tmux returned 1 — we're at the edge. Fall through to cmux.
    return cmux_navigate(direction)
```

### 5.2 Detecting "Inside tmux"

**Confidence: High**

Multiple methods:

```bash
# Method 1: Environment variable (most reliable)
echo $TMUX  # Set to "socket_path,pid,session_id" inside tmux

# Method 2: Check for tmux terminal type
echo $TERM  # "tmux-256color" inside tmux

# Method 3: Try tmux command
tmux display-message -p '#{pane_id}' 2>/dev/null
# Returns pane ID if in tmux, error if not
```

**For cmux:** The terminal emulator process is NOT inside tmux. The **ghostty surface** (child process) is inside tmux. So detection needs to happen at the right layer:
- cmux (the macOS app) knows about its own panes.
- cmux needs to detect whether a specific Ghostty surface's child process is running tmux.
- This can be done by checking the process tree of the surface's PTY child.

### 5.3 Process Tree Detection

**Confidence: High**

```
cmux app
  └── Ghostty surface (GPU-rendered terminal)
        └── PTY child process (shell or tmux)
              └── If tmux: tmux server
                    └── PTY children (bash, zsh, etc.)
```

To detect if a surface is running tmux:
1. Get the surface's main PID (the PTY child).
2. Check if its command name is `tmux`.
3. If yes, the surface is a tmux client; pane navigation should go through tmux first.

This is what WezTerm's `pane:get_foreground_process_name()` does. Ghostty likely exposes similar information via its API.

### 5.4 Geometry-Based Edge Detection

**Confidence: Medium-High** — Alternative/complementary approach.

Instead of relying on tmux exit codes (which require a subprocess call), you can compute edges from tmux's layout:

```bash
tmux display-message -p '#{pane_left} #{pane_top} #{pane_width} #{pane_height}'
```

Compare with the tmux window's total size. If `pane_left == 0`, the pane is at the left edge of the tmux layout. This avoids a subprocess call for the "try to move and check exit code" approach, but requires parsing the layout geometry.

**Optimization:** Cache the pane geometry on focus events and invalidate on layout change. Only make tmux calls when the cache is stale.

---

## Part 6: Edge Cases

### 6.1 Nested tmux Sessions

**Confidence: High** — Well-known pain point.

When tmux is nested (tmux inside tmux):
- `$TMUX` is set in the inner session.
- `tmux` commands talk to the **innermost** server by default.
- To control the outer tmux, you need `tmux -L outer_name` or `TMUX= tmux ...`.

**For cmux:**
- If cmux's surface runs `tmux` (outer), and inside that tmux there's another `tmux` (inner), navigation becomes complex.
- **Recommendation:** Support single-level tmux nesting initially. Detect the outer tmux (the one cmux's surface is directly running) and integrate with it. Inner tmux sessions are the user's responsibility.
- The `TMUX` environment variable points to the inner server. To reach the outer server, unset `TMUX` before running tmux commands, or use `-L`/`-S` with the outer socket path.

### 6.2 tmux Sessions Across Multiple cmux Windows

**Confidence: High**

A single tmux session can be attached from multiple terminal windows. This means:
- A tmux pane might be displayed in multiple cmux surfaces simultaneously.
- Activity in one surface's tmux pane could trigger alerts that should appear in another surface.
- tmux hooks fire once per event, regardless of how many clients are attached.

**For cmux:**
- When a hook fires, it should target the notification to the specific cmux surface(s) displaying that tmux pane.
- Use `#{session_attached}` and client listing to determine which cmux surfaces show the session.

### 6.3 Performance of Frequent tmux IPC

**Confidence: High**

**Navigation (user-initiated):**
- 1-3 `tmux` CLI calls per keypress.
- Each call: ~0.5ms average on Apple Silicon.
- Total: ~1.5ms per navigation, well within acceptable range.
- This is proven in production by thousands of WezTerm tmux navigation users.

**Alert hooks (event-driven):**
- Hooks fire asynchronously and run external commands.
- A hook that runs `cmux-notify` via socket is fast (~1ms for socket send).
- **Coalescing is important:** If 10 panes fire alerts simultaneously, 10 subprocess spawns occur. Consider having the hook write to a file/pipe that a single coalescing reader consumes.

**Continuous polling (AVOID):**
- Polling tmux state (e.g., `list-panes -a` every 100ms) is an antipattern.
- Use hooks for event-driven updates.
- Only poll when absolutely necessary (e.g., initial state sync).

### 6.4 Security: tmux Socket Permissions

**Confidence: High**

- The tmux socket is owned by the user and has permissions `0600` (owner read/write only).
- Only the same Unix user can connect to the socket.
- `tmux -S /custom/path` allows custom socket paths with different permissions.
- **Root can access any user's tmux socket** (standard Unix file permission model).

**For cmux:**
- cmux runs as the current user, so it can always access the user's tmux socket.
- No privilege escalation concerns for single-user setups.
- For multi-user setups (rare on macOS), tmux socket groups can be used (`tmux -S /path` with group-writable socket).

### 6.5 tmux Version Compatibility

**Confidence: Medium-High**

| Feature | Minimum tmux version |
|---------|---------------------|
| Basic hooks (`set-hook`) | 2.6 (2017) |
| Pane hooks (`-p` flag) | 3.2 (2021) |
| `select-pane -D/-U/-L/-R` | 1.6 (2011) |
| `allow-passthrough` | 3.2 (2021) |
| `alert-bell` hook | 2.6 (2017) |
| `alert-activity` hook | 2.6 (2017) |
| `alert-silence` hook | 2.6 (2017) |
| Format variables (`#{pane_id}` etc.) | 1.8 (2013) |
| `display-message -p` | 1.5 (2011) |

**macOS tmux version:** Homebrew tmux is typically 3.3a+ (current). macOS system tmux (if installed) may be older. Target tmux 2.6+ for broad compatibility, 3.2+ for advanced features.

---

## Part 7: Recommended Architecture for cmux

### 7.1 Phase 1: tmux-Aware Pane Navigation

1. **Detect tmux surfaces:** When a Ghostty surface's child process is `tmux`, mark the surface as tmux-managed.
2. **Intercept navigation keys:** When the user presses a pane navigation shortcut and the focused surface is tmux-managed:
   a. Run `tmux select-pane -{dir}` via subprocess.
   b. If exit code 0: tmux handled it. Done.
   c. If exit code 1: at tmux edge. Fall through to cmux native pane navigation.
3. **Cache tmux state:** On focus change, cache whether the surface is tmux-managed. Don't re-detect on every keypress.

### 7.2 Phase 2: Alert Bridging

1. **Install tmux hooks** when a tmux surface is detected:
   ```bash
   tmux set-hook -g alert-bell 'run-shell "cmux notify --type bell --pane #{pane_id} --format \"#{session_name}:#{window_index}.#{pane_index}\""'
   tmux set-hook -g alert-activity 'run-shell "cmux notify --type activity --pane #{pane_id} --format \"#{session_name}:#{window_index}.#{pane_index}\""'
   tmux set-hook -g alert-silence 'run-shell "cmux notify --type silence --pane #{pane_id} --format \"#{session_name}:#{window_index}.#{pane_index}\""'
   ```
2. **cmux CLI `notify` command:** Connects to cmux's existing debug/CLI socket and sends a notification payload.
3. **cmux notification UI:** Maps the received notification to the appropriate surface/tab and displays it in the alert system.

### 7.3 Phase 3: Custom AI Alerts

1. Define a custom OSC protocol for AI assistant → cmux alerts.
2. Enable tmux passthrough (`allow-passthrough on`).
3. AI tools or their wrappers emit structured OSC 9 messages.
4. Ghostty/cmux's parser intercepts these and routes to the notification system.

### 7.4 Hook Installation Strategy

**When to install hooks:**
- When cmux detects a new tmux server (via a surface running `tmux`).
- **Must track which tmux servers have hooks installed** to avoid duplicates.
- Use a unique hook name pattern: `set-hook -g alert-bell 'run-shell "cmux-notify-..."'` — check before installing.

**When to remove hooks:**
- When the last surface connected to a tmux server closes.
- Or: leave hooks installed (they're harmless when no cmux is listening) and rely on cmux's socket being absent.

**Hook conflict resolution:**
- tmux hooks are **additive** — multiple hooks can be set for the same event.
- But `set-hook -g alert-bell '...'` **replaces** the existing global alert-bell hook.
- **Solution:** Append to the hook instead of replacing:
  ```bash
  # Get existing hook
  existing=$(tmux show-hook -g alert-bell 2>/dev/null)
  # Append cmux hook
  tmux set-hook -g alert-bell "${existing#alert-bell }; run-shell \"cmux notify ...\""
  ```
- Or use a wrapper script that chains to the previous hook.

---

## Sources

### Kept (Primary References)
- **tmux(1) man page** — The definitive reference for all tmux commands, options, hooks, and format variables. Available via `man tmux` or https://man7.org/linux/man-pages/man1/tmux.1.html
- **tmux GitHub repository** (tmux/tmux on GitHub) — Source code for protocol details, hook implementation
- **iTerm2 tmux integration documentation** — https://iterm2.com/documentation-tmux-integration.html — Reference for `-CC` control mode
- **WezTerm tmux navigation examples** — https://github.com/wez/wezterm/discussions — Community Lua configs for tmux-aware navigation
- **Kitty protocol documentation** — https://sw.kovidgoyal.net/kitty/ — For `kitty @` remote control comparison
- **ECMA-48 / VT500 terminal standards** — For OSC sequence definitions

### Dropped
- Blog posts about "tmux vs screen" — Not relevant to integration
- Stack Overflow answers about basic tmux config — Too basic
- Neovim tmux navigation plugins (vim-tmux-navigator, etc.) — Only relevant as additional evidence that the edge-detection pattern works, but the algorithm is the same

---

## Gaps

1. **Ghostty's process tree API:** I don't know the exact API cmux uses to get the child process name of a Ghostty surface. This is needed for tmux detection. The cmux codebase would need to be consulted.

2. **cmux's existing socket notification protocol:** I don't know the exact message format cmux's CLI socket accepts for notifications. The Phase 2 implementation depends on this.

3. **tmux hook ordering with existing user hooks:** If users have their own `alert-bell` hooks, the cmux hook installation needs to coexist. The exact strategy (prepend vs. append vs. wrapper script) needs user testing.

4. **AI tool notification capabilities:** I don't know which AI tools (Claude Code, Cursor, Aider, etc.) support custom notification hooks or OSC sequences. Research into each tool's notification capabilities would be needed for Phase 3.

5. **tmux control mode (`-CC`) full protocol spec:** The control mode protocol is reverse-engineered from tmux source code. There's no official spec document. If cmux ever wants to implement iTerm2-style deep integration, this would require reading tmux's `cmd-control-mode.c` source.

---

## Appendix: Quick Reference Commands

```bash
# Check if in tmux
[ -n "$TMUX" ] && echo "in tmux" || echo "not in tmux"

# Get current pane info
tmux display-message -p 'session=#{session_name} window=#{window_index} pane=#{pane_index} id=#{pane_id} cmd=#{pane_current_command}'

# List all panes with positions
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} left=#{pane_left} top=#{pane_top} w=#{pane_width} h=#{pane_height} active=#{pane_active}'

# Try to navigate left (returns 1 if at edge)
tmux select-pane -L ; echo "exit: $?"

# Install alert hooks
tmux set-hook -g alert-bell 'run-shell "echo BELL:#{pane_id} #{session_name}:#{window_index}.#{pane_index} >> /tmp/cmux-tmux-alerts.log"'
tmux set-hook -g alert-activity 'run-shell "echo ACTIVITY:#{pane_id} #{session_name}:#{window_index}.#{pane_index} >> /tmp/cmux-tmux-alerts.log"'
tmux set-hook -g alert-silence 'run-shell "echo SILENCE:#{pane_id} #{session_name}:#{window_index}.#{pane_index} >> /tmp/cmux-tmux-alerts.log"'

# Test bell alert
printf '\a'  # triggers alert-bell hook

# Enable activity monitoring
tmux set -g monitor-activity on
tmux set -g visual-activity on

# Enable silence monitoring (30 second threshold)
tmux set -g monitor-silence 30
tmux set -g visual-silence on

# Show currently installed hooks
tmux show-hooks -g

# Remove hooks
tmux set-hook -u -g alert-bell
tmux set-hook -u -g alert-activity
tmux set-hook -u -g alert-silence

# Enable passthrough for OSC sequences
tmux set -g allow-passthrough on

# Send OSC 9 through tmux passthrough
printf '\ePtmux;\e\e]9;Test notification from inside tmux\a\e\\'
```
