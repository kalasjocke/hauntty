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

    public init(
        id: String, index: Int, title: String, command: String? = nil, paneCount: Int = 1,
        status: WindowStatus? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.command = command ?? title
        self.paneCount = paneCount
        self.status = status
    }
}

/// The windows of the tmux session, in tmux's order. Only tmux changes it.
@MainActor
@Observable
public final class TabStore {
    public private(set) var windows: [TmuxWindow] = []
    public private(set) var activeID: String?

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
    /// is last so it may contain the separator. Process names do not.
    public static let windowListFormat =
        "#{window_id}|#{window_index}|#{window_active}|#{window_panes}|#{@hauntty-status}|"
        + "#{pane_current_command}|" + titleFormat

    public init() {}

    /// Replace the windows with the output of `list-windows -F windowListFormat`.
    public func applyWindowList(_ lines: [String]) {
        var parsed: [TmuxWindow] = []
        var active: String?
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7, fields[0].hasPrefix("@"),
                  let index = Int(fields[1]), let paneCount = Int(fields[3])
            else { continue }
            let window = TmuxWindow(
                id: String(fields[0]), index: index, title: String(fields[6]),
                command: String(fields[5]), paneCount: paneCount,
                status: WindowStatus(rawValue: String(fields[4])))
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
