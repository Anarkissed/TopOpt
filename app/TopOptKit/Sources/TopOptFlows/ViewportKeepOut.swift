// ViewportKeepOut.swift — the ONE placement pass every viewport-anchored control
// goes through, so no two on-screen controls overlap (handoff 2026-07-27).
//
// THE BUG THIS REMOVES: chips, value pills, gizmo handles, gravity controls and
// primitive handles each projected their 3D anchor to a screen point and drew
// themselves there independently (`.position(proj.project(...))`). When two landed
// on top of each other one became unselectable, and which one lost was arbitrary
// and flipped as the camera moved. This file owns placement for all of them: every
// element registers an ANCHOR (its projected point), a drawn BOUNDS, a grabbable
// TOUCH bounds (which may be larger — touches are what we protect, not the glass),
// and a PRIORITY; the pass displaces lower-priority elements off their neighbours
// and returns final positions. Nothing draws itself at a raw projected point any more.
//
// PURE + HEADLESS. No SwiftUI, no GPU, no camera object — it takes ALREADY-projected
// screen points (via `CameraProjection.project`) and returns screen points, so the
// whole thing is unit-tested headlessly (the /app/ verification standard):
// determinism, stability under a slow orbit, min-size, the no-room case, leader
// thresholds. `WorkspacePlaceholder` builds the element list each frame and reads
// the resolved placements back; `ViewportLayoutModel` (SwiftUI-side) holds the
// per-frame temporal state.
//
// ── PRIORITY (published; requirement 6) ──────────────────────────────────────
// Highest keeps its exact anchor and DISPLACES everything below it; lowest yields
// first and is HIDDEN first when there is genuinely no room:
//
//   activeDrag  the element the finger currently owns — outranks everything, rigid
//   gizmo       transform gizmo box / gravity base gizmo — anchored to geometry, rigid
//   handle      grab knobs (clearance drag, design-box, primitive move) — rigid
//   chrome      static screen-edge chrome bands (top bar, panels, corner gizmo) — rigid
//   pill        load / weight pills, anchor chip — MOVABLE
//   label       clearance value pills, snap badges, action clusters — MOVABLE, yields first
//
// RIGID = only the gizmo box, the gravity base gizmo, the element being dragged, and
// the static screen chrome. The gizmo is rigid because its anchor is the geometry it
// manipulates — moving it would lie about what it points at (requirement L5). Everything
// a user grabs otherwise — clearance knobs, design-box handles — and every chip/pill is
// MOVABLE: the maintainer's rule is that no two on-screen controls may overlap, so a
// handle slides clear of the gizmo rather than sitting under it. A clearance knob prefers
// to stay on its geometric locus (a margin knob anywhere around the cylinder, an axial
// knob anywhere on the end face — the drag math is angle-agnostic, so this is exact) via
// `candidates`, but may nudge slightly off it when even the locus is blocked. Among
// movable elements a handle outranks a pill outranks a label.

import Foundation
import CoreGraphics

/// What yields to what when viewport space runs out. Higher `rank` wins space and
/// displaces lower ranks; the lowest present rank is hidden first in the no-room case.
/// Backed by an explicit Int so the ordering is a stable total order (requirement 2).
public enum KeepOutPriority: Int, Comparable, CaseIterable, Sendable {
    /// Clearance value pills, snap badges, transform/gravity action clusters. Yields first.
    case label = 0
    /// Load / weight pills, the anchor-load chip, unselected primitive move knobs.
    case pill = 1
    /// Grab knobs — clearance drag handles, design-box handles. MOVABLE: they slide clear
    /// of the gizmo (a clearance knob prefers its geometric locus via `candidates`).
    case handle = 2
    /// Static screen-edge chrome bands (top bar, side panels, corner orientation gizmo).
    case chrome = 3
    /// The transform gizmo box and the gravity base gizmo — anchored rigidly to geometry.
    case gizmo = 4
    /// The element the finger is currently dragging — outranks everything.
    case activeDrag = 5

    public static func < (a: KeepOutPriority, b: KeepOutPriority) -> Bool { a.rawValue < b.rawValue }

    /// RIGID priorities never move — they hold their anchor and displace movable elements.
    /// Only the gizmo, the gravity gizmo, the active drag and the static chrome are rigid;
    /// every handle / pill / label is displaceable.
    public var isRigid: Bool { self >= .chrome }
}

/// One element registered with the pass. `anchor`, `bounds` and `touch` are all in
/// the SwiftUI/top-left/y-down point space `CameraProjection.project` returns.
public struct KeepOutElement: Equatable, Sendable {
    /// A stable identity — used to look the placement back up AND to break ties in the
    /// resolve order, so the result never depends on array/dictionary iteration order.
    public let id: String
    /// The desired centre: the element's projected anchor point (already offset to
    /// where it WANTS to sit, e.g. a value pill's anchor is beside its knob).
    public let anchor: CGPoint
    /// The drawn glass rect (for reference / leader geometry).
    public let bounds: CGSize
    /// The grabbable rect — MAY be larger than `bounds`. Collisions resolve on THIS
    /// (requirement 4: touch targets are the thing being protected, not the glass).
    public let touch: CGSize
    public let priority: KeepOutPriority
    /// Whether the element's anchor is rigid. Defaults to the priority's rigidity but
    /// callers may force a normally-movable element rigid while it is the drag target.
    public let rigid: Bool
    /// Equally-valid alternative screen positions this element MAY occupy — its geometric
    /// locus sampled to points (e.g. a clearance margin knob sampled around its cylinder).
    /// The pass starts the element at the candidate that clears its neighbours best, then
    /// still allows a small 2-D nudge from there. Empty ⇒ the element only has `anchor`.
    /// The first candidate should be the home position, so a clear scene leaves it put.
    public let candidates: [CGPoint]
    /// The MOST an element may be shifted from its anchor (points). A control must stay
    /// close enough to its referent to read as belonging to it (the maintainer's rule:
    /// a SLIGHT nudge to clear a neighbour, never floated far). When clearing would need
    /// more than this, the element stops at the cap and accepts a little residual overlap —
    /// close-but-touching beats far-but-clear. `.infinity` = unbounded (headless tests).
    public let maxShift: CGFloat

    public init(id: String, anchor: CGPoint, bounds: CGSize, touch: CGSize,
                priority: KeepOutPriority, rigid: Bool? = nil, candidates: [CGPoint] = [],
                maxShift: CGFloat = .infinity) {
        self.id = id
        self.anchor = anchor
        self.bounds = bounds
        // Touch bounds are never smaller than the drawn glass.
        self.touch = CGSize(width: Swift.max(touch.width, bounds.width),
                            height: Swift.max(touch.height, bounds.height))
        self.priority = priority
        self.rigid = rigid ?? priority.isRigid
        self.candidates = candidates
        self.maxShift = maxShift
    }
}

/// Where an element ended up after the pass.
public struct KeepOutPlacement: Equatable, Sendable {
    public let id: String
    /// The final centre to draw at (points).
    public let center: CGPoint
    /// center − anchor. The leader line is drawn from `anchor` to `center` when set.
    public let displacement: CGVector
    /// True once the element sits far enough from its anchor that it no longer reads as
    /// belonging to it — the caller draws a leader line (requirement 3).
    public let needsLeader: Bool
    /// True when there was genuinely no room and the element was withdrawn rather than
    /// stacked (requirement 7). The caller collapses it into a count badge / hides it.
    public let hidden: Bool

    public var displacementLength: CGFloat { CoreGraphics.hypot(displacement.dx, displacement.dy) }
}

/// The pure, deterministic collision-resolution pass. No temporal state — same
/// elements + viewport in, same placements out, every time (requirement 2).
public enum KeepOutSolver {

    /// Apple Human Interface Guidelines minimum tap target: 44×44 pt. A protected touch
    /// rect is never resolved as smaller than this; an element whose declared touch is
    /// smaller is treated at 44 pt (never silently shrunk — requirement 5). If 44 pt
    /// cannot be placed clear, the element is hidden (no-room), not squeezed.
    public static let minTouch: CGFloat = 44
    /// A gap kept between two touch rects so they don't merely kiss.
    public static let separation: CGFloat = 4
    /// A displaced element gets a leader line once its centre sits more than this far
    /// from its anchor (requirement 3). Chosen at the HIG tap radius (44/2 ≈ 22) plus a
    /// margin, so the leader appears exactly when the element clears its own anchor's
    /// touch zone and no longer visually hugs it.
    public static let leaderOnDistance: CGFloat = 30
    /// Iteration cap for the per-element separation loop. Past this the element is
    /// treated as un-placeable (no-room). Small — each pass strictly reduces overlap.
    public static let maxIterations = 24

    /// The min-enforced protected size (requirement 5).
    static func protectedSize(_ e: KeepOutElement) -> CGSize {
        CGSize(width: Swift.max(e.touch.width, minTouch),
               height: Swift.max(e.touch.height, minTouch))
    }

    static func rect(center c: CGPoint, size s: CGSize) -> CGRect {
        CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    /// The deterministic total order the pass walks elements in: highest priority first
    /// (it keeps its anchor and pushes the rest), ties broken by `id`. No dependence on
    /// input array order (requirement 2) — a caller may register in any order.
    static func ordered(_ elements: [KeepOutElement]) -> [KeepOutElement] {
        elements.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.id < b.id
        }
    }

    /// Resolve overlaps and return one placement per element (same ids, any order).
    ///
    /// Algorithm: place the elements in priority order into a growing `occupied` set of
    /// touch rects. A rigid element takes its exact anchor. A movable element starts at
    /// its anchor and, while it overlaps any placed rect, is pushed by the MINIMUM
    /// TRANSLATION that clears the deepest overlap — the smallest move that separates,
    /// which is exactly the displacement that "least breaks the link to its anchor"
    /// (requirement: displace along the direction that least breaks the anchor link).
    /// Every choice (which rect, which axis, which sign) is deterministic.
    public static func resolve(_ elements: [KeepOutElement], viewport: CGSize) -> [KeepOutPlacement] {
        var occupied: [CGRect] = []
        occupied.reserveCapacity(elements.count)
        var out: [KeepOutPlacement] = []
        out.reserveCapacity(elements.count)

        for e in ordered(elements) {
            let size = protectedSize(e)
            if e.rigid {
                let r = rect(center: e.anchor, size: size)
                occupied.append(r)
                out.append(KeepOutPlacement(id: e.id, center: e.anchor, displacement: .zero,
                                            needsLeader: false, hidden: false))
                continue
            }

            // Locus-constrained controls start at the candidate that clears best (a clearance
            // knob slides around its cylinder before it floats off it); everything else starts
            // at its anchor. Sliding along the locus to a far candidate is legitimate (still ON
            // the geometry), so `maxShift` caps only the 2-D nudge FROM this start, not the whole
            // move from the home anchor.
            let start = e.candidates.isEmpty
                ? e.anchor
                : e.candidates[bestCandidateIndex(e.candidates, size: size, avoiding: occupied)]
            var center = start
            var iterations = 0
            while iterations < maxIterations {
                iterations += 1
                guard let hit = deepestOverlap(rect(center: center, size: size), occupied) else { break }
                let push = minimumTranslation(rect(center: center, size: size), hit)
                if push == .zero { break }
                center = CGPoint(x: center.x + push.dx, y: center.y + push.dy)
                center = clamp(center: center, size: size, viewport: viewport)
            }

            // SLIGHT-MOVEMENT CAP on the 2-D NUDGE from the chosen locus point: a control may
            // slide freely along its locus (that stays on the geometry), but only nudges a little
            // off it, even if that leaves a small overlap. A capped element is never hidden —
            // close-but-touching beats far-but-clear (the maintainer's rule).
            var nudge = CGVector(dx: center.x - start.x, dy: center.y - start.y)
            let nd = CoreGraphics.hypot(nudge.dx, nudge.dy)
            if nd > e.maxShift {
                let k = e.maxShift / nd
                nudge = CGVector(dx: nudge.dx * k, dy: nudge.dy * k)
                center = CGPoint(x: start.x + nudge.dx, y: start.y + nudge.dy)
            }
            let disp = CGVector(dx: center.x - e.anchor.x, dy: center.y - e.anchor.y)
            let dist = CoreGraphics.hypot(disp.dx, disp.dy)
            // Only an UNBOUNDED element withdraws when it still can't clear (requirement 7);
            // a capped control stays visible and close.
            let hidden = e.maxShift.isFinite
                ? false
                : deepestOverlap(rect(center: center, size: size), occupied) != nil
            // A capped control is meant to stay close (a slight nudge), so it never leads;
            // only an unbounded element that ended up far draws a leader.
            out.append(KeepOutPlacement(id: e.id, center: center, displacement: disp,
                                        needsLeader: !hidden && e.maxShift.isInfinite && dist > leaderOnDistance,
                                        hidden: hidden))
            if !hidden { occupied.append(rect(center: center, size: size)) }
        }
        return out
    }

    /// The placed rect that `r` overlaps most (by overlap area), or nil if clear. Walks
    /// `occupied` in order and keeps the first maximal — deterministic tie-break.
    static func deepestOverlap(_ r: CGRect, _ occupied: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for o in occupied {
            let ix = Swift.min(r.maxX, o.maxX) - Swift.max(r.minX, o.minX) + separation
            let iy = Swift.min(r.maxY, o.maxY) - Swift.max(r.minY, o.minY) + separation
            guard ix > 0, iy > 0 else { continue }
            let area = ix * iy
            if area > bestArea { bestArea = area; best = o }
        }
        return best
    }

    /// The minimum translation that pushes `a` out of `b` (touch rects, plus the
    /// separation gap). Pushes along the axis of LEAST penetration — the smallest move
    /// that separates. Sign is away from `b`'s centre; when the two centres coincide the
    /// choice is fixed (+x) so the result is deterministic even in the exact-stack case.
    static func minimumTranslation(_ a: CGRect, _ b: CGRect) -> CGVector {
        let ox = Swift.min(a.maxX, b.maxX) - Swift.max(a.minX, b.minX) + separation
        let oy = Swift.min(a.maxY, b.maxY) - Swift.max(a.minY, b.minY) + separation
        guard ox > 0, oy > 0 else { return .zero }
        if ox <= oy {
            let dir: CGFloat = a.midX >= b.midX ? 1 : -1
            return CGVector(dx: dir * ox, dy: 0)
        } else {
            let dir: CGFloat = a.midY >= b.midY ? 1 : -1
            return CGVector(dx: 0, dy: dir * oy)
        }
    }

    /// Pick, from a set of equally-valid candidate screen positions, the one whose touch
    /// rect overlaps `occupied` least (by area). Ties resolve to the EARLIEST candidate, so
    /// pass the control's home position first — it wins whenever nothing is in the way, and
    /// the control only moves when it has to (stability). This is how a LOCUS-constrained
    /// control stays clear: a clearance knob may sit anywhere around its cylinder, so the
    /// caller samples the circumference into candidates and this chooses the on-geometry one
    /// that dodges the gizmo — instead of floating the knob off its surface in 2-D.
    /// Deterministic (fixed scan order, area compared with a fixed epsilon).
    public static func bestCandidateIndex(_ candidates: [CGPoint], size: CGSize,
                                          avoiding occupied: [CGRect]) -> Int {
        guard candidates.count > 1 else { return 0 }
        let s = CGSize(width: Swift.max(size.width, minTouch), height: Swift.max(size.height, minTouch))
        var bestIdx = 0
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (i, c) in candidates.enumerated() {
            let r = rect(center: c, size: s)
            var area: CGFloat = 0
            for o in occupied {
                let ix = Swift.min(r.maxX, o.maxX) - Swift.max(r.minX, o.minX) + separation
                let iy = Swift.min(r.maxY, o.maxY) - Swift.max(r.minY, o.minY) + separation
                if ix > 0, iy > 0 { area += ix * iy }
            }
            if area < bestArea - 1e-6 { bestArea = area; bestIdx = i; if area <= 0 { break } }
        }
        return bestIdx
    }

    /// Keep the whole touch rect inside the viewport (so a displaced element never slides
    /// off-screen). If the viewport is smaller than the rect, centre it — the follow-up
    /// overlap check then decides no-room.
    static func clamp(center: CGPoint, size: CGSize, viewport: CGSize) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return center }
        let hw = size.width / 2, hh = size.height / 2
        let x: CGFloat = viewport.width >= size.width
            ? Swift.min(Swift.max(center.x, hw), viewport.width - hw) : viewport.width / 2
        let y: CGFloat = viewport.height >= size.height
            ? Swift.min(Swift.max(center.y, hh), viewport.height - hh) : viewport.height / 2
        return CGPoint(x: x, y: y)
    }
}

/// Radial placement around a central obstacle (the transform gizmo). A clearance knob's home is on
/// the clearance BOUNDARY (the primitive side + margin), so it TRACKS the value — it comes in as the
/// margin shrinks and out as it grows. But it can't sit UNDER the gizmo, so it is never seated
/// closer than a tight ring just beyond the gizmo's ribbons: on the boundary when that's outside the
/// ring, on the ring when the boundary would be inside the gizmo. The gizmo is a fixed on-screen
/// size, so the ring floor is zoom-independent. Keeps its angle from the gizmo centre. Pure + tested.
public enum ClearanceRing {
    /// `p` (the boundary point) kept along `centre→p` but never closer to `centre` than `ringRadius`
    /// — so it tracks the margin outside the ring and clears the gizmo inside it. A point at the
    /// centre falls back to due-right on the ring.
    public static func place(_ p: CGPoint, around centre: CGPoint, ringRadius: CGFloat) -> CGPoint {
        let vx = p.x - centre.x, vy = p.y - centre.y
        let d = CoreGraphics.hypot(vx, vy)
        guard d > 0.5 else { return CGPoint(x: centre.x + ringRadius, y: centre.y) }
        let r = Swift.max(d, ringRadius)
        return CGPoint(x: centre.x + vx / d * r, y: centre.y + vy / d * r)
    }

    /// A point `outward` points farther from `centre` than `p`, along `centre→p` — used to seat a
    /// value pill just beyond its knob, radially, so it too stays clear of the gizmo.
    public static func nudgeOutward(_ p: CGPoint, from centre: CGPoint, by outward: CGFloat) -> CGPoint {
        let vx = p.x - centre.x, vy = p.y - centre.y
        let d = CoreGraphics.hypot(vx, vy)
        guard d > 0.5 else { return CGPoint(x: p.x + outward, y: p.y) }
        return CGPoint(x: centre.x + vx / d * (d + outward), y: centre.y + vy / d * (d + outward))
    }
}

/// The temporal layer that makes the pass STABLE across frames (requirement 1). The
/// camera moves constantly, so a raw per-frame resolve would jitter and could swap two
/// elements across a frame boundary. This holds each element's last drawn centre and
/// moves it toward the freshly-resolved target by a fixed fraction each frame (a
/// critically-damped follower — monotone, never overshoots, so it cannot oscillate),
/// with a dead-band that ignores sub-pixel target moves. The leader-line flag latches
/// with hysteresis so it never flickers on/off at the threshold.
///
/// Determinism holds: the target comes from the deterministic `KeepOutSolver.resolve`,
/// and the follower is a pure function of (previous centre, target, damping). Value
/// type — the SwiftUI model owns one and calls `step` from the projection-publish path.
public struct KeepOutStabilizer: Equatable, Sendable {
    /// Fraction of the remaining gap closed each frame. 1 = snap (no smoothing); smaller
    /// = smoother but laggier. 0.35 settles a step to <1 pt in ~11 frames while keeping
    /// a slow orbit visually glued to its anchors.
    public var damping: CGFloat
    /// Target moves smaller than this (points) are ignored — the element holds still, so
    /// a near-stationary camera produces NO motion (kills shimmer).
    public var deadBand: CGFloat
    /// Leader turns on above `leaderOnDistance` and only back off below this — hysteresis
    /// so an element hovering at the threshold doesn't flash its leader every frame.
    public var leaderOffDistance: CGFloat
    /// Hard slew cap: no element may travel more than this many points in one frame,
    /// however far its resolved target jumped. This bounds a separation FLIP (when two
    /// crowding anchors cross, the yielding element's target teleports to the far side)
    /// into a smooth multi-frame migration instead of a lurch — the crisp form of
    /// "small camera movements produce small position changes" (requirement 1). At the
    /// slow orbit the app actually renders (a few points/frame of anchor motion) the cap
    /// is never hit by normal tracking, only by a flip.
    public var maxStep: CGFloat

    private var lastCenter: [String: CGPoint]
    private var leaderLatched: [String: Bool]

    public init(damping: CGFloat = 0.35, deadBand: CGFloat = 0.5,
                leaderOffDistance: CGFloat = 22, maxStep: CGFloat = 8) {
        self.damping = damping
        self.deadBand = deadBand
        self.leaderOffDistance = leaderOffDistance
        self.maxStep = maxStep
        self.lastCenter = [:]
        self.leaderLatched = [:]
    }

    /// Advance one frame: smooth each target toward its previous drawn centre and apply
    /// leader hysteresis. Elements not in `targets` are forgotten (so a dismissed control
    /// doesn't leave stale state that would make it jump when it returns).
    public mutating func step(_ targets: [KeepOutPlacement], anchors: [String: CGPoint]) -> [KeepOutPlacement] {
        var out: [KeepOutPlacement] = []
        out.reserveCapacity(targets.count)
        var nextCenter: [String: CGPoint] = [:]
        var nextLatched: [String: Bool] = [:]

        for t in KeepOutStabilizer.sortById(targets) {
            // Hidden elements aren't drawn; pass through without disturbing their state
            // (they resume from their real anchor when room reappears).
            if t.hidden { out.append(t); continue }

            let prev = lastCenter[t.id] ?? t.center     // first sighting: start ON target (no fly-in)
            let dx = t.center.x - prev.x, dy = t.center.y - prev.y
            let moved = CoreGraphics.hypot(dx, dy)
            var center: CGPoint
            if moved < deadBand {
                center = prev                            // dead-band: hold still, no shimmer
            } else {
                // Damped step toward the target, then clamped to the slew cap so a target
                // flip migrates smoothly instead of lurching.
                var mx = damping * dx, my = damping * dy
                let step = CoreGraphics.hypot(mx, my)
                if step > maxStep { let k = maxStep / step; mx *= k; my *= k }
                center = CGPoint(x: prev.x + mx, y: prev.y + my)
            }
            nextCenter[t.id] = center

            // Leader flag off the SMOOTHED displacement, with hysteresis.
            let anchor = anchors[t.id] ?? t.center
            let dist = CoreGraphics.hypot(center.x - anchor.x, center.y - anchor.y)
            let was = leaderLatched[t.id] ?? false
            let now = was ? (dist > leaderOffDistance) : (dist > KeepOutSolver.leaderOnDistance)
            nextLatched[t.id] = now

            out.append(KeepOutPlacement(
                id: t.id, center: center,
                displacement: CGVector(dx: center.x - anchor.x, dy: center.y - anchor.y),
                needsLeader: now, hidden: false))
        }
        lastCenter = nextCenter
        leaderLatched = nextLatched
        return out
    }

    /// Reset all temporal memory — call when the whole overlay set changes wholesale
    /// (e.g. a new model loads) so nothing eases in from a stale position.
    public mutating func reset() { lastCenter = [:]; leaderLatched = [:] }

    private static func sortById(_ p: [KeepOutPlacement]) -> [KeepOutPlacement] {
        p.sorted { $0.id < $1.id }
    }
}
