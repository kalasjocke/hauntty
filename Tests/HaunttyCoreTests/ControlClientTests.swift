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
    let socket = "hauntty-test-\(getpid())"

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
        try tmux("new-session", "-d", "-s", "hauntty", "-x", "100", "-y", "30", "sleep 600")
        defer { _ = try? tmux("kill-server") }

        let store = TabStore()
        let client = ControlClient(executable: tmuxPath!, socketName: socket, session: "hauntty", store: store)
        client.start()
        defer { client.stop() }

        #expect(await waitUntil { store.windows.map(\.title) == ["sleep"] })
        let first = try #require(store.windows.first?.id)
        #expect(store.activeID == first)

        // A new window becomes a tab, named after its process.
        try tmux("new-window", "-d", "-t", "hauntty:", "top")
        #expect(await waitUntil { store.windows.map(\.title) == ["sleep", "top"] })
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

        // The title follows the focused split.
        try tmux("split-window", "-t", first, "cat")
        #expect(await waitUntil { store.windows.first?.title == "cat" })
        try tmux("select-pane", "-t", "\(first).0")
        #expect(await waitUntil { store.windows.first?.title == "sleep" })

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

        try tmux("new-session", "-d", "-s", "hauntty", "sleep 600")
        #expect(await waitUntil { store.windows.map(\.title) == ["sleep"] })
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
