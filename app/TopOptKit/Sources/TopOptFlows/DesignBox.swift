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
