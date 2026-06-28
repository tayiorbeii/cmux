public import Foundation

/// Tmux pane metadata attached to sidebar status rows reported from inside tmux.
public struct TmuxPaneMetadata: Equatable, Hashable, Sendable {
    public let paneId: String?
    public let paneTTY: String?
    public let session: String?
    public let window: String?
    public let pane: String?
    public let command: String?

    public init(paneId: String?, paneTTY: String?, session: String?, window: String?, pane: String?, command: String?) {
        self.paneId = paneId; self.paneTTY = paneTTY; self.session = session; self.window = window; self.pane = pane; self.command = command
    }

    public var hasContent: Bool { paneId != nil || paneTTY != nil || session != nil || window != nil || pane != nil || command != nil }
}

/// One keyed status row shown under a workspace in the sidebar
/// (e.g. an agent status line), as reported over the control socket.
public struct SidebarStatusEntry: Equatable, Sendable {
    /// Stable key identifying the row (last write per key wins).
    public let key: String
    /// The displayed status text.
    public let value: String
    /// Optional SF Symbol name shown before the text.
    public let icon: String?
    /// Optional hex color for the row.
    public let color: String?
    /// Optional URL the row opens when clicked.
    public let url: URL?
    /// Sort priority (higher sorts first).
    public let priority: Int
    /// How `value` is rendered.
    public let format: SidebarMetadataFormat
    /// When the entry was reported.
    public let timestamp: Date
    /// Optional tmux pane identity used to route notifications back to the originating pane.
    public let tmuxMetadata: TmuxPaneMetadata?

    /// Creates a status row (defaults mirror the legacy initializer).
    public init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date(),
        tmuxMetadata: TmuxPaneMetadata? = nil
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
        self.tmuxMetadata = tmuxMetadata
    }
}
