import SwiftUI

/// One square per node, one row per node type. Color = how full the node is; gray = down.
struct NodeMap: View {
    let snapshot: ClusterSnapshot
    let width: CGFloat
    var cell: CGFloat = 11
    var gap: CGFloat = 3
    var labelWidth: CGFloat = 78
    var labelSize: CGFloat = 10.5
    @Binding var hover: String?

    var body: some View {
        let columns = max(Int((width - labelWidth + gap) / (cell + gap)), 1)
        VStack(alignment: .leading, spacing: gap + 2) {
            ForEach(snapshot.groups, id: \.label) { group in
                HStack(alignment: .top, spacing: 0) {
                    Text(group.label)
                        .font(.system(size: labelSize))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(stride(from: 0, to: group.nodes.count, by: columns)), id: \.self) { start in
                            HStack(spacing: gap) {
                                ForEach(group.nodes[start..<min(start + columns, group.nodes.count)]) { node in
                                    square(node)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func square(_ node: Node) -> some View {
        RoundedRectangle(cornerRadius: cell * 0.22, style: .continuous)
            .fill(node.isUp ? Palette.status(node.load * 100) : Palette.down)
            .overlay {
                if node.isDraining && !node.isDown {
                    RoundedRectangle(cornerRadius: cell * 0.22, style: .continuous)
                        .strokeBorder(Color.secondary, lineWidth: 1)
                }
            }
            .frame(width: cell, height: cell)
            .help(node.summary)
            .onHover { inside in
                if inside { hover = node.summary } else if hover == node.summary { hover = nil }
            }
    }
}

struct NodeLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(Palette.status(0), "mostly free")
            item(Palette.status(60), "busy")
            item(Palette.status(100), "full")
            item(Palette.down, "down")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
