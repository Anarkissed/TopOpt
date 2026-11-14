import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// Opt-in diagnosis (HOLE_PROBE_STEP=<a STEP path outside the repo>): every concave cylinder face on HIS part — is it a
/// fastener bore, its radius, wrap, partners, and (with every face in one anchor group) does it get a keep-clear?
final class HoleKeepClearProbe: XCTestCase {
    @MainActor
    func testEveryHoleOnHisPart() throws {
        guard let path = ProcessInfo.processInfo.environment["HOLE_PROBE_STEP"] else { throw XCTSkip("HOLE_PROBE_STEP not set") }
        let p = try FlexiblePressFixtures.project(path: path, name: "probe")
        let mesh = try XCTUnwrap(p.viewerMesh)
        let all = FaceTopology.faceIDs(in: mesh)
        var kinds: [String: Int] = [:]
        for f in all { if let g = mesh.faceGeometry(f) { kinds["\(g.kind)", default: 0] += 1 } else { kinds["none", default: 0] += 1 } }
        print("HOLE-PROBE faces \(all.count) kinds \(kinds)")
        var sel = SelectionModel(); sel.addGroup(); sel.pickFaces(all)
        p.selection = sel
        let g = sel.groups[0]
        p.force.makeAnchor(g.id)
        let specFaces = Set(p.clearanceSpecs().map(\.faceID))
        for f in all {
            guard let geo = mesh.faceGeometry(f), geo.isCylinder, simd_length(geo.axisDir) > 1e-6 else { continue }
            let e = simd_normalize(SIMD3<Float>(geo.axisDir))
            let m = FaceTopology.boreAxisMetrics(f, in: mesh, axisPoint: SIMD3<Float>(geo.axisPoint), axisDir: e)
            let parts = FaceTopology.borePartners(f, in: mesh)
            let bore = FaceTopology.isFastenerBore(f, in: mesh)
            let rep = bore ? FaceTopology.isBoreRepresentative(f, among: all, in: mesh) : false
            let span = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(geo.axisPoint), axisDir: e)
            let c = mesh.faceCentroid(f) ?? .zero
            print(String(format: "HOLE-PROBE f%4d r=%6.3f wrap=%5.1f concave=%d parts=%@ bore=%d rep=%d spec=%d span=%.2f..%.2f at (%.1f,%.1f,%.1f) axis(%.2f,%.2f,%.2f)",
                         Int(f), geo.cylinderRadiusMM, m.wrapDeg, m.concave ? 1 : 0, "\(parts)", bore ? 1 : 0, rep ? 1 : 0,
                         specFaces.contains(Int(f)) ? 1 : 0, span?.lo ?? 0, span?.hi ?? 0, c.x, c.y, c.z, e.x, e.y, e.z))
        }
    }
}
