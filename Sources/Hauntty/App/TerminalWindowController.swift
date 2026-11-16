import AppKit
import HaunttyCore
import SwiftUI

/// One Hauntty window: the tab bar at the top and the terminal surface below it.
/// The titlebar and its buttons are hidden, like Ghostty's
/// `macos-titlebar-style = hidden`.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let tabBarHeight: CGFloat = 36

    private let surfaceView: SurfaceView

    /// - Parameter onSelectTab: Called with the tmux window id of a clicked tab.
    init(ghostty: GhosttyApp, command: String, tabs: TabStore, onSelectTab: @escaping (String) -> Void) {
        surfaceView = SurfaceView(app: ghostty.app!, command: command)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hauntty"
        window.backgroundColor = ghostty.backgroundColor
        window.tabbingMode = .disallowed
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Dark glass on a dark theme, light glass on a light one.
        window.appearance = NSAppearance(
            named: ghostty.backgroundColor.isDark ? .darkAqua : .aqua)
        window.setFrameAutosaveName("HaunttyWindow")
        if !window.setFrameUsingName("HaunttyWindow") {
            window.center()
        }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = ghostty.backgroundColor.cgColor
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(surfaceView)

        let tabBar = NSHostingView(rootView: TabBarView(
            store: tabs,
            foreground: Color(nsColor: ghostty.foregroundColor),
            onSelect: { [weak surfaceView] id in
                onSelectTab(id)
                // Keep typing going to the terminal after a click.
                surfaceView?.window?.makeFirstResponder(surfaceView)
            }))
        tabBar.sizingOptions = []
        // The hidden titlebar still counts as a safe area, which would push
        // the tabs 28 points down, over the terminal.
        tabBar.safeAreaRegions = []
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabBar)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
            surfaceView.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.tabBarHeight),
            surfaceView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content

        // Hide the titlebar container too, as Ghostty does, so it does not
        // take clicks or drags meant for the tab bar.
        if let frameView = content.superview {
            frameView.firstDescendant(withClassName: "NSTitlebarContainerView")?.isHidden = true
        }

        super.init(window: window)
        window.delegate = self

        // When tmux exits or detaches, close the window.
        surfaceView.onClose = { [weak window] in window?.close() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(surfaceView)
    }
}

private extension NSView {
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name { return subview }
            if let found = subview.firstDescendant(withClassName: name) { return found }
        }
        return nil
    }
}

private extension NSColor {
    var isDark: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent < 0.5
    }
}
