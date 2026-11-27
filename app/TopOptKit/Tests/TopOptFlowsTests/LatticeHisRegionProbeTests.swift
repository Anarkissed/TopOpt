// LatticeHisRegionProbeTests — ★ HIS OWN TWO REGIONS, MEASURED
//
// Read from his device: `M2 verticalStand`, faces 15 (depth 11 mm) and 2 (depth 13 mm),
// `selectableExpandMM` EMPTY — he has never set an expansion, which is why "it is
// expanding when I have not set it to" is a report about a defect and not about a
// setting.
//
// ★ THREE SYMPTOMS, AND THE HYPOTHESIS THAT THEY ARE ONE:
//   1. the declared wall renders SOLID rather than latticed
//   2. the lattice view cuts the TOP faces away
//   3. the lattice runs past the face into the chamfer
// 1 and 3 look contradictory — too little lattice AND too much — which is the signature
// of a region in the WRONG PLACE rather than one merely the wrong size.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeHisRegionProbeTests: XCTestCase {

    /// His two, exactly as his project.json carries them.
    private let hisFaces: [(face: FaceID, depth: Double)] = [(15, 11.0), (2, 13.0)]

    func testWhereHisTwoRegionsActuallySit() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()

        for (f, depth) in hisFaces {
            guard let geo = mesh.faceGeometry(f) else {
                print("face \(f): NO GEOMETRY"); continue
            }
            guard geo.isPlane else {
                print("face \(f): not a plane"); continue
            }
            guard let o = mesh.facePlaneOutline(
                f, planeNormal: SIMD3<Float>(geo.planeNormal),
                planeOrigin: SIMD3<Float>(geo.planeOrigin)) else {
                print("face \(f): NO PLANE OUTLINE"); continue
            }
            let loops = LatticeFaceOutline.loops(face: f, in: mesh,
                                                 normal: geo.planeNormal,
                                                 origin: SIMD3<Double>(o.center))
            // ★★ THE FIRST QUESTION: does the emission get an OUTLINE at all? With no
            // loops, `LatticeRegionMask.contains` falls back to the bounding RECTANGLE
            // — and on these two faces the outline is a documented 41.2% / 29.8% of
            // that rectangle, so the region would cover roughly 2.4-3.4x the material
            // he marked. That is symptom 3, and symptom 2 follows from it: the shell
            // discards wherever the region says "latticed".
            let resolved = LatticeRegionEmission.ResolvedFace.plane(
                center: SIMD3<Double>(o.center), normal: geo.planeNormal,
                halfUMM: Double(o.halfU), halfWMM: Double(o.halfV),
                outlineLoops: loops)
            guard let spec = LatticeRegionEmission.spec(
                for: resolved, role: .include, depthMM: depth, faceID: Int(f)) else {
                print("face \(f): SPEC REFUSED"); continue
            }

            // Area of the outline vs the rectangle it would fall back to.
            let rect = 4.0 * Double(o.halfU) * Double(o.halfV)
            var outlineArea = 0.0
            for loop in loops {
                var a = 0.0
                for i in 0..<loop.count {
                    let p = loop[i], q = loop[(i + 1) % loop.count]
                    a += p.x * q.y - q.x * p.y
                }
                outlineArea += abs(a) * 0.5
            }

            // ★★ THE SECOND QUESTION: is the material IMMEDIATELY BEHIND THE FACE in
            // the region? It must be — that is the face he picked. Sampled just inside
            // the surface along the INWARD normal.
            let nOut = simd_normalize(geo.planeNormal)
            let faceCentre = SIMD3<Double>(o.center)

            // ★★★ THE PLANE ORIGIN IS NOT ON THE FACE. `PlaneOutline.fit` centres on
            // the projected BOUNDING BOX, and on these two faces the real outline is
            // 41.2% / 29.8% of that box — so the centre lands IN THE SCOOP. Sampling
            // down the centre line therefore measures the hole, not the wall. Recorded
            // because the first version of this probe did exactly that and reported
            // 0/22, which is true and means nothing about the wall.
            let centreOnFace = loops.isEmpty
                || LatticeFaceOutline.contains(SIMD2<Double>(0, 0), loops: loops)

            // A point that really IS on the face: the centroid of the outer loop's
            // vertices, nudged toward the loop's own interior until it is inside.
            let (uAx, vAx) = LatticeRegionMask.basisForTests(nOut)
            var onFaceUV: SIMD2<Double>? = nil
            if let outer = loops.max(by: { $0.count < $1.count }) {
                let c = outer.reduce(SIMD2<Double>(0, 0), +) / Double(max(1, outer.count))
                if LatticeFaceOutline.contains(c, loops: loops) { onFaceUV = c }
                if onFaceUV == nil {
                    // Walk the loop's own vertices inward toward that centroid.
                    outer: for v in outer {
                        for f in stride(from: 0.05, through: 0.95, by: 0.05) {
                            let q = v + (c - v) * f
                            if LatticeFaceOutline.contains(q, loops: loops) {
                                onFaceUV = q; break outer
                            }
                        }
                    }
                }
            }
            let probeBase = onFaceUV.map { faceCentre + uAx * $0.x + vAx * $0.y }
                            ?? faceCentre

            var behindIn = 0, behindTotal = 0
            for t in stride(from: 0.25, through: depth - 0.25, by: 0.5) {
                behindTotal += 1
                if LatticeRegionMask.contains(probeBase - nOut * t, region: spec) {
                    behindIn += 1
                }
            }
            // …and does it reach BEYOND the declared depth (past the far side)?
            var beyond = 0
            for t in stride(from: depth + 0.25, through: depth + 6.0, by: 0.5) {
                if LatticeRegionMask.contains(probeBase - nOut * t, region: spec) {
                    beyond += 1
                }
            }
            // …and OUTSIDE the face, in front of it (where the chamfer is)?
            var inFront = 0
            for t in stride(from: 0.25, through: 4.0, by: 0.5) {
                if LatticeRegionMask.contains(probeBase + nOut * t, region: spec) {
                    inFront += 1
                }
            }

            print("""

            ── face \(f) · declared depth \(depth) mm ──────────────────────
            plane normal ............ \(geo.planeNormal)
            emitted normal .......... \(spec.normal)   (slab runs origin + s·this)
            outline loops ........... \(loops.count)
            outline area ............ \(String(format: "%.1f", outlineArea)) mm²
            bounding rect ........... \(String(format: "%.1f", rect)) mm²  \
            (outline is \(rect > 0 ? String(format: "%.1f", 100 * outlineArea / rect) : "-")% of it)
            in-plane offset (expand)  \(spec.inPlaneOffsetMM) mm
            ★ plane ORIGIN on the face? \(centreOnFace ? "yes" : "NO — it is in the hole")
            probe point on the face .. \(onFaceUV != nil ? "found" : "NONE FOUND")
            basis(face normal) ....... \(LatticeRegionMask.basisForTests(nOut))
            basis(EMITTED normal) .... \(LatticeRegionMask.basisForTests(simd_normalize(spec.normal)))
            ★ same frame? ............ \(LatticeRegionMask.basisForTests(nOut) == LatticeRegionMask.basisForTests(simd_normalize(spec.normal)) ? "yes" : "NO — the outline is measured MIRRORED")
            samples BEHIND the face IN the region ... \(behindIn)/\(behindTotal)
            samples BEYOND the depth in the region .. \(beyond)/12
            samples IN FRONT of the face in region .. \(inFront)/8
            """)

            // ★★★ THE BAR, AND IT IS POSITIONAL ON PURPOSE. A reflection preserves
            // AREA and preserves HALF-EXTENTS, so every existing check on this outline
            // passed while the region sat mirrored off the wall. The only check that
            // catches it asks whether a point that is genuinely ON THE FACE is IN THE
            // REGION. Measured before the fix: face 15 scored 0 of 22.
            XCTAssertEqual(behindIn, behindTotal,
                           "★ face \(f): material directly behind the declared face is "
                           + "NOT in the region (\(behindIn)/\(behindTotal)). The wall "
                           + "he marked would render SOLID, and the region would be "
                           + "sitting somewhere he never marked.")
            // ★ AND IT STOPS WHERE HE SAID. Both halves matter: the mirrored region was
            // simultaneously missing the wall AND covering the chamfer.
            XCTAssertEqual(beyond, 0,
                           "★ face \(f): the region runs past the declared depth")
            XCTAssertEqual(inFront, 0,
                           "★ face \(f): the region reaches OUT through the face — that "
                           + "is the chamfer the lattice was peeking through")
        }
    }

    /// ★★★ THE FRAME ITSELF, as a unit bar — so the fix cannot be undone by someone
    /// "simplifying" the conversion away.
    ///
    /// `LatticeFaceOutline.loops` writes the polygon in `basis(faceNormal)`; the slab
    /// carries `-faceNormal` and `LatticeRegionMask.contains` reads it in
    /// `basis(-faceNormal)`. Those differ by a reflection (u flips, v does not), so the
    /// emission has to re-express the loops or the region is the face's mirror image.
    func testTheEmittedOutlineIsInTheSlabsOwnFrameNotTheFaces() throws {
        let n = SIMD3<Double>(0, 1, 0)
        let (uFace, vFace) = LatticeRegionMask.basisForTests(n)
        let (uSlab, vSlab) = LatticeRegionMask.basisForTests(-n)
        XCTAssertNotEqual(uFace, uSlab,
                          "positive control: the two frames really do differ, which is "
                          + "the whole reason this conversion exists")

        // A deliberately ASYMMETRIC outline — a symmetric one cannot show a mirror.
        let loop: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(0, 10)]
        let spec = try XCTUnwrap(LatticeRegionEmission.spec(
            for: .plane(center: .zero, normal: n, halfUMM: 40, halfWMM: 40,
                        outlineLoops: [loop]),
            role: .include, depthMM: 5, faceID: 1))

        // Take a point that is inside the polygon as WRITTEN, put it in the world using
        // the FACE frame, and require the region to contain it just under the surface.
        let inside = SIMD2<Double>(15, 5)
        let world = uFace * inside.x + vFace * inside.y - n * 2.5
        XCTAssertTrue(LatticeRegionMask.contains(world, region: spec),
                      "★ a point inside the face's own outline must be inside the "
                      + "region. If this fails the loops are being read in the wrong "
                      + "frame and the region is the face's mirror image.")

        // …and the mirror of that point must NOT be, or the conversion did nothing.
        let mirrored = uFace * -inside.x + vFace * inside.y - n * 2.5
        XCTAssertFalse(LatticeRegionMask.contains(mirrored, region: spec),
                       "★ the REFLECTED point must be outside — otherwise the outline "
                       + "is still being measured mirrored")
        _ = (uSlab, vSlab)
    }
}
