import Foundation
import Testing
@testable import HaunttyCore

@MainActor
@Suite struct ClaudeSessionTests {
    @Test func readsTheIdStateNamePaneAndTitle() {
        #expect(ClaudeSession(line: "s1\tdone\tslack-mentions\t\t") == ClaudeSession(
            id: "s1", status: .done, name: "slack-mentions"))
        #expect(ClaudeSession(line: "s2\tworking\ttile-09\tdefault:%3\t✳ Divvy replacement") == ClaudeSession(
            id: "s2", status: .working, name: "tile-09", pane: "default:%3", paneTitle: "✳ Divvy replacement"))
        #expect(ClaudeSession(line: "s3\tblocked") == ClaudeSession(id: "s3", status: .blocked, name: ""))
        #expect(ClaudeSession(line: "s4\tbogus\tname") == nil)
        #expect(ClaudeSession(line: "\tdone\tname") == nil)
        #expect(ClaudeSession(line: "") == nil)
    }

    @Test func loadsTheFileAndRemovesOnlyUnchangedSessions() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hauntty-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ClaudeSessionFile(url: folder.appending(path: "claude-sessions"))
        var reported: [[ClaudeSession]] = []
        file.onChange = { reported.append($0) }
        file.start()
        defer { file.stop() }
        #expect(reported == [[]])

        try "a\tdone\talpha\t\t\nb\tworking\tbeta\t\t\ngarbage\n".write(to: file.url, atomically: true, encoding: .utf8)
        let sessions = file.load()
        #expect(sessions == [
            ClaudeSession(id: "a", status: .done, name: "alpha"),
            ClaudeSession(id: "b", status: .working, name: "beta"),
        ])

        // A hook wrote a new state after the sessions were read.
        try "a\tworking\talpha\t\t\nb\tworking\tbeta\t\t\n".write(to: file.url, atomically: true, encoding: .utf8)
        file.remove(sessions[0])
        #expect(file.load().map(\.id) == ["a", "b"])

        file.remove(file.load()[1])
        #expect(file.load() == [ClaudeSession(id: "a", status: .working, name: "alpha")])
    }

    /// The hook script writes what `ClaudeSessionFile` reads.
    @Test func readsWhatTheHookScriptWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hauntty-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
        try #"{"sessionId":"s1","name":"alpha"}"#.write(
            to: home.appending(path: ".claude/sessions/1.json"), atomically: true, encoding: .utf8)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/hauntty.sh")

        func hook(_ event: String, _ sessionID: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = folder.path + "/"
            environment["HOME"] = home.path
            environment["TMUX"] = nil
            environment["TMUX_PANE"] = nil
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"\#(event)","session_id":"\#(sessionID)"}"#.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        let file = ClaudeSessionFile(url: folder.appending(path: "hauntty/claude-sessions"))
        try hook("UserPromptSubmit", "s1")
        try hook("Stop", "s2")
        #expect(file.load() == [
            ClaudeSession(id: "s1", status: .working, name: "alpha"),
            ClaudeSession(id: "s2", status: .done, name: ""),
        ])
        try hook("Stop", "s1")
        try hook("SessionEnd", "s2")
        #expect(file.load() == [ClaudeSession(id: "s1", status: .done, name: "alpha")])
    }
}

@MainActor
@Suite struct TabStoreClaudeSessionTests {
    /// Window @0 has a Claude pane %0 and a shell %1, @1 a Claude pane %2,
    /// and @2 a shell %3 that kept the title of a Claude session it ran.
    private func store() -> TabStore {
        let store = TabStore()
        store.applyWindowList([
            "@0|0|1|2||%0|%0 %1 |2.1.326|2.1.326",
            "@1|1|0|1||%2|%2 |2.1.326|2.1.326",
            "@2|2|0|1||%3|%3 |zsh|zsh",
        ])
        store.applyPaneReport(paneID: "%0", value: "2.1.326|✳ alpha")
        store.applyPaneReport(paneID: "%1", value: "zsh|beta")
        store.applyPaneReport(paneID: "%2", value: "2.1.326|beta")
        store.applyPaneReport(paneID: "%3", value: "zsh|✳ alpha")
        return store
    }

    @Test func showsTheSessionsTheClaudePanesShow() {
        let store = store()
        store.applyClaudeSessions([
            ClaudeSession(id: "a", status: .working, name: "alpha"),
            ClaudeSession(id: "b", status: .done, name: "beta"),
        ])
        #expect(store.windows.map { store.status(for: $0) } == [.working, .done, nil])
    }

    @Test func followsAPaneThatSwitchesSession() {
        let store = store()
        store.applyClaudeSessions([
            ClaudeSession(id: "a", status: .working, name: "alpha"),
            ClaudeSession(id: "b", status: .done, name: "beta"),
        ])
        store.applyPaneReport(paneID: "%0", value: "2.1.326|✳ gamma")
        #expect(store.windows.map { store.status(for: $0) } == [nil, .done, nil])
        store.applyPaneReport(paneID: "%0", value: "2.1.326|beta")
        #expect(store.windows.map { store.status(for: $0) } == [.done, .done, nil])
    }

    @Test func showsASessionRunningInAPaneWhileThePaneKeepsItsTitle() {
        let store = store()
        store.applyClaudeSessions([
            ClaudeSession(id: "i", status: .working, name: "src-67", pane: "default:%2", paneTitle: "✳ beta"),
        ])
        #expect(store.windows.map { store.status(for: $0) } == [nil, .working, nil])
        store.applyPaneReport(paneID: "%2", value: "2.1.326|other")
        #expect(store.windows.map { store.status(for: $0) } == [nil, nil, nil])
        // The same pane id on another tmux server is another pane.
        let other = TabStore(socketName: "work")
        other.applyWindowList(["@1|1|1|1||%2|%2 |2.1.326|2.1.326"])
        other.applyPaneReport(paneID: "%2", value: "2.1.326|beta")
        other.applyClaudeSessions(store.claudeSessions)
        #expect(other.windows.map { other.status(for: $0) } == [nil])
    }

    @Test func showsTheHighestStatusInAWindow() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|2|working|%0|%0 %1 |2.1.326|2.1.326"])
        store.applyPaneReport(paneID: "%0", value: "2.1.326|alpha")
        store.applyPaneReport(paneID: "%1", value: "2.1.326|beta")
        store.applyClaudeSessions([ClaudeSession(id: "a", status: .done, name: "alpha")])
        #expect(store.status(for: store.windows[0]) == .done)
        store.applyClaudeSessions([
            ClaudeSession(id: "a", status: .done, name: "alpha"),
            ClaudeSession(id: "b", status: .blocked, name: "beta"),
        ])
        #expect(store.status(for: store.windows[0]) == .blocked)
    }

    @Test func seesOnlyTheActiveTabsSessionsThatWantAttention() {
        let store = store()
        let sessions = [
            ClaudeSession(id: "a", status: .done, name: "alpha"),
            ClaudeSession(id: "b", status: .blocked, name: "beta"),
        ]
        store.applyClaudeSessions(sessions)
        #expect(store.seenClaudeSessions() == [sessions[0]])
        store.setActive("@1")
        #expect(store.seenClaudeSessions() == [sessions[1]])
        store.applyClaudeSessions([ClaudeSession(id: "b", status: .working, name: "beta")])
        #expect(store.seenClaudeSessions() == [])
    }
}
