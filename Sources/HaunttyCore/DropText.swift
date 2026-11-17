import Foundation

/// Turns what is dropped on the terminal into the text to paste, the way
/// Ghostty does (macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift).
/// A file becomes its shell-escaped path, so a program like Claude Code reads
/// a dropped image as an attachment.
public enum DropText {
    /// One dropped item: a file or a piece of text.
    public enum Item: Equatable, Sendable {
        case file(path: String)
        case text(String)
    }

    /// The text to paste for the dropped items, separated by spaces, or nil
    /// when nothing was dropped.
    public static func text(for items: [Item]) -> String? {
        guard !items.isEmpty else { return nil }
        return items.map { item in
            switch item {
            case .file(let path): escape(path)
            case .text(let text): text
            }
        }.joined(separator: " ")
    }

    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Prefix each character the shell treats specially with a backslash.
    /// Backslash comes first, so the backslashes added for the other
    /// characters are not escaped again.
    public static func escape(_ path: String) -> String {
        var result = path
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}
