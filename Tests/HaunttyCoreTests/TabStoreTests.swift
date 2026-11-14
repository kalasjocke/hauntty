import Testing
@testable import HaunttyCore

@MainActor
@Suite struct TabStoreTests {
    @Test func sortsWindowsByIndexAndSetsTheActiveOne() {
        let store = TabStore()
        store.applyWindowList(
            ["@4|3|0|1||nvim|nvim", "@0|0|0|3|done|zsh|zsh", "@2|1|1|2|working|node|claude"])
        #expect(store.windows == [
            TmuxWindow(id: "@0", index: 0, title: "zsh", paneCount: 3, status: .done),
            TmuxWindow(id: "@2", index: 1, title: "claude", command: "node", paneCount: 2, status: .working),
            TmuxWindow(id: "@4", index: 3, title: "nvim", paneCount: 1),
        ])
        #expect(store.activeID == "@2")
    }

    @Test func keepsSeparatorsInTitlesAndSkipsMalformedLines() {
        let store = TabStore()
        store.applyWindowList(
            ["@1|0|1|1|bogus|a|a|b", "garbage", "@2|x|0|1||zsh|zsh", "@5|1|0|x||zsh|zsh",
             "%1|1|0|1||zsh|zsh", "@3|2|0|1|blocked||"])
        #expect(store.windows == [
            TmuxWindow(id: "@1", index: 0, title: "a|b", command: "a"),
            TmuxWindow(id: "@3", index: 2, title: "", status: .blocked),
        ])
    }

    @Test func replacesTheWindowsOnEveryReload() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||zsh|zsh", "@1|1|0|1||zsh|zsh"])
        store.applyWindowList(["@1|0|1|1||top|top"])
        #expect(store.windows == [TmuxWindow(id: "@1", index: 0, title: "top")])
        #expect(store.activeID == "@1")
    }

    @Test func setActiveIgnoresUnknownWindows() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||zsh|zsh", "@1|1|0|1||zsh|zsh"])
        store.setActive("@1")
        #expect(store.activeID == "@1")
        store.setActive("@9")
        #expect(store.activeID == "@1")
    }
}
