import CmuxCommandPalette
import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.sleepyMode",
                title: constant(String(localized: "command.sleepyMode.title", defaultValue: "Sleepy Mode")),
                subtitle: constant(String(localized: "command.sleepyMode.subtitle", defaultValue: "View")),
                keywords: ["sleepy", "screensaver", "caffeinate", "keep awake", "do not sleep", "lock", "pets", "night"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.remoteHandoff",
                title: constant(String(localized: "command.remoteHandoff.title", defaultValue: "Tmux Handoff")),
                subtitle: constant(String(localized: "command.remoteHandoff.subtitle", defaultValue: "Hand off this agent to a tmux session over ssh")),
                keywords: ["remote", "handoff", "ssh", "tmux", "agent", "resume", "fork", "session"]
            ),
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: "palette.sleepyMode") {
            SleepyModeController.shared.activate()
        }
        registry.register(commandId: "palette.remoteHandoff") {
            // The registry handler runs on the main actor (same as the
            // triggerFlash handler above); RemoteHandoffInApp.perform runs the
            // shared RemoteHandoffRunner off-main and surfaces the ssh line on
            // the main actor.
            Task { @MainActor in
                await RemoteHandoffInApp.perform(tabManager: tabManager)
            }
        }
    }
}
