// FaceNames — every face's plain name: ONE namer, read by Lattice Setup's face rows and Topology's (the reviewer's ruling
// 11-06 09:41Z, part 3: UI-Notes' (a) of 11-05 19:55Z, plus its three points). His rule (10-24): never a face number.
//
// • From the part's OWN axes — up is against gravity, else +Z; front is the world's −Y laid flat (a CAD front view) — never
//   the camera, so a name doesn't change as the view turns.
// • A flat face by the way it faces: "Top face", "Underside", "Front face", "Back face", "Left side", "Right side", or, more
//   than 20° off both, "Sloped face, facing up" / "… down".
// • A cylinder: a hole (FaceTopology.isFastenerBore, the keep-clear rule's own; a hole STEP splits in two is one hole)
//   "Hole, ⌀ 8 mm"; a whole round outside "Round side, ⌀ 22 mm"; a partial one (a fillet, inside or out)
//   "Rounded edge, R 3 mm".
// • Anything else "Curved face". A mesh with no B-rep geometry (STL, a result) names its flat pieces the same way.
// • Two faces with one name are numbered in reading order — top to bottom, left to right, front to back: "Top face 2",
//   "Hole 2, ⌀ 8 mm". A hole's pieces share its name.
import Foundation
import simd
import TopOptKit

public enum FaceNames {

    /// The part's own axes.
    public struct Frame: Equatable, Sendable {
        public let up: SIMD3<Float>, front: SIMD3<Float>, right: SIMD3<Float>
        /// `gravity` as the project stores it (pointing down); nil ⇒ +Z up.
        public init(gravity: SIMD3<Float>?) {
            let g = gravity.flatMap { simd_length($0) > 1e-6 ? -simd_normalize($0) : nil } ?? SIMD3<Float>(0, 0, 1)
            var f = SIMD3<Float>(0, -1, 0)
            for c in [SIMD3<Float>(0, -1, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(-1, 0, 0)] {
                let flat = c - g * simd_dot(c, g)
                if simd_length(flat) > 0.5 { f = simd_normalize(flat); break }
            }
            up = g; front = f; right = simd_normalize(simd_cross(g, f))   // +Z up, −Y front ⇒ +X right
        }
    }

    /// What a face is, before numbering. Sizes are kept to 0.1 mm so two "Hole, ⌀ 8 mm" are one name.
    enum Kind: Hashable {
        case top, under, front, back, left, right, slopeUp, slopeDown, curved
        case hole(tenthsMM: Int), round(tenthsMM: Int), edge(tenthsMM: Int)

        func text(_ n: Int) -> String {
            let num = n > 1 ? " \(n)" : ""
            func mm(_ t: Int) -> String { SelectionsSummary.format(Double(t) / 10, decimals: 1) + " mm" }
            switch self {
            case .top: return "Top face" + num
            case .under: return "Underside" + num
            case .front: return "Front face" + num
            case .back: return "Back face" + num
            case .left: return "Left side" + num
            case .right: return "Right side" + num
            case .slopeUp: return "Sloped face" + num + ", facing up"
            case .slopeDown: return "Sloped face" + num + ", facing down"
            case .curved: return "Curved face" + num
            case let .hole(t): return "Hole" + num + ", \u{2300} " + mm(t)
            case let .round(t): return "Round side" + num + ", \u{2300} " + mm(t)
            case let .edge(t): return "Rounded edge" + num + ", R " + mm(t)
            }
        }
    }

    /// A flat face's kind from its outward normal.
    static func flatKind(_ n: SIMD3<Float>, _ frame: Frame) -> Kind {
        let up = simd_dot(n, frame.up)
        if up >= 0.94 { return .top }          // within 20° of up
        if up <= -0.94 { return .under }
        if abs(up) > 0.34 { return up > 0 ? .slopeUp : .slopeDown }   // more than 20° off the side
        let f = simd_dot(n, frame.front), r = simd_dot(n, frame.right)
        if abs(f) >= abs(r) { return f > 0 ? .front : .back }
        return r > 0 ? .right : .left
    }

    /// Every face's name on `mesh` under `frame`, by face id. Cached per mesh and frame.
    public static func names(in mesh: ViewerMesh, frame: Frame) -> [FaceID: String] {
        Cache.shared.names(mesh, frame) { compute(mesh, frame) }
    }

    /// One face's name (the whole mesh is named once, so the numbers agree everywhere).
    public static func name(_ face: FaceID, in mesh: ViewerMesh, frame: Frame) -> String? {
        names(in: mesh, frame: frame)[face]
    }

    static func compute(_ mesh: ViewerMesh, _ frame: Frame) -> [FaceID: String] {
        // one pass: each face's area-weighted normal and centroid
        var area: [FaceID: SIMD3<Float>] = [:], centre: [FaceID: (sum: SIMD3<Float>, n: Float)] = [:]
        let idx = mesh.indices, pos = mesh.positions
        func p(_ i: UInt32) -> SIMD3<Float> { let j = Int(i) * 3; return SIMD3(pos[j], pos[j + 1], pos[j + 2]) }
        for (t, f) in mesh.faceIDs.enumerated() {
            let i = t * 3
            guard i + 2 < idx.count else { break }
            let a = p(idx[i]), b = p(idx[i + 1]), c = p(idx[i + 2])
            area[f, default: .zero] += simd_cross(b - a, c - a)
            let s = centre[f] ?? (.zero, 0)
            centre[f] = (s.sum + a + b + c, s.n + 3)
        }
        let faces = area.keys.sorted()
        // a face with no CAD geometry (a painted piece) is curved when a triangle turns more than FaceTopology's 5° from the
        // face's own normal — one more pass, where isCurved's pairwise test would cost a big flat face its triangle count
        // squared on the main thread
        let turn = cos(FaceTopology.curveThresholdDeg * .pi / 180)
        var bent: Set<FaceID> = []
        for (t, f) in mesh.faceIDs.enumerated() where mesh.faceGeometry(f) == nil && !bent.contains(f) {
            let i = t * 3
            guard i + 2 < idx.count else { break }
            let a = p(idx[i]), b = p(idx[i + 1]), c = p(idx[i + 2])
            let n = simd_cross(b - a, c - a)
            guard simd_length(n) > 1e-12 else { continue }
            if simd_dot(simd_normalize(n), safeNormal(area[f])) < turn { bent.insert(f) }
        }
        // a hole's pieces are named once, by their first piece
        var holeOf: [FaceID: FaceID] = [:]
        var kinds: [FaceID: Kind] = [:]
        for f in faces {
            if let g = mesh.faceGeometry(f) {
                switch g.kind {
                case .plane:
                    let n = SIMD3<Float>(g.planeNormal)
                    kinds[f] = flatKind(simd_length(n) > 1e-6 ? simd_normalize(n) : safeNormal(area[f]), frame)
                case .cylinder where g.isCylinder:
                    kinds[f] = cylinderKind(f, g, mesh, &holeOf)
                default:
                    kinds[f] = .curved
                }
            } else {
                kinds[f] = bent.contains(f) ? .curved : flatKind(safeNormal(area[f]), frame)
            }
        }
        // number each name's faces in reading order (a hole's pieces count once), to the whole millimetre so the order is a
        // true order and a face a hair higher than its neighbour doesn't jump ahead of it
        func key(_ f: FaceID) -> [Int] {
            let s = centre[holeOf[f] ?? f] ?? (.zero, 1)
            let c = s.sum / max(s.n, 1)
            return [-simd_dot(c, frame.up), simd_dot(c, frame.right), -simd_dot(c, frame.front)].map { Int($0.rounded()) }
                + [Int(f)]
        }
        var out: [FaceID: String] = [:]
        for (kind, members) in Dictionary(grouping: faces, by: { kinds[$0]! }) {
            let leaders = Set(members.map { holeOf[$0] ?? $0 }).sorted { key($0).lexicographicallyPrecedes(key($1)) }
            let number = Dictionary(uniqueKeysWithValues: leaders.enumerated().map { ($1, $0 + 1) })
            for f in members { out[f] = kind.text(number[holeOf[f] ?? f] ?? 1) }
        }
        return out
    }

    private static func safeNormal(_ a: SIMD3<Float>?) -> SIMD3<Float> {
        guard let a, simd_length(a) > 1e-12 else { return SIMD3(0, 0, 1) }
        return simd_normalize(a)
    }

    /// A cylinder face: a hole (the keep-clear rule's own test, split holes included), a whole round outside, or a part of
    /// one — a rounded edge.
    private static func cylinderKind(_ f: FaceID, _ g: StepFaceGeometry, _ mesh: ViewerMesh,
                                     _ holeOf: inout [FaceID: FaceID]) -> Kind {
        let r = g.cylinderRadiusMM
        let tenths = Int((r * 20).rounded())   // the diameter, in 0.1 mm
        let axis = SIMD3<Float>(g.axisDir)
        guard simd_length(axis) > 1e-6 else { return .curved }
        let e = simd_normalize(axis), o = SIMD3<Float>(g.axisPoint)
        if FaceTopology.isFastenerBore(f, in: mesh) {
            holeOf[f] = FaceTopology.borePartners(f, in: mesh).min() ?? f
            return .hole(tenthsMM: tenths)
        }
        let m = FaceTopology.boreAxisMetrics(f, in: mesh, axisPoint: o, axisDir: e)
        if !m.concave {
            // a round outside STEP split in two: its convex pieces on the same axis wrap it together
            let parts = convexPartners(f, g, mesh)
            let wrap = parts.count > 1 ? FaceTopology.boreAxisMetrics(faces: parts, in: mesh, axisPoint: o, axisDir: e).wrapDeg
                                       : m.wrapDeg
            if wrap >= FaceTopology.fastenerWrapMinDeg {
                holeOf[f] = parts.min() ?? f
                return .round(tenthsMM: tenths)
            }
        }
        return .edge(tenthsMM: Int((r * 10).rounded()))
    }

    /// The convex cylinder faces on `f`'s axis with its radius and over the same stretch of it, `f` included
    /// (FaceTopology.borePartners' rule, outside: two bosses on one axis are two round sides).
    private static func convexPartners(_ f: FaceID, _ g: StepFaceGeometry, _ mesh: ViewerMesh) -> [FaceID] {
        let e = simd_normalize(g.axisDir)
        let mine = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(g.axisPoint), axisDir: SIMD3<Float>(e))
        return (0..<Int32(mesh.faceGeometry.count)).filter { o in
            if o == f { return true }
            guard let h = mesh.faceGeometry(o), h.isCylinder, abs(h.cylinderRadiusMM - g.cylinderRadiusMM) < 0.01,
                  simd_length(h.axisDir) > 1e-9, abs(simd_dot(simd_normalize(h.axisDir), e)) > 0.9999 else { return false }
            let d = h.axisPoint - g.axisPoint
            guard simd_length(d - e * simd_dot(d, e)) < 0.01 else { return false }
            guard let a = mine, let b = mesh.faceAxialSpan(o, axisPoint: SIMD3<Float>(g.axisPoint), axisDir: SIMD3<Float>(e))
            else { return false }
            guard min(a.hi, b.hi) - max(a.lo, b.lo) > 0.5 * min(a.hi - a.lo, b.hi - b.lo) else { return false }
            return !FaceTopology.boreAxisMetrics(o, in: mesh, axisPoint: SIMD3<Float>(g.axisPoint),
                                                 axisDir: SIMD3<Float>(e)).concave
        }
    }

    /// One mesh's names, kept until the mesh, its face ids or the frame change. The signature reads positions and indices
    /// only, so the face ids ride along: a paint stroke can relabel triangles without moving them. (Array == is O(1) on the
    /// same storage, so a row's lookup stays cheap.)
    final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var key: (ViewerMeshSignature, [Int32], Int, Frame)?
        private var map: [FaceID: String] = [:]
        func names(_ mesh: ViewerMesh, _ frame: Frame, compute: () -> [FaceID: String]) -> [FaceID: String] {
            lock.lock()
            if let k = key, k.0 == mesh.signature, k.2 == mesh.faceGeometry.count, k.3 == frame, k.1 == mesh.faceIDs {
                let m = map; lock.unlock(); return m
            }
            lock.unlock()
            let v = compute()
            lock.lock(); key = (mesh.signature, mesh.faceIDs, mesh.faceGeometry.count, frame); map = v; lock.unlock()
            return v
        }
    }
}
