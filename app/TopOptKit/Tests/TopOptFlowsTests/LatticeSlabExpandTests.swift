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

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ "at least 1 cm away from the depth handle … currently it is touching"

    /// ★★ THE SEPARATION IS A *SCREEN*-SPACE FLOOR, AND THAT IS THE POINT.
    /// `knobAnchor` offsets by MILLIMETRES; how far apart that lands on screen
    /// depends on the zoom, so framed to the whole part the two 44 pt targets
    /// overlapped. Raising the millimetres would fix one zoom and break another.
    func testTwoNearKnobsArePushedApartToTheFloor() {
        let depth = CGPoint(x: 100, y: 100)
        let out = LatticeSlabExpand.separated(knob: CGPoint(x: 104, y: 100),
                                              from: depth)
        let d = hypot(Double(out.x - depth.x), Double(out.y - depth.y))
        XCTAssertEqual(d, LatticeSlabExpand.knobSeparationPT, accuracy: 1e-6)
        XCTAssertGreaterThan(out.x, depth.x, "★ pushed along the SAME direction")
    }

    /// A knob already clear of the depth handle is left exactly where the
    /// millimetre offset put it — the floor is a floor, not a fixed distance.
    func testAKnobAlreadyClearIsNotMoved() {
        let far = CGPoint(x: 400, y: 100)
        XCTAssertEqual(LatticeSlabExpand.separated(knob: far,
                                                   from: CGPoint(x: 100, y: 100)),
                       far)
    }

    /// Exactly coincident knobs still get a direction — no divide-by-zero, no
    /// NaN, and no knob left sitting under the other one.
    func testCoincidentKnobsStillSeparate() {
        let p = CGPoint(x: 50, y: 50)
        let out = LatticeSlabExpand.separated(knob: p, from: p)
        XCTAssertEqual(hypot(Double(out.x - p.x), Double(out.y - p.y)),
                       LatticeSlabExpand.knobSeparationPT, accuracy: 1e-6)
    }

    /// ★ 72 pt is comfortably past his "at least 1 cm", at any sane scale.
    func testTheFloorClearsHisOneCentimetreAsk() {
        XCTAssertGreaterThanOrEqual(LatticeSlabExpand.knobSeparationPT, 72)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ "make the expansion *also* take a negative value"

    /// ★ SHRINK IS A FIRST-CLASS VALUE, not a clamped-away accident. The floor
    /// is the ceiling's mirror, so the control is symmetric.
    func testTheMarginMayBeNegativeAndTheBoundsAreSymmetric() {
        XCTAssertEqual(LatticeSlabExpand.minMM, -LatticeSlabExpand.maxMM,
                       accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.clamp(-3), -3, accuracy: 1e-12)
    }

    /// A negative margin takes BOTH in-plane half-extents in, and depth is
    /// still untouched — the same invariant the growth direction has.
    func testANegativeMarginShrinksBothInPlaneAxes() {
        let e = LatticeSlabExpand.expanded(halfUMM: 10, halfWMM: 4, by: -2)
        XCTAssertEqual(e.halfUMM, 8, accuracy: 1e-12)
        XCTAssertEqual(e.halfWMM, 2, accuracy: 1e-12)
    }

    /// ★ A SHRINK CANNOT INVERT THE SLAB. Past the face's own half-extent an
    /// axis bottoms out at a sliver rather than going negative — a negative
    /// width is not a smaller region, it is a region that stopped being one.
    /// The two axes floor INDEPENDENTLY, so a long thin face keeps its length
    /// after its width has already bottomed out.
    func testAShrinkPastTheFaceFloorsPerAxisInsteadOfInverting() {
        let e = LatticeSlabExpand.expanded(halfUMM: 20, halfWMM: 1, by: -5)
        XCTAssertEqual(e.halfUMM, 15, accuracy: 1e-12,
                       "★ the long axis is unaffected by the short one's floor")
        XCTAssertEqual(e.halfWMM, LatticeSlabExpand.minHalfExtentMM,
                       accuracy: 1e-12)
        XCTAssertGreaterThan(e.halfWMM, 0, "★ never inverted")
    }

    /// The knob rides OUT for a shrink too — it must not walk back through the
    /// depth knob and come out the far side.
    func testTheKnobRidesOutForAShrinkAsWell() throws {
        let a = SIMD3<Float>(0, 0, 0), n = SIMD3<Float>(0, 0, 1)
        let shrunk = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: a, normal: n, baseMM: 8, expandMM: -12))
        let grown = try XCTUnwrap(LatticeSlabExpand.knobAnchor(
            anchor: a, normal: n, baseMM: 8, expandMM: 12))
        XCTAssertEqual(simd_length(shrunk - a), simd_length(grown - a),
                       accuracy: 1e-4, "★ same travel, opposite MEANING")
        XCTAssertGreaterThan(simd_length(shrunk - a), 8)
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

    /// ★★ THIS TEST USED TO ASSERT THE OPPOSITE, AND IT IS SUPERSEDED BY AN
    /// EXPLICIT INSTRUCTION — not weakened to make a build pass (bar R7).
    ///
    /// It read `testItIsClampedAndNeverShrinksTheFace`, and pinned
    /// `clamp(-5) == 0` plus "★ never inward". That was the right rule for the
    /// control as first specified — "It needs to expand outward" — and it is the
    /// wrong rule now: "Can we make the expansion *also* take a negative value?
    /// I'd like to see us also be able to make it smaller in the x/y axis as
    /// well" (maintainer, 2026-08-17). A rule the user has reversed in writing
    /// is a rule that changes; the assertion is REPLACED with the new one so the
    /// reversal is recorded rather than silently dropped.
    ///
    /// ★ WHAT DID NOT CHANGE, and is still asserted below: NaN is not a value,
    /// the ceiling still holds, ZERO is still exactly the face, and the reach is
    /// still IN-PLANE ONLY. Only the sign became free.
    func testItIsClampedAndNowShrinksOnPurpose() {
        // Unchanged: nonsense is refused, and the ceiling holds.
        XCTAssertEqual(LatticeSlabExpand.clamp(.nan), 0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.clamp(1e9), LatticeSlabExpand.maxMM,
                       accuracy: 1e-12)
        // ★ REVERSED, deliberately: a negative reach is now a SHRINK, not a zero.
        XCTAssertEqual(LatticeSlabExpand.clamp(-5), -5, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.clamp(-1e9), LatticeSlabExpand.minMM,
                       accuracy: 1e-12, "★ and the floor mirrors the ceiling")
        let e = LatticeSlabExpand.expanded(halfUMM: 10, halfWMM: 4, by: -3)
        XCTAssertEqual(e.halfUMM, 7, accuracy: 1e-12, "★ inward, on purpose")
        XCTAssertEqual(e.halfWMM, 1, accuracy: 1e-12)
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

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE PRIMITIVE ITSELF MOVES — "expand and contract along with the handle"

@MainActor
final class LatticeSlabExpandPrimitiveTests: XCTestCase {

    /// A flat unit-square patch as two triangles, with its inward normals.
    /// Corners at ±1 in x/y, normal along −z (inward = into the part).
    private func square() -> (base: [SIMD3<Float>], inward: [SIMD3<Float>],
                              idx: [UInt32]) {
        let base: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(1, -1, 0),
                                    SIMD3(1, 1, 0), SIMD3(-1, 1, 0)]
        let inward = [SIMD3<Float>](repeating: SIMD3(0, 0, -1), count: 4)
        return (base, inward, [0, 1, 2, 0, 2, 3])
    }

    /// ★ THE DEFECT HE REPORTED TWICE: the number reached the JOB — the emitted
    /// slab's half-extents grow — but the shaded primitive was built from the
    /// face's own triangles at their own positions, so the picture never moved.
    /// The run was right and the picture was silent, which is the worse half.
    func testAPositiveExpandPushesTheOutlineOutward() {
        let s = square()
        let out = FaceOffsetShell.dilated(base: s.base, inward: s.inward,
                                          indices: s.idx, byMM: 0.5)
        for k in 0..<4 {
            XCTAssertGreaterThan(simd_length(out[k]), simd_length(s.base[k]),
                                 "★ corner \(k) moved OUT")
        }
    }

    func testANegativeExpandPullsTheOutlineIn() {
        let s = square()
        let out = FaceOffsetShell.dilated(base: s.base, inward: s.inward,
                                          indices: s.idx, byMM: -0.5)
        for k in 0..<4 {
            XCTAssertLessThan(simd_length(out[k]), simd_length(s.base[k]),
                              "★ corner \(k) moved IN")
        }
    }

    /// ★ ZERO IS A NO-OP, BIT FOR BIT — which is what makes the parameter safe
    /// to default on every existing call site.
    func testZeroLeavesEveryVertexExactlyWhereItWas() {
        let s = square()
        XCTAssertEqual(FaceOffsetShell.dilated(base: s.base, inward: s.inward,
                                               indices: s.idx, byMM: 0),
                       s.base)
    }

    /// ★ THE DISPLACEMENT IS IN THE TANGENT PLANE, so a dilation can never
    /// double as a depth change — depth has its own control and its own detents.
    func testTheDilationNeverMovesAlongTheNormal() {
        let s = square()
        for e in [-0.4, 0.7] {
            let out = FaceOffsetShell.dilated(base: s.base, inward: s.inward,
                                              indices: s.idx, byMM: e)
            for k in 0..<4 {
                XCTAssertEqual(out[k].z, s.base[k].z, accuracy: 1e-5,
                               "★ z is the normal axis and must not move")
            }
        }
    }

    /// ★ A SHRINK IS BOUNDED BY THE PATCH'S OWN SIZE. Pulling in further than
    /// the patch is wide would fold the outline through itself, which is not a
    /// smaller region — so a runaway negative collapses toward the centre and
    /// stops, rather than inverting.
    func testARunawayShrinkCollapsesRatherThanInverting() {
        let s = square()
        let out = FaceOffsetShell.dilated(base: s.base, inward: s.inward,
                                          indices: s.idx, byMM: -1e6)
        for k in 0..<4 {
            XCTAssertTrue(out[k].x.isFinite && out[k].y.isFinite)
            XCTAssertLessThan(simd_length(out[k]), simd_length(s.base[k]))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE DETENT AT ZERO, AND THE SIGN ON THE KNOB

final class LatticeSlabExpandDetentTests: XCTestCase {

    /// ★ "Please make a magnetic detent at 0 … so it is easier to 'feel' when
    /// it hits the floor." Inside the band it snaps; outside it passes through
    /// untouched, so the magnet cannot quietly eat a value the user aimed at.
    func testItSnapsToZeroInsideTheBandAndNowhereElse() {
        XCTAssertEqual(LatticeSlabExpand.snapped(0.3), 0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.snapped(-0.3), 0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.snapped(4.0), 4.0, accuracy: 1e-12)
        XCTAssertEqual(LatticeSlabExpand.snapped(-4.0), -4.0, accuracy: 1e-12)
    }

    /// The band is narrow enough that an aimed value survives it.
    func testTheBandIsNarrowerThanAnyValueWorthAiming() {
        XCTAssertLessThan(LatticeSlabExpand.detentBandMM, 1.0)
        XCTAssertEqual(LatticeSlabExpand.snapped(1.0), 1.0, accuracy: 1e-12)
    }

    /// ★ "'+/-' when it is pushed up, '+' … '-'" — the knob states what the
    /// number IS, and the icon flips exactly where the detent catches.
    func testTheKnobIconReadsTheSign() {
        XCTAssertEqual(LatticeSlabExpand.sense(5), .grow)
        XCTAssertEqual(LatticeSlabExpand.sense(-5), .shrink)
        XCTAssertEqual(LatticeSlabExpand.sense(0), .floor)
        // ★ INSIDE THE DETENT IT READS AS THE FLOOR — the icon and the magnet
        // agree by construction, because `sense` snaps before it decides.
        XCTAssertEqual(LatticeSlabExpand.sense(0.2), .floor)
        XCTAssertEqual(LatticeSlabExpand.sense(-0.2), .floor)
    }

    func testEachSenseHasItsOwnSymbol() {
        XCTAssertEqual(LatticeSlabExpand.Sense.grow.symbolName, "plus")
        XCTAssertEqual(LatticeSlabExpand.Sense.shrink.symbolName, "minus")
        XCTAssertEqual(LatticeSlabExpand.Sense.floor.symbolName, "plusminus")
    }
}
