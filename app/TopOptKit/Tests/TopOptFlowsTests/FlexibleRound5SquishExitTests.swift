// FlexibleRound5SquishExitTests — round 5 batch S, the Settings page's squish and its Exit (task
// 2026-09-29-flexible-screens):
//   S2 the SELECTED face's squeeze group squishes on the Settings page, ALONE — its faces' columns
//      while the lattice is behind, its OWN 3D sim when the lattice is current (RED: round 4's page
//      dented every group's faces at once);
//   S9 "Exit" with nothing changed leaves the main page exactly as it was — no rebuild (a failed
//      build is not retried), no restart of the squish, no new sim (RED: Save & Exit's path retries);
//      Save & Exit with the Lattice view OFF only stores, and the bake runs when the view is turned
//      on (RED: with the view on, the same Save & Exit bakes). ★ S VERIFICATION: Exit with nothing
//      changed, the view off and opened by the view button, leaves the view off and nothing deferred
//      (RED: Save & Exit's path turns it on) — the test that goes red without the early return; the
//      "leaves the main page alone" numbers do not (with a current lattice that path shows nothing).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleRound5SquishExitTests: XCTestCase {

    // MARK: - S2

    /// Per face key: the largest displacement (mm) of its column quads in `dents`.
    @MainActor
    static func quadMotion(_ dents: [Float], overlay o: FlexibleOverlayMesh, model m: FlexibleStageModel) -> [Int: Float] {
        var out: [Int: Float] = [:]
        for (k, start) in o.flatStart {
            guard let st = m.stacks[k] else { continue }
            var mx: Float = 0
            for v in start..<min(start + st.columns.count * 6, dents.count / 3) {
                mx = max(mx, simd_length(SIMD3(dents[3 * v], dents[3 * v + 1], dents[3 * v + 2])))
            }
            out[k.region] = mx
        }
        return out
    }

    @MainActor
    func testOnlyTheSelectedFacesGroupSquishesOnTheSettingsPage() async throws {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        m.newGroup(with: 3)   // his img 4's split: Face 3 its own squeeze
        try await FlexibleSquishFixture.settle(m, "his 0004 split")
        try await FlexibleHisProject.waitFor(30, "the drawn maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let a = FlexibleHisProject.topA
        var report: [String] = []
        for (sel, mine) in [(a, Set([a, FlexibleHisProject.topB, 5])), (3, Set([3]))] {
            m.select(sel)
            let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
            XCTAssertFalse(sq.fe, "no lattice yet: the column preview")
            // ★ S VERIFICATION: …and the player says why
            XCTAssertEqual(FlexibleSettingsSquish.note(model: m, fe: sq.fe), FlexibleRowCopy.settingsColumnNoLattice)
            XCTAssertEqual(sq.groupNumber, m.squeezeGroup(of: sel)?.number)
            let moved = Self.quadMotion(try XCTUnwrap(sq.dents), overlay: o, model: m)
            let all = Self.quadMotion(try XCTUnwrap(c.dents), overlay: o, model: m)
            report.append("\(m.faceName(sel)) selected: " + moved.sorted { $0.key < $1.key }.map { "\(m.faceName($0.key)) \(String(format: "%.2f", $0.value))" }.joined(separator: " · ")
                          + " | round 4: " + all.sorted { $0.key < $1.key }.map { "\(m.faceName($0.key)) \(String(format: "%.2f", $0.value))" }.joined(separator: " · "))
            for (region, d) in moved {
                if mine.contains(region) { XCTAssertGreaterThan(d, 0.05, "\(m.faceName(region)) is in the playing group: it dents") }
                else { XCTAssertEqual(d, 0, "\(m.faceName(region)) is another group's: it stands still") }
            }
            // ★ RED CONTROL: round 4's page dented every group's faces at once
            XCTAssertTrue(all.filter { !mine.contains($0.key) }.values.contains { $0 > 0.05 }, "control: the old dent moved the other group too")
        }
        print("FLEX-R5 S2 column:\n  " + report.joined(separator: "\n  "))
    }

    /// The lattice current and each group's sim landed: the Settings page plays the SELECTED face's
    /// group's own 3D field (the part's sides move with it), and another group's when its face is picked.
    @MainActor
    func testTheSelectedGroupsOwnSimMovesTheSettingsPage() async throws {
        let (_, m) = try await FlexibleSquishFixture.his(self, "his 0004 split") { m in m.newGroup(with: 3) }
        XCTAssertEqual(m.squeezeGroups.count, 2)
        let g1 = try XCTUnwrap(m.squish[FlexibleSim.groupID(1)]?.field), g2 = try XCTUnwrap(m.squish[FlexibleSim.groupID(2)]?.field)
        m.select(FlexibleHisProject.topA)
        let edge = try XCTUnwrap(FlexibleSettingsSquish.overlayEdge(model: m), "the overlay is cut to the sim's grid")
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: edge))
        var cache: (key: String, dents: [Float])?
        let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        let s1 = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        XCTAssertTrue(s1.fe, "the lattice is current: the group's 3D sim")
        XCTAssertEqual(try XCTUnwrap(s1.dents), g1.meshDisplacements(positions: o.mesh.flat.positions), "Group 1's OWN field")
        m.select(3)
        let s2 = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        XCTAssertEqual(s2.groupNumber, 2)
        XCTAssertEqual(try XCTUnwrap(s2.dents), g2.meshDisplacements(positions: o.mesh.flat.positions), "Group 2's own field")
        let diff = zip(try XCTUnwrap(s1.dents), try XCTUnwrap(s2.dents)).map { abs($0 - $1) }.max() ?? 0
        print(String(format: "FLEX-R5 S2 FE: k %.2f / %.2f · the two groups' fields differ by up to %.3f mm", s1.exaggeration, s2.exaggeration, diff))
        XCTAssertGreaterThan(diff, 0.1, "control: the two groups are two different squeezes")
        // an edit puts the lattice behind: the column preview at once (never a stale field)
        m.edit { s in guard var f = s.face(3) else { return }; f.deepestMM = 2; s.setFace(f) }
        XCTAssertTrue(m.latticeIsStale)
        XCTAssertNil(FlexibleSettingsSquish.overlayEdge(model: m))
        let s3 = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        XCTAssertFalse(s3.fe, "behind the settings: the column preview")
        XCTAssertEqual(FlexibleSettingsSquish.note(model: m, fe: true), FlexibleRowCopy.settingsSimNote)
        // ★ S VERIFICATION: the column preview after an edit SAYS so, and what brings the fold back
        // (round 5's page changed character with no word — its note was nil here)
        XCTAssertEqual(FlexibleSettingsSquish.note(model: m, fe: s3.fe), FlexibleRowCopy.settingsColumnEdited)
    }

    // MARK: - S9

    /// C1's plain pad under a main stage, its lattice built through Save & Exit.
    @MainActor
    private func padStage(persisted: @escaping () -> Void = {}) async throws -> (FlexibleMainStage, FlexibleStageModel, ProjectModel) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                            persist: persisted)
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        _ = m.press(FlexibleHisProject.topFace(mesh), kg: 20)
        m.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleSquishFixture.settle(m, "pad")
        return (stage, m, pm)
    }

    /// Settings opens over the main page, then closes (Exit or Save & Exit), as H2 and H3 do.
    @MainActor
    private func visitSettings(_ stage: FlexibleMainStage, _ pm: ProjectModel, unchanged: Bool, edit: () -> Void = {}) {
        stage.apply(pm, owned: true, pageUp: true)
        edit()
        if unchanged { stage.model?.exitUnchanged = true } else { stage.model?.save() }
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
    }

    @MainActor
    func testExitWithNothingChangedLeavesTheMainPageAlone() async throws {
        var saves = 0
        let (stage, m, pm) = try await padStage(persisted: { saves += 1 })
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        try await FlexibleHisProject.waitFor(300, "the sims") { stage.refresh(); return !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        stage.refresh()
        let gen = try XCTUnwrap(m.lattice?.generation)
        let pictureGen = stage.generation, playing = stage.loop.playing, squish = m.squish, savesBefore = saves
        XCTAssertTrue(playing, "premise: the squish plays")
        // Exit, nothing changed
        visitSettings(stage, pm, unchanged: true)
        await m.waitForIdle()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await m.waitForIdle()
        stage.refresh()
        print("FLEX-R5 S9 exit: lattice gen \(gen) → \(m.lattice?.generation ?? -1) · picture gen \(pictureGen) → \(stage.generation) · playing \(playing) → \(stage.loop.playing) · saves \(savesBefore) → \(saves)")
        XCTAssertEqual(m.lattice?.generation, gen, "no rebuild")
        XCTAssertEqual(m.squish, squish, "no re-solve")
        XCTAssertEqual(stage.loop.playing, playing, "the squish keeps playing — no restart")
        XCTAssertEqual(stage.generation, pictureGen, "the main page's picture did not change")
        XCTAssertEqual(saves, savesBefore, "nothing saved")
        XCTAssertFalse(m.exitUnchanged, "the flag is read once")
    }

    /// ★ S VERIFICATION: an Exit-unchanged case where the Save & Exit path VISIBLY acts — the
    /// Lattice view off, and Settings opened by the view button (Save & Exit turns the view on and
    /// marks the bake deferred). The test above passed with the early return removed (with a
    /// current lattice the Save & Exit path changes nothing visible); this one goes RED.
    @MainActor
    func testExitWithNothingChangedLeavesTheViewOffAndNothingDeferred() async throws {
        let (stage, m, pm) = try await padStage()
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        stage.latticeOn = false
        stage.showLatticeOnExit = true   // as the Lattice view button opens Settings
        visitSettings(stage, pm, unchanged: true)
        await m.waitForIdle()
        print("FLEX-R5V S9 exit, view off: latticeOn \(stage.latticeOn) · deferred \(m.latticeBuildDeferred) · showOnExit \(stage.showLatticeOnExit)")
        XCTAssertFalse(stage.latticeOn, "Exit with nothing changed: the view stays off")
        XCTAssertFalse(m.latticeBuildDeferred, "…and nothing is left for it to bake")
        XCTAssertFalse(stage.showLatticeOnExit, "…and the button's request is spent")
        // ★ RED CONTROL: Save & Exit from the same state turns the view on
        stage.showLatticeOnExit = true
        visitSettings(stage, pm, unchanged: false)
        XCTAssertTrue(stage.latticeOn, "control: Save & Exit turns the view on")
    }

    @MainActor
    func testExitWithNothingChangedDoesNotRetryAFailedBuild() async throws {
        let (stage, m, pm) = try await padStage()
        m.controlFailBuild = "first failure"
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the failed build") { m.latticeFailure != nil }
        m.controlFailBuild = "second failure"
        visitSettings(stage, pm, unchanged: true)
        try await Task.sleep(nanoseconds: 800_000_000)
        await m.waitForIdle()
        XCTAssertEqual(m.latticeFailure, "first failure", "Exit (nothing changed) never re-bakes")
        // ★ RED CONTROL: Save & Exit asks for the build again (a failed one is tried once more)
        visitSettings(stage, pm, unchanged: false)
        try await FlexibleHisProject.waitFor(60, "the retried build") { m.latticeFailure == "second failure" }
        XCTAssertEqual(m.latticeFailure, "second failure", "control: Save & Exit re-bakes")
    }

    @MainActor
    func testSaveAndExitWithTheLatticeViewOffOnlyStores() async throws {
        let (stage, m, pm) = try await padStage()
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        let gen = try XCTUnwrap(m.lattice?.generation)
        stage.latticeOn = false
        let top = try XCTUnwrap(m.settings.loadedFaces.first?.faceRegionID)
        visitSettings(stage, pm, unchanged: false) {
            m.edit { s in guard var f = s.face(top) else { return }; f.deepestMM = 2; s.setFace(f) }
        }
        try await FlexibleSquishFixture.settle(m, "the edit's designs")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await m.waitForIdle()
        XCTAssertTrue(m.latticeIsStale, "stored, not baked")
        XCTAssertFalse(m.latticeBuilding)
        XCTAssertEqual(m.lattice?.generation, gen)
        XCTAssertEqual(FlexibleMainStatus.of(model: m).line, FlexibleMainStatus.deferred, "the pill says so")
        // the view on: the bake runs
        stage.latticeOn = true
        try await FlexibleHisProject.waitFor(120, "the deferred bake") { m.lattice?.generation != gen && !m.latticeBuilding && !m.latticeIsStale }
        XCTAssertFalse(m.latticeBuildDeferred)
        // ★ RED CONTROL: with the view ON the same Save & Exit bakes at once
        let gen2 = try XCTUnwrap(m.lattice?.generation)
        visitSettings(stage, pm, unchanged: false) {
            m.edit { s in guard var f = s.face(top) else { return }; f.deepestMM = 2.5; s.setFace(f) }
        }
        try await FlexibleHisProject.waitFor(120, "the bake") { m.lattice?.generation != gen2 && !m.latticeBuilding }
        XCTAssertNotEqual(m.lattice?.generation, gen2, "control: the view on bakes on Save & Exit")
    }
}
