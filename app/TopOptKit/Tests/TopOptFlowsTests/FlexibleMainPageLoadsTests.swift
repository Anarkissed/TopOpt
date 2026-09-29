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
//     a weight of his own survives a re-sync (RED: a re-sync without weightFrom overwrites it);
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
        // his own weight on a face in no group is never overwritten by a re-sync
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        var s = try XCTUnwrap(r.project.lattice.flexible)
        var own = try XCTUnwrap(s.face(FlexibleHisProject.topA))
        XCTAssertNil(own.weightFrom, "premise: he typed top A's weight before round 3")
        own.weightKg = 7
        s.setFace(own)
        r.project.lattice.flexible = s
        let hm = try await FlexibleHisProject.openedModel(r.project, test: self)
        hm.adoptMainPageLoads()
        XCTAssertEqual(hm.settings.face(FlexibleHisProject.topA)?.weightKg, 7, "his own 7 kg survives")
        // ★ RED CONTROL: a re-sync that ignores weightFrom writes the group's 10 kg over it
        let loads = hm.mainPageLoads
        var naive = hm.settings
        for e in loads.entries.values where e.role == .pressed {
            if var f = naive.face(e.region) { f.weightKg = e.weightKg; naive.setFace(f) }
        }
        XCTAssertEqual(naive.face(FlexibleHisProject.topA)?.weightKg, 10, "control: the naive re-sync overwrites it")
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
