import HaunttyCore
import SwiftUI

/// One tab per tmux window, up to 160 points wide each, inside a translucent
/// grey capsule. The active tab sits on a lighter capsule that slides between
/// tabs.
struct TabBarView: View {
    let store: TabStore
    let foreground: Color
    let onSelect: (String) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.windows) { window in
                TabButton(
                    title: window.title,
                    paneCount: window.paneCount,
                    isActive: window.id == store.activeID,
                    foreground: foreground,
                    namespace: namespace,
                    onSelect: { onSelect(window.id) })
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(3)
        .background(Capsule().fill(foreground.opacity(0.08)))
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        // The titlebar is hidden, so the tab bar is where the window is moved
        // from. Taps on a tab still select it.
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .animation(.smooth(duration: 0.25), value: store.windows)
        .animation(.smooth(duration: 0.25), value: store.activeID)
    }
}

private struct TabButton: View {
    let title: String
    let paneCount: Int
    let isActive: Bool
    let foreground: Color
    let namespace: Namespace.ID
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            PaneStackIcon(
                symbol: ProcessIcon.symbol(for: title),
                paneCount: paneCount,
                color: foreground)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
            .foregroundStyle(foreground)
            .opacity(isActive ? 1 : 0.6)
            .padding(.horizontal, 12)
            .frame(maxWidth: 160, maxHeight: .infinity)
            .background {
                if isActive {
                    Capsule()
                        .fill(foreground.opacity(0.14))
                        .matchedGeometryEffect(id: "active", in: namespace)
                } else if isHovered {
                    Capsule().fill(foreground.opacity(0.06))
                }
            }
            .contentShape(.capsule)
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
    }
}
