// CutAim.swift — B8 (rows 36, R1; round 3 P6; plan §B8; mockup #cut-line, #cut-hole, #cut-hole-across, #cut-hole-along,
// #cut-plane-ask, #cut-ring): WHERE A CUT LIES, by the face it is on.
//
//   • A FLAT face: the line lies on the face. Rotate turns it in the face (15° steps, any angle); its ↕ handle and the mm
//     number slide it across the face. No Tilt (a flat face's line only turns: "one word for one thing").
//   • A HOLE: first [Along the hole │ Across the hole].
//       Across — a ring round the bore. Tilt leans it (±60°), Rotate says which way it leans (0–359°), the ↕ handle and the
//       mm number move it up and down the bore.
//       Along — a line down the bore. Tilt slants it, Rotate carries it round the bore; its ⟲ handle drags it round.
//   • ANYTHING ELSE (a round side, a rounded edge, a curved face): first "Which plane?" [Around it │ Down it │ At an angle].
//     Around it is Across, Down it is Along, At an angle is Across leaning 30°, about the face's own axis (a round side's
//     cylinder axis; for a free-form face, the direction its normals turn least about).
//
// Tilt never moves the cut and the handle never angles it (R1). Pure geometry over value types: no view, no camera.

import Foundation
import CoreGraphics
import simd

public struct CutAim: Equatable, Sendable {

    /// What the face is, for the cut.
    public enum Shape: Equatable, Sendable {
        /// A flat face, its outward normal.
        case flat(normal: SIMD3<Double>)
        /// A hole: its bore axis and radius.
        case hole(axis: SIMD3<Double>, radius: Double)
        /// Anything else: its axis (a cylinder's, or the fitted one) and the piece's mean distance from it.
        case free(axis: SIMD3<Double>, radius: Double)
    }

    /// How the cut lies once asked.
    public enum Way: String, Equatable, Sendable {
        /// On a flat face: a line on it.
        case line
        /// A ring round the axis (Across the hole, Around it, At an angle).
        case across
        /// A line down the axis (Along the hole, Down it).
        case along
    }

    /// The question asked before the line shows.
    public enum Ask: Equatable, Sendable { case hole, plane }

    public let face: FaceID
    /// Flat: the piece's middle. Otherwise: the piece's middle taken onto its axis.
    public let centre: SIMD3<Double>
    public let shape: Shape
    /// The piece's reach from `centre`: across a flat face (±), along the axis (lo … hi) otherwise.
    public let reach: ClosedRange<Double>
    /// nil while it asks.
    public var way: Way?
    /// ±60° (R1: "Tilt stops at ±60°"). Not on a flat face.
    public var tiltDeg: Double = 0
    /// 0–359°.
    public var rotateDeg: Double = 0
    /// mm: across a flat face, along the axis for a ring. An along line has none (its handle turns it round).
    public var offsetMM: Double = 0

    public static let tiltLimit = 60.0
    /// "At an angle" starts leaning this far.
    public static let atAnAngleDeg = 30.0

    public init(face: FaceID, centre: SIMD3<Double>, shape: Shape, reach: ClosedRange<Double>, way: Way? = nil) {
        self.face = face; self.centre = centre; self.shape = shape; self.reach = reach
        if case .flat = shape { self.way = .line } else { self.way = way }
    }

    // MARK: - what the page shows

    /// The question it asks first, or nil once the way is known.
    public var asks: Ask? {
        guard way == nil else { return nil }
        if case .hole = shape { return .hole }
        return .plane
    }

    /// A Tilt shows beside Rotate everywhere but on a flat face (P6).
    public var showsTilt: Bool { way != .line }
    /// The mm number and the ↕ handle: a flat line and a ring move; an along line turns round (⟲) instead.
    public var moves: Bool { way == .line || way == .across }

    /// The answers. Hole: Along / Across. Plane: Around it / Down it / At an angle.
    public mutating func answer(_ w: Way, atAnAngle: Bool = false) {
        way = w
        tiltDeg = atAnAngle ? Self.atAnAngleDeg : 0
        rotateDeg = 0
        offsetMM = 0
    }

    public mutating func setTilt(_ d: Double) { tiltDeg = min(Self.tiltLimit, max(-Self.tiltLimit, d)) }
    public mutating func setRotate(_ d: Double) { var x = d.truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; rotateDeg = x }
    public mutating func setOffset(_ mm: Double) { offsetMM = min(reach.upperBound, max(reach.lowerBound, mm)) }

    // MARK: - the plane

    /// The axis a ring or along-line turns about (unit); a flat face's own normal.
    public var axis: SIMD3<Double> {
        switch shape {
        case .flat(let n): return Self.unit(n)
        case .hole(let a, _), .free(let a, _): return Self.unit(a)
        }
    }

    var radius: Double {
        switch shape {
        case .flat: return 0
        case .hole(_, let r), .free(_, let r): return r
        }
    }

    /// A unit direction square to the axis at `deg` round it (0° = a fixed, stable start).
    public func around(_ deg: Double) -> SIMD3<Double> {
        let a = axis, u = Self.orthogonal(to: a), v = simd_cross(a, u)
        let t = deg * .pi / 180
        return simd_normalize(u * cos(t) + v * sin(t))
    }

    /// ★ THE CUT PLANE: a point on it and its unit normal (the half-space the pieces are made by).
    public var plane: (point: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard let way else { return nil }
        let a = axis, t = tiltDeg * .pi / 180
        switch way {
        case .line:
            // a plane standing up out of the face; Rotate turns it about the face's normal; the offset slides it across
            let n = around(rotateDeg)
            return (centre + n * offsetMM, n)
        case .across:
            // square to the axis, leaning `tilt` toward `rotate`; moved along the axis by the offset
            let n = simd_normalize(a * cos(t) + around(rotateDeg) * sin(t))
            return (centre + a * offsetMM, n)
        case .along:
            // through the axis at `rotate`; Tilt turns it about that radial line, so the line slants down the bore
            let r = around(rotateDeg)
            let n0 = simd_cross(a, r)
            return (centre, simd_normalize(n0 * cos(t) + a * sin(t)))
        }
    }

    /// ★ WHERE THE HANDLE SITS AND WHICH WAY IT DRAGS (model space): on the line; ↕ along the move, ⟲ round the bore.
    public var handle: (point: SIMD3<Double>, direction: SIMD3<Double>, around: Bool)? {
        guard let way, let pl = plane else { return nil }
        switch way {
        case .line:
            return (pl.point, pl.normal, false)
        case .across:
            // on the ring, at the side it leans toward: where the plane meets the line at radius r and azimuth `rotate`
            let d = around(rotateDeg), a = axis
            let base = centre + d * radius
            let den = simd_dot(pl.normal, a)
            let h = abs(den) > 1e-9 ? simd_dot(pl.normal, pl.point - base) / den : 0
            return (base + a * h, a, false)
        case .along:
            let d = around(rotateDeg)
            return (centre + d * radius, simd_cross(axis, d), true)
        }
    }

    /// The handle's drag, in model mm along its direction: a move (mm) or, round a bore, a turn (degrees).
    public mutating func drag(byMM s: Double, from start: CutAim) {
        if way == .along {
            let r = max(radius, 1e-3)
            setRotate(start.rotateDeg + s / r * 180 / .pi)
        } else {
            setOffset(start.offsetMM + s)
        }
    }

    /// The cut as the project commits it (`ProjectModel.commitSurfaceCut`).
    public func surfaceCut() -> SurfaceCut? {
        guard let pl = plane else { return nil }
        return SurfaceCut(point: pl.point, normal: pl.normal, faceID: face, faceNormal: axis)
    }

    // MARK: - building one from a tap

    /// ★ THE AIM FOR A TAPPED FACE (or one piece of it): flat, a hole, or anything else.
    public static func make(face: FaceID, piece: RegionID?, regions: FaceRegionModel, mesh: ViewerMesh) -> CutAim? {
        let pts = points(face: face, piece: piece, regions: regions, mesh: mesh)
        guard !pts.isEmpty else { return nil }
        let mid = pts.reduce(SIMD3<Double>(repeating: 0), +) / Double(pts.count)
        if let g = mesh.faceGeometry(face) {
            switch g.kind {
            case .plane:
                return flat(face, mid, pts, SurfaceCut.faceNormal(of: face, in: mesh))
            case .cylinder where g.isCylinder && simd_length(g.axisDir) > 1e-9:
                let a = unit(g.axisDir), o = g.axisPoint
                let hole = FaceTopology.isFastenerBore(face, in: mesh)
                return axial(face, pts, axisPoint: o, axis: a, radius: g.cylinderRadiusMM, hole: hole)
            default:
                break
            }
        } else if !bent(face, mesh) {
            return flat(face, mid, pts, SurfaceCut.faceNormal(of: face, in: mesh))
        }
        // anything else: the direction its normals turn least about, through the circle its points make square to it
        let a = fittedAxis(face, mesh)
        let fit = circle(pts, axis: a, near: mid)
        return axial(face, pts, axisPoint: fit.centre, axis: a, radius: fit.radius, hole: false)
    }

    /// ★ THE AXIS LINE'S PLACE: the points taken onto the plane square to `axis`, a least-squares circle through them
    /// (Kåsa). A face that makes no circle (nearly straight across) keeps the axis through its middle, radius 0.
    static func circle(_ pts: [SIMD3<Double>], axis a: SIMD3<Double>, near mid: SIMD3<Double>)
        -> (centre: SIMD3<Double>, radius: Double) {
        let u = orthogonal(to: a), v = simd_cross(a, u)
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0, sxz = 0.0, syz = 0.0, sz = 0.0
        let n = Double(pts.count)
        for p in pts {
            let d = p - mid, x = simd_dot(d, u), y = simd_dot(d, v), z = x * x + y * y
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; sxz += x * z; syz += y * z; sz += z
        }
        // [sxx sxy sx; sxy syy sy; sx sy n] · [D E F] = −[sxz syz sz]
        let m = simd_double3x3(rows: [SIMD3(sxx, sxy, sx), SIMD3(sxy, syy, sy), SIMD3(sx, sy, n)])
        guard abs(m.determinant) > 1e-9 else { return (mid, 0) }
        let s = m.inverse * SIMD3(-sxz, -syz, -sz)
        let cx = -s.x / 2, cy = -s.y / 2, r2 = cx * cx + cy * cy - s.z
        guard r2 > 0, r2.squareRoot() < 1e4 else { return (mid, 0) }
        return (mid + u * cx + v * cy, r2.squareRoot())
    }

    static func flat(_ face: FaceID, _ mid: SIMD3<Double>, _ pts: [SIMD3<Double>], _ n: SIMD3<Double>) -> CutAim {
        let r = pts.map { simd_length($0 - mid) }.max() ?? 0
        return CutAim(face: face, centre: mid, shape: .flat(normal: unit(n)), reach: -r...r)
    }

    static func axial(_ face: FaceID, _ pts: [SIMD3<Double>], axisPoint o: SIMD3<Double>, axis a: SIMD3<Double>,
                      radius: Double, hole: Bool) -> CutAim {
        let ts = pts.map { simd_dot($0 - o, a) }
        let lo = ts.min() ?? 0, hi = ts.max() ?? 0, tc = (lo + hi) / 2
        let centre = o + a * tc
        let shape: Shape = hole ? .hole(axis: a, radius: radius) : .free(axis: a, radius: radius)
        return CutAim(face: face, centre: centre, shape: shape, reach: (lo - tc)...(hi - tc))
    }

    /// The piece's vertices (a region's: those on its own side of its cuts).
    static func points(face: FaceID, piece: RegionID?, regions: FaceRegionModel, mesh: ViewerMesh) -> [SIMD3<Double>] {
        let cuts = piece.flatMap { regions.region($0)?.cuts } ?? []
        var out: [SIMD3<Double>] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face {
                for k in 0..<3 {
                    let vi = Int(mesh.indices[t + k]) * 3
                    guard vi + 2 < mesh.positions.count else { continue }
                    let v = SIMD3<Double>(Double(mesh.positions[vi]), Double(mesh.positions[vi + 1]), Double(mesh.positions[vi + 2]))
                    if cuts.isEmpty || FaceRegionGeometry.inside(v, cuts) { out.append(v) }
                }
            }
            t += 3
        }
        return out
    }

    /// A face with no CAD geometry is curved when a triangle turns more than FaceTopology's 5° from its own normal.
    static func bent(_ face: FaceID, _ mesh: ViewerMesh) -> Bool {
        let n = SurfaceCut.faceNormal(of: face, in: mesh)
        let turn = cos(Double(FaceTopology.curveThresholdDeg) * .pi / 180)
        return triangleNormals(face, mesh).contains { simd_dot($0.n, n) < turn }
    }

    static func triangleNormals(_ face: FaceID, _ mesh: ViewerMesh) -> [(n: SIMD3<Double>, area: Double)] {
        var out: [(SIMD3<Double>, Double)] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face {
                func v(_ k: Int) -> SIMD3<Double> {
                    let b = Int(mesh.indices[t + k]) * 3
                    return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
                }
                let c = simd_cross(v(1) - v(0), v(2) - v(0))
                let l = simd_length(c)
                if l > 1e-12 { out.append((c / l, l / 2)) }
            }
            t += 3
        }
        return out
    }

    /// ★ THE FITTED AXIS: the eigenvector of Σ area·n·nᵀ with the SMALLEST eigenvalue — the direction the face's normals
    /// have least of. On a cylinder-like face that is its axis exactly (every normal is square to it).
    static func fittedAxis(_ face: FaceID, _ mesh: ViewerMesh) -> SIMD3<Double> {
        var m = simd_double3x3(0)
        for (n, a) in triangleNormals(face, mesh) {
            m = m + simd_double3x3(columns: (n * (n.x * a), n * (n.y * a), n * (n.z * a)))
        }
        // the largest eigenvector of (trace·I − M) is M's smallest: power iteration from three starts, the best kept
        let tr = m[0][0] + m[1][1] + m[2][2]
        let s = simd_double3x3(diagonal: SIMD3(repeating: tr)) - m
        var best = SIMD3<Double>(0, 0, 1), bestScore = -Double.infinity
        for start in [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)] {
            var x = start
            for _ in 0..<64 {
                let y = s * x
                guard simd_length(y) > 1e-15 else { break }
                x = simd_normalize(y)
            }
            let score = simd_dot(x, s * x)
            if score > bestScore { bestScore = score; best = x }
        }
        return unit(best)
    }

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { simd_length(v) > 1e-12 ? simd_normalize(v) : SIMD3(0, 0, 1) }

    /// A unit vector square to `n`, the same every time (so 0° is stable).
    static func orthogonal(to n: SIMD3<Double>) -> SIMD3<Double> { SurfaceCut.orthogonal(to: unit(n)) }
}

/// Tests (a synthesised click never picks a face in an offscreen Metal view, and a drag never reaches a gesture there): the
/// Edit faces page's own calls, as it last built them.
@MainActor
public enum CutLive {
    public static var recordLive = false
    /// The page's tap on a face (handleSurfacePick, no 3D point: the deepest piece holding the face).
    public static var pick: ((FaceID) -> Void)?
    /// The aim as the page last drew it (nil: no Cut aimed).
    public static var aim: CutAim?
    /// The cut handle's drag, in points along its axis (`ended` once, on release) — DragHandle's own closure.
    public static var handleDrag: ((CGFloat, Bool) -> Void)?

    public static func reset() {
        recordLive = false; pick = nil; aim = nil; handleDrag = nil
    }
}
