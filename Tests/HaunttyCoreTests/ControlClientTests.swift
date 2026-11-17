import Foundation
import Testing
@testable import HaunttyCore

private let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Runs `ControlClient` against a throwaway tmux server and changes the
/// session from outside, the way a user would from the terminal.
@MainActor
@Suite(.serialized, .enabled(if: tmuxPath != nil, "tmux is not installed"))
struct ControlClientTests {
    /// Each test gets its own server, so one test's server shutting down
    /// cannot break the next test.
    let socket = "hauntty-test-\(getpid())-\(UUID().uuidString.prefix(8))"
    /// tmux names a window after its process only once the pane prints
    /// something, so the tests run processes that print.
    let ping = "ping -i 0.2 127.0.0.1"

    @discardableResult
    func tmux(_ arguments: String...) throws -> String {
        try tmux(arguments)
    }

    @discardableResult
    func tmux(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath!)
        process.arguments = ["-L", socket, "-f", "/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Attach a client that stands in for the tmux in the terminal pane.
    /// It is a control-mode client, so it needs no tty.
    func attachPane(to session: String) throws -> PaneClient {
        try PaneClient(arguments: ["-L", socket, "-f", "/dev/null", "-C", "attach-session", "-t", "=\(session)"])
    }

    func waitUntil(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func followsTheSession() async throws {
        try tmux("new-session", "-d", "-s", "hauntty", "-x", "100", "-y", "30", "top")
        defer { _ = try? tmux("kill-server") }
        let pane = try attachPane(to: "hauntty")
        defer { pane.detach() }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, store: store) { pane.name }
        client.start()
        defer { client.stop() }

        #expect(await waitUntil { store.windows.map(\.title) == ["top"] })
        let first = try #require(store.windows.first?.id)
        #expect(store.activeID == first)

        // A new window becomes a tab, named after its process.
        try tmux("new-window", "-d", "-t", "hauntty:", ping)
        #expect(await waitUntil { store.windows.map(\.title) == ["top", "ping"] })
        let second = store.windows[1].id

        // Clicking a tab selects the window in tmux.
        client.selectWindow(second)
        #expect(store.activeID == second)
        #expect(await waitUntil {
            (try? tmux("display-message", "-p", "-t", "hauntty:", "#{window_id}")) == second
        })

        // Selecting from tmux moves the active tab.
        try tmux("select-window", "-t", first)
        #expect(await waitUntil { store.activeID == first })

        // The title follows the focused split, and the pane count follows
        // splits.
        try tmux("split-window", "-t", first, ping)
        #expect(await waitUntil { store.windows.first?.title == "ping" })
        #expect(store.windows.first?.paneCount == 2)
        try tmux("split-window", "-d", "-t", first, "cat")
        #expect(await waitUntil { store.windows.first?.paneCount == 3 })
        let panes = try tmux("list-panes", "-t", first, "-F", "#{pane_id}").split(separator: "\n").map(String.init)
        #expect(store.windows.first?.paneIDs == panes)
        #expect(store.windows.first?.activePaneID == (try tmux("display-message", "-p", "-t", first, "#{pane_id}")))
        try tmux("select-pane", "-t", "\(first).0")
        #expect(await waitUntil { store.windows.first?.title == "top" })

        // The focused pane's process and name follow a pane switch at once.
        // They do not wait for the subscription, which tmux checks once a
        // second, or for tmux to rename the window, which it does at most
        // once every 500 ms and the printing panes keep it busy with.
        #expect(await waitUntil { store.windows.first?.command == "top" })
        try await Task.sleep(for: .milliseconds(1100))
        for (pane, name) in [("1", "ping"), ("0", "top"), ("1", "ping"), ("0", "top")] {
            try tmux("select-pane", "-t", "\(first).\(pane)")
            #expect(await waitUntil(within: .milliseconds(150)) {
                store.windows.first?.command == name && store.windows.first?.title == name
            })
        }

        // A program sets the window's status through a window option.
        try tmux("set-option", "-w", "-t", first, "@state", "blocked")
        #expect(await waitUntil { store.windows.first?.status == .blocked })
        try tmux("set-option", "-w", "-u", "-t", first, "@state")
        #expect(await waitUntil { store.windows.first?.status == nil })

        // Done shows only on background tabs. It stays until the user
        // switches to the window, from tmux or by clicking the tab.
        try tmux("set-option", "-w", "-t", second, "@state", "done")
        #expect(await waitUntil { store.windows.map(\.status) == [nil, .done] })
        try tmux("select-window", "-t", second)
        #expect(await waitUntil { store.windows.map(\.status) == [nil, nil] })
        try tmux("set-option", "-w", "-t", first, "@state", "done")
        #expect(await waitUntil { store.windows.map(\.status) == [.done, nil] })
        client.selectWindow(first)
        #expect(await waitUntil { store.windows.map(\.status) == [nil, nil] })
        #expect(try tmux("show-options", "-w", "-v", "-t", first, "@state").isEmpty)

        // The active window clears done as soon as it gets it, but keeps
        // working.
        try tmux("set-option", "-w", "-t", first, "@state", "working")
        #expect(await waitUntil { store.windows.first?.status == .working })
        try tmux("set-option", "-w", "-t", first, "@state", "done")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.windows.first?.status == nil)
        #expect(try tmux("show-options", "-w", "-v", "-t", first, "@state").isEmpty)

        // A window the user renamed shows its name. Turning automatic-rename
        // back on lets tmux name it after the process again.
        try tmux("rename-window", "-t", first, "api server")
        #expect(await waitUntil { store.windows.first?.title == "api server" })
        #expect(store.windows.first?.command == "top")
        try tmux("set-option", "-w", "-t", first, "automatic-rename", "on")
        #expect(await waitUntil { store.windows.first?.title == "top" })

        // A window tmux named "tmux" by itself shows its process, but a
        // window the user named "tmux" keeps the name.
        try tmux("rename-window", "-t", first, "tmux")
        try tmux("set-option", "-w", "-t", first, "automatic-rename", "on")
        try tmux("rename-window", "-t", second, "tmux")
        #expect(await waitUntil { store.windows.map(\.title) == ["top", "tmux"] })
        try tmux("set-option", "-w", "-t", second, "automatic-rename", "on")
        #expect(await waitUntil { store.windows.map(\.title) == ["top", "ping"] })

        // Moving a window reorders the tabs.
        try tmux("move-window", "-s", second, "-t", "hauntty:7")
        try tmux("move-window", "-s", first, "-t", "hauntty:9")
        #expect(await waitUntil { store.windows.map(\.index) == [7, 9] })
        #expect(store.windows.map(\.id) == [second, first])

        // Killing a window removes its tab.
        try tmux("kill-window", "-t", second)
        #expect(await waitUntil { store.windows.map(\.id) == [first] })
    }

    @Test func iconChangesWithTheTitleWhenAProgramStartsAndEnds() async throws {
        try tmux("new-session", "-d", "-s", "hauntty", "-x", "100", "-y", "30", "zsh -f")
        defer { _ = try? tmux("kill-server") }
        let pane = try attachPane(to: "hauntty")
        defer { pane.detach() }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, store: store) { pane.name }
        client.start()
        defer { client.stop() }
        #expect(await waitUntil { store.windows.first?.command == "zsh" })

        // tmux renames the window about half a second after the program
        // starts, and the pane subscription reports it up to a second
        // later. The icon must not wait for the subscription.
        for (keys, name) in [(["top", "Enter"], "top"), (["q"], "zsh"), (["top", "Enter"], "top")] {
            try tmux(["send-keys", "-t", "hauntty"] + keys)
            #expect(await waitUntil { store.windows.first?.title == name })
            #expect(await waitUntil(within: .milliseconds(100)) { store.windows.first?.command == name })
        }
    }

    @Test func waitsForThePaneToAttach() async throws {
        defer { _ = try? tmux("kill-server") }

        // The pane's client name is not known until its tmux starts.
        var paneName: String?
        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, store: store) { paneName }
        client.start()
        defer { client.stop() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(store.windows.isEmpty)

        // Another session exists before the pane's, so the client first
        // attaches to the wrong one. Its tabs must not show.
        try tmux("new-session", "-d", "-s", "other", ping)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.windows.isEmpty)

        try tmux("new-session", "-d", "-s", "hauntty", "top")
        let pane = try attachPane(to: "hauntty")
        defer { pane.detach() }
        paneName = pane.name
        #expect(await waitUntil { store.windows.map(\.title) == ["top"] })
    }

    @Test func followsThePaneToAnotherSession() async throws {
        try tmux("new-session", "-d", "-s", "work", "-x", "100", "-y", "30", "top")
        try tmux("new-session", "-d", "-s", "play", "-x", "100", "-y", "30", ping)
        defer { _ = try? tmux("kill-server") }
        let pane = try attachPane(to: "work")
        defer { pane.detach() }
        // A client on another session, attached last, so tmux would pick
        // its session for a client attaching without a target.
        let other = try attachPane(to: "play")
        defer { other.detach() }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, store: store) { pane.name }
        client.start()
        defer { client.stop() }
        #expect(await waitUntil { store.windows.map(\.title) == ["top"] })

        // The pane switches session, as with `switch-client` or choose-tree.
        try tmux("switch-client", "-c", pane.name, "-t", "=play")
        #expect(await waitUntil { store.windows.map(\.title) == ["ping"] })

        // Clicking a tab selects the window in the pane's session.
        try tmux("new-window", "-d", "-t", "play:", "top")
        #expect(await waitUntil { store.windows.map(\.title) == ["ping", "top"] })
        client.selectWindow(store.windows[1].id)
        #expect(await waitUntil {
            (try? tmux("display-message", "-p", "-c", pane.name, "#{window_name}")) == "top"
        })

        // Other clients switching session do not move the tabs.
        try tmux("switch-client", "-c", other.name, "-t", "=work")
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.windows.map(\.title) == ["ping", "top"])
    }
}

/// A control-mode tmux client, named `client-<pid>` by tmux.
final class PaneClient {
    private let process = Process()
    private let input = Pipe()

    init(arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: tmuxPath!)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = environment
        // Control mode exits when its input closes, so keep the pipe open.
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var name: String { "client-\(process.processIdentifier)" }

    func detach() {
        try? input.fileHandleForWriting.close()
        process.terminate()
    }
}
