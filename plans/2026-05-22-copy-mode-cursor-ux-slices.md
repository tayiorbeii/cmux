# Copy-Mode Cursor UX – Vertical Implementation Slices

> **Parent plan:** `plans/2026-05-22-copy-mode-cursor-ux-plan.md`  
> **Supersedes:** `docs/copy-mode-implementation-plan.md`

Each slice is self-contained: a single PR (or PR pair for fork changes) that delivers
observable user-visible improvement. Slices are ordered to build on each other.

---

## Table of Contents

- [Slice 0: Ghostty Fork API – `set_selection_range`](#slice-0-ghostty-fork-api)
- [Slice 1: Cursor State Model + Normal-Mode Motions](#slice-1-cursor-state-model--normal-mode-motions)
- [Slice 2: Visual Mode Reconnection](#slice-2-visual-mode-reconnection)
- [Slice 3: Additional Motions (w/b/e, 0/^/$, word boundaries)](#slice-3-additional-motions)
- [Slice 4: Visual Block Mode](#slice-4-visual-block-mode)
- [Slice 5: Selection Color & Overlay Enhancement](#slice-5-selection-color--overlay-enhancement)
- [Appendix: Full State Transition Diagram](#appendix-full-state-transition-diagram)

---

## Slice 0: Ghostty Fork API

### What this slice delivers

Adds `ghostty_surface_set_selection_range` to the C API — the single Ghostty fork
change needed by all subsequent slices. Without it, cmux cannot place the copy-mode
cursor or start a visual selection at an arbitrary buffer position.

### User-visible change

None directly. This is a prerequisite for every other slice.

### Files changed

| File | What changes |
|------|-------------|
| `ghostty/include/ghostty.h` | Add `GHOSTTY_API bool ghostty_surface_set_selection_range(...)` declaration after line ~1179 (after existing `ghostty_surface_select_cursor_cell`) |
| `ghostty/src/apprt/embedded.zig` | Add `export fn ghostty_surface_set_selection_range(...)` implementation after `ghostty_surface_clear_selection` (~line 1670) |
| `ghostty/src/Surface.zig` | No changes needed — `setSelection` and `Selection.init` are already public/internal |
| `.` (parent repo) | Update submodule pointer: `git add ghostty && git commit -m "ghostty: add set_selection_range C API for copy-mode cursor"` |
| `docs/ghostty-fork.md` | Add §12: "Copy-mode set_selection_range C API" with the commit hash and merge-conflict notes |

### Ghostty fork commit

One commit in `manaflow-ai/ghostty`, pushed to `main` BEFORE updating the parent submodule pointer:

```
ghostty: add ghostty_surface_set_selection_range C API

Exports a C function that sets a selection range from buffer (screen)
coordinates.  Used by cmux keyboard copy mode to place the copy-mode
cursor (1-cell selection) and to set visual-mode selections from an
arbitrary anchor point.
```

### New C API declaration (`ghostty/include/ghostty.h`)

Insert after line ~1179 (after `ghostty_surface_select_cursor_cell`):

```c
GHOSTTY_API bool ghostty_surface_set_selection_range(
    ghostty_surface_t,
    uint32_t row_start, uint32_t col_start,
    uint32_t row_end, uint32_t col_end,
    bool is_rectangular
);
```

### New export implementation (`ghostty/src/apprt/embedded.zig`)

Insert after `ghostty_surface_clear_selection` (~line 1670):

```zig
/// Set a selection range from buffer (screen) coordinates.
/// row/col are 0-indexed. If the range endpoint is outside the viewport,
/// Ghostty's existing selection rendering will auto-scroll (same as
/// adjust_selection).
export fn ghostty_surface_set_selection_range(
    surface: *Surface,
    row_start: u32, col_start: u32,
    row_end: u32, col_end: u32,
    is_rectangular: bool,
) bool {
    surface.core_surface.renderer_state.mutex.lock();
    defer surface.core_surface.renderer_state.mutex.unlock();

    const screen = &surface.core_surface.io.terminal.screens.active;
    const start_pin = screen.pages.pin(.{ .screen = .{ .x = col_start, .y = row_start } }) orelse return false;
    const end_pin   = screen.pages.pin(.{ .screen = .{ .x = col_end,   .y = row_end   } }) orelse return false;

    surface.core_surface.setSelection(
        terminal.Selection.init(start_pin, end_pin, is_rectangular)
    ) catch return false;

    screen.dirty.selection = true;
    surface.core_surface.queueRender() catch return false;
    return true;
}
```

### C ABI compatibility notes

- Uses `terminal.Selection`, `pin(.screen)`, `setSelection`, `queueRender` —
  all of which already exist in Ghostty and are used by the existing
  `ghostty_surface_select_cursor_cell`.
- `pin(.screen)` returns `null` if the screen row is beyond the scrollback
  buffer. Callers must handle `false` return.
- The existing `adjust_selection` binding (`Surface.zig:5893-5942`) performs
  auto-scroll on the first motion when the endpoint is outside the viewport.
  `set_selection_range` via `setSelection` marks the selection dirty but
  does NOT auto-scroll. The cmux side handles viewport-follow explicitly
  (Slice 1).

### Swift compat function

In `Sources/GhosttyTerminalView.swift`, add after the existing compat functions (~line 21):

```swift
@_silgen_name("ghostty_surface_set_selection_range")
private func ghostty_surface_set_selection_range_compat(
    _ surface: ghostty_surface_t,
    _ row_start: UInt32,
    _ col_start: UInt32,
    _ row_end: UInt32,
    _ col_end: UInt32,
    _ is_rectangular: Bool
) -> Bool
```

### Verification

1. **Compile check:** `./scripts/reload.sh --tag slice0-api` — the Debug app builds.
2. **Runtime smoke:** Launch the tagged app. Enter copy mode (⌘⇧M). The existing
   copy mode still works (no behavior change). Exit copy mode.
3. **Ghostty fork:** `cd ghostty && git merge-base --is-ancestor HEAD origin/main`
   must succeed before the parent commit.
4. **CI:** The existing E2E copy-mode tests still pass.

### Dependencies

None. This is the first slice.

---

## Slice 1: Cursor State Model + Normal-Mode Motions

### What this slice delivers

The **visible cursor** and **normal-mode cursor movement**. This fixes the two
core bugs:

1. **Cursor invisible after scrolling** — cursor is now placed at the correct
   screen position via `set_selection_range`, not the terminal's active cursor.
2. **j/k scroll instead of moving a cursor** — j/k now move the cursor, scrolling
   the viewport only when the cursor reaches the edge.

After this slice: pressing ⌘⇧M shows a blinking cursor at the terminal's active
position. Pressing j/k/h/l moves it. The viewport scrolls to follow.

### User-visible change

| Before | After |
|--------|-------|
| ⌘⇧M → no visible cursor (or cursor at wrong position) | ⌘⇧M → visible blinking cursor at terminal cursor position |
| j/k → viewport scrolls, no cursor movement | j/k → cursor moves, viewport scrolls when cursor hits edge |
| h/l → no visible effect in normal mode | h/l → cursor moves left/right within current line |
| y → copies current line and exits | y → still copies and exits (unchanged) |
| Escape → exits copy mode | Escape → exits copy mode (unchanged) |

### Files changed

| File | What changes |
|------|-------------|
| `Sources/GhosttyTerminalView.swift` | (1) New state struct: `CopyModeCursor`. (2) New state vars: `copyCursor`, `copyPreferredCol`, `copyViewportTopScreenRow`. (3) New actions: `moveCursor(direction, count)`. (4) Modified action dispatch: `.moveCursor` implementation. (5) Modified `setKeyboardCopyModeActive`: bootstrap cursor. (6) Modified key mapping: j/k/h/l → `.moveCursor` instead of `.scrollLines`/`nil`. (7) Modified `refreshKeyboardCopyModeViewportRowFromVisibleAnchor` → `placeCopyModeCursor`. (8) Removed: `keyboardCopyModeViewportRow` (folded into cursor). (9) New helper: `copyModeCellHeight`. (10) New helper: `scrollViewportIfCursorOutside`. |

### New Swift types

```swift
/// Copy-mode cursor position in screen (buffer) coordinates, plus a
/// viewport-relative row for scroll-boundary checks.
struct CopyModeCursor: Equatable {
    /// Screen (buffer) row, 0-indexed from the top of scrollback.
    var screenRow: Int
    /// Screen (buffer) column, 0-indexed.
    var screenCol: Int
    /// Viewport-relative row. 0 = top of visible viewport, rows-1 = bottom.
    /// Used for scroll-boundary checks (scroll-off margin).
    var viewportRow: Int
}
```

### New state variables (replace `keyboardCopyModeViewportRow`)

Add inside the `GhosttyTerminalView` class, replacing `private var keyboardCopyModeViewportRow: Int?`:

```swift
/// Copy-mode cursor. Non-nil only when `keyboardCopyModeActive` is true.
private var copyCursor: CopyModeCursor?

/// Preferred column for vertical motion (preserved across j/k).
private var copyPreferredCol: Int = 0

/// The screen row currently at the top of the viewport.
/// Updated on scroll events. Used to compute viewportRow from screenRow.
private var copyViewportTopScreenRow: Int = 0
```

The existing `keyboardCopyModeViewportRow: Int?` is **removed**. All call sites
that read it migrate to `copyCursor?.viewportRow`. The one call site that writes
it (`scrollToTop`/`scrollToBottom`) migrates to updating `copyViewportTopScreenRow`.

### Modified key mapping

In `terminalKeyboardCopyModeAction` (line ~1469), replace the normal-mode
branches for j/k/h/l to emit `.moveCursor` instead of `.scrollLines`/`nil`:

```swift
case 126: // Up
    return hasSelection ? .adjustSelection(.up) : .moveCursor(.up)
case 125: // Down
    return hasSelection ? .adjustSelection(.down) : .moveCursor(.down)
case 123: // Left
    return hasSelection ? .adjustSelection(.left) : .moveCursor(.left)
case 124: // Right
    return hasSelection ? .adjustSelection(.right) : .moveCursor(.right)
// ... similarly in the chars switch:
case "j":
    return hasSelection ? .adjustSelection(.down) : .moveCursor(.down)
case "k":
    return hasSelection ? .adjustSelection(.up) : .moveCursor(.up)
case "h":
    return hasSelection ? .adjustSelection(.left) : .moveCursor(.left)
case "l":
    return hasSelection ? .adjustSelection(.right) : .moveCursor(.right)
```

Page Up/Down and Home/End **keep** their scroll actions in normal mode (they
scroll large amounts to reposition the viewport):

```swift
case 116: // Page Up
    return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
case 121: // Page Down
    return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
case 115: // Home
    return hasSelection ? .adjustSelection(.home) : .scrollToTop
case 119: // End
    return hasSelection ? .adjustSelection(.end) : .scrollToBottom
```

### New `CopyModeAction` cases

Add to `TerminalKeyboardCopyModeAction` enum:

```swift
/// Direction for cursor movement in copy mode.
enum TerminalKeyboardCopyModeCursorDirection: Equatable {
    case up, down, left, right
}

// Add to TerminalKeyboardCopyModeAction:
case moveCursor(TerminalKeyboardCopyModeCursorDirection)
```

### New action dispatch: `.moveCursor`

In `handleKeyboardCopyModeIfNeeded`'s `switch action` block, add:

```swift
case let .moveCursor(direction):
    for _ in 0..<count {
        moveCopyModeCursor(surface: surface, direction: direction)
    }
```

### Core implementation: `moveCopyModeCursor`

```swift
private func moveCopyModeCursor(
    surface: ghostty_surface_t,
    direction: TerminalKeyboardCopyModeCursorDirection
) {
    guard var cursor = copyCursor else { return }
    let size = ghostty_surface_size(surface)
    let viewportRows = max(Int(size.rows), 1)
    let viewportCols = max(Int(size.columns), 1)
    
    switch direction {
    case .up:
        cursor.screenRow = max(0, cursor.screenRow - 1)
        cursor.viewportRow -= 1
    case .down:
        cursor.screenRow += 1  // no upper bound — scrollback can be large
        cursor.viewportRow += 1
    case .left:
        cursor.screenCol = max(0, cursor.screenCol - 1)
    case .right:
        cursor.screenCol = min(viewportCols - 1, cursor.screenCol + 1)
    }
    
    // Update preferred column for vertical-only motions.
    if direction == .up || direction == .down {
        copyPreferredCol = cursor.screenCol
    }
    
    copyCursor = cursor
    placeCopyModeCursor(surface: surface)
    
    // Scroll viewport if cursor left the visible area.
    scrollViewportIfCursorOutside(
        surface: surface,
        cursor: cursor,
        viewportRows: viewportRows
    )
}
```

### `placeCopyModeCursor` (replaces `refreshKeyboardCopyModeViewportRowFromVisibleAnchor`)

```swift
/// Place a 1-cell selection at the copy-mode cursor position.
/// Called after every cursor move, scroll, and copy-mode entry.
private func placeCopyModeCursor(surface: ghostty_surface_t) {
    guard let cursor = copyCursor else { return }
    let row = UInt32(cursor.screenRow)
    let col = UInt32(cursor.screenCol)
    _ = ghostty_surface_set_selection_range_compat(surface, row, col, row, col, false)
}
```

### `scrollViewportIfCursorOutside`

```swift
/// If the cursor's viewport row is outside the viewport bounds
/// (with a scroll-off margin of 3 rows), scroll the viewport to follow.
private let copyModeScrollOffMargin = 3

private func scrollViewportIfCursorOutside(
    surface: ghostty_surface_t,
    cursor: CopyModeCursor,
    viewportRows: Int
) {
    let margin = copyModeScrollOffMargin
    if cursor.viewportRow < margin {
        // Cursor above top margin — scroll up.
        let delta = cursor.viewportRow - margin  // negative
        _ = performBindingAction("scroll_page_lines:\(delta)")
        copyViewportTopScreenRow += delta
        // Recompute viewport row after scroll.
        copyCursor?.viewportRow = margin
    } else if cursor.viewportRow >= viewportRows - margin {
        // Cursor below bottom margin — scroll down.
        let delta = cursor.viewportRow - (viewportRows - margin - 1)  // positive
        _ = performBindingAction("scroll_page_lines:\(delta)")
        copyViewportTopScreenRow += delta
        copyCursor?.viewportRow = viewportRows - margin - 1
    }
}
```

### `setKeyboardCopyModeActive` – bootstrap cursor

Modify the activation branch to compute initial cursor position from the
terminal cursor anchor:

```swift
private func setKeyboardCopyModeActive(_ active: Bool) {
    keyboardCopyModeInputState.reset()
    keyboardCopyModeVisualActive = false
    keyboardCopyModeActive = active
    if active, let surface {
        // 1. Get terminal cursor position as an anchor point.
        //    (screenRow, pixelY) is a known screen↔pixel mapping.
        guard let anchor = keyboardCopyModeSelectionAnchor(surface: surface) else {
            // Fallback: cursor at viewport top-left.
            copyCursor = CopyModeCursor(screenRow: 0, screenCol: 0, viewportRow: 0)
            copyViewportTopScreenRow = 0
            copyPreferredCol = 0
            placeCopyModeCursor(surface: surface)
            terminalSurface?.setKeyboardCopyModeActive(active)
            return
        }
        
        // 2. Compute which viewport row the anchor occupies.
        let cellH = copyModeCellHeight(surface: surface)
        let viewportRowOfAnchor = cellH > 0
            ? Int(anchor.y / cellH)
            : 0
        
        // 3. Compute viewport-top screen row.
        copyViewportTopScreenRow = anchor.row - viewportRowOfAnchor
        
        // 4. Set cursor at the anchor's screen position.
        copyCursor = CopyModeCursor(
            screenRow: anchor.row,
            screenCol: 0,  // Column 0 — simple, predictable start
            viewportRow: viewportRowOfAnchor
        )
        copyPreferredCol = 0
        
        // 5. Place visible cursor.
        placeCopyModeCursor(surface: surface)
    } else {
        copyCursor = nil
        copyViewportTopScreenRow = 0
        copyPreferredCol = 0
    }
    terminalSurface?.setKeyboardCopyModeActive(active)
}
```

### `copyModeCellHeight` helper

```swift
/// Returns the height of a single terminal cell in points.
private func copyModeCellHeight(surface: ghostty_surface_t) -> Double {
    var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    return h > 0 ? h : {
        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        return max(bounds.height / Double(rows), 1)
    }()
}
```

### Scroll actions that need updating

The existing `.scrollLines`, `.scrollPage`, `.scrollHalfPage`,
`.scrollToTop`, `.scrollToBottom`, `.jumpToPrompt`, `.searchNext`, and
`.searchPrevious` actions must update `copyViewportTopScreenRow` and
recompute the cursor's viewportRow after scrolling.

Add a post-scroll helper:

```swift
/// Update cursor viewport tracking after a scroll operation.
/// Call after any action that moves the viewport.
private func refreshCopyCursorViewportRowAfterScroll(surface: ghostty_surface_t) {
    guard let cursor = copyCursor else { return }
    let viewportRows = max(Int(ghostty_surface_size(surface).rows), 1)
    let newViewportRow = cursor.screenRow - copyViewportTopScreenRow
    var updated = cursor
    updated.viewportRow = max(0, min(viewportRows - 1, newViewportRow))
    copyCursor = updated
}
```

Modify `.scrollLines` dispatch:

```swift
case let .scrollLines(delta):
    _ = performBindingAction("scroll_page_lines:\(delta * count)")
    copyViewportTopScreenRow += delta * count
    refreshCopyCursorViewportRowAfterScroll(surface: surface)
    placeCopyModeCursor(surface: surface)
```

Similarly update `.scrollPage`, `.scrollHalfPage`, `.jumpToPrompt`,
`.searchNext`, `.searchPrevious` to track `copyViewportTopScreenRow`.

For `.scrollToTop` and `.scrollToBottom`:

```swift
case .scrollToTop:
    _ = performBindingAction("scroll_to_top")
    copyViewportTopScreenRow = 0
    refreshCopyCursorViewportRowAfterScroll(surface: surface)
    placeCopyModeCursor(surface: surface)
case .scrollToBottom:
    _ = performBindingAction("scroll_to_bottom")
    // Viewport top is now at the last rows-worth of buffer.
    // We don't know the exact screen row, but the cursor's viewport row
    // is recomputed below.  As a rough approximation, set cursor to
    // bottom of viewport.
    let viewportRows = max(Int(ghostty_surface_size(surface).rows), 1)
    if var cursor = copyCursor {
        cursor.viewportRow = viewportRows - 1
        copyCursor = cursor
        placeCopyModeCursor(surface: surface)
    }
```

### `.copyLineAndExit` migration

`copyCurrentViewportLinesToClipboard` uses `keyboardCopyModeViewportRow` as a
viewport-relative row. Replace its call site:

```swift
case .copyLineAndExit:
    let startRow = copyCursor?.viewportRow ?? 0
    // ... rest unchanged
```

### State transitions for this slice

```
Copy mode inactive
    │
    │ ⌘⇧M
    ▼
Copy mode active (normal)
    │  copyCursor set from terminal cursor anchor
    │  1-cell selection placed via set_selection_range
    │  copyViewportTopScreenRow computed
    │
    ├─ j/k/h/l ──► move cursor, place selection, maybe scroll viewport
    ├─ Page/Home/End ──► scroll viewport, update viewport tracking
    ├─ y ──► copy line at cursor viewport row, exit (unchanged)
    ├─ v ──► Slice 2 (currently: still starts from hidden position)
    └─ Esc ──► clear selection, copyCursor = nil, exit
```

### Verification

1. **Build:** `./scripts/reload.sh --tag slice1-cursor`
2. **Manual verification:**
   - Open a terminal, run a command that produces 40+ lines of output (e.g., `ls -laR /usr/lib`).
   - Press ⌘⇧M. A **visible blinking cursor** appears at the prompt.
   - Press `j` — the cursor moves DOWN one row. The viewport does NOT scroll
     until the cursor reaches the bottom 3 rows.
   - Press `k` — the cursor moves UP. Scrolls when near top.
   - Press `h`/`l` — cursor moves left/right on the current line.
   - Press `Page Down` — viewport scrolls down a page, cursor stays visible.
   - Press `y` — copies the current line (cursor's row) and exits.
   - Press `Escape` — exits copy mode, cursor disappears.
   - Scroll up in the terminal, then enter copy mode — cursor appears at the
     **current viewport position**, not at the off-screen shell prompt.
3. **Edge cases:**
   - Very narrow terminal (1 column): l/r constrained properly.
   - Very tall terminal: j/k scroll boundaries work.
   - Empty terminal (just a prompt): cursor moves within viewport bounds.
   - Turbo mode: hold j — cursor races to bottom, viewport scrolls smoothly.
4. **Automated:** Existing CI E2E copy-mode tests still pass. New unit test for
   `CopyModeCursor` math and `scrollViewportIfCursorOutside` boundary logic
   (pure Swift, no app launch needed — see §10.1 of the parent plan).

### Dependencies

- **Slice 0** (Ghostty fork API) — required for `ghostty_surface_set_selection_range_compat`.

---

## Slice 2: Visual Mode Reconnection

### What this slice delivers

Fixes visual mode so selection starts from the **current copy-mode cursor**
instead of the off-screen terminal cursor. After this slice: pressing `v` in
copy mode starts a selection at the visible cursor position, and motions
extend the selection from that anchor.

### User-visible change

| Before | After |
|--------|-------|
| `v` → selection starts from hidden terminal cursor position | `v` → selection starts from visible copy-mode cursor position |
| First motion after `v` → jarring jump as viewport auto-scrolls to selection | First motion → smooth extension from visible anchor |
| Visual mode motions work but start wrong | Visual mode motions work from correct position |
| `o` → does nothing | `o` → swaps selection anchor to other end |
| `V` → does nothing (no line mode) | `V` → enters visual line mode, selects full lines |
| `v` in visual → does nothing/confusing | `v` in visual → returns to normal mode, cursor stays |

### Files changed

| File | What changes |
|------|-------------|
| `Sources/GhosttyTerminalView.swift` | (1) New state: `copyVisualAnchor: CopyModeCursor?`. (2) Modified `startSelection` handler: set anchor, place range selection. (3) Modified visual-mode motions: use `set_selection_range` instead of `adjust_selection` for initial range. (4) Modified `clearSelection` handler: return to normal-mode cursor. (5) New `o` handler: swap anchor. (6) New `V` handler: visual line mode. (7) Modified yank handler: read from Ghostty selection, not emulate a mouse selection. |

### New state variable

```swift
/// Visual mode anchor. Set when user presses `v`.
/// The selection spans from anchor to cursor.
private var copyVisualAnchor: CopyModeCursor?
```

### Modified `startSelection` handler

In the action dispatch switch, replace:

```swift
case .startSelection:
    keyboardCopyModeVisualActive = true
```

With:

```swift
case .startSelection:
    // Enter visual mode. Anchor at current cursor position.
    copyVisualAnchor = copyCursor
    keyboardCopyModeVisualActive = true
    // Set initial 1-cell selection at anchor position.
    guard let anchor = copyVisualAnchor else { break }
    let r = UInt32(anchor.screenRow), c = UInt32(anchor.screenCol)
    _ = ghostty_surface_set_selection_range_compat(surface, r, c, r, c, false)
```

### Modified visual-mode motion dispatch

When visual mode is active, `.moveCursor` actions should update the cursor
AND set the selection range from anchor to new cursor position.

Add a `setVisualSelection` helper:

```swift
/// Set the Ghostty selection range from anchor to current cursor.
private func setVisualSelection(surface: ghostty_surface_t) {
    guard keyboardCopyModeVisualActive,
          let anchor = copyVisualAnchor,
          let cursor = copyCursor else { return }
    
    // Determine which end is "start" (top-left) and which is "end" (bottom-right).
    let startRow = UInt32(min(anchor.screenRow, cursor.screenRow))
    let startCol = UInt32(min(anchor.screenCol, cursor.screenCol))
    let endRow   = UInt32(max(anchor.screenRow, cursor.screenRow))
    let endCol   = UInt32(max(anchor.screenCol, cursor.screenCol))
    
    _ = ghostty_surface_set_selection_range_compat(
        surface, startRow, startCol, endRow, endCol, false
    )
}
```

In the `.moveCursor` dispatch, add after updating copyCursor:

```swift
case let .moveCursor(direction):
    for _ in 0..<count {
        moveCopyModeCursor(surface: surface, direction: direction)
    }
    if keyboardCopyModeVisualActive {
        setVisualSelection(surface: surface)
    }
```

### Visual line mode (`V`)

Add a new action and key mapping:

```swift
// New action case:
case startLineSelection

// Key mapping (chars switch, alongside "v"):
case "V", "5":  // "5" when Shift is held
    guard chars == "V" || normalized == [.shift] else { return nil }
    return .startLineSelection
```

Handler:

```swift
case .startLineSelection:
    guard let cursor = copyCursor else { break }
    // Snap cursor to column 0 for full-line anchor.
    var lineAnchor = cursor
    lineAnchor.screenCol = 0
    copyVisualAnchor = lineAnchor
    keyboardCopyModeVisualActive = true
    // Set initial selection on the full line.
    let lineEnd = CopyModeCursor(
        screenRow: cursor.screenRow,
        screenCol: Int(ghostty_surface_size(surface).columns) - 1,
        viewportRow: cursor.viewportRow
    )
    // Set selection from col 0 to end of line.
    _ = ghostty_surface_set_selection_range_compat(
        surface,
        UInt32(lineAnchor.screenRow), 0,
        UInt32(lineEnd.screenRow), UInt32(lineEnd.screenCol),
        false
    )
    // Also set copyCursor to end of line so motions extend from there.
    copyCursor = lineEnd
```

### `o` — swap anchor

In copy mode, `o` swaps which end of the selection is the "active" end.
The selection range stays the same, but the cursor moves to the other end.

```swift
// In chars switch in terminalKeyboardCopyModeAction:
case "o":
    return .swapSelectionAnchor

// New action:
case swapSelectionAnchor

// Handler:
case .swapSelectionAnchor:
    guard keyboardCopyModeVisualActive,
          let anchor = copyVisualAnchor,
          let cursor = copyCursor else { break }
    // Swap: old cursor becomes new anchor, old anchor becomes new cursor.
    copyVisualAnchor = cursor
    copyCursor = anchor
    placeCopyModeCursor(surface: surface)
    setVisualSelection(surface: surface)
```

### `clearSelection` — return to normal mode

When user presses `v` while in visual mode, return to normal mode:

```swift
// In chars switch for "v":
case "v":
    if hasSelection {
        return .clearSelection
    } else {
        return .startSelection
    }

// Modified .clearSelection handler:
case .clearSelection:
    keyboardCopyModeVisualActive = false
    copyVisualAnchor = nil
    _ = ghostty_surface_clear_selection_compat(surface)
    // Re-place 1-cell cursor at current copy-cursor position.
    placeCopyModeCursor(surface: surface)
```

### Modified yank handler

The existing `.copyAndExit` handler calls `performBindingAction("copy_to_clipboard")`
which copies Ghostty's active selection. Since visual mode now sets the
selection via `set_selection_range`, this **already works**. No change needed.

However, ensure that selection is placed before yanking:

```swift
case .copyAndExit:
    if keyboardCopyModeVisualActive {
        // Ensure the full selection range is set before copying.
        setVisualSelection(surface: surface)
    }
    _ = performBindingAction("copy_to_clipboard")
    _ = ghostty_surface_clear_selection_compat(surface)
    setKeyboardCopyModeActive(false)
```

### `scrollViewportIfCursorOutside` in visual mode

When extending selection in visual mode, if the cursor moves outside the
viewport, we still need to scroll. Ghostty's selection rendering handles
off-screen endpoints visually, but the user needs to see their cursor.

Modify `moveCopyModeCursor` to call `scrollViewportIfCursorOutside` regardless
of visual mode. The only difference is that afterwards, `setVisualSelection`
re-establishes the full range.

### State transitions for this slice

```
Normal mode (copyCursor set, 1-cell selection visible)
    │
    ├─ v ──► Visual mode
    │         copyVisualAnchor = copyCursor
    │         initial 1-cell selection at anchor
    │         keyboardCopyModeVisualActive = true
    │         │
    │         ├─ j/k/h/l ──► move cursor, set selection range anchor→cursor
    │         ├─ o ──► swap anchor ↔ cursor
    │         ├─ V ──► visual line mode (snap to full lines)
    │         ├─ y ──► set selection, copy, exit
    │         └─ v ──► clearSelection → normal mode (cursor stays)
    │
    └─ V ──► Visual line mode
              copyVisualAnchor at col 0, line anchor
              cursor at end of line
              keyboardCopyModeVisualActive = true
              subsequent motions extend full-line ranges
```

### Verification

1. **Build:** `./scripts/reload.sh --tag slice2-visual`
2. **Manual verification:**
   - Open a terminal with multi-line output. Enter copy mode (⌘⇧M).
   - Press `j` a few times → cursor moves down.
   - Press `v` → selection starts from where the cursor was. Cursor position
     is the selection endpoint.
   - Press `j` → selection extends downward from anchor. **No jarring jump.**
   - Press `k` → selection shrinks upward.
   - Press `h`/`l` → selection extends left/right from anchor.
   - Press `o` → cursor jumps to the other end of selection. Anchor swaps.
   - Press `v` → returns to normal mode. Cursor stays at current position.
   - Press `V` → enters line mode. Full line selected.
   - Press `j` in line mode → extends downward line-by-line.
   - Press `y` → copies the selection and exits.
3. **Edge cases:**
   - Enter visual mode at viewport edge (top/bottom), extend past — viewport scrolls.
   - Swap anchor (`o`) multiple times — toggle works correctly in both directions.
   - Clear selection (`v` in visual) then re-enter visual — new anchor at new position.
4. **Automated:** CI test that verifies `v` + `j` + `y` produces the correct
   clipboard content from the correct starting position.

### Dependencies

- **Slice 0** (Ghostty fork API) — `set_selection_range` for range selection.
- **Slice 1** (Cursor state model) — `copyCursor` state, `moveCopyModeCursor`,
  `placeCopyModeCursor`, `scrollViewportIfCursorOutside`.

---

## Slice 3: Additional Motions (w/b/e, 0/^/$)

### What this slice delivers

Adds word-motion (`w`, `b`, `e`) and line-boundary (`0`, `^`, `$`) motions
in both normal and visual modes.

### User-visible change

| Key | Normal mode | Visual mode |
|-----|------------|-------------|
| `w` | Cursor to start of next word | Extend selection to start of next word |
| `b` | Cursor to start of previous word | Extend selection to start of previous word |
| `e` | Cursor to end of current/next word | Extend selection to end of current/next word |
| `0` | Cursor to column 0 | Extend selection to column 0 |
| `^` | Cursor to first non-whitespace character | Extend selection to first non-whitespace |
| `$` | Cursor to last column of line | Extend selection to last column of line |

After this slice, normal-mode navigation feels Vim-like: `w` jumps words,
`0` goes to line start, etc. Visual-mode motions extend selection with the
same semantics.

### Files changed

| File | What changes |
|------|-------------|
| `Sources/GhosttyTerminalView.swift` | (1) New helper: `readLineContent(surface:screenRow:)` to get text of a line. (2) New helper: `findNextWordStart`, `findPrevWordStart`, `findWordEnd` — pure Swift word-boundary logic. (3) New helper: `findFirstNonWhitespace` for `^`. (4) New cases in `TerminalKeyboardCopyModeCursorDirection`: `nextWordStart`, `prevWordStart`, `wordEnd`, `lineStart`, `firstNonWhitespace`, `lineEnd`. (5) Key mapping: `w`/`b`/`e`/`0`/`^`/`$` mapped to new directions. (6) Extended `moveCopyModeCursor` to handle word-motion directions. |

### Word-boundary logic (pure Swift, no Ghostty API needed)

Word boundaries are computed by reading the text of the current line via
the Ghostty text-reading API and parsing it in Swift.

```swift
/// Word character classification for copy-mode motions.
/// Matches Vim's `iskeyword`-style behavior: letters, digits, underscore
/// are "word" characters; everything else is a boundary.
private func isCopyModeWordChar(_ c: Character) -> Bool {
    return c.isLetter || c.isNumber || c == "_"
}

/// Find the start of the next word from a given column on a line.
/// Returns nil if no next word exists on this line.
private func findNextWordStart(in line: String, from col: Int) -> Int? {
    guard col < line.count else { return nil }
    let chars = Array(line)
    var i = col
    
    // Skip current word characters.
    if i < chars.count, isCopyModeWordChar(chars[i]) {
        while i < chars.count, isCopyModeWordChar(chars[i]) { i += 1 }
    }
    // Skip whitespace/non-word.
    while i < chars.count, !isCopyModeWordChar(chars[i]) { i += 1 }
    // Found start of next word.
    return i < chars.count ? i : nil
}

/// Find the start of the current or previous word from a given column.
private func findPrevWordStart(in line: String, from col: Int) -> Int {
    let chars = Array(line)
    var i = min(col, chars.count - 1)
    if i < 0 { return 0 }
    
    // Skip whitespace backwards.
    while i >= 0, !isCopyModeWordChar(chars[i]) { i -= 1 }
    // Skip word characters backwards.
    while i >= 0, isCopyModeWordChar(chars[i]) { i -= 1 }
    // i is now at the boundary before the word. Return i+1.
    return max(0, i + 1)
}

/// Find the end of the current or next word from a given column.
private func findWordEnd(in line: String, from col: Int) -> Int? {
    let chars = Array(line)
    guard col < chars.count else { return nil }
    var i = col
    
    // If on whitespace, skip to next word start.
    if !isCopyModeWordChar(chars[i]) {
        while i < chars.count, !isCopyModeWordChar(chars[i]) { i += 1 }
        guard i < chars.count else { return nil }
    }
    // i is now at a word character. Skip to end of word.
    while i < chars.count, isCopyModeWordChar(chars[i]) { i += 1 }
    return i - 1  // last character of the word
}

/// Find the first non-whitespace column on a line.
private func findFirstNonWhitespace(in line: String) -> Int {
    let chars = Array(line)
    for (i, c) in chars.enumerated() {
        if !c.isWhitespace { return i }
    }
    return 0
}
```

### Reading a line's content

```swift
/// Read the text content of a single screen row.
/// Uses the Ghostty selection API to read one row's worth of text.
private func readLineContent(surface: ghostty_surface_t, screenRow: Int) -> String? {
    let cols = Int(ghostty_surface_size(surface).columns)
    guard cols > 0 else { return nil }
    
    // Set a 1-row selection to read just this line.
    let r = UInt32(screenRow)
    _ = ghostty_surface_set_selection_range_compat(
        surface, r, 0, r, UInt32(cols - 1), false
    )
    
    var text = ghostty_text_s()
    defer { ghostty_surface_free_text(surface, &text) }
    guard ghostty_surface_read_selection(surface, &text) else {
        // Save/restore previous cursor selection? Not needed since
        // placeCopyModeCursor is called after.
        return nil
    }
    
    // Convert the text buffer to a String.
    guard let str = String(
        data: Data(bytes: text.data, count: Int(text.len)),
        encoding: .utf8
    ) else { return nil }
    
    // The text includes trailing whitespace from the full line.
    // Trim trailing newlines but keep the line content.
    return str.replacingOccurrences(of: "\n", with: "")
}
```

**Performance note:** `readLineContent` temporarily replaces the selection
to read a line. After computing the word boundary, `placeCopyModeCursor`
or `setVisualSelection` restores the correct selection. This is O(1) text
reads per motion — acceptable for keyboard-driven interactions. If
performance is a concern in the future, cache the line content or use a
dedicated "read buffer text at coordinates" API (not needed for Slice 3).

### Extended `moveCopyModeCursor`

Add word-motion handling:

```swift
private func moveCopyModeCursor(
    surface: ghostty_surface_t,
    direction: TerminalKeyboardCopyModeCursorDirection
) {
    guard var cursor = copyCursor else { return }
    let size = ghostty_surface_size(surface)
    let viewportRows = max(Int(size.rows), 1)
    let viewportCols = max(Int(size.columns), 1)
    
    switch direction {
    case .up, .down:
        // ... existing vertical logic, plus preferred column restore
        // When moving vertically, restore copyPreferredCol:
        if direction == .up || direction == .down {
            cursor.screenCol = copyPreferredCol
        }
        
    case .left:
        if cursor.screenCol > 0 {
            cursor.screenCol -= 1
        } else {
            // Wrap to end of previous line.
            cursor.screenRow = max(0, cursor.screenRow - 1)
            cursor.viewportRow -= 1
            cursor.screenCol = viewportCols - 1
        }
        
    case .right:
        if cursor.screenCol < viewportCols - 1 {
            cursor.screenCol += 1
        } else {
            // Wrap to start of next line.
            cursor.screenRow += 1
            cursor.viewportRow += 1
            cursor.screenCol = 0
        }
        
    case .nextWordStart:
        guard let line = readLineContent(surface: surface, screenRow: cursor.screenRow) else { break }
        if let next = findNextWordStart(in: line, from: cursor.screenCol) {
            cursor.screenCol = next
        } else {
            // No next word on this line — try next line.
            cursor.screenRow += 1
            cursor.viewportRow += 1
            cursor.screenCol = 0
            // Recurse to find word start on the new line.
            // (Guard against infinite recursion with a depth limit.)
        }
        
    case .prevWordStart:
        guard let line = readLineContent(surface: surface, screenRow: cursor.screenRow) else { break }
        let prev = findPrevWordStart(in: line, from: cursor.screenCol)
        if prev < cursor.screenCol {
            cursor.screenCol = prev
        } else {
            // Already at first word — try previous line end.
            if cursor.screenRow > 0 {
                cursor.screenRow -= 1
                cursor.viewportRow -= 1
                cursor.screenCol = viewportCols - 1
                // Recurse to find word on the new line.
            }
        }
        
    case .wordEnd:
        guard let line = readLineContent(surface: surface, screenRow: cursor.screenRow) else { break }
        if let end = findWordEnd(in: line, from: cursor.screenCol) {
            cursor.screenCol = end
        }
        
    case .firstNonWhitespace:
        guard let line = readLineContent(surface: surface, screenRow: cursor.screenRow) else { break }
        cursor.screenCol = findFirstNonWhitespace(in: line)
        
    case .lineStart:
        cursor.screenCol = 0
        
    case .lineEnd:
        cursor.screenCol = viewportCols - 1
    }
    
    if direction == .up || direction == .down {
        copyPreferredCol = cursor.screenCol
    }
    
    copyCursor = cursor
    placeCopyModeCursor(surface: surface)
    scrollViewportIfCursorOutside(surface: surface, cursor: cursor, viewportRows: viewportRows)
}
```

### Key mapping additions

In `terminalKeyboardCopyModeAction`, add to the chars switch:

```swift
case "w":
    return hasSelection ? .adjustSelection(.right) : .moveCursor(.nextWordStart)
    // Note: for visual mode w/b/e, we currently don't have Ghostty-level
    // word motions. Fall back to basic single-step motions for visual mode
    // in this slice. Full visual word-motion can be added in a future slice
    // by implementing word-boundary selection in Swift and calling
    // set_selection_range after each word step.
case "b":
    return hasSelection ? .adjustSelection(.left) : .moveCursor(.prevWordStart)
case "e":
    return hasSelection ? .adjustSelection(.right) : .moveCursor(.wordEnd)
case "0":
    return hasSelection ? .adjustSelection(.beginningOfLine) : .moveCursor(.lineStart)
case "^":
    return hasSelection ? .adjustSelection(.beginningOfLine) : .moveCursor(.firstNonWhitespace)
case "$", "4":
    guard chars == "$" || normalized == [.shift] else { return nil }
    return hasSelection ? .adjustSelection(.endOfLine) : .moveCursor(.lineEnd)
```

**Design decision for visual mode w/b/e:** In this slice, visual-mode
w/b/e use the existing `adjust_selection` Ghostty binding with the basic
single-step directions (right/left). This provides incremental word-like
movement but not true word-boundary jumps. Full visual-mode word motions
require implementing word-boundary-aware selection extension in Swift
and calling `set_selection_range` — deferred to a future slice.

### Verification

1. **Build:** `./scripts/reload.sh --tag slice3-motions`
2. **Manual verification:**
   - Enter copy mode in a terminal with text output.
   - `w` → jumps to start of next word. Repeated `w` skips through words.
   - `b` → jumps back to start of previous word.
   - `e` → jumps to end of current/next word.
   - `0` → goes to column 0.
   - `^` → goes to first non-whitespace character on the line.
   - `$` → goes to last column on the line.
   - In visual mode, `w`/`b`/`e` extend selection one cell at a time.
   - `3w` → jumps forward 3 words.
   - `5j` → moves cursor down 5 rows.
3. **Edge cases:**
   - Line with only whitespace: `^` goes to col 0.
   - Line longer than viewport: `$` goes to viewport-col-1 (end of visible line).
   - Word at end of line: `w` wraps to next line.
   - Word at start of line: `b` wraps to previous line.

### Dependencies

- **Slice 0** (Ghostty fork API).
- **Slice 1** (Cursor state model, `moveCopyModeCursor`, `placeCopyModeCursor`).
- **Slice 2** (Visual mode reconnection) — for visual-mode motion integration.

---

## Slice 4: Visual Block Mode

### What this slice delivers

Adds `Ctrl-v` to enter visual block (rectangle) mode. Selection is a rectangular
block between anchor and cursor. Yank copies the block content.

### User-visible change

| Before | After |
|--------|-------|
| `Ctrl-v` → does nothing | `Ctrl-v` → enters visual block mode |
| No rectangle selection | Rectangle selection from anchor to cursor |
| Yank in block mode → undefined | Yank → copies rectangular block of text |

### Files changed

| File | What changes |
|------|-------------|
| `Sources/GhosttyTerminalView.swift` | (1) New state: `copyVisualBlockActive: Bool`. (2) New action: `startBlockSelection`. (3) Key mapping: `Ctrl-v` → `.startBlockSelection`. (4) Modified `setVisualSelection` → pass `is_rectangular: true` when block mode active. (5) Modified `clearSelection` → clear block flag. (6) Modified yank handler → block-aware copy. |

### New state variable

```swift
/// True when visual block mode is active (Ctrl-v).
private var copyVisualBlockActive = false
```

### Key mapping

In `terminalKeyboardCopyModeAction`, in the `normalized == [.control]` block
(or add a new Ctrl-v check):

```swift
// Ctrl-v: codes vary. Check char first, then keyCode as fallback.
if chars == "\u{16}" {  // Ctrl-v produces SYN (0x16)
    return .startBlockSelection
}
```

### Action handler

```swift
case .startBlockSelection:
    guard let cursor = copyCursor else { break }
    copyVisualAnchor = cursor
    keyboardCopyModeVisualActive = true
    copyVisualBlockActive = true
    // Set initial 1-cell selection at anchor.
    let r = UInt32(cursor.screenRow), c = UInt32(cursor.screenCol)
    _ = ghostty_surface_set_selection_range_compat(surface, r, c, r, c, true)
```

### Modified `setVisualSelection`

```swift
private func setVisualSelection(surface: ghostty_surface_t) {
    guard keyboardCopyModeVisualActive,
          let anchor = copyVisualAnchor,
          let cursor = copyCursor else { return }
    
    let isRect = copyVisualBlockActive
    
    let startRow = UInt32(min(anchor.screenRow, cursor.screenRow))
    let startCol = UInt32(min(anchor.screenCol, cursor.screenCol))
    let endRow   = UInt32(max(anchor.screenRow, cursor.screenRow))
    let endCol   = UInt32(max(anchor.screenCol, cursor.screenCol))
    
    _ = ghostty_surface_set_selection_range_compat(
        surface, startRow, startCol, endRow, endCol, isRect
    )
}
```

### `clearSelection` update

```swift
case .clearSelection:
    keyboardCopyModeVisualActive = false
    copyVisualBlockActive = false
    copyVisualAnchor = nil
    _ = ghostty_surface_clear_selection_compat(surface)
    placeCopyModeCursor(surface: surface)
```

### Block yank behavior

Ghostty's `read_selection` already handles rectangular selections, so
no changes needed for the yank handler. The clipboard will contain
newline-separated lines, each trimmed to the block width.

### Verification

1. **Build:** `./scripts/reload.sh --tag slice4-block`
2. **Manual verification:**
   - Enter copy mode. Press `v` → regular visual mode. Press `Ctrl-v` instead → visual block mode.
   - Move cursor with j/k/h/l → rectangle selection grows.
   - Press `y` → copies block content to clipboard.
   - Press `o` in block mode → swaps anchor, preserves block mode.
   - Press `v` in block mode → returns to normal mode, clears block flag.
3. **Edge cases:**
   - 1-column block, 1-row block, block spanning 1 row.
   - Block extending past viewport → viewport scrolls.
   - Transition from block mode to regular visual mode and back.

### Dependencies

- **Slice 0** (Ghostty fork API — `is_rectangular` parameter).
- **Slice 1** (Cursor state model).
- **Slice 2** (Visual mode reconnection — reuses `setVisualSelection`).

---

## Slice 5: Selection Color & Overlay Enhancement

### What this slice delivers

Ensures the copy-mode cursor and selection are always **clearly visible**
regardless of the user's theme. Addresses the "low-contrast selection colors"
problem identified in the root cause analysis.

### User-visible change

| Before | After |
|--------|-------|
| Cursor/selection may be invisible on low-contrast themes | Cursor always visible with forced high-contrast colors |
| Selection uses theme's selection colors (could be subtle) | Selection uses high-contrast override in copy mode |
| No fallback if Ghostty rendering fails | Optional overlay cursor CALayer as fallback |

### Files changed

| File | What changes |
|------|-------------|
| `Sources/GhosttyTerminalView.swift` | (1) `setKeyboardCopyModeActive` → toggle high-contrast selection config. (2) `handleKeyboardCopyModeIfNeeded` → restore config on exit. (3) Optional: overlay cursor CALayer implementation. |
| `ghostty/src/config/Config.zig` | (Optional) If no existing config key provides sufficient contrast, add copy-mode-specific config overrides. (Prefer existing keys.) |

### Approach

**Primary: Config override.** Ghostty already has `selection-background` and
`selection-foreground` config keys. On copy-mode entry, temporarily override
these to high-contrast values (e.g., bright yellow on black). On exit, restore
the user's settings.

```swift
private func setKeyboardCopyModeActive(_ active: Bool) {
    // ... existing activation logic ...
    
    if active {
        // Force high-contrast selection colors for copy mode.
        // Use Ghostty's config load string API to apply a temporary override.
        let overrideConfig = """
        selection-background = #FFD700
        selection-foreground = #000000
        """
        // Apply via ghostty_surface_load_config_string if available,
        // or via a dedicated config-reload mechanism.
        applyCopyModeSelectionOverride()
    } else {
        restoreUserSelectionColors()
    }
}
```

**Fallback: Overlay cursor.** If Ghostty's selection rendering is still not
visible enough (e.g., on themes that override selection colors in ways that
can't be overridden), render a cmux-side overlay:

```swift
/// A CALayer drawn over the terminal surface at the cursor position.
private var copyModeOverlayCursor: CALayer?

private func showOverlayCursor(at cursor: CopyModeCursor, surface: ghostty_surface_t) {
    let layer = copyModeOverlayCursor ?? {
        let l = CALayer()
        l.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.6).cgColor
        l.cornerRadius = 2
        self.layer?.addSublayer(l)
        copyModeOverlayCursor = l
        return l
    }()
    
    // Position the overlay at the cursor's pixel position.
    let cellW = ... // compute from ghostty_surface_size.cell_width_px
    let cellH = ... // compute from ghostty_surface_size.cell_height_px
    let viewportY = cursor.viewportRow
    let viewportX = cursor.screenCol
    layer.frame = CGRect(
        x: CGFloat(viewportX) * cellW,
        y: CGFloat(viewportY) * cellH,
        width: cellW,
        height: cellH
    )
    layer.isHidden = false
}

private func hideOverlayCursor() {
    copyModeOverlayCursor?.isHidden = true
}
```

The overlay cursor is a **secondary enhancement** — the primary fix is the
selection color override. The overlay should only be enabled if a Debug
menu toggle or advanced config key explicitly requests it.

### Verification

1. **Build:** `./scripts/reload.sh --tag slice5-colors`
2. **Manual verification:**
   - Switch to a low-contrast theme (e.g., Solarized Light with subtle selection).
   - Enter copy mode → cursor is bright yellow on black, clearly visible.
   - Enter visual mode → selection range is bright yellow on black.
   - Exit copy mode → original theme colors restored.
   - Switch themes while in copy mode → colors stay high-contrast (or degrade gracefully).
3. **Edge cases:**
   - Dark themes, light themes, high-contrast accessibility themes.
   - Multiple surfaces open in splits — each surface's colors are independently managed.

### Dependencies

- **Slice 1** (Cursor state model for overlay positioning).
- **Slice 2** (Visual mode for selection rendering verification).

---

## Appendix: Full State Transition Diagram

```
                         ┌──────────────────────────┐
                         │   Copy mode INACTIVE      │
                         │   copyCursor = nil        │
                         │   no selection             │
                         └──────────┬───────────────┘
                                    │ ⌘⇧M
                                    ▼
                         ┌──────────────────────────┐
                         │   NORMAL MODE             │
                         │   copyCursor = (r,c,vr)   │
                         │   1-cell selection at     │
                         │     cursor position        │
                         │   copyViewportTopScreenRow│
                         │     = bootstrapped from   │
                         │     terminal cursor        │
                         └──┬───┬───┬───┬───┬──────┘
                            │   │   │   │   │
              ┌─────────────┘   │   │   │   └─────────────┐
              │                 │   │   │                 │
         j/k/h/l           v   V   C-v  y/yy           Esc
              │                 │   │   │                 │
              ▼                 ▼   ▼   ▼                 ▼
    ┌─────────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
    │ Cursor moves     │  │ VISUAL   │  │ Copy     │  │ INACTIVE │
    │ Viewport scrolls │  │ MODE     │  │ line(s)  │  │ (exit)   │
    │ if near edge     │  │          │  │ & exit   │  │          │
    │ Preferred col    │  │ anchor = │  └──────────┘  └──────────┘
    │ updated on j/k   │  │  cursor  │
    └─────────────────┘  │ range    │
                         │ selection│
                         └──┬───┬──┘
                            │   │
              ┌─────────────┘   └─────────────┐
              │                               │
        j/k/h/l/w/b/e                     o / v / y
              │                               │
              ▼                      ┌────────┴────────┐
    ┌─────────────────┐              │                   │
    │ Selection        │         o → swap           v → clear
    │ extends from     │         anchor↔cursor      Selection
    │ anchor to cursor │         (cursor moves)     → NORMAL MODE
    │ Viewport scrolls │                            │
    │ if near edge     │                        y → set selection
    └─────────────────┘                            → copy → INACTIVE

                    ┌──────────────────┐
                    │ VISUAL LINE MODE │
                    │ (V from normal)  │
                    │ anchor at col 0  │
                    │ cursor at EOL    │
                    │ full-line range  │
                    └──────────────────┘

                    ┌──────────────────┐
                    │ VISUAL BLOCK MODE│
                    │ (Ctrl-v)         │
                    │ anchor = cursor  │
                    │ rect selection   │
                    │ is_rect = true   │
                    └──────────────────┘
```
