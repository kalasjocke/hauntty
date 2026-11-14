// Runtime glue for libghostty. Adapted from Ghostty's macOS app (MIT license):
// macos/Sources/Ghostty/Ghostty.App.swift.

import AppKit
import GhosttyKit
import os

let log = Logger(subsystem: "io.hauntty", category: "hauntty")

/// Owns the Ghostty config and app, and answers libghostty's runtime callbacks.
final class GhosttyApp {
    let config: ghostty_config_t
    private(set) var app: ghostty_app_t?

    init() {
        guard let config = ghostty_config_new() else {
            fatalError("ghostty_config_new failed")
        }
        // Read the user's Ghostty config, so Hauntty looks like Ghostty.
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            log.warning("ghostty config: \(String(cString: diagnostic.message), privacy: .public)")
        }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyApp.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyApp.readClipboard(
                    userdata, location: location, state: state,
                    mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyApp.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, _ in GhosttyApp.closeSurface(userdata) }
        )

        guard let app = ghostty_app_new(&runtime, config) else {
            fatalError("ghostty_app_new failed")
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }
        center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }
        center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_keyboard_changed(app)
        }
    }

    /// The terminal colors from the config.
    var backgroundColor: NSColor { color("background") ?? .windowBackgroundColor }
    var foregroundColor: NSColor { color("foreground") ?? .textColor }

    private func color(_ key: String) -> NSColor? {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1)
    }

    // MARK: Callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let state = Unmanaged<GhosttyApp>.fromOpaque(userdata!).takeUnretainedValue()
        // Called from any thread. Ticking must happen on the main thread.
        DispatchQueue.main.async {
            guard let app = state.app else { return }
            ghostty_app_tick(app)
        }
    }

    private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return nil }
        return surfaceView(from: ghostty_surface_userdata(surface))
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?) {
        guard let view = surfaceView(from: userdata) else { return }
        DispatchQueue.main.async { view.onClose?() }
    }

    /// Handle the actions Hauntty supports. Returning false tells libghostty the
    /// action was not performed. Hauntty ignores new tab, new window and split
    /// actions on purpose, since tabs only come from tmux.
    private static func action(
        _ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            surfaceView(target: target)?.window?.performClose(nil)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            surfaceView(target: target)?.setCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            surfaceView(target: target)?.cellSizeInPixels = NSSize(
                width: Double(size.width), height: Double(size.height))
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // libghostty turns on wait-after-command when the surface has a
            // command, so it reports the exit here instead of closing. Close
            // the window, unless the command failed right away (250 ms is
            // Ghostty's abnormal-command-exit-runtime default). Returning false
            // then shows the error in the terminal.
            guard action.action.child_exited.timetime_ms > 250 else { return false }
            guard let view = surfaceView(target: target) else { return false }
            DispatchQueue.main.async { view.onClose?() }
            return true

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_RENDER:
            // The tab bar shows tmux state, not terminal titles.
            return true

        default:
            return false
        }
    }

    // MARK: Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer,
        mimes: UnsafePointer<UnsafePointer<CChar>>,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = surfaceView(from: userdata)?.surface,
              location == GHOSTTY_CLIPBOARD_STANDARD else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // Hauntty only serves plain text.
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)
        let wantsText = (0..<mimesLen).contains { String(cString: mimes[$0]) == "text/plain" }
        var contents: [(mime: String, data: Data)] = []
        if wantsText, let text {
            contents.append(("text/plain", Data(text.utf8)))
        }
        let available = list && text != nil ? ["text/plain"] : []
        if contents.isEmpty && !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        completeClipboardRequest(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ask before an unsafe paste or a program reading the clipboard.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
        state: UnsafeMutableRawPointer,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = surfaceView(from: userdata), let surface = view.surface else { return }
        let c = confirm.pointee
        var contents: [(mime: String, data: Data)] = []
        if let items = c.contents {
            for i in 0..<c.contents_len {
                let item = items[i]
                let data = Data(bytes: item.data, count: item.len)
                contents.append((String(cString: item.mime), data))
            }
        }
        var available: [String] = []
        if let names = c.available {
            for i in 0..<c.available_len { available.append(String(cString: names[i])) }
        }
        let text = contents.first { $0.mime == "text/plain" }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? ""

        let alert = NSAlert()
        if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            alert.messageText = "Paste this text?"
            alert.informativeText = "It may run commands when pasted.\n\n" + text.prefix(500)
            alert.addButton(withTitle: "Paste")
        } else {
            alert.messageText = "Allow the program to read the clipboard?"
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                completeClipboardRequest(
                    surface, contents: contents, available: available, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [(mime: String, data: Data)],
        available: [String],
        state: UnsafeMutableRawPointer,
        confirmed: Bool = false
    ) {
        // Copy everything into C memory for the duration of the call.
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { free($0) } }
        func cString(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            allocations.append(UnsafeMutableRawPointer(p))
            return UnsafePointer(p)
        }

        var cContents: [ghostty_clipboard_content_s] = contents.map { item in
            let buffer = malloc(max(item.data.count, 1))!
            allocations.append(buffer)
            item.data.withUnsafeBytes { src in
                if let base = src.baseAddress { buffer.copyMemory(from: base, byteCount: src.count) }
            }
            return ghostty_clipboard_content_s(
                mime: cString(item.mime),
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: item.data.count)
        }
        var cAvailable: [UnsafePointer<CChar>] = available.map(cString)

        cContents.withUnsafeMutableBufferPointer { contentsBuffer in
            cAvailable.withUnsafeMutableBufferPointer { availableBuffer in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.isEmpty ? nil : UnsafePointer(contentsBuffer.baseAddress),
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.isEmpty ? nil : UnsafePointer(availableBuffer.baseAddress),
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
        // Hauntty only writes the plain text representation.
        var text: String?
        for i in 0..<len {
            let item = content[i]
            guard String(cString: item.mime) == "text/plain" else { continue }
            text = String(decoding: Data(bytes: item.data, count: item.len), as: UTF8.self)
            break
        }
        guard let text else { return }

        let write = {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
        }
        guard confirm else { return write() }

        // The config asks for confirmation before a program writes the clipboard.
        let alert = NSAlert()
        alert.messageText = "Allow the program to copy this text?"
        alert.informativeText = String(text.prefix(500))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { write() }
        }
        if let window = surfaceView(from: userdata)?.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
