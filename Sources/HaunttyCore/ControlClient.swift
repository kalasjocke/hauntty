import Foundation

/// A tmux client in control mode, attached to the same session as the
/// terminal. It keeps a `TabStore` in sync with the session's windows and
/// sends tab clicks back to tmux.
///
/// The terminal surface creates the session, so the client retries until the
/// session exists, and reconnects if it drops.
@MainActor
public final class ControlClient {
    public let store: TabStore

    private let executable: String
    private let socketName: String?
    private let session: String

    private var process: Process?
    private var input: FileHandle?
    private var parser = ControlParser()
    /// Handlers for commands sent but not yet answered, in order.
    private var pending: [(ControlReply) -> Void] = []
    private var sessionID: String?
    private var attached = false
    private var stopped = true
    /// Bumped on every launch and stop, so output from an old process is
    /// ignored.
    private var generation = 0
    private var retryDelay: TimeInterval = ControlClient.minimumRetryDelay
    private var reloadInFlight = false
    private var reloadQueued = false
    /// The window whose done status is being cleared, so it is cleared once.
    private var clearingID: String?

    private static let minimumRetryDelay: TimeInterval = 0.1
    private static let maximumRetryDelay: TimeInterval = 2

    /// Subscription that reports each window's index, status, focused process
    /// and title. A change reloads the window list. tmux checks it at most
    /// once a second.
    static let subscription =
        "hauntty-tabs:@*:#{window_index} #{@hauntty-status} #{pane_current_command} " + TabStore.titleFormat

    /// - Parameters:
    ///   - executable: Path to tmux, or a bare name to look up in PATH.
    ///   - socketName: A tmux `-L` socket name, or nil for the default server.
    ///   - session: The session to attach to, matched exactly.
    public init(executable: String, socketName: String? = nil, session: String, store: TabStore) {
        self.executable = executable
        self.socketName = socketName
        self.session = session
        self.store = store
    }

    public func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    public func stop() {
        stopped = true
        generation += 1
        process?.terminate()
        reset()
    }

    /// Ask tmux to switch to a window. The store updates at once and tmux
    /// confirms it with a notification.
    public func selectWindow(_ id: String) {
        guard attached else { return }
        store.setActive(id)
        send("select-window -t \(id)")
    }

    // MARK: Process

    private func launch() {
        generation += 1
        let generation = generation

        var arguments: [String] = []
        if let socketName { arguments += ["-L", socketName] }
        arguments += ["-C", "attach-session", "-t", "=\(session)", "-f", "ignore-size,no-output"]

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        // tmux refuses to attach from inside another tmux client.
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, generation: generation) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.exited(generation: generation) }
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            exited(generation: generation)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private func exited(generation: Int) {
        guard generation == self.generation else { return }
        reset()
        guard !stopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, generation == self.generation else { return }
                self.launch()
            }
        }
    }

    private func reset() {
        process = nil
        try? input?.close()
        input = nil
        parser = ControlParser()
        pending.removeAll()
        sessionID = nil
        attached = false
        reloadInFlight = false
        reloadQueued = false
        clearingID = nil
    }

    // MARK: Protocol

    private func receive(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        for event in parser.feed(data) {
            handle(event)
        }
    }

    private func handle(_ event: ControlEvent) {
        if !attached {
            // tmux prints a reply block for the attach command as soon as the
            // client is attached.
            attached = true
            retryDelay = Self.minimumRetryDelay
            send("refresh-client -B \(Self.quoted(Self.subscription))")
            reload()
        }

        switch event {
        case .reply(let reply):
            guard reply.fromClient, !pending.isEmpty else { return }
            pending.removeFirst()(reply)
        case .notification(let notification):
            switch notification {
            case .sessionChanged(let id, _):
                sessionID = id
                reload()
            case .sessionWindowChanged(let id, let windowID):
                guard id == sessionID else { return }
                store.setActive(windowID)
                reload()
            case .windowAdd, .windowClose, .windowRenamed, .windowPaneChanged, .layoutChange,
                 .subscriptionChanged:
                reload()
            case .exit, .other:
                break
            }
        }
    }

    /// Refresh the store from `list-windows`. Bursts of notifications send
    /// at most one more request after the one in flight.
    private func reload() {
        if reloadInFlight {
            reloadQueued = true
            return
        }
        reloadInFlight = true
        send("list-windows -F \(Self.quoted(TabStore.windowListFormat))") { [weak self] reply in
            guard let self else { return }
            reloadInFlight = false
            if !reply.isError {
                store.applyWindowList(reply.lines)
                clearDoneInActiveWindow()
            }
            if reloadQueued {
                reloadQueued = false
                reload()
            }
        }
    }

    /// A `done` status means "come and look", so it only shows on background
    /// tabs. Clear it when the user switches to the window, or when the
    /// window finishes while it is the active one.
    private func clearDoneInActiveWindow() {
        guard let id = store.activeID,
              store.windows.first(where: { $0.id == id })?.status == .done
        else {
            clearingID = nil
            return
        }
        guard clearingID != id else { return }
        clearingID = id
        send("set-option -w -u -t \(id) @hauntty-status")
        reload()
    }

    private func send(_ command: String, reply: @escaping (ControlReply) -> Void = { _ in }) {
        guard let input else { return }
        pending.append(reply)
        // Writing to a closed pipe raises SIGPIPE, which would kill Hauntty.
        signal(SIGPIPE, SIG_IGN)
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Single-quote a constant argument for tmux's command parser, so `#{}`
    /// formats are passed through as they are.
    private static func quoted(_ argument: String) -> String {
        precondition(!argument.contains("'"))
        return "'\(argument)'"
    }
}
