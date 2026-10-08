import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ WHY A 13 mm WALL DERIVES A 6.5 mm CELL — the width distribution, printed.
///
/// His report, 2026-08-24: single-cell/member gives 12.00 mm on the back wall (its full
/// depth) but only 6.50 mm on the front. Same setting, same bake — so the floor is not
/// what differs; the MEASURED WIDTH is.
final class LatticeWallWidthProbe: XCTestCase {

    func testTheWidthDistributionOfEachWall() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        // ★ THE TRUE PAIRING, read from his saved project.json (selectableDepthMM):
        // face 15 → 12 mm, face 2 → 13 mm. The 2026-08-24 handoff had them SWAPPED,
        // and the swap was the whole mystery: with the real depths the observed
        // 12.00 / 6.50 falls straight out of the measured widths at floor 1.
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { continue }
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        regions: [spec], whenEmpty: .latticeNothing)
            let occ = scene.occupancy
            let n = simd_normalize(spec.normal)
            let h = Double(min(occ.spacing.x, min(occ.spacing.y, occ.spacing.z)))
            let sdf = scene.partSDF
            func solid(_ p: SIMD3<Double>) -> Bool {
                let g = (SIMD3<Float>(p) - sdf.origin) / sdf.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, a < sdf.nx, b >= 0, b < sdf.ny, c >= 0, c < sdf.nz
                else { return false }
                return sdf.values[(c * sdf.ny + b) * sdf.nx + a] < 0
            }
            var seen: [Double] = []
            for k in 0..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx {
                let idx = (k * occ.ny + j) * occ.nx + i
                guard occ.values[idx] > 0.5 else { continue }
                let p = SIMD3<Double>(
                    Double(occ.origin.x) + Double(i) * Double(occ.spacing.x),
                    Double(occ.origin.y) + Double(j) * Double(occ.spacing.y),
                    Double(occ.origin.z) + Double(k) * Double(occ.spacing.z))
                guard LatticeRegionMask.contains(p, region: spec) else { continue }
                var fwd = 0.0, back = 0.0, q = p
                while fwd < 400, solid(q + n * h) { q += n * h; fwd += h }
                q = p
                while back < 400, solid(q - n * h) { q -= n * h; back += h }
                seen.append(fwd + back + h)
            } } }
            guard !seen.isEmpty else { continue }
            seen.sort()
            func pct(_ f: Double) -> Double { seen[Int(f * Double(seen.count - 1))] }
            print(String(format:
                "FACE %d depth %.1f  n=%d  min %.2f  p05 %.2f  p25 %.2f  MEDIAN %.2f  p75 %.2f  max %.2f",
                Int(face), depth, seen.count, seen.first!, pct(0.05), pct(0.25),
                pct(0.5), pct(0.75), seen.last!))
        }
    }

    /// ★ THE FORMERLY-UNEXPLAINED STEP, INSTRUMENTED — and it is EXPLAINED. With the
    /// TRUE depth pairing (face 15 → 12, face 2 → 13, from his project.json; the
    /// handoff had them swapped) the observed screen is the derivation working as
    /// written, at floor 1 (single-cell + fullSkin finish):
    ///
    ///     face 15: w=10.31 → cell 10.31 → n=round(12/10.31)=1 → 12.00  (his back wall)
    ///     face  2: w= 8.59 → cell  8.59 → n=round(13/ 8.59)=2 →  6.50  (his front wall)
    ///
    /// The asymmetry is the p05 width statistic meeting the whole-number-of-cells
    /// rounding: 13/8.59 = 1.513 sits just past the 1.5 boundary, so the depth is cut
    /// in two; 12/10.31 = 1.16 does not. The 8.59 is that wall's thinnest sliver —
    /// its MEDIAN is 12.03 — which is the p05-pinning question the handoff says to
    /// put to him before changing the statistic.
    func testWhatTheDerivationDoesWithTheMeasuredWidths() throws {
        let bead = 0.45   // the shipped profile's strut bead (max of the two wall beads)
        for (label, w, depth) in [("face15", 10.31, 12.0), ("face2", 8.59, 13.0)] {
            for floor in [1.0, 2.0, 5.0] {
                let d = TopOptKit.latticeRegionDerivation(
                    topology: "octet", memberWidthMM: w,
                    minExtrudableWidthMM: bead, cellsPerMemberFloor: floor)
                // Never-overshoot (2026-08-24 evening): the fit depth is the
                // material's, so the divided length is min(depth, wall).
                let depth = Swift.min(depth, w)
                let n = Swift.max(1, (depth / d.cellMM).rounded())
                print(String(format:
                    "DERIVE %@ w=%.2f floor=%.0f  valid=%d feasible=%d coreCell=%.3f "
                    + "rho=%.3f strut=%.3f prints=%d  ->  n=%.0f final=%.3f",
                    label, w, floor, d.valid ? 1 : 0, d.feasible ? 1 : 0, d.cellMM,
                    d.derivedRelativeDensity, d.strutMM, d.prints ? 1 : 0,
                    n, depth / n))
            }
        }
    }

    /// ★ THE MEASUREMENT THE BAKE ACTUALLY TAKES — `wallWidthAlongNormalMM` itself (not
    /// this probe's re-walk), on a scene holding BOTH regions at once, which is the
    /// scene the app hands it. If ITS answer differs from the distribution above, the
    /// asymmetry lives in the measurement's own scene, not in the derivation.
    func testTheRealMeasurementOnTheBothRegionsScene() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { continue }
            specs.append(spec)
        }
        XCTAssertEqual(specs.count, 2, "both faces must yield a region spec")
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: specs, whenEmpty: .latticeNothing)
        for (i, spec) in specs.enumerated() {
            let wNormal = LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(
                region: spec, occupancy: scene.occupancy, partSDF: scene.partSDF)
            let wIso = scene.memberThicknessMM.isEmpty ? -1.0
                : LatticeMeasuredRegionWidth.widthMM(
                    region: spec, occupancy: scene.occupancy,
                    memberThicknessMM: scene.memberThicknessMM)
            print(String(format:
                "MEASURE region=%d face=%@ depth=%.1f  alongNormal=%.3f  isotropic=%.3f",
                i, String(describing: spec.faceID), spec.depthMM, wNormal, wIso))
        }
    }
}
