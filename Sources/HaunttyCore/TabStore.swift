import Observation

/// What a program in a window reports through the `@hauntty-status` window
/// option, for example from a Claude Code hook:
/// `tmux set -w @hauntty-status working`. The states are the ones in the
/// OSC 7501 program status proposal:
/// https://mitchellh.com/writing/program-status-osc7501
public enum WindowStatus: String, Sendable {
    /// At rest, waiting for the user's next instruction.
    case idle
    case working
    /// Finished, and the user has not seen the result yet.
    case done
    /// Cannot continue until the user does something.
    case blocked
    /// Failed and stopped.
    case error
}

/// One tmux window, shown as one tab.
public struct TmuxWindow: Identifiable, Equatable, Sendable {
    /// The tmux window id, like `@3`.
    public let id: String
    public var index: Int
    /// The tmux window name. With tmux's defaults it is the process in the
    /// focused pane, until the user renames the window.
    public var title: String
    /// The process running in the window's focused pane.
    public var command: String
    public var paneCount: Int
    public var status: WindowStatus?
    /// The focused pane's id, like `%12`.
    public var activePaneID: String
    /// All pane ids, in tmux's order.
    public var paneIDs: [String]

    public init(
        id: String, index: Int, title: String, command: String? = nil, paneCount: Int = 1,
        status: WindowStatus? = nil, activePaneID: String = "", paneIDs: [String] = []
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.command = command ?? title
        self.paneCount = paneCount
        self.status = status
        self.activePaneID = activePaneID
        self.paneIDs = paneIDs
    }
}

/// The windows of the tmux session, in tmux's order. Only tmux changes it.
@MainActor
@Observable
public final class TabStore {
    public private(set) var windows: [TmuxWindow] = []
    public private(set) var activeID: String?
    /// Running Claude Code sessions, by tmux pane id.
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]

    /// The fields the tmux subscription last reported, by window id.
    ///
    /// tmux only reports a value that differs from the one it last sent. A
    /// reload can show a newer value the subscription never sent, and if
    /// the value then changes back, tmux reports nothing. So once the
    /// subscription has reported a window, its fields win over reloads.
    private var reported: [String: Report] = [:]

    fileprivate struct Report: Equatable {
        var index: Int
        var status: WindowStatus?
        var command: String
        var title: String
    }

    /// What the tmux subscription reports for each window, read by
    /// `applyReport`. The title is last so it may contain the separator.
    public static let reportFormat =
        "#{window_index}|#{@hauntty-status}|#{pane_current_command}|" + titleFormat

    /// The tab title: the window name, as tmux's own status bar shows it.
    /// tmux keeps it set to the focused process while `automatic-rename` is
    /// on, following `automatic-rename-format`.
    ///
    /// One exception: a new pane runs as a copy of tmux until it starts the
    /// shell, and tmux keeps the automatic name `tmux` until the shell prints
    /// something. Show the process instead of that name.
    public static let titleFormat =
        "#{?#{&&:#{automatic-rename},#{==:#{window_name},tmux}},#{pane_current_command},#{window_name}}"

    /// The `list-windows -F` format that `applyWindowList` reads. The title
    /// is last so it may contain the separator. Process names and pane ids
    /// do not.
    public static let windowListFormat =
        "#{window_id}|#{window_index}|#{window_active}|#{window_panes}|#{@hauntty-status}|"
        + "#{pane_id}|#{P:#{pane_id} }|#{pane_current_command}|" + titleFormat

    public init() {}

    /// Replace the windows with the output of `list-windows -F windowListFormat`.
    public func applyWindowList(_ lines: [String]) {
        var parsed: [TmuxWindow] = []
        var active: String?
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, fields[0].hasPrefix("@"),
                  let index = Int(fields[1]), let paneCount = Int(fields[3])
            else { continue }
            let window = TmuxWindow(
                id: String(fields[0]), index: index, title: String(fields[8]),
                command: String(fields[7]), paneCount: paneCount,
                status: WindowStatus(rawValue: String(fields[4])),
                activePaneID: String(fields[5]),
                paneIDs: fields[6].split(separator: " ").map(String.init))
            parsed.append(window.applying(reported[window.id]))
            if fields[2] == "1" { active = window.id }
        }
        parsed.sort { $0.index < $1.index }
        reported = reported.filter { id, _ in parsed.contains { $0.id == id } }

        // Assign only on change, so observers do not redraw or animate for
        // reloads that change nothing.
        if parsed != windows { windows = parsed }
        if let active, active != activeID { activeID = active }
    }

    public enum ReportResult: Equatable {
        case applied
        /// The window is new or moved, so the window list needs a reload.
        case needsReload
    }

    /// Apply a subscription value in `reportFormat` for one window.
    public func applyReport(windowID: String, value: String) -> ReportResult {
        let fields = value.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let index = Int(fields[0]) else { return .needsReload }
        let report = Report(
            index: index, status: WindowStatus(rawValue: String(fields[1])),
            command: String(fields[2]), title: String(fields[3]))
        reported[windowID] = report
        guard let position = windows.firstIndex(where: { $0.id == windowID }),
              windows[position].index == index
        else { return .needsReload }
        let window = windows[position].applying(report)
        if window != windows[position] { windows[position] = window }
        return .applied
    }

    /// Clear a window's status after Hauntty unsets it in tmux, before the
    /// subscription reports it.
    public func clearStatus(_ windowID: String) {
        reported[windowID]?.status = nil
        if let position = windows.firstIndex(where: { $0.id == windowID }) {
            windows[position].status = nil
        }
    }

    /// Replace the running Claude Code sessions.
    public func applyClaudeSessions(_ sessions: [String: ClaudeSession]) {
        if sessions != claudeSessions { claudeSessions = sessions }
    }

    /// The Claude Code session running in a window, preferring the focused
    /// pane when there is more than one.
    public func claudeSession(in window: TmuxWindow) -> ClaudeSession? {
        claudeSessions[window.activePaneID] ?? window.paneIDs.lazy.compactMap { self.claudeSessions[$0] }.first
    }

    /// Whether the window runs Claude Code, from its session file or its
    /// process name.
    public func runsClaude(_ window: TmuxWindow) -> Bool {
        claudeSession(in: window) != nil || ClaudeSession.isClaudeProcess(window.command)
            || ClaudeSession.isClaudeProcess(window.title)
    }

    /// The tab title: the Claude Code session's title if one runs in the
    /// window, or else the window's title from tmux.
    public func tabTitle(for window: TmuxWindow) -> String {
        if let session = claudeSession(in: window) { return session.title }
        // tmux names a window running Claude Code after its version.
        return ClaudeSession.isClaudeProcess(window.title) ? "Claude" : window.title
    }

    /// Apply a `%window-renamed` notification. tmux sends one for every
    /// rename, so unlike the subscription it cannot miss a change back.
    /// The `tmux` name a new pane has for a moment is left to the
    /// subscription, which shows the process instead.
    public func applyRename(windowID: String, name: String) {
        guard name != "tmux" else { return }
        reported[windowID]?.title = name
        if let position = windows.firstIndex(where: { $0.id == windowID }), windows[position].title != name {
            windows[position].title = name
        }
    }

    /// Mark a window active before tmux confirms it, so a click shows at once.
    public func setActive(_ id: String) {
        guard id != activeID, windows.contains(where: { $0.id == id }) else { return }
        activeID = id
    }
}

private extension TmuxWindow {
    /// The window with the subscription's fields, except the index, which
    /// only a reload changes so the order stays consistent.
    func applying(_ report: TabStore.Report?) -> TmuxWindow {
        guard let report else { return self }
        var window = self
        window.status = report.status
        window.command = report.command
        window.title = report.title
        return window
    }
}
