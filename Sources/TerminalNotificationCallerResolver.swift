import Foundation
import CmuxSidebar

@MainActor
private struct TerminalCallerTarget {
    let workspace: Workspace
    let surfaceId: UUID?
    let shouldRecordTmuxRoute: Bool

    init(workspace: Workspace, surfaceId: UUID?, shouldRecordTmuxRoute: Bool = true) {
        self.workspace = workspace
        self.surfaceId = surfaceId
        self.shouldRecordTmuxRoute = shouldRecordTmuxRoute
    }
}

@MainActor
extension TerminalController {
    func v2NotificationCreateForCaller(params: [String: Any]) -> V2CallResult {
        guard let fallbackTabManager = activeTabManagerForCallerNotification() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let preferredWorkspaceId = v2UUID(params, "preferred_workspace_id")
        let preferredSurfaceId = v2UUID(params, "preferred_surface_id")
        let callerTTY = Self.normalizedTTYName(stringParam(params, "caller_tty"))
        let preferTTY = boolParam(params, "prefer_tty") ?? false
        let allowSelectedFallback = boolParam(params, "allow_selected_fallback") ?? true
        let tmuxMetadata = tmuxPaneMetadata(params)
        let title = stringParam(params, "title") ?? "Notification"
        let subtitle = stringParam(params, "subtitle") ?? ""
        let body = stringParam(params, "body") ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        runOnMain {
            let target = Self.callerTarget(
                fallback: fallbackTabManager,
                preferredWorkspaceId: preferredWorkspaceId,
                preferredSurfaceId: preferredSurfaceId,
                callerTTY: callerTTY,
                preferTTY: preferTTY,
                tmuxMetadata: tmuxMetadata,
                allowSelectedFallback: allowSelectedFallback
            )
            guard let target else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if target.shouldRecordTmuxRoute {
                target.workspace.recordTmuxPaneRoute(metadata: tmuxMetadata, surfaceId: target.surfaceId)
            }
            self.deliverNotificationSynchronously(
                tabId: target.workspace.id,
                surfaceId: target.surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(self.callerTargetPayload(target))
        }
        return result
    }

    func v2StatusSetForCaller(params: [String: Any]) -> V2CallResult {
        guard let fallbackTabManager = activeTabManagerForCallerNotification() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let key = stringParam(params, "key") else {
            return .err(code: "invalid_params", message: "Missing status key", data: nil)
        }
        guard let value = stringParam(params, "value") else {
            return .err(code: "invalid_params", message: "Missing status value", data: nil)
        }

        let formatRaw = stringParam(params, "format") ?? SidebarMetadataFormat.plain.rawValue
        guard let format = Self.sidebarMetadataFormat(formatRaw) else {
            return .err(code: "invalid_params", message: "Invalid metadata format", data: ["format": formatRaw])
        }

        let priority = max(-9999, min(9999, intParam(params, "priority") ?? 0))
        let parsedURL: URL?
        if let rawURL = stringParam(params, "url") ?? stringParam(params, "link") {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .err(code: "invalid_params", message: "Invalid status URL", data: ["url": rawURL])
            }
            parsedURL = candidate
        } else {
            parsedURL = nil
        }

        let preferredWorkspaceId = v2UUID(params, "preferred_workspace_id")
        let preferredSurfaceId = v2UUID(params, "preferred_surface_id")
        let callerTTY = Self.normalizedTTYName(stringParam(params, "caller_tty"))
        let preferTTY = boolParam(params, "prefer_tty") ?? false
        let allowSelectedFallback = boolParam(params, "allow_selected_fallback") ?? true
        let tmuxMetadata = tmuxPaneMetadata(params)
        let pidValue = intParam(params, "pid").flatMap { value -> pid_t? in
            value > 0 ? pid_t(value) : nil
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to set status", data: nil)
        runOnMain {
            let target = Self.callerTarget(
                fallback: fallbackTabManager,
                preferredWorkspaceId: preferredWorkspaceId,
                preferredSurfaceId: preferredSurfaceId,
                callerTTY: callerTTY,
                preferTTY: preferTTY,
                tmuxMetadata: tmuxMetadata,
                allowSelectedFallback: allowSelectedFallback
            )
            guard let target else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            if target.shouldRecordTmuxRoute {
                target.workspace.recordTmuxPaneRoute(metadata: tmuxMetadata, surfaceId: target.surfaceId)
            }
            target.workspace.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: self.stringParam(params, "icon"),
                color: self.stringParam(params, "color"),
                url: parsedURL,
                priority: priority,
                format: format,
                timestamp: Date(),
                tmuxMetadata: tmuxMetadata?.hasContent == true ? tmuxMetadata : nil
            )
            if let pidValue {
                target.workspace.recordAgentPID(key: key, pid: pidValue, panelId: target.surfaceId)
            }
            result = .ok(self.callerTargetPayload(target))
        }
        return result
    }

    private static func callerTarget(
        fallback: TabManager,
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        callerTTY: String?,
        preferTTY: Bool,
        tmuxMetadata: TmuxPaneMetadata?,
        allowSelectedFallback: Bool
    ) -> TerminalCallerTarget? {
        let managers = candidateManagers(
            fallback: fallback,
            preferredWorkspaceId: preferredWorkspaceId,
            preferredSurfaceId: preferredSurfaceId
        )
        let ttyTarget = callerTTY.flatMap { targetForTTY($0, tabManagers: managers) }
        if preferTTY, let ttyTarget { return ttyTarget }

        if let preferredWorkspaceId,
           let workspace = workspace(id: preferredWorkspaceId, tabManagers: managers) {
            if let preferredSurfaceId, workspace.panels[preferredSurfaceId] != nil {
                return TerminalCallerTarget(workspace: workspace, surfaceId: preferredSurfaceId)
            }
            if let ttyTarget, ttyTarget.workspace.id == workspace.id { return ttyTarget }
            if let routeTarget = targetForTmuxPane(tmuxMetadata, tabManagers: managers),
               routeTarget.workspace.id == workspace.id {
                return routeTarget
            }
            guard allowSelectedFallback else { return nil }
            return TerminalCallerTarget(workspace: workspace, surfaceId: workspace.focusedPanelId, shouldRecordTmuxRoute: false)
        }

        if let ttyTarget { return ttyTarget }
        if let preferredSurfaceId,
           let surfaceTarget = targetForSurface(preferredSurfaceId, tabManagers: managers) {
            return surfaceTarget
        }
        if let routeTarget = targetForTmuxPane(tmuxMetadata, tabManagers: managers) { return routeTarget }
        if let preferredSurfaceId,
           let selected = selectedWorkspace(in: managers),
           selected.panels[preferredSurfaceId] != nil {
            return TerminalCallerTarget(workspace: selected, surfaceId: preferredSurfaceId)
        }
        guard allowSelectedFallback, let selected = selectedWorkspace(in: managers) else { return nil }
        return TerminalCallerTarget(workspace: selected, surfaceId: selected.focusedPanelId, shouldRecordTmuxRoute: false)
    }

    private static func candidateManagers(
        fallback: TabManager,
        preferredWorkspaceId: UUID?,
        preferredSurfaceId: UUID?
    ) -> [TabManager] {
        var managers: [TabManager] = []
        func append(_ manager: TabManager?) {
            guard let manager, !managers.contains(where: { $0 === manager }) else { return }
            managers.append(manager)
        }

        let app = AppDelegate.shared
        if let preferredWorkspaceId { append(app?.tabManagerFor(tabId: preferredWorkspaceId)) }
        if let preferredSurfaceId { append(app?.locateSurface(surfaceId: preferredSurfaceId)?.tabManager) }
        append(fallback)
        app?.listMainWindowSummaries().forEach { append(app?.tabManagerFor(windowId: $0.windowId)) }
        return managers
    }

    private static func workspace(id: UUID, tabManagers: [TabManager]) -> Workspace? {
        for manager in tabManagers {
            if let workspace = manager.tabs.first(where: { $0.id == id }) { return workspace }
        }
        return nil
    }

    private static func selectedWorkspace(in tabManagers: [TabManager]) -> Workspace? {
        for manager in tabManagers {
            if let selectedId = manager.selectedTabId,
               let workspace = manager.tabs.first(where: { $0.id == selectedId }) {
                return workspace
            }
        }
        return nil
    }

    private static func targetForTTY(
        _ ttyName: String,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs {
                for (surfaceId, candidateTTY) in workspace.surfaceTTYNames
                    where workspace.panels[surfaceId] != nil && normalizedTTYName(candidateTTY) == ttyName {
                    return TerminalCallerTarget(workspace: workspace, surfaceId: surfaceId)
                }
            }
        }
        return nil
    }

    private static func targetForTmuxPane(
        _ metadata: TmuxPaneMetadata?,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        guard let metadata else { return nil }
        for manager in tabManagers {
            for workspace in manager.tabs {
                guard let route = workspace.tmuxPaneRoute(metadata: metadata) else { continue }
                if let surfaceId = route.surfaceId, workspace.panels[surfaceId] == nil { continue }
                return TerminalCallerTarget(workspace: workspace, surfaceId: route.surfaceId)
            }
        }
        return nil
    }

    private static func targetForSurface(
        _ surfaceId: UUID,
        tabManagers: [TabManager]
    ) -> TerminalCallerTarget? {
        for manager in tabManagers {
            for workspace in manager.tabs where workspace.panels[surfaceId] != nil {
                return TerminalCallerTarget(workspace: workspace, surfaceId: surfaceId)
            }
        }
        return nil
    }

    private func callerTargetPayload(_ target: TerminalCallerTarget) -> [String: Any] {
        [
            "workspace_id": target.workspace.id.uuidString,
            "surface_id": target.surfaceId?.uuidString ?? NSNull()
        ]
    }

    private func tmuxPaneMetadata(_ params: [String: Any]) -> TmuxPaneMetadata? {
        let metadata = TmuxPaneMetadata(
            paneId: stringParam(params, "tmux_pane_id") ?? stringParam(params, "pane_id"),
            paneTTY: Self.normalizedTTYName(stringParam(params, "tmux_pane_tty") ?? stringParam(params, "pane_tty")),
            session: stringParam(params, "tmux_session") ?? stringParam(params, "session"),
            window: stringParam(params, "tmux_window") ?? stringParam(params, "window"),
            pane: stringParam(params, "tmux_pane") ?? stringParam(params, "pane"),
            command: stringParam(params, "tmux_command") ?? stringParam(params, "command")
        )
        return metadata.hasContent ? metadata : nil
    }

    private func stringParam(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boolParam(_ params: [String: Any], _ key: String) -> Bool? {
        if let value = params[key] as? Bool { return value }
        if let value = params[key] as? NSNumber { return value.boolValue }
        switch stringParam(params, key)?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let value = params[key] as? Int { return value }
        if let value = params[key] as? NSNumber { return value.intValue }
        if let raw = stringParam(params, key) { return Int(raw) }
        return nil
    }

    private static func normalizedTTYName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "not a tty" else {
            return nil
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func sidebarMetadataFormat(_ raw: String) -> SidebarMetadataFormat? {
        switch raw.lowercased() {
        case "plain": return .plain
        case "markdown", "md": return .markdown
        default: return nil
        }
    }

    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }
}
