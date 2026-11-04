// FlexiblePressAim — the arrow's maths (task 2026-10-07, angled presses, batch AP3; final spec §6 "The arrow", AS
// AMENDED by the reviewer's A4 and A8 of 2026-10-08: "a multi-face press never offers a snap to one of its own faces'
// normals, because core refuses edge-on. Offer only directions core accepts. A single-face press snaps to its normal
// as 'straighten'." and "build Z covers both straight down and straight up").
//
// ★ ONE SOURCE: CORE. Everything here works on core's numbers, handed in by the stage model (FlexibleStageModel+Aim):
// each member's INWARD NORMAL is core's face_frame_cut load (flexible_scene_region_frame, per region — or per member
// face of a multi-face region, clipped by its cuts), the fallback axes are core's frame X / Y, build Z is core's own
// build direction (the scene's `build`), and WHICH targets are offered is core's verdict (build_press_stack through
// flexible_scene_press_verdict). This file computes INPUTS only: the halfway default (Σ core's per-member inward
// normals, normalised — never the area-weighted union normal core uses when no direction is stated), the snap of a
// pointed direction onto a target, the degrees box's great circle, the drag's 1° UI limit and the knob's geometry. No
// frame, column, design, side verdict or ownership is computed here: the side verdict is core's FaceFrame.side for the
// stated direction (FlexibleStageModel.pressSide), never an angle compared with 15 in Swift.
//
// ★ THE TARGETS (A4/A8), in order — the first wins a tie and a repeat is dropped:
//   * one region (a tilted face press): its own core normal, [Straighten]; the halfway too when the region spans
//     2+ faces (each face's core normal, clipped by the region's cuts); then build Z down and up;
//   * 2+ regions (an edge, a corner): the halfway; then build Z down and up. NEVER a member's own normal: on a box
//     edge or corner it is exactly edge-on to another member, and core refuses it.
//   Each is ASKED of core; only what core builds is offered (`FlexiblePressAimSet.offered`).
// ★ EXACT. A chip tap, a knob within 12° of a target and the degrees box at 0 all store the target's own vector, bit
// for bit (`on`); a target never carries a negative zero (`canon`), so its bits survive the project file's JSON.
// ★ THE 1° LIMIT is the app's, not core's: a FREE direction (a drag, the degrees box) holds 1° short of edge-on to
// core's inward normal of EVERY triangle core checks a stated direction against ("a press can't pull";
// FlexiblePressAimSet.footprintNormals — AP3 REVIEW: each member's average let the M2's curved corners through to
// directions core refuses). Snaps are exempt (each was accepted by core); a free drag or box that STARTS from a target
// core built inside the 1° band keeps that target's own margin instead (`margin`), so it moves and never goes further
// out. Core's refusals read as one plain line in the app's names (`plainLine`), core's sentence behind the (i).
import Foundation
import simd

public enum FlexiblePressAim {

    /// The knob snaps within this many degrees of a target (the gravity gizmo's tolerance).
    public static let snapToleranceDeg: Double = GravityDirectionGizmo.snapToleranceDegrees
    /// A FREE direction holds this many degrees short of edge-on to every member (a UI limit, not core's rule).
    public static let edgeOnMarginDeg: Double = 1
    /// Looking along the arrow (|view ray · arrow| above this) the knob turns into a screen trackball …
    public static let trackballDot: Double = 0.9
    /// … at this many degrees per point of finger travel.
    public static let trackballDegPerPoint: Double = 0.5
    /// The degrees box's step (a scrub moves it in whole degrees; the keypad takes any value).
    public static let boxStepDeg: Double = 1

    // MARK: - the one normaliser and angles

    /// d / |d|, component by component — core's press_unit — or nil for a zero or non-finite vector.
    public static func unit(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let n = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard n.isFinite, n > 0 else { return nil }
        return SIMD3(v.x / n, v.y / n, v.z / n)
    }

    /// No negative zeros (−0 + 0 = +0): the same direction, and its bits survive a JSON round trip.
    public static func canon(_ v: SIMD3<Double>) -> SIMD3<Double> { v + SIMD3<Double>(repeating: 0) }

    /// The angle between two directions, degrees (atan2: accurate near 0 and 180).
    public static func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(simd_length(simd_cross(a, b)), simd_dot(a, b)) * 180 / .pi
    }

    /// Bit for bit.
    public static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    // MARK: - the halfway (D-AP-4)

    /// ★ The halfway between members' inward normals: Σ core's unit loads in member order, normalised. nil when the
    /// sum has (almost) no length — the faces face apart — or when it does not point into EVERY member (a dot ≤ 0:
    /// no one direction presses them all).
    public static func halfway(_ loads: [SIMD3<Double>]) -> SIMD3<Double>? {
        guard !loads.isEmpty else { return nil }
        var s = SIMD3<Double>.zero
        for l in loads { s += l }
        guard simd_length(s) >= 1e-9, let h = unit(s) else { return nil }
        guard loads.allSatisfy({ simd_dot(h, $0) > 0 }) else { return nil }
        return canon(h)
    }

    // MARK: - the targets (A4, A8)

    /// One direction the arrow snaps to, of a kind the press stores (`FlexiblePress.snap`).
    public struct Target: Equatable, Sendable {
        public let kind: FlexiblePress.Snap
        /// Unit, INTO the part, no negative zeros: stored exactly as it is.
        public let direction: SIMD3<Double>
        public init(kind: FlexiblePress.Snap, direction: SIMD3<Double>) { self.kind = kind; self.direction = direction }
        /// The chip's words (one or two words; his captions are at most four).
        public var label: String { FlexiblePressAim.label(kind) }
    }

    public static func label(_ kind: FlexiblePress.Snap) -> String {
        switch kind {
        case .halfway: return "Halfway"
        case .straighten: return "Straighten"
        case .buildDown: return "Straight down"
        case .buildUp: return "Straight up"
        case .build: return "Build Z"
        case .face: return "Face"
        }
    }

    /// ★ The targets ASKED of core, in order (A4/A8). `memberLoads`: core's inward normal of each member — each
    /// region of an edge or corner, or each member face of a one-region press over 2+ faces (one load for a plain
    /// face). `ownLoad`: a one-region press's own core normal (its straighten); nil for 2+ regions. `buildDir`:
    /// core's build direction (the scene's). Never a member's own normal for 2+ regions. A target that repeats an
    /// earlier one is dropped (the first wins: the top face's straighten IS straight down).
    public static func candidates(memberLoads: [SIMD3<Double>], ownLoad: SIMD3<Double>?, buildDir: SIMD3<Double>) -> [Target] {
        var out: [Target] = []
        // straighten IS core's load, bit for bit (re-normalising a unit vector can move its last bit)
        if let own = ownLoad, unit(own) != nil { out.append(Target(kind: .straighten, direction: canon(own))) }
        if memberLoads.count >= 2, let h = halfway(memberLoads) { out.append(Target(kind: .halfway, direction: h)) }
        if let b = unit(buildDir) {
            out.append(Target(kind: .buildDown, direction: canon(SIMD3<Double>.zero - b)))
            out.append(Target(kind: .buildUp, direction: canon(b)))
        }
        var kept: [Target] = []
        for t in out where !kept.contains(where: { degrees($0.direction, t.direction) < 1e-9 }) { kept.append(t) }
        return kept
    }

    /// ★ THE TARGET RULE of the degrees box: it measures FROM the press's stored snap kind when that target is
    /// offered, else from the first offered target (the halfway of an edge or a corner, a tilt's straighten).
    public static func selected(_ snap: FlexiblePress.Snap?, offered: [Target]) -> Target? {
        if let s = snap, let t = offered.first(where: { $0.kind == s }) { return t }
        return offered.first
    }

    // MARK: - snapping (exact)

    /// What a chip, the knob or the box puts on the press: its direction and the snap kind it stores.
    public struct Release: Equatable, Sendable {
        public let direction: SIMD3<Double>
        public let snap: FlexiblePress.Snap?
        /// ★ AP3 REVIEW: the direction IS the snap kind's target, bit for bit — a chip, a knob snap, the degrees box
        /// at 0. false for a free release, and for the box OFF its target (the kind is then only the target it
        /// measures FROM, D-AP3-1). [Straighten] turns a tilted press back into its face only when exact.
        public let exact: Bool
        public init(direction: SIMD3<Double>, snap: FlexiblePress.Snap?, exact: Bool = false) {
            self.direction = direction; self.snap = snap; self.exact = exact
        }
    }

    /// A chip tap: the target's own vector, bit for bit.
    public static func chip(_ t: Target) -> Release { Release(direction: t.direction, snap: t.kind, exact: true) }

    /// Is `d` exactly on `t` (bit for bit)?
    public static func on(_ d: SIMD3<Double>, _ t: Target) -> Bool { bits(d) == bits(t.direction) }

    /// ★ The nearest target within `toleranceDeg` wins and is returned EXACTLY (its own bits); the first in the list
    /// wins a tie. Outside every tolerance: nil.
    public static func snapped(_ d: SIMD3<Double>, targets: [Target],
                               toleranceDeg: Double = snapToleranceDeg) -> Target? {
        guard let n = unit(d) else { return nil }
        var best: Target? = nil
        var bestDot = cos(toleranceDeg * .pi / 180)
        for t in targets {
            let c = simd_dot(n, t.direction)
            if c > bestDot { bestDot = c; best = t }
        }
        return best
    }

    // MARK: - the 1° limit (the app's; core decides what it builds)

    /// Does `d` stay at least `margin` into every normal (default sin 1°: `edgeOnMarginDeg` short of edge-on)?
    public static func admissible(_ d: SIMD3<Double>, loads: [SIMD3<Double>], margin: Double? = nil) -> Bool {
        guard let n = unit(d) else { return false }
        let s = margin ?? sin(edgeOnMarginDeg * .pi / 180)
        return loads.allSatisfy { simd_dot(n, $0) >= s }
    }

    /// The least dot of unit `d` with `loads` (+∞ with none); nil when `d` has no direction.
    public static func minDot(_ d: SIMD3<Double>, loads: [SIMD3<Double>]) -> Double? {
        guard let n = unit(d) else { return nil }
        return loads.reduce(Double.infinity) { Swift.min($0, simd_dot(n, $1)) }
    }

    /// ★ AP3 REVIEW: the margin a free direction keeps when it starts from `a` (where a drag starts, a box's target):
    /// sin 1° — or, when `a` (a target core built) already sits inside that band, `a`'s OWN margin, so the knob and
    /// the box move from it (they froze there) and never go further out than it. nil when `a` does not point into
    /// every normal.
    public static func margin(from a: SIMD3<Double>, loads: [SIMD3<Double>]) -> Double? {
        let s = sin(edgeOnMarginDeg * .pi / 180)
        guard let m = minDot(a, loads: loads) else { return nil }
        if m >= s { return s }
        return m > 0 ? m : nil
    }

    /// The point a fraction `t` along the great circle from unit `a` to unit `b` (nil when they are opposite).
    static func slerp(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double>? {
        let w = atan2(simd_length(simd_cross(a, b)), simd_dot(a, b))
        guard w > 1e-15 else { return a }
        let s = sin(w)
        guard s > 1e-12 else { return nil }
        return unit((sin((1 - t) * w) / s) * a + (sin(t * w) / s) * b)
    }

    /// ★ THE CLAMP: `d` when it is admissible; else the last admissible direction on the great circle from `from`
    /// (the drag's start) toward `d` — 1° short of edge-on to the normal that binds, or (AP3 REVIEW) the start's own
    /// margin when the start is a target inside that band. A start that does not point into every normal holds where
    /// it is.
    public static func clamp(_ d: SIMD3<Double>, from start: SIMD3<Double>, loads: [SIMD3<Double>]) -> SIMD3<Double> {
        guard let e = unit(d) else { return start }
        if admissible(e, loads: loads) { return canon(e) }
        guard let a = unit(start), let m = margin(from: a, loads: loads) else { return start }
        if admissible(e, loads: loads, margin: m) { return canon(e) }
        func ok(_ t: Double) -> Bool { slerp(a, e, t).map { admissible($0, loads: loads, margin: m) } ?? false }
        var lo = 0.0, hi = 1.0
        let samples = 64
        for k in 1...samples {
            let t = Double(k) / Double(samples)
            if !ok(t) { hi = t; break }
            lo = t
        }
        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            if ok(mid) { lo = mid } else { hi = mid }
        }
        guard lo > 0 else { return start }   // no room toward `d`: it stays where it is
        return canon(slerp(a, e, lo) ?? a)
    }

    /// ★ One drag update, or its release: a snap (EXACT, exempt from the 1° limit) when a target is within 12°,
    /// else the clamped direction, free (no snap kind).
    public static func release(_ d: SIMD3<Double>, from start: SIMD3<Double>, targets: [Target],
                               loads: [SIMD3<Double>]) -> Release {
        if let t = snapped(d, targets: targets) { return chip(t) }
        return Release(direction: clamp(d, from: start, loads: loads), snap: nil)
    }

    // MARK: - the degrees box (his rule: numbers are boxes — keypad + vertical drag)

    /// The plane a box scrubs in when the arrow sits ON its target: the first of `fallbacks` not parallel to the
    /// target — for an edge or a corner the members' core normals in pick order, for a tilt core's frame X then Y.
    public static func fallbacks(memberLoads: [SIMD3<Double>], single: Bool, coreX: SIMD3<Double>?,
                                 coreY: SIMD3<Double>?) -> [SIMD3<Double>] {
        let axes = [coreX, coreY].compactMap { $0 }
        return single ? axes + memberLoads : memberLoads + axes
    }

    /// ★ The degrees box: "12°" off its target. It scrubs along the great circle from the target through the
    /// arrow (or, when the arrow sits on the target, toward the first fallback not parallel to it); 0 is the target
    /// bit for bit; it stops where a free direction must (1° short of edge-on, or — AP3 REVIEW — the target's own
    /// margin when core built it inside that band: its range was 0…0).
    public struct Box: Equatable, Sendable {
        public let target: Target
        /// Unit, perpendicular to the target: the great circle's second axis.
        public let plane: SIMD3<Double>
        /// Degrees from the target now.
        public let value: Double
        /// The most it can show (1° short of edge-on along the plane).
        public let limit: Double

        /// The box as FlexNumberBox shows it: degrees, 1° steps, 0 … limit, one decimal.
        public var spec: FlexNumberSpec {
            FlexNumberSpec(value: (value * 10).rounded() / 10, unit: "\u{00B0}", step: FlexiblePressAim.boxStepDeg,
                           range: 0...Swift.max(0, limit), decimals: 1)
        }

        /// The direction at `deg` from the target along the plane: the target ITSELF at 0 (or below).
        public func direction(_ deg: Double) -> SIMD3<Double> {
            guard deg > 0, deg.isFinite else { return target.direction }
            let a = deg * .pi / 180
            return FlexiblePressAim.canon(FlexiblePressAim.unit(cos(a) * target.direction + sin(a) * plane) ?? target.direction)
        }

        /// What a commit of `deg` puts on the press: the direction, and the target's kind kept (the box measures from
        /// it) — EXACT only at 0, where the direction is the target's own bits.
        public func release(_ deg: Double) -> Release {
            let d = direction(deg)
            return Release(direction: d, snap: target.kind, exact: FlexiblePressAim.on(d, target))
        }
    }

    /// The box for `current` measured from `target`; nil when no plane exists (no fallback off the target's line).
    public static func box(target: Target, current: SIMD3<Double>, fallbacks: [SIMD3<Double>],
                           loads: [SIMD3<Double>]) -> Box? {
        let t = target.direction
        let value = on(current, target) ? 0 : (unit(current).map { degrees($0, t) } ?? 0)
        func perp(_ v: SIMD3<Double>) -> SIMD3<Double>? {
            guard let u = unit(v) else { return nil }
            guard abs(simd_dot(u, t)) < 1 - 1e-9 else { return nil }
            return unit(u - simd_dot(u, t) * t)
        }
        var plane: SIMD3<Double>? = value > 1e-9 ? perp(current) : nil
        if plane == nil { plane = fallbacks.lazy.compactMap(perp).first }
        guard let u = plane.map(canon) else { return nil }
        // the limit: the first angle along the plane past which a free direction is not admissible
        func at(_ deg: Double) -> SIMD3<Double> {
            let a = deg * .pi / 180
            return unit(cos(a) * t + sin(a) * u) ?? t
        }
        var limit = 0.0
        if let m = margin(from: t, loads: loads) {
            func ok(_ deg: Double) -> Bool { admissible(at(deg), loads: loads, margin: m) }
            var lo = 0.0, hi = 180.0
            var deg = 0.25
            var found = false
            while deg <= 180 {
                if !ok(deg) { hi = deg; found = true; break }
                lo = deg
                deg += 0.25
            }
            if found {
                for _ in 0..<60 {
                    let mid = (lo + hi) / 2
                    if ok(mid) { lo = mid } else { hi = mid }
                }
            }
            limit = lo
        }
        return Box(target: target, plane: u, value: value, limit: limit)
    }

    // MARK: - the knob (GravityDirectionGizmo's drag; the knob is at the TAIL)

    /// The arrow's length: a quarter of the part's bounds diagonal, 15 … 80 mm, grown (up to 2×) so it keeps 60 pt
    /// on screen at `pointsPerMM` (the page's projected scale ALONG the arrow, foreshortening included).
    public static func arrowLength(boundsDiagonalMM: Double, pointsPerMM: Double? = nil) -> Double {
        let l = Swift.min(80, Swift.max(15, 0.25 * boundsDiagonalMM))
        guard let p = pointsPerMM, p > 0, l * p < 60 else { return l }
        return Swift.min(2 * l, 60 / p)
    }

    /// ★ The knob drag: GravityDirectionGizmo.Drag with the gizmo's direction REVERSED — its tip is the arrow's tail
    /// (the knob), at `length` mm out of the part from `anchor` (on the faces); the arrow points from it INTO the part.
    public struct Drag: Equatable, Sendable {
        public let gizmo: GravityDirectionGizmo.Drag
        public let start: SIMD3<Double>
        public let targets: [Target]
        public let loads: [SIMD3<Double>]

        public init(direction: SIMD3<Double>, anchor: SIMD3<Double>, length: Double, grab: PrimitiveGizmo.Ray,
                    viewDir: SIMD3<Double>, targets: [Target], loads: [SIMD3<Double>]) {
            gizmo = GravityDirectionGizmo.Drag(startDirection: SIMD3<Double>.zero - direction, center: anchor,
                                               length: length, grab: grab, viewDir: viewDir)
            start = direction
            self.targets = targets
            self.loads = loads
        }

        /// The model-space knob (the arrow's tail) at the grab.
        public var knob: SIMD3<Double> { gizmo.startTip }

        /// The direction the finger points the arrow (unclamped, unsnapped).
        public func pointed(_ ray: PrimitiveGizmo.Ray) -> SIMD3<Double> {
            SIMD3<Double>.zero - gizmo.resolve(currentRay: ray)
        }

        /// One update (live) or the release (committed once): snapped exactly, else clamped and free.
        public func step(_ ray: PrimitiveGizmo.Ray) -> Release {
            FlexiblePressAim.release(pointed(ray), from: start, targets: targets, loads: loads)
        }
    }

    /// ★ Looking ALONG the arrow, the knob's drag plane faces the arrow and a drag cannot tilt it: the knob turns into
    /// a screen trackball.
    public static func isTrackball(viewDir: SIMD3<Double>, direction: SIMD3<Double>) -> Bool {
        guard let v = unit(viewDir), let d = unit(direction) else { return false }
        return abs(simd_dot(v, d)) > trackballDot
    }

    /// The trackball: a finger move of (dx, dy) points turns the arrow 0.5° per point — right about the screen's up
    /// axis, down about its right axis (both in model space) — then snaps or clamps like the knob.
    public struct Trackball: Equatable, Sendable {
        public let start: SIMD3<Double>
        public let right: SIMD3<Double>
        public let up: SIMD3<Double>
        public let targets: [Target]
        public let loads: [SIMD3<Double>]

        public init(direction: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>, targets: [Target],
                    loads: [SIMD3<Double>]) {
            start = direction
            self.right = FlexiblePressAim.unit(right) ?? SIMD3(1, 0, 0)
            self.up = FlexiblePressAim.unit(up) ?? SIMD3(0, 1, 0)
            self.targets = targets
            self.loads = loads
        }

        /// The arrow turned by a finger move of (dx, dy) points (unclamped, unsnapped).
        public func pointed(dx: Double, dy: Double) -> SIMD3<Double> {
            let k = FlexiblePressAim.trackballDegPerPoint * .pi / 180
            return FlexiblePressAim.rotate(FlexiblePressAim.rotate(start, about: up, by: dx * k), about: right, by: dy * k)
        }

        public func step(dx: Double, dy: Double) -> Release {
            FlexiblePressAim.release(pointed(dx: dx, dy: dy), from: start, targets: targets, loads: loads)
        }
    }

    /// Rodrigues: `v` turned by `angle` radians about unit `axis`.
    static func rotate(_ v: SIMD3<Double>, about axis: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        let c = cos(angle), s = sin(angle)
        return v * c + simd_cross(axis, v) * s + axis * simd_dot(axis, v) * (1 - c)
    }

    // MARK: - core's refusals in plain words (AP3 REVIEW; his rule: one line, at most 44 characters)

    /// ★ Core's refusal of a press (build_press_stack's FlexibleError) as ONE plain line of at most 44 characters, in
    /// the app's names (`name` of a region id, fitted so the line fits); core's own sentence stays behind the (i).
    /// A sentence this does not know reads "Core can't build this press".
    public static func plainLine(_ reason: String, name: (Int) -> String) -> String {
        let ids = regionIDs(reason)
        let most = FlexibleRowCopy.maxChars
        func fitted(_ k: Int, _ room: Int) -> String {
            k < ids.count ? FlexibleRowCopy.fit(name(ids[k]), Swift.max(6, room)) : "a face"
        }
        let line: String
        if reason.contains("does not point into the part") {
            let head = "Arrow doesn't push into all of "
            line = head + fitted(0, most - head.count)
        } else if reason.contains("are not adjacent") {
            let room = (most - " and  don't touch".count) / 2
            line = fitted(0, room) + " and " + fitted(1, room) + " don't touch"
        } else if reason.contains("SAME face") {
            let room = (most - " and  are parts of one face".count) / 2
            line = fitted(0, room) + " and " + fitted(1, room) + " are parts of one face"
        } else if reason.contains("appears twice") {
            let tail = " is in the press twice"
            line = fitted(0, most - tail.count) + tail
        } else if reason.contains("press_direction must be") {
            line = "The arrow has no direction"
        } else if reason.contains("needs at least one face region") {
            line = "The press has no faces"
        } else if let first = ids.first, let r = reason.range(of: "face region \(first)") {
            line = plainFrameLine(String(reason[r.upperBound...]), name: name(first))
        } else {
            line = "Core can't build this press"
        }
        return FlexibleRowCopy.fit(line)
    }

    /// ★ Core's refusal to FRAME region `name` (face_frame_cut's reason, or build_stack's) as one plain line of at
    /// most 44 characters.
    public static func plainFrameLine(_ reason: String, name: String) -> String {
        let tail: String
        if reason.contains("normals cancel out") {
            tail = " has no one push direction"
        } else if reason.contains("cuts leave nothing") {
            tail = " is cut away to nothing"
        } else if reason.contains("has no triangles") {
            tail = " has no surface"
        } else if reason.contains("no column") {
            tail = " is too narrow to press"
        } else if reason.contains("out of range") {
            tail = " is not on this part"
        } else {
            tail = ": core can't frame it"
        }
        return FlexibleRowCopy.fit(FlexibleRowCopy.fit(name, FlexibleRowCopy.maxChars - tail.count) + tail)
    }

    /// Every "face region N" core's sentence names, in order.
    public static func regionIDs(_ reason: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: "face region (\\d+)") else { return [] }
        let ns = reason as NSString
        return re.matches(in: reason, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        }
    }

    // MARK: - the side label's (i) text

    /// The (i) under the side label: core's own number (kSideStackDeg, bridged for this text only).
    public static func sideInfo(sideStackDeg: Double) -> String {
        "More than \(FlexNumberSpec.format(sideStackDeg, decimals: 1))\u{00B0} off build Z is a side press in core. "
            + "Squish data were measured pressing straight down; angled presses are estimates until they're measured."
    }
}
