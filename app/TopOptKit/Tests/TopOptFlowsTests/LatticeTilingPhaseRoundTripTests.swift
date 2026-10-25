// LatticeTilingPhaseRoundTripTests — the per-region tiling phase must SURVIVE the texture.
//
// ★ THE PHASE IS PACKED AS `axis + fraction` INTO ONE HALF-FLOAT CHANNEL, and that is the
// whole risk: a half near 2.0 resolves to ~0.001, so a fraction of 0.9995 packs as 1.9995,
// rounds to 2.0, and the shader decodes AXIS 2 WITH NO SHIFT. The correction lands on the
// wrong axis, the region is left exactly as mis-phased as before, and the quilt returns —
// which is what the maintainer saw after changing a face depth to 12.6 mm.
//
// This is the control that change needed and did not have: encode every fraction, put it
// through the SAME half conversion the texture uses, decode it the way the shader does,
// and require the cap to land on a cell boundary.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeTilingPhaseRoundTripTests: XCTestCase {

    /// The shader's own decode, in Swift: `paxis = floor(a)`, `pfrac = a - paxis`.
    private func decode(_ packed: Float) -> (axis: Int, frac: Double) {
        let a = max(0, packed)
        let axis = Int(floor(Double(a) + 1e-4))
        return (axis, Double(a) - Double(axis))
    }

    /// IEEE half, exactly as `makeCellTexture` stores it.
    private func half(_ v: Float) -> Float { Float(Float16(v)) }

    func testEveryFractionSurvivesTheHalfFloatChannel() {
        var worst = 0.0
        var worstCase = ""
        for axis in 0...2 {
            for k in 0...2000 {
                let frac = Double(k) / 2000.0            // 0 … 1, the full range
                var f = frac
                if f > 0.999 || f < 0.001 { f = 0 }      // the production clamp
                let packed = Float(axis) + Float(f)
                let (dAxis, dFrac) = decode(half(packed))
                XCTAssertEqual(dAxis, axis,
                               "★ the AXIS must survive: \(packed) decoded as axis \(dAxis), "
                               + "so the tiling shift would land on the wrong axis and the "
                               + "region would be left mis-phased — the quilt, returning.")
                let err = abs(dFrac - f)
                if err > worst { worst = err; worstCase = "axis \(axis) frac \(f)" }
            }
        }
        print("worst fraction error through the texture: \(worst)  at \(worstCase)")
        XCTAssertLessThan(worst, 0.002,
                          "★ a fraction is a shift in CELLS; 0.002 of a 6 mm cell is 12 µm, "
                          + "and anything looser moves the cap off the boundary it was "
                          + "computed to sit on.")
    }

    /// ★ AND THE PHASE PUTS THE CAP ON A BOUNDARY — the property, not the encoding.
    func testTheNearCapLandsOnACellBoundaryAfterTheRoundTrip() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let emission = Self.hisRegions(mesh)
        let occ = LatticePreviewOccupancy.occupancy(
            positions: mesh.positions, indices: mesh.indices, bounds: mesh.bounds, maxDim: 64)
        // A spread of cells, including ones that put the fraction near the boundary.
        let cells: [Double] = emission.regions.map { r in
            r.role == .include ? Swift.max(1.0, r.depthMM / 2) : 0
        }
        let packed = LatticeSDFRenderer.faceTilingPhase(
            regions: emission.regions, cellMM: cells,
            fallbackCellMM: cells.first(where: { $0 > 0 }) ?? 5, origin: occ.origin)
        for (i, r) in emission.regions.enumerated() where r.role == .include && r.kind == .face {
            let n = simd_normalize(r.normal)
            let a = abs(n)
            let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
            guard a[axis] > 0.99, cells[i] > 0 else { continue }
            let (dAxis, dFrac) = decode(half(packed[i]))
            XCTAssertEqual(dAxis, axis, "★ region \(i)'s shift decoded onto the wrong axis")
            let s0 = simd_dot(r.origin - SIMD3<Double>(occ.origin), n)
            let sign = n[axis] < 0 ? -1.0 : 1.0
            let t = (s0 - sign * dFrac * cells[i]) / cells[i]
            let off = abs(t - t.rounded())
            print(String(format: "  region %d axis %d cell %.2f -> cap off boundary by %.4f cells",
                         i, axis, cells[i], off))
            XCTAssertLessThan(off, 0.01,
                              "★ region \(i)'s declared face must land ON a cell boundary — "
                              + "a cap through the middle of a cell slices every strut at "
                              + "its fattest, which is the quilt.")
        }
    }

    /// His two declared walls, as the emission builds them. Inlined here when the
    /// throwaway diagnosis file it used to live in was removed — that file carried
    /// measurements that were later retracted, and a helper is not worth keeping a
    /// retracted claim alive for.
    static func hisRegions(_ mesh: ViewerMesh) -> LatticeRegionEmission.Result {
        var out: [LatticeRegionSpec] = []
        var skipped = 0
        for (face, depth) in [(FaceID(15), 11.0), (FaceID(2), 12.0)] {
            guard let resolved = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: resolved, role: .include,
                                                        depthMM: depth,
                                                        faceID: Int(face))
            else { skipped += 1; continue }
            out.append(spec)
        }
        return LatticeRegionEmission.Result(regions: out, skippedFaces: skipped)
    }
}
