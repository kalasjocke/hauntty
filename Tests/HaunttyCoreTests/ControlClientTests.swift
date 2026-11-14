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

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func followsTheSession() async throws {
        try tmux("new-session", "-d", "-s", "hauntty", "-x", "100", "-y", "30", "top")
        defer { _ = try? tmux("kill-server") }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, session: "hauntty", store: store)
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
        try tmux("select-pane", "-t", "\(first).0")
        #expect(await waitUntil { store.windows.first?.title == "top" })

        // A program sets the window's status through a window option.
        try tmux("set-option", "-w", "-t", first, "@hauntty-status", "blocked")
        #expect(await waitUntil { store.windows.first?.status == .blocked })
        try tmux("set-option", "-w", "-u", "-t", first, "@hauntty-status")
        #expect(await waitUntil { store.windows.first?.status == nil })

        // Done shows only on background tabs. It stays until the user
        // switches to the window, from tmux or by clicking the tab.
        try tmux("set-option", "-w", "-t", second, "@hauntty-status", "done")
        #expect(await waitUntil { store.windows.map(\.status) == [nil, .done] })
        try tmux("select-window", "-t", second)
        #expect(await waitUntil { store.windows.map(\.status) == [nil, nil] })
        try tmux("set-option", "-w", "-t", first, "@hauntty-status", "done")
        #expect(await waitUntil { store.windows.map(\.status) == [.done, nil] })
        client.selectWindow(first)
        #expect(await waitUntil { store.windows.map(\.status) == [nil, nil] })
        #expect(try tmux("show-options", "-w", "-v", "-t", first, "@hauntty-status").isEmpty)

        // The active window clears done as soon as it gets it, but keeps
        // working.
        try tmux("set-option", "-w", "-t", first, "@hauntty-status", "working")
        #expect(await waitUntil { store.windows.first?.status == .working })
        try tmux("set-option", "-w", "-t", first, "@hauntty-status", "done")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.windows.first?.status == nil)
        #expect(try tmux("show-options", "-w", "-v", "-t", first, "@hauntty-status").isEmpty)

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

    @Test func waitsForTheSessionToExist() async throws {
        defer { _ = try? tmux("kill-server") }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, session: "hauntty", store: store)
        client.start()
        defer { client.stop() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(store.windows.isEmpty)

        try tmux("new-session", "-d", "-s", "hauntty", "top")
        #expect(await waitUntil { store.windows.map(\.title) == ["top"] })
    }

    @Test func doesNotAttachToASessionThatOnlyStartsWithTheName() async throws {
        try tmux("new-session", "-d", "-s", "hauntty-extra", "sleep 600")
        defer { _ = try? tmux("kill-server") }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, session: "hauntty", store: store)
        client.start()
        defer { client.stop() }

        try await Task.sleep(for: .milliseconds(500))
        #expect(store.windows.isEmpty)
    }
}
