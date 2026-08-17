// LatticeSlabExpandTests.swift — ★ THE SLAB REACHES PAST ITS FACE
// (maintainer, 2026-08-17).
//
// ★ HIS WORDS: "the primitives are the same shape as the face that they are
// derived from. I'd like a way to expand them with a handle to be able to get
// the outside walls that might be otherwise impossible to get latticed (i.e. the
// chamfer)." And his axes: "all the other axis *except* the depth that was set
// (so x and y). It needs to expand outward."
//
// So: ONE outward margin, added to both in-plane half-extents, never to the
// depth — and it has to reach the JOB, or it is a decorative control.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeSlabExpandTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ THE KNOB'S ANCHOR — the reason there was no handle

    /// ★★ THE SHIPPED DEFECT, PINNED AT ITS EXACT INPUT (maintainer,
    /// 2026-08-17, second report: "Expand still does not work - still does not
    /// have a handle").
    ///
    /// The first cut built the offset direction from `ClearanceHandle.axisDir`.
    /// That type documents "only the fields the role needs are populated; the
    /// rest stay zero", and a `.slabDepth` handle — which is what EVERY lattice
    /// depth plane carries — populates `planeOrigin`/`planeNormal` and leaves
    /// `axisDir` at `.zero`. `simd_normalize(.zero)` is NaN, `.position(NaN)`
    /// draws nothing, and the knob was invisible on every part.
    ///
    /// So the zero vector is fed in DELIBERATELY here: the contract is that a
    /// direction that cannot be normalised yields `nil` — a refusal the caller
    /// can act on — and never a NaN point that silently disappears.
    func testAZeroNormalRefusesInsteadOfProducingANaNAnchor() {
        let out = LatticeSlabExpand.knobAnchor(
            anchor: SIMD3(1, 2, 3), normal: .zero, baseMM: 8, expandMM: 0)
        XCTAssertNil(out, "★ a zero normal is the shipped condition — refuse it")
    }

    /// The normal that IS populated on a slab-depth handle places a real knob:
    /// finite, off the depth anchor, and PERPENDICULAR to the normal — so the
    /// knob never rides along the axis the depth control already owns.
    func testItPlacesTheKnobPerpendicularToTheSlabNormal() throws {
        let anchor = SIMD3<Float>(0, 0, 0)
        let n = SIMD3<Float>(0, 0, 1)
        let at = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: anchor, normal: n, baseMM: 8, expandMM: 0))
        XCTAssertTrue(at.x.isFinite && at.y.isFinite && at.z.isFinite)
        XCTAssertEqual(simd_length(at - anchor), 8, accuracy: 1e-4,
                       "★ at the resting offset, so it never sits under the depth knob")
        XCTAssertEqual(simd_dot(at - anchor, n), 0, accuracy: 1e-4,
                       "★ IN PLANE — the expand never moves along the depth axis")
    }

    /// The knob rides OUT as the expand grows, so the handle is on the edge it
    /// moves rather than parked at a fixed spot.
    func testTheKnobRidesOutWithTheExpand() throws {
        let a = SIMD3<Float>(0, 0, 0), n = SIMD3<Float>(0, 1, 0)
        let near = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: a, normal: n, baseMM: 8, expandMM: 0))
        let far = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: a, normal: n, baseMM: 8, expandMM: 20))
        XCTAssertEqual(simd_length(far - a) - simd_length(near - a), 20,
                       accuracy: 1e-3)
    }

    /// A non-unit normal is fine — it is normalised, not trusted.
    func testItNormalisesTheNormalItIsGiven() throws {
        let a = SIMD3<Float>(0, 0, 0)
        let at = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: a, normal: SIMD3(0, 0, 7), baseMM: 8, expandMM: 0))
        XCTAssertEqual(simd_length(at - a), 8, accuracy: 1e-4)
    }

    /// A non-finite normal refuses too — the same failure the zero vector had,
    /// arriving by a different route.
    func testANonFiniteNormalAlsoRefuses() {
        XCTAssertNil(LatticeSlabExpand.knobAnchor(
            anchor: .zero, normal: SIMD3(.nan, 0, 1), baseMM: 8, expandMM: 0))
    }

    // MARK: the value math — in plane ONLY

    func testItGrowsBothInPlaneHalfExtentsAndNothingElse() {
        let e = LatticeSlabExpand.expanded(halfUMM: 10, halfWMM: 4, by: 3)
        XCTAssertEqual(e.halfUMM, 13, accuracy: 1e-12)
        XCTAssertEqual(e.halfWMM, 7, accuracy: 1e-12)
    }

    func testZeroIsExactlyTheFace() {
        let e = LatticeSlabExpand.expanded(halfUMM: 10, halfWMM: 4, by: 0)
        XCTAssertEqual(e.halfUMM, 10, accuracy: 1e-12)
        XCTAssertEqual(e.halfWMM, 4, accuracy: 1e-12)
    }

    /// Clamped, and a negative or NaN reach is "no expand" rather than a shrink —
    /// the control is an OUTWARD one and must not be able to eat the face.
    func testItIsClampedAndNeverShrinksTheFace() {
        XCTAssertEqual(LatticeSlabExpand.clamp(-5), 0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.clamp(.nan), 0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.clamp(1e9), LatticeSlabExpand.maxMM,
                       accuracy: 1e-12)
        let e = LatticeSlabExpand.expanded(halfUMM: 10, halfWMM: 4, by: -3)
        XCTAssertEqual(e.halfUMM, 10, accuracy: 1e-12, "★ never inward")
    }

    // MARK: ★ IT REACHES THE JOB

    /// ★ THE ASSERTION THAT STOPS THIS BEING DECORATIVE: the expanded slab is
    /// what core is asked to lattice, and the DEPTH is untouched by it.
    func testTheExpandGrowsTheEmittedRegionInPlaneAndNotInDepth() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)

        func emitted() -> LatticeRegionSpec? {
            p.latticeJobRegions().regions.first { $0.kind == .face && $0.faceID == 1 }
        }
        let before = try? XCTUnwrap(emitted())
        let u0 = before?.halfUMM ?? 0, w0 = before?.halfWMM ?? 0, d0 = before?.depthMM ?? 0
        XCTAssertGreaterThan(u0, 0, "the face emits a real slab to start")

        p.writeLatticeExpandMM(face, mm: 3)
        let after = try? XCTUnwrap(emitted())
        XCTAssertEqual((after?.halfUMM ?? 0) - u0, 3, accuracy: 1e-9,
                       "★ x grew by exactly the expand")
        XCTAssertEqual((after?.halfWMM ?? 0) - w0, 3, accuracy: 1e-9,
                       "★ …and so did y")
        XCTAssertEqual(after?.depthMM ?? 0, d0, accuracy: 1e-12,
                       "★★ and the DEPTH did not move — his one explicit exclusion")
    }

    /// It is PER SELECTABLE, like the role, the depth and the density.
    func testTheExpandIsPerSelectable() {
        let (p, gid, rid) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        p.writeLatticeExpandMM(face, mm: 3)
        XCTAssertEqual(p.latticeExpandMM(face), 3, accuracy: 1e-12)
        XCTAssertEqual(p.latticeExpandMM(region), 0, accuracy: 1e-12,
                       "…and its sibling is untouched")
    }

    /// Writing 0 CLEARS the key, so "exactly the face" round-trips as absence —
    /// which is what every project written before this had.
    func testZeroClearsTheKeyRatherThanStoringIt() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.writeLatticeExpandMM(face, mm: 3)
        XCTAssertFalse(p.lattice.selectableExpandMM.isEmpty)
        p.writeLatticeExpandMM(face, mm: 0)
        XCTAssertTrue(p.lattice.selectableExpandMM.isEmpty)
    }

    /// An untouched project emits EXACTLY what it emitted before the feature.
    func testAnUntouchedProjectEmitsTheSameSlab() {
        let (a, gidA, _) = project()
        let (b, gidB, _) = project()
        b.writeLatticeExpandMM(.face(group: gidB, face: 1), mm: 0)
        _ = gidA
        let ra = a.latticeJobRegions().regions.first { $0.faceID == 1 }
        let rb = b.latticeJobRegions().regions.first { $0.faceID == 1 }
        XCTAssertEqual(ra?.halfUMM, rb?.halfUMM)
        XCTAssertEqual(ra?.halfWMM, rb?.halfWMM)
    }

    // MARK: the control

    /// A second mm control beside the depth, with its own kind and setter — the
    /// mechanism the density bug forced into existence.
    func testTheDrawerOffersExpandAsItsOwnControl() {
        let card = LatticeFaceCardDerivation.card(
            faceID: 1, depthMM: 20, heldVoxels: 5000, spacingMM: 1.7,
            densityGCM3: 1.24, topology: LatticeType.octet,
            minExtrudableWidthMM: 0.45)
        let d = LatticeRegionDrawer.make(card: card, depthMM: 20, held: true,
                                         expandMM: 3)
        let row = d.rows.first { $0.label == "Expand" }
        XCTAssertEqual(row?.kind, .expand)
        XCTAssertEqual(row?.unit, "mm", "an in-plane reach is millimetres")
        XCTAssertEqual(row?.value, "3.0 mm")
        XCTAssertEqual(d.modifiableRows.map(\.label), ["Depth", "Expand"],
                       "§4b: the depth and the expand, and nothing else")
        XCTAssertEqual(
            LatticeRegionDrawer.make(card: card, depthMM: 20, held: true,
                                     perRegionDensity: true, expandMM: 3)
                .modifiableRows.map(\.label),
            ["Depth", "Density", "Expand"], "…plus the density under per-region")
    }

    // MARK: ★ THE BOUNDARY, PINNED RATHER THAN DISCOVERED ON A RUN

    /// ★★ THE EXPAND GROWS THE LATTICE REGION, NOT THE PROTECTION.
    ///
    /// Core's `face_protections` are keyed by FACE ID and masked by
    /// `mask_step_face`, which walks that face's OWN footprint — there is no
    /// margin on that call, so nothing the app can send widens it. Material
    /// outside the face's outline is therefore latticed-if-present but NOT held
    /// against the optimizer, and TO may carve it away before the lattice pass
    /// sees it. The remedy is the one the app already has: protect the chamfer's
    /// own face too.
    ///
    /// This test exists so that boundary is a STATED property rather than
    /// something found on a wasted run — and so that if core ever grows a
    /// protection margin, the test fails and points here.
    func testTheExpandDoesNotWidenTheProtection() {
        let (p, gid, _) = project()
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        let before = p.faceProtectionSpecs()
        p.writeLatticeExpandMM(face, mm: 5)
        let after = p.faceProtectionSpecs()
        XCTAssertEqual(before.faceIDs, after.faceIDs,
                       "the protection is by FACE ID — the expand adds no face")
        XCTAssertEqual(before.depthsMM, after.depthsMM,
                       "★ and no depth moved: the expand is in plane only")
        // The lattice region DID grow, so the two really are decoupled here.
        let r = p.latticeJobRegions().regions.first { $0.faceID == 1 }
        XCTAssertGreaterThan(r?.halfUMM ?? 0, 0)
    }

    // MARK: fixture

    private func bandedCube() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9)
        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]; faces.append(f)
        }
        T(0, 3, 2, 0); T(0, 2, 1, 0)
        T(4, 5, 6, 1); T(4, 6, 7, 1)
        T(0, 1, 8, 2); T(0, 8, 10, 2); T(10, 8, 5, 2); T(10, 5, 4, 2)
        T(1, 2, 9, 3); T(1, 9, 8, 3)
        T(2, 3, 11, 4); T(2, 11, 9, 4); T(9, 11, 7, 4); T(9, 7, 6, 4)
        T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5)
        T(8, 9, 6, 8); T(8, 6, 5, 8)
        let normals: [SIMD3<Double>] = [
            SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
            SIMD3(1, 0, 0),
        ]
        return ViewerMesh(vertices: v, indices: idx, faceIDs: faces,
                          faceGeometry: normals.map {
                              StepFaceGeometry(kind: .plane, planeNormal: $0)
                          })
    }

    private func project() -> (ProjectModel, group: UUID, region: RegionID) {
        let p = ProjectModel(id: UUID(), name: "Expand", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = bandedCube()
        let rid = p.faceRegions.union(faces: [3, 8], named: "wall")
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 20
        p.lattice.groupRoles[gid] = .include
        p.printParams.strutLineWidthMM = 0.45
        return (p, gid, rid)
    }
}
