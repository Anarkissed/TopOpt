// LatticeRegionBleedProbeTests — ★ HOW FAR PAST THE FACE DOES THE PREVIEW DRAW?
// (maintainer, 2026-08-21: "The faces are in the middle of the walls. They both have
// chamfers on every side of them - space which will be printed solid. I do not want to
// see lattice peeking through there, It shouldn't expand beyond its actual face shape.")
//
// ★ MEASUREMENT FIRST. Three things could put a strut outside the face — a positive
// expand, an empty outline falling back to the bounding rectangle, or the region SDF
// being SAMPLED at grid spacing rather than evaluated. They have different fixes and
// only one of them is worth changing code for, so this counts them apart before anything
// moves.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeRegionBleedProbeTests: XCTestCase {

    /// Trilinear sample of a voxel grid — what the SHADER does with the region texture.
    private func sample(_ g: LatticeVoxelGrid, _ p: SIMD3<Float>) -> Float {
        let t = (p - g.origin) / g.spacing
        func lo(_ v: Float, _ n: Int) -> Int { Swift.min(Swift.max(Int(v.rounded(.down)), 0), n - 1) }
        let i = lo(t.x, g.nx), j = lo(t.y, g.ny), k = lo(t.z, g.nz)
        let i1 = Swift.min(i + 1, g.nx - 1), j1 = Swift.min(j + 1, g.ny - 1)
        let k1 = Swift.min(k + 1, g.nz - 1)
        let f = SIMD3<Float>(t.x - Float(i), t.y - Float(j), t.z - Float(k))
        func at(_ a: Int, _ b: Int, _ c: Int) -> Float { g.values[(c * g.ny + b) * g.nx + a] }
        let c00 = at(i, j, k) * (1 - f.x) + at(i1, j, k) * f.x
        let c10 = at(i, j1, k) * (1 - f.x) + at(i1, j1, k) * f.x
        let c01 = at(i, j, k1) * (1 - f.x) + at(i1, j, k1) * f.x
        let c11 = at(i, j1, k1) * (1 - f.x) + at(i1, j1, k1) * f.x
        let c0 = c00 * (1 - f.y) + c10 * f.y, c1 = c01 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }

    /// ★★ HIS OWN FACE, BUILT THE WAY THE APP BUILDS IT — outline loops and all.
    /// The first version of this probe used a synthetic 200x200 slab with ZERO loops
    /// and reported a perfect match, which measured nothing: with no outline the mask
    /// falls back to the rectangle and there is no face shape to overshoot.
    private func hisFaceRegion(_ mesh: ViewerMesh, face f: FaceID,
                               depthMM: Double, expandMM: Double = 0) throws
        -> LatticeRegionSpec {
        guard let geo = mesh.faceGeometry(f), geo.isPlane,
              let o = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                            planeOrigin: SIMD3<Float>(geo.planeOrigin))
        else { throw XCTSkip("face \(f) has no planar geometry") }
        let loops = LatticeFaceOutline.loops(face: f, in: mesh, normal: geo.planeNormal,
                                             origin: SIMD3<Double>(o.center))
        let resolved = LatticeRegionEmission.ResolvedFace.plane(
            center: SIMD3<Double>(o.center), normal: geo.planeNormal,
            halfUMM: Double(o.halfU), halfWMM: Double(o.halfV), outlineLoops: loops)
        return try XCTUnwrap(LatticeRegionEmission.spec(
            for: resolved, role: .include, depthMM: depthMM,
            faceID: Int(f), expandMM: expandMM))
    }

    /// The biggest PLANAR face — his lattice wall. Planarity matters: the emission
    /// only builds a slab for a plane, and the first pick (the most triangles overall)
    /// was a curved face and skipped the whole probe.
    private func biggestPlanarFace(_ mesh: ViewerMesh) -> FaceID? {
        var count: [Int32: Int] = [:]
        for id in mesh.faceIDs { count[id, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }
            .first { mesh.faceGeometry($0.key)?.isPlane == true }
            .map { $0.key }
    }

    func testHowFarPastTheFaceThePreviewAccepts() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = try XCTUnwrap(biggestPlanarFace(mesh))
        let region = try hisFaceRegion(mesh, face: f, depthMM: 11)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let rg = try XCTUnwrap(scene.regionSDF, "no region field was baked")
        let occ = scene.occupancy

        print("""

        ── the region, as declared ──────────────────────────────────────
        outline loops ............ \(region.outlineLoops.count)
        in-plane offset (expand) . \(region.inPlaneOffsetMM) mm
        half-extents ............. \(region.halfUMM) x \(region.halfWMM) mm
        occupancy spacing ........ \(occ.spacing.x) mm
        region-field spacing ..... \(rg.spacing.x) mm
        """)

        // ★ THE COMPARISON: the EXACT set (`contains`, the law the job uses) against the
        // SAMPLED set (what the shader accepts). Every voxel the shader accepts and the
        // law does not is a strut drawn outside the face.
        // ★ AGAINST THE PART INTERIOR, NOT THE OCCUPANCY. `scene.occupancy` is ALREADY
        // clipped to the declared regions (`whenEmpty: .latticeNothing`), so the first
        // run of this compared the clipped set against itself and reported a perfect
        // 7581 = 7581 — a green run measuring nothing, for the second time in this file.
        // `partSDF < 0` is the part's own interior, which is the set a stray strut could
        // actually be drawn into.
        let part = scene.partSDF
        var exactIn = 0, shaderIn = 0, shaderOnly = 0, exactOnly = 0, insideCount = 0
        var worstOvershootMM = 0.0
        for i in 0..<part.count where part.values[i] < 0 {
            insideCount += 1
            let ix = i % part.nx, iy = (i / part.nx) % part.ny, iz = i / (part.nx * part.ny)
            let pf = part.origin + SIMD3<Float>(Float(ix) * part.spacing.x,
                                                Float(iy) * part.spacing.y,
                                                Float(iz) * part.spacing.z)
            let p = SIMD3<Double>(pf)
            let exact = LatticeRegionMask.contains(p, region: region)
            let shader = sample(rg, pf) <= 0
            if exact { exactIn += 1 }
            if shader { shaderIn += 1 }
            if shader && !exact {
                shaderOnly += 1
                // How far outside is it, in the region's own terms?
                let d = LatticeRegionMask.signedDistance(p, region: region)
                worstOvershootMM = Swift.max(worstOvershootMM, d)
            }
            if exact && !shader { exactOnly += 1 }
        }

        print("""

        ── what the shader accepts vs what the law says ─────────────────
        voxels inside the part ... \(insideCount)
        the LAW accepts .......... \(exactIn)
        the SHADER accepts ....... \(shaderIn)
        shader-only (drawn OUTSIDE the face) .. \(shaderOnly)
        law-only (missed) ..................... \(exactOnly)
        worst overshoot ....................... \(String(format: "%.3f", worstOvershootMM)) mm

        """)
        XCTAssertGreaterThan(exactIn, 0, "positive control: the region has material")
    }

    /// ★★★ THE FRONT-FACE PAD, MEASURED (`LatticeSDFScene.init`).
    ///
    /// The region field is baked from regions whose origin is pushed `1.5 x spacing`
    /// OUTWARD along the face normal and whose depth grows by the same, to break a
    /// coincidence between the region's zero crossing and the part's surface. Its own
    /// note argues this is free because "outside the part is empty space".
    ///
    /// ★ THAT ARGUMENT HOLDS FOR A FLAT WALL AND NOT FOR A CHAMFERED ONE. Along a
    /// chamfer, "outward along the face normal" is still INSIDE the solid — so the pad
    /// hands the march a band of real material the user never declared, and it is
    /// exactly chamfer-sized. This counts that band on his part.
    func testHowMuchMaterialTheFrontFacePadAdds() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = try XCTUnwrap(biggestPlanarFace(mesh))
        let region = try hisFaceRegion(mesh, face: f, depthMM: 11)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let part = scene.partSDF
        let pad = 1.5 * Double(Swift.min(part.spacing.x,
                                         Swift.min(part.spacing.y, part.spacing.z)))
        var padded = region
        let n = simd_normalize(SIMD3<Double>(region.normal))
        padded.origin = region.origin - n * pad
        padded.depthMM = region.depthMM + pad

        var declared = 0, withPad = 0, addedByPad = 0
        for i in 0..<part.count where part.values[i] < 0 {
            let ix = i % part.nx, iy = (i / part.nx) % part.ny, iz = i / (part.nx * part.ny)
            let p = SIMD3<Double>(
                Double(part.origin.x) + Double(ix) * Double(part.spacing.x),
                Double(part.origin.y) + Double(iy) * Double(part.spacing.y),
                Double(part.origin.z) + Double(iz) * Double(part.spacing.z))
            let a = LatticeRegionMask.contains(p, region: region)
            let b = LatticeRegionMask.contains(p, region: padded)
            if a { declared += 1 }
            if b { withPad += 1 }
            if b && !a { addedByPad += 1 }
        }
        print("""

        ── the front-face pad, on his part ──────────────────────────────
        pad ....................... \(String(format: "%.2f", pad)) mm
        the user declared ......... \(declared) voxels
        the bake actually uses .... \(withPad) voxels
        added by the pad .......... \(addedByPad) voxels \
        (\(declared > 0 ? String(format: "%.1f", 100.0 * Double(addedByPad) / Double(declared)) : "-")%)

        """)
        XCTAssertGreaterThan(declared, 0, "positive control")
    }
}
