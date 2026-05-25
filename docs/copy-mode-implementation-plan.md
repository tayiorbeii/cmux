# tmux-style Copy Mode — Implementation Plan

## Current State (What Already Exists)

**cmux already has a fully functional keyboard-driven copy mode.** This document was initially planned as a design from scratch, but source analysis reveals the feature is ~90% implemented.

### Already Implemented

| Component | File | Status |
|-----------|------|--------|
| **Copy mode state machine** | `GhosttyTerminalView.swift:1337-1383` | ✅ Full enum hierarchy: `TerminalKeyboardCopyModeAction`, `TerminalKeyboardCopyModeSelectionMove`, `TerminalKeyboardCopyModeInputState`, `TerminalKeyboardCopyModeResolution` |
| **Key resolver** | `GhosttyTerminalView.swift:1456-1643` | ✅ `terminalKeyboardCopyModeAction()` + `terminalKeyboardCopyModeResolve()` — vi-like keys (h/j/k/l, w/b/e, v, y, g/G, Ctrl-U/D, etc.), count prefix, pending operators (yy, gg) |
| **Activation** | `KeyboardShortcutSettings.swift:108,360-361` | ✅ `toggleTerminalCopyMode` action, default **⌘⇧M**, routed through `AppDelegate:11707` → `TabManager.toggleFocusedTerminalCopyMode()` → `GhosttyNSView.toggleKeyboardCopyMode()` |
| **Event interception** | `GhosttyTerminalView.swift:7278-7358` | ✅ `handleKeyboardCopyModeIfNeeded()` — early return in `keyDown`, swallows events when `keyboardCopyModeActive`, dispatches resolved actions |
| **Visual mode** | `GhosttyTerminalView.swift:6510,7305-7310` | ✅ `keyboardCopyModeVisualActive` flag, `v` toggles selection, Ghostty's `adjust_selection` binding for visual selection extension |
| **Line yank** | `GhosttyTerminalView.swift:1355,7234-7268` | ✅ `copyLineAndExit` action, `copyCurrentViewportLinesToClipboard()` — uses IME geometry to compute pixel-based selection range |
| **Scrollback navigation** | `GhosttyTerminalView.swift:7327-7342` | ✅ `scrollLines`, `scrollPage`, `scrollHalfPage`, `scrollToTop`, `scrollToBottom` via Ghostty binding actions |
| **Search integration** | `GhosttyTerminalView.swift:7348-7354` | ✅ `startSearch`, `searchNext`, `searchPrevious` via Ghostty binding actions |
| **Prompt jumping** | `GhosttyTerminalView.swift:7343-7346` | ✅ `jumpToPrompt` via Ghostty binding action |
| **Cursor indicator** | `GhosttyTerminalView.swift:7171-7173` | ✅ 1-cell selection at terminal cursor via `ghostty_surface_select_cursor_cell` |
| **Viewport row tracking** | `GhosttyTerminalView.swift:7187-7231` | ✅ `keyboardCopyModeViewportRow`, `refreshKeyboardCopyModeViewportRowFromVisibleAnchor()`, IME-based position computation |
| **Visual badge** | `GhosttyTerminalView.swift:10096-10435` | ✅ `keyboardCopyModeBadgeContainerView`, icon + label overlay, localized "vim" indicator |
| **Key table integration** | `GhosttyTerminalView.swift:8601-8620` | ✅ `updateKeyTable()` — Ghostty's `activate_key_table` / `deactivate_key_table` action support |
| **Key-up consumption** | `GhosttyTerminalView.swift:7921` | ✅ `keyboardCopyModeConsumedKeyUps` — prevents stale key-up events from leaking to PTY |
| **Bypass for shortcuts** | `GhosttyTerminalView.swift:1451-1453` | ✅ `terminalKeyboardCopyModeShouldBypassForShortcut()` — Command-modified keys escape copy mode |

### Ghostty C APIs Already Available

All defined in `ghostty/src/apprt/embedded.zig` and imported in `GhosttyTerminalView.swift`:

```swift
ghostty_surface_has_selection(surface) -> Bool          // line 1654
ghostty_surface_select_cursor_cell(surface) -> Bool     // line 1659 (cmux-specific)
ghostty_surface_clear_selection(surface) -> Bool        // line 1667 (cmux-specific)
ghostty_surface_read_selection(surface, &text) -> Bool  // line 1676
ghostty_surface_read_text(surface, sel, &text) -> Bool  // line 1696
```

### Ghostty Binding Actions Used by Copy Mode

These are Ghostty keybind actions triggered programmatically via `performBindingAction()`:

- `copy_to_clipboard` — copies current selection
- `scroll_page_lines:<n>` — scroll n lines
- `scroll_page_down` / `scroll_page_up`
- `scroll_page_fractional:<f>` — scroll by fraction (0.5 = half page)
- `scroll_to_top` / `scroll_to_bottom`
- `adjust_selection:<direction>` — extend selection (left/right/up/down/page_up/page_down/home/end)
- `jump_to_prompt:<delta>` — navigate between shell prompts
- `start_search` — open search overlay
- `navigate_search:next` / `navigate_search:previous`

---

## What's Missing (The Gap Analysis)

### Feature 1: Select + Enter to Copy

**Status: NOT IMPLEMENTED**

Currently, when text is selected in the terminal and the user presses Enter, the Enter key is forwarded to the PTY (shell). There is no intercept that copies the selection and clears it.

**What needs to be added:**
- A guard in `GhosttyNSView.keyDown()` (around line 7847) that checks for Enter (keyCode 36/76) + `ghostty_surface_has_selection()` + NOT in copy mode (copy mode handles its own Enter)
- If matched: read selection → write to clipboard → clear selection → swallow event
- Gated behind a config option in `cmux.json`

### Feature 2: Additional Vi-like Motions

**Status: PARTIALLY IMPLEMENTED**

The current key resolver (`terminalKeyboardCopyModeAction()`) covers:
- ✅ h/j/k/l — basic movement
- ✅ w/b — word navigation (via Ghostty `adjust_selection`)
- ✅ 0/$ — line start/end (via Ghostty `adjust_selection`)
- ✅ Ctrl-U/D — half page scroll
- ✅ Ctrl-B/F — full page scroll
- ✅ g/G — top/bottom
- ✅ v — visual char mode
- ✅ y/yy/Y — yank
- ✅ q/Escape — exit

Missing from the original plan (lower priority):
- ❌ `e` — end of word (currently maps to "scroll one line down" — may conflict)
- ❌ `V` — visual line mode (currently `v` is the only visual toggle)
- ❌ `Ctrl-V` — visual block mode
- ❌ `/` / `?` — search from copy mode (partially works via `startSearch`)
- ❌ `n` / `N` — next/previous search result (partially works via `searchNext`/`searchPrevious`)
- ❌ `f` / `F` — find character (not in Ghostty binding actions)

---

## Implementation Plan

### Phase 1: Select + Enter to Copy (Smallest Useful Increment)

**Scope:** Intercept Enter key when mouse selection exists, copy and clear.

**Files to modify:**

1. **`Sources/GhosttyTerminalView.swift`** — `GhosttyNSView.keyDown()` (~line 7870, after `handleKeyboardCopyModeIfNeeded` check)
   ```swift
   // After the copy-mode check, before the control-modified fast path:
   if cmuxSettings.copyOnEnterSelection {
       let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
       let plainReturn = (event.keyCode == 36 || event.keyCode == 76) &&
                         flags.subtracting([.numericPad, .function]).isEmpty
       if plainReturn && ghostty_surface_has_selection(surface) {
           var text = ghostty_text_s()
           if ghostty_surface_read_selection(surface, &text) {
               let str = String(cString: text.data)
               NSPasteboard.general.clearContents()
               NSPasteboard.general.setString(str, forType: .string)
           }
           _ = ghostty_surface_clear_selection_compat(surface)
           return  // swallow Enter
       }
   }
   ```

2. **Config surface** — Add `copyOnEnterSelection: Bool` setting:
   - Add to `Sources/CmuxSettingsFileStore+Template.swift` default template
   - Add UserDefaults key in settings
   - Default: `false` (opt-in, since it changes Enter behavior)

**Estimated scope:** ~30 lines of Swift + config wiring.

**Risk:** Low. The intercept is narrow (only plain Enter with active mouse selection) and happens after copy-mode check so it doesn't conflict.

### Phase 2: Visual Line Mode (`V`)

**Scope:** Add `visualLine` mode to copy mode.

**Files to modify:**

1. **`Sources/GhosttyTerminalView.swift`** — `terminalKeyboardCopyModeAction()`:
   - Add case for `chars == "v" && normalized == [.shift]` → `.startLineSelection`
   - Add `TerminalKeyboardCopyModeAction.startLineSelection` case
   - In `handleKeyboardCopyModeIfNeeded`, on `.startLineSelection`:
     - Set `keyboardCopyModeVisualActive = true`
     - Use `copyCurrentViewportLinesToClipboard` logic to select the current line
     - Extend selection on subsequent moves via line-based `adjust_selection`

2. **State tracking:** Add `keyboardCopyModeVisualLineActive: Bool` to differentiate char vs line visual mode.

**Estimated scope:** ~50 lines of Swift.

**Risk:** Medium. Requires understanding Ghostty's `adjust_selection:beginning_of_line`/`end_of_line` behavior.

### Phase 3: Visual Block Mode (`Ctrl-V`)

**Scope:** Rectangle/column selection.

**This requires a new Ghostty C API.** The current selection model is linear (start/end points). Block selection needs:
- `ghostty_surface_set_block_selection(surface, startRow, startCol, endRow, endCol)` 
- Or: expose Ghostty's internal `Selection.Rectangle` mode through the C API

**Ghostty submodule changes needed:**
1. **`ghostty/src/apprt/embedded.zig`** — New export:
   ```zig
   export fn ghostty_surface_set_selection(
       surface: *Surface,
       tl_row: usize, tl_col: usize,
       br_row: usize, br_col: usize,
       rectangle: bool,
   ) bool {
       // Construct terminal.Selection from coordinates
       // Set on surface's active screen
   }
   ```

2. **`ghostty/src/terminal/Selection.zig`** — The `Selection` struct already supports `.rectangle` mode. Need to add a constructor from row/col coordinates.

**Estimated scope:** ~80 lines Zig + ~40 lines Swift + testing.

**Risk:** Higher. Touches Ghostty internals. Must follow submodule workflow (commit to fork's `main`, update pointer).

### Phase 4: Enhanced Search from Copy Mode

**Scope:** `/` and `?` to start search from copy mode, `n`/`N` to navigate.

**Current state:** `startSearch` already works via Ghostty binding. `searchNext`/`searchPrevious` also work. The key resolver just needs to map:
- `/` → `.startSearch`
- `n` → `.searchNext`
- `N` → `.searchPrevious`

These are already partially handled. The gap is `/` (forward search) and `?` (backward search) — need to check if Ghostty's search supports directional start.

**Estimated scope:** ~10 lines of Swift (key mapping additions).

### Phase 5: Word-end Motion (`e`)

**Scope:** Add `e` as a motion in copy mode.

Currently `e` with Ctrl maps to "scroll one line down" (`Ctrl-E`). The lowercase `e` without modifiers is NOT mapped in `terminalKeyboardCopyModeAction()`.

**What's needed:**
- Map `e` → Ghostty binding action for "move to end of word" — check if Ghostty exposes this
- If not available as a binding, would need a new C API

**Estimated scope:** ~5 lines if binding exists, ~50 lines if C API needed.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    AppDelegate                           │
│  performKeyEquivalent()                                  │
│  ┌─────────────────────────────────────────────┐        │
│  │ ⌘⇧M → toggleTerminalCopyMode               │        │
│  │   → TabManager.toggleFocusedTerminalCopyMode()│       │
│  │     → GhosttyNSView.toggleKeyboardCopyMode() │       │
│  └─────────────────────────────────────────────┘        │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│                 GhosttyNSView.keyDown()                  │
│                                                          │
│  1. handleKeyboardCopyModeIfNeeded()  ← copy mode active│
│     ├─ terminalKeyboardCopyModeResolve()                 │
│     │   ├─ count prefix (digits)                         │
│     │   ├─ pending operators (y, g)                      │
│     │   └─ terminalKeyboardCopyModeAction()              │
│     │       maps keys → TerminalKeyboardCopyModeAction   │
│     └─ dispatch action:                                  │
│         ├─ .exit → clear selection, deactivate           │
│         ├─ .startSelection → visual mode on              │
│         ├─ .clearSelection → visual mode off             │
│         ├─ .copyAndExit → copy_to_clipboard + exit       │
│         ├─ .copyLineAndExit → read lines + copy + exit   │
│         ├─ .scrollLines(n) → scroll_page_lines           │
│         ├─ .scrollPage(n) → scroll_page_down/up          │
│         ├─ .scrollHalfPage(n) → scroll_page_fractional   │
│         ├─ .scrollToTop/Bottom → scroll_to_top/bottom    │
│         ├─ .jumpToPrompt(n) → jump_to_prompt             │
│         ├─ .startSearch → start_search                   │
│         ├─ .searchNext/Previous → navigate_search        │
│         └─ .adjustSelection(dir) → adjust_selection      │
│                                                          │
│  2. [NEW] Enter-to-copy intercept ← mouse selection     │
│     if copyOnEnterSelection && Enter && has_selection    │
│     → read selection → NSPasteboard → clear → swallow   │
│                                                          │
│  3. Normal key processing (control fast path, IME, etc.) │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│              Ghostty C API (embedded.zig)                 │
│                                                          │
│  ghostty_surface_has_selection()                          │
│  ghostty_surface_read_selection()                         │
│  ghostty_surface_clear_selection()    ← cmux-specific    │
│  ghostty_surface_select_cursor_cell() ← cmux-specific    │
│  ghostty_surface_read_text(sel)                           │
│  [NEW] ghostty_surface_set_selection(r1,c1,r2,c2,rect)   │
└─────────────────────────────────────────────────────────┘
```

---

## Config Surface Design

### cmux.json Additions

```jsonc
{
  // Phase 1: Enter-to-copy
  "copyOnEnterSelection": false,  // opt-in, default off

  // Existing (already in shortcuts.bindings):
  // "toggleTerminalCopyMode": "Cmd+Shift+M"
}
```

### Interaction with Ghostty's `copy-on-select`

- Ghostty's `copy-on-select` (default `true` on macOS) auto-copies mouse selections to clipboard
- `copyOnEnterSelection` adds Enter-triggered explicit copy (useful when `copy-on-select` is `false`)
- These are independent settings — both can be active simultaneously
- When `copy-on-select` is `true`, the Enter-to-copy is redundant but harmless (re-copies already-copied text)

---

## File-by-File Change List

### Phase 1: Select + Enter to Copy

| File | Change |
|------|--------|
| `Sources/GhosttyTerminalView.swift` | Add Enter intercept in `keyDown()` after copy-mode check (~5 lines). Add config read. |
| `Sources/CmuxSettingsFileStore+Template.swift` | Add `copyOnEnterSelection` to default template JSON |
| `Sources/KeyboardShortcutSettings.swift` or settings store | Add `copyOnEnterSelection` UserDefaults key |

### Phase 2: Visual Line Mode

| File | Change |
|------|--------|
| `Sources/GhosttyTerminalView.swift` | Add `startLineSelection` case to `TerminalKeyboardCopyModeAction`. Map `V` (shift+v) in `terminalKeyboardCopyModeAction()`. Handle line selection in `handleKeyboardCopyModeIfNeeded()`. |

### Phase 3: Visual Block Mode

| File | Change |
|------|--------|
| `ghostty/src/apprt/embedded.zig` | Add `ghostty_surface_set_selection()` export |
| `ghostty/src/terminal/Selection.zig` | Add constructor from row/col coordinates (if not already available) |
| `Sources/GhosttyTerminalView.swift` | Add `startBlockSelection` case. Map `Ctrl-V`. Use new C API for rectangle selection. |

### Phase 4: Search Enhancements

| File | Change |
|------|--------|
| `Sources/GhosttyTerminalView.swift` | Add `/`, `?`, `n`, `N` mappings in `terminalKeyboardCopyModeAction()` |

### Phase 5: Word-end Motion

| File | Change |
|------|--------|
| `Sources/GhosttyTerminalView.swift` | Add `e` mapping (check if Ghostty has a "move to word end" binding action) |

---

## Ghostty Submodule Changes

### Needed for Phase 3 (Visual Block Mode) only

1. New export in `ghostty/src/apprt/embedded.zig`:
   ```zig
   export fn ghostty_surface_set_selection(
       surface: *Surface,
       start_row: usize,
       start_col: usize,
       end_row: usize,
       end_col: usize,
       rectangle: bool,
   ) bool { ... }
   ```

2. The internal `terminal.Selection` already supports:
   - `.bounds` with `.untracked` (start/end `Point`) or `.tracked` (screen/pin pairs)
   - `.rectangle: bool` for block selection
   - `Point` has row/col fields

3. **Workflow:**
   - Create branch in `ghostty` submodule
   - Implement + test in isolation
   - Push to `manaflow-ai/ghostty` fork's `main`
   - Update submodule pointer in parent repo
   - Follow AGENTS.md submodule safety rules

---

## Implementation Order with Dependencies

```
Phase 1: Enter-to-copy (standalone, no dependencies)
    ↓
Phase 4: Search keys (standalone, ~5 lines)
    ↓
Phase 2: Visual line mode (standalone, uses existing APIs)
    ↓
Phase 5: Word-end motion (may need Ghostty API check)
    ↓
Phase 3: Visual block mode (requires Ghostty submodule change)
```

Phases 1, 2, 4, 5 are independent and can be done in any order.
Phase 3 is the only one requiring Ghostty submodule changes.

---

## Testing Strategy

### CI-testable (via GitHub Actions)

- **Unit tests for key resolver:** Test `terminalKeyboardCopyModeAction()` and `terminalKeyboardCopyModeResolve()` with various key combinations, count prefixes, and pending operators. These are pure functions with no UI dependency.
- **Unit tests for state machine:** Test `TerminalKeyboardCopyModeInputState.reset()`, count prefix accumulation, pending operator transitions.

### Manual Verification Required

- **Enter-to-copy behavior:** Select text with mouse → press Enter → verify clipboard contents → verify selection cleared
- **Copy mode navigation:** ⌘⇧M → j/k/h/l → verify cursor moves in scrollback
- **Visual mode:** v → move → y → verify selection copied
- **Line yank:** yy → verify current line copied
- **Badge visibility:** Verify "vim" badge appears/disappears with copy mode
- **Shortcut bypass:** ⌘C while in copy mode → should still copy (Command bypasses copy mode)
- **No typing latency regression:** Type rapidly in terminal with copy mode inactive → no lag

### Regression Risk Areas (from AGENTS.md)

- `TerminalWindowPortal.hitTest()` — no changes to hit testing
- `TabItemView` — no changes to tab rendering
- `TerminalSurface.forceRefresh()` — no changes to refresh path
- Copy mode intercept is in `keyDown()` only, early-exits when inactive (`guard keyboardCopyModeActive`)

---

## Summary

**The tmux-style copy mode is already substantially implemented.** The keyboard-driven mode with vi-like navigation, visual selection, search, and scrollback browsing is working and wired to ⌘⇧M.

The main gaps are:
1. **Enter-to-copy on mouse selection** (Phase 1, ~30 lines) — the smallest useful increment
2. **Visual line/block modes** (Phases 2-3) — enhancement to existing visual mode
3. **Additional motions and search keys** (Phases 4-5) — minor key mapping additions

The recommended first PR is Phase 1 alone — it's self-contained, low-risk, and addresses the most common user expectation (select text → Enter to copy).
