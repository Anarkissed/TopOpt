// LatticeSeparationRegionTests.swift — the INTERRUPT's bars
// (task 2026-08-14-lattice-separation, rebased onto PR 331 `face-regions`).
//
// §8 of the original brief said face splitting, grid splitting and union were
// deferred and must not be designed around. PR 331 landed and that is no longer
// true: a REGION is a first-class selectable and it is sitting in the very panel
// this task restructures.
//
//   R11  rebased on PR 331, not merged blind — the base commit is stated in the
//        handoff and this file drives PR 331's own types.
//   R12  ONE collapse mechanism in the Selections panel: a region's expansion IS
//        PR 331's `FaceRegion.collapsed`, not a second flag beside it.
//   R13  a REGION and a FACE behave identically as selectables — same role
//        chips, same lattice choice, same depth, same drawer.
//   R14  PR 331's sliver guard and small-face policy still fire after the
//        restructure.
//
// ★ AND THE ONE THING THAT IS *NOT* IDENTICAL, asserted rather than glossed: a
// region's lattice choice cannot reach the run (PR 331 §6 — core's
// `lattice.regions` are geometry predicates, a region is a voxel set). It is
// CAPTURED and the row SAYS SO.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeSeparationRegionTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: fixture — PR 331's banded cube, in a protected + latticed group

    /// Face ids: 0 bottom, 1 top, 2 y=0, 3 the +x wall below z=9, 4 y=10,
    /// 5 x=0, 8 the +x BAND (small, between larger faces — his 41-47 shape).
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

    /// ONE group holding a REGION (the +x wall unioned with its band) and one
    /// plain FACE (the top), protected and latticed — so the two kinds of
    /// selectable sit side by side in the row R13 is about.
    private func projectWithARegionAndAFace()
        -> (ProjectModel, group: UUID, region: RegionID) {
        let p = ProjectModel(id: UUID(), name: "Regions", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = bandedCube()
        let rid = p.faceRegions.union(faces: [3, 8], named: "wall")
        p.selection.addGroup()
        p.selection.pickFaces([1])
        let gid = p.selection.groups[0].id
        p.selection.addRegions([rid], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.force.faceProtectDepthMM = 5.0
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4.0
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 7.0
        return (p, gid, rid)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R13 — a region and a face are the SAME KIND OF THING

    /// ★ His complaint applies to a region identically: "Each primitive needs to
    /// have its own lattice/no lattice selection. Otherwise, what the fuck are
    /// they doing?" A region that is listed and cannot decide is decorative.
    func testARegionIsASelectableJustLikeAFace() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let refs = p.latticeSelectableRefs(p.selection.groups[0])
        XCTAssertTrue(refs.contains(.region(group: gid, region: rid)),
                      "R13: the region is in the list the row is built from")
        XCTAssertTrue(refs.contains(.face(group: gid, face: 1)),
                      "…beside the plain face")
        // The region comes FIRST: PR 331's whole point is that a union is the
        // summary of the faces it replaced.
        XCTAssertEqual(refs.first, .region(group: gid, region: rid))
    }

    /// Same role chips, resolved by the same function, with the same three states.
    func testARegionCarriesItsOwnLatticeChoice() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let face = LatticeSelectableRef.face(group: gid, face: 1)

        XCTAssertEqual(p.latticeSelectableRole(region, in: gid), .include,
                       "it follows the group until it is given its own answer")
        LatticeSelectableRoles.declare(
            .exclude, for: region,
            siblings: p.latticeSelectableRefs(p.selection.groups[0]),
            groupRole: p.latticeEligibleRoles()[gid],
            in: &p.lattice.selectableRoles)
        XCTAssertEqual(p.latticeSelectableRole(region, in: gid), .exclude,
                       "R13: and then it carries its own")
        XCTAssertEqual(p.latticeSelectableRole(face, in: gid), .include,
                       "R13: …without moving the face beside it")
        XCTAssertEqual(p.latticeCoverage(p.selection.groups[0]), .some,
                       "and the group SUMMARISES the two answers")
    }

    /// ★ THE DEPTH — and this is the one that had to match PR 331's own store.
    /// A region's dragged depth must land in `face_protection_region_depths_mm`,
    /// parallel to `face_protection_region_ids`, not in a parallel store of ours.
    func testARegionsDepthFillsPR331sPerRegionProtectionArrays() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        p.writeLatticeDepthMM(region, mm: 9.0)
        p.writeLatticeDepthMM(face, mm: 3.0)

        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.regionIDs, [rid], "R13: the region is protected")
        XCTAssertEqual(specs.regionDepthsMM.count, specs.regionIDs.count,
                       "the depths are PARALLEL to the ids, PR 331's own shape")
        XCTAssertEqual(specs.regionDepthsMM.first ?? 0, 9.0, accuracy: 1e-12,
                       "R13/§3d: the depth the handle dragged, not the 5 mm global")
        XCTAssertEqual(specs.depthsMM.first ?? 0, 3.0, accuracy: 1e-12,
                       "…and the face beside it kept its own, so R4 still holds "
                       + "with a region in the group")
    }

    /// Same drawer, same builder, same layout — R13's "same drawer" is a property
    /// of there being ONE builder rather than two kept in step.
    func testARegionGetsTheSameDrawerAFaceDoes() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let region = LatticeSelectableRef.region(group: gid, region: rid)
        let d = LatticeRegionDrawer.make(
            card: nil, depthMM: p.latticeSlabDepthMM(region, in: gid),
            held: true, latticeReachesTheRun: region.latticeReachesTheRun)
        XCTAssertEqual(d.modifiableRows.count, 1, "§4b: one control, the depth")
        XCTAssertEqual(d.modifiableRows.first?.label, "Depth")
        XCTAssertTrue(d.held, "and the barrier is named on a region too")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ THE ONE HONEST DIFFERENCE — captured, and said

    /// PR 331 §6: core's `lattice.regions` are pure GEOMETRY that become
    /// `ClearanceGeometry` predicates evaluated pointwise; a region is a voxel
    /// SET. So a region's lattice choice cannot reach the run today. It is still
    /// STORED — it is the user's answer and must survive until core catches up —
    /// and the row states the limit rather than doing nothing quietly.
    func testARegionsLatticeChoiceIsCapturedAndTheRowSaysItIsNotConsumed() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let region = LatticeSelectableRef.region(group: gid, region: rid)

        XCTAssertFalse(region.latticeReachesTheRun,
                       "PR 331 §6: not until core grows a mask-backed sibling")
        XCTAssertTrue(LatticeSelectableRef.face(group: gid, face: 1).latticeReachesTheRun)
        XCTAssertTrue(LatticeSelectableRef.primitive(UUID()).latticeReachesTheRun)

        // CAPTURED: the answer persists.
        p.lattice.selectableRoles[region.key] = .include
        XCTAssertEqual(p.latticeSelectableRole(region, in: gid), .include)

        // SAID: the drawer leads with it, in three words.
        let d = LatticeRegionDrawer.make(card: nil, depthMM: 7, held: true,
                                         latticeReachesTheRun: false)
        let head = d.headline
        XCTAssertNotNil(head, "a control that silently does nothing is the defect")
        XCTAssertEqual(head?.text, "Frozen, not latticed")
        XCTAssertLessThanOrEqual(head?.text.split(separator: " ").count ?? 99, 3,
                                 "R7: three words")
        XCTAssertEqual(WorkspacePlaceholder.latticeRegionNotConsumed,
                       "Frozen, not latticed",
                       "the row chip and the drawer headline are the same words")
    }

    /// …and it is not merely unshown: the emitted job carries no region as a
    /// lattice region, so nothing downstream can act on a choice core cannot read.
    func testNoRegionIsEverEmittedAsALatticeRegion() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        p.lattice.selectableRoles[LatticeSelectableRef.region(group: gid, region: rid).key] = .include
        let faceRegions = p.latticeJobRegions().regions
        XCTAssertEqual(faceRegions.count, 1,
                       "only the plain FACE becomes a lattice region")
        XCTAssertEqual(faceRegions.first?.faceID, 1)
        // The protection side DOES carry it — that is PR 331 §6's "a grid split
        // grades what is FROZEN, not what is LATTICED", and it still holds.
        XCTAssertEqual(p.faceProtectionSpecs().regionIDs, [rid])
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R12 — ONE collapse mechanism

    /// ★ A region's expansion in the Selections panel IS `FaceRegion.collapsed`.
    /// Not a copy, not a mirror: the same bit, so the Regions sheet and this
    /// panel cannot disagree about whether a split is open.
    func testTheSelectionsPanelUsesPR331sOwnCollapseFlag() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        var disclosure = LatticeRowDisclosure()
        let region = LatticeSelectableRef.region(group: gid, region: rid)

        p.faceRegions.setCollapsed(rid, true)
        XCTAssertFalse(disclosure.isExpanded(region, regions: p.faceRegions))
        disclosure.toggle(region, regions: &p.faceRegions)
        XCTAssertTrue(disclosure.isExpanded(region, regions: p.faceRegions))
        XCTAssertEqual(p.faceRegions.region(rid)?.collapsed, false,
                       "R12: the panel WROTE PR 331's flag — there is no second "
                       + "state to drift from it")

        // A face has no FaceRegion to store it on, so it uses the same type's own
        // set — one mechanism, two backing stores, and only one of them is ours.
        let face = LatticeSelectableRef.face(group: gid, face: 1)
        XCTAssertFalse(disclosure.isExpanded(face, regions: p.faceRegions))
        disclosure.toggle(face, regions: &p.faceRegions)
        XCTAssertTrue(disclosure.isExpanded(face, regions: p.faceRegions))
        XCTAssertEqual(p.faceRegions.regions.count, 1,
                       "…and toggling a face did not manufacture a region")
    }

    /// ★ §5(b) STILL HOLDS IN THIS LIST: a grid split adds ONE row, not fifty.
    /// The restructure walks `latticeSelectableRefs`, which folds children under
    /// a collapsed parent using PR 331's flag.
    func testAGridSplitStillAddsONERowToTheLatticeList() {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let mesh = p.viewerMesh!
        let members = FaceRegionGeometry.members(
            of: p.faceRegions.region(rid)!, in: mesh)
        let frame = FaceRegionGeometry.frame(members: members, in: mesh)
        let cells = FaceRegionGeometry.gridSplitCells(frame, n: 5, m: 5)
        let kids = p.faceRegions.splitGrid(rid, cells: cells)
        XCTAssertEqual(kids.count, 25, "the split really made 25 cells")
        p.selection.addRegions(kids, to: gid)

        XCTAssertEqual(p.latticeRegionRefs(p.selection.groups[0]).count, 1,
                       "§5b/R12: ONE row while the parent is collapsed — the list "
                       + "does not explode")
        p.faceRegions.setCollapsed(rid, false)
        XCTAssertEqual(p.latticeRegionRefs(p.selection.groups[0]).count, 26,
                       "…and expanding it shows the parent and its 25 children")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R14 — PR 331's guards still fire

    /// ★ THE SLIVER GUARD, after the restructure. A guard that stops firing
    /// because the list was rebuilt is a regression, so it is checked HERE and
    /// not only in PR 331's own suite.
    func testTheSliverGuardStillRefusesWithItsNumber() {
        let (p, _, rid) = projectWithARegionAndAFace()
        let mesh = p.viewerMesh!
        let members = FaceRegionGeometry.members(
            of: p.faceRegions.region(rid)!, in: mesh)
        let frame = FaceRegionGeometry.frame(members: members, in: mesh)
        // A 10x10 split of a 110 mm² region at a coarse grid: the cells cannot
        // clear the 16-voxel floor.
        let cells = FaceRegionGeometry.gridSplitCells(frame, n: 10, m: 10)
        let counts = FaceRegionGeometry.cellVoxelCounts(
            members: members, in: mesh, cells: cells, spacingMM: 1.0)
        let verdict = FaceRegionModel.checkSliver(
            cellVoxels: counts,
            memberVoxels: FaceRegionGeometry.memberVoxelEstimate(
                members: members, in: mesh, spacingMM: 1.0))
        XCTAssertFalse(verdict.ok, "R14: the guard still refuses")
        XCTAssertFalse(verdict.reason.isEmpty, "…with the number, not silently")
        XCTAssertEqual(verdict.floorVoxels, kRegionSliverFloorVoxels,
                       "and against the floor PR 331 derived from his own CAD")
    }

    /// ★ THE SMALL-FACE POLICY (§5c): rows below the floor are DIMMED, not
    /// hidden. The restructure must not have dropped them from the list — losing
    /// them would lose a selection his CAD does hand him.
    func testASmallSelectableIsListedAndFlaggedNotHidden() {
        let (p, gid, _) = projectWithARegionAndAFace()
        // Put the BAND (10 mm², the small one) in the group as a plain face.
        p.selection.addFaces([8], to: gid)

        let refs = p.latticeSelectableRefs(p.selection.groups[0])
        XCTAssertTrue(refs.contains(.face(group: gid, face: 8)),
                      "R14/§5c: the small face is LISTED — hiding it would lose a "
                      + "selection his CAD hands him (faces 41-47 are 16 voxels)")
        let mesh = p.viewerMesh!
        let small = FaceRegionGeometry.memberVoxelEstimate(
            members: [8], in: mesh, spacingMM: 1.0)
        let large = FaceRegionGeometry.memberVoxelEstimate(
            members: [1], in: mesh, spacingMM: 1.0)
        XCTAssertLessThan(small, large,
                          "and the fixture really does hold a small one beside a "
                          + "large one, so the dimming rule has something to bite")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §3d — the depth PLANE on a region, and its honest refusal

    /// A region whose members face one way gets a depth plane reaching INTO the
    /// part, exactly as a face does.
    func testAFlatRegionGetsADepthPlaneReachingIntoThePart() throws {
        let (p, gid, rid) = projectWithARegionAndAFace()
        let planes = p.latticeDepthPlanes()
        let regionPlane = try XCTUnwrap(
            planes.first { $0.ref == .region(group: gid, region: rid) },
            "§3d: the +x wall and its band face one way, so they have a plane")
        guard case let .slab(_, normal, _, _, _, _, depth) = regionPlane.volume.shape
        else { return XCTFail("a region plane is a SLAB") }
        XCTAssertEqual(simd_dot(normal, SIMD3<Float>(-1, 0, 0)), 1, accuracy: 1e-5,
                       "§3d: INTO the part — the members' outward normal, flipped")
        XCTAssertEqual(Double(depth), 7.0, accuracy: 1e-4, "at the group's depth")
        XCTAssertEqual(regionPlane.handle.role, .slabDepth,
                       "R13: the same grab a face's plane gets")
    }

    /// ★ AND IT IS REFUSED, NOT INVENTED, when the members do not face one way.
    /// A union of the +x wall and the top has no single "into the part": any
    /// plane drawn for it would be a number the user could drag that means
    /// nothing.
    func testAWrappingRegionGetsNoDepthPlaneRatherThanAMeaninglessOne() {
        let (p, gid, _) = projectWithARegionAndAFace()
        let wrap = p.faceRegions.union(faces: [3, 1], named: "wrap")
        p.selection.addRegions([wrap], to: gid)

        let planes = p.latticeDepthPlanes()
        XCTAssertNil(planes.first { $0.ref == .region(group: gid, region: wrap) },
                     "§3d: no plane for a region with no direction")
        // …and the region is still LISTED and still carries a depth, so what it
        // loses is the 3D grab, not the number.
        XCTAssertTrue(p.latticeSelectableRefs(p.selection.groups[0])
                        .contains(.region(group: gid, region: wrap)))
        XCTAssertEqual(p.latticeSlabDepthMM(.region(group: gid, region: wrap),
                                            in: gid), 7.0, accuracy: 1e-12)
    }
}
