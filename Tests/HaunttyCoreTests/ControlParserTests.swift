import Testing
@testable import HaunttyCore

/// Recorded from tmux 3.8: attach with `-f ignore-size,no-output`, subscribe,
/// list windows, send an unknown command, then add, select, split, move and
/// kill windows from another client.
private let recording = """
    %begin 1794772901 315 0
    %end 1794772901 315 0
    %session-changed $0 hauntty
    %begin 1794772901 317 1
    %end 1794772901 317 1
    %begin 1794772901 318 1
    @0|0|1|zsh
    %end 1794772901 318 1
    %begin 1794772901 319 1
    parse error: unknown command: bogus-cmd
    %error 1794772901 319 1
    %window-renamed @0 zsh
    %window-add @1
    %window-renamed @1 tmux
    %session-window-changed $0 @1
    %layout-change @1 468d,100x30,0,0[100x15,0,0,1,100x14,0,16,2] 468d,100x30,0,0[100x15,0,0,1,100x14,0,16,2] *
    %subscription-changed tabs $0 @0 0 - : 0 zsh
    %subscription-changed tabs $0 @1 1 - : 1 zsh
    %window-renamed @1 zsh
    %window-add @1
    %session-window-changed $0 @1
    %window-close @1
    %subscription-changed tabs $0 @1 5 - : 5 zsh
    %session-window-changed $0 @0
    %window-close @1
    %exit

    """

private let expected: [ControlEvent] = [
    .reply(ControlReply(number: 315, fromClient: false, isError: false, lines: [])),
    .notification(.sessionChanged(sessionID: "$0", name: "hauntty")),
    .reply(ControlReply(number: 317, fromClient: true, isError: false, lines: [])),
    .reply(ControlReply(number: 318, fromClient: true, isError: false, lines: ["@0|0|1|zsh"])),
    .reply(ControlReply(
        number: 319, fromClient: true, isError: true, lines: ["parse error: unknown command: bogus-cmd"])),
    .notification(.windowRenamed(windowID: "@0", name: "zsh")),
    .notification(.windowAdd(windowID: "@1")),
    .notification(.windowRenamed(windowID: "@1", name: "tmux")),
    .notification(.sessionWindowChanged(sessionID: "$0", windowID: "@1")),
    .notification(.layoutChange(windowID: "@1")),
    .notification(.subscriptionChanged(name: "tabs", windowID: "@0", paneID: nil, value: "0 zsh")),
    .notification(.subscriptionChanged(name: "tabs", windowID: "@1", paneID: nil, value: "1 zsh")),
    .notification(.windowRenamed(windowID: "@1", name: "zsh")),
    .notification(.windowAdd(windowID: "@1")),
    .notification(.sessionWindowChanged(sessionID: "$0", windowID: "@1")),
    .notification(.windowClose(windowID: "@1")),
    .notification(.subscriptionChanged(name: "tabs", windowID: "@1", paneID: nil, value: "5 zsh")),
    .notification(.sessionWindowChanged(sessionID: "$0", windowID: "@0")),
    .notification(.windowClose(windowID: "@1")),
    .notification(.exit(reason: nil)),
]

@Suite struct ControlParserTests {
    @Test func parsesRecordedSession() {
        var parser = ControlParser()
        #expect(parser.feed(Array(recording.utf8)) == expected)
    }

    @Test func parsesOneByteAtATime() {
        var parser = ControlParser()
        var events: [ControlEvent] = []
        for byte in recording.utf8 {
            events += parser.feed([byte])
        }
        #expect(events == expected)
    }

    @Test func waitsForTheEndOfALine() {
        var parser = ControlParser()
        #expect(parser.feed(Array("%window-add @".utf8)).isEmpty)
        #expect(parser.feed(Array("7\n".utf8)) == [.notification(.windowAdd(windowID: "@7"))])
    }

    @Test func keepsOutputLinesThatLookLikeNotifications() {
        var parser = ControlParser()
        let input = """
            %begin 1 5 1
            %window-add @9
            %end 1 4 1
            %end 1 5 1

            """
        #expect(parser.feed(Array(input.utf8)) == [
            .reply(ControlReply(
                number: 5, fromClient: true, isError: false, lines: ["%window-add @9", "%end 1 4 1"])),
        ])
    }

    @Test func stripsCarriageReturns() {
        var parser = ControlParser()
        #expect(parser.feed(Array("%window-close @2\r\n".utf8)) == [
            .notification(.windowClose(windowID: "@2")),
        ])
    }

    @Test func parsesSubscriptionValuesWithColonsAndSessionAndPaneSubscriptions() {
        var parser = ControlParser()
        let input = """
            %subscription-changed tabs $0 @3 2 - : 2 a : b
            %subscription-changed status $0 - - - : on
            %subscription-changed panes $0 @3 2 %7 : nvim

            """
        #expect(parser.feed(Array(input.utf8)) == [
            .notification(.subscriptionChanged(name: "tabs", windowID: "@3", paneID: nil, value: "2 a : b")),
            .notification(.subscriptionChanged(name: "status", windowID: nil, paneID: nil, value: "on")),
            .notification(.subscriptionChanged(name: "panes", windowID: "@3", paneID: "%7", value: "nvim")),
        ])
    }

    @Test func parsesSessionNamesWithSpacesAndExitReasons() {
        var parser = ControlParser()
        let input = """
            %session-changed $4 my session
            %client-session-changed /dev/ttys012 $4 my session
            %exit server exited

            """
        #expect(parser.feed(Array(input.utf8)) == [
            .notification(.sessionChanged(sessionID: "$4", name: "my session")),
            .notification(.clientSessionChanged(client: "/dev/ttys012", sessionID: "$4", name: "my session")),
            .notification(.exit(reason: "server exited")),
        ])
    }
}
