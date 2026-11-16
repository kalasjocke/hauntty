import Foundation

/// A Claude Code session running in a tmux pane.
///
/// Claude Code writes a file for each running session to
/// `~/.claude/sessions/<pid>.json`, with the session's name and its tmux
/// pane. The format is internal to Claude Code, so all reading of it is
/// here.
public struct ClaudeSession: Equatable, Sendable {
    public var pid: Int32
    /// The tmux pane id, like `%12`.
    public var paneID: String
    public var name: String
    /// True if the user named the session, for example with `/rename`.
    /// Otherwise the name is derived from the directory, like `hauntty-c4`.
    public var isNamed: Bool

    public init(pid: Int32, paneID: String, name: String, isNamed: Bool) {
        self.pid = pid
        self.paneID = paneID
        self.name = name
        self.isNamed = isNamed
    }

    /// The tab title for a window running this session.
    public var title: String { isNamed ? name : "Claude" }

    /// Claude Code runs from `~/.local/share/claude/versions/<version>`, so
    /// tmux sees a process named like `2.1.325`. This tells it apart from
    /// other processes before its session file exists and after it is gone.
    public static func isClaudeProcess(_ command: String) -> Bool {
        let parts = command.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// Read a session file. Sessions that are not in a tmux pane give nil.
    public static func parse(_ data: Data) -> ClaudeSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int,
              // "<session>:<window id>.<pane id>", like "0:@36.%121".
              let tmux = object["tmux"] as? String,
              let dot = tmux.lastIndex(of: "."),
              case let paneID = String(tmux[tmux.index(after: dot)...]),
              paneID.hasPrefix("%")
        else { return nil }
        return ClaudeSession(
            pid: Int32(pid),
            paneID: paneID,
            name: object["name"] as? String ?? "",
            isNamed: object["nameSource"] as? String == "user" && !(object["name"] as? String ?? "").isEmpty)
    }
}

/// Watches Claude Code's session files and passes the running sessions to a
/// `TabStore`. It rereads the files when FSEvents reports a change in the
/// folder, and when a session's process exits, since a process that crashes
/// leaves its file behind.
@MainActor
public final class ClaudeSessionWatcher {
    private let directory: URL
    private let store: TabStore
    private let isAlive: (Int32) -> Bool
    private var stream: FSEventStreamRef?
    /// Exit watchers for the processes of the sessions in the store.
    private var exits: [Int32: DispatchSourceProcess] = [:]

    /// `$CLAUDE_CONFIG_DIR/sessions`, or `~/.claude/sessions`.
    public nonisolated static var defaultDirectory: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("sessions", isDirectory: true)
    }

    /// - Parameter isAlive: Whether a process is running. Session files can
    ///   outlive their process.
    public init(
        directory: URL = ClaudeSessionWatcher.defaultDirectory,
        store: TabStore,
        isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        self.directory = directory
        self.store = store
        self.isAlive = isAlive
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let watcher = Unmanaged<ClaudeSessionWatcher>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scan() }
        }
        // File events report files rewritten in place too. The folder may
        // not exist until Claude Code first runs; FSEvents watches the path
        // anyway.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [Self.resolvingSymlinks(directory.path)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        scan()
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        exits.values.forEach { $0.cancel() }
        exits.removeAll()
    }

    /// Read the session files once.
    public func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var sessions: [String: ClaudeSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = ClaudeSession.parse(data),
                  isAlive(session.pid)
            else { continue }
            sessions[session.paneID] = session
        }
        store.applyClaudeSessions(sessions)
        if stream != nil { watchExits(of: Set(sessions.values.map(\.pid))) }
    }

    /// FSEvents reports real paths and does not match a watched path that
    /// goes through a symlink, like `/var` or a linked `~/.claude`, unless the
    /// path exists. Resolve the part that exists and append the rest.
    nonisolated static func resolvingSymlinks(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let real = realpath(existing, nil) else { return path }
        defer { free(real) }
        return missing.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func watchExits(of pids: Set<Int32>) {
        for (pid, source) in exits where !pids.contains(pid) {
            source.cancel()
            exits[pid] = nil
        }
        for pid in pids where exits[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
            source.resume()
            exits[pid] = source
        }
    }
}
