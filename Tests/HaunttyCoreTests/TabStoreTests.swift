import Testing
@testable import HaunttyCore

@MainActor
@Suite struct TabStoreTests {
    @Test func sortsWindowsByIndexAndSetsTheActiveOne() {
        let store = TabStore()
        store.applyWindowList([
            "@4|3|0|1||%4|%4 |nvim|nvim",
            "@0|0|0|3|done|%1|%0 %1 %2 |zsh|zsh",
            "@2|1|1|2|working|%3|%3 %5 |node|claude",
        ])
        #expect(store.windows == [
            TmuxWindow(
                id: "@0", index: 0, title: "zsh", paneCount: 3, status: .done,
                activePaneID: "%1", paneIDs: ["%0", "%1", "%2"]),
            TmuxWindow(
                id: "@2", index: 1, title: "claude", command: "node", paneCount: 2, status: .working,
                activePaneID: "%3", paneIDs: ["%3", "%5"]),
            TmuxWindow(id: "@4", index: 3, title: "nvim", paneCount: 1, activePaneID: "%4", paneIDs: ["%4"]),
        ])
        #expect(store.activeID == "@2")
    }

    @Test func keepsSeparatorsInTitlesAndSkipsMalformedLines() {
        let store = TabStore()
        store.applyWindowList(
            ["@1|0|1|1|bogus|%1|%1 |a|a|b", "garbage", "@2|x|0|1||%2|%2 |zsh|zsh",
             "@5|1|0|x||%5|%5 |zsh|zsh", "%1|1|0|1||%1|%1 |zsh|zsh", "@3|2|0|1|blocked|%3|%3 ||"])
        #expect(store.windows == [
            TmuxWindow(id: "@1", index: 0, title: "a|b", command: "a", activePaneID: "%1", paneIDs: ["%1"]),
            TmuxWindow(id: "@3", index: 2, title: "", status: .blocked, activePaneID: "%3", paneIDs: ["%3"]),
        ])
    }

    @Test func replacesTheWindowsOnEveryReload() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|zsh", "@1|1|0|1||%1|%1 |zsh|zsh"])
        store.applyWindowList(["@1|0|1|1||%1|%1 |top|top"])
        #expect(store.windows == [TmuxWindow(id: "@1", index: 0, title: "top", activePaneID: "%1", paneIDs: ["%1"])])
        #expect(store.activeID == "@1")
    }

    @Test func setActiveIgnoresUnknownWindows() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|zsh", "@1|1|0|1||%1|%1 |zsh|zsh"])
        store.setActive("@1")
        #expect(store.activeID == "@1")
        store.setActive("@9")
        #expect(store.activeID == "@1")
    }

    @Test func titlesTabsAfterTheClaudeSessionInTheWindow() {
        let store = TabStore()
        store.applyWindowList([
            "@0|0|1|2||%1|%0 %1 |zsh|zsh",
            "@1|1|0|2||%2|%2 %3 |2.1.325|2.1.325",
            "@2|2|0|1||%4|%4 |zsh|zsh",
        ])
        store.applyClaudeSessions([
            "%0": ClaudeSession(pid: 1, paneID: "%0", name: "hauntty-c4", isNamed: false),
            "%2": ClaudeSession(pid: 2, paneID: "%2", name: "slack-mentions", isNamed: true),
            "%3": ClaudeSession(pid: 3, paneID: "%3", name: "other", isNamed: true),
        ])
        // A session in an unfocused split still names the tab.
        #expect(store.tabTitle(for: store.windows[0]) == "Claude")
        // The focused pane's session wins over another one in the window.
        #expect(store.tabTitle(for: store.windows[1]) == "slack-mentions")
        #expect(store.tabTitle(for: store.windows[2]) == "zsh")
    }

    @Test func subscriptionValuesWinOverReloads() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|zsh"])
        #expect(store.applyReport(windowID: "@0", value: "0||zsh") == .applied)

        // A reload sees a status the subscription never reported. tmux will
        // not report the status going back to unset, so the reload must not
        // win.
        store.applyWindowList(["@0|0|1|1|done|%0|%0 |zsh|zsh"])
        #expect(store.windows[0].status == nil)

        #expect(store.applyReport(windowID: "@0", value: "0|working|my|tab") == .applied)
        #expect(store.windows[0].status == .working)
        #expect(store.windows[0].title == "my|tab")
    }

    @Test func showsTheFocusedPanesProcessAsSoonAsTheFocusMoves() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|2||%0|%0 %1 |zsh|zsh"])
        store.applyPaneReport(paneID: "%0", value: "zsh")
        store.applyPaneReport(paneID: "%1", value: "nvim")
        #expect(store.windows[0].command == "zsh")

        store.applyActivePane(windowID: "@0", paneID: "%1")
        #expect(store.windows[0].activePaneID == "%1")
        #expect(store.windows[0].command == "nvim")

        // A reload that catches a process the subscription never reported
        // does not win, since tmux would not report it going away.
        store.applyWindowList(["@0|0|1|2||%1|%0 %1 |git|nvim"])
        #expect(store.windows[0].command == "nvim")

        // A new pane shows the reload's process until it is reported.
        store.applyWindowList(["@0|0|1|3||%2|%0 %1 %2 |zsh|zsh"])
        #expect(store.windows[0].command == "zsh")
        store.applyPaneReport(paneID: "%2", value: "top")
        #expect(store.windows[0].command == "top")
    }

    @Test func subscriptionAsksForAReloadForNewAndMovedWindows() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|zsh"])
        #expect(store.applyReport(windowID: "@1", value: "1||zsh") == .needsReload)
        #expect(store.applyReport(windowID: "@0", value: "5||zsh") == .needsReload)
        #expect(store.applyReport(windowID: "@0", value: "garbage") == .needsReload)
    }

    @Test func titlesClaudeByItsVersionBeforeItsSessionFileExists() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |2.1.325|2.1.325", "@1|1|0|1||%1|%1 |zsh|1.2"])
        #expect(store.tabTitle(for: store.windows[0]) == "Claude")
        #expect(store.runsClaude(store.windows[0]))
        // Only a full version number counts.
        #expect(store.tabTitle(for: store.windows[1]) == "1.2")
        #expect(!store.runsClaude(store.windows[1]))
    }

    @Test func renamesApplyAtOnceExceptTheNameOfAStartingPane() {
        let store = TabStore()
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|2.1.325"])
        #expect(store.applyReport(windowID: "@0", value: "0||2.1.325") == .applied)
        store.applyRename(windowID: "@0", name: "zsh")
        #expect(store.windows[0].title == "zsh")
        // A reload does not undo it.
        store.applyWindowList(["@0|0|1|1||%0|%0 |zsh|2.1.325"])
        #expect(store.windows[0].title == "zsh")
        store.applyRename(windowID: "@0", name: "tmux")
        #expect(store.windows[0].title == "zsh")
    }
}
