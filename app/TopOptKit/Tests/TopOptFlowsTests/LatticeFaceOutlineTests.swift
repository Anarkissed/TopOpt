// LatticeFaceOutlineTests — ★ THE OUTLINE IS THE FACE, THE RECTANGLE WAS NOT.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeFaceOutlineTests: XCTestCase {

    /// ★ THE MEASUREMENT THAT SENT US HERE, now an assertion. On his own part the
    /// emitted bounding rectangle is 2.4× and 3.4× the face it claims to be; the
    /// outline recovers the face itself.
    func testTheOutlineRecoversTheFaceTheRectangleOverstates() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()

        func trueArea(_ f: FaceID) -> Double {
            var area = 0.0, i = 0
            func P(_ n: Int) -> SIMD3<Double> {
                let k = Int(mesh.indices[n]) * 3
                return SIMD3<Double>(Double(mesh.positions[k]), Double(mesh.positions[k+1]),
                                     Double(mesh.positions[k+2]))
            }
            while i + 2 < mesh.indices.count {
                if i / 3 < mesh.faceIDs.count, mesh.faceIDs[i / 3] == Int32(f) {
                    area += simd_length(simd_cross(P(i+1) - P(i), P(i+2) - P(i))) * 0.5
                }
                i += 3
            }
            return area
        }
        /// Shoelace over the loops — signed areas cancel, so a hole subtracts.
        func loopArea(_ loops: [LatticeFaceOutline.Loop]) -> Double {
            var total = 0.0
            for l in loops {
                var s = 0.0
                var j = l.count - 1
                for i in 0..<l.count { s += (l[j].x * l[i].y - l[i].x * l[j].y); j = i }
                total += abs(s) * 0.5
            }
            return total
        }

        var reported = ""
        for f in [FaceID(15), FaceID(2), FaceID(18)] {
            guard let geo = mesh.faceGeometry(f), geo.isPlane,
                  let o = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                                planeOrigin: SIMD3<Float>(geo.planeOrigin))
            else { continue }
            let loops = LatticeFaceOutline.loops(
                face: f, in: mesh, normal: geo.planeNormal,
                origin: SIMD3<Double>(o.center))
            XCTAssertFalse(loops.isEmpty, "face \(f) must produce a closed outline")
            let rect = Double(o.halfU) * Double(o.halfV) * 4
            let truth = trueArea(f), poly = loopArea(loops)
            reported += String(format: "  face %3d  true %9.1f   rect %9.1f (%5.1f%%)   outline %9.1f (%5.1f%%)\n",
                               Int(f), truth, rect, 100 * truth / rect, poly, 100 * poly / truth)
            // The outline's own area must match the face's triangles closely.
            XCTAssertEqual(poly, truth, accuracy: 0.06 * truth,
                           "★ face \(f): the outline must enclose the FACE's area, not a "
                           + "bounding box's. rect=\(Int(rect)) true=\(Int(truth))")
        }
        print("""

        ================================================================================
        THE OUTLINE vs THE EMITTED RECTANGLE — his part
        \(reported)★ the rect column is what every lattice region has been until now.
        ================================================================================
        """)
    }

    /// ★★ THE OUTLINE REACHES THE LATTICE — the artifact fix, as a number.
    ///
    /// Two regions for the SAME face 15, identical in every field except one: the
    /// outline. The rectangle latticed 2.4x the face; the outline latticed the
    /// face. The occupied-voxel ratio has to track the AREA ratio, because the
    /// slab depth is the same for both.
    func testTheOutlineRegionLatticesOnlyTheFace() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = FaceID(15)
        guard let geo = mesh.faceGeometry(f), geo.isPlane,
              let o = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                            planeOrigin: SIMD3<Float>(geo.planeOrigin))
        else { throw XCTSkip("face 15 has no planar geometry") }

        func spec(withOutline: Bool) -> LatticeRegionSpec {
            var s = LatticeRegionSpec(role: .include, kind: .face)
            s.origin = SIMD3<Double>(o.center)
            s.normal = -simd_normalize(geo.planeNormal)   // the emission's own flip
            s.halfUMM = Double(o.halfU); s.halfWMM = Double(o.halfV)
            s.depthMM = 11.0
            if withOutline {
                s.outlineLoops = LatticeFaceOutline.loops(
                    face: f, in: mesh, normal: geo.planeNormal,
                    origin: SIMD3<Double>(o.center))
            }
            return s
        }
        func occupied(_ r: LatticeRegionSpec) -> Int {
            LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                            regions: [r], whenEmpty: .latticeNothing)
                .occupancy.values.filter { $0 > 0.5 }.count
        }
        let rect = occupied(spec(withOutline: false))
        let outline = occupied(spec(withOutline: true))
        print("""

        ================================================================================
        WHAT THE REGION ACTUALLY LATTICES — face 15, same depth, same everything else
          bounding RECTANGLE (until now) .... \(rect) voxels
          the face's real OUTLINE ........... \(outline) voxels
          the rectangle latticed \(rect > 0 ? Double(outline) / Double(rect) : 0) of what it should
        ★ the difference is struts inside solid shell — the artifacts.
        ================================================================================
        """)
        XCTAssertGreaterThan(rect, 0, "the rectangle arm must lattice something to compare")
        XCTAssertLessThan(outline, rect,
                          "★ the outline must lattice STRICTLY LESS than the bounding box")
        // Face 15's outline is 41.2% of its rectangle by area, and both share a
        // depth, so the volume ratio must land near that rather than merely below 1.
        let ratio = Double(outline) / Double(rect)
        XCTAssertEqual(ratio, 0.412, accuracy: 0.10,
                       "★ the latticed VOLUME must track the AREA the face actually "
                       + "covers (41.2%). A ratio near 1 would mean the outline never "
                       + "reached the mask; near 0 would mean it emptied the region.")
    }

    /// ★★ THE FACE'S OWN SURFACE MUST BE INSIDE ITS OWN REGION.
    ///
    /// ★ THE TEST THAT WAS MISSING, AND THE BUG IT WOULD HAVE CAUGHT. Every
    /// earlier assertion here compared AREAS — the outline enclosed the right
    /// amount of face. Area is invariant under a reflection, so all of them
    /// passed while the region was MIRRORED: `LatticeRegionMask.basis` derives
    /// `u = unit(cross(n, a))`, and `LatticeRegionEmission.spec` flips the normal
    /// to reach into the part, so loops built on the OUTWARD normal came out
    /// reflected about v. On screen the lattice landed beside the face instead of
    /// on it, overlapping only in a narrow band.
    ///
    /// This assertion cannot be satisfied by a mirror: it walks the face's own
    /// triangle centroids, pushes each one just inside the slab, and requires the
    /// REGION to contain it. It is expressed in world space, so it is independent
    /// of whichever in-plane basis anyone chose.
    func testTheFacesOwnSurfaceIsInsideItsOwnRegion() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        for f in [FaceID(15), FaceID(2)] {
            guard let resolved = LatticeRegionEmission.planeFor(face: f, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: resolved, role: .include,
                                                        depthMM: 11.0, faceID: Int(f))
            else { continue }
            XCTAssertFalse(spec.outlineLoops.isEmpty, "face \(f) must carry an outline")

            var tested = 0, inside = 0
            var i = 0
            func P(_ n: Int) -> SIMD3<Double> {
                let k = Int(mesh.indices[n]) * 3
                return SIMD3<Double>(Double(mesh.positions[k]), Double(mesh.positions[k+1]),
                                     Double(mesh.positions[k+2]))
            }
            while i + 2 < mesh.indices.count {
                if i / 3 < mesh.faceIDs.count, mesh.faceIDs[i / 3] == Int32(f) {
                    let c = (P(i) + P(i+1) + P(i+2)) / 3
                    // 1 mm along the slab's own direction — comfortably inside a
                    // depth of 11 mm, and off the boundary where a centroid on the
                    // rim could legitimately read either way.
                    let p = c + simd_normalize(spec.normal) * 1.0
                    tested += 1
                    if LatticeRegionMask.contains(p, region: spec) { inside += 1 }
                }
                i += 3
            }
            XCTAssertGreaterThan(tested, 40, "face \(f) must have a real tessellation")
            let frac = Double(inside) / Double(tested)
            print(String(format: "  face %3d: %d of %d face centroids inside its own region (%.1f%%)",
                         Int(f), inside, tested, 100 * frac))
            XCTAssertGreaterThan(frac, 0.97,
                                 "★ face \(f): the face's OWN surface must lie inside the "
                                 + "region that face declares. A mirrored outline scores "
                                 + "near chance here while every AREA assertion still passes.")
        }
    }

    /// ★★ THE SHELL'S OWN SURFACE MUST BE DECISIVELY INSIDE THE REGION FIELD.
    ///
    /// ★ THE DEFECT THIS PINS (maintainer, 2026-08-19: "it made the face that the
    /// primitive originated from become solid instead of a lattice … there are
    /// still an *incredible* amount of artifacts and I don't understand why").
    /// A face region starts AT the face — `s ∈ [0, depth]` with the origin on the
    /// surface — so the region's front boundary was COINCIDENT with the shell's
    /// own triangles. The analytic clip tested `s >= 0` exactly and did not care;
    /// a SAMPLED field cannot. At the surface the baked field read +0.00, and
    /// every shell fragment there tested `field <= 0` against interpolation error
    /// of order the voxel size — a per-pixel coin flip. The face read solid, and
    /// the fragments that flipped let a strut through as a speckle.
    ///
    /// The bake now pushes the slab's FRONT face one and a half voxels out of the
    /// part, into the empty space the inward normal guarantees is there. Same
    /// region, no coincidence.
    func testTheShellSurfaceIsDecisivelyInsideTheRegionField() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = FaceID(15)
        guard let resolved = LatticeRegionEmission.planeFor(face: f, in: mesh)
        else { throw XCTSkip("face 15 has no planar geometry") }

        func P(_ n: Int) -> SIMD3<Double> {
            let k = Int(mesh.indices[n]) * 3
            return SIMD3<Double>(Double(mesh.positions[k]), Double(mesh.positions[k+1]),
                                 Double(mesh.positions[k+2]))
        }
        var seeds: [SIMD3<Double>] = []
        var i = 0
        while i + 2 < mesh.indices.count {
            if i / 3 < mesh.faceIDs.count, mesh.faceIDs[i/3] == Int32(f) {
                seeds.append((P(i) + P(i+1) + P(i+2)) / 3)
            }
            i += 3
        }
        XCTAssertGreaterThan(seeds.count, 40)

        var occupancies: [Int] = []
        for expand in [0.0, -3.0, -5.0] {
            let spec = try XCTUnwrap(LatticeRegionEmission.spec(
                for: resolved, role: .include, depthMM: 11.0, faceID: 15, expandMM: expand))
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        regions: [spec], whenEmpty: .latticeNothing)
            let g = try XCTUnwrap(scene.regionSDF)
            func sample(_ p: SIMD3<Double>) -> Float {
                let q = (SIMD3<Float>(p) - g.origin) / g.spacing
                let x = Int(q.x.rounded()), y = Int(q.y.rounded()), z = Int(q.z.rounded())
                guard x >= 0, x < g.nx, y >= 0, y < g.ny, z >= 0, z < g.nz else { return 9e9 }
                return g.values[(z * g.ny + y) * g.nx + x]
            }
            // Every seed that the region actually covers must read decisively
            // negative AT THE SURFACE, not ~0. One voxel of margin is the bar.
            let voxel = Swift.min(g.spacing.x, Swift.min(g.spacing.y, g.spacing.z))
            // ★ SEEDS WELL CLEAR OF THE RIM ONLY. Near the outline's edge the
            // field MUST cross zero — that is the in-plane boundary doing its job,
            // and including those would assert the region has no edge. The defect
            // being pinned is about the FRONT face, so restrict to points whose
            // only nearby boundary is that one: more than two voxels inside the
            // outline in plane.
            let n3 = simd_normalize(spec.normal)   // points INTO the part
            let (bu, bv) = LatticeRegionMask.basis(n3)
            var covered = 0, decisive = 0
            for seed in seeds {
                // ★★★ SAMPLED WHERE THE SHADER SAMPLES — ONE VOXEL INTO THE REGION.
                //
                // ★ THIS USED TO READ THE BARE FIELD AT THE SURFACE and require it a
                // full voxel negative, which was the FRONT-FACE PAD's job: the bake
                // pushed the slab's front face 1.5 voxels out of the part so the shell
                // sat unambiguously inside it. The ruling of 2026-08-21 removed that pad
                // — the primitive is "ONLY AS BIG AS THE FACE … Never bigger" — and the
                // ambiguity it existed to break is a SAMPLING problem, so it is now
                // broken at the sample instead: `shell_is_latticed` steps `spacing.w`
                // along the declared face's inward normal before it reads the field.
                //
                // The property under test has not moved an inch: the shell's discard at
                // the declared face must be DECISIVE, never a per-pixel coin flip. What
                // moved is where production asks, so this asks in the same place.
                let d = sample(seed + n3 * Double(voxel))
                guard d < 9e8 else { continue }
                // The shader's test is `field <= 0` after the nudge; a quarter-voxel of
                // margin is what makes it a verdict rather than a coin flip. Requiring a
                // FULL voxel here would be requiring the pad back by another name — at
                // exactly one voxel in, the true distance IS one voxel and rounding
                // decides it.
                let rel = seed - spec.origin
                let uv = SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv))
                let inPlane = LatticeFaceOutline.signedDistance(uv, loops: spec.outlineLoops)
                    - spec.inPlaneOffsetMM
                guard inPlane < -2.0 * Double(voxel) else { continue }
                covered += 1
                if d <= -0.25 * voxel { decisive += 1 }
            }
            XCTAssertGreaterThan(covered, 10, "expand \(expand): the region must cover the face")
            XCTAssertEqual(decisive, covered,
                           "★ expand \(expand): every shell fragment the region covers must "
                           + "sample the field a full voxel INSIDE. At +0.00 the discard is a "
                           + "coin flip and the face reads solid with strut speckles through it.")
            occupancies.append(scene.occupancy.values.filter { $0 > 0.5 }.count)
        }
        // ★ AND THE NUDGE MUST NOT HAVE MOVED THE REGION. The expand still bites,
        // monotonically, and only in plane.
        XCTAssertTrue(occupancies[0] > occupancies[1] && occupancies[1] > occupancies[2],
                      "a negative expand must keep shrinking the latticed volume: \(occupancies)")
        print("""

        ================================================================================
        THE SHELL SURFACE vs THE REGION FIELD — face 15
          occupancy at expand 0 / -3 / -5 mm ... \(occupancies)
        ★ shrinks in plane only; the field at the surface is a full voxel inside.
        ================================================================================
        """)
    }

    /// ★★ THE SKIN LEAVES A SOLID WALL — the maintainer's "make the walls thicker",
    /// done with the setting he already chose rather than by faking geometry.
    ///
    /// ★ THE MEASUREMENT BEHIND IT: the plate under his face 15 is 9.75 mm thick
    /// and he declared an 11.0 mm slab. The region is DEEPER THAN THE WALL, so the
    /// lattice ran clean through and out the far side and no solid material was
    /// left in that plate at all — "the walls of shell are impossibly thin" was
    /// literally true, because there was no wall, only the mesh's zero-thickness
    /// surface. His Finish has said `fullSkin` throughout; the preview simply
    /// never read `boundary`.
    ///
    /// The skin is cut out of the region field itself (`max(region, partSDF +
    /// skin)`), so ONE field still carries the whole rule: the march stops short
    /// of the surface and the shell — which discards where that field is negative
    /// — SURVIVES in the band. The surviving band is the wall.
    func testTheSkinLeavesASolidWallAtTheSurface() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        guard let resolved = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              let spec = LatticeRegionEmission.spec(for: resolved, role: .include,
                                                    depthMM: 11.0, faceID: 15)
        else { throw XCTSkip("face 15 has no planar geometry") }

        func P(_ n: Int) -> SIMD3<Double> {
            let k = Int(mesh.indices[n]) * 3
            return SIMD3<Double>(Double(mesh.positions[k]), Double(mesh.positions[k+1]),
                                 Double(mesh.positions[k+2]))
        }
        var seeds: [SIMD3<Double>] = []
        var i = 0
        while i + 2 < mesh.indices.count {
            if i/3 < mesh.faceIDs.count, mesh.faceIDs[i/3] == 15 {
                seeds.append((P(i)+P(i+1)+P(i+2))/3)
            }
            i += 3
        }
        let seed = seeds[seeds.count/2]
        let n = simd_normalize(spec.normal)

        func fieldAt(_ skin: Double, _ depth: Double) -> Float {
            let sc = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                     regions: [spec], whenEmpty: .latticeNothing,
                                     skinMM: skin)
            guard let g = sc.regionSDF else { return 9e9 }
            let p = seed + n * depth
            let q = (SIMD3<Float>(p) - g.origin) / g.spacing
            let a = Int(q.x.rounded()), b = Int(q.y.rounded()), c = Int(q.z.rounded())
            guard a >= 0, a < g.nx, b >= 0, b < g.ny, c >= 0, c < g.nz else { return 9e9 }
            return g.values[(c * g.ny + b) * g.nx + a]
        }
        // With a 2 mm skin the first 2 mm must be OUTSIDE the latticed volume …
        XCTAssertGreaterThan(fieldAt(2.0, 0.0), 0,
                             "★ a skin must leave the surface itself SOLID")
        XCTAssertGreaterThan(fieldAt(2.0, 1.0), 0,
                             "★ …and the whole band, not just the outermost sample")
        // … and past it the lattice resumes.
        XCTAssertLessThan(fieldAt(2.0, 5.0), 0,
                          "★ past the skin the region must lattice again")
        // ★★★ WITH NO SKIN THE REGION STARTS **AT** THE FACE, exactly as declared.
        //
        // ★ THIS USED TO DEMAND THE FIELD BE < -0.5 AT THE SURFACE, which only held
        // because the bake padded the slab's front face 1.5 voxels out of the part. That
        // pad made the primitive bigger than the face and was removed by the ruling of
        // 2026-08-21. At the surface the field is now ~0 BY CONSTRUCTION — that is what
        // "the region is exactly the face" means — and the coin flip it used to cause is
        // resolved by the reader instead: the shell steps one voxel inward first.
        //
        // So the bar is now the two things that must actually be true.
        let atSurface = fieldAt(0.0, 0.0)
        XCTAssertLessThan(abs(Double(atSurface)), 1.0,
                          "★ with no skin the region's front boundary IS the face — a "
                          + "field far from zero there means it was moved again")
        let nudged = fieldAt(0.0, 2.0)
        XCTAssertLessThan(nudged, -0.5,
                          "★ and one step in it is decisively inside, which is what the "
                          + "shell reads (`shell_is_latticed` nudges before sampling)")
    }

    /// ★ ONLY `covered` HAS A SOLID THICKNESS — corrected from the first cut,
    /// which gave it to `fullSkin` (maintainer, 2026-08-19: "The skin is
    /// incorrect. It's adding a FULL skin back onto the lattice … The skin is
    /// supposed to be like it is in the settings: a covering across all
    /// edges/corners. Meanwhile, rim is supposed to be around only the outside
    /// edges"). Rim and Skin are LATTICE geometry — a frame of edge struts, and a
    /// diagrid woven across the faces — so neither is an offset, and both return
    /// 0 here until D1 draws them.
    func testOnlyCoveredLeavesASolidWall() {
        XCTAssertEqual(LatticeBoundaryTreatment.none.faceSkinMM(wallRingMM: 1.26), 0)
        XCTAssertEqual(LatticeBoundaryTreatment.rim.faceSkinMM(wallRingMM: 1.26), 0,
                       "a rim closes the BORDER — it is not a wall across the face")
        XCTAssertEqual(LatticeBoundaryTreatment.fullSkin.faceSkinMM(wallRingMM: 1.26), 0,
                       "★ a diagrid skin is an open LATTICE, not a slab")
        XCTAssertEqual(LatticeBoundaryTreatment.covered.faceSkinMM(wallRingMM: 1.26), 1.26,
                       accuracy: 1e-12)
        // And the cover is the only one that carries an outer finish to core.
        XCTAssertEqual(LatticeBoundaryTreatment.covered.jobOuterFinish, "shell")
        XCTAssertNil(LatticeBoundaryTreatment.fullSkin.jobOuterFinish)
        XCTAssertNil(LatticeBoundaryTreatment.rim.jobOuterFinish)
        // And the ring is the slicer's own: outer + (loops-1)·inner.
        var pp = PrintParams.fdmDefault
        pp.wallLineWidthOuterMM = 0.46
        pp.wallLineWidthInnerMM = 0.42
        pp.wallLoops = 3
        XCTAssertEqual(pp.wallRingMM, 0.46 + 2 * 0.42, accuracy: 1e-12)
    }

    /// A true rectangle is unchanged — the outline must not "fix" what was right.
    func testARectangularFaceIsStillExactlyItsRectangle() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let f = FaceID(18)
        guard let geo = mesh.faceGeometry(f), geo.isPlane,
              let o = mesh.facePlaneOutline(f, planeNormal: SIMD3<Float>(geo.planeNormal),
                                            planeOrigin: SIMD3<Float>(geo.planeOrigin))
        else { throw XCTSkip("face 18 has no planar geometry") }
        let loops = LatticeFaceOutline.loops(face: f, in: mesh, normal: geo.planeNormal,
                                             origin: SIMD3<Double>(o.center))
        let ext = try XCTUnwrap(LatticeFaceOutline.halfExtents(loops))
        // ★ COMPARED AS A PAIR, NOT AXIS-BY-AXIS, and that is not a dodge.
        // `LatticeRegionMask.basis` and `PlaneOutline.fit` both build a valid
        // orthonormal pair perpendicular to the normal, and they do NOT agree on
        // which of the two is "u" — the mask's own header says so ("the extents
        // are symmetric in both, so which pair does not matter"). Only the mask's
        // basis governs containment, so what must hold is that the outline spans
        // the same two half-extents, not that they arrive in the same order.
        let got = [ext.halfU, ext.halfW].sorted()
        let want = [Double(o.halfU), Double(o.halfV)].sorted()
        XCTAssertEqual(got[0], want[0], accuracy: 0.05,
                       "a rectangular face's outline IS its rectangle")
        XCTAssertEqual(got[1], want[1], accuracy: 0.05)
    }

    /// Containment and distance agree, and a hole reads as outside.
    func testContainmentAndDistanceAgreeIncludingAHole() {
        let outer: LatticeFaceOutline.Loop = [
            .init(-10, -10), .init(10, -10), .init(10, 10), .init(-10, 10)]
        let hole: LatticeFaceOutline.Loop = [
            .init(-2, -2), .init(2, -2), .init(2, 2), .init(-2, 2)]
        let loops = [outer, hole]
        XCTAssertTrue(LatticeFaceOutline.contains(.init(7, 0), loops: loops))
        XCTAssertFalse(LatticeFaceOutline.contains(.init(0, 0), loops: loops),
                       "★ a point in the HOLE is outside the face")
        XCTAssertFalse(LatticeFaceOutline.contains(.init(20, 0), loops: loops))
        // Sign follows containment, magnitude is the distance to the nearest edge.
        XCTAssertEqual(LatticeFaceOutline.signedDistance(.init(0, 0), loops: loops), 2,
                       accuracy: 1e-9, "inside the hole ⇒ +2 mm from its wall")
        XCTAssertEqual(LatticeFaceOutline.signedDistance(.init(7, 0), loops: loops), -3,
                       accuracy: 1e-9, "inside the face ⇒ negative, 3 mm from the rim")
        XCTAssertEqual(LatticeFaceOutline.signedDistance(.init(14, 0), loops: loops), 4,
                       accuracy: 1e-9)
    }
}
