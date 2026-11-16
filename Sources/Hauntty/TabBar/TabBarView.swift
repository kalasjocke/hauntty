import HaunttyCore
import SwiftUI

/// One tab per tmux window, in equal widths across the top of the window.
/// The active tab sits on a liquid glass capsule that slides between tabs.
struct TabBarView: View {
    let store: TabStore
    let foreground: Color
    let onSelect: (String) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(store.windows) { window in
                TabButton(
                    title: window.title,
                    isActive: window.id == store.activeID,
                    foreground: foreground,
                    namespace: namespace,
                    onSelect: { onSelect(window.id) })
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
    let isActive: Bool
    let foreground: Color
    let namespace: Namespace.ID
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(foreground.opacity(isActive ? 1 : 0.6))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isActive {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                        .matchedGeometryEffect(id: "active", in: namespace)
                } else if isHovered {
                    Capsule().fill(foreground.opacity(0.08))
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
