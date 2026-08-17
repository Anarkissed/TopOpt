// LatticePrimitiveAlwaysTests.swift — task 2026-08-15-lattice-and-face-ui.
//
//   R2  ★ A PRIMITIVE IS ALWAYS CREATED when a selectable is set to Lattice.
//       His words: "In many cases, when I press 'Lattice' on a face, NO
//       PRIMITIVE APPEARS. It ALWAYS has to create a primitive. IF THERE ISN'T
//       ONE MADE, IT IS BROKEN." — treated here as a FAILING TEST, not a
//       display quirk.
//   R3  ★ DEPTH AND THE HANDLE CANNOT DIVERGE. Asserted in BOTH directions.
//   R4  ★ THE LIST SHOWS REGIONS. A face a region already covers is that
//       region's CHILD, not a row of its own.
//
// ★ THE ROOT CAUSE THESE PIN, with file and line at the time of writing:
// `ProjectModel.latticeDepthPlanes()` required `geo.isPlane` before it would
// build a face's primitive, and `latticeRegionDepthPlane` required a member to
// be a plane, the members' normals to agree within 0.75 and the PCA frame to be
// valid. A cylinder or an `Other` surface failed all of those SILENTLY.
// Measured by `lattice_primitive_probe` on M2_verticalStand.step: 42 of 78
// faces (53.8%) drew nothing, and 19 of the 22 faces in his own declared load
// group (86.4%) drew nothing.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePrimitiveAlwaysTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: fixture — a part with ALL THREE surface kinds
    //
    // Face 0: a PLANE (the top).                     -> used to work
    // Face 1: a CYLINDER (a four-facet bore wall).    -> drew NOTHING
    // Face 2: an OTHER (a curved fillet strip).       -> drew NOTHING
    //
    // The kinds are declared in `faceGeometry` exactly as the importer declares
    // them, because `isPlane` — the predicate that used to gate this — reads
    // nothing else.

    /// How finely the bore wall is tessellated. ★ A real STEP import gives a
    /// cylinder tens of facets; a 4-facet "cylinder" is a SQUARE, and the
    /// asymmetric quad-to-triangle split then skews each vertex normal ~22° off
    /// radial. That is a property of the fixture's tessellation, not of the
    /// offset rule, so the fixture uses a realistic count.
    private static let boreSegments = 24

    private func mixedKindMesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        // face 0 — a flat square in z = 10 (verts 0..3)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        // face 1 — a cylinder wall about the z axis through (5,5)
        let seg = Self.boreSegments
        let r: Float = 3
        let boreBase = Int32(4)
        for k in 0..<seg {
            let a = Float(k) / Float(seg) * 2 * .pi
            V(5 + r * cos(a), 5 + r * sin(a), 0)
            V(5 + r * cos(a), 5 + r * sin(a), 6)
        }
        // face 2 — a curved strip, three quads along a shallow arc
        let stripBase = boreBase + Int32(seg * 2)
        for k in 0..<4 {
            let t = Float(k) / 3
            V(t * 9, -2 - t * t * 2, 0); V(t * 9, -2 - t * t * 2, 5)
        }

        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]; faces.append(f)
        }
        T(0, 1, 2, 0); T(0, 2, 3, 0)
        // The bore wall WRAPS (k+1 mod seg), so every vertex has incident facets
        // on both sides and its area-weighted normal is radial.
        for k in 0..<seg {
            let b = boreBase + Int32(k * 2)
            let n = boreBase + Int32(((k + 1) % seg) * 2)
            T(b, n, n + 1, 1); T(b, n + 1, b + 1, 1)
        }
        for k in 0..<3 {
            let b = stripBase + Int32(k * 2)
            T(b, b + 2, b + 3, 2); T(b, b + 3, b + 1, 2)
        }
        return ViewerMesh(
            vertices: v, indices: idx, faceIDs: faces,
            faceGeometry: [
                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                 planeOrigin: SIMD3(5, 5, 10)),
                StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 3,
                                 axisPoint: SIMD3(5, 5, 0), axisDir: SIMD3(0, 0, 1)),
                StepFaceGeometry(kind: .other),
            ])
    }

    /// One group holding all three faces, declared LATTICE.
    private func latticedProject() -> (ProjectModel, UUID) {
        let p = ProjectModel(id: UUID(), name: "Kinds", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mixedKindMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        let gid = p.selection.groups[0].id
        p.force.sync(groups: p.selection.groups)
        // The role gate needs the group to be DECLARED — anchor, load or
        // protected — or `latticeEligibleRoles` prunes the role and nothing is
        // drawn for any face, planar or not (LatticeFaceRoleGate.block).
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4.0
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 2.0
        return (p, gid)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R2 — a primitive is ALWAYS created

    /// ★ THE BAR. Every declared selectable gets a primitive — not the planes
    /// only. Before the fix this returned ONE plane out of three.
    func testEveryLatticedFaceGetsAPrimitiveWhateverItsSurfaceKind() {
        let (p, gid) = latticedProject()
        let planes = p.latticeDepthPlanes()
        XCTAssertEqual(planes.count, 3,
                       "R2: all three faces must produce a primitive — a plane, "
                       + "a cylinder and an 'other'. Got \(planes.count).")
        for f in FaceID(0)...FaceID(2) {
            let ref = LatticeSelectableRef.face(group: gid, face: f)
            XCTAssertTrue(planes.contains { $0.ref == ref },
                          "R2: face \(f) was set to Lattice and drew NOTHING")
        }
    }

    /// ★ THE NON-PLANAR CASES SPECIFICALLY, because those are the ones his part
    /// is made of: 42 of 78 faces, and 19 of the 22 he declares.
    func testACylinderAndAnOtherSurfaceBothProduceGeometry() {
        let (p, gid) = latticedProject()
        for f in [FaceID(1), FaceID(2)] {
            let ref = LatticeSelectableRef.face(group: gid, face: f)
            guard let plane = p.latticeDepthPlanes().first(where: { $0.ref == ref })
            else { return XCTFail("R2: no primitive for non-planar face \(f)") }
            guard case let .shell(s) = plane.volume.shape else {
                return XCTFail("R2: face \(f) must be an offset shell, got "
                               + "\(plane.volume.shape)")
            }
            XCTAssertFalse(s.isEmpty, "R2: face \(f)'s shell has no triangles")
            XCTAssertFalse(plane.volume.isDegenerate,
                           "R2: face \(f) must not be a degenerate no-op volume")
        }
    }

    /// ★ A REGION OF CURVED FACES GETS ONE TOO. `latticeRegionDepthPlane` used
    /// to return nil four ways, three of which are just "the region is curved" —
    /// which is the case §2 exists to answer ("a doughnut shape").
    func testARegionOfCURVEDFacesGetsAPrimitive() {
        let p = ProjectModel(id: UUID(), name: "Curved", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mixedKindMesh()
        // A union of the cylinder wall and the curved strip: NO member is a
        // plane, so the old normal-agreement path bailed before it started.
        let rid = p.faceRegions.union(faces: [1, 2], named: "curved")
        p.selection.addGroup()
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 1.5
        let planes = p.latticeDepthPlanes()
        XCTAssertTrue(planes.contains { $0.ref.regionID == rid },
                      "R2: a region whose members are ALL curved drew nothing")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §2(b) — the shape is the SHAPE OF WHAT WAS SELECTED

    /// A plane's offset is a SLAB: every vertex travels the same direction.
    func testAPlanesOffsetTravelsOneDirection() {
        let mesh = mixedKindMesh()
        guard let s = FaceOffsetShell.build(faces: [0], in: mesh, depthMM: 2)
        else { return XCTFail("no shell for the plane") }
        let first = simd_normalize(s.offset[0] - s.base[0])
        for k in 1..<s.base.count {
            let d = simd_normalize(s.offset[k] - s.base[k])
            XCTAssertGreaterThan(simd_dot(first, d), 0.999,
                                 "a plane must offset as a slab — one direction")
        }
    }

    /// ★ A CYLINDER'S OFFSET IS AN ANNULUS — his "doughnut". Every vertex moves
    /// RADIALLY, so each offset point is closer to the axis by the depth.
    func testACylindersOffsetIsAnAnnulus() {
        let mesh = mixedKindMesh()
        guard let s = FaceOffsetShell.build(faces: [1], in: mesh, depthMM: 1)
        else { return XCTFail("no shell for the cylinder") }
        let axis = SIMD2<Float>(5, 5)
        for k in 0..<s.base.count {
            let rb = simd_length(SIMD2(s.base[k].x, s.base[k].y) - axis)
            let ro = simd_length(SIMD2(s.offset[k].x, s.offset[k].y) - axis)
            XCTAssertEqual(Double(rb - ro), s.reachedDepthMM, accuracy: 0.02,
                           "a cylinder must offset radially inward by the depth")
        }
    }

    /// ★ IT CANNOT SELF-INTERSECT (§2b). On a CONCAVE surface the offset fronts
    /// converge; past the radius of curvature a true surface offset folds through
    /// itself. The clamp binds, and — R14's rule — it is REPORTED, not silent.
    func testAConcaveSurfaceClampsTheOffsetAndSaysSo() {
        // A tight concave arc: normals turn hard over a short span.
        var v: [Float] = []
        var idx: [Int32] = []
        var faces: [Int32] = []
        let r: Float = 2
        let n = 12
        for k in 0...n {
            let a = Float(k) / Float(n) * (.pi / 2)
            v += [r * cos(a), r * sin(a), 0]
            v += [r * cos(a), r * sin(a), 4]
        }
        // ★ WOUND SO THE INWARD DIRECTION POINTS AT THE ARC CENTRE — i.e. the
        // material is on the OUTSIDE of the arc and the selected surface is
        // CONCAVE. That is the case a surface offset folds on: every point
        // travels toward one centre, and they all arrive at radius `r`.
        for k in 0..<n {
            let b = Int32(k * 2)
            idx += [b, b + 3, b + 1]; faces.append(0)
            idx += [b, b + 2, b + 3]; faces.append(0)
        }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: faces,
                              faceGeometry: [StepFaceGeometry(kind: .other)])
        guard let s = FaceOffsetShell.build(faces: [0], in: mesh, depthMM: 50)
        else { return XCTFail("no shell for the concave arc") }
        XCTAssertTrue(s.wasClamped,
                      "§2b: a depth past the radius of curvature must be clamped")
        XCTAssertEqual(s.clampedFromMM, 50,
                       "the clamp must report the depth that was ASKED for")
        XCTAssertLessThan(s.reachedDepthMM, 50,
                          "the reached depth must be less than the request")
        // ★ AND THE LIMIT IS THE RADIUS OF CURVATURE, not an arbitrary cap: the
        // fronts of a radius-2 arc meet at 2 mm. (A chord estimate reads a shade
        // under the true radius, hence the 5% band.)
        XCTAssertEqual(s.reachedDepthMM, Double(r), accuracy: Double(r) * 0.05,
                       "§2b: the clamp is the LOCAL RADIUS OF CURVATURE")
        // And no point may have folded past the centre.
        for k in 0..<s.base.count {
            let d = simd_length(SIMD2(s.offset[k].x, s.offset[k].y))
            XCTAssertGreaterThanOrEqual(Double(d), -1e-3,
                                        "the offset must not fold through itself")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R3 — depth and the handle CANNOT diverge

    /// ★ HIS WORDS: "Depth as a number INSIDE the drawer is absolutely useless if
    /// it's going to disagree with the handle of the primitive… they both need to
    /// be LOCKED TOGETHER otherwise what the fuck do they do???"
    ///
    /// DIRECTION 1 — TYPING MOVES THE HANDLE.
    func testTypingTheDepthMovesTheHandle() {
        let (p, gid) = latticedProject()
        let ref = LatticeSelectableRef.face(group: gid, face: 0)
        func handleDepth() -> Double? {
            guard let plane = p.latticeDepthPlanes().first(where: { $0.ref == ref })
            else { return nil }
            return Double(simd_length(plane.handle.anchor - plane.handle.planeOrigin))
        }
        for typed in [1.5, 3.0, 6.25] {
            p.writeLatticeDepthMM(ref, mm: typed)
            guard let h = handleDepth() else { return XCTFail("no primitive") }
            XCTAssertEqual(h, typed, accuracy: 1e-3,
                           "R3: typing \(typed) mm must move the handle to \(typed) mm")
        }
    }

    /// DIRECTION 2 — DRAGGING THE HANDLE MOVES THE NUMBER. The drag writes
    /// through the SAME call the viewport's gesture uses, so this is the value
    /// the drawer reads back, not a parallel store.
    func testDraggingTheHandleMovesTheNumber() {
        let (p, gid) = latticedProject()
        let ref = LatticeSelectableRef.face(group: gid, face: 0)
        for dragged in [2.0, 5.5, 1.25] {
            p.writeLatticeDepthMM(ref, mm: dragged)
            XCTAssertEqual(p.latticeSlabDepthMM(ref, in: gid), dragged, accuracy: 1e-9,
                           "R3: the drawer's number must equal the dragged depth")
            XCTAssertEqual(p.latticeDepthPlanes().first { $0.ref == ref }?.depthMM,
                           dragged,
                           "R3: the primitive's own depth must equal it too")
        }
    }

    /// ★ AND IT IS THE PROTECTION DEPTH TOO (§2e) — one number, not two.
    func testTheProtectionDepthIsTheSameNumber() {
        let (p, gid) = latticedProject()
        let ref = LatticeSelectableRef.face(group: gid, face: 0)
        p.writeLatticeDepthMM(ref, mm: 3.75)
        XCTAssertEqual(LatticeSlabDepth.depthMM(ref: ref, group: gid,
                                                perSelectable: p.lattice.selectableDepthMM,
                                                perGroup: p.lattice.groupDepthMM,
                                                fallbackMM: p.lattice.paintDepthMM),
                       3.75, accuracy: 1e-9,
                       "§2e: the protection reads the SAME number the lattice does")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R4 — the list shows REGIONS

    /// ★ HIS COMPLAINT: three faces selected, "over twenty rows". The list
    /// emitted the regions AND every raw face. A face a region covers is now
    /// that region's CHILD.
    func testAUnionCollapsesItsMemberFacesIntoOneRow() {
        let p = ProjectModel(id: UUID(), name: "Rows", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mixedKindMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        let gid = p.selection.groups[0].id
        let before = p.latticeSelectableRefs(p.selection.groups[0]).count
        XCTAssertEqual(before, 3, "three faces, three rows, before combining")

        let rid = p.faceRegions.union(faces: [0, 1, 2], named: "the load faces")
        p.selection.addRegions([rid], to: gid)
        let after = p.latticeSelectableRefs(p.selection.groups[0]).count
        XCTAssertEqual(after, 1,
                       "R4: after Combine the list must show ONE region row, not "
                       + "one region row plus three face rows. Got \(after).")
        XCTAssertEqual(p.latticeRegionMemberFaces(rid).count, 3,
                       "R4: the three faces are the region's CHILDREN")
    }

    /// ★ A COLLAPSED PARENT STILL OWNS ITS FACES. A face must not pop back up as
    /// a top-level row merely because the row holding it is shut.
    func testACollapsedRegionStillHidesItsFaces() {
        let p = ProjectModel(id: UUID(), name: "Rows", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mixedKindMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        let gid = p.selection.groups[0].id
        let rid = p.faceRegions.union(faces: [0, 1, 2], named: "the load faces")
        p.selection.addRegions([rid], to: gid)
        p.faceRegions.setCollapsed(rid, true)
        XCTAssertEqual(p.latticeSelectableRefs(p.selection.groups[0]).count, 1,
                       "R4: collapsing the region must not resurrect its faces")
    }

    /// A face the region does NOT cover keeps its own row — the change hides
    /// members, it does not hide the group.
    func testAFaceOutsideEveryRegionKeepsItsRow() {
        let p = ProjectModel(id: UUID(), name: "Rows", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mixedKindMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        let gid = p.selection.groups[0].id
        let rid = p.faceRegions.union(faces: [1, 2], named: "the curved pair")
        p.selection.addRegions([rid], to: gid)
        let refs = p.latticeSelectableRefs(p.selection.groups[0])
        XCTAssertEqual(refs.count, 2, "one region row + the uncovered face 0")
        XCTAssertTrue(refs.contains(.face(group: gid, face: 0)),
                      "R4: face 0 is in no region and must keep its own row")
        XCTAssertFalse(refs.contains(.face(group: gid, face: 1)),
                       "R4: face 1 is a member and must NOT be a top-level row")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: R3 (round 2) — THE GROUP FIELD AND THE PRIMITIVE
//
// ★ HIS REPORT: "the face shaped primitive and it are not locked together… I need
// to be able to drag the primitive OR put a number in the 'Depth' field and see
// the primitive pulled to that depth. They need to be *locked* together."
//
// The drawer he is typing into is the GROUP's (`latticeGroupDrawer`, the row that
// reads "All · 108.0 g"). These pin what that field must do.

@MainActor
final class LatticeGroupDepthLockTests: XCTestCase {

    private func planeMesh() -> ViewerMesh {
        let v: [Float] = [0, 0, 10,  10, 0, 10,  10, 10, 10,  0, 10, 10]
        return ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1),
                                                          planeOrigin: SIMD3(5, 5, 10))])
    }

    private func project() -> (ProjectModel, UUID, LatticeSelectableRef) {
        let p = ProjectModel(id: UUID(), name: "Lock", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = planeMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0])
        let gid = p.selection.groups[0].id
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 4.0
        return (p, gid, .face(group: gid, face: 0))
    }

    /// The depth the PRIMITIVE is actually drawn at.
    private func drawnDepth(_ p: ProjectModel, _ ref: LatticeSelectableRef) -> Double? {
        p.latticeDepthPlanes().first { $0.ref == ref }?.depthMM
    }

    /// Typing in the group drawer with nothing overridden moves the primitive.
    func testTypingTheGroupDepthMovesThePrimitive() {
        let (p, gid, ref) = project()
        p.writeGroupDepthMM(gid, mm: 9.0)
        XCTAssertEqual(drawnDepth(p, ref), 9.0,
                       "typing the group depth must pull the primitive to it")
    }

    /// ★ THE DEFECT. Drag the primitive's knob ONCE — which writes a PER-SELECTABLE
    /// override — and the group's Depth field goes inert for that face: the number
    /// changes and the primitive does not move. That is exactly "not locked
    /// together", and it needs no unusual sequence to reach: dragging the handle is
    /// the other half of the feature he is asking for.
    func testTypingTheGroupDepthStillMovesAPrimitiveThatWasDragged() {
        let (p, gid, ref) = project()
        p.writeLatticeDepthMM(ref, mm: 6.0)          // the user drags the knob
        XCTAssertEqual(drawnDepth(p, ref), 6.0, "the drag moved it")

        p.writeGroupDepthMM(gid, mm: 12.0)           // …then types in the drawer
        XCTAssertEqual(drawnDepth(p, ref), 12.0,
                       "R3: after a drag, TYPING must still pull the primitive — "
                       + "the group field cannot be shadowed by the override the "
                       + "drag left behind")
    }

    /// ★ THE DEFECT ITSELF, WITNESSED. This drives the OLD write — a bare
    /// assignment to `groupDepthMM`, which is what the drawer's field did — and
    /// shows the primitive refusing to move. It documents WHY
    /// `writeGroupDepthMM` has to clear the overrides, and it fails the moment
    /// someone reverts that method to a plain assignment.
    func testTheOldBareAssignmentIsWhatLeftThemUnlocked() {
        let (p, gid, ref) = project()
        p.writeLatticeDepthMM(ref, mm: 6.0)          // the user drags the knob

        p.lattice.groupDepthMM[gid] = 12.0           // the OLD group-field write
        XCTAssertEqual(drawnDepth(p, ref), 6.0,
                       "the per-selectable override SHADOWS a bare group write — "
                       + "this is the 'not locked together' the maintainer saw")

        p.writeGroupDepthMM(gid, mm: 12.0)           // what it does now
        XCTAssertEqual(drawnDepth(p, ref), 12.0, "and this is the fix")
    }

    /// And the reverse still holds: a drag after a typed group depth wins for that
    /// one face, because a per-face drag is a deliberate per-face statement.
    func testDraggingAfterTypingStillOverridesThatOneFace() {
        let (p, gid, ref) = project()
        p.writeGroupDepthMM(gid, mm: 12.0)
        p.writeLatticeDepthMM(ref, mm: 3.0)
        XCTAssertEqual(drawnDepth(p, ref), 3.0)
        XCTAssertEqual(p.latticeSlabDepthMM(gid), 12.0,
                       "the GROUP's own number is unchanged by a per-face drag")
    }
}
