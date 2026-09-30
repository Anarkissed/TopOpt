// FlexibleMainPageLoadsTests — "weight comes from the main page" (task
// 2026-09-29-flexible-screens, round 3, item 1.2; maintainer: the weight is EDITABLE on the
// Flexible page and WRITES BACK to the main-page group — one source of truth, the group).
//   * HIS project: Top (region 103 = top A, 10 kg gravity) ⇒ sector 1000103 pressed at 10 kg;
//     bottom (anchor) ⇒ face 0 rests; top B is in no group ⇒ ask. RED CONTROL: a mapping
//     without sectors presses the WHOLE face 1 at 10 kg;
//   * the area split: a group over a 60 / 40 split gives 6 / 4 kg and sums to the group.
//     RED CONTROL: an equal split;
//   * a pull, or gravity on a side face, is ASKED, never mapped;
//   * a tap only selects (img 8: seven faces pressed at 10 kg by tapping around);
//   * a typed weight on an inherited face writes back to the group and the split re-syncs;
//     a weight of his own on a face in NO group survives a re-sync; a face a group presses is
//     ALWAYS linked — HIS top A (an old tap's 10 kg) reads "10 kg from Top" and writes back
//     (RED: the rule that skipped unlinked faces kept two truths);
//   * [Rests] chosen here survives a write-back and a re-open; the trash is refused for a
//     face a group holds; the number pad commits once, when it closes;
//   * the Flexible job carries loads.build_dir = −gravity (core defaulted to +Z; RED control).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleMainPageLoadsTests: XCTestCase {

    @MainActor
    static func derive(_ pm: ProjectModel) -> FlexibleMainPageLoads {
        let mesh = pm.viewerMesh!
        return FlexibleMainPageLoads.derive(groups: pm.selection.groups, force: pm.force, faceRegions: pm.faceRegions,
                                            mesh: mesh, regions: FlexibleRegions(model: pm.faceRegions, mesh: mesh))
    }

    @MainActor
    func testHisTopGroupPressesTopAAndTheBottomRests() throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let pm = r.project
        let top = try XCTUnwrap(pm.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(top.regionIDs, [103], "premise: his Top group is region 103 (top A)")
        let loads = Self.derive(pm)
        let a = try XCTUnwrap(loads.entry(FlexibleHisProject.topA))
        XCTAssertEqual(a.role, .pressed)
        XCTAssertEqual(a.weightKg, 10, accuracy: 1e-9)
        XCTAssertEqual(a.groupID, top.id)
        XCTAssertEqual(a.pressFraction, 1, accuracy: 1e-6, "gravity (0,0,−1) straight into the top")
        XCTAssertEqual(loads.entry(0)?.role, .rests, "the bottom anchor rests")
        XCTAssertNil(loads.entry(FlexibleHisProject.topB), "top B is in no group: ask")
        XCTAssertNil(loads.entry(1), "the whole top face is not pressed — only its sector")
        // ★ RED CONTROL: a mapping that ignores sectors (a region → its member faces) would
        // press the WHOLE top face at 10 kg
        let region = try XCTUnwrap(pm.faceRegions.region(103))
        let naive = FaceRegionGeometry.members(of: region, in: try XCTUnwrap(pm.viewerMesh)).map { Int($0) }
        XCTAssertEqual(naive, [1], "control: without the sector mapping the whole face 1 is pressed")
    }

    /// A pad whose top is split at x = 60 (a 4000 / 6000 mm² pair), one Load group over both.
    @MainActor
    static func split60(direction: LoadDirection = .gravity) throws -> (ProjectModel, [Int], UUID) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        var model = FaceRegionModel()
        let whole = model.union(faces: [FaceID(top)], named: "top")
        let kids = model.splitManual(whole, point: SIMD3(60, 50, 20), normal: SIMD3(1, 0, 0))
        pm.faceRegions = model
        let g = pm.selection.addGroup()
        pm.selection.addRegions(kids, to: g)
        pm.force.makeLoad(g)
        pm.force.setWeight(g, kg: 10)
        if direction != .gravity { pm.force.setDirection(g, direction) }
        pm.force.setGravity(direction: SIMD3(0, 0, -1))
        return (pm, kids.map { FlexibleRegions.sectorBase + $0 }, g)
    }

    @MainActor
    func testAGroupsWeightIsSplitByArea() throws {
        let (pm, ids, _) = try Self.split60()
        let loads = Self.derive(pm)
        let w = try ids.map { try XCTUnwrap(loads.entry($0)).weightKg }
        let shares = try ids.map { try XCTUnwrap(loads.entry($0)).share }
        print("FLEX-LOADS 60/40 split, 10 kg: \(w) kg, shares \(shares)")
        XCTAssertEqual(w.reduce(0, +), 10, accuracy: 1e-9, "the parts sum to the group")
        XCTAssertEqual(Set(w.map { ($0 * 1000).rounded() / 1000 }), [4, 6], "split by area, 4000 / 6000 mm²")
        XCTAssertTrue(ids.allSatisfy { loads.entry($0)?.groupRegions == 2 })
        // ★ RED CONTROL: an equal split gives 5 / 5
        XCTAssertFalse(w.contains { abs($0 - 5) < 1e-6 }, "control: not an equal split")
    }

    @MainActor
    func testAPullOrASidewaysLoadIsAskedNeverMapped() throws {
        let (pull, ids, _) = try Self.split60(direction: .pull)
        let lp = Self.derive(pull)
        XCTAssertTrue(ids.allSatisfy { lp.entry($0)?.role == .ask && lp.entry($0)?.weightKg == 0 }, "a pull is not a squish")
        // gravity on a side face (the pad's x = 100 side)
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        var side: FaceID = -1
        for t in 0..<mesh.triangleCount {
            let x = (0..<3).map { mesh.positions[Int(mesh.indices[3 * t + $0]) * 3] }
            if x.allSatisfy({ abs($0 - 100) < 1e-3 }) { side = mesh.faceIDs[t]; break }
        }
        let g = pm.selection.addGroup()
        pm.selection.addFaces([side], to: g)
        pm.force.makeLoad(g)
        pm.force.setGravity(direction: SIMD3(0, 0, -1))
        let ls = Self.derive(pm)
        let e = try XCTUnwrap(ls.entry(Int(side)))
        XCTAssertEqual(e.role, .ask, "gravity along a side face shears it — asked, not mapped")
        XCTAssertEqual(e.weightKg, 0)
        XCTAssertEqual(e.pressFraction, 0, accuracy: 1e-6)
    }

    /// ★ A TAP ONLY SELECTS (img 8: tapping around pressed seven faces at 10 kg each).
    @MainActor
    func testATapOnlySelects() async throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        // face 3 not marked yet (his project pressed it by tapping; here it is fresh)
        var s = try XCTUnwrap(r.project.lattice.flexible)
        s.removeFace(3)
        r.project.lattice.flexible = s
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        let before = m.settings.faces
        XCTAssertNil(m.settings.face(3), "premise: face 3 is not marked")
        m.tapFace(3)
        XCTAssertEqual(m.selectedRegion, 3)
        m.tapFace(1, point: SIMD3(20, 50, 20))
        XCTAssertEqual(m.selectedRegion, FlexibleHisProject.topB, "a split face selects the sector under the finger")
        XCTAssertEqual(m.settings.faces.map(\.faceRegionID), before.map(\.faceRegionID), "no face was added by a tap")
        XCTAssertEqual(m.settings.faces.map(\.role), before.map(\.role), "…or pressed")
    }

    /// Adopt: his Top's weight arrives on top A (inherited); a weight of his own survives;
    /// a typed weight on an inherited face writes back to the group and the split re-syncs.
    @MainActor
    func testWeightsInheritWriteBackAndHisOwnSurvive() async throws {
        let (pm, ids, g) = try Self.split60()
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        m.adoptMainPageLoads()
        let a = try XCTUnwrap(m.settings.face(ids[0])), b = try XCTUnwrap(m.settings.face(ids[1]))
        XCTAssertEqual(a.weightFrom, g); XCTAssertEqual(b.weightFrom, g)
        XCTAssertEqual(a.weightKg + b.weightKg, 10, accuracy: 1e-9)
        // the write-back: 8 kg typed on the larger sector ⇒ the group becomes 8 / 0.6
        let big = a.weightKg > b.weightKg ? ids[0] : ids[1], small = big == ids[0] ? ids[1] : ids[0]
        m.setWeight(big, kg: 8)
        XCTAssertEqual(pm.force.kind(for: g).weightKg ?? 0, 8 / 0.6, accuracy: 1e-6, "the group took the weight")
        XCTAssertEqual(m.settings.face(big)?.weightKg ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(m.settings.face(small)?.weightKg ?? 0, 8 / 0.6 * 0.4, accuracy: 1e-6, "the split re-synced")
        // ★ RE-PINNED (verification of round 3): "his own weight" is a face in NO group (top B);
        // a face a Load group presses is ALWAYS linked — one source of truth, the group
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        var s = try XCTUnwrap(r.project.lattice.flexible)
        var a7 = try XCTUnwrap(s.face(FlexibleHisProject.topA)), b7 = try XCTUnwrap(s.face(FlexibleHisProject.topB))
        a7.weightKg = 7; b7.weightKg = 7
        s.setFace(a7); s.setFace(b7)
        r.project.lattice.flexible = s
        let hm = try await FlexibleHisProject.openedModel(r.project, test: self)
        XCTAssertEqual(hm.settings.face(FlexibleHisProject.topB)?.weightKg, 7, "his own 7 kg on top B (no group) survives")
        XCTAssertNil(hm.settings.face(FlexibleHisProject.topB)?.weightFrom)
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(hm.settings.face(FlexibleHisProject.topA)?.weightKg, 10, "top A takes Top's 10 kg")
        XCTAssertEqual(hm.settings.face(FlexibleHisProject.topA)?.weightFrom, top.id)
        XCTAssertEqual(hm.relinkedWeights[FlexibleHisProject.topA], 7, "…and the panel says it was 7 kg")
        XCTAssertEqual(FlexibleRowCopy.relinked(oldKg: 7, group: "Top"), "Was 7 kg · now Top's weight")
        // ★ RED CONTROL: the rule that skipped every unlinked face left top A at 7 kg, unlinked,
        // while the main run pressed it with 10 — two sources of truth
        var builder = s
        for e in hm.mainPageLoads.entries.values where e.role == .pressed {
            guard var f = builder.face(e.region), f.weightFrom != nil else { continue }
            f.weightKg = e.weightKg; builder.setFace(f)
        }
        XCTAssertEqual(builder.face(FlexibleHisProject.topA)?.weightKg, 7, "control: the old rule kept two truths")
        XCTAssertNil(builder.face(FlexibleHisProject.topA)?.weightFrom)
    }

    /// ★ HIS PROJECT AS SAVED (verification of round 3): top A — pressed by an old tap at the
    /// 10 kg default, weightFrom nil — reads "10 kg from Top", and a weight typed on it
    /// changes the Top group (one source of truth).
    @MainActor
    func testHisTopAReadsFromTopAndATypedWeightChangesTheGroup() async throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let raw = try XCTUnwrap(r.project.lattice.flexible?.face(FlexibleHisProject.topA))
        XCTAssertNil(raw.weightFrom, "premise: saved before round 3, unlinked")
        XCTAssertEqual(raw.weightKg, 10, "premise: the old tap's 10 kg default")
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        let a = try XCTUnwrap(m.settings.face(FlexibleHisProject.topA))
        XCTAssertEqual(a.weightFrom, top.id, "linked to Top")
        let line = FlexibleRowCopy.weight(face: a, entry: m.mainPageLoads.entry(FlexibleHisProject.topA))
        print("FLEX-LOADS his top A row: '\(line)'")
        XCTAssertEqual(line, "10 kg from Top")
        XCTAssertNil(m.relinkedWeights[FlexibleHisProject.topA], "the same 10 kg: nothing to say")
        // the faces no group holds keep what he had (top B, faces 3 and 5)
        for id in [FlexibleHisProject.topB, 3, 5] {
            XCTAssertEqual(m.settings.face(id)?.isLoaded, true)
            XCTAssertNil(m.settings.face(id)?.weightFrom)
        }
        m.setWeight(FlexibleHisProject.topA, kg: 4)
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 4, accuracy: 1e-9, "the Top group took 4 kg")
        XCTAssertEqual(m.settings.face(FlexibleHisProject.topA)?.weightKg ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(m.settings.face(FlexibleHisProject.topA)?.weightFrom, top.id, "still linked")
        // ★ RED CONTROL: unlinked (the round-3 build on his project), the row read "10 kg" and a
        // typed weight stayed on the Flexible page
        XCTAssertEqual(FlexibleRowCopy.weight(face: raw, entry: m.mainPageLoads.entry(FlexibleHisProject.topA)), "10 kg")
    }

    /// ★ [Rests] ON A FACE A GROUP PRESSES IS HIS CHOICE: it survives a write-back on another
    /// face of the group and a re-open, and the panel says the main page still presses it.
    @MainActor
    func testRestsSurvivesAWriteBackAndAReopen() async throws {
        let (pm, ids, g) = try Self.split60()
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        m.adoptMainPageLoads()
        m.rest(ids[0])
        XCTAssertEqual(m.settings.face(ids[0])?.role, "resting")
        XCTAssertNil(m.settings.face(ids[0])?.weightFrom, "his choice: unlinked")
        m.setWeight(ids[1], kg: 3)                      // a write-back on the OTHER face
        XCTAssertNotEqual(pm.force.kind(for: g).weightKg ?? 0, 10, "premise: the group was written")
        XCTAssertEqual(m.settings.face(ids[0])?.role, "resting", "Rests survives a write-back")
        let again = try await FlexibleHisProject.openedModel(pm, test: self)
        XCTAssertEqual(again.settings.face(ids[0])?.role, "resting", "…and a re-open")
        XCTAssertEqual(again.mainPageLoads.entry(ids[0])?.role, .pressed, "the main page still presses it")
        XCTAssertEqual(FlexibleRowCopy.pressedOnMainPage(group: "Top"), "Top presses it on the main page")
        // [Pressed] links it again
        XCTAssertTrue(again.press(ids[0]))
        XCTAssertEqual(again.settings.face(ids[0])?.weightFrom, g)
        // ★ RED CONTROL: Rests that kept the link (the round-3 build) was pressed again by the
        // next re-sync
        var kept = again.settings
        var f = try XCTUnwrap(kept.face(ids[0])); f.role = "resting"; kept.setFace(f)
        XCTAssertNotNil(f.weightFrom)
        again.mainPageLoads.adopt(into: &kept)
        XCTAssertEqual(kept.face(ids[0])?.role, "loaded", "control: a linked Rests is undone by the re-sync")
    }

    /// ★ THE TRASH IS NOT OFFERED FOR A FACE A GROUP HOLDS (it came back at the next open).
    @MainActor
    /// ★ RE-PINNED (round 5, S6 — his img 3: "For some reason, top A/B are not deletable. All faces
    /// should be deletable."): round 3's rule refused the trash for a face a main-page group holds
    /// (the re-sync brought it back). Now every face is deletable and a held one is REMEMBERED as
    /// deleted, so the re-sync skips it; the main page's group is untouched.
    func testTheTrashDeletesAFaceAGroupHoldsAndTheReSyncLeavesItDeleted() async throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        XCTAssertFalse(m.mainPageLoads.canRemove(FlexibleHisProject.topA), "premise: Top presses top A")
        XCTAssertTrue(m.removeFace(FlexibleHisProject.topA), "deleted")
        XCTAssertNil(m.settings.face(FlexibleHisProject.topA))
        XCTAssertFalse(m.mainPageLoads.canRemove(0), "premise: the bottom anchor holds face 0")
        XCTAssertTrue(m.removeFace(0))
        XCTAssertTrue(m.removeFace(FlexibleHisProject.topB), "top B is in no group: removed")
        XCTAssertNil(m.settings.face(FlexibleHisProject.topB))
        m.adoptMainPageLoads()
        XCTAssertNil(m.settings.face(FlexibleHisProject.topA), "the re-sync leaves it deleted")
        XCTAssertNil(m.settings.face(0))
        // ★ RED CONTROL: without the remembered deletion, the re-sync brings top A straight back
        var s = m.settings
        s.removedRegions = nil
        m.mainPageLoads.adopt(into: &s)
        XCTAssertEqual(s.face(FlexibleHisProject.topA)?.role, "loaded", "control: the group re-adds it")
        // the panel's trash is on every face (source pin)
        let panel = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleFacePanel.swift"), encoding: .utf8)
        XCTAssertFalse(panel.contains("if model.mainPageLoads.canRemove(r) {"))
    }

    /// ★ THE NUMBER PAD COMMITS ONCE, WHEN IT CLOSES: typing "12" on an inherited face wrote 1 kg
    /// then 12 kg to the main-page group (and a first digit that marked a face tore its pad
    /// down). RED CONTROL: the live path writes the intermediate 1 kg to the group.
    @MainActor
    func testThePadCommitsOnceWhenItCloses() async throws {
        var b = FlexPadBuffer()
        b.typed(1); b.typed(12)
        XCTAssertEqual(b.closed(), 12)
        XCTAssertNil(b.closed(), "committed once")
        b.typed(3); b.typed(nil)
        XCTAssertNil(b.closed(), "an emptied field commits nothing")
        b.typed(0)
        XCTAssertNil(b.closed(), "nor does 0")
        // the group sees only the final number
        let (pm, ids, g) = try Self.split60()
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        m.adoptMainPageLoads()
        let big = (m.settings.face(ids[0])?.weightKg ?? 0) > (m.settings.face(ids[1])?.weightKg ?? 0) ? ids[0] : ids[1]
        var seen: [Double] = []
        var pad = FlexPadBuffer()
        for v in [1.0, 12.0] { pad.typed(v) }
        if let v = pad.closed() { m.setWeight(big, kg: v); seen.append(pm.force.kind(for: g).weightKg ?? 0) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0], 12 / 0.6, accuracy: 1e-6)
        // ★ RED CONTROL: live, every keystroke reached the group
        var live: [Double] = []
        for v in [1.0, 12.0] { m.setWeight(big, kg: v); live.append(pm.force.kind(for: g).weightKg ?? 0) }
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live[0], 1 / 0.6, accuracy: 1e-6, "control: the intermediate 1 kg was written")
        // source pin: every pad on the panel goes through the commit-on-close modifier
        let panel = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleFacePanel.swift"), encoding: .utf8)
        XCTAssertEqual(panel.components(separatedBy: ".numberPad(").count - 1, 1, "only FlexPadCommit opens the pad")
        // ★ RE-PINNED (round 5, S3): the pencil pills are gone — the ask pad is the panel's one
        // FlexPadCommit; every number is a FlexNumberBox, which commits ONCE as its keypad closes too
        XCTAssertEqual(panel.components(separatedBy: ".modifier(FlexPadCommit(").count - 1, 1, "the ask pad")
        let box = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleNumberBox.swift"), encoding: .utf8)
        XCTAssertEqual(box.components(separatedBy: ".numberPad(").count - 1, 1)
        XCTAssertTrue(box.contains("if !open, let v = buffer.closed(spec)"), "the box commits once, as its keypad closes")
    }

    /// ★ loads.build_dir = −gravity reaches core's scene. RED CONTROL: without it, core's +Z.
    func testTheBuildDirectionReachesCore() throws {
        var i = FlexibleStageTests.inputs(FlexibleStageSettings(materialID: "varioshore_tpu"))
        i.buildDir = SIMD3(-1, 0, 0)          // gravity +X: "up" is −X
        let json = try FlexibleJob.sceneJobJSON(i, fallbackMaterial: "varioshore_tpu")
        let doc = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let loads = doc["loads"] as! [String: Any]
        XCTAssertEqual(loads["build_dir"] as? [Double], [-1, 0, 0])
        let info = try FlexibleScene(jobJSON: json, jobDir: "/").info()
        XCTAssertEqual(info.buildDir.x, -1, accuracy: 1e-9)
        var none = i
        none.buildDir = nil
        let base = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(none, fallbackMaterial: "varioshore_tpu"), jobDir: "/").info()
        XCTAssertEqual(base.buildDir.z, 1, accuracy: 1e-9, "control: without it core assumes +Z")
        // the plate direction, when declared, goes at the ROOT (core prefers it)
        var plate = i
        plate.plateDir = SIMD3(0, 1, 0)
        let pdoc = try JSONSerialization.jsonObject(with: Data(try FlexibleJob.sceneJobJSON(plate, fallbackMaterial: "varioshore_tpu").utf8)) as! [String: Any]
        XCTAssertEqual(pdoc["build_direction"] as? [Double], [0, 1, 0])
    }
}
