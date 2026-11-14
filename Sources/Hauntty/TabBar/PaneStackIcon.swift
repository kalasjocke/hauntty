import SwiftUI

/// The SF Symbol for a process. A placeholder set until there are real icons.
enum ProcessIcon {
    static func symbol(for command: String) -> String {
        switch command {
        case "nvim", "vim", "vi", "hx", "nano": return "pencil"
        case "zsh", "bash", "fish", "sh": return "chevron.right"
        case "claude": return "sparkle"
        case "node", "bun", "deno": return "hexagon"
        case "top", "htop", "btop": return "chart.bar.fill"
        case "git", "lazygit", "tig": return "arrow.triangle.branch"
        case "ssh", "mosh": return "network"
        case "python", "python3", "ruby", "irb": return "chevron.left.forwardslash.chevron.right"
        default: return "gearshape.fill"
        }
    }
}

/// A filled tile with the focused pane's process icon, and up to two tiles
/// stacked behind it to the right for the window's other panes. Each tile
/// behind is slightly smaller and fainter than the one in front.
struct PaneStackIcon: View {
    let symbol: String
    let paneCount: Int
    let color: Color

    private let width: CGFloat = 18
    private let height: CGFloat = 14
    private let radius: CGFloat = 3.5
    /// How far each tile behind sticks out past the one in front.
    private let step: CGFloat = 3
    /// How much smaller each tile behind is than the one in front.
    private let shrink = CGSize(width: 1, height: 1.5)
    /// Fill opacity of the front tile and each one behind it.
    private let fills: [Double] = [0.32, 0.17, 0.08]
    /// A faint shadow each tile casts onto the tile behind it, to separate
    /// them.
    private let shadowOpacity = 0.2
    private let shadowBlur: CGFloat = 1.2
    private let shadowOffset: CGFloat = 0.75

    private var others: Int { min(max(paneCount - 1, 0), 2) }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach((1...max(others, 1)).reversed(), id: \.self) { k in
                if k <= others {
                    tile(fill: fills[k], radius: tileRadius(k))
                        .frame(width: tileWidth(k), height: tileHeight(k))
                        .overlay(alignment: .leading) {
                            shadowOfTile(k - 1, onto: k)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: tileRadius(k)))
                        .offset(x: tileX(k))
                }
            }
            tile(fill: fills[0], radius: radius)
                .frame(width: width, height: height)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(color)
                }
        }
        .frame(width: width + step * CGFloat(others), height: height, alignment: .leading)
        // Keep each tile's erase inside the icon.
        .compositingGroup()
    }

    // Geometry of tile k, where 0 is the front tile. Each tile behind is
    // smaller and sticks out `step` points further to the right.
    private func tileWidth(_ k: Int) -> CGFloat { width - shrink.width * CGFloat(k) }
    private func tileHeight(_ k: Int) -> CGFloat { height - shrink.height * CGFloat(k) }
    private func tileRadius(_ k: Int) -> CGFloat { radius - 0.25 * CGFloat(k) }
    private func tileX(_ k: Int) -> CGFloat { width + step * CGFloat(k) - tileWidth(k) }

    /// The shadow tile `front` casts, in the coordinates of tile `back`. The
    /// caller clips it to tile `back`, and tile `front` erases the part under
    /// itself, so only the edge to its right shows.
    private func shadowOfTile(_ front: Int, onto back: Int) -> some View {
        RoundedRectangle(cornerRadius: tileRadius(front))
            .fill(.black.opacity(shadowOpacity))
            .frame(width: tileWidth(front), height: tileHeight(front))
            .offset(x: tileX(front) - tileX(back) + shadowOffset)
            .blur(radius: shadowBlur)
    }

    /// A tile that erases what is behind it, so the tiles do not add up where
    /// they overlap.
    private func tile(fill: Double, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return ZStack {
            shape.fill(.black).blendMode(.destinationOut)
            shape.fill(color.opacity(fill))
        }
    }
}
