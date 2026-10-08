import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (2026-09-26): which CAD face is which on the stand — area, mean outward normal
/// and extent of every face, so a report about "the floor" or "the wall between face 23 and
/// face 2" can be mapped to face ids before anything is measured.
final class LatticeStandFaceMapProbe: XCTestCase {
    func testTheFaceMap() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        struct Acc { var area = 0.0; var n = SIMD3<Double>(0, 0, 0); var lo = SIMD3<Double>(repeating: 1e9); var hi = SIMD3<Double>(repeating: -1e9) }
        var faces: [Int: Acc] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let id = tri < mesh.faceIDs.count ? Int(mesh.faceIDs[tri]) : -1
            func P(_ k: Int) -> SIMD3<Double> { let b = Int(mesh.indices[t + k]) * 3; return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2])) }
            let p0 = P(0), p1 = P(1), p2 = P(2)
            t += 3
            let cr = simd_cross(p1 - p0, p2 - p0)
            var a = faces[id] ?? Acc()
            a.area += 0.5 * simd_length(cr); a.n += 0.5 * cr
            for p in [p0, p1, p2] { a.lo = simd_min(a.lo, p); a.hi = simd_max(a.hi, p) }
            faces[id] = a
        }
        print(String(format: "FACEMAP bounds (%.1f,%.1f,%.1f)–(%.1f,%.1f,%.1f)", mesh.bounds.min.x, mesh.bounds.min.y, mesh.bounds.min.z, mesh.bounds.max.x, mesh.bounds.max.y, mesh.bounds.max.z))
        for id in faces.keys.sorted() {
            let a = faces[id]!
            let flat = simd_length(a.n) / max(a.area, 1e-9)
            let n = simd_length(a.n) > 1e-9 ? simd_normalize(a.n) : .zero
            print(String(format: "FACEMAP f%d area %8.1f flat %.2f n (%+.2f,%+.2f,%+.2f) x[%6.1f,%6.1f] y[%6.1f,%6.1f] z[%6.1f,%6.1f]",
                         id, a.area, flat, n.x, n.y, n.z, a.lo.x, a.hi.x, a.lo.y, a.hi.y, a.lo.z, a.hi.z))
        }
    }
}

extension LatticeStandFaceMapProbe {
    /// Is the mesh edge-matched ACROSS faces (by position)? Counts edges seen once / twice / more.
    func testEdgeSharing() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        func key(_ i: UInt32) -> SIMD3<Int> {
            let b = Int(i) * 3
            return SIMD3(Int((mesh.positions[b] * 1000).rounded()), Int((mesh.positions[b + 1] * 1000).rounded()), Int((mesh.positions[b + 2] * 1000).rounded()))
        }
        struct E: Hashable { let a: SIMD3<Int>; let b: SIMD3<Int> }
        var count: [E: Int] = [:]
        var crossFace: [E: Set<Int>] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let fid = Int(mesh.faceIDs[t / 3])
            for k in 0..<3 {
                let a = key(mesh.indices[t + k]), b = key(mesh.indices[t + (k + 1) % 3])
                let e = (a.x, a.y, a.z) < (b.x, b.y, b.z) ? E(a: a, b: b) : E(a: b, b: a)
                count[e, default: 0] += 1
                crossFace[e, default: []].insert(fid)
            }
            t += 3
        }
        var hist: [Int: Int] = [:]
        for (_, c) in count { hist[c, default: 0] += 1 }
        let between = crossFace.values.filter { $0.count > 1 }.count
        print("EDGES seen-count histogram: \(hist.keys.sorted().map { "\($0)×:\(hist[$0]!)" }.joined(separator: " ")) · edges shared by two FACES \(between)")
        // the floor f20's edges: which faces are across each
        var across: [Int: Int] = [:]
        for (e, fs) in crossFace where fs.contains(20) { for f in fs where f != 20 { across[f, default: 0] += 1 }; if fs.count == 1 && count[e] == 1 { across[-1, default: 0] += 1 } }
        print("EDGES of f20 across faces: \(across)")
    }
}
