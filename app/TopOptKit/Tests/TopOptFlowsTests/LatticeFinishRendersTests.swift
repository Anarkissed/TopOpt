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
        guard let r15 = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              let spec = LatticeRegionEmission.spec(for: r15, role: .include,
                                                    depthMM: 11.0, faceID: 15)
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
        renderer.latticeParams = LatticePreviewConfettiTests.hisParams()
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
