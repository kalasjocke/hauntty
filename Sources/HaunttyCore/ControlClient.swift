import Foundation

/// A tmux client in control mode that follows the terminal pane's tmux
/// client: it attaches to whichever session the pane shows, and switches
/// when the pane switches. It keeps a `TabStore` in sync with that session's
/// windows and sends tab clicks back to tmux.
///
/// The pane starts tmux, so the client retries until a session exists and
/// the pane's client shows up, and reconnects if it drops.
@MainActor
public final class ControlClient {
    public let store: TabStore

    private let executable: String
    private let socketName: String?
    private let paneClient: @MainActor () -> String?

    private var process: Process?
    private var input: FileHandle?
    private var parser = ControlParser()
    /// Handlers for commands sent but not yet answered, in order.
    private var pending: [(ControlReply) -> Void] = []
    /// The session this client is attached to.
    private var sessionID: String?
    /// The session the pane's client is on, once it is known. The tabs show
    /// it only once `sessionID` matches.
    private var paneSessionID: String?
    private var attached = false
    private var stopped = true
    /// Bumped on every launch and stop, so output from an old process is
    /// ignored.
    private var generation = 0
    private var retryDelay: TimeInterval = ControlClient.minimumRetryDelay
    private var reloadInFlight = false
    private var reloadQueued = false

    private static let minimumRetryDelay: TimeInterval = 0.1
    private static let maximumRetryDelay: TimeInterval = 2
    private static let paneLookupDelay: TimeInterval = 0.25

    /// Subscription that reports each window's index, status and title,
    /// which the store applies directly. tmux checks it at most once a
    /// second.
    static let subscription = "\(subscriptionName):@*:" + TabStore.reportFormat
    static let subscriptionName = "hauntty-tabs"

    /// Subscription that reports the process and title of each pane, also
    /// checked at most once a second.
    static let paneSubscription = "\(paneSubscriptionName):%*:" + TabStore.paneReportFormat
    static let paneSubscriptionName = "hauntty-panes"

    /// - Parameters:
    ///   - executable: Path to tmux, or a bare name to look up in PATH.
    ///   - socketName: A tmux `-L` socket name, or nil for the default server.
    ///   - paneClient: The tmux client name of the terminal pane's tmux, or
    ///     nil while it is not known yet. For a terminal client this is its
    ///     tty path, like `/dev/ttys012`.
    public init(
        executable: String, socketName: String? = nil, store: TabStore,
        paneClient: @escaping @MainActor () -> String?
    ) {
        self.executable = executable
        self.socketName = socketName
        self.store = store
        self.paneClient = paneClient
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
        // Attach to any session. The client switches to the pane's session
        // once it finds the pane's client.
        arguments += ["-C", "attach-session", "-f", "ignore-size,no-output"]

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
        paneSessionID = nil
        attached = false
        reloadInFlight = false
        reloadQueued = false
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
            send("refresh-client -B \(Self.quoted(Self.paneSubscription))")
            lookUpPane()
        }

        switch event {
        case .reply(let reply):
            guard reply.fromClient, !pending.isEmpty else { return }
            pending.removeFirst()(reply)
        case .notification(let notification):
            switch notification {
            case .sessionChanged(let id, _):
                sessionID = id
                if let paneSessionID { followPane(to: paneSessionID) }
            case .clientSessionChanged(let client, let id, _):
                guard client == paneClient() else { return }
                followPane(to: id)
            case .sessionWindowChanged(let id, let windowID):
                guard id == sessionID else { return }
                store.setActive(windowID)
                reload()
            case .subscriptionChanged(Self.subscriptionName, let windowID?, _, let value):
                switch store.applyReport(windowID: windowID, value: value) {
                case .applied: clearDoneInActiveWindow()
                case .needsReload: reload()
                }
            case .subscriptionChanged(Self.paneSubscriptionName, _, let paneID?, let value):
                store.applyPaneReport(paneID: paneID, value: value)
            case .windowRenamed(let windowID, let name):
                store.applyRename(windowID: windowID, name: name)
                readActiveCommand(in: windowID)
                reload()
            case .windowPaneChanged(let windowID, let paneID):
                store.applyActivePane(windowID: windowID, paneID: paneID)
                // The window subscription would report the new title within
                // a second. Ask for it now.
                send("display-message -p -t \(paneID) \(Self.quoted(TabStore.titleFormat))") { [weak self] reply in
                    guard let self, !reply.isError, let title = reply.lines.first else { return }
                    store.applyTitle(windowID: windowID, paneID: paneID, title: title)
                }
                reload()
            case .windowAdd, .windowClose, .layoutChange, .subscriptionChanged:
                reload()
            case .exit, .other:
                break
            }
        }
    }

    /// Find the session the pane's client is on. The pane may start tmux
    /// after this client attached, so look again until the client shows up.
    /// After that, `%client-session-changed` reports its switches.
    private func lookUpPane() {
        let generation = generation
        send("list-clients -F \(Self.quoted("#{client_name}|#{session_id}"))") { [weak self] reply in
            guard let self, paneSessionID == nil else { return }
            if let name = paneClient(), !reply.isError,
               let line = reply.lines.first(where: { $0.hasPrefix(name + "|") }) {
                followPane(to: String(line.dropFirst(name.count + 1)))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.paneLookupDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.attached, generation == self.generation,
                          self.paneSessionID == nil
                    else { return }
                    self.lookUpPane()
                }
            }
        }
    }

    /// Show the pane's session: switch this client to it, or reload if it is
    /// already there. tmux confirms a switch with `%session-changed`. The
    /// tabs replace the session's status bar, so turn it off.
    private func followPane(to id: String) {
        paneSessionID = id
        send("set-option -t \(Self.quoted(id)) status off")
        if id == sessionID {
            reload()
        } else {
            send("switch-client -t \(Self.quoted(id))")
        }
    }

    /// Refresh the store from `list-windows`. Bursts of notifications send
    /// at most one more request after the one in flight. Until this client
    /// is on the pane's session, the tabs stay as they are.
    private func reload() {
        guard sessionID != nil, sessionID == paneSessionID else { return }
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

    /// tmux renames a window when its focused pane starts or ends a program,
    /// up to a second before the pane subscription reports the program. Read
    /// the program then, so the icon changes with the title. Only automatic
    /// renames follow the program, so a rename by the user is ignored.
    private func readActiveCommand(in windowID: String) {
        let format = "#{automatic-rename}|#{pane_id}|" + TabStore.paneReportFormat
        send("display-message -p -t \(windowID) \(Self.quoted(format))") { [weak self] reply in
            guard let self, !reply.isError, let line = reply.lines.first else { return }
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == "1" else { return }
            store.applyPaneReport(paneID: String(fields[1]), value: String(fields[2]))
        }
    }

    /// A `done` status means "come and look", so it only shows on background
    /// tabs. Clear it when the user switches to the window, or when the
    /// window finishes while it is the active one.
    private func clearDoneInActiveWindow() {
        guard let id = store.activeID,
              store.windows.first(where: { $0.id == id })?.status == .done
        else { return }
        send("set-option -w -u -t \(id) @state")
        store.clearStatus(id)
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
