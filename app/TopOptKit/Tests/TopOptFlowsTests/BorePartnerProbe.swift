import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// Opt-in diagnosis (BORE_PROBE_STEP=<a STEP path outside the repo>): which fastener bores are "partners" of a bore whose
/// axial span does NOT overlap theirs (lined-up holes in two plates), and which bores lose their representative in a group
/// holding every face.
final class BorePartnerProbe: XCTestCase {
    @MainActor
    func testListLinedUpHoles() throws {
        guard let path = ProcessInfo.processInfo.environment["BORE_PROBE_STEP"] else { throw XCTSkip("BORE_PROBE_STEP not set") }
        let p = try FlexiblePressFixtures.project(path: path, name: "probe")
        let mesh = try XCTUnwrap(p.viewerMesh)
        let all = FaceTopology.faceIDs(in: mesh)
        var bores = 0, dropped: [FaceID] = [], apart = 0
        for f in all where FaceTopology.isFastenerBore(f, in: mesh) {
            bores += 1
            if !FaceTopology.isBoreRepresentative(f, among: all, in: mesh) { dropped.append(f) }
            let g = mesh.faceGeometry(f)!, e = simd_normalize(SIMD3<Float>(g.axisDir))
            let s = mesh.faceAxialSpan(f, axisPoint: SIMD3<Float>(g.axisPoint), axisDir: e)!
            for o in FaceTopology.borePartners(f, in: mesh) where o != f {
                let t = mesh.faceAxialSpan(o, axisPoint: SIMD3<Float>(g.axisPoint), axisDir: e)!
                if min(s.hi, t.hi) - max(s.lo, t.lo) < 0.01 { apart += 1 }
            }
        }
        print("BORE-PROBE bores \(bores) · dropped as 'same hole' \(dropped.count) \(dropped) · partner pairs NOT overlapping axially \(apart)")
    }
}
