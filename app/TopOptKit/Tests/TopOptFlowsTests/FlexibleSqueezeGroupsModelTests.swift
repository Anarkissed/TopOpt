// FlexibleSqueezeGroupsModelTests — squeeze groups on HIS project 0004 (task
// 2026-09-29-flexible-screens, round 4 batch D2; img 4: "squeeze the sides without squeezing
// the top and bottom … group two sides together … as a different group"; answer 1: ONE force
// per group, written back to the main page loads where it came from).
//   * his faces start in ONE group, its force "Squeeze 10 kg";
//   * the group's force writes back: the main page's Top group and every face of his own —
//     RED: the old per-face weight changed one face;
//   * a stack shared INSIDE a group (a pinch) or ACROSS groups never blocks Exit — RED: the old
//     rule (every conflict blocks);
//   * separate groups are separate squeezes: the lattice carries both, FIRMER wins per voxel,
//     said in one line — RED: min-combine is softer somewhere both groups need;
//   * the player picks a group: only its faces squish (walls and dent), by a faces-only token —
//     RED: unpicked, every face squishes;
//   * the run job says what core cannot run yet (groups, a pinch) — RED: one group, no pinch
//     round-trips.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSqueezeGroupsModelTests: XCTestCase {

    @MainActor
    private func his(_ prepare: (FlexibleStageModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        prepare(m)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
    }

    @MainActor
    private func build(_ m: FlexibleStageModel) async throws -> FlexibleGeneratedLattice {
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        return try XCTUnwrap(m.lattice)
    }

    /// His img 4: the top in group 1, the two sides (3 and 5) in group 2.
    @MainActor
    private func sidesApart(_ m: FlexibleStageModel) {
        m.newGroup(with: 3)
        if let g = m.squeezeGroup(of: 3) { m.moveToGroup(5, g.id) }
    }

    @MainActor
    func testHisFacesStartInOneGroupSqueezedWithTenKg() async throws {
        let (_, m) = try await his()
        let g = m.squeezeGroups
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(Set(g[0].regions), Set([FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]))
        XCTAssertEqual(m.groupForce(g[0]), 10...10)
        XCTAssertEqual(m.groupLine(g[0]), "Group 1 · Top A + 3 more · Squeeze 10 kg")
        XCTAssertEqual(m.sims.map(\.id), ["group-1"])
    }

    @MainActor
    func testTheGroupForceWritesBackToTheMainPage() async throws {
        let (r, m) = try await his()
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        let before = m.settings
        m.setGroupForce(FlexibleSqueezeGroups.first, kg: 12)
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 12, accuracy: 1e-9, "the main page's Top took 12 kg")
        for id in [FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5] {
            XCTAssertEqual(m.settings.face(id)?.weightKg ?? 0, 12, accuracy: 1e-9, "face \(id): every hand presses 12 kg")
        }
        XCTAssertEqual(m.settings.face(FlexibleHisProject.topA)?.weightFrom, top.id, "top A still Top's")
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 12...12)
        // a weight typed on ONE face is the group's force (one force per group)
        m.setWeight(3, kg: 9)
        XCTAssertEqual(m.settings.face(5)?.weightKg ?? 0, 9, accuracy: 1e-9, "the other side of the pinch follows")
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 9, accuracy: 1e-9)
        // ★ RED CONTROL: the OLD per-face write (round 3) changed face 3 alone
        var old = before
        var f3 = try XCTUnwrap(old.face(3)); f3.weightKg = 9; f3.weightFrom = nil; old.setFace(f3)
        XCTAssertEqual(old.face(5)?.weightKg, 10, "control: the old write left face 5 at 10 kg")
    }

    /// A face of his own moved into a group takes that group's ONE force; a face a main-page Load
    /// group presses keeps the main page's weight (the group line says the range).
    @MainActor
    func testAMovedFaceTakesItsNewGroupsForce() async throws {
        let (r, m) = try await his()
        m.newGroup(with: 3)
        let two = try XCTUnwrap(m.squeezeGroup(of: 3))
        m.setGroupForce(two.id, kg: 6)
        XCTAssertEqual(m.settings.face(3)?.weightKg ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(m.settings.face(5)?.weightKg ?? 0, 10, accuracy: 1e-9, "premise: group 1 still 10 kg")
        m.moveToGroup(5, two.id)
        XCTAssertEqual(m.settings.face(5)?.weightKg ?? 0, 6, accuracy: 1e-9, "face 5 joins group 2 at its 6 kg")
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(of: 5))), 6...6)
        // top A (the main page's Top) moved in keeps Top's 10 kg: the group says 6–10 kg
        m.moveToGroup(FlexibleHisProject.topA, try XCTUnwrap(m.squeezeGroup(of: 5)).id)
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 10, accuracy: 1e-9, "the main page is not written by a move")
        let g = try XCTUnwrap(m.squeezeGroup(of: 5))
        XCTAssertEqual(m.groupLine(g), "Group 2 · Top A + 2 more · Squeeze 6–10 kg")
        // ★ RED CONTROL: a move that keeps the face's own weight leaves one group with two forces
        var kept = m.settings
        var f = try XCTUnwrap(kept.face(FlexibleHisProject.topB)); f.squeezeGroup = g.id; kept.setFace(f)
        XCTAssertEqual(kept.face(FlexibleHisProject.topB)?.weightKg, 10, "control: without the rule top B would bring its 10 kg")
    }

    @MainActor
    func testAStackSharedInOrAcrossGroupsNeverBlocks() async throws {
        let (_, m) = try await his()
        XCTAssertEqual(m.pinches.count, 1, "premise: 3 and 5 pinch in group 1")
        XCTAssertTrue(m.readiness.isReady, "a pinch never blocks: \(m.readiness.blocking.map(\.oneLine))")
        XCTAssertFalse(m.readiness.issues.contains { $0.oneLine.contains("same material") })
        sidesApart(m)
        try await settle(m)
        XCTAssertEqual(m.squeezeGroups.count, 2)
        XCTAssertTrue(m.readiness.isReady, "across groups neither: \(m.readiness.blocking.map(\.oneLine))")
        m.newGroup(with: 5)
        try await settle(m)
        XCTAssertEqual(m.squeezeGroups.count, 3)
        XCTAssertEqual(FlexibleSqueezeGroups.acrossGroups(m.conflicts, m.settings).count, 1, "3 and 5 in different groups")
        XCTAssertTrue(m.readiness.isReady)
        // ★ RED CONTROL: the old rule turned his one conflict into the one blocker
        XCTAssertEqual(m.conflicts.count, 1, "control: core still reports the stack the old rule blocked on")
    }

    @MainActor
    func testSeparateGroupsAreSeparateSqueezesAndTheFirmerWins() async throws {
        let (_, m) = try await his { self.sidesApart($0) }
        // ★ D2 REVIEW: the ~24 MB combined field is kept only when a test asks
        m.keepCombinedField = true
        XCTAssertEqual(m.squeezeGroups.map(\.regions.count), [2, 2])
        XCTAssertTrue(m.pinches.count == 1, "3 and 5 still pinch, in group 2")
        XCTAssertTrue(m.groupsShareMaterial, "the top's columns and the sides' cross the same pad")
        let g = try await build(m)
        XCTAssertEqual(g.sims.map(\.id), ["group-1", "group-2", "all"])
        XCTAssertEqual(g.sims[1].title, "Group 2 · Face 3 + Face 5")
        print("FLEX-GROUPS his top | sides: shared voxels \(g.sharedVoxels) · notes \(g.simNotes)")
        XCTAssertGreaterThan(g.sharedVoxels, 0)
        // each group's own field, then the lattice's: the max of the two everywhere
        let keys1 = [FlexibleHisProject.topA, FlexibleHisProject.topB]
        let f1 = try await m.workerForTests.withScene { try $0.densityField(faces: keys1, rotations: [0, 0], build: m.build) }
        let mask = try await m.workerForTests.withScene { try $0.latticeMask(build: m.build) }
        let faces2 = try [3, 5].map { r -> FlexibleGroupField.Face in
            let k = FlexFaceKey(region: r, rotation: 0)
            let s = try XCTUnwrap(m.segments[k])
            return FlexibleGroupField.Face(region: r, stack: try XCTUnwrap(m.stacks[k]), cuts: [], density: s.buildableDensity, cellMM: s.cellMM)
        }
        let f2 = FlexibleGroupField.assemble(mask: mask, faces: faces2)
        let combined = try XCTUnwrap(m.lastCombinedField, "the model keeps the field the lattice was built from")
        var worst: Float = 0, wonBy2 = 0, softerMin = 0
        for n in combined.density.indices where combined.density[n] > -0.5 {
            let want = max(f1.density[n], f2.density[n])
            worst = max(worst, abs(combined.density[n] - want))
            if f2.density[n] > f1.density[n] + 1e-4 { wonBy2 += 1 }
            if min(f1.density[n], f2.density[n]) < want - 1e-4 { softerMin += 1 }
        }
        print("FLEX-GROUPS firmer wins: |combined − max| ≤ \(worst) · group 2 firmer on \(wonBy2) voxels · min-combine softer on \(softerMin)")
        XCTAssertLessThan(worst, 1e-5, "per voxel, the firmer group's density")
        XCTAssertGreaterThan(wonBy2, 0, "each group wins somewhere")
        // ★ RED CONTROL: min-combine is softer where both groups need material
        XCTAssertGreaterThan(softerMin, 0, "control: min-combine softens voxels both groups need")
    }

    @MainActor
    func testThePlayerPicksAGroupAndOnlyItsFacesSquish() async throws {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        // ★ RE-PINNED (round 5 batch G): this pins the COLUMN path's pick — today the fallback while a
        // group's 3D sim runs or when it failed (the sims, once landed, move the whole body by one
        // field: FlexibleSquishSolverTests); held on the column path so the sims landing mid-test
        // cannot race it
        stage.controlColumnSquish = true
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his stacks") { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }
        sidesApart(m)
        try await settle(m)
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertEqual(stage.sims.map(\.id), ["group-1", "group-2", "all"])
        // ★ RE-PINNED (round 5 batch G, his "a way to play the different sims"): the default is
        // "Play all" (D2's was group 1) — group 1 is picked here to pin its faces
        XCTAssertEqual(stage.shownLattice?.shownSim?.kind, .playAll, "the default: Play all")
        stage.pick("group-1")
        stage.refresh()
        let first = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertEqual(Set(first.faces.map(\.load.x)), [0], "group 1: the top's faces (load −Z)")
        stage.pick("group-2")
        stage.refresh()
        let sides = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertEqual(sides.faces.count, 2)
        XCTAssertEqual(Set(sides.faces.map { abs($0.load.x) }), [1], "faces 3 and 5 (load ±X)")
        XCTAssertEqual(sides.token, first.token, "the same lattice: no volume re-upload")
        XCTAssertNotEqual(sides.facesToken, first.facesToken, "a faces-only upload")
        // the dent moves only the sides' map
        let o = try XCTUnwrap(stage.overlay)
        let dents = try XCTUnwrap(stage.dents(r.project, on: .lattice))
        func moved(_ region: Int) -> Int {
            let k = FlexFaceKey(region: region, rotation: 0)
            guard let start = o.flatStart[k], let st = m.stacks[k] else { return 0 }
            // three floats per flat vertex (FlexibleOverlayMesh.displacements)
            return (start..<(start + st.columns.count * 6)).filter { v in
                3 * v + 2 < dents.count && (abs(dents[3 * v]) + abs(dents[3 * v + 1]) + abs(dents[3 * v + 2])) > 1e-6
            }.count
        }
        print("FLEX-PLAYER group 2: dented vertices top A \(moved(FlexibleHisProject.topA)) · face 3 \(moved(3)) · face 5 \(moved(5))")
        XCTAssertEqual(moved(FlexibleHisProject.topA), 0, "the top is not pressed in group 2's squeeze")
        XCTAssertGreaterThan(moved(3), 0)
        XCTAssertGreaterThan(moved(5), 0)
        XCTAssertEqual(stage.fullLabel, "10 kg each")
        stage.pick(FlexibleSim.allID)
        stage.refresh()
        let all = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertEqual(all.faces.count, 4, "Play all on the column path: every face")
        // ★ RED CONTROL: the lattice itself (unpicked) squishes every face
        XCTAssertEqual(try XCTUnwrap(m.lattice).faces.count, 4, "control: without the pick every face squishes")
    }

    @MainActor
    func testTheRunJobSaysWhatCoreCannotRunYet() async throws {
        let (_, m) = try await his()
        XCTAssertThrowsError(try m.runJobJSON(), "one group with a pinch") { XCTAssertEqual($0 as? FlexibleJob.EncodeError, .pinch) }
        sidesApart(m)
        try await settle(m)
        XCTAssertThrowsError(try m.runJobJSON(), "two groups") { XCTAssertEqual($0 as? FlexibleJob.EncodeError, .squeezeGroups) }
        // ★ RED CONTROL: one group, no pinch — core's job round-trips
        m.removeGroup(m.squeezeGroups[1].id)
        m.rest(5)
        try await settle(m)
        XCTAssertEqual(m.squeezeGroups.count, 1)
        XCTAssertTrue(m.pinches.isEmpty)
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(try m.runJobJSON()))
    }
}
