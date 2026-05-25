# Terminal Copy Mode Cursor UX — Architecture & Implementation Plan

**Date:** 2026-05-22
**Status:** Proposal
**Supersedes:** `docs/copy-mode-implementation-plan.md` (which was written before the invisible-cursor and scroll-mode bugs were identified)

---

## Table of Contents

1. [Root Cause Analysis](#1-root-cause-analysis)
2. [Target UX Definition](#2-target-ux-definition)
3. [Architecture Options](#3-architecture-options)
4. [Recommended Hybrid Approach](#4-recommended-hybrid-approach)
5. [State Model Changes](#5-state-model-changes)
6. [Rendering Strategy](#6-rendering-strategy)
7. [Scroll / Cursor Semantics](#7-scroll--cursor-semantics)
8. [Ghostty Fork Impact](#8-ghostty-fork-impact)
9. [Phase Plan](#9-phase-plan)
10. [Test / Verification Strategy](#10-test--verification-strategy)

---

## 1. Root Cause Analysis

### 1.1 Why is the cursor invisible?

The copy-mode "cursor" is a 1-cell selection created via `ghostty_surface_select_cursor_cell()`. This function (in `ghostty/src/Surface.zig:2081`) creates a `Selection` at the **terminal's active cursor position** — where the user was typing, not where the viewport is.

```zig
// Surface.zig:2081–2097 (simplified)
pub fn selectCursorCell(self: *Surface) !bool {
    const screen = self.io.terminal.screens.active;
    const pin = screen.cursor.page_pin.*;  // ← active cursor, NOT viewport
    try self.setSelection(terminal.Selection.init(pin, pin, false));
    screen.dirty.selection = true;
}
```

**This position does not move when the viewport scrolls.** After the user presses `j`/`k`:

1. `scrollLines(1)` → Ghostty's `scroll_page_lines` binding queues a viewport scroll Delta. No selection change.
2. `refreshKeyboardCopyModeViewportRowFromVisibleAnchor(surface:)` runs.
3. This calls `keyboardCopyModeSelectionAnchor()`, which calls `ghostty_surface_select_cursor_cell_compat(surface)` **again** — still at the active cursor position.
4. The viewport has moved away from that position. The 1-cell selection is now off-screen.

**Result:** After the first scroll operation, the "cursor" is invisible because it's rendered at a fixed buffer position while the viewport has moved.

Additionally, even if it were in the right position, the cursor is rendered using Ghostty's **selection highlight** (selection_background_color / selection_foreground_color shader uniforms, `renderer/generic.zig:2109-2119`). If the user's theme has minimal contrast between selection and background, it's invisible even when on-screen.

### 1.2 Why do `j`/`k` scroll instead of moving a visible cursor?

This is an intentional design choice in `handleKeyboardCopyModeIfNeeded(surface:)`:

```swift
// Line 7286–7288: deliberately uses visual-mode flag, NOT raw hasSelection
let hasSelection = keyboardCopyModeVisualActive
```

The code deliberately prevents the 1-cell cursor selection from making normal-mode motions behave as selection extension (which would immediately enter visual-mode semantics). But the alternative implemented — `scrollLines(1)` / `scrollLines(-1)` — is also wrong: it scrolls the viewport without moving any cursor position marker.

**The semantic gap:** Current architecture has no "cursor position" concept. It only has:
- A viewport row tracking variable (`keyboardCopyModeViewportRow`)
- A visual-mode boolean (`keyboardCopyModeVisualActive`)
- Ghostty selection state (either 1-cell cursor or user's extended selection)

There is **no cursor row** or **cursor column** that user motions can adjust independently of selection.

### 1.3 Why does visual mode start from a hidden position?

When the user presses `v`:

1. `keyboardCopyModeVisualActive = true`
2. Next `j`/`k` → `.adjustSelection(.down/up)` → Ghostty's `adjust_selection` binding handler extends the selection endpoint.
3. But the selection is still at the active cursor position (off-screen).
4. Ghostty's `adjust_selection` auto-scrolls only **after** the first movement (part of the `adjust_selection` handler in `Surface.zig:5893–5942`).

So visual mode begins from an off-screen point, and the first movement both extends the selection and scrolls to reveal it — creating a confusing "jump" and an initially-invisible selection origin.

### 1.4 Summary of root causes

| Problem | Root Cause |
|---------|-----------|
| Cursor invisible | 1-cell selection placed at fixed active cursor; viewport scrolls away from it. Selection colors may also be low-contrast. |
| j/k scroll instead of move cursor | No cursor-position state model. `keyboardCopyModeVisualActive` flag gates between "scroll" and "selection-extend" behaviors. |
| Visual mode starts hidden | Selection anchor is at active cursor (off-screen after scrolling). No separate "visual anchor" state. |
| No h/l/w/b motions in normal mode | Motions that aren't mapped to `.scrollLines(n)` return `nil` when not in visual mode. |

---

## 2. Target UX Definition

### 2.1 Entering copy mode

| Action | Expected behavior |
|--------|------------------|
| `⌘⇧M` | Enter copy mode. Show "vim" badge. Place a **visible cursor** at the top-left of the current viewport content, or at the last terminal cursor position if it's in view. |

### 2.2 Visible cursor appearance

The cursor should be:
- A **solid block** or **outlined cell** at the current cursor position
- Inverted or high-contrast relative to the terminal theme (e.g., invert the cell's foreground/background)
- **Not dependent** on the Ghostty selection highlight colors
- Persistent across scroll operations
- Theme-independent: should be visible even with low-contrast selection colors

### 2.3 Normal-mode cursor movement

| Motion | Expected behavior |
|--------|------------------|
| `h` | Move cursor left one cell (no wrap by default) |
| `j` | Move cursor down one row |
| `k` | Move cursor up one row |
| `l` | Move cursor right one cell |
| `w` | Move cursor forward by word (start of next word) |
| `b` | Move cursor backward by word (start of current/previous word) |
| `e` | Move cursor to end of word |
| `0` | Move cursor to column 0 of current row |
| `$` | Move cursor to last non-empty column of current row |
| `^` | Move cursor to first non-empty column of current row |
| `g` (prefix) | Prefix for `gg` |
| `gg` | Move cursor to scrollback top (row 0) |
| `G` (shift+g) | Move cursor to scrollback bottom (last written row) |
| `Ctrl-u` | Move cursor up half a page |
| `Ctrl-d` | Move cursor down half a page |
| `Ctrl-b` / Page Up | Move cursor up one full page |
| `Ctrl-f` / Page Down | Move cursor down one full page |

### 2.4 Viewport anchoring

- The viewport should **follow the cursor** when it moves to keep it visible
- When the cursor reaches a configurable scroll-off margin (e.g., 3 lines from top/bottom), the viewport auto-scrolls
- If the cursor is already on-screen after a motion, the viewport should **not** scroll (avoid distracting jumps)
- `z` + Enter / `z.` / `zz` / `zt` / `zb` for repositioning cursor in viewport (nice-to-have)

### 2.5 Visual mode

| Action | Expected behavior |
|--------|------------------|
| `v` | Enter visual mode. Selection begins at current cursor position. Cursor becomes the selection endpoint. |
| `V` | Enter visual line mode. Selection covers full lines from anchor to current line. |
| `Ctrl-v` | Enter visual block mode. Rectangle selection between anchor and cursor. |
| Motions (h/j/k/l/w/b, etc.) | Extend selection in visual mode (already works via `adjust_selection` Ghostty binding) |
| `o` | Swap selection anchor to the other end (move "active" end of selection) |
| `v` (in visual) | Return to normal mode, cursor stays at current position |

### 2.6 Yank / exit

| Action | Expected behavior |
|--------|------------------|
| `y` | Yank selected text to clipboard, exit copy mode |
| `yy` / `Y` | Yank current line to clipboard, exit copy mode |
| `q` | Exit copy mode, return to terminal input |
| `Escape` | Exit copy mode, return to terminal input |
| Enter (with mouse selection) | (Already in plan as Phase 1: copy-on-enter) |

---

## 3. Architecture Options

### Option 1: Selection color improvement only

**Approach:** Improve the selection color contrast or add a separate debug overlay.

**Verdict: INSUFFICIENT.** Does not fix any of the semantic problems:
- `j`/`k` still scroll the viewport
- No cursor position tracking
- Visual mode still starts from a hidden position
- `h`/`l`/`w`/`b`/`e`/`0`/`$` still don't work in normal mode

**Risk:** Low effort, but the user would still report "copy mode doesn't feel like tmux."

### Option 2: Pure cmux overlay cursor (no Ghostty fork changes)

**Approach:**
- Maintain cursor position state entirely in cmux Swift code
- Render a CALayer or NSView overlay on top of the Ghostty surface to show the cursor
- For selection in visual mode, use Ghostty's existing `adjust_selection` binding actions starting from the terminal cursor
- The overlay cursor tracks an independent (row, col) position

**Challenges:**
- Ghostty's `scroll_page_lines` binding doesn't move the selection cursor — so we can't use the 1-cell selection as the visual indicator
- Coordinate mapping: the overlay cursor needs to know the exact pixel position of each cell in the Ghostty surface, which requires knowing the font metrics, cell size, and scroll offset
- Ghostty draws the surface via its own compositing pipeline; an NSView overlay would be in a different layer and could have Z-ordering issues
- Selection in visual mode still uses Ghostty's internal selection, which starts from the terminal cursor — not from the overlay cursor position. Moving it to the right location would require many `adjust_selection` steps or a new API.

**Verdict:** Feasible for the cursor rendering and normal-mode state model, but fails to connect normal-mode cursor position to visual-mode selection. Would still need a Ghostty API for setting selection range.

### Option 3: Ghostty fork API expansion (selection by coordinates)

**Approach:** Add one or more new C API exports in Ghostty's `embedded.zig`:

```
ghostty_surface_set_selection_range(surface, row1, col1, row2, col2, is_rect)
```

This API would:
1. Receive screen-relative coordinates (buffer coordinates)
2. Internally call `s.pages.pin(.{ .screen = .{ .x = col, .y = row } })` to get Pins
3. Create a `terminal.Selection.init(pin1, pin2, rect)`
4. Call `self.setSelection(selection)`

**Advantages:**
- Enables placing the cursor (1-cell selection) at arbitrary positions
- Enables setting selection ranges from visual mode
- Connection between normal-mode cursor and visual-mode selection is clean
- Ghostty's existing `adjust_selection` binding and auto-scroll work naturally

**Challenges:**
- Requires modifying Ghostty submodule (two commits: one for the API, one for the cmux integration)
- The `pin()` method on PageList requires access to the screen struct — needs attention on thread safety (the renderer mutex pattern seen in existing APIs)

**Verdict:** Required for a clean implementation. Without it, visual mode selection cannot start from the correct cursor position.

### Option 4: Hybrid approach (RECOMMENDED)

Combine the best of Option 2 and Option 3:

1. **cmux-side state model**: cursor row, col, preferred column, visual anchor. All motion logic in Swift.
2. **Ghostty API** (`ghostty_surface_set_selection_range`): bridge the cursor position to Ghostty selection for rendering and visual mode.
3. **Cursor rendering**: Use the Ghostty selection mechanism (correctly-placed 1-cell selection) for visibility, enhanced by ensuring high-contrast selection colors. Only fall back to an overlay cursor if selection colors prove insufficient.

---

## 4. Recommended Hybrid Approach

### Why hybrid?

| Concern | How addressed |
|---------|---------------|
| Normal-mode cursor position | cmux Swift state model handles all math |
| Cursor rendering in Ghostty | 1-cell selection via `ghostty_surface_set_selection_range` at cursor position |
| Visual mode selection | `ghostty_surface_set_selection_range` from anchor to cursor; Ghostty auto-scrolls |
| Viewport scroll to follow cursor | After cursor moves, if off-screen, scroll viewport via `scroll_page_lines` binding |
| No new overlay rendering | Leverage existing Ghostty selection rendering infrastructure |
| Theme independence | Ensure selection colors are always high-contrast in copy mode, or apply a forced inverted-cell color |

### Required Ghostty fork change

**One new C API:**

```c
// Set a selection range in buffer (screen) coordinates.
// row/col are 0-indexed buffer positions.
// If the selection endpoint is outside the current viewport, Ghostty auto-scrolls.
bool ghostty_surface_set_selection_range(
    ghostty_surface_t surface,
    uint32_t row_start, uint32_t col_start,
    uint32_t row_end, uint32_t col_end,
    bool is_rectangular
);
```

Implementation sketch (`ghostty/src/apprt/embedded.zig`):

```zig
export fn ghostty_surface_set_selection_range(
    surface: *Surface,
    row_start: u32, col_start: u32,
    row_end: u32, col_end: u32,
    is_rectangular: bool,
) bool {
    surface.renderer_state.mutex.lock();
    defer surface.renderer_state.mutex.unlock();

    const screen = surface.io.terminal.screens.active;
    const start_pin = screen.pages.pin(.{ .screen = .{ .x = col_start, .y = row_start } }) orelse return false;
    const end_pin = screen.pages.pin(.{ .screen = .{ .x = col_end, .y = row_end } }) orelse return false;
    surface.setSelection(terminal.Selection.init(start_pin, end_pin, is_rectangular)) catch return false;
    screen.dirty.selection = true;
    surface.queueRender() catch return false;
    return true;
}
```

### Files to change in Ghostty submodule

| File | Change |
|------|--------|
| `ghostty/include/ghostty.h` | Add `ghostty_surface_set_selection_range` declaration |
| `ghostty/src/apprt/embedded.zig` | Add export implementation |
| `ghostty/src/Surface.zig` | `setSelection` already exists (private at line 2394); either make it public or keep calling it from embedded.zig |

### Why `pin(.screen)` not `.viewport`?

The `.screen` tag refers to the full scrollback buffer (all data, written rows only). `.viewport` refers to the visible viewport area. Since copy mode needs to place the cursor at any point in the scrollback, `.screen` is correct. The existing `selectCursorCell` and `adjust_selection` also work in screen coordinates.

---

## 5. State Model Changes

### 5.1 New cmux Swift state

Add to `GhosttyTerminalView.swift` (replacing/expanding current `keyboardCopyModeViewportRow`):

```swift
/// Copy mode cursor position in buffer (screen) coordinates.
/// These are 0-indexed and reference the full scrollback buffer.
private var copyCursor: (row: Int, col: Int) = (0, 0)

/// Preferred column for vertical motions (j/k). When the cursor moves
/// vertically, it tries to maintain this column unless the line is shorter.
private var copyPreferredCol: Int = 0

/// Visual mode anchor position. Set when entering visual mode or pressing 'o'.
/// Nil when not in visual mode.
private var copyVisualAnchor: (row: Int, col: Int)?

/// Whether visual mode is active (replaces keyboardCopyModeVisualActive)
private var copyVisualActive = false
```

### 5.2 Remove or replace

| Current variable | Replacement |
|-----------------|-------------|
| `keyboardCopyModeViewportRow` | Folded into `copyCursor.row` |
| `keyboardCopyModeVisualActive` | `copyVisualActive` |

### 5.3 State transition diagram

```
[not in copy mode]
  │ ⌘⇧M
  ▼
[normal mode]
  copyCursor = (initial row, col)
  copyVisualActive = false
  copyVisualAnchor = nil
  │
  ├── motions (h/j/k/l/w/b/e/0/$/gg/G/Ctrl-u/d/b/f)
  │   → update copyCursor, possibly scroll viewport
  │   → set selection to (copyCursor, copyCursor, false)
  │
  ├── v ───────────────► [visual mode]
  │                       copyVisualAnchor = copyCursor
  │                       copyVisualActive = true
  │                       selection = (anchor, cursor, false)
  │                       │
  │                       ├── motions → extend selection
  │                       │   → selection = (anchor, cursor + move, false)
  │                       │
  │                       ├── v / Esc → back to [normal mode]
  │                       │   cursor stays, selection cleared to 1-cell
  │                       │
  │                       └── y → yank selection, exit
  │
  ├── yy/Y → yank line at cursor, exit
  ├── q / Esc → exit copy mode
  └── [Ghostty search starts] → enters search sub-mode
```

---

## 6. Rendering Strategy

### 6.1 Cursor = 1-cell selection at correct position

The cursor is rendered by placing a 1-cell selection at `(copyCursor.row, copyCursor.col)` using the new `ghostty_surface_set_selection_range` API. This uses Ghostty's existing selection rendering infrastructure (shader uniforms, dirty-selection tracking).

### 6.2 Selection color contrast guarantee

To ensure the cursor is always visible regardless of theme:

1. In `setKeyboardCopyModeActive(true)`, **override** the selection colors to ensure high contrast:
   - Set `selection_background` to an inverted or contrasting color (e.g., `cursor-color` if available, or a forced inverse)
   - Restore original colors when copy mode exits

2. Alternatively, add a copy-mode-specific selection color config:
   - `cmux.copy-mode.selection-background` / `-foreground`
   - Falls back to regular selection colors if not set

3. The 1-cell selection at the current copy cursor position should use **inverted foreground/background** for maximum visibility (like a normal terminal cursor).

### 6.3 Selection rendering for visual mode

When `copyVisualActive = true`, the selection spans from `copyVisualAnchor` to `copyCursor`. Use normal selection colors (or copy-mode-specific variant). The cursor cell (endpoint) could be rendered with a distinct style (e.g., outlined block) to distinguish it from the rest of the selection.

### 6.4 Fallback: overlay cursor

If selection-based rendering proves insufficient (e.g., for accessibility), add an optional overlay:

- A `CALayer` or `NSView` positioned at the pixel coordinates of the cursor cell
- Pixel position computed from `ghostty_surface_ime_point` (cell size) + scroll offset + cursor row/col
- Rendered as a colored rectangle matching `cursor-color` from the theme
- Toggleable via config

This is **not required for Phase 1** but should be architected as an optional enhancement.

---

## 7. Scroll / Cursor Semantics

### 7.1 Normal-mode motion rules

Each motion in normal mode:

1. **Update `copyCursor`** (absolute or relative, depending on motion type)
2. **Check if cursor is still in viewport** (between `viewportTop` and `viewportBottom` in screen coordinates)
3. **If viewport needs to scroll** to keep cursor visible with scroll-off margin:
   - Calculate lines to scroll
   - Call `performBindingAction("scroll_page_lines:\(delta)")`
4. **Place 1-cell selection** via `ghostty_surface_set_selection_range` at the new cursor position

### 7.2 Scroll-off margin

- When cursor is within N rows of the viewport edge, auto-scroll
- `N = 3` by default, configurable via `cmux.json`
- When re-entering viewport via opposite motion, stop scrolling

### 7.3 Visual-mode motion rules

In visual mode, motions extend the selection:

1. **Update `copyCursor`** (same as normal mode)
2. **Set selection** via `ghostty_surface_set_selection_range` from `copyVisualAnchor` to `copyCursor`
3. Ghostty's `adjust_selection` auto-scroll already handles viewport following, but we may need to supplement it since we're setting the range directly

### 7.4 Cursor position on copy mode entry

On `⌘⇧M`:

```
1. Get current viewport bounds (ghostty_surface_size → rows)
2. Get viewport top-left point in screen coordinates
3. Set copyCursor to (viewportTopScreenRow, 0) -- top-left of viewport
   OR: set to terminal cursor position if it's within the viewport
4. Place 1-cell selection at copyCursor
```

---

## 8. Ghostty Fork Impact

### 8.1 Required changes

**One new C API:** `ghostty_surface_set_selection_range`

This is the **only** Ghostty fork change required for the core implementation. It is:

- **Cmux-specific:** Upstream Ghostty has no keyboard copy mode, so this API is cmux-only
- **Small:** ~15 lines of Zig + one C header declaration
- **Safe:** Uses the existing `renderer_state.mutex` pattern, `pin()` method, and `setSelection()` infrastructure
- **Composable:** After this API exists, ALL cursor and selection operations become straightforward from cmux

### 8.2 Why this API is necessary

Without it, there is no Swift-side way to:
- Place a cursor at an arbitrary buffer position
- Create a selection starting from the copy-mode cursor (not the terminal cursor)
- Implement visual mode with anchor-based semantics

The existing `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` are insufficient because:
- `selectCursorCell` always targets the terminal's **active cursor**, not an arbitrary position
- `adjust_selection` can move an existing selection but only by relative steps — reaching an arbitrary position from the terminal cursor would require O(N) API calls

### 8.3 Alternative: no Ghostty fork change

If a fork change is unacceptable, the alternative would be:
1. cmux overlay cursor for visibility
2. Use `ghostty_surface_select_cursor_cell` + N calls to `adjust_selection` to reposition the selection endpoint to the desired location
3. This is O(buffer_rows) in the worst case — impractical

**Verdict: Fork change is strongly recommended.**

### 8.4 Upstream compatibility

The API is added to the manaflow-ai/ghostty fork's embedded.zig and ghostty.h. When the next upstream rebase happens, these exports need to be re-verified (same as existing `selectCursorCell` / `clearSelection` — see ghostty-fork.md section 6).

---

## 9. Phase Plan

### Phase 0: Ghostty fork API (prerequisite)

| Step | File | Change |
|------|------|--------|
| 1 | `ghostty/include/ghostty.h` | Add `ghostty_surface_set_selection_range` declaration |
| 2 | `ghostty/src/apprt/embedded.zig` | Add export implementation |
| 3 | `.`, submodule commit | `git add ghostty && git commit` |

### Phase 1: Cursor state model + normal-mode motions (cmux only)

| Step | File | Change |
|------|------|--------|
| 1 | `Sources/GhosttyTerminalView.swift` | Add `copyCursor`, `copyPreferredCol`, `copyVisualAnchor`, `copyVisualActive` state |
| 2 | `Sources/GhosttyTerminalView.swift` | Update `setKeyboardCopyModeActive`: set initial cursor position |
| 3 | `Sources/GhosttyTerminalView.swift` | Replace scroll actions with cursor-move actions in key mapping |
| 4 | `Sources/GhosttyTerminalView.swift` | Add cursor-move implementation: update state, scroll viewport if needed, place 1-cell selection |
| 5 | `Sources/GhosttyTerminalView.swift` | Add viewport-anchor-after-scroll helper |
| 6 | `Sources/GhosttyTerminalView.swift` | Update `refreshKeyboardCopyModeViewportRowFromVisibleAnchor` to work with new model |

### Phase 2: Visual mode reconnection

| Step | File | Change |
|------|------|--------|
| 1 | `Sources/GhosttyTerminalView.swift` | `startSelection` → set `copyVisualAnchor = copyCursor`, `copyVisualActive = true` |
| 2 | `Sources/GhosttyTerminalView.swift` | Visual mode motions → set selection via `ghostty_surface_set_selection_range` from anchor to cursor |
| 3 | `Sources/GhosttyTerminalView.swift` | Update yank handler to use range selection |
| 4 | `Sources/GhosttyTerminalView.swift` | Add `o` support (swap anchor) |
| 5 | `Sources/GhosttyTerminalView.swift` | Visual line mode (`V`) — snap anchor and cursor to full lines |

### Phase 3: Additional motions

| Step | File | Change |
|------|------|--------|
| 1 | `Sources/GhosttyTerminalView.swift` | `w`/`b` word motions in normal and visual mode |
| 2 | `Sources/GhosttyTerminalView.swift` | `e` word-end motion (check Ghostty binding availability) |
| 3 | `Sources/GhosttyTerminalView.swift` | `0`/`^`/`$` for line-boundary motions in normal mode |
| 4 | `Sources/GhosttyTerminalView.swift` | Update `terminalKeyboardCopyModeAction` key mapping table |

### Phase 4: Visual block mode

| Step | File | Change |
|------|------|--------|
| 1 | `Sources/GhosttyTerminalView.swift` | `Ctrl-v` mapping |
| 2 | Both | Rectangle selection via `ghostty_surface_set_selection_range(..., is_rectangular: true)` |
| 3 | `Sources/GhosttyTerminalView.swift` | Block yank behavior |

### Phase 5: Selection color / overlay enhancement

| Step | File | Change |
|------|------|--------|
| 1 | `Sources/GhosttyTerminalView.swift` | Copy mode selection color override (high-contrast) |
| 2 | `Sources/GhosttyTerminalView.swift` | (Optional) overlay cursor CALayer if selection not visible enough |

---

## 10. Test / Verification Strategy

### 10.1 Unit tests (Swift, no app launch needed)

| Test target | What to test |
|-------------|-------------|
| `TerminalKeyboardCopyModeAction` | Key mapping correctness (all keys produce expected actions in normal/visual mode) |
| `TerminalKeyboardCopyModeResolve` | Count prefixes, `gg`, `yy` operator-pending behavior |
| Cursor state model | Position updates, preferred-column tracking, viewport-margin calculations |
| Visual anchor state | Setting/resetting, swap-with-cursor (`o`), line-mode snap |

### 10.2 Behavioral verification scenarios

These are validation scenarios for dogfood testing:

1. **Basic cursor visibility:**
   - Open terminal with multi-page scrollback
   - `⌘⇧M` → confirm cursor block is visible at top-left of viewport
   - Press `j` 5 times → cursor moves down 5 rows, viewport scrolls at margin

2. **Normal-mode motions:**
   - `k` → cursor moves up
   - `h`/`l` → cursor moves left/right
   - `gg` → cursor goes to scrollback top
   - `G` → cursor goes to scrollback bottom
   - `0`/`$` → cursor goes to line start/end

3. **Visual mode:**
   - Enter copy mode, navigate to interesting line
   - `v` → visual mode activates, selection starts at cursor
   - `j` → selection extends down one line
   - `k` → selection shrinks up
   - `y` → selected text copied, exits copy mode

4. **Visual line mode:**
   - Navigate to line, `V` → entire line selected
   - `j`/`k` → extends line selection

5. **Edge cases:**
   - Empty terminal (no scrollback)
   - Very wide lines
   - Lines with varying lengths (preferred-column behavior for j/k)
   - Copy mode from tab start (no viewport scroll yet)
   - Exit and re-enter copy mode multiple times
   - Theme with low-contrast selection colors (verify cursor is still visible)

### 10.3 Manual verification checklist

Copy-mode-related manual tests (to be added to the project's existing manual test checklist):

```
[ ] Copy mode cursor visible on entry
[ ] j/k moves cursor, viewport follows
[ ] h/l moves cursor horizontally
[ ] w/b/e word motions work
[ ] gg/G scroll-to-top/bottom
[ ] 0/$/^ line-boundary motions
[ ] v enters visual mode from correct position
[ ] Visual mode motions extend selection correctly
[ ] y yanks selected text
[ ] yy/Y yanks current line
[ ] q/Escape exits copy mode
[ ] Re-entry restores expected behavior
```

### 10.4 What should eventually be CI-covered

- Key mapping unit tests (no app launch)
- State model unit tests (no app launch)
- Python socket tests (`tests_v2/`) that test copy-mode behavior through the socket API
- E2E test that verifies copy-paste roundtrip through copy mode

---

## Appendix: Current Architecture vs Proposed

### Current (simplified)

```
GhosttyTerminalView
├── keyboardCopyModeActive: Bool
├── keyboardCopyModeVisualActive: Bool
├── keyboardCopyModeViewportRow: Int?
├── keyboardCopyModeInputState (countPrefix, pendingYankLine, pendingG)
└── handleKeyboardCopyModeIfNeeded(event, surface)
    ├── hasSelection = keyboardCopyModeVisualActive
    ├── resolve(event) → terminalKeyboardCopyModeAction(key, hasSelection)
    │   ├── hasSelection=true → .adjustSelection(dir)  [visual mode]
    │   └── hasSelection=false → .scrollLines(n)        [scroll mode]
    └── dispatch(action)
        ├── .scrollLines → performBindingAction("scroll_page_lines:δ")
        ├── .adjustSelection → performBindingAction("adjust_selection:dir")
        └── ...
```

### Proposed

```
GhosttyTerminalView
├── copyActive: Bool
├── copyCursor: (row: Int, col: Int)           ★ NEW
├── copyPreferredCol: Int                        ★ NEW
├── copyVisualActive: Bool
├── copyVisualAnchor: (row: Int, col: Int)?      ★ NEW
├── copyInputState (countPrefix, pendingYankLine, pendingG)
├── handleKeyboardCopyModeIfNeeded(event, surface)
│   ├── hasSelection = copyVisualActive
│   ├── resolve(event) → terminalKeyboardCopyModeAction(key, hasSelection)
│   │   ├── hasSelection=true → .adjustSelection(dir)  [visual mode]
│   │   └── hasSelection=false → .moveCursor(dir)      [cursor mode] ★
│   └── dispatch(action)
│       ├── .moveCursor → update copyCursor, scroll viewport if needed,
│       │                 ghostty_surface_set_selection_range(cursor, cursor, false)
│       ├── .startSelection → set copyVisualAnchor = copyCursor, copyVisualActive = true,
│       │                    ghostty_surface_set_selection_range(anchor, cursor, false)
│       └── .adjustSelection → performBindingAction("adjust_selection:dir")
└── ghostty_surface_set_selection_range(          ★ NEW Ghostty API
        surface, row1, col1, row2, col2, isRect
    )
```

---

## Summary

### What changed from the old plan

The previous plan (`docs/copy-mode-implementation-plan.md`) assessed copy mode as ~90% complete. The **invisible cursor** bug was not identified. This new analysis reveals that the copy mode architecture has a **fundamental semantic model mismatch**: it uses "scroll mode + optional visual selection" instead of "cursor mode + visual mode anchored to cursor."

### Recommended implementation order

1. **Ghostty fork** — add `ghostty_surface_set_selection_range` (one small API, prerequisite)
2. **Phase 1** — cursor state model + normal-mode motions (fixes invisible cursor, j/k/h/l behavior)
3. **Phase 2** — visual mode reconnection (fixes hidden visual mode start point)
4. **Phase 3** — additional motions (w/b/e, improved line motions)
5. **Phase 4** — visual block mode
6. **Phase 5** — selection color/overlay polish

### Key takeaway

The fix requires **both** a new Ghostty fork API (~15 lines of Zig) and a reworked cmux copy-mode state model (~200-300 lines of Swift). The implementation is well-scoped and the individual changes are small — the bulk is in getting the state model semantics right.
