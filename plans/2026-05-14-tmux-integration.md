# tmux Integration Plan

**Date:** 2026-05-14
**Status:** Research complete, ready for implementation planning

## Overview

Two features to bring tmux integration to cmux, modeled on the user's existing WezTerm tmux-aware pane switching plugin and extending the partially-built tmux notification bridge.

---

## Feature 1: tmux-Aware Pane Navigation

### Goal

When a cmux surface is running tmux, pane navigation shortcuts (h/j/k/l) should:
1. Navigate tmux panes first (inside the surface)
2. Fall through to cmux split navigation only when tmux reports being at its edge
3. Allow a bypass modifier to always navigate cmux splits (ignoring tmux)

### Reference Implementation

The user's WezTerm plugin at `~/dotfiles/wezterm/.config/wezterm/keys/navigation.lua` implements this exact pattern using:

- **TTY-based client resolution**: `pane:get_tty_name()` → match against `tmux list-clients -F "#{client_tty}"`
- **Edge detection**: `tmux display-message -t <tty> -p "#{pane_at_left/top/bottom/right}"` — returns `"1"` when at edge
- **Why `pane_at_*` over exit codes**: `select-pane -D` wraps at edges (bottom→top), causing false "tmux moved" detection. `pane_at_*` is unambiguous.
- **Two modes**: `ALT+h/j/k/l` (tmux-aware) vs `LEADER+h/j/k/l` (pure WezTerm, bypasses tmux)

### Algorithm (per direction keypress)

```
1. Get focused surface
2. Is surface tmux-managed? (cached check)
   NO → cmux native pane navigation. Done.
   YES → continue
3. Get surface TTY → resolve tmux client
4. tmux display-message -t <tty> -p "#{pane_at_<dir>}"
5a. "1" (at edge) → cmux native pane navigation. Done.
5b. "0" (not edge) → tmux select-pane -t <id> -<dir>. Done.
```

### Architecture

#### Interception Point

`Sources/AppDelegate.swift` lines 11785-11850 — where `performKeyEquivalent` dispatches pane focus shortcuts (`focusLeft/Right/Up/Down`). Before calling `tabManager?.movePaneFocus(direction:)`, insert tmux-awareness check.

#### Current Call Chain

```
AppDelegate.performKeyEquivalent
  └─ KeyboardShortcutSettings (.focusLeft/Up/Down/Right)
      └─ TabManager.movePaneFocus(direction:)
          └─ Workspace.moveFocus(direction:)
              └─ bonsplitController.navigateFocus()
                  └─ applyTabSelection()
                      └─ Panel.focusPanel()
                          └─ GhosttySurface.ensureFocus()
```

Ghostty native path (same destination):
```
Ghostty C library → GHOSTTY_ACTION_GOTO_SPLIT
  → GhosttyTerminalView handler
    → TabManager.moveSplitFocus()
      → Workspace.moveFocus()
```

**Both paths need the tmux-awareness gate.**

#### New Component: TmuxSurfaceCache

A lightweight cache that tracks which surfaces are currently running tmux.

```swift
// Pseudocode
actor TmuxSurfaceCache {
    // surface UUID → is tmux-managed
    var tmuxSurfaces: Set<UUID>
    
    // surface UUID → tmux client TTY
    var surfaceTTYs: [UUID: String]
    
    // Invalidate on: surface focus change, surface lifecycle, layout change
    func refresh(surfaceId: UUID, tty: String?) async -> Bool
    
    // Quick synchronous check (cached)
    func isTmuxManaged(surfaceId: UUID) -> Bool
    
    // Run edge detection
    func isAtEdge(surfaceId: UUID, direction: NavigationDirection) async -> Bool
    
    // Navigate within tmux
    func selectPane(surfaceId: UUID, direction: NavigationDirection) async -> Bool
}
```

**Detection methods** (in order of preference):
1. `tmuxStartCommand` on `TerminalSurface` — set at creation, but not updated if tmux is launched later
2. Process tree check — walk foreground process name for "tmux" (like WezTerm's `pane:get_foreground_process_name()`)
3. TTY → `tmux list-clients` match — definitive but requires subprocess

**Caching strategy:**
- Set `isTmuxManaged` on focus change
- Invalidate on surface close, focus change, layout change
- Only run subprocess for edge detection (1 call per navigation keypress when tmux-managed)

#### Shortcut Configuration

- New shortcuts for tmux-aware navigation (default: `ALT+h/j/k/l` or user-configurable)
- Bypass modifier for pure cmux navigation (default: `LEADER+h/j/k/l` or similar)
- Both must go through `KeyboardShortcutSettings`, visible in Settings UI, supported in `cmux.json`, documented

### Implementation Steps

1. **Create `TmuxSurfaceDetector`** — utility to detect tmux on a surface via TTY + `tmux list-clients`
2. **Create `TmuxNavigationController`** — edge detection + `select-pane` execution
3. **Add `tmuxAwarePaneFocus` shortcut action** to `KeyboardShortcutSettings`
4. **Intercept in `AppDelegate`** — check tmux state before dispatching to `movePaneFocus()`
5. **Handle Ghostty native path** — intercept `GHOSTTY_ACTION_GOTO_SPLIT` similarly
6. **Add caching** — avoid subprocess per keystroke for tmux detection
7. **Add bypass shortcut** — always-navigate-cmux-splits modifier
8. **Settings UI** — toggle tmux-aware navigation on/off, configure keybindings
9. **Testing** — tagged debug build, manual testing with tmux sessions

### Constraints

- **Typing-latency-sensitive path**: `performKeyEquivalent` is called on every event. tmux subprocess calls must be off-main or ultra-fast (~1ms budget). Cache the tmux-managed flag; only subprocess for edge detection.
- **Shortcut policy**: All new shortcuts → `KeyboardShortcutSettings` + Settings UI + `cmux.json` + docs
- **Snapshot boundary**: No `@ObservedObject` in lazy rows (not directly relevant here but keep in mind)
- **Thread safety**: `surfaceTTYNames` is `@MainActor`. tmux subprocess runs off-main, dispatches result to main actor.

### Performance Budget

| Operation | Frequency | Cost | Total |
|-----------|-----------|------|-------|
| Cache check (isTmuxManaged) | Every nav keypress | ~0µs (in-memory) | 0µs |
| tmux edge detection | Only on tmux surfaces | ~0.5-1ms (subprocess) | ~1ms |
| tmux select-pane | Only on tmux non-edge | ~0.5ms (subprocess) | ~0.5ms |
| cmux native navigation | Fallback | existing cost | — |

**Worst case: ~1.5ms per keypress** — well within 16ms frame budget.

---

## Feature 2: tmux Alert → cmux Notification Bridge

### Goal

When AI assistants or other programs in tmux panes trigger alerts (bell, activity, silence), those alerts should appear in cmux's native notification system with:
- Unread badge on the correct workspace
- Dock badge count
- Desktop notification with tmux pane context
- Unread ring overlay on the tmux pane within the surface
- Workspace reorder for high-priority alerts

### What Already Exists

The foundation is **already partially built**:

1. **tmux hooks in `.tmux.conf`** (lines 133-155):
   ```
   set -g monitor-bell on
   set -g bell-action any
   set -g monitor-silence 15
   set-hook -g alert-bell 'run-shell "cmux hooks feed --source tmux-bridge --event bell"'
   set-hook -g alert-silence 'run-shell "cmux hooks feed --source tmux-bridge --event silence"'
   ```

2. **cmux hooks system** (`cmux hooks feed`): accepts JSON from external sources, forwards to socket

3. **Notification pipeline**: `TerminalNotificationStore` → `TerminalNotificationPolicyEngine` → effects (unread badge, dock badge, desktop notification, pane flash, workspace reorder)

4. **TTY-based routing**: `TerminalNotificationCallerResolver.targetForTTY()` walks all workspaces' `surfaceTTYNames` to match caller's TTY to a specific surface

5. **Socket commands**: `notification.create_for_caller` with `caller_tty`, `preferred_workspace_id`, `preferred_surface_id`

6. **Unread ring overlays**: `TmuxWorkspacePaneOverlayView` renders blue rings around tmux panes with animation

7. **tmux layout data**: `TmuxPaneLayoutReport` provides per-pane geometry from shell integration

### What's Missing

1. **tmux metadata in bridge events** — current hooks don't pass `#{pane_id}`, `#{session_name}`, `#{window_index}`, `#{pane_current_command}`
2. **Surface routing from tmux context** — hook fires with tmux metadata but needs to map to cmux surface
3. **AI-specific alert types** — "waiting for input" vs "idle" vs "completed task"
4. **Auto-installation of hooks** — currently user-managed in `.tmux.conf`; cmux could auto-detect and install

### Enhanced Hook Design

Replace current `.tmux.conf` hooks with metadata-rich versions:

```bash
# Bell — AI assistant bell or terminal bell
set-hook -g alert-bell 'run-shell "cmux hooks feed --source tmux-bridge --event bell --pane-id #{pane_id} --session #{session_name} --window #{window_index} --pane #{pane_index} --command \'#{pane_current_command}\' --message \'Bell in #{session_name}:#{window_index}.#{pane_index}\'"'

# Activity — output detected after silence (AI finished working)
set-hook -g alert-activity 'run-shell "cmux hooks feed --source tmux-bridge --event activity --pane-id #{pane_id} --session #{session_name} --window #{window_index} --pane #{pane_index} --command \'#{pane_current_command}\' --message \'Activity in #{session_name}:#{window_index}.#{pane_index}\'"'

# Silence — no output for threshold seconds (AI waiting for input)
set-hook -g alert-silence 'run-shell "cmux hooks feed --source tmux-bridge --event silence --pane-id #{pane_id} --session #{session_name} --window #{window_index} --pane #{pane_index} --command \'#{pane_current_command}\' --message \'Silence in #{session_name}:#{window_index}.#{pane_index}\'"'
```

### AI Assistant Signal Mapping

| tmux Signal | Meaning for AI assistants | cmux Notification |
|-------------|--------------------------|-------------------|
| `alert-silence` (15s) | AI stopped outputting → waiting for input or idle | "AI waiting" — desktop notification, unread badge |
| `alert-activity` | AI started outputting after silence | "AI active" — clear unread badge, optional flash |
| `alert-bell` | AI explicitly rang bell (Claude Code `--notify`, Aider bell) | "AI alert" — desktop notification, dock bounce, pane flash |

### Enhanced Notification Routing

The bridge should map tmux events to cmux surfaces:

```
tmux hook fires with #{pane_id}, #{session_name}
  → cmux hooks feed receives JSON
    → cmux socket receives notification.create_for_caller
      → TerminalNotificationCallerResolver.targetForTTY()
        → matches caller TTY against surfaceTTYNames
          → routes to correct workspace + surface
            → notification effects fire
```

### Implementation Steps

1. **Enhance `.tmux.conf` hooks** — pass full tmux metadata
2. **Extend `cmux hooks feed`** — parse tmux bridge metadata, construct notification with context
3. **Add AI-aware notification types** — map silence→"waiting", activity→"active", bell→"alert"
4. **Route to correct surface** — use TTY matching from existing `TerminalNotificationCallerResolver`
5. **Add notification content** — include tmux pane command, session name, window/pane index
6. **Test end-to-end** — trigger bell in tmux, verify notification appears in cmux

### Future: OSC-Based Custom Alerts (Phase 3)

For richer AI assistant integration:

1. **Define OSC 9 convention**: `printf '\ePtmux;\e\e]9;[CMUX] ai-waiting Claude Code needs input\a\e\\'`
2. **Enable tmux passthrough**: `set -g allow-passthrough on`
3. **Ghostty/cmux parser intercepts** OSC 9 with `[CMUX]` prefix → routes to notification system
4. **Ship shell wrapper functions** for AI tools that emit these sequences automatically

---

## Key Files

| File | Role |
|------|------|
| `Sources/AppDelegate.swift:11785-11850` | Pane focus shortcut dispatch (interception point) |
| `Sources/TabManager.swift:5567` | `movePaneFocus(direction:)` |
| `Sources/Workspace.swift:11850` | `moveFocus(direction:)` — bonsplit navigation |
| `Sources/Workspace.swift:7305` | `surfaceTTYNames` — TTY tracking per surface |
| `Sources/GhosttyTerminalView.swift:3804` | `GHOSTTY_ACTION_GOTO_SPLIT` handler |
| `Sources/GhosttyTerminalView.swift:4454` | `TerminalSurface` with `tmuxStartCommand`, TTY tracking |
| `Sources/TerminalNotificationStore.swift` | Full notification pipeline |
| `Sources/TerminalNotificationCallerResolver.swift` | TTY-based notification routing |
| `Sources/TerminalNotificationPolicy.swift` | Notification hook engine |
| `Sources/TmuxWorkspacePaneOverlayView.swift` | Unread ring overlays for tmux panes |
| `CLI/CMUXCLI+TmuxCompatSupport.swift` | Existing tmux CLI compat layer |
| `~/dotfiles/tmux/.tmux.conf:133-155` | Existing tmux→cmux alert bridge hooks |
| `~/dotfiles/wezterm/.config/wezterm/keys/navigation.lua` | Reference WezTerm tmux navigation |

## tmux CLI Quick Reference

```bash
# Detect tmux client for a TTY
tmux list-clients -F "#{client_tty}||#{client_session}"

# Edge detection
tmux display-message -t <tty> -p "#{pane_at_left}"
tmux display-message -t <tty> -p "#{pane_at_top}"
tmux display-message -t <tty> -p "#{pane_at_bottom}"
tmux display-message -t <tty> -p "#{pane_at_right}"

# Navigate within tmux
tmux select-pane -t <pane_id> -L
tmux select-pane -t <pane_id> -R
tmux select-pane -t <pane_id> -U
tmux select-pane -t <pane_id> -D

# Alert hooks
set-hook -g alert-bell 'run-shell "cmux hooks feed --source tmux-bridge --event bell"'
set-hook -g alert-activity 'run-shell "cmux hooks feed --source tmux-bridge --event activity"'
set-hook -g alert-silence 'run-shell "cmux hooks feed --source tmux-bridge --event silence"'

# Passthrough for OSC sequences
set -g allow-passthrough on
printf '\ePtmux;\e\e]9;Test notification\a\e\\'
```

## Risks & Open Questions

1. **Ghostty foreground process API** — How does cmux get the current foreground process name of a Ghostty surface at runtime? `tmuxStartCommand` is set at creation. Need runtime check for "tmux launched after surface creation."

2. **Hook coexistence** — If cmux auto-installs tmux hooks, must not clobber user hooks. `set-hook` replaces; need append strategy or wrapper script.

3. **Nested tmux** — Single-level tmux is the right first target. Inner tmux sessions are the user's responsibility.

4. **Multi-surface tmux sessions** — A tmux session attached from multiple cmux surfaces needs careful notification routing.

5. **AI tool notification capabilities** — Which AI tools support custom notification hooks? Claude Code has `--notify`; others need research.

6. **Shortcut collision** — The user's WezTerm uses `ALT+h/j/k/l` for tmux-aware nav and `LEADER+h/j/k/l` for pure WezTerm. cmux needs to pick bindings that don't conflict with existing Ghostty shortcuts or tmux prefix keys.
