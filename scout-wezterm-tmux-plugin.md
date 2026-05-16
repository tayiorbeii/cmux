# WezTerm ↔ tmux Pane Switching Plugin — Analysis

## Files Retrieved

1. `/Users/taylor/dotfiles/wezterm/.config/wezterm/keys/navigation.lua` (411 lines) — **Core mechanism: ALT+h/j/k/l tmux-aware pane navigation**
2. `/Users/taylor/dotfiles/wezterm/.config/wezterm/helpers.lua` (188 lines) — `rename_pane()` with tmux IPC integration
3. `/Users/taylor/dotfiles/wezterm/.config/wezterm/pickers.lua` (~400 lines) — Tab/pane picker with tmux sub-pane introspection
4. `/Users/taylor/dotfiles/wezterm/.config/wezterm/events.lua` (525 lines) — Event handlers, overlay mode, trigger system
5. `/Users/taylor/dotfiles/wezterm/.config/wezterm/keys/init.lua` (70 lines) — Key aggregator, leader = Ctrl+B
6. `/Users/taylor/dotfiles/wezterm/.config/wezterm/wezterm.lua` (92 lines) — Main entry point
7. `/Users/taylor/dotfiles/tmux/.tmux.conf` — tmux config (Ctrl+A prefix, vim-tmux-navigator, cmux hooks)

## Architecture Overview

This is **not a standalone plugin** but a deeply integrated system within the user's WezTerm Lua config that enables **seamless bidirectional pane navigation between tmux and WezTerm**. When tmux runs inside WezTerm, the ALT+h/j/k/l keys intelligently navigate tmux panes first, and only "fall through" to WezTerm pane navigation when tmux is at its edge.

## The Core Mechanism: Edge-Detection-Based Handoff

### Location
`keys/navigation.lua` — The four `ALT+h/j/k/l` keybindings (lines ~135–411)

### Algorithm (same for all 4 directions)

```
ALT+h/j/k/l pressed
  ↓
1. Get TTY of current WezTerm pane: pane:get_tty_name()
  ↓
2. Run: tmux list-clients -F "#{client_tty}||#{client_session}"
   → Find the tmux client whose TTY matches this WezTerm pane
  ↓
3. Run: tmux display-message -t <tty> -p "#{pane_id}"
   → Get the current tmux pane ID
  ↓
4. Run: tmux display-message -t <tty> -p "#{pane_at_left/top/bottom/right}"
   → Check if tmux is at its edge in the navigation direction
  ↓
5a. IF at edge (value == "1"):
    → Cross the boundary: wezterm.action.ActivatePaneDirection('Left/Down/Up/Right')
    → Returns immediately (WezTerm handles the move)
  ↓
5b. IF NOT at edge:
    → Stay inside tmux: tmux select-pane -t <pane_id> -L/-D/-U/-R
    → Returns immediately (tmux handles the move)
  ↓
Fallback (no tmux detected):
    → Direct WezTerm pane navigation: ActivatePaneDirection
```

### Key Design Decision: `pane_at_*` vs `before/after` comparison

The code comments explain why they chose `#{pane_at_left}`, `#{pane_at_top}`, etc. over comparing pane IDs before/after a `select-pane` call:

> Edge detection: uses pane_at_* format variables instead of before/after pane_id comparison. The before/after approach fails because select-pane wraps at tmux edges (e.g., select-pane -D from the bottom pane wraps to the top pane), causing a false "tmux moved" detection and skipping the wezterm fallback entirely.

### TTY-Based Client Resolution

The plugin matches WezTerm panes to tmux clients using the **TTY device name**:

```lua
local tty = pane:get_tty_name()  -- e.g. "/dev/ttys003"
-- then match against:
tmux list-clients -F "#{client_tty}||#{client_session}"
```

This avoids tmux's "ambiguous session-name resolution" by targeting the specific client TTY directly.

### Exact tmux Commands Per Direction

| Key | tmux edge check | tmux navigation | WezTerm fallback |
|-----|-----------------|------------------|-----------------|
| ALT+h | `#{pane_at_left}` | `select-pane -t <id> -L` | `ActivatePaneDirection 'Left'` |
| ALT+j | `#{pane_at_bottom}` | `select-pane -t <id> -D` | `ActivatePaneDirection 'Down'` |
| ALT+k | `#{pane_at_top}` | `select-pane -t <id> -U` | `ActivatePaneDirection 'Up'` |
| ALT+l | `#{pane_at_right}` | `select-pane -t <id> -R` | `ActivatePaneDirection 'Right'` |

## "Independent Switching" — What It Means

The system does **not** maintain separate focus stacks. Instead, it creates a **unified navigation tree** where:

1. **tmux panes are navigated first** — ALT+h/j/k/l always tries tmux navigation
2. **WezTerm panes act as the outer layer** — only reached when tmux reports being at an edge
3. **Without tmux**, ALT+h/j/k/l navigates pure WezTerm panes directly

This means:
- You can have **multiple WezTerm panes**, each containing **multiple tmux panes**
- Navigation within a tmux session stays inside tmux
- Navigation at tmux edges "breaks through" to adjacent WezTerm panes
- Each WezTerm pane's tmux session is independent

## Two Navigation Modes

### Mode 1: ALT+h/j/k/l — Smart tmux-aware (the plugin)
- Crosses tmux↔WezTerm boundaries automatically
- Uses edge detection to decide when to hand off

### Mode 2: LEADER+h/j/k/l — Pure WezTerm (bypasses tmux)
```lua
{ mods = "LEADER", key = "h", action = act.ActivatePaneDirection "Left" },
{ mods = "LEADER", key = "j", action = act.ActivatePaneDirection "Down" },
{ mods = "LEADER", key = "k", action = act.ActivatePaneDirection "Up" },
{ mods = "LEADER", key = "l", action = act.ActivatePaneDirection "Right" },
```
These **always** navigate WezTerm panes, ignoring tmux entirely. The leader key is `Ctrl+B`.

## Additional tmux Integration Points

### 1. Pane Renaming — `helpers.rename_pane()` (lines ~106–188)

When renaming a pane, the system:
1. Updates `wezterm.GLOBAL.pane_aliases` for WezTerm display
2. Detects if the pane runs tmux (by walking the process tree from the TTY's PID)
3. Extracts the tmux socket from the tmux client's `TMUX` env var
4. Matches the tmux pane by CWD comparison across all `tmux list-panes -a`
5. Runs `tmux select-pane -T "<name>"` to rename the tmux pane too

### 2. Tab/Pane Picker — `pickers.show_tab_picker()` (pickers.lua)

The picker introspects tmux sessions running inside WezTerm panes:
- Uses **PID-based matching** (walks process tree for `tmux` or `ntm` processes)
- Maps WezTerm panes → tmux windows via `tmux list-clients -F "#{client_pid}||#{window_id}"`
- Shows tmux sub-panes as indented entries under their parent WezTerm pane
- Selecting a tmux sub-pane: activates the parent WezTerm tab/pane, then runs `tmux select-pane -t <target>`

### 3. External Trigger System

Events like `toggle_overlay`, `quick_open`, etc. are triggered by writing to `/tmp/wezterm.trigger`. The `window-focus-changed` event processes triggers immediately.

## Key Bindings Summary

| Binding | Layer | Behavior |
|---------|-------|----------|
| `ALT+h/j/k/l` | tmux-aware | Navigate tmux first, fall through to WezTerm at edges |
| `ALT+SHIFT+h/j/k/l` | WezTerm only | Resize panes (5 cells) |
| `LEADER+h/j/k/l` | WezTerm only | Navigate WezTerm panes (bypasses tmux) |
| `CMD+1-9` | WezTerm | Switch to pane by index |
| `CMD+E` | WezTerm | Pane selector (number overlay) |
| `ALT+9` | WezTerm + tmux | Fuzzy tab/pane picker (shows tmux sub-panes) |
| `LEADER+,` | WezTerm | Rename tab |
| `SHIFT+ALT+P` | WezTerm + tmux | Rename pane (updates both WezTerm alias and tmux pane title) |
| `LEADER+.` | WezTerm + tmux | Rename pane (same, leader variant) |

## tmux Config Notes

- Prefix: `Ctrl+A` (not the default Ctrl+B — that's WezTerm's leader)
- Has `christoomey/vim-tmux-navigator` installed (for pure-tmux vim-style navigation outside WezTerm)
- `set -g allow-passthrough on` — enables WezTerm↔tmux escape sequence passthrough
- `set -g extended-keys on` + `xterm-keys on` — full key passthrough
- cmux notification bridge forwards tmux bells to the cmux app

## How It All Connects (Data Flow)

```
User presses ALT+h
    │
    ▼
WezTerm keys/navigation.lua callback
    │
    ├─ pane:get_tty_name() → "/dev/ttys003"
    │
    ├─ tmux list-clients → find client on ttys003
    │   │
    │   ├─ Found tmux client? ─── YES ───►
    │   │                              │
    │   │                              ├─ tmux display-message → pane_id
    │   │                              │
    │   │                              ├─ tmux display-message → pane_at_left?
    │   │                              │     │
    │   │                              │     ├─ "1" (at edge) → ActivatePaneDirection('Left') [WEZTERM]
    │   │                              │     └─ "0" (not edge) → tmux select-pane -L [TMUX]
    │   │                              │
    │   └─ No tmux client ──► ActivatePaneDirection('Left') [WEZTERM DIRECT]
    │
    └─ No TTY (shouldn't happen) → ActivatePaneDirection('Left') [WEZTERM DIRECT]
```

## Start Here

Open `/Users/taylor/dotfiles/wezterm/.config/wezterm/keys/navigation.lua` — specifically the four ALT+h/j/k/l bindings starting around line 135. This is the entire tmux-aware navigation mechanism in ~280 lines of Lua.
