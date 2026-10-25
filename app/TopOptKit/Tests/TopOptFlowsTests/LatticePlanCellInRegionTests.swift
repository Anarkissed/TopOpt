import XCTest
import simd
@testable import TopOptFlows

/// ★ EVERY PLAN CELL INTERSECTS ITS OWN REGION'S POLYGON (the one outline, P1/P6). A cell the preview cannot
/// draw must never be on the wire: the plan is withheld by name, never trimmed.
final class LatticePlanCellInRegionTests: XCTestCase {

    /// A 40 × 40 mm face at z = 0 looking into +z, 14 mm deep, outlined (an L: the square minus its +u+w quarter).
    private func face() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = 14; r.halfUMM = 20; r.halfWMM = 20; r.faceID = 3
        r.outlineLoops = [[SIMD2(-20, -20), SIMD2(20, -20), SIMD2(20, 0), SIMD2(0, 0), SIMD2(0, 20), SIMD2(-20, 20)]]
        return r
    }
    private func cell(_ u: Double, _ w: Double, _ s: Double = 7) -> LatticeSteppedCellWire {
        let (bu, bv) = LatticeRegionMask.basisForTests(SIMD3(0, 0, 1))
        let p = bu * u + bv * w
        return LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(p.x, p.y, 0), sizeMM: s, planBaseCellMM: 14)
    }

    func testACellWhollyOutsideItsRegionsPolygonWithholdsThePlanByName() {
        let r = face()
        // inside: a cell at the L's −u−w corner; outside: a cell in the cut-away +u+w quarter, and one far off
        let inside = cell(-15, -15)
        let (bu, bv) = LatticeRegionMask.basisForTests(SIMD3(0, 0, 1))
        // a 7 mm world box whose every point projects into the removed quarter (u, w in 3…17)
        let qc = bu * 10 + bv * 10
        let outside = LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(qc.x - 3.5, qc.y - 3.5, 0), sizeMM: 7, planBaseCellMM: 14)
        XCTAssertGreaterThan(-r.inPlaneDistance(SIMD2(10, 10)), 0, "positive control: the quarter is outside the polygon")
        let result = LatticeSteppedCellWire.plannedRegions([inside, outside], regions: [r],
                                                           slotOriginWired: true, slotOriginIsPhase: true, baseWired: true)
        guard case .failure(let why) = result else { return XCTFail("★ a cell outside its region is withheld, never sent") }
        XCTAssertEqual(why, .cellOutsideRegion(regionID: 1, count: 1))
        XCTAssertTrue(why.reason.contains("outside") && why.reason.contains("region 1"), why.reason)
        // ★ the control: every cell intersects (one straddles the L's inner corner) ⇒ sent
        let straddle = cell(-3, -3)     // near the L's inner corner
        guard case .success = LatticeSteppedCellWire.plannedRegions([inside, straddle], regions: [r],
                                                                     slotOriginWired: true, slotOriginIsPhase: true,
                                                                     baseWired: true) else {
            return XCTFail("control: cells that intersect the polygon go")
        }
    }
}
