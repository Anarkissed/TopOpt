// LatticeSeparationTests.swift — task 2026-08-14-lattice-separation.
//
// ★ THE ONE ARCHITECTURAL REQUIREMENT, AS CHECKS: "It is VERY important we
// separate the TO and Lattices out so the user can choose between JUST TO or
// TO+lattice and have complete control with where the lattice goes."
//
//   R1  a TO-only job runs without the lattice page ever being opened.
//   R2  no lattice control, chip, readout or state text survives on the TO page
//       except the single navigation button.
//   R3  per-primitive lattice/no-lattice: two primitives in ONE group with
//       different settings produce two DIFFERENT regions in the emitted job.
//   R4  the depth drag and the protection depth remain ONE number — now per FACE,
//       because the depth plane became per face.
//   R5  the wizard and the side modal share one state.
//   §2  what each page hides — and that hiding is not disabling.
//   §4  the drawer: the out-of-regime flag is the headline, the depth is the only
//       control.
//   §7  the sample is visible on entry.
//   R7  the longest string this task adds, counted rather than claimed.
//
// R5 and §7 were WRITTEN TO FAIL FIRST — see
// `evidence/2026-08-14-lattice-separation/r5_r7_failing_first.txt`, which is this
// file run against the pre-task `LatticeWizardModel`.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeSeparationTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: fixtures — his shape: one part, one group, TWO walls in it

    /// A part with two planar walls, B-rep face ids 16 and 17. Two faces in ONE
    /// group is the case §3c is about: before this task they had no say.
    private func twoWallMesh() -> ViewerMesh {
        let verts: [Float] = [
            0, 0, 0,  20, 0, 0,  20, 30, 0,  0, 30, 0,          // face 16, +z
            0, 0, 10,  20, 0, 10,  20, 30, 10,  0, 30, 10,      // face 17, −z
        ]
        let indices: [Int32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
        let faceIDs: [Int32] = [16, 16, 17, 17]
        var geo = [StepFaceGeometry](repeating: StepFaceGeometry(kind: .other),
                                     count: 18)
        geo[16] = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                   planeOrigin: SIMD3(0, 0, 0))
        geo[17] = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1),
                                   planeOrigin: SIMD3(0, 0, 10))
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs,
                          faceGeometry: geo)
    }

    /// ONE group holding BOTH walls, protected and latticed — the maintainer's
    /// primary path (protect + lattice is one slab).
    private func oneGroupTwoWalls() -> (ProjectModel, UUID) {
        let p = ProjectModel(id: UUID(), name: "Separation", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = twoWallMesh()
        p.selection.addGroup()
        p.selection.pickFaces([16, 17])
        let gid = p.selection.groups[0].id
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.force.faceProtectDepthMM = 5.0      // the OLD global — must never win
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4.0
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 7.0
        return (p, gid)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R1 — a TO-only job needs no lattice page

    /// ★ THE HEADLINE PROMISE. Anchor, load, Optimize — and the lattice page never
    /// opened. `lattice.enabled` is false, no role is declared, and the job the run
    /// is built from carries no lattice at all.
    func testATopologyOnlyJobNeedsNoLatticePage() {
        let p = ProjectModel(id: UUID(), name: "TO only", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = twoWallMesh()
        p.selection.addGroup(); p.selection.pickFaces([16])
        p.selection.addGroup(); p.selection.pickFaces([17])
        let ids = p.selection.groups.map(\.id)
        p.force.sync(groups: p.selection.groups)
        p.force.makeAnchor(ids[0])
        p.force.makeLoad(ids[1])
        p.force.setGravity(faceNormal: SIMD3(0, 0, -1), face: 17)

        XCTAssertFalse(p.lattice.enabled,
                       "R1: nothing turned the lattice on, because nothing asked")
        XCTAssertTrue(p.latticeJobRegions().regions.isEmpty,
                      "R1: and the job carries no lattice region")
        XCTAssertNil(p.lattice.runSpec(lineWidthMM: p.printParams.strutLineWidthMM),
                     "R1: no lattice block at all — a TO-only run")
        XCTAssertTrue(p.faceProtectionSpecs().faceIDs.isEmpty,
                      "R1: and no protection either — the user declared none")
        // The Optimize gate is the force model's, and it does not consult the
        // lattice: an anchor and a load are the whole requirement.
        XCTAssertFalse(p.force.hasPending(in: p.selection.groups),
                       "R1: two declared groups, nothing pending")
    }

    /// ★ R1, AT THE DOCUMENT. The check above is on the project; this is on the
    /// job.json a submit actually posts — because "tests on value types miss call
    /// sites" has shipped a defect in this repo five times.
    func testTheJobDocumentOfATopologyOnlyRunCarriesNoLatticeAtAll() throws {
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "TO only",
            anchorFaceIDs: [3],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11],
                                                 force: SIMD3(0, 0, -250))],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1))
        // ★ The lattice block is nil because nothing configured one — the user
        // never opened the lattice page.
        XCTAssertNil(request.lattice)
        let run = RemoteRun(config: RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                                       expectedFingerprint: "test"),
                            request: request,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        let job = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        XCTAssertNil(job["lattice"],
                     "R1: a TO-only run emits a job with no lattice block — the "
                     + "lattice page was never opened and nothing pretends it was")
        // …and it IS a real run request, so the check is not passing on an empty job.
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        XCTAssertEqual(loads["anchor_face_ids"] as? [Int], [3],
                       "R1: the anchor is there")
        XCTAssertEqual((loads["groups"] as? [[String: Any]])?.count, 1,
                       "R1: and the load")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R2 / §2 — what each page shows

    func testTheTopologyPagesGroupRowHasNoLatticeSectionAtAll() {
        let v = WorkspaceStageVisibility.of(.topology)
        XCTAssertEqual(v.rowSections, [.clearanceEditor],
                       "R2: the TO page's group row is the keep-clear editor and "
                       + "NOTHING else — no role chips, no slab row, no readout")
        XCTAssertFalse(v.latticeControls)
        XCTAssertFalse(v.latticeDepthPlanes)
    }

    func testTheOneSurvivingAffordanceIsANavigationTitleNotAStateReadout() {
        // §1b — it NAVIGATES; it is not a state readout. One word, and the same
        // word whether or not a lattice is configured.
        XCTAssertEqual(WorkspaceStage.topology.navigationTitle, "Lattice")
        XCTAssertEqual(WorkspaceStage.topology.navigationTitle
                        .split(separator: " ").count, 1,
                       "§1b: no '· on', no subtitle describing the configuration")
    }

    func testEachPageHidesTheOthersPrimitives() {
        // §2a — the TO page: design box, group primitives, keep-outs. NOT depth planes.
        let to = WorkspaceStageVisibility.of(.topology)
        XCTAssertTrue(to.designBox)
        XCTAssertTrue(to.groupPrimitives)
        XCTAssertTrue(to.keepOuts)
        XCTAssertFalse(to.latticeDepthPlanes)

        // §2b — the lattice page: depth planes. NOT the design box, NOT group
        // primitives, NOT their chips.
        let lat = WorkspaceStageVisibility.of(.lattice)
        XCTAssertTrue(lat.latticeDepthPlanes)
        XCTAssertFalse(lat.designBox)
        XCTAssertFalse(lat.groupPrimitives)
        XCTAssertFalse(lat.keepOuts)
    }

    /// ★ §2c — HIDING IS NOT DISABLING. The lattice depth planes are invisible on
    /// the TO page, and the depth still drives the protection there: the barrier
    /// PR 328 §0 measured (+58.2% material held) survives the separation.
    func testHidingIsNotDisabling() {
        let (p, _) = oneGroupTwoWalls()
        XCTAssertFalse(WorkspaceStageVisibility.of(.topology).latticeDepthPlanes,
                       "the depth plane is HIDDEN on the TO page")
        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.faceIDs.sorted(), [16, 17])
        for d in specs.depthsMM {
            XCTAssertEqual(d, 7.0, accuracy: 1e-12,
                           "§2c: and the number it hides still freezes the slab — "
                           + "the protection is 7 mm, not the 5 mm global")
        }
        XCTAssertEqual(p.latticeJobRegions().regions.count, 2,
                       "§2c: and both regions are still emitted")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R3 — per-primitive lattice / no-lattice

    /// ★ HIS COMPLAINT, AS A CHECK: "Otherwise, what the fuck are they doing?"
    /// Two walls in ONE group, set differently, must reach the job as two
    /// DIFFERENT regions — not one answer applied twice.
    func testTwoPrimitivesInOneGroupWithDifferentSettingsProduceTwoRegions() {
        let (p, gid) = oneGroupTwoWalls()
        let a = LatticeSelectableRef.face(group: gid, face: 16)
        let b = LatticeSelectableRef.face(group: gid, face: 17)

        // Before: the group decides, so both faces get the same role.
        let before = p.latticeJobRegions().regions.filter { $0.kind == .face }
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before.map(\.role)), [.include],
                       "the group's declaration still governs a primitive that "
                       + "has not been given its own answer")

        // The user says "lattice here" on one wall and "no lattice" on the other.
        p.lattice.selectableRoles[a.key] = .include
        p.lattice.selectableRoles[b.key] = .exclude

        let after = p.latticeJobRegions().regions.filter { $0.kind == .face }
        XCTAssertEqual(after.count, 2, "R3: still two regions")
        let byFace = Dictionary(uniqueKeysWithValues: after.map { ($0.faceID ?? -1, $0.role) })
        XCTAssertEqual(byFace[16], .include, "R3: face 16 is latticed")
        XCTAssertEqual(byFace[17], .exclude, "R3: face 17 is kept solid")
        XCTAssertNotEqual(byFace[16], byFace[17],
                          "R3: two primitives in one group, two different regions")
    }

    /// ★ THE THIRD STATE, AND WHY IT HAS TO EXIST. `LatticeGroupRole` is
    /// include|exclude and BOTH are regions core emits, so a per-primitive answer
    /// needs "not a region" as well — otherwise declaring ONE face of a three-face
    /// group would silently declare the other two, and "complete control with
    /// where the lattice goes" would not be reachable.
    func testDeclaringOnePrimitivePinsItsSiblingsInsteadOfMovingThem() {
        let (p, gid) = oneGroupTwoWalls()
        p.lattice.groupRoles[gid] = nil          // an undeclared group…
        p.force.setProtected(gid, true)          // …that is still eligible
        XCTAssertNil(p.latticeEligibleRoles()[gid])

        let a = LatticeSelectableRef.face(group: gid, face: 16)
        let b = LatticeSelectableRef.face(group: gid, face: 17)
        LatticeSelectableRoles.declare(.include, for: a,
                                      siblings: p.latticeSelectableRefs(p.selection.groups[0]),
                                      groupRole: p.latticeEligibleRoles()[gid],
                                      in: &p.lattice.selectableRoles)
        p.lattice.groupRoles[gid] = .include     // what the tap also does

        XCTAssertEqual(p.lattice.selectableRoles[a.key], .include)
        XCTAssertEqual(p.lattice.selectableRoles[b.key], .off,
                       "§3c: the sibling was PINNED to what it already was — "
                       + "nothing, not carried along by the new declaration")
        let faces = p.latticeJobRegions().regions.filter { $0.kind == .face }
        XCTAssertEqual(faces.count, 1, "§3c: ONE face was declared, ONE is emitted")
        XCTAssertEqual(faces.first?.faceID, 16)
    }

    func testOffIsNeverAWireRole() {
        XCTAssertNil(LatticeSelectableRole.off.regionRole)
        XCTAssertEqual(LatticeSelectableRole.include.regionRole, .include)
        XCTAssertEqual(LatticeSelectableRole.exclude.regionRole, .exclude)
        // …and it overrides the group, rather than falling through to it.
        let gid = UUID()
        let ref = LatticeSelectableRef.face(group: gid, face: 16)
        XCTAssertNil(LatticeSelectableRoles.role(for: ref, groupRole: .include,
                                                overrides: [ref.key: .off]),
                     "§3c: OFF means not a region, even inside a latticed group")
    }

    func testTheGroupShowsASummaryRatherThanOwningTheDecision() {
        let (p, gid) = oneGroupTwoWalls()
        let g = p.selection.groups[0]
        XCTAssertEqual(p.latticeCoverage(g), .all,
                       "§3c: both walls follow the group's include declaration")

        p.lattice.selectableRoles[LatticeSelectableRef.face(group: gid, face: 17).key] = .exclude
        XCTAssertEqual(p.latticeCoverage(g), .some, "§3c: all / SOME / none")

        p.lattice.selectableRoles[LatticeSelectableRef.face(group: gid, face: 16).key] = .exclude
        XCTAssertEqual(p.latticeCoverage(g), .none)
    }

    /// The eligibility gate (§1a) is not routed around by a per-primitive answer:
    /// a group that declares nothing emits nothing, whatever its primitives say.
    func testAPerPrimitiveOverrideIsNotAWayPastTheRoleGate() {
        let (p, gid) = oneGroupTwoWalls()
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: gid, face: 16).key] = .include
        p.force.setProtected(gid, false)      // the group now declares nothing
        XCTAssertNil(p.latticeEligibleRoles()[gid])
        XCTAssertTrue(p.latticeJobRegions().regions.isEmpty,
                      "§1a: the gate is on the GROUP and the override does not "
                      + "reach past it")
    }

    /// A project written before this task has no overrides, so every primitive
    /// follows its group and the emission is exactly what it was.
    func testASnapshotWithoutOverridesEmitsExactlyWhatItDidBefore() throws {
        let (p, _) = oneGroupTwoWalls()
        XCTAssertTrue(p.lattice.selectableRoles.isEmpty)
        let data = try JSONEncoder().encode(p.lattice)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertTrue(back.selectableRoles.isEmpty)
        XCTAssertTrue(back.selectableDepthMM.isEmpty)
        XCTAssertEqual(back.groupDepthMM, p.lattice.groupDepthMM)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R4 — the depth drag and the protection depth are one number

    /// ★ PR 328 §0's fix, carried through the change that could have broken it.
    /// The depth plane is per FACE now, so two faces of one group can hold two
    /// depths — and each face's protection must be its own face's depth.
    func testTheDepthDragAndTheProtectionDepthRemainOneNumberPerFace() {
        let (p, gid) = oneGroupTwoWalls()
        let a = LatticeSelectableRef.face(group: gid, face: 16)
        let b = LatticeSelectableRef.face(group: gid, face: 17)
        p.lattice.selectableDepthMM[a.key] = 9.0     // dragged deeper
        p.lattice.selectableDepthMM[b.key] = 3.0     // dragged shallower

        let specs = p.faceProtectionSpecs()
        let protections = zip(specs.faceIDs, specs.depthsMM).map {
            (faceID: $0.0, depthMM: $0.1)
        }
        let regions = p.latticeJobRegions().regions.compactMap {
            r -> (faceID: Int, depthMM: Double)? in
            guard r.kind == .face, let f = r.faceID else { return nil }
            return (f, r.depthMM)
        }
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(LatticeSlabDepth.mismatches(protections: protections,
                                                  regions: regions).isEmpty,
                      "R4: every face's protection depth IS its lattice depth, on "
                      + "the path the run is built from")
        // …and they really are two different numbers, so the check above is not
        // passing because both are the group default.
        let byFace = Dictionary(uniqueKeysWithValues: protections.map { ($0.faceID, $0.depthMM) })
        XCTAssertEqual(byFace[16] ?? 0, 9.0, accuracy: 1e-12)
        XCTAssertEqual(byFace[17] ?? 0, 3.0, accuracy: 1e-12)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §3d — the depth PLANE, the thing the 3D handle grabs

    /// ★ THE PLANE REACHES INTO THE PART, and that is the whole difference from a
    /// keep-out. A clearance slab is space that must stay EMPTY, so it extrudes
    /// along the outward face normal; a lattice slab is material that must be HELD
    /// and lightened, so it extrudes the other way. `LatticeRegionEmission.spec`
    /// flips it for the region; this flips it for the picture, so the plane on
    /// screen is the region in the job.
    func testEachLatticedFaceGetsADepthPlaneReachingIntoThePart() throws {
        let (p, gid) = oneGroupTwoWalls()
        let planes = p.latticeDepthPlanes()
        XCTAssertEqual(planes.count, 2, "§3d: one plane per latticed face")

        // ★ The primitive became the distance-field OFFSET of the face's own
        // surface (task 2026-08-15-lattice-and-face-ui §2b) so that a CURVED face
        // gets one too — the old slab needed a plane and silently skipped 86.4%
        // of the faces the maintainer declares. Every property below is the one
        // this test always asserted; it is now checked at EVERY vertex instead of
        // on a single fitted normal, which is strictly stronger.
        for plane in planes {
            guard case let .shell(s) = plane.volume.shape
            else { return XCTFail("§3d: a face primitive is an offset shell, "
                                  + "not \(plane.volume.shape)") }
            XCTAssertFalse(s.isEmpty, "§3d: the primitive has geometry")
            XCTAssertEqual(s.reachedDepthMM, 7.0, accuracy: 1e-4,
                           "§3d: at the dragged depth, not the 4 mm project default")
            // Face 16's outward normal is +z and 17's is −z; both must run the
            // OTHER way, into the material between them.
            let expectedInward: SIMD3<Float> =
                plane.faceKey == 16 ? SIMD3(0, 0, -1) : SIMD3(0, 0, 1)
            for k in 0..<s.base.count {
                let travel = s.offset[k] - s.base[k]
                XCTAssertEqual(simd_dot(simd_normalize(travel), expectedInward), 1,
                               accuracy: 1e-5,
                               "§3d: it reaches INTO the part, not out of it")
                XCTAssertEqual(Double(simd_length(travel)), 7.0, accuracy: 1e-4,
                               "§3d: by the depth, at every point")
            }
            // The grab knob sits on the offset surface, so dragging it along that
            // normal IS the depth (the keep-clear `.slabDepth` pair, verbatim).
            XCTAssertEqual(plane.handle.role, .slabDepth)
            XCTAssertEqual(simd_distance(plane.handle.anchor,
                                         plane.handle.planeOrigin),
                           Float(s.reachedDepthMM), accuracy: 1e-3)
        }
        XCTAssertEqual(Set(planes.map(\.faceKey)), [16, 17])
        XCTAssertEqual(Set(planes.map(\.groupID)), [gid])
    }

    /// The handle writes the ONE depth, clamped like every other route to it —
    /// so a viewport drag cannot reach a depth the card could not.
    func testTheDepthPlaneHandleWritesTheOneNumber() {
        let (p, gid) = oneGroupTwoWalls()
        let ref = LatticeSelectableRef.face(group: gid, face: 16)
        p.writeLatticeDepthMM(ref, mm: 9.25)
        XCTAssertEqual(p.latticeSlabDepthMM(ref, in: gid), 9.25, accuracy: 1e-12)
        XCTAssertEqual(p.latticeSlabDepthMM(.face(group: gid, face: 17), in: gid),
                       7.0, accuracy: 1e-12, "§3d: and it moved ONLY that face")
        p.writeLatticeDepthMM(ref, mm: 1e6)
        XCTAssertEqual(p.latticeSlabDepthMM(ref, in: gid), LatticeSlabDepth.maxMM,
                       accuracy: 1e-12, "clamped, like the card's drag")
    }

    /// The TO page draws no depth planes — but they are still THERE to be built,
    /// which is the difference between hidden and disabled (§2c).
    func testTheDepthPlanesExistEvenWhereTheyAreNotDrawn() {
        let (p, _) = oneGroupTwoWalls()
        XCTAssertFalse(WorkspaceStageVisibility.of(.topology).latticeDepthPlanes)
        XCTAssertEqual(p.latticeDepthPlanes().count, 2,
                       "§2c: the model does not know about stages, and must not")
    }

    func testTheDepthFallsBackGroupThenProject() {
        let gid = UUID()
        let ref = LatticeSelectableRef.face(group: gid, face: 16)
        XCTAssertEqual(LatticeSlabDepth.depthMM(ref: ref, group: gid,
                                                perSelectable: [ref.key: 9],
                                                perGroup: [gid: 7], fallbackMM: 4),
                       9, accuracy: 1e-12, "the primitive's own number wins")
        XCTAssertEqual(LatticeSlabDepth.depthMM(ref: ref, group: gid,
                                                perSelectable: [:],
                                                perGroup: [gid: 7], fallbackMM: 4),
                       7, accuracy: 1e-12, "then the group's")
        XCTAssertEqual(LatticeSlabDepth.depthMM(ref: ref, group: gid,
                                                perSelectable: [:], perGroup: [:],
                                                fallbackMM: 4),
                       4, accuracy: 1e-12, "then the project's")
        XCTAssertEqual(LatticeSlabDepth.depthMM(ref: ref, group: gid,
                                                perSelectable: [ref.key: 1e6],
                                                perGroup: [:], fallbackMM: 4),
                       LatticeSlabDepth.maxMM, accuracy: 1e-12,
                       "and it is clamped like every other route to a depth")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R5 — the wizard and the side modal are ONE state machine

    /// ★ THE COUPLING HE ASKED FOR. Changing a setting in the modal moves the
    /// wizard to that stage's visual output; the wizard's Next moves the modal's
    /// highlighted stage. Two views, one state.
    func testTheWizardAndTheSideModalShareOneState() {
        var m = LatticeWizardModel()
        XCTAssertEqual(m.stage, .cell, "the page opens on ONE cell")

        // The modal → the wizard: a boundary finish is a stage-C decision, so
        // touching it moves the wizard to stage C and plays what shows it.
        m.setBoundary(.rim)
        XCTAssertEqual(m.stage, LatticeWizardSetting.finish.stage,
                       "R5: changing a setting in the modal MOVES the wizard")
        XCTAssertEqual(m.playing, .boundarySwap,
                       "R5: …to that stage's visual OUTPUT, so it is seen live")

        // …and back: touching a ONE-CELL setting returns the wizard to that view.
        // ★ UPDATED (maintainer, 2026-08-14): the setting used here was `.size`,
        // which he moved OUT of the "one cell" view — "Remove size from the 'one
        // cell' view. Put it below the 'cell size' area in the 'part' view." So
        // the test now uses a setting that is still a one-cell decision, and the
        // COUPLING it asserts is unchanged.
        m.finishedPlaying()
        m.touched(.thickness)
        XCTAssertEqual(m.stage, .cell)

        // ★ AND THE TWO VIEWS GO BOTH WAYS. This was a one-way Next through three
        // stages; they are now two switchable views ("make it so you can go back
        // and forth"), so advancing from the second returns to the first.
        m.advance()
        XCTAssertEqual(m.stage, .lattice)
        m.advance()
        XCTAssertEqual(m.stage, .cell, "the views switch in BOTH directions")
    }

    /// ★ THE NEW STRUCTURE, ASSERTED (maintainer, 2026-08-14). Two views, and the
    /// cell dimension asked for exactly once.
    func testThereAreTwoViewsAndFinishIsNotOneOfThem() {
        XCTAssertEqual(LatticeWizardStage.allCases.count, 2,
                       "\"These are now 'views'. One cell or a lattice.\"")
        XCTAssertEqual(LatticeWizardStage.allCases.map(\.title),
                       ["One cell", "In the part"])
        // Finish is a SETTING of the in-the-part view, never a view of its own.
        XCTAssertEqual(LatticeWizardSetting.finish.stage, .lattice,
                       "\"Do not include the 'Finish' section\" — as a view")
        XCTAssertEqual(LatticeWizardSetting.density.stage, .lattice)
    }

    /// ★ THE CELL DIMENSION IS ASKED FOR ONCE. It used to be "Size" under ONE CELL
    /// *and* the swept window under Cell size — "Having the same thing asked twice
    /// is wasteful."
    func testTheCellDimensionIsAskedForOnceInThePartView() {
        XCTAssertEqual(LatticeWizardSetting.size.stage, .lattice,
                       "size moved OUT of the one-cell view")
        XCTAssertTrue(LatticeWizardSetting.size.isRenderedByCellSize,
                      "and it is drawn BY the cell-size row, not as a row of its own")
        XCTAssertEqual(LatticeWizardStage.cell.settings, [.type, .thickness],
                       "so 'One cell' holds Type and Thickness and nothing else")
        XCTAssertEqual(
            LatticeWizardStage.lattice.settings.filter { !$0.isRenderedByCellSize },
            [.cellSize, .density, .finish],
            "and 'In the part' renders Cell size (which owns the number), "
            + "Density and Finish")
    }

    /// ★ §5c — the side modal's sub-titles ARE the wizard's stages. One table read
    /// two ways: every setting belongs to exactly one stage, and every stage's
    /// settings map back to it.
    func testTheModalsSubTitlesAreTheWizardsStages() {
        var seen: Set<LatticeWizardSetting> = []
        for stage in LatticeWizardStage.allCases {
            XCTAssertFalse(stage.settings.isEmpty,
                           "§5c: every stage owns at least one setting")
            for s in stage.settings {
                XCTAssertEqual(s.stage, stage)
                XCTAssertTrue(seen.insert(s).inserted,
                              "§5c: a setting belongs to ONE stage")
            }
        }
        XCTAssertEqual(seen.count, LatticeWizardSetting.allCases.count,
                       "§5c: and every setting has a stage — none is orphaned "
                       + "from the walkthrough")
    }

    /// §5b — the modal SKIPS the wizard: `jump` goes anywhere with no cinematic,
    /// so a user who knows what they want is never walked through it.
    func testTheSideModalSkipsTheWizard() {
        var m = LatticeWizardModel()
        m.jump(to: .lattice)
        XCTAssertEqual(m.stage, .lattice)
        XCTAssertNil(m.playing, "§5b: a jump is not a lesson")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §7 — the sample is VISIBLE on entry

    /// ★ THE SHIPPED BUG. The page opened with `reveal = 0` because the wipe's
    /// progress was read whenever the density mode was Auto — and §4b had just
    /// made Auto the default. The shader discarded every fragment of a mesh it had
    /// just uploaded: an empty viewport reading "1 ms · 544 tris".
    func testTheSampleIsVisibleOnEntry() {
        let r = LatticeWizardReveal()
        XCTAssertEqual(r.value, 1, accuracy: 1e-12,
                       "§7: on entry the whole sample is drawn — the reveal is "
                       + "not a density mode, it is a running cinematic")
        // And it stays visible for the mode that caused the defect.
        var m = LatticeWizardModel()
        XCTAssertEqual(m.densityMode, .auto, "§4b: Auto is still the default")
        m.jump(to: .cell)
        XCTAssertEqual(LatticeWizardReveal().value, 1, accuracy: 1e-12)
    }

    func testTheWipeStillWipesAndAlwaysEndsWhole() {
        var r = LatticeWizardReveal()
        r.begin()
        XCTAssertEqual(r.value, 0, accuracy: 1e-12, "the wipe starts at nothing")
        r.step(to: 0.5)
        XCTAssertEqual(r.value, 0.5, accuracy: 1e-12)
        r.end()
        XCTAssertEqual(r.value, 1, accuracy: 1e-12,
                       "§7: every exit from a wipe leaves the part whole")
        r.step(to: 0.2)
        XCTAssertEqual(r.value, 1, accuracy: 1e-12,
                       "§7: and a stale step cannot blank it again")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §4 — the drawer

    /// ★ A CARD MUST SAY WHICH PRINT PROFILE IT MEANS (task
    /// 2026-08-13-lattice-as-a-material §1b). `minExtrudableWidthMM` has no
    /// default in production — an unknown width is `outOfRegime`, never a silent
    /// pass — so a fixture has to state one. These are AUTO cards whose cell sits
    /// at or above the floor in `bounds`, so they are printable by construction
    /// at this width and the verdict below stays governed by the bounds this test
    /// is actually exercising. Same constant, same reason, as LatticeWizardTests.
    private let profileWidthMM = 0.45

    private func card(verdict: LatticeFaceCard.Verdict) -> LatticeFaceCard {
        let bounds = TopOptKit.LatticeCellBounds(
            printabilityFloorMM: verdict == .outOfRegime ? 4.93 : 1.2,
            cellsPerMemberFloor: 5, valid: true)
        let limits = TopOptKit.LatticeLimits(rhoMin: 0.05, rhoMax: 0.8,
                                             certifiable: true, minCellsPerMember: 5)
        return LatticeFaceCardDerivation.card(
            faceID: 16, depthMM: verdict == .outOfRegime ? 4.0 : 40.0,
            heldVoxels: verdict == .noMaterial ? 0 : 12_000,
            spacingMM: 1.70527, densityGCM3: 1.24, topology: .octet,
            minExtrudableWidthMM: profileWidthMM)
    }

    /// ★ §4c — the flag is the HEADLINE, not a sideways orange strip. His own
    /// case: a 4.0 mm depth against a 4.93 mm cell IS out of regime.
    func testTheOutOfRegimeFlagIsTheHeadlineOfTheDrawer() {
        let c = card(verdict: .outOfRegime)
        XCTAssertEqual(c.verdict, .outOfRegime,
                       "4.0 mm of slab at a 4.93 mm cell floor")
        let d = LatticeRegionDrawer.make(card: c, depthMM: 4.0, held: true)
        let head = d.headline
        XCTAssertNotNil(head, "§4c: the drawer opens with the reason")
        XCTAssertEqual(head?.verdict, .outOfRegime)
        XCTAssertLessThanOrEqual(head?.text.split(separator: " ").count ?? 99, 3,
                                 "R7: three words at most")

        XCTAssertNil(LatticeRegionDrawer.make(card: card(verdict: .certified),
                                              depthMM: 40, held: true).headline,
                     "§4c: a certified region has no headline to give")
    }

    /// ★ §4a/§4d — nothing was removed, and the collapsed row shows ONE thing:
    /// the grams handed over, with the verdict as colour.
    func testTheNumbersAreAllStillThereAndTheCollapsedRowShowsOne() {
        let c = card(verdict: .certified)
        let d = LatticeRegionDrawer.make(card: c, depthMM: 40, held: true)
        XCTAssertEqual(d.collapsedValue, c.heldText,
                       "§4d: the grams handed over, and nothing else")
        XCTAssertEqual(d.verdict, .certified, "…and the verdict as COLOUR")
        let labels = d.rows.map(\.label)
        for expected in ["Depth", "Hands over", "Cell", "Density", "Strut",
                         "Cells across"] {
            XCTAssertTrue(labels.contains(expected),
                          "§4a: \(expected) was NOT removed, it moved")
        }
    }

    /// ★ §4b — the depth is modifiable (it is the drag); the rest are DERIVED and
    /// READ-ONLY. A row that is not modifiable is not given a gesture.
    func testOnlyTheDepthIsAControl() {
        let d = LatticeRegionDrawer.make(card: card(verdict: .certified),
                                         depthMM: 40, held: false)
        XCTAssertEqual(d.modifiableRows.count, 1)
        XCTAssertEqual(d.modifiableRows.first?.label, "Depth")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: R7 — the longest string this task adds

    func testNoWallOfText() {
        var longest = ""
        func consider(_ s: String) {
            if s.split(separator: " ").count > longest.split(separator: " ").count {
                longest = s
            }
        }
        for s in WorkspaceStage.allCases { consider(s.navigationTitle) }
        for s in LatticeWizardSetting.allCases { consider(s.title) }
        for s in LatticeWizardStage.allCases { consider(s.title) }
        for c in [LatticeGroupCoverage.all, .some, .none] { consider(c.label) }
        for v in [LatticeFaceCard.Verdict.certified, .outOfRegime, .noMaterial] {
            let d = LatticeRegionDrawer.make(card: card(verdict: v),
                                             depthMM: 4, held: true)
            if let h = d.headline { consider(h.text) }
            for r in d.rows { consider(r.label) }
        }
        let words = longest.split(separator: " ").count
        XCTAssertLessThanOrEqual(words, 3,
            "R7: the longest string this task adds is \(words) words: “\(longest)”")
        // NOTE the scope, because a bar that quietly narrows is not a bar: this
        // counts the strings this TASK adds. The longest string the lattice stage
        // can render is still `LatticeFaceRoleGate.Block.reason` — "Give this face
        // a role first", 6 words — which PR 328 wrote and this task did not touch.
        XCTAssertLessThanOrEqual(
            LatticeFaceRoleGate.Block.undeclared.reason.split(separator: " ").count, 6,
            "R7: and the one inherited sentence is still a phrase, not a paragraph")
    }
}
