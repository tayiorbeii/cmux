# Code Context

## Files Retrieved

- **Sources/TerminalNotificationStore.swift** — Core notification store (~2078 lines). Lines 1–80, 664–710, 724–758, 769–786, 821–910, 1078–1098, 1368–1428, 1700–1796, 1856–1865
- **Sources/TerminalNotificationQueue.swift** — `TerminalMutationBus` notification queue (~362 lines, full)
- **Sources/TerminalNotificationPolicy.swift** — Policy engine for notification evaluation (~925 lines, full)
- **Sources/TerminalNotificationCallerResolver.swift** — Caller resolution for notification routing (~331 lines, full)
- **Sources/NotificationsPage.swift** — SwiftUI notifications page (~269 lines, lines 1–50)
- **Sources/CmuxConfig.swift** — Config types, notification hooks definitions. Lines 146–278
- **Sources/Workspace.swift** — TmuxPaneMetadata, TmuxPaneRoute, SidebarStatusEntry, surfaceTTYNames, tmuxPaneRoutes. Lines 43–100, 7333–7334, 9285–9334
- **Sources/GhosttyTerminalView.swift** — Ghostty action callback handler, TerminalSurface, TerminalSurfaceRegistry. Lines 3657–3694, 3931–3953, 4305–4500, 10039–10067
- **Sources/WorkspaceContentView.swift** — TmuxPaneLayoutReport, TmuxWorkspacePaneOverlayRenderState, TmuxWorkspacePaneOverlayModel. Lines 56–130
- **Sources/TmuxWorkspacePaneOverlayView.swift** — SwiftUI overlay for tmux pane rings. Lines 1–50
- **Sources/Panels/Panel.swift** — WorkspaceAttentionFlashReason, WorkspaceAttentionCoordinator. Lines 68–157
- **Sources/CmuxEventPublishing.swift** — Event bus notification lifecycle events
- **Sources/TerminalController.swift** — Socket command handlers for notifications. Lines 2156–2174, 2649–2670, 7977–8316, 14486–14745
- **Sources/CmuxConfig.swift** — Notification hook definition types (CmuxNotificationHookDefinition, CmuxResolvedNotificationHook). Lines 146–277
- **CLI/CMUXCLI+TmuxCompatSupport.swift** — Tmux compat CLI support (~362 lines)
- **daemon/remote/cmd/cmuxd-remote/tmux_compat.go** — Go daemon-side tmux compat (~1802 lines)
- **plans/2026-05-14-tmux-integration.md** — Tmux integration plan (~306 lines)
- **docs/notifications.md** — Notification docs (~244 lines)

---

## Key Code

### 1. Notification System

#### Core Data Model: `TerminalNotification`
**File:** `Sources/TerminalNotificationStore.swift`, line 664

```swift
struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID           // Workspace/tab this notification belongs to
    let surfaceId: UUID?      // Specific surface/panel (nil = workspace-level)
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
    var paneFlash: Bool = true
}
```

#### Store: `TerminalNotificationStore`
**File:** `Sources/TerminalNotificationStore.swift`, line 677

- Singleton: `TerminalNotificationStore.shared` (line 691)
- `@Published private(set) var notifications: [TerminalNotification]` (line 701)
- Uses `UNUserNotificationCenter.current()` (line 724)
- Notification category: `com.cmuxterm.app.userNotification` (line 693)
- Action show identifier: `com.cmuxterm.app.userNotification.show` (line 694)
- Delivery handlers (lines 747–757):
  - `notificationDeliveryHandler` → `scheduleUserNotification(_:effects:)` (line 1700)
  - `suppressedNotificationFeedbackHandler` → `playSuppressedNotificationFeedback` (line 1769)
- `addNotification(tabId:surfaceId:title:subtitle:body:cooldownKey:cooldownInterval:)` (line 1078)
- `clearNotifications(forTabId:surfaceId:discardQueuedNotifications:)` (line 1597)
- `clearNotifications(forTabId:discardQueuedNotifications:)` (line 1664)
- `reportNotificationHookFailure(_:)` — shows hook failure alerts via UNNotification (line 1385)

#### Notification Queue: `TerminalMutationBus`
**File:** `Sources/TerminalNotificationQueue.swift`, line 33

- Singleton: `TerminalMutationBus.shared` (line 34)
- Off-main notification queue with coalescing
- Methods: `enqueueNotification`, `enqueueClearAllNotifications`, `enqueueClearNotifications(forTabId:)`
- Internal types: `QueuedTerminalNotification`, `TerminalSocketMutation`, `TerminalNotificationCoalescingKey`
- Drains mutations on main actor, max 16 per drain

#### Policy Engine: `TerminalNotificationPolicyEngine`
**File:** `Sources/TerminalNotificationPolicy.swift`, line 205

- Evaluates notifications against configured hooks
- `evaluate(request:hooks:)` → async returns `Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>`
- Envelope shape (line 180):
  ```swift
  struct TerminalNotificationPolicyEnvelope: Codable, Sendable, Equatable {
      var version: Int
      var notification: TerminalNotificationPolicyPayload  // title, subtitle, body
      var context: TerminalNotificationPolicyContext        // cwd, configPath, hookId, appFocused, focusedPanel
      var effects: TerminalNotificationPolicyEffects        // record, markUnread, reorderWorkspace, desktop, sound, command, paneFlash
      var stop: Bool?
  }
  ```
- Hook execution: `NotificationHookProcessRun` (line 396) — spawns `/bin/sh -c <command>` as subprocess
- Passes env vars: `CMUX_NOTIFICATION_TITLE`, `CMUX_NOTIFICATION_SUBTITLE`, `CMUX_NOTIFICATION_BODY`, `CMUX_NOTIFICATION_WORKSPACE_ID`, `CMUX_NOTIFICATION_SURFACE_ID`, `CMUX_NOTIFICATION_POLICY_JSON`
- Hooks receive JSON on stdin, return patch JSON on stdout

#### Caller Resolver: `TerminalController` extension
**File:** `Sources/TerminalNotificationCallerResolver.swift`, line 17

- `v2NotificationCreateForCaller(params:)` (line 18) — resolves target workspace/surface from TTY, tmux metadata, or preferences
- `v2StatusSetForCaller(params:)` (line 63) — sets sidebar metadata status entries
- Resolution priority: `preferredWorkspaceId` > TTY match > tmux pane route > selected fallback
- `TmuxPaneMetadata` parsed from params: `tmux_pane_id`, `tmux_pane_tty`, `tmux_session`, `tmux_window`, `tmux_pane`, `tmux_command`

#### Desktop Notification Delivery (UNUserNotificationCenter)
**File:** `Sources/TerminalNotificationStore.swift`, lines 1700–1759

- `scheduleUserNotification()` creates `UNMutableNotificationContent` with:
  - `title`, `subtitle`, `body`
  - `sound` (optional, based on effects)
  - `categoryIdentifier` = `com.cmuxterm.app.userNotification`
  - `userInfo`: `tabId`, `notificationId`, optional `surfaceId`
- Creates `UNNotificationRequest` with `identifier: notification.id.uuidString`
- Falls back to `playLocalNotificationFeedback` if authorization denied

#### Notifications Page (SwiftUI)
**File:** `Sources/NotificationsPage.swift`, line 4

- `NotificationsPage: View` — renders notification list in sidebar
- Uses `TerminalNotificationStore` via `@EnvironmentObject`
- Rows: `NotificationRow` (line 187)
- Actions: open (select tab/surface), clear (remove notification)

#### Event Bus: `CmuxEventBus`
**File:** `Sources/CmuxEventPublishing.swift`

- `publishNotificationLifecycle()` — publishes notification lifecycle events (created/removed/read)
- Events emitted via `CmuxSocketEventMapper`

#### In-App Visual Indicators
**File:** `Sources/Panels/Panel.swift`, lines 68–157

```swift
enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    case navigation
    case notificationArrival       // Blue ring flash
    case notificationDismiss       // Blue ring flash
    case manualUnreadDismiss       // Blue ring flash
    case debug                     // Blue ring flash
}
```

- `WorkspaceAttentionCoordinator.flashStyle(for:)` — maps reasons to blue/navigation accent
- `WorkspaceAttentionFlashPresentation` — defines glow opacity/radius
- Notification arrivals use `.notificationBlue` accent with 0.6 opacity, 6px glow radius
- Notification arrivals always allowed to flash (unlike navigation which checks for competing indicators)

#### Notification Hook Configuration
**File:** `Sources/CmuxConfig.swift`, lines 146–277

```swift
struct CmuxNotificationConfigDefinition: Codable, Sendable, Hashable {
    var hooks: [CmuxNotificationHookDefinition]?
    var hooksMode: CmuxNotificationHooksMode?  // .append or .replace
}

struct CmuxNotificationHookDefinition: Codable, Sendable, Hashable {
    var id: String
    var command: String
    var timeoutSeconds: TimeInterval?
    var enabled: Bool
}

struct CmuxResolvedNotificationHook: Sendable, Hashable {
    let id: String
    let command: String
    let timeoutSeconds: TimeInterval
    let sourcePath: String?
    let cwd: String
    let trustDescriptor: CmuxActionTrustDescriptor?
}
```

- Configured in `cmux.json` under `notifications.hooks`
- Hook resolution merges global + project-local hooks (modes: `.append` or `.replace`)
- Default timeout: 20 seconds
- Hook output limit: 1MB
- Hook authorization via `CmuxActionTrust` / project automation dialog

---

### 2. Tmux Integration

#### Tmux Metadata Model
**File:** `Sources/Workspace.swift`, lines 43–60

```swift
struct TmuxPaneMetadata: Equatable, Hashable {
    let paneId: String?
    let paneTTY: String?
    let session: String?
    let window: String?
    let pane: String?
    let command: String?
}

struct TmuxPaneRoute: Equatable {
    let metadata: TmuxPaneMetadata
    let surfaceId: UUID?
    let lastSeen: Date
}
```

#### Tmux Route Tracking on Workspace
**File:** `Sources/Workspace.swift`, lines 7333–7334, 9285–9334

- `surfaceTTYNames: [UUID: String]` — maps surface IDs to TTY names
- `tmuxPaneRoutes: [String: TmuxPaneRoute]` — maps route keys to surface routes
- `recordTmuxPaneRoute(metadata:surfaceId:now:)` — records/updates tmux pane → cmux surface routing (line 9313)
- `tmuxPaneRoute(metadata:now:)` — looks up surface from tmux metadata (line 9325)
- Route key generation from session+window+pane or paneId

#### Tmux Layout Report (for shell integration)
**File:** `Sources/WorkspaceContentView.swift`, lines 56–102

```swift
struct TmuxPaneLayoutPane: Codable, Equatable, Sendable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let isActive: Bool
}

struct TmuxPaneLayoutReport: Codable, Equatable, Sendable {
    let panes: [TmuxPaneLayoutPane]
}
```

- `tmuxActivePaneOverlayRect()` — computes overlay rect for a tmux pane within a surface (line 70)
- `TmuxWorkspacePaneOverlayModel` — ObservableObject managing unread rects and flash animations (line 105)

#### Tmux Pane Overlay View (Notification Rings)
**File:** `Sources/TmuxWorkspacePaneOverlayView.swift`, lines 1–50

- `TmuxWorkspacePaneOverlayView: View` — renders notification rings on tmux panes
- Takes `unreadRects: [CGRect]`, `flashRect: CGRect?`, flash timing
- Draws blue unread rings (`drawUnreadRing`) and flash animations per pane
- Uses `Canvas` + `TimelineView` for animation

#### Daemon-Side Tmux Compat (`cmux __tmux-compat`)
**File:** `daemon/remote/cmd/cmuxd-remote/tmux_compat.go` (~1802 lines)

- `runTmuxCompat()` — translates tmux commands to cmux JSON-RPC calls
- Key functions:
  - `tmuxNewSession`, `tmuxNewWindow`, `tmuxSplitWindow` — create/manage tmux windows → cmux workspace/surface
  - `tmuxSelectWindow`, `tmuxSelectPane` — focus navigation
  - `tmuxSendKeys`, `tmuxCapturePane` — I/O operations
  - `tmuxDisplayMessage` — display message handling
  - `tmuxListWindows`, `tmuxListPanes` — workspace/pane enumeration
  - `tmuxResolveWorkspaceTarget`, `tmuxResolvePaneTarget`, `tmuxResolveSurfaceTarget` — target resolution
  - `tmuxFormatContext()`, `tmuxRenderFormat()` — tmux format string rendering
  - `tmuxEnrichContextWithGeometry()` — pane geometry enrichment
- Communicates via cmux socket JSON-RPC (`rpcContext.call()`)

#### CLI Tmux Compat Support
**File:** `CLI/CMUXCLI+TmuxCompatSupport.swift` (~362 lines)

- `tmuxEnrichContextWithGeometry()` — populates tmux-style env vars (`pane_active`, `pane_width`, etc.)
- `tmuxShellQuote()`, `tmuxShellCommandBody()`, `tmuxShellCommandText()` — shell command formatting
- `TmuxCompatFocusedContext` — focused pane context struct (line 353)

#### Tmux Integration Plan
**File:** `plans/2026-05-14-tmux-integration.md` (~306 lines)

**Feature 1: Tmux-Aware Pane Navigation** — ALT+h/j/k/l for tmux-aware, LEADER+h/j/k/l for cmux bypass
**Feature 2: Tmux Alert → cmux Notification Bridge** — bridge tmux hooks (`alert-bell`, `alert-activity`, `alert-silence`) into cmux notification system. Already partially built:
- Tmux hooks configured in `.tmux.conf` using `cmux hooks feed`
- Notification pipeline: `TerminalNotificationStore` → `TerminalNotificationPolicyEngine` → effects
- TTY-based routing: `TerminalNotificationCallerResolver.targetForTTY()`
- Socket commands: `notification.create_for_caller` with `caller_tty`
- Unread ring overlays: `TmuxWorkspacePaneOverlayView`
- Tmux layout data: `TmuxPaneLayoutReport`

---

### 3. Terminal Session Abstraction

#### TerminalSurface
**File:** `Sources/GhosttyTerminalView.swift`, line 4385

```swift
final class TerminalSurface: Identifiable, ObservableObject {
    private(set) var surface: ghostty_surface_t?
    let id: UUID
    private(set) var tabId: UUID
    var hasLiveSurface: Bool { ... }
    // Search state, pending key events, socket input, etc.
}
```

- Wraps a Ghostty `ghostty_surface_t` C pointer
- Managed by `TerminalSurfaceRegistry` singleton (line 4305) — register/unregister/lookup
- Each surface corresponds to one terminal pane in a cmux split

#### Ghostty Action → Notification Flow
**File:** `Sources/GhosttyTerminalView.swift`, lines 3657–3694

1. Ghostty C library emits action: `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` (OSC 777 desktop-notification)
2. Swift handler extracts `title`/`body` from `action.action.desktop_notification`
3. If Claude hook session is active → suppresses raw OSC notification
4. Otherwise calls `TerminalNotificationStore.shared.addNotification(tabId:surfaceId:title:subtitle:body:)`

Also: `GHOSTTY_ACTION_RING_BELL` → `self.ringBell()` (line 3690)

#### Terminal Controller Notification Delivery
**File:** `Sources/TerminalController.swift`

- `deliverNotificationSynchronously(tabId:surfaceId:title:subtitle:body:)` — calls policy evaluation then store delivery
- Notification policy context built from current app focus state

---

### 4. Socket/CLI Notification Commands

#### V1 Commands (pipe-delimited)
**File:** `Sources/TerminalController.swift`

| Command | Line | Description |
|---------|------|-------------|
| `notify` | 2157 | `notifyCurrent(args)` — notify current tab |
| `notify_surface` | 2160 | `notifySurface(args)` — notify by surface ID/index |
| `notify_target` | 2163 | `notifyTarget(args)` — notify specific workspace+surface |
| `notify_target_async` | 2166 | `notifyTargetQueued(args)` — async queued notification |
| `list_notifications` | 2169 | `listNotifications()` — list all notifications |
| `clear_notifications` | 2172 | `clearNotifications(args)` — clear by tab |
| `focus_notification` | 2357 | `focusFromNotification(args)` — focus tab/surface from notification |

#### V2 Commands (JSON-RPC)
**File:** `Sources/TerminalController.swift`, lines 2649–2670

| Command | Line | Handler |
|---------|------|---------|
| `notification.create` | 2650 | `v2NotificationCreate(params:)` (line 7977) |
| `notification.create_for_caller` | 2652 | `v2NotificationCreateForCaller(params:)` (line 18, TerminalNotificationCallerResolver) |
| `notification.create_for_surface` | 2654 | `v2NotificationCreateForSurface(params:)` (line 8014) |
| `notification.create_for_target` | 2656 | `v2NotificationCreateForTarget(params:)` (line 8048) |
| `notification.list` | 2658 | `v2NotificationList()` (line 8085) |
| `notification.clear` | 2660 | `v2NotificationClear()` (line 8313) |
| `notification.dismiss` | 2662 | `v2NotificationDismiss(params:)` (line 8095) |
| `notification.mark_read` | 2664 | `v2NotificationMarkRead(params:)` (line 8151) |
| `notification.open` | 2666 | `v2NotificationOpen(params:)` (line 8227) |
| `notification.jump_to_unread` | 2668 | `v2NotificationJumpToUnread()` (line 8270) |
| `status.set_for_caller` / `set_status_for_caller` | 2670 | `v2StatusSetForCaller(params:)` (line 63, TerminalNotificationCallerResolver) |
| `debug.notification.focus` | 2919 | `v2DebugFocusNotification(params:)` |

#### CLI Commands
**File:** `docs/notifications.md`, `Sources/CmuxHelpResource.swift`

- `cmux notify --title <title> --body <body>` — CLI notification entry point
- `cmux notify --title <title> --subtitle <subtitle> --body <body> --tab <n> --panel <n>`
- `cmux hooks feed --source tmux-bridge --event bell` — tmux hook event feeder

---

## Architecture

### Notification Flow

```
[External Trigger] → [Socket/CLI Command] → [TerminalController handler]
                                                    ↓
                                        v2NotificationCreate* / notify*
                                                    ↓
                                     [TerminalNotificationCallerResolver]
                                          (resolve workspace/surface)
                                                    ↓
                                     [TerminalNotificationPolicyEngine]
                                          (evaluate notification hooks)
                                                    ↓
                                     [TerminalMutationBus.enqueueNotification]
                                          (queue for main thread delivery)
                                                    ↓
                                     [TerminalNotificationStore.addNotification]
                                                    ↓
                          ┌─────────────────────────┼─────────────────────────┐
                          ↓                         ↓                         ↓
                   [In-app store]           [UNUserNotificationCenter]  [Pane flash/ring]
                   (notifications[])        (desktop notification)      (Workspace flash)
                   (unread counts)          (dock badge)                (blue ring overlay)
                   (sidebar badge)          (sound)                     (workspace reorder)
```

### Tmux ↔ cmux Integration Architecture

```
[tmux process]
    │
    ├── Tmux hooks (.tmux.conf): alert-bell → `cmux hooks feed`
    ├── Tmux control mode: `cmux __tmux-compat <cmd> <args>` (via daemon)
    └── Shell integration: TmuxPaneLayoutReport (pane geometry)
                                                          ↓
[Cmux daemon-side Go: tmux_compat.go]
    └── JSON-RPC calls over cmux socket
                                                          ↓
[App-side Swift: TerminalNotificationCallerResolver]
    └── TTY matching → tmux metadata routing → TerminalNotificationStore
                                                          ↓
[TmuxWorkspacePaneOverlayView] — renders per-pane blue notification rings on the surface
```

### Terminal Output Flow (Ghostty → cmux)

```
[Child process shell] → [ghostty_surface_t (C)] → [Ghostty C action callback]
                                                          ↓
                                              [GhosttyTerminalView handler]
                                               (GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
                                                GHOSTTY_ACTION_RING_BELL)
                                                          ↓
                                              [TerminalNotificationStore.addNotification]
                                                          ↓
                                              [Notification delivery effects]
```

---

## Start Here

### File: `Sources/TerminalNotificationStore.swift`
/Users/taylor/Documents/Projects/03-tools/cmux/Sources/TerminalNotificationStore.swift

This is the central file for the entire notification system. It contains:
- `TerminalNotification` data model (line 664)
- `TerminalNotificationStore` class (line 677) — the single source of truth for all notifications
- `UNUserNotificationCenter` integration (line 724, 1700)
- `addNotification()` entry point (line 1078)
- `scheduleUserNotification()` → desktop notification delivery (line 1700)
- Notification lifecycle management (clear, mark read, dismiss)

Read this first to understand:
1. What a notification looks like (id, tabId, surfaceId, title, subtitle, body)
2. How notifications enter the system (`addNotification`)
3. How they get delivered (`scheduleUserNotification` → UNNotification)
4. How side effects work (workspace reorder, dock badge, pane flash, sound, custom commands)

Then read:
- **Sources/TerminalNotificationPolicy.swift** — to understand notification hook evaluation
- **Sources/TerminalNotificationCallerResolver.swift** — to understand TTY/tmux-based routing
- **Sources/TerminalNotificationQueue.swift** — to understand the async queue (TerminalMutationBus)
- **Sources/CmuxConfig.swift** lines 146–277 — to understand hook configuration
- **Sources/GhosttyTerminalView.swift** lines 3657–3694 — to see how Ghostty OSC notifications enter the system
- **daemon/remote/cmd/cmuxd-remote/tmux_compat.go** — for the daemon-side tmux translation layer
- **plans/2026-05-14-tmux-integration.md** — for the tmux bridge roadmap
