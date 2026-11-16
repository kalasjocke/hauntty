import Foundation

enum Tmux {
    /// The tmux session every Hauntty window attaches to.
    static let sessionName = "hauntty"

    /// The tmux binary. Apps opened from Finder do not get the shell's PATH,
    /// so look in Homebrew's locations first.
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
    }()

    /// The command the terminal surface runs: attach to the hauntty session,
    /// creating it if needed, and hide the status bar since the tabs replace it.
    static func attachCommand() -> String {
        "\(executable) new-session -A -s \(sessionName) \\; set-option -t \(sessionName) status off"
    }
}
