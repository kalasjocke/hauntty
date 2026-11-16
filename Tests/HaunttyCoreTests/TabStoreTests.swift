import Testing
@testable import HaunttyCore

@MainActor
@Suite struct TabStoreTests {
    @Test func sortsWindowsByIndexAndSetsTheActiveOne() {
        let store = TabStore()
        store.applyWindowList(["@4|3|0|1|nvim", "@0|0|0|3|zsh", "@2|1|1|2|claude"])
        #expect(store.windows == [
            TmuxWindow(id: "@0", index: 0, title: "zsh", paneCount: 3),
            TmuxWindow(id: "@2", index: 1, title: "claude", paneCount: 2),
            TmuxWindow(id: "@4", index: 3, title: "nvim", paneCount: 1),
        ])
        #expect(store.activeID == "@2")
    }

    @Test func keepsSeparatorsInTitlesAndSkipsMalformedLines() {
        let store = TabStore()
        store.applyWindowList(
            ["@1|0|1|1|a|b", "garbage", "@2|x|0|1|zsh", "@5|1|0|x|zsh", "%1|1|0|1|zsh", "@3|2|0|1|"])
        #expect(store.windows == [
            TmuxWindow(id: "@1", index: 0, title: "a|b"),
            TmuxWindow(id: "@3", index: 2, title: ""),
        ])
    }

    @Test func replacesTheWindowsOnEveryReload() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1|zsh", "@1|1|0|1|zsh"])
        store.applyWindowList(["@1|0|1|1|top"])
        #expect(store.windows == [TmuxWindow(id: "@1", index: 0, title: "top")])
        #expect(store.activeID == "@1")
    }

    @Test func setActiveIgnoresUnknownWindows() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1|zsh", "@1|1|0|1|zsh"])
        store.setActive("@1")
        #expect(store.activeID == "@1")
        store.setActive("@9")
        #expect(store.activeID == "@1")
    }
}
