import Observation

/// One tmux window, shown as one tab.
public struct TmuxWindow: Identifiable, Equatable, Sendable {
    /// The tmux window id, like `@3`.
    public let id: String
    public var index: Int
    /// The process running in the window's focused pane.
    public var title: String

    public init(id: String, index: Int, title: String) {
        self.id = id
        self.index = index
        self.title = title
    }
}

/// The windows of the tmux session, in tmux's order. Only tmux changes it.
@MainActor
@Observable
public final class TabStore {
    public private(set) var windows: [TmuxWindow] = []
    public private(set) var activeID: String?

    /// The `list-windows -F` format that `applyWindowList` reads. The title
    /// is last so it may contain the separator.
    public static let windowListFormat =
        "#{window_id}|#{window_index}|#{window_active}|#{pane_current_command}"

    public init() {}

    /// Replace the windows with the output of `list-windows -F windowListFormat`.
    public func applyWindowList(_ lines: [String]) {
        var parsed: [TmuxWindow] = []
        var active: String?
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0].hasPrefix("@"), let index = Int(fields[1]) else { continue }
            let window = TmuxWindow(id: String(fields[0]), index: index, title: String(fields[3]))
            parsed.append(window)
            if fields[2] == "1" { active = window.id }
        }
        parsed.sort { $0.index < $1.index }

        // Assign only on change, so observers do not redraw or animate for
        // reloads that change nothing.
        if parsed != windows { windows = parsed }
        if let active, active != activeID { activeID = active }
    }

    /// Mark a window active before tmux confirms it, so a click shows at once.
    public func setActive(_ id: String) {
        guard id != activeID, windows.contains(where: { $0.id == id }) else { return }
        activeID = id
    }
}
