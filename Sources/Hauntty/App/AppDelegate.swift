import AppKit
import HaunttyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var ghostty: GhosttyApp!
    private var windowController: TerminalWindowController?
    private var tmux: ControlClient?
    private var tabs: TabStore?
    private var claudeSessions: ClaudeSessionFile?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        ghostty = GhosttyApp()

        // The surface runs tmux. The control client waits for the surface's
        // tmux client, then keeps the tabs in sync with its session.
        let tabs = TabStore()
        self.tabs = tabs
        let tmux = ControlClient(executable: Tmux.executable, store: tabs) { [weak self] in
            self?.windowController?.paneClient
        }
        tmux.start()
        self.tmux = tmux

        // scripts/hauntty.sh writes each Claude Code session's state from its
        // hooks. The tabs show the sessions their panes show.
        let claudeSessions = ClaudeSessionFile(url: ClaudeSessionFile.defaultURL)
        claudeSessions.onChange = { tabs.applyClaudeSessions($0) }
        claudeSessions.start()
        self.claudeSessions = claudeSessions

        let controller = TerminalWindowController(
            ghostty: ghostty,
            command: Tmux.attachCommand(),
            tabs: tabs,
            onSelectTab: { [weak tmux] id in tmux?.selectWindow(id) })
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearSeenClaudeSessions() }
        }
        observeSeenClaudeSessions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tmux?.stop()
        claudeSessions?.stop()
    }

    /// A done, blocked or error session asks you to come and look. Once you
    /// look at its tab, in the focused window, remove its state.
    @MainActor
    private func clearSeenClaudeSessions() {
        guard let tabs, let claudeSessions, windowController?.window?.isKeyWindow == true else { return }
        for session in tabs.seenClaudeSessions() {
            claudeSessions.remove(session)
        }
    }

    /// Clear seen sessions whenever the active tab, its panes or the sessions'
    /// states change.
    @MainActor
    private func observeSeenClaudeSessions() {
        clearSeenClaudeSessions()
        guard let tabs else { return }
        withObservationTracking {
            _ = tabs.seenClaudeSessions()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeSeenClaudeSessions() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Hauntty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Hauntty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
