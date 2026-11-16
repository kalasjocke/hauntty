import Foundation

/// The output of one command sent to tmux in control mode, between `%begin`
/// and `%end` or `%error`.
public struct ControlReply: Equatable, Sendable {
    public var number: Int
    /// True for commands this client sent. The block tmux prints on attach
    /// has this unset.
    public var fromClient: Bool
    public var isError: Bool
    public var lines: [String]

    public init(number: Int, fromClient: Bool, isError: Bool, lines: [String]) {
        self.number = number
        self.fromClient = fromClient
        self.isError = isError
        self.lines = lines
    }
}

/// The control-mode notifications Hauntty uses. The rest arrive as `other`.
public enum ControlNotification: Equatable, Sendable {
    case sessionChanged(sessionID: String, name: String)
    case sessionWindowChanged(sessionID: String, windowID: String)
    case windowAdd(windowID: String)
    case windowClose(windowID: String)
    case windowRenamed(windowID: String, name: String)
    case windowPaneChanged(windowID: String, paneID: String)
    /// A window's panes were split, closed or resized.
    case layoutChange(windowID: String)
    /// `windowID` is nil for subscriptions that are not per window.
    case subscriptionChanged(name: String, windowID: String?, value: String)
    case exit(reason: String?)
    case other(name: String, arguments: String)
}

public enum ControlEvent: Equatable, Sendable {
    case reply(ControlReply)
    case notification(ControlNotification)
}

/// Splits tmux control-mode output into replies and notifications. Feed it
/// bytes as they arrive; lines may be split across reads.
public struct ControlParser {
    private var buffer: [UInt8] = []
    private var block: ControlReply?

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [ControlEvent] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var events: [ControlEvent] = []
        var start = 0
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var end = newline
            if end > start, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
            let line = String(decoding: buffer[start..<end], as: UTF8.self)
            if let event = parse(line) { events.append(event) }
            start = newline + 1
        }
        buffer.removeFirst(start)
        return events
    }

    private mutating func parse(_ line: String) -> ControlEvent? {
        if var reply = block {
            // Inside a block only a matching %end or %error closes it. Any
            // other line is command output, even if it starts with %.
            if let guardLine = Self.guardLine(line),
               guardLine.kind == "end" || guardLine.kind == "error",
               guardLine.number == reply.number {
                reply.isError = guardLine.kind == "error"
                block = nil
                return .reply(reply)
            }
            reply.lines.append(line)
            block = reply
            return nil
        }

        if let guardLine = Self.guardLine(line), guardLine.kind == "begin" {
            block = ControlReply(
                number: guardLine.number, fromClient: guardLine.flags & 1 != 0, isError: false, lines: [])
            return nil
        }

        guard line.hasPrefix("%") else { return nil }
        let body = line.dropFirst()
        let name: Substring
        let arguments: Substring
        if let space = body.firstIndex(of: " ") {
            name = body[..<space]
            arguments = body[body.index(after: space)...]
        } else {
            name = body
            arguments = ""
        }
        return .notification(Self.notification(String(name), String(arguments)))
    }

    /// Parses `%begin`, `%end` and `%error` lines: `%kind time number flags`.
    private static func guardLine(_ line: String) -> (kind: String, number: Int, flags: Int)? {
        let fields = line.split(separator: " ")
        guard fields.count == 4,
              fields[0] == "%begin" || fields[0] == "%end" || fields[0] == "%error",
              let number = Int(fields[2]),
              let flags = Int(fields[3])
        else { return nil }
        return (String(fields[0].dropFirst()), number, flags)
    }

    private static func notification(_ name: String, _ arguments: String) -> ControlNotification {
        let words = arguments.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch name {
        case "session-changed" where words.count >= 2:
            // The session name may contain spaces.
            return .sessionChanged(sessionID: words[0], name: words.dropFirst().joined(separator: " "))
        case "session-window-changed" where words.count >= 2:
            return .sessionWindowChanged(sessionID: words[0], windowID: words[1])
        case "window-add" where words.count >= 1:
            return .windowAdd(windowID: words[0])
        case "window-close" where words.count >= 1:
            return .windowClose(windowID: words[0])
        case "window-renamed" where words.count >= 1:
            // The name may contain spaces.
            return .windowRenamed(windowID: words[0], name: words.dropFirst().joined(separator: " "))
        case "window-pane-changed" where words.count >= 2:
            return .windowPaneChanged(windowID: words[0], paneID: words[1])
        case "layout-change" where words.count >= 1:
            return .layoutChange(windowID: words[0])
        case "subscription-changed":
            // name session window index pane ... : value
            guard let separator = arguments.range(of: " : ") else { break }
            let head = arguments[..<separator.lowerBound].split(separator: " ")
            guard let subscription = head.first else { break }
            let windowID = head.count > 2 && head[2].hasPrefix("@") ? String(head[2]) : nil
            return .subscriptionChanged(
                name: String(subscription), windowID: windowID,
                value: String(arguments[separator.upperBound...]))
        case "exit":
            return .exit(reason: arguments.isEmpty ? nil : arguments)
        default:
            break
        }
        return .other(name: name, arguments: arguments)
    }
}
