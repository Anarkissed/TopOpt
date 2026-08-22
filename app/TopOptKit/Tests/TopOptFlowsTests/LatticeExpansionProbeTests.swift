// LatticeExpansionProbeTests — ★ IS THE REGION BIGGER THAN THE FACE, AND BY HOW MUCH?
// (maintainer, 2026-08-21, for the fourth time: "The lattice is bigger than the face
// itself. I am telling you, it's expanding.")
//
// ★ HE HAS BEEN RIGHT EACH TIME AND I MEASURED IT WRONG TWICE — once on a face that was
// not one of his, once against an occupancy that was already clipped to the region, so
// the region was compared with itself. This measures HIS faces (15, 13 mm; 2, 11 mm)
// against the PART INTERIOR, which is the only set a stray strut can be drawn into.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeExpansionProbeTests: XCTestCase {

    func testHowFarThePreviewsRegionRunsPastHisFace() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [(FaceID, LatticeRegionSpec)] = []
        for (f, depth) in [(FaceID(15), 11.0), (FaceID(2), 13.0)] {
            guard let geo = mesh.faceGeometry(f), geo.isPlane,
                  let o = mesh.facePlaneOutline(
                    f, planeNormal: SIMD3<Float>(geo.planeNormal),
                    planeOrigin: SIMD3<Float>(geo.planeOrigin)) else { continue }
            let loops = LatticeFaceOutline.loops(face: f, in: mesh,
                                                 normal: geo.planeNormal,
                                                 origin: SIMD3<Double>(o.center))
            guard let s = LatticeRegionEmission.spec(
                for: .plane(center: SIMD3<Double>(o.center), normal: geo.planeNormal,
                            halfUMM: Double(o.halfU), halfWMM: Double(o.halfV),
                            outlineLoops: loops),
                role: .include, depthMM: depth, faceID: Int(f)) else { continue }
            specs.append((f, s))
        }
        try XCTSkipIf(specs.isEmpty, "his faces did not resolve")

        // The scene as the AUTO path bakes it, at his own Fine 128³.
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: specs.map { $0.1 },
                                    whenEmpty: .latticeNothing)
        // ★★★ THE DENOMINATOR, AND I HAVE GOT IT WRONG THREE TIMES. `partSDF` is a
        // TRUNCATED narrow band, so `< 0` is a shell around the surface, not the
        // interior; `scene.occupancy` is already clipped to the regions, so comparing
        // against it compares the region with itself. The only honest "inside the part"
        // is an UNCLIPPED occupancy — a scene with no regions at all.
        let whole = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: [],
                                    whenEmpty: .latticeEverything).occupancy
        var interior = 0
        for v in whole.values where v > 0.5 { interior += 1 }
        let part = scene.partSDF
        let pad = 1.5 * Double(Swift.min(part.spacing.x,
                                         Swift.min(part.spacing.y, part.spacing.z)))

        // ★★ THE PAD, AS THE SCENE APPLIES IT: origin pushed OUT along the face normal
        // and depth grown by the same. Its own note argues this is free because
        // "outside the part is empty space" — which is true of a flat wall and FALSE at
        // a chamfer, where outward along the face normal is still solid material.
        var declared = 0, padded = 0, addedByPad = 0
        for i in 0..<part.count where part.values[i] < 0 {
            let ix = i % part.nx, iy = (i / part.nx) % part.ny, iz = i / (part.nx * part.ny)
            let p = SIMD3<Double>(
                Double(part.origin.x) + Double(ix) * Double(part.spacing.x),
                Double(part.origin.y) + Double(iy) * Double(part.spacing.y),
                Double(part.origin.z) + Double(iz) * Double(part.spacing.z))
            var inDeclared = false, inPadded = false
            for (_, s) in specs {
                if LatticeRegionMask.contains(p, region: s) { inDeclared = true }
                var o = s
                let n = simd_normalize(SIMD3<Double>(s.normal))
                o.origin = s.origin - n * pad
                o.depthMM = s.depthMM + pad
                if LatticeRegionMask.contains(p, region: o) { inPadded = true }
            }
            if inDeclared { declared += 1 }
            if inPadded { padded += 1 }
            if inPadded && !inDeclared { addedByPad += 1 }
        }

        print("""

        ── his two regions at Fine 128³ ─────────────────────────────────
        grid spacing ............... \(String(format: "%.3f", Double(part.spacing.x))) mm
        front-face pad ............. \(String(format: "%.3f", pad)) mm  (1.5 x spacing)
        ★ TOTAL part-interior voxels ........ \(interior)
        part-band voxels DECLARED ........... \(declared)
        part-interior voxels the BAKE uses .. \(padded)
        ★ ADDED BY THE PAD .................. \(addedByPad) \
        (\(declared > 0 ? String(format: "%.1f", 100.0 * Double(addedByPad) / Double(declared)) : "-")% more than he asked for)

        """)
        // ★★★ THE WALL: does the region now stop short of every surface EXCEPT the
        // declared face? Measured as "voxels within `wall` of the part surface that are
        // still in the region" — those are the chamfer and the top edge being eaten.
        let wall = 1.30   // his wallRingMM (0.46 + 2 x 0.42)
        let walled = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                     keepWallMM: wall, maxDim: 128,
                                     regions: specs.map { $0.1 },
                                     whenEmpty: .latticeNothing)
        func nearSurfaceInRegion(_ sc: LatticeSDFScene) -> (near: Int, mouth: Int) {
            guard let rg = sc.regionSDF else { return (0, 0) }
            var near = 0, mouth = 0
            var mouths = specs.map { $0.1 }
            for i in mouths.indices { mouths[i].depthMM = wall }
            for i in 0..<whole.count where whole.values[i] > 0.5 {
                let ix = i % whole.nx, iy = (i / whole.nx) % whole.ny
                let iz = i / (whole.nx * whole.ny)
                let pf = whole.origin + SIMD3<Float>(Float(ix) * whole.spacing.x,
                                                     Float(iy) * whole.spacing.y,
                                                     Float(iz) * whole.spacing.z)
                let d = Double(sc.partSDF.values[i])
                guard d > -wall else { continue }          // only the surface band
                guard rg.values[i] <= 0 else { continue }  // …and still latticed
                let p = SIMD3<Double>(pf)
                if mouths.contains(where: { LatticeRegionMask.contains(p, region: $0) }) {
                    mouth += 1
                } else {
                    near += 1
                }
            }
            return (near, mouth)
        }
        let before = nearSurfaceInRegion(scene)
        let after = nearSurfaceInRegion(walled)
        print("""

        ── the solid wall, his faces at 128³ ────────────────────────────
        wall kept ................................ \(wall) mm
        surface-band voxels still latticed, BEFORE  \(before.near)   (mouth: \(before.mouth))
        surface-band voxels still latticed, AFTER . \(after.near)   (mouth: \(after.mouth))
        ★ chamfer/edge voxels reclaimed .......... \(before.near - after.near)
        ★ the declared face's mouth is STILL open  \(after.mouth > 0 ? "yes" : "NO — it sealed the face too")

        """)
        XCTAssertLessThan(after.near, before.near,
                          "★ the wall must reclaim material at the surfaces he did NOT "
                          + "declare — that is the chamfer and the top edge")
        XCTAssertGreaterThan(after.mouth, 0,
                             "★ …and it must NOT seal the face he DID declare, or the "
                             + "lattice is walled off from the one opening it needs")

        XCTAssertGreaterThan(declared, 0, "positive control: his regions hold material")

        // ★★★ AND NOW THE ONE THAT MATTERS: what the SHADER sees. Both the march and
        // the SHELL read the baked region field by trilinear sample — the shell
        // DISCARDS wherever it is negative, which is how a region that reads too big
        // eats the chamfer and the ceiling. Compared against the exact law.
        let rg = try XCTUnwrap(scene.regionSDF)
        func sample(_ g: LatticeVoxelGrid, _ p: SIMD3<Float>) -> Float {
            let t = (p - g.origin) / g.spacing
            func lo(_ v: Float, _ n: Int) -> Int {
                Swift.min(Swift.max(Int(v.rounded(.down)), 0), n - 1)
            }
            let i = lo(t.x, g.nx), j = lo(t.y, g.ny), k = lo(t.z, g.nz)
            let i1 = Swift.min(i + 1, g.nx - 1), j1 = Swift.min(j + 1, g.ny - 1)
            let k1 = Swift.min(k + 1, g.nz - 1)
            let f = SIMD3<Float>(t.x - Float(i), t.y - Float(j), t.z - Float(k))
            func at(_ a: Int, _ b: Int, _ c: Int) -> Float {
                g.values[(c * g.ny + b) * g.nx + a]
            }
            let c00 = at(i,j,k)*(1-f.x) + at(i1,j,k)*f.x
            let c10 = at(i,j1,k)*(1-f.x) + at(i1,j1,k)*f.x
            let c01 = at(i,j,k1)*(1-f.x) + at(i1,j,k1)*f.x
            let c11 = at(i,j1,k1)*(1-f.x) + at(i1,j1,k1)*f.x
            return (c00*(1-f.y) + c10*f.y)*(1-f.z) + (c01*(1-f.y) + c11*f.y)*f.z
        }

        var shaderIn = 0, shaderOnly = 0, worstMM = 0.0, lawIn = 0
        for i in 0..<whole.count where whole.values[i] > 0.5 {
            let ix = i % whole.nx, iy = (i / whole.nx) % whole.ny, iz = i / (whole.nx * whole.ny)
            // ★★★ HALF A VOXEL OFF THE GRID POINT. Sampling AT the grid points is
            // exact by construction — trilinear interpolation reproduces the stored
            // value there — so the previous run's "0.00 mm overshoot" measured nothing
            // whatsoever. The shell's fragments land at arbitrary positions, and the
            // interpolation error is largest at the CELL CENTRE, half a voxel out on
            // every axis. That is where this samples.
            let pf = whole.origin + SIMD3<Float>(
                (Float(ix) + 0.5) * whole.spacing.x,
                (Float(iy) + 0.5) * whole.spacing.y,
                (Float(iz) + 0.5) * whole.spacing.z)
            let p = SIMD3<Double>(pf)
            let exact = specs.contains { LatticeRegionMask.contains(p, region: $0.1) }
            let shader = sample(rg, pf) <= 0
            if exact { lawIn += 1 }
            if shader { shaderIn += 1 }
            if shader && !exact {
                shaderOnly += 1
                let d = specs.map { LatticeRegionMask.signedDistance(p, region: $0.1) }.min() ?? 0
                worstMM = Swift.max(worstMM, d)
            }
        }
        print("""

        ── what the SHADER accepts vs the law, his faces, 128³ ──────────
        part interior (UNCLIPPED) ................ \(interior)
        the LAW accepts .......................... \(lawIn) \
        (\(interior > 0 ? String(format: "%.1f", 100.0 * Double(lawIn) / Double(interior)) : "-")% of the part)
        the SHADER accepts ....................... \(shaderIn)
        ★ shader accepts OUTSIDE the face ........ \(shaderOnly) \
        (\(lawIn > 0 ? String(format: "%.1f", 100.0 * Double(shaderOnly) / Double(lawIn)) : "-")% of the region)
        ★ worst overshoot ........................ \(String(format: "%.2f", worstMM)) mm

        """)
    }
}
