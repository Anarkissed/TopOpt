import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ HIS 2026-08-25 REPORT, MEASURED: "I bumped density to 20% (and 43%) and it
/// didn't change anything." The mass readout moves, the picture does not. This walks
/// the stated-density delivery chain on his real face 15 and prints where the number
/// survives and where it dies:
///
///   store → region spec (relativeDensity) → densityDemand (region containment on
///   the occupancy grid) → scene.demand → steppedCellField activation
final class LatticeStatedDensityDeliveryProbe: XCTestCase {

    func testStatedDensityReachesTheSteppedActivation() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        guard let plane = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              var spec = LatticeRegionEmission.spec(for: plane, role: .include,
                                                   depthMM: 12.0, faceID: 15)
        else { throw XCTSkip("face 15 has no planar geometry") }
        spec.relativeDensity = 0.385   // his 43% relative, roughly, in absolute rho
        let regions = [spec]
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: regions, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let candCount = occ.values.filter { $0 > 0.5 }.count

        print("=== STATED DENSITY DELIVERY face 15 ===")
        print("region outlineLoops=\(spec.outlineLoops.count) inPlaneOffset=\(spec.inPlaneOffsetMM)")
        print("occupancy candidates: \(candCount)")

        // Stage 1 — densityDemand alone, exactly as the scene builds it.
        let span = (lo: 0.0505, hi: 0.8999)   // LatticeBounds on his settings (probe4)
        let demand = LatticeRegionMask.densityDemand(
            like: occ, regions: regions, rhoMin: span.lo, rhoMax: span.hi, gamma: 1)
        if let d = demand {
            let painted = d.values.filter { $0 > 0 }.count
            let maxV = d.values.max() ?? 0
            print(String(format: "densityDemand: painted=%d of %d  max=%.3f (expect (0.385-lo)/(hi-lo)=%.3f)",
                         painted, candCount, maxV,
                         (0.385 - span.lo) / (span.hi - span.lo)))
            XCTAssertGreaterThan(painted, candCount / 4,
                                 "densityDemand painted almost nothing — the region "
                                 + "containment is dropping his dialled density")
        } else {
            XCTFail("densityDemand returned nil for a stated density")
        }

        // Stage 2 — what the SCENE holds (its own statedDemand path ran in init).
        if let sd = scene.demand {
            let painted = sd.values.filter { $0 > 0 }.count
            print("scene.demand: painted=\(painted) max=\(sd.values.max() ?? 0)")
        } else {
            print("scene.demand: NIL — the scene init did not build a stated demand")
        }

        // Stage 3 — the stepped activation the shader actually reads.
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: regions,
            cellMM: [10.31], baseCellMM: 10.31) else {
            return XCTFail("stepped bake produced nothing")
        }
        let acts = baked.field.values.enumerated()
            .filter { baked.steppedCellMM[$0.offset] > 0 }
            .map { $0.element }
        let nonZero = acts.filter { $0 > 0.01 }.count
        print(String(format: "stepped activation: cells=%d  nonzero=%d  max=%.3f",
                     acts.count, nonZero, acts.max() ?? -1))
    }
}
