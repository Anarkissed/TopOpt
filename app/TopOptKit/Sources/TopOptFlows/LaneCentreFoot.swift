// LaneCentreFoot.swift — ★ his iPad notes 2026-11-23 evening (img 5: "100 % of the lattice you asked for is solid: too narrow
// for the cells across it needs", with "Check a 0.2 mm nozzle" and "Aesthetic, walls cut cells"): "Place this more in the
// bottom's centre. It feels off-putting that it's a bit to the left."
//
// The notice rode in the new engine's stack (`LaneFoot`), which in landscape sits in the bottom row's widest gap — left of
// Settings and Lattice, so its middle was left of the screen's. It is his newer word for THIS notice (his 11-21 rule keeps
// other notes off the bottom-centre), so it now has its own place: centred on the screen's centre line, at the foot, just
// above the stack's status lines, as wide as the room round the centre allows (16 pt clear of Settings and Lattice, two
// lines where it must) — the toasts' rule (`NotificationLane.place`). With no room at the centre it steps up past the
// controls in its way. Its frame is published as "lane-<key>".

import SwiftUI

extension NotificationLane {
    /// The notice's place: centred at the foot (`bottom`), above `below` (the lane under it) by `stepGap`.
    static func centreFoot(bottom: CGFloat, height: CGFloat, viewport: CGSize, controls: [CGRect], below: CGRect?) -> Place {
        var foot = bottom
        if let b = below, b.height > 0.5, b.minY < bottom { foot = Swift.min(foot, b.minY - stepGap) }
        return place(edge: .bottom, preferred: foot, height: height, viewport: viewport, controls: controls)
    }
}

extension View {
    /// ★ his 11-23: this notice centred on the screen's centre line at the page's foot, above the lane `above` (its key without
    /// "lane-").
    func laneCentreFoot(_ key: String, above: String) -> some View { modifier(LaneCentreFoot(key: key, below: above)) }
}

struct LaneCentreFoot: ViewModifier {
    let key: String
    let below: String
    @Environment(\.laneControls) private var controls

    func body(content: Content) -> some View {
        if let controls {
            LaneCentreFootBody(controls: controls, key: key, below: below, content: content)
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)   // no lane above (a preview)
        }
    }
}

private struct LaneCentreFootBody<Content: View>: View {
    @ObservedObject var controls: LaneControls
    let key: String
    let below: String
    let content: Content
    /// The notice's measured height: the row it takes is [foot − height, foot].
    @State private var height: CGFloat = NotificationLane.twoLineHeight

    var body: some View {
        GeometryReader { g in
            let space = g.frame(in: .global)
            let local = controls.frames.map { $0.offsetBy(dx: -space.minX, dy: -space.minY) }
            let under = controls.lanes["lane-\(below)"].map { $0.offsetBy(dx: -space.minX, dy: -space.minY) }
            let p = NotificationLane.centreFoot(bottom: g.size.height - g.safeAreaInsets.bottom, height: height, viewport: g.size,
                                                controls: local, below: under)
            content
                .frame(maxWidth: p.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { s in
                    Color.clear.onAppear { height = s.size.height }.onChange(of: s.size.height) { height = $0 }
                })
                .background(NumberPad.published("lane-\(key)"))
                .frame(width: g.size.width, height: Swift.max(0, p.top + height), alignment: .bottom)
                .offset(x: (p.cx ?? g.size.width / 2) - g.size.width / 2)
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
    }
}
