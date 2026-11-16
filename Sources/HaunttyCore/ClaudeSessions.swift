import Foundation

/// What a Claude Code session is doing, as `scripts/hauntty.sh` writes it from
/// Claude Code's hooks: one line per session.
public struct ClaudeSession: Equatable, Sendable {
    public var id: String
    public var status: WindowStatus
    /// The session's name. Claude Code titles a pane that shows the session
    /// with it.
    public var name: String
    /// For a session running in a tmux pane, the pane, like `default:%12`:
    /// the tmux socket name and the pane id. Empty for a background session.
    public var pane: String
    /// The title of that pane when the state was written.
    public var paneTitle: String

    public init(id: String, status: WindowStatus, name: String, pane: String = "", paneTitle: String = "") {
        self.id = id
        self.status = status
        self.name = name
        self.pane = pane
        self.paneTitle = paneTitle
    }

    /// Read a line of the sessions file: the id, state, name, pane and pane
    /// title, separated by tabs.
    public init?(line: Substring) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, !fields[0].isEmpty, let status = WindowStatus(rawValue: fields[1]) else { return nil }
        func field(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
        self.init(id: fields[0], status: status, name: field(2), pane: field(3), paneTitle: field(4))
    }

    var line: String { [id, status.rawValue, name, pane, paneTitle].joined(separator: "\t") }
}

/// The file `scripts/hauntty.sh` keeps every session's state in. It reports
/// the sessions whenever the file is replaced.
@MainActor
public final class ClaudeSessionFile {
    public let url: URL
    public var onChange: ([ClaudeSession]) -> Void = { _ in }

    private var source: DispatchSourceFileSystemObject?

    /// `$TMPDIR/hauntty/claude-sessions`, where `scripts/hauntty.sh` writes.
    /// Claude Code and Hauntty get the same per-user temporary folder from
    /// macOS.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "hauntty/claude-sessions")
    }

    private var directory: URL { url.deletingLastPathComponent() }
    /// Writers hold an flock(2) on it while they rewrite the file.
    private var lockURL: URL { directory.appending(path: ".\(url.lastPathComponent).lock") }

    public init(url: URL) {
        self.url = url
    }

    /// Report the sessions now, and again whenever the file changes.
    public func start() {
        stop()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Writers rename a new file into place, so watch the folder: the file
        // itself is replaced.
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let source = self.source else { return }
                    // macOS clears old temporary files, which can remove the
                    // folder. Make it again and watch the new one.
                    if !source.data.isDisjoint(with: [.delete, .rename]) {
                        self.start()
                    } else {
                        self.onChange(self.load())
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        onChange(load())
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Every session in the file, in the file's order.
    public func load() -> [ClaudeSession] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap(ClaudeSession.init(line:))
    }

    /// Remove a session's line, unless its hook has written a new state since
    /// the session was read.
    public func remove(_ session: ClaudeSession) {
        let lock = open(lockURL.path, O_WRONLY | O_CREAT, 0o600)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return }

        let sessions = load()
        guard sessions.contains(session) else { return }
        let contents = sessions.filter { $0.id != session.id }.map { $0.line + "\n" }.joined()
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(getpid())")
        guard (try? contents.write(to: temporary, atomically: false, encoding: .utf8)) != nil else { return }
        if rename(temporary.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
