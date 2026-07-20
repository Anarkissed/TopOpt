// DesignBox.swift — the M7.dom-app design-domain data model.
//
// dom-core (handoff 068) taught the optimizer to ADD material beyond the imported
// part: voxelize onto a LARGER grid spanning the union of the part and a user
// DESIGN BOX (axis-aligned, model space), freeze the import as FrozenSolid, mark
// the design box's empty space Active (growable), and mark any KEEP-OUT boxes
// FrozenVoid (must stay empty). This file is the app-side model the workspace's
// design-box gizmo edits and that `AppModel.makeRunRequest` threads to the core
// through the bridge (`BridgeLoadCase.has_design_box` / keep-outs).
//
// Everything here is a pure value type (no SwiftUI, no GPU, no bridge call) in the
// MODEL/mesh frame the solver works in (mm), so the geometry logic — the default
// box, face resizing, moving, keep-outs, and the model-space → bridge conversion —
// is unit-tested headlessly (the M7 /app/ verification standard). The Metal gizmo
// that renders the box + drag handles renders OVER this model and is device QA.
//
// DEFAULT OFF: a fresh project has `box == nil` (the tool was never opened), so
// `bridgeBox` is nil and the run passes NO design box — byte-identical to a run
// without this feature (dom-core's opt-in guarantee).

import Foundation
import CoreGraphics
import simd
import TopOptKit

/// An axis-aligned box in MODEL space (mm): the same frame as the mesh vertices and
/// the load faces, so it maps to the core's `DesignBox` with no transform. `min` is
/// kept <= `max` componentwise by every mutating helper.
public struct DesignBoxBounds: Equatable, Sendable, Codable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = simd_min(min, max)
        self.max = simd_max(min, max)
    }

    /// The box centre.
    public var center: SIMD3<Float> { (min + max) * 0.5 }
    /// The per-axis extent (always >= 0).
    public var size: SIMD3<Float> { max - min }
    /// Half the space diagonal (used for camera-independent handle sizing).
    public var radius: Float { simd_length(size * 0.5) }

    /// Whether a model-space point lies inside (inclusive).
    public func contains(_ p: SIMD3<Float>) -> Bool {
        p.x >= min.x && p.x <= max.x &&
        p.y >= min.y && p.y <= max.y &&
        p.z >= min.z && p.z <= max.z
    }

    /// The centre of one of the 6 faces (axis 0/1/2 = x/y/z; `isMax` picks the
    /// +axis face). Feeds the gizmo's face-handle placement.
    public func faceCenter(axis: Int, isMax: Bool) -> SIMD3<Float> {
        var c = center
        c[axis] = isMax ? max[axis] : min[axis]
        return c
    }

    /// Move one face along its axis to `value`, keeping the box non-degenerate: the
    /// moved face may not cross past the opposite face closer than `minSize`.
    public func movingFace(axis: Int, isMax: Bool, to value: Float,
                           minSize: Float) -> DesignBoxBounds {
        var lo = min, hi = max
        let floor = Swift.max(minSize, 1e-4)
        if isMax {
            hi[axis] = Swift.max(value, lo[axis] + floor)
        } else {
            lo[axis] = Swift.min(value, hi[axis] - floor)
        }
        return DesignBoxBounds(min: lo, max: hi)
    }

    /// The box translated by a model-space delta (whole-box move; size unchanged).
    public func translated(by delta: SIMD3<Float>) -> DesignBoxBounds {
        DesignBoxBounds(min: min + delta, max: max + delta)
    }

    /// The tightest box that contains both this and `other` (their union AABB).
    public func union(_ other: DesignBoxBounds) -> DesignBoxBounds {
        DesignBoxBounds(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

/// The design-domain state persisted on a project and edited by the workspace gizmo.
/// `box == nil` means the tool is off (no design box → default optimize behavior).
public struct DesignBoxModel: Equatable, Sendable, Codable {
    /// The design box (growable envelope), or nil when the tool has never been opened
    /// / was turned off. nil is the DEFAULT-OFF state: the run passes no box.
    public var box: DesignBoxBounds?
    /// Keep-out boxes the optimizer must leave empty (FrozenVoid). Only meaningful
    /// when `box != nil`; cleared when the tool is turned off.
    public var keepOuts: [DesignBoxBounds]

    public init(box: DesignBoxBounds? = nil, keepOuts: [DesignBoxBounds] = []) {
        self.box = box
        self.keepOuts = keepOuts
    }

    /// Whether the design-box tool is active (a box is defined).
    public var isActive: Bool { box != nil }

    /// The default box seeded when the user first opens the tool: the part's bounding
    /// box grown outward by `growth` × the part's size on every axis, so the user
    /// immediately sees GROW ROOM around the part (the box already extends beyond the
    /// import — the whole point). A degenerate/empty part falls back to a unit box.
    public static func defaultBox(around part: MeshBounds, growth: Float = 0.4) -> DesignBoxBounds {
        guard !part.isEmpty else {
            return DesignBoxBounds(min: SIMD3<Float>(repeating: -0.5),
                                   max: SIMD3<Float>(repeating: 0.5))
        }
        let size = part.max - part.min
        // Pad each axis by a fraction of that axis' extent, with a small floor so a
        // near-flat axis still gains a little room.
        let floor = Swift.max(part.radius * 0.15, 1e-3)
        let pad = SIMD3<Float>(Swift.max(size.x * growth, floor),
                               Swift.max(size.y * growth, floor),
                               Swift.max(size.z * growth, floor))
        return DesignBoxBounds(min: part.min - pad, max: part.max + pad)
    }

    /// The smallest sensible box extent on any axis, so a resize/move can't collapse
    /// the box. Scaled to the part so it works at any model size.
    public static func minSize(for part: MeshBounds) -> Float {
        Swift.max(part.radius * 0.05, 1e-3)
    }

    /// Open the tool: seed the design box from the part bounds (idempotent — keeps an
    /// existing box so re-opening doesn't discard the user's edits).
    public mutating func enable(around part: MeshBounds) {
        if box == nil { box = Self.defaultBox(around: part) }
    }

    /// Turn the tool off: drop the box AND its keep-outs (the run reverts to the
    /// default no-box path).
    public mutating func disable() {
        box = nil
        keepOuts = []
    }

    /// Reset the design box back to the default grow-room box around the part
    /// (keep-outs are preserved).
    public mutating func reset(around part: MeshBounds) {
        box = Self.defaultBox(around: part)
    }

    /// Move one design-box face along its axis to `value` (no-op if the tool is off).
    public mutating func resizeFace(axis: Int, isMax: Bool, to value: Float,
                                    part: MeshBounds) {
        guard let b = box else { return }
        box = b.movingFace(axis: axis, isMax: isMax, to: value,
                           minSize: Self.minSize(for: part))
    }

    /// Translate the whole design box by a model-space delta (no-op if off).
    public mutating func move(by delta: SIMD3<Float>) {
        guard let b = box else { return }
        box = b.translated(by: delta)
    }

    /// Add a keep-out box: a small cube at the part centre the user then resizes/moves
    /// (no-op if the tool is off — keep-outs only apply under a design box).
    @discardableResult
    public mutating func addKeepOut(around part: MeshBounds) -> Int? {
        guard box != nil else { return nil }
        let c = part.isEmpty ? SIMD3<Float>(repeating: 0) : part.center
        let h = Swift.max(part.radius * 0.15, 1e-3)
        keepOuts.append(DesignBoxBounds(min: c - h, max: c + h))
        return keepOuts.count - 1
    }

    /// Remove the keep-out at `index` (bounds-checked).
    public mutating func removeKeepOut(at index: Int) {
        guard keepOuts.indices.contains(index) else { return }
        keepOuts.remove(at: index)
    }

    /// Resize a keep-out box's face (bounds-checked; no-op if off / bad index).
    public mutating func resizeKeepOutFace(_ index: Int, axis: Int, isMax: Bool,
                                           to value: Float, part: MeshBounds) {
        guard box != nil, keepOuts.indices.contains(index) else { return }
        keepOuts[index] = keepOuts[index].movingFace(
            axis: axis, isMax: isMax, to: value, minSize: Self.minSize(for: part))
    }

    /// Translate a keep-out box (bounds-checked; no-op if off / bad index).
    public mutating func moveKeepOut(_ index: Int, by delta: SIMD3<Float>) {
        guard box != nil, keepOuts.indices.contains(index) else { return }
        keepOuts[index] = keepOuts[index].translated(by: delta)
    }

    // MARK: - bridge conversion (model space → the core's DesignBox, mm)

    /// The design box as the bridge spec (model space, Double), or nil when the tool
    /// is off → the run passes NO box (default behavior). This is what
    /// `AppModel.makeRunRequest` hands `minimizePlasticLoadCase`.
    public var bridgeBox: TopOptKit.DesignBoxSpec? {
        guard let b = box else { return nil }
        return TopOptKit.DesignBoxSpec(min: SIMD3<Double>(b.min), max: SIMD3<Double>(b.max))
    }

    /// The keep-out boxes as bridge specs (empty when the tool is off, so no keep-out
    /// is passed unless a design box is too).
    public var bridgeKeepOuts: [TopOptKit.DesignBoxSpec] {
        guard box != nil else { return [] }
        return keepOuts.map {
            TopOptKit.DesignBoxSpec(min: SIMD3<Double>($0.min), max: SIMD3<Double>($0.max))
        }
    }
}

/// Single-owner drag arbitration for the design-box handles (design-overhaul 109 — fixes the
/// "ghost duplicate boxes" bug).
///
/// THE BUG: the workspace draws 6 face handles + a move handle for the design box, and the
/// same set per keep-out. Every one of them mutated ONE `project.designBox.box` from a single
/// shared drag-base snapshot (`dragBaseBox`) that was captured when nil and cleared only on
/// `.onEnded`. The handle hit-targets are each expanded to ~44 pt (`contentShape(inset: -12)`),
/// so when they overlap — a small or edge-on box clusters the face handles near the centre
/// move handle — a single touch drives TWO gestures at once. Both read the SAME shared base but
/// computed COMPETING poses (a whole-box translate vs a single-face resize), and both wrote the
/// box every frame, so it flipped between two transforms — read on screen as ghost duplicate
/// boxes tracking at different speeds/directions. A missed `.onEnded` compounded it by leaving
/// a stale base the NEXT handle's drag then applied its delta to.
///
/// THE FIX: make the drag single-owner. The first handle to `begin` claims the drag and
/// captures ITS OWN base once; any `begin`/`base` from a different handle while it is held is
/// REJECTED (nil) until the owner `end`s. Exactly one handle ever writes the box, and a stale
/// or duplicate gesture can't corrupt it. Pure value type + headless-tested; the SwiftUI
/// gesture wiring that calls it is device QA.
public struct DesignBoxDragSession: Equatable, Sendable {
    /// Which handle a drag belongs to — the identity that arbitrates ownership.
    public struct HandleID: Equatable, Sendable {
        /// The design box itself, or a keep-out by index.
        public enum Target: Equatable, Sendable { case designBox; case keepOut(Int) }
        /// The centre move handle, or a face-resize handle (axis 0/1/2, ±face).
        public enum Kind: Equatable, Sendable { case move; case face(axis: Int, isMax: Bool) }
        public let target: Target
        public let kind: Kind
        public init(target: Target, kind: Kind) {
            self.target = target
            self.kind = kind
        }

        /// A STABLE total order over every handle, so the single-gesture hit-test
        /// (handoff 111) breaks an exact-distance tie the SAME way every frame,
        /// independent of the order candidates are supplied in: the design box before
        /// any keep-out (by index), the move handle before the faces, faces by axis
        /// (0→2) then min-before-max. Two handles never share a rank.
        public var tieBreakRank: Int {
            let targetRank: Int
            switch target {
            case .designBox: targetRank = 0
            case .keepOut(let i): targetRank = 1 + Swift.max(0, i)
            }
            let kindRank: Int
            switch kind {
            case .move: kindRank = 0
            case .face(let axis, let isMax): kindRank = 1 + axis * 2 + (isMax ? 1 : 0)
            }
            return targetRank * 100 + kindRank
        }
    }

    private var owner: HandleID?
    private var snapshot: DesignBoxBounds?

    public init() {}

    /// True while some handle owns an in-flight drag.
    public var isActive: Bool { owner != nil }
    /// The handle currently owning the drag, if any.
    public var activeOwner: HandleID? { owner }

    /// Claim (or continue) the drag for `handle`, returning the base bounds to compute the
    /// drag against — but ONLY if the drag is free or already owned by this SAME handle. If a
    /// different handle owns it, returns nil so the caller drops the stray gesture. The base is
    /// captured exactly ONCE, on the claiming call, and never re-captured mid-drag, so each
    /// frame's absolute delta measures from where the box was when the drag began.
    @discardableResult
    public mutating func begin(_ handle: HandleID, current: DesignBoxBounds?) -> DesignBoxBounds? {
        if let owner, owner != handle { return nil }   // another handle owns the drag → reject
        if owner == nil { owner = handle; snapshot = current }
        return snapshot
    }

    /// The captured base for `handle` if it owns the drag, else nil.
    public func base(for handle: HandleID) -> DesignBoxBounds? {
        owner == handle ? snapshot : nil
    }

    /// Release the drag if `handle` owns it (a stale `end` from a non-owner is ignored, so it
    /// can't tear down another handle's live drag).
    public mutating func end(_ handle: HandleID) {
        guard owner == handle else { return }
        owner = nil
        snapshot = nil
    }
}

/// Pure camera math for the design-box drag handles: turning an on-screen drag into
/// a model-space displacement along one axis. Kept out of SwiftUI so the projection
/// arithmetic is unit-tested headlessly (the gizmo gesture that calls it is device QA).
public enum DesignBoxDrag {
    /// The model-space (mm) displacement along `worldAxis` that a screen drag of
    /// `drag` points represents, given where the handle sits in world space and the
    /// camera projection. Returns 0 when the axis projects to a near-zero on-screen
    /// length (edge-on) so a degenerate view can't fling the handle.
    ///
    /// `worldAxis` is the (settled) world-space direction of the box axis; the returned
    /// scalar is applied directly to the MODEL-space box because a settle is a pure
    /// rotation (distance along a rotated axis equals distance along the model axis).
    /// `probe` is a small world-space step used to measure the axis' screen scale.
    public static func axisDelta(handleWorld: SIMD3<Float>, worldAxis: SIMD3<Float>,
                                 drag: CGVector, projection: CameraProjection,
                                 probe: Float) -> Float {
        guard probe > 0,
              let pA = projection.project(handleWorld),
              let pB = projection.project(handleWorld + worldAxis * probe) else { return 0 }
        let sx = Float(pB.x - pA.x), sy = Float(pB.y - pA.y)
        let screenLen = (sx * sx + sy * sy).squareRoot()
        guard screenLen > 1e-4 else { return 0 }
        let ux = sx / screenLen, uy = sy / screenLen           // unit screen dir of +axis
        let along = Float(drag.dx) * ux + Float(drag.dy) * uy  // drag component along it (points)
        let screenPerWorld = screenLen / probe                 // points per mm
        return along / screenPerWorld
    }
}

/// The single-gesture hit-test that replaces the per-handle gestures (handoff 111 —
/// the design-box drag redesign). BEFORE 111 every box/keep-out handle carried its
/// OWN `DragGesture`; when the ~44 pt targets overlapped (a small or edge-on box)
/// a single touch drove two gestures at once and the box flipped between competing
/// poses (teleport + "ghost duplicate boxes"). Now ONE gesture on the overlay hit-
/// tests the touch-down point HERE, picking exactly one handle, so overlapping
/// handles are impossible by construction — there is only ever one gesture and one
/// chosen handle. Pure value math (points in one coordinate space), unit-tested; the
/// SwiftUI gesture that calls it is device QA.
public enum DesignBoxHitTest {
    /// One candidate handle for the chooser: its identity and where it sits on screen
    /// (points, in the overlay's coordinate space — the same space the touch is read
    /// in, so the distance is a straight subtraction).
    public struct Target: Equatable, Sendable {
        public let handle: DesignBoxDragSession.HandleID
        public let screen: CGPoint
        public init(handle: DesignBoxDragSession.HandleID, screen: CGPoint) {
            self.handle = handle
            self.screen = screen
        }
    }

    /// The handle whose screen point is NEAREST `point`, but only if within `radius`
    /// points; nil when the touch landed outside every handle's grab circle (so the
    /// caller drops the drag and the touch falls through to the camera). An exact
    /// distance tie is broken by `HandleID.tieBreakRank` — deterministic and
    /// independent of the order `targets` is supplied in.
    public static func choose(at point: CGPoint, among targets: [Target],
                              radius: CGFloat) -> DesignBoxDragSession.HandleID? {
        let r2 = radius * radius
        var best: (handle: DesignBoxDragSession.HandleID, d2: CGFloat)?
        for t in targets {
            let dx = t.screen.x - point.x, dy = t.screen.y - point.y
            let d2 = dx * dx + dy * dy
            guard d2 <= r2 else { continue }
            if let b = best {
                if d2 < b.d2 || (d2 == b.d2 && t.handle.tieBreakRank < b.handle.tieBreakRank) {
                    best = (t.handle, d2)
                }
            } else {
                best = (t.handle, d2)
            }
        }
        return best?.handle
    }
}

/// Builds the CANONICAL handle set for a design box + keep-outs, each projected to a
/// screen point (handoff 111). `settledWorld` rotates a model point into its settled
/// world pose; `project` turns a world point into an overlay point (nil = off-screen /
/// behind the camera → the handle is skipped). Order matches `HandleID.tieBreakRank`
/// so the on-screen candidates and the tie order agree. Pure (closures carry all the
/// view/camera state), so the overlay's hit-set is unit-tested headlessly.
public enum DesignBoxHandles {
    public static func candidates(box: DesignBoxBounds?, keepOuts: [DesignBoxBounds],
                                  settledWorld: (SIMD3<Float>) -> SIMD3<Float>,
                                  project: (SIMD3<Float>) -> CGPoint?) -> [DesignBoxHitTest.Target] {
        var out: [DesignBoxHitTest.Target] = []
        func add(_ handle: DesignBoxDragSession.HandleID, _ modelPoint: SIMD3<Float>) {
            if let pt = project(settledWorld(modelPoint)) {
                out.append(DesignBoxHitTest.Target(handle: handle, screen: pt))
            }
        }
        func addBox(_ b: DesignBoxBounds, target: DesignBoxDragSession.HandleID.Target) {
            add(DesignBoxDragSession.HandleID(target: target, kind: .move), b.center)
            for i in 0..<6 {
                let axis = i / 2, isMax = (i % 2 == 1)
                add(DesignBoxDragSession.HandleID(target: target, kind: .face(axis: axis, isMax: isMax)),
                    b.faceCenter(axis: axis, isMax: isMax))
            }
        }
        if let box { addBox(box, target: .designBox) }
        for (idx, ko) in keepOuts.enumerated() { addBox(ko, target: .keepOut(idx)) }
        return out
    }
}

/// Magnetic face-detent math for design-box (and keep-out) face dragging (device round 3, item
/// 10). While a face handle drags along an axis, its plane can SNAP to a nearby part feature
/// plane perpendicular to that axis — a part planar face, or the part AABB extent. Enter the
/// detent within `snapThresholdMM`; escape only past `releaseThresholdMM` (~2×) — hysteresis so
/// the snap holds without chattering. Pure + headless-tested; the flash/haptic feedback and the
/// gesture that calls this are device QA.
public enum DesignBoxDetent {
    /// Snap radius (model-space mm). A face within this of a candidate detents to it.
    public static let snapThresholdMM: Float = 1.5
    /// Escape band as a multiple of the snap threshold (drag past this to leave a detent).
    public static let releaseMultiple: Float = 2.0
    /// The escape distance (mm): the raw drag must leave this band around the held candidate.
    public static var releaseThresholdMM: Float { snapThresholdMM * releaseMultiple }

    /// The candidate snap coordinates along `axis` (0=x,1=y,2=z): every part planar face whose
    /// normal is (anti)parallel to that axis contributes its plane coordinate, plus the part AABB
    /// min/max extents on that axis. Sorted + de-duplicated within `epsilon` so coincident
    /// faces/AABB don't yield redundant targets. `faces` is the 127-bridge per-face geometry.
    public static func candidates(axis: Int, faces: [StepFaceGeometry],
                                  aabbMin: SIMD3<Float>, aabbMax: SIMD3<Float>,
                                  epsilon: Float = 1e-3) -> [Float] {
        var raw: [Float] = [aabbMin[axis], aabbMax[axis]]
        for f in faces where f.isPlane {
            let n = SIMD3<Float>(f.planeNormal)
            let len = simd_length(n)
            guard len > 1e-6, abs(n[axis]) >= 0.999 * len else { continue }   // ⟂ to the drag axis
            raw.append(SIMD3<Float>(f.planeOrigin)[axis])
        }
        var uniq: [Float] = []
        for c in raw.sorted() where (uniq.last.map { abs($0 - c) > epsilon } ?? true) { uniq.append(c) }
        return uniq
    }

    /// The nearest candidate to `coord` within `threshold`, or nil if none is close enough.
    public static func nearestCandidate(to coord: Float, candidates: [Float],
                                        threshold: Float = snapThresholdMM) -> Float? {
        var best: Float?
        var bestD = threshold
        for c in candidates {
            let d = abs(c - coord)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// Resolve a dragged face coordinate with hysteresis. `rawCoord` is where the un-snapped drag
    /// would place the face; `current` is the candidate the face is presently detented to (nil =
    /// free). Returns the coordinate to apply and the candidate now held (nil = free). While
    /// detented the face STAYS on the candidate until the raw drag exceeds the release band; when
    /// free it snaps to any candidate within the snap threshold. `didSnap` is true whenever the
    /// result is a fresh entry into a detent (the caller flashes the matched face + ticks haptics).
    public static func resolve(rawCoord: Float, candidates: [Float], current: Float?)
        -> (coord: Float, snapped: Float?, didSnap: Bool) {
        if let c = current, abs(rawCoord - c) <= releaseThresholdMM {
            return (c, c, false)                      // held at the detent (inside the escape band)
        }
        if let near = nearestCandidate(to: rawCoord, candidates: candidates) {
            let fresh = current != near               // entered or switched detents
            return (near, near, fresh)
        }
        return (rawCoord, nil, false)                 // free
    }

    /// The B-rep face id whose planar face (perpendicular to `axis`) sits at `coord`, or nil when
    /// the snap target was a part AABB extent rather than a real face (nothing to highlight). Used
    /// by the viewer to PULSE the matched part face on a fresh detent (device round 3, item 2). The
    /// index into `faces` IS the face id (`ViewerMesh.faceGeometry` is indexed by face id); when
    /// several coincident faces share the plane the lowest id wins (deterministic).
    public static func matchedFace(axis: Int, coord: Float, faces: [StepFaceGeometry],
                                   epsilon: Float = snapThresholdMM) -> FaceID? {
        var best: (id: FaceID, d: Float)?
        for (i, f) in faces.enumerated() where f.isPlane {
            let n = SIMD3<Float>(f.planeNormal)
            let len = simd_length(n)
            guard len > 1e-6, abs(n[axis]) >= 0.999 * len else { continue }   // ⟂ to the drag axis
            let d = abs(SIMD3<Float>(f.planeOrigin)[axis] - coord)
            guard d <= epsilon else { continue }
            if best == nil || d < best!.d { best = (FaceID(i), d) }
        }
        return best?.id
    }

    /// The result of running the whole face-drag detent pipeline: the applied box, the candidate
    /// now held (nil = free), whether this call freshly ENTERED a detent (→ flash + haptic), and
    /// the matched part face to pulse (nil for an AABB-extent snap or no snap).
    public struct FaceDragResult: Equatable {
        public let bounds: DesignBoxBounds
        public let detent: Float?
        public let didSnap: Bool
        public let matchedFace: FaceID?
        public init(bounds: DesignBoxBounds, detent: Float?, didSnap: Bool, matchedFace: FaceID?) {
            self.bounds = bounds; self.detent = detent; self.didSnap = didSnap; self.matchedFace = matchedFace
        }
    }

    /// The COMPLETE face-drag detent pipeline the drag gesture runs (round-4 item 5): from a raw
    /// (un-snapped) face-plane coordinate `rawTarget` to the applied box + detent state + the face
    /// to pulse. Composes `candidates` → `resolve` (hysteresis) → `DesignBoxBounds.movingFace` →
    /// `matchedFace` in one place, so the gesture and its integration test share the exact same
    /// path — a dead wire here fails the test, not just the isolated math. `current` is the detent
    /// held from the previous drag frame; pass `result.detent` back in on the next frame.
    public static func applyFaceDrag(axis: Int, isMax: Bool, base: DesignBoxBounds, rawTarget: Float,
                                     faces: [StepFaceGeometry], aabbMin: SIMD3<Float>, aabbMax: SIMD3<Float>,
                                     current: Float?, minSize: Float) -> FaceDragResult {
        let cands = candidates(axis: axis, faces: faces, aabbMin: aabbMin, aabbMax: aabbMax)
        let d = resolve(rawCoord: rawTarget, candidates: cands, current: current)
        let moved = base.movingFace(axis: axis, isMax: isMax, to: d.coord, minSize: minSize)
        let face = d.didSnap ? matchedFace(axis: axis, coord: d.coord, faces: faces) : nil
        return FaceDragResult(bounds: moved, detent: d.snapped, didSnap: d.didSnap, matchedFace: face)
    }
}
