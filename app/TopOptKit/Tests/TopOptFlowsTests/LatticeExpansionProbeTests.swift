// LatticeExpansionProbeTests — ★ IS THE REGION BIGGER THAN THE FACE, AND BY HOW MUCH?
// (maintainer, 2026-08-21, for the fourth time: "The lattice is bigger than the face
// itself. I am telling you, it's expanding.")
//
// ★★★ THIS FILE HAS REPORTED "no expansion" THREE TIMES WHILE MEASURING NOTHING, so its
// denominator and its sample points are now the point of the file:
//
//   • NOT `scene.occupancy` — it is already clipped to the regions, so the region was
//     being compared with itself. A green run measuring nothing.
//   • NOT `partSDF < 0` — that is a TRUNCATED narrow band, a shell around the surface,
//     not the interior.
//   • NOT at voxel CENTRES — the baked field's values ARE the voxel centres, so
//     trilinear sampling there is exact by construction and cannot see interpolation
//     error. Half-voxel offsets are where a sampled field is worst.
//
//   The honest denominator is an UNCLIPPED occupancy: a scene built with `regions: []`
//   and `whenEmpty: .latticeEverything`. That is every voxel a stray strut could be
//   drawn into.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeExpansionProbeTests: XCTestCase {

    /// His two lattice walls, as the emission builds them.
    private func hisSpecs(_ mesh: ViewerMesh) -> [(FaceID, LatticeRegionSpec)] {
        var specs: [(FaceID, LatticeRegionSpec)] = []
        for (f, depth) in [(FaceID(15), 11.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: f, in: mesh),
                  let s = LatticeRegionEmission.spec(for: r, role: .include,
                                                     depthMM: depth, faceID: Int(f))
            else { continue }
            specs.append((f, s))
        }
        return specs
    }

    /// ★★★ REQUIREMENT 2: in plane the region is the face outline, no more and no less.
    ///
    /// The baked field is the thing both readers use, so the baked field is what is
    /// measured — against `LatticeRegionMask.contains`, which IS the declaration. Any
    /// point where the field says "inside" and the declaration says "outside" is
    /// material he did not mark, and until this task there were 1.5 voxels of it
    /// deliberately added along every declared face's normal.
    func testTheBakedFieldNeverReachesPastTheDeclaredFace() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let specs = hisSpecs(mesh)
        try XCTSkipIf(specs.isEmpty, "his faces did not resolve")

        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: specs.map { $0.1 },
                                    whenEmpty: .latticeNothing)
        let field = try XCTUnwrap(scene.regionSDF)
        // The denominator — see the file note.
        let whole = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: [],
                                    whenEmpty: .latticeEverything).occupancy

        /// Trilinear read of the baked field, exactly as the shaders sample it.
        func sample(_ p: SIMD3<Double>) -> Double {
            let g = SIMD3<Double>(
                (p.x - Double(field.origin.x)) / Double(field.spacing.x),
                (p.y - Double(field.origin.y)) / Double(field.spacing.y),
                (p.z - Double(field.origin.z)) / Double(field.spacing.z))
            let i0 = SIMD3<Int>(Int(floor(g.x)), Int(floor(g.y)), Int(floor(g.z)))
            let f = g - SIMD3<Double>(Double(i0.x), Double(i0.y), Double(i0.z))
            func at(_ x: Int, _ y: Int, _ z: Int) -> Double {
                let cx = Swift.min(Swift.max(x, 0), field.nx - 1)
                let cy = Swift.min(Swift.max(y, 0), field.ny - 1)
                let cz = Swift.min(Swift.max(z, 0), field.nz - 1)
                return Double(field.values[cx + field.nx * (cy + field.ny * cz)])
            }
            var acc = 0.0
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y)
                      * (dz == 1 ? f.z : 1 - f.z)
                acc += w * at(i0.x + dx, i0.y + dy, i0.z + dz)
            } } }
            return acc
        }

        // HALF-VOXEL OFFSETS — the worst case for a sampled field, and the only place
        // the old 1.5-voxel pad and the interpolation error are both visible.
        let h = SIMD3<Double>(Double(whole.spacing.x), Double(whole.spacing.y),
                              Double(whole.spacing.z)) * 0.5
        var interior = 0, fieldInside = 0, declaredInside = 0, past = 0
        var worstOvershootMM = 0.0
        for i in 0..<whole.values.count where whole.values[i] > 0.5 {
            interior += 1
            let ix = i % whole.nx, iy = (i / whole.nx) % whole.ny
            let iz = i / (whole.nx * whole.ny)
            let p = SIMD3<Double>(
                Double(whole.origin.x) + Double(ix) * Double(whole.spacing.x) + h.x,
                Double(whole.origin.y) + Double(iy) * Double(whole.spacing.y) + h.y,
                Double(whole.origin.z) + Double(iz) * Double(whole.spacing.z) + h.z)
            let inField = sample(p) <= 0
            let inDecl = specs.contains { LatticeRegionMask.contains(p, region: $0.1) }
            if inField { fieldInside += 1 }
            if inDecl { declaredInside += 1 }
            if inField && !inDecl {
                past += 1
                // How far outside the declaration it is — the honest size of the miss.
                let d = specs.map { LatticeRegionMask.signedDistance(p, region: $0.1) }.min() ?? 0
                worstOvershootMM = Swift.max(worstOvershootMM, d)
            }
        }

        let pct = declaredInside > 0
            ? 100.0 * Double(past) / Double(declaredInside) : 0
        print("""

        ── requirement 2, his two walls at Fine 128³, half-voxel offsets ──
        part-interior samples ................ \(interior)
        DECLARED (the analytic region) ....... \(declaredInside)
        the BAKED field calls inside ......... \(fieldInside)
        ★ inside the FIELD, outside the FACE . \(past)  (\(String(format: "%.2f", pct))%)
        ★ worst overshoot .................... \(String(format: "%.3f", worstOvershootMM)) mm
        voxel .................................\(String(format: "%.3f", Double(whole.spacing.x))) mm

        """)

        // ★ THE TOLERANCE IS ONE VOXEL, AND IT IS INTERPOLATION, NOT GEOMETRY. A
        // trilinear read half a voxel off the grid cannot resolve a boundary finer than
        // the grid; what this bars is a boundary deliberately moved, which is what the
        // 1.5-voxel pad was. Anything past one voxel is geometry, not sampling.
        let voxel = Double(whole.spacing.x)
        XCTAssertLessThanOrEqual(worstOvershootMM, voxel,
            "the baked region reaches \(worstOvershootMM) mm past the declared face — "
          + "more than the \(voxel) mm voxel, so it is the GEOMETRY that is bigger")
        XCTAssertGreaterThan(declaredInside, 0, "his declarations matched nothing")
    }

    /// ★★★ THE POSITIVE CONTROL — and it had to be REWRITTEN once, which is the finding.
    ///
    /// ★ THE FIRST VERSION CONTROLLED WITH THE 1.5-VOXEL PAD the bake used to add, and it
    /// measured 0 added samples. That is not a broken control, it is a RESULT: the pad
    /// extended the slab from s ∈ [0, depth] to s ∈ [−pad, depth], and everything it
    /// added lies OUTSIDE the part in front of the face. Its own note claimed that was
    /// free; on his part, at 128³, it measurably was. So the pad was never the expansion
    /// he has been reporting — removing it satisfies the ruling ("never bigger") but it
    /// was not the defect, and a probe controlled on it would have proved nothing.
    ///
    /// ★ THE REAL CLASS OF "BIGGER THAN THE FACE" IS THE BOUNDING BOX — the rectangle
    /// this task just stopped falling back to. On his two walls the rectangle is 41.2%
    /// and 29.8% face, so it declares interior material he never marked, which is
    /// exactly what the probe above must be able to see.
    func testTheProbeCatchesAnExpandedRegion() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let specs = hisSpecs(mesh)
        try XCTSkipIf(specs.isEmpty, "his faces did not resolve")

        // The SAME faces as a bounding-box slab: outline dropped, `faceID` dropped so
        // `LatticeRegionMask` still measures the rectangle (it now refuses to do that
        // for a face — that refusal is the fix; this reconstructs the old shape).
        let boxed: [LatticeRegionSpec] = specs.map { (_, s) in
            var o = s
            o.outlineLoops = []
            o.inPlaneOffsetMM = 0
            o.faceID = nil
            return o
        }

        let whole = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: [],
                                    whenEmpty: .latticeEverything).occupancy
        let voxel = Double(whole.spacing.x)
        var declared = 0, past = 0, worst = 0.0
        for i in 0..<whole.values.count where whole.values[i] > 0.5 {
            let ix = i % whole.nx, iy = (i / whole.nx) % whole.ny
            let iz = i / (whole.nx * whole.ny)
            let p = SIMD3<Double>(
                Double(whole.origin.x) + Double(ix) * Double(whole.spacing.x) + 0.5 * voxel,
                Double(whole.origin.y) + Double(iy) * Double(whole.spacing.y) + 0.5 * voxel,
                Double(whole.origin.z) + Double(iz) * Double(whole.spacing.z) + 0.5 * voxel)
            let inFace = specs.contains { LatticeRegionMask.contains(p, region: $0.1) }
            if inFace { declared += 1 }
            guard boxed.contains(where: { LatticeRegionMask.contains(p, region: $0) }),
                  !inFace else { continue }
            past += 1
            worst = Swift.max(worst, specs.map {
                LatticeRegionMask.signedDistance(p, region: $0.1) }.min() ?? 0)
        }
        let pct = declared > 0 ? 100.0 * Double(past) / Double(declared) : 0
        print("""
        ── positive control: the BOUNDING BOX ─────────────────────────────
        declared (the outline) ............... \(declared)
        ★ added by the rectangle ............. \(past)  (+\(String(format: "%.1f", pct))%)
        ★ worst overshoot .................... \(String(format: "%.3f", worst)) mm          (voxel \(String(format: "%.3f", voxel)) mm)
        """)
        XCTAssertGreaterThan(past, 0, "the rectangle added nothing — the control does not control")
        XCTAssertGreaterThan(worst, voxel,
            "the control's overshoot must exceed the tolerance the real probe uses, "
          + "or that probe could not have caught it")
    }
}
