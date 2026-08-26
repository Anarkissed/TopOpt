import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE HOLES, RENDERED (his 2026-08-25: "there's a massive hole", and the tap
/// callout only ever reports the hole's EDGE — the ray goes through and lands on a
/// rim strut, so the area is genuinely empty).
///
/// Everything upstream of the GPU has been measured and is clean: 528 of 528
/// in-region cells painted, at both resolutions and every floor; only 1-2% of the
/// declared face has no material behind it; the sizes all mesh. So the remaining
/// suspect is the MARCH — drawing nothing where the field says a cell lives.
///
/// This renders his own scene offscreen and asks, per pixel, whether the lattice
/// drew anything, then varies ONE input at a time. A cause that survives every
/// variation is upstream; a cause that vanishes with a variation is named by it.
final class LatticeHoleRenderProbe: XCTestCase {

    private func scene() throws -> (LatticeSDFScene, [Double]) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let pl = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: pl, role: .include,
                                                     depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("face \(face) has no planar geometry") }
            specs.append(s)
        }
        return (LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                maxDim: 64, regions: specs,
                                whenEmpty: .latticeNothing),
                [10.312240362167358, 12.030947089195251])
    }

    /// Lit fraction of the frame, and the largest empty run along each scanline —
    /// a big contiguous run is a HOLE; scattered gaps are just a sparse truss.
    private func report(_ label: String, _ px: [UInt8], size: Int) {
        var lit = 0
        var worstRun = 0
        var rowsWithBigRun = 0
        for y in 0..<size {
            var run = 0, rowWorst = 0, rowLit = 0
            for x in 0..<size {
                let i = (y * size + x) * 4
                // The clear colour is the stage background; anything brighter is drawn.
                let v = Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])
                if v > 90 { lit += 1; rowLit += 1; run = 0 }
                else { run += 1; rowWorst = max(rowWorst, run) }
            }
            worstRun = max(worstRun, rowWorst)
            // only rows that actually contain lattice can have a HOLE in them
            if rowLit > 8, rowWorst > size / 8 { rowsWithBigRun += 1 }
        }
        print(String(format: "%-28@ lit %5.2f%%   longest empty run %3d px   rows with a big gap %3d",
                     label as NSString,
                     100 * Double(lit) / Double(size * size), worstRun, rowsWithBigRun))
    }

    func testWhereTheMarchDrawsNothing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let (sc, cells) = try scene()
        let size = 384
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        /// One render, with the scene's inputs varied by `setUp`.
        func shot(_ label: String, _ setUp: (LatticeSDFRenderer) -> Void) {
            guard let r = LatticeSDFRenderer(device: device, buildPipeline: true) else {
                print("\(label): renderer init failed — \(LatticeSDFRenderer.lastInitError ?? "?")")
                return
            }
            var p = LatticeProxyParams()
            p.latticeID = "octet"
            p.cellMM = cells[0]
            p.shapeFitBandMM = 10
            p.minRelativeDensity = 0.05
            p.maxRelativeDensity = 0.90
            r.params = p
            r.lineWidthMM = 0.45
            r.steppedCellMM = cells
            setUp(r)
            r.setScene(sc)
            // ★ FRAME THE PART, or the camera sits inside it (everything lit) or
            // outside it (nothing lit) and the frame measures neither.
            r.camera.frame(sc.bounds)
            r.camera.setOrientation(azimuth: 0.9, elevation: 0.25)
            guard let px = r.renderOffscreen(size: size, clear: clear) else {
                print("\(label): nothing rendered (no cell texture or no segments)")
                return
            }
            report(label, px, size: size)
        }

        print("=== HOLE RENDER PROBE (his two faces, Fast 64³) ===")
        shot("as shipped") { _ in }
        shot("no shape band") { $0.params.shapeFitBandMM = 0 }
        shot("no stepped (dyadic ladder)") { $0.steppedCellMM = [] }
        shot("uniform 6 mm cell") { $0.steppedCellMM = [6, 6] }
        // ★ DOES THE DRAWN STRUT ANSWER THE DENSITY AT ALL? Everything else held,
        // only the band the shader grades between moves. A lattice whose coverage
        // does not follow this is not being graded by it.
        for rho in [0.05, 0.20, 0.50, 0.90] {
            shot(String(format: "rho pinned at %.2f", rho)) {
                $0.params.minRelativeDensity = rho
                $0.params.maxRelativeDensity = rho
                $0.params.uniformRelativeDensity = rho
            }
        }
    }
}
