// LatticeSetupHandles.swift — B6 N2 / N3 (design-system §4.24 "one handle for every drag"; ledger N2, N3, row 28; mockup
// #lat-face-prism, #lat-prisms-eye, #lat-zone-sel, #lat-zone-cyl).
//
// His words (N2): "there should always be a way to drag out the face-prisms manually. This should change the depth value …
// Selecting that face should open it up … It should also *show/hide* the face-prism associated to the face." (N3): "the
// zone should open up with the size of the primitive; it should show/highlight the primitive's handles for dragging".
//
// On Lattice Setup a face's prism shows while its row is picked, or while its row's eye says so (the eye overrides, the
// mockup's `prismShown`); the picked face's prism wears the one DragHandle at its end, and a picked zone one on each side.
// This file is the pure part: which prisms show, a handle's drag direction on screen, and where a drag puts the finger.
// The page (WorkspacePlaceholder) draws them and writes the numbers.

import CoreGraphics
import Foundation
import simd

public enum LatticeSetupHandles {
    /// A face's prism shows while its row is picked, or while its eye says so (the eye wins either way).
    public static func prismShown(_ key: String, eye: [String: Bool], picked: String?) -> Bool {
        eye[key] ?? (picked == key)
    }

    /// The drag direction on screen: from a handle's point `a` to the point 10 mm along its direction `b`, unit length.
    /// Straight up when either does not project or the direction points at the camera (nothing to drag along).
    public static func screenAxis(from a: CGPoint?, to b: CGPoint?) -> CGVector {
        guard let a, let b else { return CGVector(dx: 0, dy: -1) }
        let dx = b.x - a.x, dy = b.y - a.y, l = (dx * dx + dy * dy).squareRoot()
        return l > 1 ? CGVector(dx: dx / l, dy: dy / l) : CGVector(dx: 0, dy: -1)
    }

    /// Where a drag `along` points down the handle's axis (unit) from where it began puts the finger — on the axis only.
    public static func finger(start: CGPoint, axis: CGVector, along: CGFloat) -> CGPoint {
        CGPoint(x: start.x + axis.dx * along, y: start.y + axis.dy * along)
    }

    /// How far, and in what steps, `placed` slides a handle (pt).
    public static let slideStep: CGFloat = 4
    public static let slideMax: CGFloat = 240

    /// ★ Where a handle is DRAWN (U-rules: no hidden controls): on its point — or, when its 44 pt knob would sit under the
    /// page's own UI (`keepOut`: the Selections panel, a legend, the tool column — where no finger can reach it), slid along
    /// its own drag line to the nearest clear place, either way, up to 240 pt. The drag still reads the handle's TRUE point,
    /// so the number never jumps and a finger moved along the line moves the value as it would on the point. With no clear
    /// place within reach it stays on its point.
    public static func placed(_ p: CGPoint, axis: CGVector, keepOut: [CGRect], size: CGFloat = 44) -> CGPoint {
        func clear(_ q: CGPoint) -> Bool {
            let r = CGRect(x: q.x - size / 2, y: q.y - size / 2, width: size, height: size)
            return !keepOut.contains { $0.intersects(r) }
        }
        if clear(p) { return p }
        var t = slideStep
        while t <= slideMax {
            for s in [CGFloat(1), -1] {
                let q = CGPoint(x: p.x + axis.dx * t * s, y: p.y + axis.dy * t * s)
                if clear(q) { return q }
            }
            t += slideStep
        }
        return p
    }

    /// The widest number a handle's pill shows beside its knob ("⌀ 120.0 mm"), pt.
    public static let pillMax: CGFloat = 96
    /// The room a drawn handle takes: its 44 pt knob (middle on `p`), then its number beside it (DragHandle's HStack).
    public static func footprint(_ p: CGPoint, size: CGFloat = 44, spacing: CGFloat = 8) -> CGRect {
        CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size + spacing + pillMax, height: size)
    }

    /// A held handle: its key, and where it was and its axis on screen when the drag began.
    public struct DragStart: Equatable {
        public let key: String
        public let start: CGPoint
        public let axis: CGVector
        public init(key: String, start: CGPoint, axis: CGVector) { self.key = key; self.start = start; self.axis = axis }
    }

    /// The keys the page gives its handles (DragHandle publishes "handle-<key>"): a face's prism end, a zone's side.
    public static func prismKey(_ ref: LatticeSelectableRef) -> String { "prism-\(ref.key)" }
    public static func zoneKey(_ zone: UUID, _ side: LatticeZoneHandle.Side) -> String { "zone\(side.rawValue)-\(zone.uuidString)" }

    // MARK: Test hooks (a synthesised drag never reaches a gesture in an offscreen test window — FlexibleR7U21CHandlesHostedTests'
    // finding — so the tests drive the very closure each handle's gesture calls, as the page last built it).

    /// While true, the page records its live handles and the prisms it draws.
    @MainActor public static var recordLive = false
    /// Handle key → its axis on screen and its drag closure (points along the axis since the drag began; true on release).
    @MainActor public static var live: [String: (axis: CGVector, drag: (CGFloat, Bool) -> Void)] = [:]
    /// The selectable keys whose prisms the page drew last.
    @MainActor public static var drawnPrisms: Set<String> = []
    /// What the page drew lit through the part: the picked face's prism (its key) or the picked zone (its id).
    @MainActor public static var litThrough: Set<String> = []
    /// The picked zone's move glass's gesture (where the finger went down, where it is now; then its release).
    @MainActor public static var liveZoneGizmo: (changed: (CGPoint, CGPoint) -> Void, ended: () -> Void)?
}
