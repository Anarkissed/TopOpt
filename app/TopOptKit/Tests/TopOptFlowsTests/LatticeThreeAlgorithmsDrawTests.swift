// LatticeThreeAlgorithmsDrawTests — ★★★ ALL THREE ARE ON SCREEN, AND EACH IS ITSELF.
//
// (maintainer, 2026-08-22: "make sure that it and stepped both get drawn. do not stop
// until they are both visible".)
//
// ★ THE STANDING NO-GO SAID TWO OF THE THREE COULD NOT BE. Its reasoning: the cell
// texture carries a base cell plus an integer DYADIC LEVEL, which is what DOUBLED means;
// STEPPED's cells are arbitrary reals no (base, level) pair expresses, and ORGANIC "has
// no cells at all, only traced curves". Both halves were about the ENCODING, not about
// the algorithms:
//
//   STEPPED — the texture carries a real cell SIZE per base cell, and the frame is built
//             with the power-of-two assumption removed. Same renderer.
//   ORGANIC — its curves are baked to a DISTANCE FIELD, which is the one thing this
//             renderer was already sphere-tracing (`partSDF`, the region). One more
//             `max()` term, not a second renderer.
//
// These bars render real frames and count pixels. A test that only reads the source
// would pass on a shader that never compiled.

import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeThreeAlgorithmsDrawTests: XCTestCase {

    /// Lit pixels — the same discriminator `UnifiedShadingTests` uses.
    private func lit(_ bgra: [UInt8], _ size: Int) -> Int {
        var n = 0
        for i in stride(from: 0, to: size * size * 4, by: 4)
        where Int(bgra[i]) + Int(bgra[i + 1]) + Int(bgra[i + 2]) > 24 { n += 1 }
        return n
    }

    /// A block under UNIAXIAL tension, its own tensor, and a declared slab over one
    /// face. Uniaxial so the principal frame is determined — on a degenerate field the
    /// eigenvector order swaps between neighbours and core counts that separately.
    private func blockScene(algorithm: String, organic: Bool) throws
        -> (LatticeSDFScene, ViewerMesh) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = [(FaceID(15), 11.0), (FaceID(2), 13.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: f, in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d,
                                           faceID: Int(f))
            }
        }
        try XCTSkipIf(regions.isEmpty, "his faces did not resolve")

        var input: LatticeOrganicInput?
        if organic {
            // ★ THE TENSOR GRID'S VOXEL IS A FLOOR ON THE SEPARATION — core cannot
            // place curves closer than the grid can resolve the field they follow
            // (`resolution_floor_voxels`). At 20³ that floor is ~11 mm and it BINDS,
            // swamping the 4-8 mm window; the run solves far finer, so a coarse fixture
            // would be measuring the fixture.
            let n = 56
            let e = mesh.bounds.max - mesh.bounds.min
            let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
            var tensor = [Double](repeating: 0, count: 6 * n * n * n)
            for i in 0..<(n * n * n) {
                tensor[6 * i] = 10.0; tensor[6 * i + 1] = 3.0; tensor[6 * i + 2] = 1.0
            }
            input = LatticeOrganicInput(
                tensor: tensor, dims: (n, n, n),
                originMM: SIMD3<Double>(mesh.bounds.min), spacingMM: sp,
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                separationMinMM: 4, separationMaxMM: 8, rhoMin: 0.05, rhoMax: 0.9)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stageMode: .aesthetic, algorithm: algorithm,
                                    boundaryFinishWritten: true, organic: input,
                                    maxDim: 64, regions: regions,
                                    whenEmpty: .latticeNothing)
        return (scene, mesh)
    }

    private func render(_ scene: LatticeSDFScene, mesh: ViewerMesh,
                        stepped: [Double]) throws -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        guard let r = MeshRenderer(device: device, sampleCount: 4) else {
            throw XCTSkip("MeshRenderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        r.setMesh(mesh)
        r.camera.setOrientation(azimuth: 0.7, elevation: 0.5)
        r.setLatticeScene(scene, token: 1)
        r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 5.5,
                                             minRelativeDensity: 0.10,
                                             maxRelativeDensity: 0.55)
        r.latticeSteppedCellMM = stepped
        r.setBodyAlpha(0)          // the lattice stage: the struts ARE the picture
        try XCTSkipUnless(r.latticePipelinesDidBuild,
                          "lattice pipelines: \(MeshRenderer.lastInitError ?? "?")")
        let size = 320
        let px = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
        return lit(px, size)
    }

    /// ★★★ DOUBLED, STEPPED AND ORGANIC ALL PUT GEOMETRY ON SCREEN.
    func testAllThreeAlgorithmsDraw() throws {
        let (doubled, mesh) = try blockScene(algorithm: "doubled", organic: false)
        let dPix = try render(doubled, mesh: mesh, stepped: [])

        let (steppedScene, m2) = try blockScene(algorithm: "stepped", organic: false)
        // Two regions, two VERBATIM cells, neither a dyadic multiple of the other —
        // the exact case the old encoding could not express.
        let sPix = try render(steppedScene, mesh: m2, stepped: [5.3125, 6.875])

        let (organicScene, m3) = try blockScene(algorithm: "organic", organic: true)
        let oField = organicScene.organicField
        let oPix = try render(organicScene, mesh: m3, stepped: [])

        print("""

        ── lit pixels, 320² ────────────────────────────────────────────
        doubled ....... \(dPix)
        stepped ....... \(sPix)
        organic ....... \(oPix)   field \(oField?.values.count ?? 0) cells
        organic trace . \(organicScene.organicSummary)

        """)

        XCTAssertGreaterThan(dPix, 500, "★ doubled draws nothing — the baseline is broken")
        XCTAssertGreaterThan(sPix, 500, "★ STEPPED draws nothing")
        XCTAssertNotNil(oField, "★ the organic field was never baked — the tracer or the "
                              + "tensor did not reach the scene")
        XCTAssertGreaterThan(oPix, 500, "★ ORGANIC draws nothing")
        XCTAssertFalse(organicScene.organicSummary.isEmpty,
                       "★ the trace reported nothing about itself")
    }

    /// ★★★ STEPPED AT A UNIFORM CELL MUST LOOK LIKE DOUBLED AT THAT CELL.
    ///
    /// (maintainer, 2026-08-22: "The lattice looks weird. They aren't connected. They're
    /// like blocks floating on top of one another.")
    ///
    /// ★ THIS IS THE TEST THAT SEPARATES THE TWO EXPLANATIONS. Stepped's cells do not
    /// share nodes ACROSS A REGION BOUNDARY — that is the algorithm. Inside ONE region
    /// it is a plain uniform lattice and must join up exactly as doubled does. If the
    /// per-cell neighbour lookup were wrong for a real (non-dyadic) cell multiplier,
    /// every cell would draw in isolation and the block would come apart everywhere,
    /// not just at a seam — which is what "blocks floating on top of one another"
    /// describes. Same cell, same topology, so the two frames must agree closely.
    func testSteppedAtAUniformCellMatchesDoubled() throws {
        let (doubled, mesh) = try blockScene(algorithm: "doubled", organic: false)
        let dPix = try render(doubled, mesh: mesh, stepped: [])
        let (steppedScene, m2) = try blockScene(algorithm: "stepped", organic: false)
        // BOTH regions at the renderer's own cell — stepped, but uniform.
        let sPix = try render(steppedScene, mesh: m2, stepped: [5.5, 5.5])
        let delta = abs(Double(dPix - sPix)) / Double(max(dPix, 1))
        print(String(format: "\n── stepped(uniform 5.5) %d px vs doubled %d px — %.1f%% apart\n",
                     sPix, dPix, 100 * delta))
        XCTAssertLessThan(delta, 0.15,
            "★ stepped at a uniform cell renders \(Int(100 * delta))% away from doubled "
          + "at the same cell. Inside one region there is no seam, so the two are the "
          + "same lattice — a gap this size means the per-cell neighbour lookup is "
          + "failing and every cell is drawing in isolation.")
    }

    /// ★ AND THEY ARE NOT THE SAME PICTURE. Three algorithms that render identically
    /// would pass the bar above while proving only that SOMETHING is on screen — the
    /// exact shape of the defect being closed (the ladder drawn under another name).
    func testTheThreePicturesDiffer() throws {
        let (doubled, mesh) = try blockScene(algorithm: "doubled", organic: false)
        let dPix = try render(doubled, mesh: mesh, stepped: [])
        let (steppedScene, m2) = try blockScene(algorithm: "stepped", organic: false)
        let sPix = try render(steppedScene, mesh: m2, stepped: [5.3125, 6.875])
        let (organicScene, m3) = try blockScene(algorithm: "organic", organic: true)
        let oPix = try render(organicScene, mesh: m3, stepped: [])

        XCTAssertNotEqual(dPix, sPix,
                          "★ stepped rendered pixel-identically to doubled — it is the "
                        + "ladder wearing another name, which is what this closed")
        XCTAssertNotEqual(dPix, oPix,
                          "★ organic rendered pixel-identically to doubled")
    }
}
