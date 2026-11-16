import Foundation
import Testing
@testable import HaunttyCore

@Suite struct ClaudeSessionTests {
    func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func readsNamedAndDerivedSessions() {
        let named = ClaudeSession.parse(json([
            "pid": 44280, "tmux": "0:@36.%121", "name": "slack-mentions", "nameSource": "user",
            "status": "busy",
        ]))
        #expect(named == ClaudeSession(pid: 44280, paneID: "%121", name: "slack-mentions", isNamed: true))
        #expect(named?.title == "slack-mentions")

        let derived = ClaudeSession.parse(json([
            "pid": 79587, "tmux": "0:@36.%121", "name": "hauntty-c4", "nameSource": "derived",
        ]))
        #expect(derived?.isNamed == false)
        #expect(derived?.title == "Claude")
    }

    @Test func skipsSessionsOutsideTmuxAndBadFiles() {
        #expect(ClaudeSession.parse(json(["pid": 1, "name": "bg", "nameSource": "user"])) == nil)
        #expect(ClaudeSession.parse(json(["pid": 1, "tmux": "0:@1"])) == nil)
        #expect(ClaudeSession.parse(Data("not json".utf8)) == nil)
    }

    @MainActor
    @Test func watcherSkipsExitedProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hauntty-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try json(["pid": 10, "tmux": "0:@1.%1", "name": "alive", "nameSource": "user"])
            .write(to: directory.appendingPathComponent("10.json"))
        try json(["pid": 11, "tmux": "0:@2.%2", "name": "gone", "nameSource": "user"])
            .write(to: directory.appendingPathComponent("11.json"))
        try Data("key".utf8).write(to: directory.appendingPathComponent("10.abc.key"))

        let store = TabStore()
        let watcher = ClaudeSessionWatcher(directory: directory, store: store, isAlive: { $0 == 10 })
        watcher.scan()
        #expect(store.claudeSessions == [
            "%1": ClaudeSession(pid: 10, paneID: "%1", name: "alive", isNamed: true),
        ])
    }

    @MainActor
    @Test func watcherFollowsFileChangesAndProcessExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hauntty-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A real process, so the watcher can see it exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier

        let store = TabStore()
        // Start before the folder exists, as on a Mac that has not run
        // Claude Code yet.
        let watcher = ClaudeSessionWatcher(directory: directory, store: store)
        watcher.start()
        defer { watcher.stop() }

        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(pid).json")
        try json(["pid": Int(pid), "tmux": "0:@1.%1", "name": "a", "nameSource": "derived"]).write(to: file)
        #expect(await waitUntil { store.claudeSessions["%1"]?.title == "Claude" })

        // Renaming the session rewrites its file in place.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: json(["pid": Int(pid), "tmux": "0:@1.%1", "name": "b", "nameSource": "user"]))
        try handle.close()
        #expect(await waitUntil { store.claudeSessions["%1"]?.title == "b" })

        // A crashed session leaves its file, but its process exits.
        process.terminate()
        #expect(await waitUntil { store.claudeSessions.isEmpty })
    }
}
