// CutRailOpen.swift — the owner's ask of 11-14: "an expanding arrow that expands the tools to the left to open up names above
// the tool icons with some (i) for some details on what it does and how to use it."
//
// Edit faces' rail (`surfaceToolsPanel`): an arrow beside it opens it to the left. Open, every tool shows its name above its
// icon (inside the tool's button, so a tap on the name picks the tool as a tap on the icon does) and the app's one (i)
// (`InfoTip`, as a setting row's) to the left of them. Closed, the rail is exactly as it was. It starts closed on every launch.

import SwiftUI
import TopOptDesign

enum CutRailInfo {
    /// Each tool's (i): what it does, then how.
    static func text(_ name: String) -> String? {
        switch name {
        case SurfaceTool.select.title:
            return "Picks one face. Tap a face to select it."
        case SurfaceTool.similar.title:
            return "Picks every face that looks like the one you tap, such as all the bolt holes at once. Tap one of them."
        case SurfaceTool.cut.title:
            return "Splits a face into two pieces along a line. Tap the face where the cut goes, turn or tilt the line on its bar, "
                + "then tap ✓."
        case SurfaceTool.union.title:
            return "Joins faces into one, or joins a cut face's pieces back together. Tap the faces to join, then ✓."
        case SurfaceTool.pattern.title:
            return "Splits a face into a grid of pieces. Tap the face, set the grid, then ✓."
        case SurfaceTool.region.title:
            return "Adds faces to a region or takes them out. Tap the region, then the faces to add or drop."
        case paint:
            return "On an STL part, paints a face of your own where the file has none. Brush over the part; the eraser takes paint off."
        case pencilOnly:
            return "On: only the Apple Pencil picks and cuts; your finger turns and zooms the part."
        default:
            return nil
        }
    }

    static let paint = "Paint"
    static let pencilOnly = "Pencil only"

    /// The open rail's name column: the longest name ("Pencil only") at the rail line's 12 pt, whole.
    static let nameWidth: CGFloat = 76
    /// ★ his iPad 11-16: the open rail's corner — a squircle, not a pill
    static let openCorner: CGFloat = 18
}

/// A rail tool's face: open, its name above the icon (one target with it); closed, the icon alone, as it was.
struct CutRailLabel<Content: View>: View {
    let open: Bool
    let name: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if open {
            VStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).fixedSize()
                    .background(DSParts.publish("cutRailName-\(name)"))
                content()
            }
            .frame(width: CutRailInfo.nameWidth)
            .contentShape(Rectangle())
        } else {
            content()
        }
    }
}

/// Open, a rail tool's (i) — the app's `InfoTip` — to the left of its name and icon.
struct CutRailInfoTip: ViewModifier {
    let open: Bool
    let name: String

    func body(content: Content) -> some View {
        if open, let text = CutRailInfo.text(name) {
            HStack(spacing: 0) {
                InfoTip(key: "cutRail-\(name)", text: text, title: name)
                content
            }
        } else {
            content
        }
    }
}

/// The rail's arrow: opens the rail to the left (‹), and closes it again (›). A 44 pt target beside the rail.
struct CutRailArrow: View {
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "chevron.right" : "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DSParts.publish(open ? "cutRailArrow-on" : "cutRailArrow"))
    }
}
