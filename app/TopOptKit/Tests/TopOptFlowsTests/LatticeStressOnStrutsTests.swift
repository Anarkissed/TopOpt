// LatticeStressOnStrutsTests — ★ THE OVERLAY MUST REACH THE STRUTS
// (maintainer, 2026-08-19: "The stress map is still not on the actual lattice").
//
// ★★ THIS IS THE TEST THAT EXONERATED THE RENDERER. Flipping `latticeStressOverlay`
// repaints EVERY shared strut pixel (4,863 of 4,863 when this was written), so the
// shader, the uniform flag and the texture bind were all correct — which is what
// pointed the search at the missing rebake instead: a scene baked before the FEA
// landed has `demand == nil`, so `stressRGB` is never built, so `stressTex` is nil,
// so `stressOverlay && stressTex != nil` is false however loudly the toggle is set.
// See `LatticeProbeSamplingTests` for the other half of that chain.
//
// ★ IT ASSERTS THE PIXELS MOVE, not that a flag is set — a flag that travels the
// whole way and paints nothing is exactly the defect this branch has hit repeatedly.

import XCTest
import Metal
import simd
@testable import TopOptFlows

final class LatticeStressOnStrutsTests: XCTestCase {
    private func gradedField(_ b: MeshBounds) -> StressField {
        let ext = b.max - b.min
        let n = 48
        let sp = Swift.max(ext.x, Swift.max(ext.y, ext.z)) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            vals[(k * n + j) * n + i] = Float(i) / Float(n - 1)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: vals)
    }

    @MainActor
    func testStressOverlayChangesTheStrutPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        let scene = LatticeSDFScene(mesh: mesh, field: gradedField(mesh.bounds),
                                    latticeID: "octet", regions: [region],
                                    rhoMin: 0.05, rhoMax: 0.9, gamma: 1,
                                    whenEmpty: .latticeNothing)
        XCTAssertNotNil(scene.stressRGB, "the scene must bake the stress colours at all")

        guard let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("init") }
        try XCTSkipUnless(r.latticePipelinesDidBuild, "MSL")
        r.setMesh(mesh); r.setBodyAlpha(1)
        r.setLatticeScene(scene, token: 1)
        // ★★ A CELL HIS PART CAN HOLD (task 2026-08-21). This read `hisParams()`, whose
        // cell is the shipped 8.00 mm default — at which core leaves this material SOLID
        // (N* = 5 wants 40 mm of member; the widest here measures 10.39 mm). That cost
        // nothing while the shell was cut to the declared REGION, because the hole was
        // there whether or not a strut filled it. Now that the shell stands down only
        // where a cell is actually LATTICED, the opaque shell correctly covers material
        // the run builds solid — and this fixture's own positive control ("struts must
        // be on screen") fell to 48. That is the fix working, not a regression.
        //
        // The overlay claim is unchanged; it is asked of a lattice that exists.
        r.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold()
        r.camera.setOrientation(azimuth: 0.7, elevation: 0.4)

        r.latticeStressOverlay = false
        guard let off = r.latticeMaskDump(size: 384) else { throw XCTSkip("no dump") }
        r.latticeStressOverlay = true
        guard let on = r.latticeMaskDump(size: 384) else { throw XCTSkip("no dump") }

        var diff = 0, both = 0
        for i in 0..<Swift.min(off.mask.count, on.mask.count) where off.mask[i] && on.mask[i] {
            both += 1
            if off.rgb[i*3] != on.rgb[i*3] || off.rgb[i*3+1] != on.rgb[i*3+1]
                || off.rgb[i*3+2] != on.rgb[i*3+2] { diff += 1 }
        }
        XCTAssertGreaterThan(both, 100, "positive control: struts must be on screen")
        XCTAssertGreaterThan(diff, both / 2,
                             "★ turning the stress overlay on must REPAINT the struts")
    }
}
