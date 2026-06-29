# Plan: cmux "Remote Handoff"

> Design doc for the Remote Handoff feature. All file:line references below
> were **empirically verified** against branch
> `integration/keyboard-accessibility-tmux-movement` on 2026-06-28. Line
> numbers in the originating prompt had drifted; the numbers here are current.

## Mission

Take the currently focused cmux pane, detect any running coding agent in it,
create a named tmux session rooted at that conversation's working directory,
resume (or fork) the conversation inside it, and print an
`ssh -t tmux attach` line so the conversation can be remoted into from
another machine.

## Key recon finding (confirmed)

cmux ALREADY has authoritative agent detection + resume/fork command building.
The feature is primarily **a shared runner + a CLI verb that wire existing
pieces together** — no new agent-detection logic, no pi extension for v1.

### Verified API surface

`Sources/RestorableAgentSession.swift` (1960 lines):

- `RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
    homeDirectory:fileManager:) async -> RestorableAgentSessionIndex` **:1053**
  — one-shot async loader (merges hook-store records + live process-detected
  snapshots). The sync sibling `...Synchronously` is at **:1065** but carries
  a "NEVER call on main actor / interactive paths" warning (:1047).
- `RestorableAgentSessionIndex.snapshot(workspaceId: UUID, panelId: UUID)
    -> SessionRestorableAgentSnapshot?` **:1013** — the single lookup entry
  point. `entry()` (:1011) falls back to an `entriesByPanelId[panelId]` map,
  so the panel UUID alone is sufficient.
- `struct SessionRestorableAgentSnapshot` **:762** — fields:
  - `kind: RestorableAgentKind` (:763), `sessionId: String` (:766),
    `workingDirectory: String?` (:767),
    `launchCommand: AgentLaunchCommandSnapshot?` (:768),
    `registration: CmuxVaultAgentRegistration?` (:769).
  - computed `resumeCommand: String?` **:771** (`pi --session <id>`),
    `forkCommand: String?` **:781** (`pi --fork <id>`),
    `agentDisplayName: String` (extension, computed).
  - **METHODS (not properties — they take injected fileManager/temp dir):**
    - `resumeStartupInput(fileManager:temporaryDirectory:allowLauncherScript:
        allowOversizedInlineInput:) -> String?` **~:805**
    - `forkStartupInput(fileManager:temporaryDirectory:allowLauncherScript:)
        -> String?` **~:830**
  - `maxInlineStartupInputBytes = 900` (:764). Inputs > 900 bytes are
    transparently rewritten as a self-deleting zsh launcher script via
    `AgentResumeScriptStore.writeLauncherScript(...)` **:887** and the
    returned input becomes `/bin/zsh '<script>'`. So the same string feeds a
    fresh tmux pane for both short and long commands.
- `private enum AgentResumeScriptStore` **:883** with
  `writeLauncherScript(command:kind:sessionId:fileManager:temporaryDirectory:...)`
  **:887**.

`Sources/RestorableAgentTypes.swift`:
- `enum RestorableAgentKind` **:3** — `.claude`, `.codex`, `.pi`, `.amp`,
  `.cursor`, `.gemini`, `.opencode`, `.rovodev`, `.hermesAgent`, `.copilot`,
  `.codebuddy`, `.factory`, `.qoder`, `.custom(String)`. Has `displayName`.
- `AgentLaunchCommandSnapshot` — has `workingDirectory: String?` (used at
  `RestorableAgentSession.swift:~840` as `launchCommand?.workingDirectory`).

`Sources/VaultAgentRegistry.swift` (467 lines):
- `struct CmuxVaultAgentRegistration` **:12** — `name`, `id`, `detect`,
  `sessionIdSource` (:17), `resumeCommand` (:18), `cwd`, `sessionDirectory`.
- `defaultExecutable` **:122**; `static var builtInPi` **:134**
  (`resumeCommand: "{{executable}} --session {{sessionId}}"` :141,
  `sessionDirectory: "~/.pi/agent/sessions"` :144).
- `CmuxVaultAgentDetectRule` **:190**; `CmuxVaultAgentSessionIDSource` **:245**;
  `CmuxVaultAgentRegistry.load` **:394**.

### UUID namespace fact (decisive)

`surface_id == panel_id`. `CLI/cmux.swift:5930` exports
`CMUX_PANEL_ID='__CMUX_SURFACE_ID__'` (same value), and
`Sources/CmuxTopSnapshotScopeCache.swift:106` reads the surface UUID from
`["CMUX_SURFACE_ID", "CMUX_PANEL_ID"]` interchangeably. Therefore the
`surface_id` returned by the `surface.current` socket method is directly
usable as the index `panelId`.

### Focused-pane resolution (CLI)

- `surface.current` socket method returns the focused surface with
  `surface_id`/`surface_ref`, `workspace_id`/`workspace_ref`,
  `window_id`/`window_ref` (see `CLI/cmux.swift` focused-context resolver
  ~:19380-19490; field reads at :19393-19394).
- `workspace.current` returns the focused `workspace_id`
  (`CLI/cmux.swift:16576`).
- CLI verb dispatch + handle resolution pattern (canonical "act on a pane"):
  `case "send":` **CLI/cmux.swift:4641** — uses `parseOption(:name:)`,
  `normalizeWindowHandle`, `normalizeWorkspaceHandle`,
  `normalizeSurfaceHandle`, then `client.sendV2(method:params:)`.

### Target / build wiring facts

- `CLI/cmux.swift` is compiled **into the `cmux` app target**
  (`project.pbxproj` Sources build phase :4641; PBXFileReference :1428). It
  can therefore call `Sources/` APIs directly — no socket round-trip needed
  for the core handoff logic.
- `Sources/` files are **explicitly listed** in `project.pbxproj`
  (objectVersion 60; no synchronized folder groups). Each new `Sources/*.swift`
  needs 4 pbxproj entries: PBXBuildFile, PBXFileReference, parent-group child,
  and the `cmux` target's PBXSourcesBuildPhase. Mirror `RestorableAgentSession.swift`
  (refs `A5001660` build / `A5001661` file). Then run
  `python3 scripts/normalize-pbxproj.py` + `./scripts/check-pbxproj.sh`.
- Subprocess spawning uses `Process()` directly (precedents:
  `Sources/App/CmuxCLIPathInstaller.swift:254`,
  `Sources/App/TerminalDirectoryOpenSupport.swift:390/:556`).
- Socket v2 method dispatch: `Sources/CmuxSocketEventMapper.swift:63+`.

## Design decisions

1. **Shared runner, not entrypoint-local logic.** One `RemoteHandoffRunner`
   (new file `Sources/RemoteHandoff.swift`) owns all handoff logic and is
   called by every entrypoint (CLI verb first; palette/shortcut/custom-command
   later). Target resolution (focused-panel lookup) is the only
   entrypoint-specific part — the handoff *logic* is single-path. Satisfies
   the shared-behavior rule from the start (collapses plan Steps 1+2).
2. **Fork is the safe default.** `mode: .fork` → `snapshot.forkStartupInput()`
   (branch session, original untouched). `--mode handoff` →
   `snapshot.resumeStartupInput()` (in-place resume). One-line toggle on
   already-built APIs.
3. **No new socket method for v1.** The CLI process loads the agent index
   itself (same FS + sysctl view as the app; panel UUIDs are stable) and runs
   tmux locally. Keeps v1 small. (A socket method is a clean future
   enhancement if a remote-only caller needs it.)
4. **Testability via injected seams.** `RemoteHandoffRunner` takes an
   `AgentSessionResolving` protocol (default: the real
   `RestorableAgentSessionIndex` loader) and a `TmuxSessionCreating` protocol
   (default: `TmuxSessionController` spawning real `tmux`). Tests inject fakes
   and assert argv + ssh line without tmux or a real agent.
5. **App-target file grouping.** New handoff types live in one new file
   `Sources/RemoteHandoff.swift` (runner + mode/result/error + tmux protocol),
   matching the existing app-target convention of grouping related types
   (`RestorableAgentSession.swift` holds 4 types). Minimizes pbxproj churn.
6. **Async core, sync CLI bridge.** `RemoteHandoffRunner.run()` is `async`
   (uses the async loader per the :1047 warning). The CLI verb bridges
   async→sync with a detached-Task + semaphore (acceptable for a one-shot CLI
   process with no UI). In-app entrypoints `await` it off-main.

## RemoteHandoff contract

```swift
enum RemoteHandoffMode: String { case fork, handoff }

struct RemoteHandoffRequest: Sendable {
    var workspaceId: UUID
    var panelId: UUID            // == focused surface_id
    var mode: RemoteHandoffMode  // default .fork
    var sessionName: String?     // override; else derived
    var sshHost: String?         // for the printed ssh line
}

struct RemoteHandoffResult: Sendable {
    var sessionName: String
    var workingDirectory: String
    var agentDisplayName: String
    var startupInput: String
    var sshCommand: String       // "ssh <host> -t tmux attach -t <name>"
}

enum RemoteHandoffError: Error, CustomStringConvertible {
    case noAgentDetected
    case startupInputUnavailable
    case tmuxNotFound
    case tmuxFailed(String)      // stderr from tmux
    case sessionNameInvalid(String)
}

// Seams
protocol AgentSessionResolving: Sendable {
    func loadIndex() async -> any RemoteHandoffIndexSnapshotting
}
protocol RemoteHandoffIndexSnapshotting: Sendable {
    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot?
}
protocol TmuxSessionCreating: Sendable {
    func createDetachedSession(name: String, workingDirectory: String) throws
    func sendKeys(target: String, input: String) throws
}

struct RemoteHandoffRunner: Sendable {
    var request: RemoteHandoffRequest
    var resolver: any AgentSessionResolving
    var tmux: any TmuxSessionCreating
    var fileManager: FileManager
    func run() async throws -> RemoteHandoffResult
}
```

### tmux invocation (concrete default `TmuxSessionController`)

- Resolve `tmux` on PATH (check `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`,
  then `which tmux` via `/usr/bin/env`); else throw `.tmuxNotFound`.
- `createDetachedSession`: `tmux new-session -d -s <name> -c <cwd>` via
  `Process` (no shell; argv passed literally).
- `sendKeys`: strip trailing newline from `startupInput`, then
  `tmux send-keys -t <name> <input> Enter`.

### Session-name derivation

Default `<agentID>-<first6(of sessionId)>` (e.g. `pi-a1b2c3`), sanitized to
tmux's rules (no `.` or `:`); `--name` overrides. Reject empty / invalid.

### Working directory

`snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory`
(else fall back to `NSHomeDirectory()`).

## CLI verb (`cmux handoff`) — vertical slice

Add `case "handoff":` to the dispatch (mirror `case "send":` at
`CLI/cmux.swift:4641`):

- Flags: `--mode fork|handoff` (default `fork`), `--name <tmux-session>`,
  `--host <ssh-host>`, `--workspace`, `--surface`/`--panel`, `--window`,
  `--no-copy`, `--json`.
- Resolve `(workspaceId, panelId)`:
  - Explicit `--workspace`/`--surface`/`--window` → `normalize*Handle`.
  - Else focused → `workspace.current` + `surface.current` socket;
    `focused["surface_id"]` is the panelId.
- Build `RemoteHandoffRequest`, `await RemoteHandoffRunner.run()` (via the
  CLI async bridge).
- On success: print human line + the `ssh <host> -t tmux attach -t <name>`
  command; copy to pasteboard via `pbcopy` unless `--no-copy`. `--json` →
  emit `RemoteHandoffResult` JSON.
- On `.noAgentDetected`: print a helpful localized message + exit non-zero.

## Build & dogfood (non-negotiable)

- `./scripts/reload.sh --tag remote-handoff --launch` (NEVER bare `xcodebuild`/
  `open`).
- Dogfood: `CMUX_TAG=remote-handoff scripts/cmux-debug-cli.sh handoff ...`
  (NEVER `/tmp/cmux-cli`).
- pbxproj: `python3 scripts/normalize-pbxproj.py && ./scripts/check-pbxproj.sh`.
- Tests wired into `project.pbxproj` (cmuxTests target); enforced by
  `scripts/lint-pbxproj-test-wiring.sh`.
- Localization: every user-facing string → `String(localized:)` + EN+JA in
  `Resources/Localizable.xcstrings`.

## Phases

1. **Phase 1 (vertical slice):** `Sources/RemoteHandoff.swift` + pbxproj wiring
   + `case "handoff":` CLI verb + normalization. Tagged green build + dogfood.
2. **Phase 2 (entrypoints):** palette entry + keyboard shortcut + custom-command
   action, all calling `RemoteHandoffRunner`. Shortcuts registered in
   `KeyboardShortcutSettings` + docs.
3. **Phase 3 (tests + l10n + polish):** `cmuxTests/RemoteHandoffRunnerTests.swift`
   (wired), EN+JA strings, docs changelog, regression two-commit structure.

## STATUS (2026-06-28)

### Done ✅
- **`Sources/RemoteHandoff.swift`** — the shared `RemoteHandoffRunner`
  action + `RemoteHandoffMode`/`Request`/`Result`/`Error` + `AgentSessionResolving`
  / `TmuxSessionCreating` seams + `VaultAgentSessionResolver` /
  `TmuxSessionController` defaults. Verified to compile in the `cmux` app
  target.
- **`cmuxTests/RemoteHandoffRunnerTests.swift`** — 10 Swift Testing tests
  covering fork/handoff mode, derived/custom session name + validation, cwd
  fallbacks, ssh-line host, no-agent and invalid-name error paths. **All 10
  pass** via `cmux-unit` scheme. Wired into `project.pbxproj`
  (`lint-pbxproj-test-wiring.sh` ok, 292 files).
- **`CLI/cmux.swift`** — `cmux handoff` verb (dispatch case + `runHandoff`
  helper + `copyToPasteboard` + `topLevelCommandNames` entry + `subcommandUsage`
  help). **Socket-only**: resolves the focused/target pane via `system.identify`
  and sends `remote-handoff.run`; prints/copies the ssh line. Compiles in BOTH
  the `cmux` app target and the standalone **`cmux-cli`** target (which cannot
  link `Sources/` — this is why the verb must be socket-only).
- **`Resources/Localizable.xcstrings`** — 7 `remote-handoff.*` keys, EN+JA
  (validated JSON).
- **`cmux.xcodeproj/project.pbxproj`** — `RemoteHandoff.swift` wired (4
  entries) + test wired (4 entries); `normalize-pbxproj.py` + `check-pbxproj.sh`
  + test-wiring lint all pass.
- **Green tagged build**: `./scripts/reload.sh --tag remote-handoff` succeeds
  (app + cmux-cli).

### DONE: `remote-handoff.run` socket handler ✅ (end-to-end validated)

The CLI verb is now **end-to-end functional**. Validated live against a tagged
Debug app: `cmux handoff` reaches the handler and returns a real
`no_agent_detected` error (with correct wire code + localized message) instead
of `method_not_found`. (The success path — snapshot → tmux → ssh line — is
covered by the 10/10 unit tests with injected fakes; live real-agent detection
depends on existing agent-index infra, not new code.)

Implementation note: the original plan assumed the `@MainActor`
`ControlCommandCoordinator` seam. That was wrong — the coordinator's own docs
state "worker-lane methods that block or await are NOT handled here; they stay
on the app-side worker path." `remote-handoff.run` blocks (tmux spawn) + awaits
(agent-index load), so it is wired on the **worker lane** instead:

- `Packages/macOS/CmuxControlSocket/.../Wire/ControlCommandExecutionPolicy.swift`
  — added `"remote-handoff.run"` to `socketWorkerMethods` so the dispatcher
  (`socketWorkerV2ResponseIfHandled`, gated by `runsOnSocketWorker`) routes it
  to the worker-lane switch instead of the main-actor switch.
- `Sources/TerminalController.swift` — added `case "remote-handoff.run"` to
  `socketWorkerV2Response` (the nonisolated worker switch; resolves UUIDs/
  `kind:N` refs on main via `v2MainSync`, then `v2AsyncResultCall` runs the
  async body off-main) + advertised it in `v2Capabilities()`.
- `Sources/TerminalController+RemoteHandoff.swift` (NEW) — the worker-lane
  handler `v2RemoteHandoffRun` (`nonisolated`) + `v2ResolveHandoffTargetID`.
  Builds a `RemoteHandoffRequest` from the socket params and runs the **shared
  `RemoteHandoffRunner.run()`** — the same action the CLI and the (future) UI
  entrypoints use. Maps `RemoteHandoffError.socketErrorCode` → wire error.
- `Sources/RemoteHandoff.swift` — added `RemoteHandoffError.socketErrorCode`
  (stable wire codes: `no_agent_detected`, `startup_input_unavailable`,
  `tmux_not_found`, `tmux_failed`, `invalid_session_name`).
- `Resources/Localizable.xcstrings` — added 2 EN+JA keys for the
  `invalid_params` (missing workspace_id/surface_id) messages.
- `CLI/cmux.swift` sends `workspace_id` + `surface_id` (UUID or `kind:N` ref,
  resolved from `system.identify` when no explicit target) + `mode` +
  `session_name?` + `ssh_host?`; `sendV2` surfaces a thrown `.err` as a
  readable `CLIError`.

### DONE: Command Palette entrypoint ✅ (verified green)

The **palette** half of the requirement is wired through the one shared action.
Tagged build is green and all 10 `RemoteHandoffRunnerTests` still pass.

- `Sources/RemoteHandoffInApp.swift` (NEW) — the single in-app entrypoint
  `@MainActor RemoteHandoffInApp.perform(tabManager:mode:sessionName:sshHost:)`.
  Resolves the focused pane from `tabManager.selectedWorkspace?.focusedPanelId`,
  builds a `RemoteHandoffRequest`, and runs the **shared `RemoteHandoffRunner`**
  off the main actor (`Task.detached`, since `run()` spawns tmux + awaits the
  restorable-agent index). On success it copies the `ssh … tmux attach` line to
  the pasteboard and shows a confirmation `NSAlert`; on failure a warning alert
  with the `RemoteHandoffError` description. A Sendable `RemoteHandoffFailure`
  error box keeps the crossed-actor `Result` Sendable.
- `Sources/ContentView+ViewCommandPalette.swift` (EDIT) — added a
  `palette.remoteHandoff` contribution (title/subtitle/keywords) + a handler in
  the already-aggregated `registerViewCommandHandlers(_:)`. The handler kicks
  off `Task { @MainActor in await RemoteHandoffInApp.perform(tabManager:) }`.
  (Extended the existing aggregated file rather than adding a new aggregated
  file, so no aggregator-discovery risk — the `triggerFlash`/`openTaskManager`
  entries prove this file is wired into the palette.)
- `Resources/Localizable.xcstrings` — 7 EN+JA keys (`command.remoteHandoff.title`,
  `command.remoteHandoff.subtitle`, `remote-handoff.error.no-focused-pane`,
  `remote-handoff.error.title`, `remote-handoff.success.title`,
  `remote-handoff.success.copied`, `remote-handoff.common.ok`).
- `cmux.xcodeproj/project.pbxproj` — wired `RemoteHandoffInApp.swift`
  (IDs `BEEF00000000000000000001/2`); normalize + check + test-wiring all pass.

The palette handler, the CLI verb, and the socket handler all funnel into the
same `RemoteHandoffRunner` action — identical behavior across surfaces.

### DONE: Keyboard shortcut entrypoint ✅ (verified green)

Correction to the earlier note: in-app shortcuts ARE bound centrally via SwiftUI
menu `Button`s carrying `.keyboardShortcut(menuShortcut(for: .action))` in
`Sources/cmuxApp.swift` `windowAndViewCommands` — the menu infrastructure routes
a bound key event to the button action. No per-surface NSEvent matcher needed.

- `Sources/KeyboardShortcutSettings.swift` (EDIT) — added `case remoteHandoff` to
  the `Action: String, CaseIterable` enum (after `.triggerFlash`), a `label` case
  (`shortcut.remoteHandoff.label`), and `defaultShortcut = .unbound` (mirrors
  `.sendFeedback`). All other exhaustive `switch self` sites had `default:`
  clauses, so no further cases were required (compiler-verified green).
- `Sources/cmuxApp.swift` (EDIT) — added a `splitCommandButton` in
  `CommandGroup(after: .windowArrangement)` (after Task Manager) bound via
  `menuShortcut(for: .remoteHandoff)`; action fires
  `Task { @MainActor in await RemoteHandoffInApp.perform(tabManager: activeTabManager) }`.
  Default `.unbound` → menu-only until the user binds a shortcut in Settings.
- `Resources/Localizable.xcstrings` — `shortcut.remoteHandoff.label` +
  `menu.window.remoteHandoff`, both EN+JA.

### DONE: Custom-command (built-in verb) entrypoint ✅ (verified green)

A user can now trigger Remote Handoff from `~/.config/cmux/cmux.json`:
```json
"actions": { "handoff": { "builtin": "remoteHandoff", "palette": true } }
```
- `Sources/CmuxSurfaceTabBarBuiltInAction.swift` (EDIT) — added
  `case remoteHandoff = "cmux.remoteHandoff"` + `init?(configID:)` aliases
  (`"cmux.remoteHandoff"`, `"remoteHandoff"`) + `defaultIcon`
  (`"arrow.up.right.square"`) + `bonsplitAction` (nil → custom handling).
- `Sources/CmuxConfig.swift` (EDIT) — title/keywords in the
  `CmuxResolvedConfigAction.builtIn(_:)` factory switch (reuses existing
  `command.remoteHandoff.title` key).
- `Sources/AppDelegate.swift` (EDIT) — `case .remoteHandoff` in
  `executeConfiguredCmuxAction`'s inner `switch builtIn` →
  `RemoteHandoffInApp.perform(tabManager: context.tabManager)`.
- `Sources/Workspace.swift` (EDIT) — `case .remoteHandoff` in the surface tab-bar
  button switch (`executeSurfaceTabBarCommandButton`) so a surface tab-bar button
  using the built-in also works.

All four exhaustive switches over `CmuxSurfaceTabBarBuiltInAction` are satisfied
(compiler-verified). All three entrypoints funnel into the one shared
`RemoteHandoffInApp.perform(...) → RemoteHandoffRunner` action.

## Contamination / hygiene

- `context.md` (repo root) deleted at session start — autoresearch scratch,
  never commit.
- Do NOT commit: `vendor/bonsplit` (unstaged drift),
  `plans-integration-keyboard-tmux.md` (prior-session scratch),
  `plans-remote-handoff-prompt.md` (this session's input prompt).
- `.gitignore` additions if any tooling drops stray files.
