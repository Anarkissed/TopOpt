// LatticeBarrierModelTests.swift — task 2026-08-12-lattice-page-redesign.
//
// THE MAINTAINER'S SENTENCE, AS TESTS: "we are setting a barrier on the TO in
// order to get the lattice to lighten."
//
//   §0a  ONE CONTROL, ONE VALUE, ONE SLAB. Protection depth and lattice region
//        depth are THE SAME NUMBER for a face that carries both, at every call
//        site that reaches the run — not merely on the value type (R2).
//   §1e  A LATTICE ROLE IS A COMPLETE DECLARATION. A group set "lattice here"
//        must not sit PENDING and must not refuse the run — at the TAGGER too,
//        which is where the model-level fix stopped short.
//   §1f  LOAD AND ANCHOR FACES ARE NOT AUTO-PROTECTED. What the app declares as
//        a Face protection is what the user marked Protect, and nothing else.
//
// Written to FAIL first (see the handoff's §1e section for the recorded failure).

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeBarrierModelTests: XCTestCase {

    private func groups(_ faces: [FaceID]) -> (SelectionModel, [UUID]) {
        var m = SelectionModel()
        for f in faces { m.addGroup(); m.pickFaces([f]) }
        return (m, m.groups.map { $0.id })
    }

    // MARK: §1e — a lattice role satisfies the pending check AT THE TAGGER

    /// THE L5 BLOCKER. `ForceModel.hasPending` learned about lattice roles; the
    /// tagger — the seam that actually applies a load case — did not, and it
    /// throws `.pendingGroup` for any group without an anchor/load role. That
    /// refuses a keep-clear-only and a protect-only group too, both of which the
    /// model has called complete declarations since keep-clear v2 / handoff 124.
    func testTaggerAcceptsALatticeRoleOnlyGroup() throws {
        let (sel, ids) = groups([3, 4])
        let latticed = ids[0], anchor = ids[1]
        var fm = ForceModel()
        fm.sync(groups: sel.groups)
        fm.makeAnchor(anchor)

        var tagged: [FaceID] = []
        let tagger = LoadCaseTagger(
            shellDepthVoxels: 2,
            tagFace: { _, f, _, _ in tagged.append(f); return 1 },
            maskFace: { _, _, _, _ in 1 })

        // The group's ONLY declaration is a lattice role.
        let results = try tagger.apply(force: fm, groups: sel.groups,
                                       latticeRoleGroups: [latticed],
                                       stepPath: "part.step", resolution: 24)
        XCTAssertEqual(results.count, 2,
                       "§1e: a lattice-role group does not refuse the load case")
        XCTAssertEqual(tagged.sorted(), [3, 4],
                       "§1e: and both groups still reach the bridge")
    }

    /// The tagger must still refuse a group that has declared NOTHING — the
    /// positive control, so the check above cannot pass by the tagger having
    /// simply stopped refusing anything.
    func testTaggerStillRefusesAnUndeclaredGroup() {
        let (sel, ids) = groups([3])
        var fm = ForceModel()
        fm.sync(groups: sel.groups)
        let tagger = LoadCaseTagger(tagFace: { _, _, _, _ in 1 },
                                    maskFace: { _, _, _, _ in 1 })
        XCTAssertThrowsError(
            try tagger.apply(force: fm, groups: sel.groups,
                             stepPath: "part.step", resolution: 24)
        ) { error in
            XCTAssertEqual(error as? LoadCaseError, .pendingGroup(ids[0]))
        }
    }

    /// Keep-clear-only and protect-only groups are complete declarations by the
    /// same rule, and the tagger refused those too.
    func testTaggerAcceptsKeepClearOnlyAndProtectOnlyGroups() throws {
        let (sel, ids) = groups([3, 4])
        var fm = ForceModel()
        fm.sync(groups: sel.groups)
        fm.setKeepClearAffix(ids[0], .on)
        fm.setProtected(ids[1], true)
        let tagger = LoadCaseTagger(tagFace: { _, _, _, _ in 1 },
                                    maskFace: { _, _, _, _ in 1 })
        let results = try tagger.apply(force: fm, groups: sel.groups,
                                       stepPath: "part.step", resolution: 24)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: §0a / R2 — protection depth IS the lattice depth

    /// The value-type guarantee: one dragged depth produces both numbers.
    func testOneDraggedDepthProducesBothNumbers() {
        let (sel, ids) = groups([16])
        let gid = ids[0]
        var s = LatticeSettings()
        s.enabled = true
        s.groupRoles[gid] = .include
        s.groupDepthMM[gid] = 7.0
        s.paintDepthMM = 4.0                   // the OLD global — must not win

        let depth = LatticeSlabDepth.depthMM(group: gid, perGroup: s.groupDepthMM,
                                             fallbackMM: s.paintDepthMM)
        XCTAssertEqual(depth, 7.0, accuracy: 1e-12)

        let slabs = LatticeSlabDepth.slabs(
            groups: sel.groups, roles: s.groupRoles,
            isProtected: { _ in true }, perGroupDepthMM: s.groupDepthMM,
            fallbackMM: s.paintDepthMM, runFaceID: { Int($0) })
        XCTAssertEqual(slabs.count, 1)
        XCTAssertEqual(slabs[0].faceID, 16)
        XCTAssertEqual(slabs[0].depthMM, 7.0, accuracy: 1e-12)
        XCTAssertTrue(slabs[0].protected)
    }

    /// The mismatch detector, with the maintainer's own numbers.
    func testMismatchDetectorNamesTheFaceAndBothDepths() {
        let bad = LatticeSlabDepth.mismatches(protections: [(16, 5.0)],
                                              regions: [(16, 7.0)])
        XCTAssertEqual(bad.count, 1)
        XCTAssertEqual(bad[0].faceID, 16)
        XCTAssertEqual(bad[0].protectionMM, 5.0)
        XCTAssertEqual(bad[0].regionMM, 7.0)

        XCTAssertTrue(LatticeSlabDepth.mismatches(protections: [(16, 7.0)],
                                                  regions: [(16, 7.0)]).isEmpty,
                      "matched depths are not a mismatch")
        XCTAssertTrue(LatticeSlabDepth.mismatches(protections: [(16, 5.0)],
                                                  regions: [(19, 7.0)]).isEmpty,
                      "two different faces are two different slabs")
    }

    // MARK: §0a — THE CALL SITES, not just the value type
    //
    // "Tests on value types miss call sites" has shipped a defect in this repo
    // five times. These drive `ProjectModel`, the object the run request is
    // actually built from.

    /// A part with ONE planar wall carrying B-rep face id 16 — the maintainer's
    /// protected face, so the numbers in these tests are his numbers.
    private func wallMesh() -> ViewerMesh {
        let verts: [Float] = [0, 0, 0,  20, 0, 0,  20, 30, 0,  0, 30, 0]
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let faceIDs: [Int32] = [16, 16]
        var geo = [StepFaceGeometry](repeating: StepFaceGeometry(kind: .other),
                                     count: 17)
        geo[16] = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                   planeOrigin: SIMD3(0, 0, 0))
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs,
                          faceGeometry: geo)
    }

    private func emptyProject() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Barrier", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = wallMesh()
        return p
    }

    private func projectWithProtectedLatticeWall(depthMM: Double)
        -> (ProjectModel, UUID) {
        let p = emptyProject()
        p.selection.addGroup()
        p.selection.pickFaces([16])
        let gid = p.selection.groups[0].id
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.force.faceProtectDepthMM = 5.0          // the OLD global
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4.0              // the OLD region global
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = depthMM     // the ONE dragged number
        return (p, gid)
    }

    func testProtectionSpecCarriesTheDraggedDepthPerFace() {
        let (p, _) = projectWithProtectedLatticeWall(depthMM: 7.0)
        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.faceIDs, [16])
        XCTAssertEqual(specs.depthsMM.count, specs.faceIDs.count,
                       "§0a: the per-face depths are parallel to the face ids")
        XCTAssertEqual(specs.depthsMM.first ?? 0, 7.0, accuracy: 1e-12,
                       "§0a: the protection is as deep as the lattice, NOT the "
                       + "5 mm global")
    }

    func testProtectOnlyFaceKeepsTheGlobalDepth() {
        let p = emptyProject()
        p.selection.addGroup()
        p.selection.pickFaces([16])
        let gid = p.selection.groups[0].id
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.force.faceProtectDepthMM = 5.0
        // No lattice role: nothing has been dragged, so nothing changes.
        XCTAssertEqual(p.faceProtectionSpecs().depthsMM.first ?? 0, 5.0,
                       accuracy: 1e-12)
    }

    func testRunRequestCarriesTheDepthsAndTheyMatchTheRegions() {
        let (p, gid) = projectWithProtectedLatticeWall(depthMM: 7.0)
        XCTAssertEqual(p.latticeSlabDepthMM(gid), 7.0, accuracy: 1e-12)
        let specs = p.faceProtectionSpecs()
        let protections = zip(specs.faceIDs, specs.depthsMM).map {
            (faceID: $0.0, depthMM: $0.1)
        }
        // The regions the run would carry, from the same project.
        let regions = p.latticeJobRegions().regions.compactMap { r -> (faceID: Int, depthMM: Double)? in
            guard r.kind == .face, let f = r.faceID else { return nil }
            return (f, r.depthMM)
        }
        XCTAssertTrue(LatticeSlabDepth.mismatches(protections: protections,
                                                  regions: regions).isEmpty,
                      "R2: protection depth and lattice depth are the same number "
                      + "on the path the run is built from")
    }

    // MARK: §1a/§1d — the gate AT THE CALL SITE, not only on the value type

    /// A role stored against a group that has since lost its eligibility must not
    /// reach the job. Checked on `ProjectModel`, the object the run is built from.
    func testAnIneligibleGroupsRoleNeverReachesTheJob() {
        let (p, gid) = projectWithProtectedLatticeWall(depthMM: 7.0)
        XCTAssertEqual(p.latticeEligibleRoles()[gid], .include,
                       "a protected, latticed wall is eligible")
        XCTAssertFalse(p.latticeJobRegions().regions.isEmpty,
                       "and it emits a region")

        // The user clears Protect. The group now declares nothing, so its stored
        // lattice role is inert — not carried into the run behind their back.
        p.force.setProtected(gid, false)
        XCTAssertNil(p.latticeEligibleRoles()[gid], "§1a")
        XCTAssertTrue(p.latticeJobRegions().regions.isEmpty,
                      "§1a: and it emits nothing")

        // Keep clear blocks it even with a real role.
        p.force.makeAnchor(gid)
        XCTAssertNotNil(p.latticeEligibleRoles()[gid], "an anchor is eligible")
        p.force.setKeepClearAffix(gid, .on)
        XCTAssertNil(p.latticeEligibleRoles()[gid], "§1d: keep clear blocks it")
    }

    // MARK: §1f — load and anchor faces are NOT auto-protected

    func testLoadAndAnchorFacesAreNeverDeclaredAsProtections() {
        let p = emptyProject()
        // One protected wall, one anchor group, one load group — his shape.
        p.selection.addGroup(); p.selection.pickFaces([16])
        p.selection.addGroup(); p.selection.pickFaces([18])
        p.selection.addGroup(); p.selection.pickFaces([20, 21, 22])
        let ids = p.selection.groups.map { $0.id }
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(ids[0], true)
        p.force.makeAnchor(ids[1])
        p.force.makeLoad(ids[2])

        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.faceIDs, [16],
                       "§1f: only the wall the user marked Protect is declared a "
                       + "Face protection — not the anchor, not the 3 load faces")
    }
}
