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
    /// A face's prism shows unless its eye hid it. ★ His iPad 11-07 (3a): "They must all be VISIBLE by default" — the
    /// mockup's rule (shown only while picked or eyed) left every prism hidden on a group's first tap. `picked` is kept for
    /// the callers; a picked row's prism shows like any other until its eye hides it.
    public static func prismShown(_ key: String, eye: [String: Bool], picked: String?) -> Bool {
        eye[key] ?? true
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
    public static func footprint(_ p: CGPoint, size: CGFloat = 44, spacing: CGFloat = 8, pill: Bool = true) -> CGRect {
        CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size + (pill ? spacing + pillMax : 0), height: size)
    }

    // MARK: ★ his iPad 11-08 (3, 4) — whose chips show, and clear space between them

    /// ★ His iPad 11-08 (4): "Show only the chips of what's picked" — one face-prism → that one's; a group row → that
    /// group's; a zone → that zone's handles; nothing picked → none. (On 2a7c7bd8 every face of every group a model tap had
    /// ever opened wore its handle and ± knob: "a clusterfuck … completely unusable".)
    public enum ChipScope: Equatable {
        case none
        case group(UUID)
        case face(group: UUID, key: String)
        case zone(UUID)

        /// What is picked on Lattice Setup: the picked group (a zone, or a face group), and inside a face group the picked
        /// face row — a face pick left over from another group does not count.
        public static func of(active: UUID?, zones: Set<UUID>, facePick: String?, groupRefs: (UUID) -> [String]) -> ChipScope {
            guard let a = active else { return .none }
            if zones.contains(a) { return .zone(a) }
            if let k = facePick, groupRefs(a).contains(k) { return .face(group: a, key: k) }
            return .group(a)
        }

        /// Whether a face's prism in `group` (row key `key`) wears its chips (its end handle and its ± knob).
        public func shows(group: UUID, key: String) -> Bool {
            switch self {
            case .none, .zone: return false
            case .group(let g): return g == group
            case .face(let g, let k): return g == group && k == key
            }
        }
    }

    /// ★ His iPad 11-08 (3): "Every chip needs clear space between it and the next, so a tap can't be confused." The clear
    /// space between two chips' footprints, pt — the viewport's own (KeepOutSolver.separation).
    public static let chipGap: CGFloat = KeepOutSolver.separation

    /// One chip to lay out: its true point, the line it may slide along, and the room it takes around a point.
    public struct Chip: Equatable {
        public let key: String
        public let at: CGPoint
        public let axis: CGVector
        /// The chip's footprint when its knob's middle is on a point, as an offset rect (FootprintShape).
        public let shape: FootprintShape
        public init(key: String, at: CGPoint, axis: CGVector, shape: FootprintShape) {
            self.key = key; self.at = at; self.axis = axis; self.shape = shape
        }
    }

    /// A footprint: a knob of `size` with its middle on the point, and (a handle showing its number) the pill beside it.
    public struct FootprintShape: Equatable {
        public let size: CGFloat
        public let pill: Bool
        public init(size: CGFloat = 44, pill: Bool = false) { self.size = size; self.pill = pill }
        public func rect(_ p: CGPoint) -> CGRect {
            LatticeSetupHandles.footprint(p, size: size, pill: pill)
        }
    }

    /// How far a crowded chip looks for room (pt): his 2040 stand's Group 2 lays 38 chips over one slanted side, where the
    /// last ones found nothing within `slideMax` on their four lines and stayed on another chip.
    public static let crowdMax: CGFloat = 400
    /// The other ways a crowded chip looks at each distance, after along and across its drag line (degrees from its axis).
    static let ringMore: [CGFloat] = [45, 135, 225, 315, 22.5, 67.5, 112.5, 157.5, 202.5, 247.5, 292.5, 337.5]
    /// The ways a crowded chip looks for room at each distance, in order: along its drag line (both ways), across it (both
    /// ways), then the diagonals (`ringMore`).
    static func ringDirections(_ axis: CGVector) -> [CGVector] {
        let a = atan2(axis.dy, axis.dx)
        return ([0, 180, 90, 270] + ringMore).map { CGVector(dx: cos(a + $0 * .pi / 180), dy: sin(a + $0 * .pi / 180)) }
    }

    /// ★ ONE LAYOUT FOR EVERY CHIP ON THE PART (his iPad 11-08, 3). In order (the picked thing's first), each chip is drawn
    /// on its true point — or at the NEAREST place, in any direction (along its own drag line first, then across it, then
    /// the diagonals, at each distance up to `crowdMax`), clear of the page's own UI (`keepOut`) and `chipGap` clear of every
    /// chip already placed. Each drag still reads its chip's TRUE point (`placed`'s rule) and only the finger's travel along
    /// its line, so a slid chip moves the value exactly as one on its point. With no clear place within reach it stays put.
    public static func layout(_ chips: [Chip], keepOut: [CGRect]) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        var taken: [CGRect] = []
        for c in chips {
            func clear(_ q: CGPoint) -> Bool {
                let r = c.shape.rect(q)
                return !keepOut.contains { $0.intersects(r) }
                    && !taken.contains { $0.insetBy(dx: -chipGap, dy: -chipGap).intersects(r) }
            }
            var spot = c.at
            if !clear(spot) {
                let dirs = ringDirections(c.axis)
                var t = slideStep
                search: while t <= crowdMax {
                    for d in dirs {
                        let q = CGPoint(x: c.at.x + d.dx * t, y: c.at.y + d.dy * t)
                        if clear(q) { spot = q; break search }
                    }
                    t += slideStep
                }
            }
            out[c.key] = spot
            taken.append(c.shape.rect(spot))
        }
        return out
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
    /// ★ his iPad 11-07 (1b): the page's tap on a face of the part, as the viewer's pick calls it.
    @MainActor public static var livePick: ((FaceID) -> Void)?
    /// ★ his iPad 11-07: the faces the page last coloured for the Lattice stage's own groups (Pending ones included).
    @MainActor public static var latticeTinted: Set<FaceID> = []
    /// ★ his iPad 11-08 (1): the page's tap into nothing, as the viewer calls it (a click offscreen never reaches the 3D view).
    @MainActor public static var liveEmptyTap: (() -> Void)?
    /// ★ his iPad 11-08 (3, 4): the chips the page last laid out on Lattice Setup, by key, where each is drawn.
    @MainActor public static var chipSpots: [String: CGPoint] = [:]
}
