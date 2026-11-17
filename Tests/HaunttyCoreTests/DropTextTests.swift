import Testing
@testable import HaunttyCore

@Suite struct DropTextTests {
    @Test func leavesAPlainPathAlone() {
        #expect(DropText.escape("/Users/me/shot.png") == "/Users/me/shot.png")
    }

    @Test func escapesSpacesAndShellCharacters() {
        #expect(DropText.escape("/tmp/Screenshot 2026-11-17 at 10.00.png")
            == #"/tmp/Screenshot\ 2026-11-17\ at\ 10.00.png"#)
        #expect(DropText.escape("/tmp/it's (1)$&.png") == #"/tmp/it\'s\ \(1\)\$\&.png"#)
    }

    @Test func escapesABackslashOnce() {
        #expect(DropText.escape(#"/tmp/a\ b"#) == #"/tmp/a\\\ b"#)
    }

    @Test func joinsItemsWithSpaces() {
        #expect(DropText.text(for: [.file(path: "/tmp/a b.png"), .file(path: "/tmp/c.png")])
            == #"/tmp/a\ b.png /tmp/c.png"#)
        #expect(DropText.text(for: [.text("hello $USER")]) == "hello $USER")
    }

    @Test func returnsNilForAnEmptyDrop() {
        #expect(DropText.text(for: []) == nil)
    }
}
