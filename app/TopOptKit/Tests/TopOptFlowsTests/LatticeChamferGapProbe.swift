import XCTest
import simd
@testable import TopOptFlows

/// ★ HIS IMG 5 (2026-08-24 evening): "the lattice being just a little bit too thin
/// in depth in comparison to the chamfered edges." Hypothesis: the chamfer is its
/// own CAD face, so the declared face's outline — and therefore the prism — stops
/// where the chamfer begins; the lattice is inset by exactly the chamfer's width.
/// This measures how much part material sits just OUTSIDE each region's prism
/// in-plane (reachable by the Expand control), per expansion step.
final class LatticeChamferGapProbe: XCTestCase {
    func testHowMuchMaterialTheOutlineLeavesOut() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh) else { continue }
            var counts: [Double: Int] = [:]
            for expand in [0.0, 1.0, 2.0, 3.0, 5.0] {
                guard var spec = LatticeRegionEmission.spec(
                    for: r, role: .include, depthMM: depth, faceID: Int(face))
                else { continue }
                spec.inPlaneOffsetMM = expand
                let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                            regions: [spec], whenEmpty: .latticeNothing)
                counts[expand] = scene.occupancy.values.filter { $0 > 0.5 }.count
            }
            let base = counts[0.0] ?? 0
            print(String(format: "CHAMFER-GAP face %d: prism voxels at expand "
                + "0mm=%d  +1mm=%+d  +2mm=%+d  +3mm=%+d  +5mm=%+d",
                Int(face), base,
                (counts[1.0] ?? 0) - base, (counts[2.0] ?? 0) - base,
                (counts[3.0] ?? 0) - base, (counts[5.0] ?? 0) - base))
        }
    }
}
