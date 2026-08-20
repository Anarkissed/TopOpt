// LatticePerFaceOnlyTests.swift — ★ THE GROUP HAS NO LATTICE NOTES
// (maintainer, 2026-08-17).
//
// ★ HIS WORDS: "There is a 'per Group' set of notes regarding the lattice that
// doesn't make sense. It should be per face *only*. The group does *not* have
// its own primitive to expand therefor making it impossible to ever be *IN*
// regime. Please remove that whole per group section."
//
// ★ HE IS DESCRIBING A FABRICATED NUMBER. The group drawer was derived from a
// card built at `g.faces.first` — ONE arbitrary face standing in for the whole
// group — at the GROUP's depth. It printed a cell, a density, a strut and a
// cells-across for a slab NO PRIMITIVE OWNS and NO HANDLE CAN DRAG. Every one of
// those was a real derivation of a thing that does not exist, which is the same
// defect class as the 5% band floor: a readout that looks like a measurement and
// is not. Being unable to drag it into regime is the symptom, not the disease.
//
// ★★ AND THE BADGE HAD TO SURVIVE. It is on the do-not-regress list ("the error
// badge is live and correctly counts BOTH failures") and it was reading THAT
// card. So it is not deleted with the drawer — it is re-derived from the faces,
// which makes it describe things that exist. These tests hold both halves.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticePerFaceOnlyTests: XCTestCase {

    // MARK: the section list — the one place a stage says what a row contains

    /// ★ THE REMOVAL, AT ITS SOURCE. `latticeDrawer` is not in any stage's
    /// section list, and the row builder only builds what is listed.
    func testNoStageBuildsTheGroupLatticeDrawer() {
        for stage in [WorkspaceStage.topology, .lattice, .surface] {
            let v = WorkspaceStageVisibility.of(stage)
            XCTAssertFalse(v.rowSections.contains(.latticeDrawer),
                           "★ the per-GROUP lattice drawer is gone from \(stage)")
        }
    }

    /// …and the lattice stage still offers the two sections that DO make sense:
    /// the summary (coverage + disclosure) and the per-FACE rows.
    func testTheLatticeStageKeepsTheSummaryAndThePerFaceRows() {
        let v = WorkspaceStageVisibility.of(.lattice)
        XCTAssertEqual(v.rowSections, [.latticeSummary, .latticePrimitiveRows],
                       "★ per face ONLY — plus the row that opens them")
    }

    /// ★ AND NO GROUP CARD IS COMPUTED AT ALL. Removing the view while still
    /// deriving the number would leave the fabrication one call site away from
    /// coming back; `latticeCardInputs` is where it was born.
    func testNoGroupKeyedCardIsDerivedAnyMore() {
        let (p, gid, _) = project()
        let inputs = p.latticeCardInputs()
        XCTAssertFalse(inputs.isEmpty, "the group's faces still produce cards")
        XCTAssertFalse(inputs.contains { $0.key == gid.uuidString },
                       "★ no card is keyed by the GROUP — the slab it described "
                       + "had no primitive and no handle")
        // Every remaining input is a selectable, and each one HAS a depth a
        // handle writes.
        let refKeys = Set(p.latticeSelectableRefs(p.selection.groups[0]).map(\.key))
        for i in inputs {
            XCTAssertTrue(refKeys.contains(i.key),
                          "every card belongs to a draggable selectable: \(i.key)")
        }
    }

    // MARK: the badge — kept, and now describing things that exist

    private func diagnosis(cellsAcross: Double, strut: Double,
                           held: Int = 5000) -> LatticeFaceDiagnosis {
        let card = LatticeFaceCard(
            faceID: 1, depthMM: 8, heldVoxels: held, heldVolumeMM3: 1000,
            heldMassG: 12, cellMM: 1.6, relativeDensity: 0.4,
            strutDiameterMM: strut, cellsPerMember: cellsAcross,
            verdict: held == 0 ? .noMaterial : .outOfRegime)
        return LatticeFaceDiagnosis.of(card: card, cellsPerMemberFloor: 5,
                                       nozzleWidthMM: 0.45)
    }

    /// ★ THE BADGE HE ALREADY HAS, UNCHANGED, when one face has both faults.
    /// "Won't certify — 2 problems, tap for the fix" is the exact string on the
    /// do-not-regress list.
    func testTheTwoProblemBadgeIsWordForWordWhatItWas() {
        let d = diagnosis(cellsAcross: 3.4, strut: 0.32)
        XCTAssertEqual(d.problems.count, 2)
        XCTAssertEqual(d.badge, "Won't certify — 2 problems, tap for the fix")
        XCTAssertEqual(LatticeFaceDiagnosis.merged([d]).badge, d.badge,
                       "★ merging ONE face changes nothing — the badge he has "
                       + "today is the badge he keeps")
    }

    /// ★ THE UNION ACROSS FACES, deduped BY KIND. Three faces that are all too
    /// thin are ONE thing to fix, not three copies of one sentence.
    func testFacesWithTheSameFaultProduceOneProblemNotThree() {
        let m = LatticeFaceDiagnosis.merged([
            diagnosis(cellsAcross: 3.4, strut: 0.50),
            diagnosis(cellsAcross: 2.1, strut: 0.50),
            diagnosis(cellsAcross: 4.9, strut: 0.50),
        ])
        XCTAssertEqual(m.problems.count, 1, "one KIND of fault, one line")
        XCTAssertEqual(m.badge, "Won't certify — tap for the fix")
        XCTAssertEqual(m.severity, .outOfRegime)
    }

    /// ★ AND TWO DIFFERENT FAULTS ON TWO DIFFERENT FACES BOTH SURVIVE — §3(c)'s
    /// standing rule: "a panel that flags one problem and hides another is worse
    /// than one that flags none."
    func testTwoFacesWithDifferentFaultsBothReachTheBadge() {
        let m = LatticeFaceDiagnosis.merged([
            diagnosis(cellsAcross: 3.4, strut: 0.50),   // too few struts
            diagnosis(cellsAcross: 6.0, strut: 0.32),   // too thin to print
        ])
        XCTAssertEqual(m.problems.count, 2)
        XCTAssertEqual(m.badge, "Won't certify — 2 problems, tap for the fix")
        XCTAssertTrue(m.problems.contains { $0.what.hasPrefix("Not certifiable") })
        XCTAssertTrue(m.problems.contains { $0.what.hasPrefix("Too thin") })
    }

    /// ★ THE COUNT IS THE REAL COUNT. `badgeText` read a literal "2 problems" for
    /// ANY count above one — harmless while the badge described ONE card (there
    /// are only two fault kinds) and a lie the moment it describes a GROUP. Fixed
    /// with the merge rather than exposed by it.
    func testTheBadgeCountIsNotHardcodedToTwo() {
        let three = [
            LatticeFaceDiagnosis.Problem(what: "A.", measured: "m", fixes: ["f"]),
            LatticeFaceDiagnosis.Problem(what: "B.", measured: "m", fixes: ["f"]),
            LatticeFaceDiagnosis.Problem(what: "C.", measured: "m", fixes: ["f"]),
        ]
        XCTAssertEqual(LatticeFaceDiagnosis.badgeText(three),
                       "Won't print — 3 problems, tap for the fix")
        XCTAssertEqual(LatticeFaceDiagnosis.badgeText([three[0]]),
                       "Won't print — tap for the fix")
    }

    /// A clean group has NO badge — the merge must not invent one.
    func testAllCertifiedFacesLeaveNoBadge() {
        let clean = diagnosis(cellsAcross: 6.0, strut: 0.50)
        XCTAssertNil(clean.badge, "the fixture really is clean")
        let m = LatticeFaceDiagnosis.merged([clean, clean])
        XCTAssertNil(m.badge)
        XCTAssertEqual(m.severity, .certified)
        XCTAssertTrue(m.isClean)
    }

    /// An EMPTY group — nothing latticed yet — is clean, not broken.
    func testAGroupWithNothingLatticedHasNoBadge() {
        XCTAssertNil(LatticeFaceDiagnosis.merged([]).badge)
        XCTAssertEqual(LatticeFaceDiagnosis.merged([]).severity, .certified)
    }

    /// ★ `noMaterial` only when EVERY face says so. One empty face beside a face
    /// that is merely out of regime is the latter — the group has something to
    /// lighten, and calling it "holds nothing" would be wrong.
    func testOneEmptyFaceBesideARealOneIsNotHoldsNothing() {
        let empty = diagnosis(cellsAcross: 0, strut: 0, held: 0)
        XCTAssertEqual(empty.severity, .noMaterial, "the fixture really is empty")
        let real = diagnosis(cellsAcross: 3.4, strut: 0.50)
        XCTAssertEqual(LatticeFaceDiagnosis.merged([empty, real]).severity,
                       .outOfRegime)
        XCTAssertEqual(LatticeFaceDiagnosis.merged([empty, empty]).severity,
                       .noMaterial, "…but all-empty still reads as holds nothing")
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
        let p = ProjectModel(id: UUID(), name: "PerFace", material: "PLA",
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
        p.lattice.paintDepthMM = 4.0
        p.lattice.groupRoles[gid] = .include
        return (p, gid, rid)
    }
}
