// PlacedBox.swift — ★ HIS 11-21: "please make ALL boxes the exact same as the Design Box in TO. It has to have the same
// mechanisms including the detents against faces. The zones in the Lattice area need to be EXACTLY the same - with handles
// against each face and magnetically connected to faces. ... Do the same for Cylinders. ... Keep whatever colours are in place
// of the box you're replacing - that's all." His pick: "Keep the extras" (Turn, Copy, snapping onto a bore's axis and the
// keep-clear knobs stay).
//
// Every box or cylinder he places — a Lattice zone, a hand-placed Keep clear box or cylinder in a Topology group — is edited as
// the Design Box is: a liquid-glass square on the middle of each of its six faces and the move dot at its middle. A face square
// moves THAT face only, along the box's own axis, and snaps to the part's flat faces facing the same way (and to the part's
// outer extent) inside `DesignBoxDetent.snapThresholdMM`, leaving only past its release band — the Design Box's own numbers and
// hysteresis (`DesignBoxDetent.resolve`). The move dot slides the box as the Design Box's does (model x and z). A cylinder is its
// bounding box, square across its axis (the Design Box's cylinder): an end square sets its height, a side square its diameter.
//
// The Design Box's own boxes stay square to the part (DesignBox.swift, unchanged); these may be turned, so everything here runs
// on the box's own three axes (for a box square to the part it is the Design Box's math exactly). Pure: PlacedBoxTests.

import Foundation
import CoreGraphics
import simd
import TopOptKit

/// A placed box (or a cylinder's bounding box) in MODEL space (mm), on its own three unit axes.
public struct PlacedBox: Equatable, Sendable {
    public var center: SIMD3<Double>
    /// u, v, w: unit and square to each other. A cylinder's length is w.
    public var axes: [SIMD3<Double>]
    /// Half its size along each axis (a cylinder: radius, radius, half its height).
    public var half: SIMD3<Double>
    public var isCylinder: Bool

    public init(center: SIMD3<Double>, axes: [SIMD3<Double>], half: SIMD3<Double>, isCylinder: Bool = false) {
        self.center = center
        self.axes = axes.count == 3 ? axes : [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        self.half = simd_max(half, SIMD3(repeating: 0))
        self.isCylinder = isCylinder
    }

    /// The middle of one face (`axis` 0/1/2 = u/v/w; `isMax` the + side).
    public func faceCenter(_ axis: Int, isMax: Bool) -> SIMD3<Double> {
        center + axes[axis] * (isMax ? half[axis] : -half[axis])
    }

    /// Where a face sits along its own axis (a plane coordinate, as the Design Box's `min`/`max`).
    public func faceCoord(_ axis: Int, isMax: Bool) -> Double {
        simd_dot(center, axes[axis]) + (isMax ? half[axis] : -half[axis])
    }

    /// One face moved along its axis to `coord`; the opposite face stays (the Design Box's `movingFace`), never closer than
    /// `minSize`. A cylinder stays round: a side face sets both cross sizes (the Design Box's `DesignPrimitive.write`).
    public func movingFace(_ axis: Int, isMax: Bool, to coord: Double, minSize: Double) -> PlacedBox {
        let c = simd_dot(center, axes[axis])
        var lo = c - half[axis], hi = c + half[axis]
        let floor = Swift.max(minSize, 1e-4)
        if isMax { hi = Swift.max(coord, lo + floor) } else { lo = Swift.min(coord, hi - floor) }
        var b = self
        b.center += axes[axis] * ((lo + hi) / 2 - c)
        b.half[axis] = (hi - lo) / 2
        if isCylinder, axis < 2 { b.half[1 - axis] = b.half[axis] }
        return b
    }

    public func translated(by d: SIMD3<Double>) -> PlacedBox {
        var b = self
        b.center += d
        return b
    }
}

/// One handle: the move dot or a face square, of one placed box (`key` names the box).
public struct PlacedBoxHandle: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable { case move; case face(axis: Int, isMax: Bool) }
    public var key: String
    public var kind: Kind
    public init(key: String, kind: Kind) { self.key = key; self.kind = kind }

    /// The frame key its square or dot publishes ("placedBox-<key>-move", "placedBox-<key>-w+").
    public var frameKey: String {
        switch kind {
        case .move: return "placedBox-\(key)-move"
        case .face(let a, let isMax): return "placedBox-\(key)-\(["u", "v", "w"][a])\(isMax ? "+" : "-")"
        }
    }

    /// The seven handles of a box, in the Design Box's order: the move dot, then each axis' two faces.
    public static func all(_ key: String) -> [PlacedBoxHandle] {
        [PlacedBoxHandle(key: key, kind: .move)]
            + (0..<3).flatMap { a in [false, true].map { PlacedBoxHandle(key: key, kind: .face(axis: a, isMax: $0)) } }
    }

    /// Where it sits on the box (model mm).
    public func anchor(_ b: PlacedBox) -> SIMD3<Double> {
        switch kind {
        case .move: return b.center
        case .face(let a, let isMax): return b.faceCenter(a, isMax: isMax)
        }
    }

    /// The handle under a touch: the nearest within `radius` points (the Design Box's `DesignBoxHitTest.choose`).
    public static func choose(at p: CGPoint, among targets: [(handle: PlacedBoxHandle, screen: CGPoint)],
                              radius: CGFloat) -> PlacedBoxHandle? {
        var best: (PlacedBoxHandle, CGFloat)?
        for t in targets {
            let d = hypot(t.screen.x - p.x, t.screen.y - p.y)
            if d <= radius, best == nil || d < best!.1 { best = (t.handle, d) }
        }
        return best?.0
    }
}

/// The Design Box's magnetic face detent on a box's own axis.
public enum PlacedBoxDetent {
    /// The snap coordinates along `d` (unit): every flat face of the part facing along ±d (within the Design Box's 0.999), and
    /// the part's outer extent along d. Sorted, coincident ones merged. For d = a model axis these are the Design Box's.
    public static func candidates(direction d: SIMD3<Double>, faces: [StepFaceGeometry],
                                  partMin: SIMD3<Double>, partMax: SIMD3<Double>, epsilon: Double = 1e-3) -> [Double] {
        var corners: [Double] = []
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? partMin.x : partMax.x, i & 2 == 0 ? partMin.y : partMax.y, i & 4 == 0 ? partMin.z : partMax.z)
            corners.append(simd_dot(c, d))
        }
        var raw: [Double] = [corners.min() ?? 0, corners.max() ?? 0]
        for f in faces where f.isPlane {
            let n = f.planeNormal
            let len = simd_length(n)
            guard len > 1e-9, abs(simd_dot(n, d)) >= 0.999 * len else { continue }
            raw.append(simd_dot(f.planeOrigin, d))
        }
        var uniq: [Double] = []
        for c in raw.sorted() where (uniq.last.map { abs($0 - c) > epsilon } ?? true) { uniq.append(c) }
        return uniq
    }

    /// The part face lying at `coord` along `d` (the one to pulse), nil for an outer-extent snap.
    public static func matchedFace(direction d: SIMD3<Double>, coord: Double, faces: [StepFaceGeometry],
                                   epsilon: Double = Double(DesignBoxDetent.snapThresholdMM)) -> FaceID? {
        var best: (id: FaceID, d: Double)?
        for (i, f) in faces.enumerated() where f.isPlane {
            let n = f.planeNormal
            let len = simd_length(n)
            guard len > 1e-9, abs(simd_dot(n, d)) >= 0.999 * len else { continue }
            let dist = abs(simd_dot(f.planeOrigin, d) - coord)
            guard dist <= epsilon else { continue }
            if best == nil || dist < best!.d { best = (FaceID(i), dist) }
        }
        return best?.id
    }

    public struct Result: Equatable {
        public let box: PlacedBox
        /// The coordinate held (nil = free): pass it back in on the next frame.
        public let detent: Double?
        /// A fresh snap: flash the face and tick.
        public let didSnap: Bool
        public let matchedFace: FaceID?
    }

    /// The whole face-drag pipeline (the Design Box's `applyFaceDrag`): candidates → the Design Box's hysteresis → the face
    /// moved → the face to pulse.
    public static func applyFaceDrag(_ box: PlacedBox, axis: Int, isMax: Bool, rawTarget: Double, faces: [StepFaceGeometry],
                                     partMin: SIMD3<Double>, partMax: SIMD3<Double>, current: Double?,
                                     minSize: Double) -> Result {
        let d = box.axes[axis]
        let cands = candidates(direction: d, faces: faces, partMin: partMin, partMax: partMax)
        // the Design Box's own resolve, its own thresholds (Float, as it runs there)
        let r = DesignBoxDetent.resolve(rawCoord: Float(rawTarget), candidates: cands.map(Float.init),
                                        current: current.map(Float.init))
        // a held or snapped coordinate is the candidate itself, not its Float round trip
        var snapped: Double? = nil
        if let s = r.snapped {
            let at = Double(s)
            var best = at, bestD = Double.infinity
            for c in cands where abs(c - at) < bestD { best = c; bestD = abs(c - at) }
            snapped = best
        }
        let coord = snapped ?? rawTarget
        let moved = box.movingFace(axis, isMax: isMax, to: coord, minSize: minSize)
        let face = r.didSnap ? matchedFace(direction: d, coord: coord, faces: faces) : nil
        return Result(box: moved, detent: snapped, didSnap: r.didSnap, matchedFace: face)
    }
}

/// The drag in progress (one at a time, as the Design Box's `DesignBoxDragSession`): its handle, the box at its start, the
/// detent held. A reference, kept on AppModel — the workspace's stack budget takes no new @State (ipad-main-thread-stack-limit).
public final class PlacedBoxDrag {
    public var handle: PlacedBoxHandle?
    public var base: PlacedBox?
    public var detent: Double?
    public init() {}
    public func end() { handle = nil; base = nil; detent = nil }
}

/// Tests only: the page's placed-box gesture as it last built it (`LatticeSetupHandles.recordLive` turns it on).
public enum PlacedBoxLive {
    @MainActor public static var gesture: (changed: (CGPoint, CGSize) -> Void, ended: (CGPoint, CGSize) -> Void)?
    /// Each handle's point in the gesture's own space, by its frame key.
    @MainActor public static var handles: [String: CGPoint] = [:]
}

// MARK: the boxes he places, as placed boxes

extension ProjectModel {
    private static func axes(_ w: SIMD3<Double>) -> [SIMD3<Double>] {
        let (u, v) = corePlaneBasis(normal: SIMD3<Float>(w))   // the basis core reads half_u / half_w on
        return [SIMD3<Double>(u), SIMD3<Double>(v), w]
    }

    /// A Lattice zone: a Box's width (u), depth (v) and height (its axis) about its middle; a Cylinder's.
    public func latticeZoneBox(_ zone: UUID) -> PlacedBox? {
        guard let p = latticeZonePrimitive(zone), let s = latticeZoneSize(zone) else { return nil }
        let w = ManualPrimitive.unit(p.axis)
        return PlacedBox(center: latticeZoneMiddle(p), axes: Self.axes(w), half: SIMD3(s.width, s.depth, s.height) / 2,
                         isCylinder: p.kind == .bolt)
    }

    /// A zone written from its placed box: its middle and sizes (its turn unchanged).
    public func setLatticeZoneBox(_ zone: UUID, _ b: PlacedBox) {
        guard var p = latticeZonePrimitive(zone) else { return }
        let up = ManualPrimitive.unit(p.axis)
        if p.kind == .bolt {
            p.center = b.center
            p.radiusMM = Swift.max(0.5, b.half.x)
            p.halfLengthMM = Swift.max(0.5, b.half.z)
        } else {
            let h = Swift.max(1, 2 * b.half.z)
            p.halfUMM = Swift.max(0.5, b.half.x)
            p.halfWMM = Swift.max(0.5, b.half.y)
            p.center = b.center - up * (h / 2)
            lattice.selectableDepthMM[LatticeSelectableRef.primitive(p.id).key] = h
        }
        force.updateManualPrimitive(p, in: zone)
        persistClearances()
    }

    /// A hand-placed Keep clear shape: a Cylinder about its centre; a Box (core's slab: its face at `center`, reaching out along
    /// its normal by its depth) about its middle.
    public func manualPrimitiveBox(_ p: ManualPrimitive) -> PlacedBox {
        let w = ManualPrimitive.unit(p.axis)
        if p.kind == .bolt {
            return PlacedBox(center: p.center, axes: Self.axes(w), half: SIMD3(p.radiusMM, p.radiusMM, p.halfLengthMM),
                             isCylinder: true)
        }
        let depth = p.resolvedDepthMM
        return PlacedBox(center: p.center + w * (depth / 2), axes: Self.axes(w), half: SIMD3(p.halfUMM, p.halfWMM, depth / 2))
    }

    /// A Keep clear shape written from its placed box. A Box's depth is written only when its depth changed (an untouched depth
    /// stays Auto).
    public func setManualPrimitiveBox(_ id: UUID, in group: UUID, _ b: PlacedBox) {
        guard var p = manualPrimitives(in: group).first(where: { $0.id == id }) else { return }
        let w = ManualPrimitive.unit(p.axis)
        if p.kind == .bolt {
            p.center = b.center
            p.radiusMM = Swift.max(0.5, b.half.x)
            p.halfLengthMM = Swift.max(0.5, b.half.z)
        } else {
            let depth = Swift.max(0.5, 2 * b.half.z)
            p.halfUMM = Swift.max(0.5, b.half.x)
            p.halfWMM = Swift.max(0.5, b.half.y)
            p.center = b.center - w * (depth / 2)
            if abs(depth - p.resolvedDepthMM) > 1e-6 { p.override.slabDepthMM = depth }
        }
        force.updateManualPrimitive(p, in: group)
        persistClearances()
    }
}
