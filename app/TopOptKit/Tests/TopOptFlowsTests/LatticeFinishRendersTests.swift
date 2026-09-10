// LatticeFinishRendersTests — ★ D1: THE FINISH ACTUALLY CHANGES THE PICTURE.
//
// This is the assertion that was missing when Finish was reported broken twice
// ("I have done 3 separate finish settings in these screenshots. Can you tell
// which is which? I don't think it's working"). Every earlier check confirmed the
// SETTING travelled; none confirmed the PIXELS moved. These do.

import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows
@testable import TopOptDesign

final class LatticeFinishRendersTests: XCTestCase {

    @MainActor
    private func covered(_ dressing: Float, device: MTLDevice) throws -> Int {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        // ★★ 20 mm, NOT 11 (task 2026-08-21). See the params note below: at 11 mm this
        // region's widest member is 10.39 mm, which caps the cell at 2.08 mm — and at
        // that cell the struts are thin enough that the RIM adds a single pixel
        // (7,520 -> 7,521), a margin indistinguishable from noise. Declaring 20 mm
        // reaches 20.78 mm of material, allows a 4.16 mm cell, and the same three
        // finishes separate by 17 and 32 pixels. Deeper region, coarser strut, legible
        // difference — the CLAIM is untouched.
        guard let r15 = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              let spec = LatticeRegionEmission.spec(for: r15, role: .include,
                                                    depthMM: 20.0, faceID: 15)
        else { throw XCTSkip("no region") }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [spec], whenEmpty: .latticeNothing)
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild, "lattice MSL must compile")
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
        renderer.setBodyAlpha(0)                 // the march alone — deterministic
        renderer.setLatticeScene(scene, token: 1)
        // ★★ A CELL HIS PART CAN HOLD (task 2026-08-21). This read `hisParams()`, whose
        // cell is the shipped 8.00 mm DEFAULT — and at 8 mm core latticeS NOTHING under
        // this region: N* = 5 wants a 40 mm member and the widest material here measures
        // 10.39 mm. So this test was asking which of three finishes dressed a lattice
        // that the run never builds, and once the cells-per-member floor started asking
        // every voxel under the cell, all three arms correctly returned 0 and the
        // positive control ("there must be a lattice to dress") failed.
        //
        // The finish claim is unchanged and is still made at full strength; it is simply
        // made on a lattice that exists. See `LatticePreviewFloorVsCoreTests` for the
        // measurement, which asks core's own two laws rather than assuming either.
        //
        // 4.00 mm is core's ceiling for the region THIS test declares, not a tuned
        // constant: W / N* = 20.78 / 5 = 4.16 mm at the 20 mm depth above.
        renderer.latticeParams =
            LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: 4.0)
        renderer.latticeDressingLevel = dressing
        let d = try XCTUnwrap(renderer.latticeMaskDump(size: 384),
                              "the lattice must reach the G-buffer")
        return d.covered
    }

    /// ★ RIM AND DIAGRID MUST BOTH ADD MATERIAL, AND THE DIAGRID MUST ADD MORE —
    /// it dresses the whole boundary where the rim dresses only its edges.
    @MainActor
    func testEachFinishRendersDifferently() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let none = try covered(0, device: device)
        let rim = try covered(1, device: device)
        let skin = try covered(2, device: device)

        print("""

        ================================================================================
        WHAT EACH FINISH DRAWS — lattice pixels, his face 15, shell out
          None ....... \(none)
          Rim ........ \(rim)
          Skin ....... \(skin)
        ================================================================================
        """)

        XCTAssertGreaterThan(none, 100, "there must be a lattice to dress")
        XCTAssertGreaterThan(rim, none,
                             "★ a rim must ADD material at the region's edges — if this "
                             + "is equal, Finish is once again a setting that travels "
                             + "and does nothing")
        XCTAssertGreaterThan(skin, rim,
                             "★ and the diagrid dresses the whole boundary, so it must "
                             + "add more than the rim, which dresses only its edges")
    }

    /// ★ AND THE MAP FROM THE SETTING IS THE ONE THE RENDERER READS.
    func testTheTreatmentNamesItsOwnDressing() {
        XCTAssertEqual(LatticeBoundaryTreatment.none.previewDressingLevel, 0)
        XCTAssertEqual(LatticeBoundaryTreatment.rim.previewDressingLevel, 1)
        XCTAssertEqual(LatticeBoundaryTreatment.fullSkin.previewDressingLevel, 2)
        // ★ A cover is NOT a dressing — it is a solid wall, drawn by the skin
        // field. Dressing it as well would thicken struts under an opaque wall.
        XCTAssertEqual(LatticeBoundaryTreatment.covered.previewDressingLevel, 0)
    }
}
