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

    @Test func subscriptionValuesWinOverReloads() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||zsh|zsh"])
        #expect(store.applyReport(windowID: "@0", value: "0||zsh|zsh") == .applied)

        // A reload sees a status the subscription never reported. tmux will
        // not report the status going back to unset, so the reload must not
        // win.
        store.applyWindowList(["@0|0|1|1|done|zsh|zsh"])
        #expect(store.windows[0].status == nil)

        #expect(store.applyReport(windowID: "@0", value: "0|working|claude|my tab") == .applied)
        #expect(store.windows[0].status == .working)
        #expect(store.windows[0].command == "claude")
        #expect(store.windows[0].title == "my tab")
    }

    @Test func subscriptionAsksForAReloadForNewAndMovedWindows() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||zsh|zsh"])
        #expect(store.applyReport(windowID: "@1", value: "1||zsh|zsh") == .needsReload)
        #expect(store.applyReport(windowID: "@0", value: "5||zsh|zsh") == .needsReload)
        #expect(store.applyReport(windowID: "@0", value: "garbage") == .needsReload)
    }

    @Test func renamesApplyAtOnceExceptTheNameOfAStartingPane() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||zsh|2.1.325"])
        #expect(store.applyReport(windowID: "@0", value: "0||2.1.325|2.1.325") == .applied)
        store.applyRename(windowID: "@0", name: "zsh")
        #expect(store.windows[0].title == "zsh")
        // A reload does not undo it.
        store.applyWindowList(["@0|0|1|1||zsh|2.1.325"])
        #expect(store.windows[0].title == "zsh")
        store.applyRename(windowID: "@0", name: "tmux")
        #expect(store.windows[0].title == "zsh")
    }
}
