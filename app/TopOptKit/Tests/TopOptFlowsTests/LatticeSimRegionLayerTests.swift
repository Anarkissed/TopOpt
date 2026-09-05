import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE STAGE'S SOLVE CARRIES THE REGION LAYER (2026-09-05). Measured on the M2 stand:
/// the load was Group B, four painted regions and no native face; the run request sent
/// the regions and the sim context did not, so core threw "every declared load group
/// contributed nothing", the sim failed in silence, and the organic preview never got a
/// tensor. The context now carries them and a region edit re-fingerprints the solve.
final class LatticeSimRegionLayerTests: XCTestCase {
    func testAContextCarriesRegionsAndARegionEditReSolves() {
        let load = TopOptKit.LoadGroupSpec(faceIDs: [], force: SIMD3(0, 0, -44.5), regionIDs: [7])
        let region = TopOptKit.FaceRegionSpec(id: 7, parentID: 3)
        let a = LatticeSimModel.Context(modelPath: "m.step", material: "ABS", materialsPath: "", rulesPath: "",
                                        resolution: 64, anchorFaceIDs: [18], loadGroups: [load],
                                        faceRegions: [region], anchorRegionIDs: [])
        XCTAssertEqual(a.faceRegions.count, 1)
        XCTAssertEqual(a.loadGroups[0].regionIDs, [7], "a region-defined load keeps its region ids")
        let b = LatticeSimModel.Context(modelPath: "m.step", material: "ABS", materialsPath: "", rulesPath: "",
                                        resolution: 64, anchorFaceIDs: [18], loadGroups: [load],
                                        faceRegions: [], anchorRegionIDs: [])
        XCTAssertNotEqual(a.fingerprint, b.fingerprint, "★ dropping the region geometry must re-solve")
        let c = LatticeSimModel.Context(modelPath: "m.step", material: "ABS", materialsPath: "", rulesPath: "",
                                        resolution: 64, anchorFaceIDs: [18], loadGroups: [load],
                                        faceRegions: [region], anchorRegionIDs: [7])
        XCTAssertNotEqual(a.fingerprint, c.fingerprint, "anchoring a region changes the solve")
        // the legacy fingerprint shape is unchanged for a face-only case
        let legacy = LatticeSimFingerprint(modelPath: "m.step", material: "ABS", resolution: 64, anchorFaceIDs: [18], loadGroups: [load])
        XCTAssertEqual(legacy.anchorRegionIDs, []); XCTAssertEqual(legacy.regionSignature, "")
    }
}
