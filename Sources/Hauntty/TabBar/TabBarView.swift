import HaunttyCore
import SwiftUI

/// One tab per tmux window, each as wide as its icon and title but no wider
/// than 225 points, inside a translucent grey capsule. The active tab sits on
/// a lighter capsule that slides between tabs.
struct TabBarView: View {
    let store: TabStore
    let foreground: Color
    let onSelect: (String) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.windows) { window in
                TabButton(
                    title: store.tabTitle(for: window),
                    // Claude Code shows up in tmux as its version number.
                    command: store.runsClaude(window) ? "claude" : window.command,
                    paneCount: window.paneCount,
                    // Idle only matters for tabs in the background.
                    status: window.status == .idle && window.id == store.activeID ? nil : window.status,
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
        // The terminal adds its own top padding below the bar (2 points with
        // `window-padding-y = 2,0`), so 1 point here leaves the same 3 point
        // gap below the bar as above it.
        .padding(.top, 3)
        .padding(.bottom, 1)
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
    let command: String
    let paneCount: Int
    let status: WindowStatus?
    let isActive: Bool
    let foreground: Color
    let namespace: Namespace.ID
    let onSelect: () -> Void

    @State private var isHovered = false

    private let iconGap: CGFloat = 6

    var body: some View {
        MaxWidth(225) {
            HStack(spacing: iconGap) {
                PaneStackIcon(
                    symbol: ProcessIcon.symbol(for: command),
                    paneCount: paneCount,
                    status: status,
                    color: foreground,
                    tileOpacity: isActive ? 1 : 0.6)
                // Size for the bold title, so the tab keeps its width when it
                // becomes active.
                title(weight: .semibold)
                    .hidden()
                    .overlay(alignment: .leading) {
                        title(weight: isActive ? .semibold : .regular)
                            .opacity(isActive ? 1 : 0.6)
                    }
            }
            .padding(.horizontal, 3 * iconGap)
        }
            .foregroundStyle(foreground)
            .frame(maxHeight: .infinity)
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

    private func title(weight: Font.Weight) -> some View {
        Text(title)
            .font(.system(size: 12, weight: weight))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Sizes its content to fit, but no wider than `maxWidth`. Unlike
/// `.frame(maxWidth:)`, it does not grow to fill the space it is offered.
private struct MaxWidth: Layout {
    let maxWidth: CGFloat

    init(_ maxWidth: CGFloat) {
        self.maxWidth = maxWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
