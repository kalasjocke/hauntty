import AppKit
import HaunttyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var ghostty: GhosttyApp!
    private var windowController: TerminalWindowController?
    private var tmux: ControlClient?
    private var claude: ClaudeSessionWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        ghostty = GhosttyApp()

        // The surface runs tmux. The control client waits for the surface's
        // tmux client, then keeps the tabs in sync with its session.
        let tabs = TabStore()
        let tmux = ControlClient(executable: Tmux.executable, store: tabs) { [weak self] in
            self?.windowController?.paneClient
        }
        tmux.start()
        self.tmux = tmux

        // Title tabs that run Claude Code after the session.
        let claude = ClaudeSessionWatcher(store: tabs)
        claude.start()
        self.claude = claude

        let controller = TerminalWindowController(
            ghostty: ghostty,
            command: Tmux.attachCommand(),
            tabs: tabs,
            onSelectTab: { [weak tmux] id in tmux?.selectWindow(id) })
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tmux?.stop()
        claude?.stop()
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
