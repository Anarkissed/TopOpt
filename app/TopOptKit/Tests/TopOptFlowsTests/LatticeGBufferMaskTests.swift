// LatticeGBufferMaskTests — ★ THE ARTIFACT, PINNED BY THE ONE THING IT CANNOT DO
// (maintainer, 2026-08-18: "I can see the lattices from behind the back wall shown
// as artifacts", and "this *CANNOT* go live with artifacts like this. Not ever.").
//
// ★★ WHAT THE DEFECT WAS. The shell's depth-prepass pipeline (`dpd`) declared only
// colour attachments 0 and 1, while the pass it runs in binds THREE — the third
// being the lattice albedo, whose alpha the deferred shade reads as "is this pixel a
// strut". `depth_fragment` does write `albedo = float4(0)`, but a pipeline only
// writes attachments it DECLARES, so that write was dropped and attachment 2 was
// left undefined over every shell pixel, then stored. Undefined alpha ≥ 128 reads as
// a strut, so the shade painted lattice colour across the shell — which is precisely
// "struts behind the wall", and why the pattern moved between frames.
//
// ★ WHY THE ASSERTIONS ARE THESE TWO. Determinism alone is not enough: a renderer
// can be stably wrong. The second assertion is the one with no escape — the shell can
// only ever OCCLUDE the march, so drawing it can never produce MORE strut pixels than
// leaving it out. That bound is physics, not taste, and it is what identified the
// counts as garbage rather than as a depth race:
//
//     shell drawn ....  [2111, 8816, 8853, 2251, 9008, 8423, …]   spread 6,897
//     shell absent ...  [6040 x10]                                spread     0
//
// Half those readings exceed the no-shell maximum, which is impossible. A test that
// only demanded determinism would have passed the day someone made the garbage
// repeatable.

import XCTest
import Metal
import simd
@testable import TopOptFlows

final class LatticeGBufferMaskTests: XCTestCase {

    /// Renders his own part with a face region declared, and reports the strut-mask
    /// pixel count for a given body alpha.
    @MainActor
    private func maskCounts(bodyAlpha: Float, renders: Int)
        throws -> (counts: [Int], disagreements: Int) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [LatticeRegionFidelityTests.hisSlab(mesh)],
                                    whenEmpty: .latticeNothing)
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("MeshRenderer init: \(MeshRenderer.lastInitError ?? "?")")
        }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild, "lattice MSL must compile")
        renderer.setMesh(mesh)
        renderer.camera.setOrientation(azimuth: 0.7, elevation: 0.4)
        renderer.setBodyAlpha(bodyAlpha)
        renderer.setLatticeScene(scene, token: 1)
        renderer.latticeParams = LatticePreviewConfettiTests.hisParams()

        var counts: [Int] = []
        var first: [Bool]? = nil
        var disagreements = 0
        for _ in 0..<renders {
            guard let d = renderer.latticeMaskDump(size: 384) else { continue }
            counts.append(d.covered)
            if let f = first {
                for i in 0..<Swift.min(f.count, d.mask.count) where f[i] != d.mask[i] {
                    disagreements += 1
                }
            } else { first = d.mask }
        }
        return (counts, disagreements)
    }

    /// ★ THE SHELL IS DRAWN — the configuration that produced the artifact. Before the
    /// fix this varied by 6,897 pixels between renders of an unchanged scene.
    @MainActor
    func testTheStrutMaskIsBitExactWhileTheShellIsDrawn() throws {
        let (counts, disagreements) = try maskCounts(bodyAlpha: 1, renders: 8)
        XCTAssertEqual(counts.count, 8, "every render must produce a dump")
        XCTAssertGreaterThan(counts.first ?? 0, 100, "there must be a lattice to compare")
        XCTAssertEqual(Set(counts).count, 1,
                       "★ with the shell drawn, the strut mask must be BIT-EXACT across "
                       + "repeated renders of one unchanged scene — got \(counts). A mask "
                       + "that moves when nothing moves is the artifact he photographed.")
        XCTAssertEqual(disagreements, 0,
                       "★ …and the SAME pixels, not merely the same count.")
    }

    /// ★★ THE BOUND WITH NO ESCAPE. Occlusion can only ever remove struts, so the
    /// shell-drawn count must not exceed the shell-absent count. This is the assertion
    /// that caught undefined memory masquerading as geometry.
    @MainActor
    func testDrawingTheShellCanOnlyEverRemoveStrutPixels() throws {
        let withShell = try maskCounts(bodyAlpha: 1, renders: 3).counts
        let without = try maskCounts(bodyAlpha: 0, renders: 3).counts
        guard let ceiling = without.max(), let worst = withShell.max() else {
            throw XCTSkip("no dumps")
        }
        XCTAssertGreaterThan(ceiling, 100,
                             "positive control: the march must draw something with no shell")
        XCTAssertGreaterThan(withShell.min() ?? 0, 0,
                             "positive control: some lattice must survive the shell")
        XCTAssertLessThanOrEqual(worst, ceiling,
                                 "★ the shell can only OCCLUDE the march, so drawing it "
                                 + "cannot produce MORE strut pixels than omitting it. "
                                 + "with shell \(withShell) vs without \(without) — a count "
                                 + "above the unoccluded ceiling is undefined memory being "
                                 + "read as a strut mask, not geometry.")
    }
}
