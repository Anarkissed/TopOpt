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
