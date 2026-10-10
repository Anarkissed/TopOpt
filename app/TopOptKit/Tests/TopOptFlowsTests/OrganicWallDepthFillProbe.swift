import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

/// PROBE (his 2026-09-18 night): the front wall's organic struts fill only HALF its depth
/// while the back wall fills all of it. On his device the front wall is 72 % synthetic
/// stress (dead FEA), the back wall 5 %. Reproduce with a DEAD tensor and the synthetic
/// plan, and bin the emitted spans by depth fraction within each wall.
final class OrganicWallDepthFillProbe: XCTestCase {
    func testSpanDepthHistogramPerWallUnderSyntheticStress() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 11.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        try XCTSkipIf(regs.isEmpty)
        let n = 64
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        let origin = SIMD3<Double>(mesh.bounds.min)
        let tensor = [Double](repeating: 0, count: 6 * n * n * n)          // DEAD everywhere
        let plan = OrganicSyntheticStress.plan(regions: regs, dims: (n, n, n), originMM: origin, spacingMM: sp,
                                               defaultFoci: 2, statedFoci: [:])
        for (label, synthetic) in [("synthetic", true), ("uniform-real", false)] {
            var input = LatticeOrganicInput(tensor: synthetic ? tensor : tensor.enumerated().map { i, _ in [10.0, 3.0, 1.0, 0, 0, 0][i % 6] },
                                            dims: (n, n, n), originMM: origin, spacingMM: sp,
                                            minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                            separationMinMM: 3.47, separationMaxMM: 5.2, rhoMin: 0.073, rhoMax: 0.9)
            input.regionIDs = plan.regionIDs
            if synthetic { input.syntheticRegions = plan.regions }
            input.solidRimMM = 1.71
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                        algorithm: "organic", organic: input, maxDim: 64, regions: regs, whenEmpty: .latticeNothing)
            print("DEPTH \(label): \(scene.organicSummary.prefix(260))")
            for (ri, r) in regs.enumerated() {
                let nrm = LatticeRegionMask.unit(r.normal)
                var bins = [Int](repeating: 0, count: 4)
                var total = 0
                for c in scene.organicCapsules {
                    let mid = (SIMD3<Double>(c.a) + SIMD3<Double>(c.b)) * 0.5
                    let depth = simd_dot(mid - r.origin, nrm)
                    guard depth >= -0.5, depth <= r.depthMM + 0.5 else { continue }
                    guard LatticeRegionMask.contains(mid, region: r) else { continue }
                    let f = Swift.min(Swift.max(depth / r.depthMM, 0), 0.999)
                    bins[Int(f * 4)] += 1; total += 1
                }
                print(String(format: "DEPTH %@ region %d (face %d, depth %.0f): spans %d · quarters from the face %@",
                             label, ri, r.faceID ?? -1, r.depthMM, total,
                             bins.map { total > 0 ? String(format: "%.0f%%", 100 * Double($0) / Double(total)) : "-" }.joined(separator: " / ")))
            }
        }
    }
}
