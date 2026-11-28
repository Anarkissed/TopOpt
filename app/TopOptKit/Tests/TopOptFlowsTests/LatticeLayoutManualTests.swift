// LatticeLayoutManualTests — Install 2, the Manual controls (00-proposal.md "Manual controls for engineers — DECIDED"; his
// pick 11-14: 1, 2, 4, 5, 6, 7, 8, for the part and per zone or region):
//   * each part control reaches the new engine's settings, and only where the engine reads it (CONTROLS: Auto sends what
//     it sent before; strut widths only under By stress; the size step only on Default Grade; rim width only under Rim);
//   * an area's own controls reach its own regions only (control: the other areas state nothing);
//   * Auto writes nothing to the project (older bytes unchanged) and a set control round-trips;
//   * an area's own survives Save (saveAreaGrading) — and its skin with it;
//   * Manual shows each row only where the engine reads it;
//   * control 6: one quick solve per load scenario switched on, the field the worst at each place (RED CONTROL: the one
//     solve of Scenario 1 misses Scenario 2's stress).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutManualTests: XCTestCase {

    func project() throws -> FlexibleHisProject.Restored {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        r.project.latticePageManual = true   // ★ K3: these are Manual's controls (Auto asks for the thinnest strut, no quilt)
        return r
    }

    func byStress(_ p: ProjectModel) {
        p.lattice.setSimulateStresses(true)
        p.lattice.gradingMode = .full
        p.lattice.densityMode = .sim
    }

    func testThePartsControlsReachTheEngine() throws {
        let p = try project().project
        byStress(p)
        p.lattice.stageMode = .structural
        let before = LatticeLayoutPreview.settings(p, referenceMPa: 12)
        XCTAssertEqual(before.widthLightMM, 0, "control: Auto states no width")
        XCTAssertEqual(before.minCellsAcross, 5, "control: Auto is Structural's five")
        XCTAssertEqual(before.referenceMPa, 12, "control: Auto is the printed strength over the margin")
        // 1
        p.lattice.strutFromMM = 0.9; p.lattice.strutToMM = 2.4
        var s = LatticeLayoutPreview.settings(p, referenceMPa: 12)
        XCTAssertEqual(s.widthLightMM, 0.9, "★ 1: from")
        XCTAssertEqual(s.widthHeavyMM, 2.4, "★ 1: to")
        // 2
        p.lattice.cellsAcrossMin = 3
        XCTAssertEqual(LatticeLayoutPreview.settings(p).minCellsAcross, 3, "★ 2: his minimum")
        // 4
        XCTAssertEqual(s.maxStep, 0, "control: off, no step kept")
        p.lattice.neverSkipCellSize = true
        p.lattice.algorithm = "doubled"   // Default Grade
        XCTAssertEqual(LatticeLayoutPreview.settings(p).algorithm, "default_grade", "premise: Default Grade")
        XCTAssertEqual(LatticeLayoutPreview.settings(p).maxStep, 2, "★ 4: never skip a cell size")
        p.lattice.algorithm = "stepped"
        p.lattice.stageMode = .aesthetic   // Stepped is Aesthetic only (in Structural it goes as Default Grade)
        XCTAssertEqual(LatticeLayoutPreview.settings(p).algorithm, "stepped", "premise: Stepped")
        XCTAssertEqual(LatticeLayoutPreview.settings(p).maxStep, 0, "control: Stepped keeps no step")
        p.lattice.stageMode = .structural
        p.lattice.algorithm = "doubled"
        // 5
        p.lattice.demandExponent = 0.6
        p.lattice.stressTargetMPa = 30
        s = LatticeLayoutPreview.settings(p, referenceMPa: 12)
        XCTAssertEqual(s.response, 0.6, "★ 5: the response")
        XCTAssertEqual(s.referenceMPa, 30, "★ 5: his target over Auto's")
        // by stress off: no widths
        p.lattice.densityMode = .uniform
        XCTAssertEqual(LatticeLayoutPreview.settings(p).widthLightMM, 0, "control: strut widths only under By stress")
        // 8
        p.lattice.rimWidthMM = 1.4
        p.lattice.boundary = .none
        XCTAssertEqual(LatticeLayoutPreview.settings(p).rimMM, 0, "control: no rim under None")
        p.lattice.boundary = .rim
        XCTAssertEqual(LatticeLayoutPreview.settings(p).rimMM, 1.4, "★ 8: the rim's width under Rim")
        p.lattice.rimWidthMM = nil
        XCTAssertEqual(LatticeLayoutPreview.settings(p).rimMM, -1, "control: Auto's two line widths")
        // 7
        p.lattice.boundary = .fullSkin
        p.lattice.skinBarWidthMM = 1.1; p.lattice.skinReachCells = 2
        s = LatticeLayoutPreview.settings(p)
        XCTAssertEqual(s.skinWidthMM, 1.1, "★ 7: the skin's bar width")
        XCTAssertEqual(s.skinReachCells, 2, "★ 7: its reach")
    }

    func testTheSizeStepOnlyOnDefaultGrade() throws {
        let p = try project().project
        p.lattice.neverSkipCellSize = true
        p.lattice.gradingMode = .none
        XCTAssertEqual(LatticeLayoutPreview.settings(p).maxStep, 0, "control: no grade, no step")
        XCTAssertFalse(LatticeManualControl.shown(p.lattice).contains(.neverSkip), "★ and no row")
    }

    func testAnAreasOwnControlsReachItsRegionsOnly() throws {
        let p = try project().project
        byStress(p)
        let g = try XCTUnwrap(p.latticeGroups.first { g in
            !p.lattice.skinGroups.contains(g.id)
                && p.latticeSelectableRefs(g).contains { p.latticeSelectableRole($0, in: g.id) == .include }
        }, "premise: an area with a Lattice row")
        p.lattice.boundary = .rim
        var a = LatticeAreaGrading()
        a.strutFromMM = 1; a.strutToMM = 2; a.cellsAcrossMin = 2; a.neverSkipCellSize = true; a.response = 2
        a.stressTargetMPa = 40; a.rimWidthMM = 1.6
        p.lattice.areaGrading[g.id] = a
        let s = LatticeLayoutPreview.settings(p)
        let own = s.regions.filter { $0.own.any }
        print("MANUAL area: \(own.count) of \(s.regions.count) regions state their own")
        XCTAssertFalse(own.isEmpty, "★ the area's regions state their own")
        for r in own {
            XCTAssertEqual(r.own.widthLightMM, 1); XCTAssertEqual(r.own.widthHeavyMM, 2)
            XCTAssertEqual(r.own.minCellsAcross, 2); XCTAssertEqual(r.own.maxStep, 2)
            XCTAssertEqual(r.own.response, 2); XCTAssertEqual(r.own.referenceMPa, 40)
            XCTAssertEqual(r.finish.rimMM, 1.6, "★ its rim's width, under the part's Rim")
        }
        XCTAssertTrue(s.regions.filter { !$0.own.any }.allSatisfy { !$0.finish.any }, "control: the other areas state nothing")
        // its own Finish None: no rim width goes
        p.lattice.areaGrading[g.id]?.outerFinish = "none"; p.lattice.areaGrading[g.id]?.skin = "none"
        XCTAssertTrue(LatticeLayoutPreview.settings(p).regions.filter { $0.own.any }.allSatisfy { $0.finish.rimMM == 0 },
                      "control: an area on None has no rim")
    }

    func testAutoWritesNothingAndASetControlRoundTrips() throws {
        var l = LatticeSettings(enabled: true)
        let auto = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        for k in ["strutFromMM", "cellsAcrossMin", "neverSkipCellSize", "stressTargetMPa", "skinBarWidthMM", "rimWidthMM",
                  "demandExponent"] {
            XCTAssertFalse(auto.contains("\"\(k)\""), "★ Auto writes no \(k)")
        }
        l.strutFromMM = 0.9; l.strutToMM = 2; l.cellsAcrossMin = 3; l.neverSkipCellSize = true; l.demandExponent = 0.7
        l.stressTargetMPa = 22; l.skinBarWidthMM = 1; l.skinReachCells = 1.5; l.rimWidthMM = 1.2
        var a = LatticeAreaGrading(); a.rimWidthMM = 1.3; a.response = 1.5
        l.areaGrading[UUID()] = a
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(l))
        XCTAssertEqual(back.strutFromMM, 0.9); XCTAssertEqual(back.strutToMM, 2); XCTAssertEqual(back.cellsAcrossMin, 3)
        XCTAssertTrue(back.neverSkipCellSize); XCTAssertEqual(back.demandExponent, 0.7); XCTAssertEqual(back.stressTargetMPa, 22)
        XCTAssertEqual(back.skinBarWidthMM, 1); XCTAssertEqual(back.skinReachCells, 1.5); XCTAssertEqual(back.rimWidthMM, 1.2)
        XCTAssertEqual(back.areaGrading, l.areaGrading, "★ an area's own round-trips")
    }

    func testAnAreasOwnSurvivesSave() {
        var l = LatticeSettings(enabled: true)
        let g1 = UUID(), g2 = UUID()
        var a = LatticeAreaGrading(skin: "rim"); a.cellsAcrossMin = 2; a.rimWidthMM = 1.5
        l.saveAreaGrading([g2: a], areas: [g1, g2])
        XCTAssertEqual(l.areaGrading[g2]?.cellsAcrossMin, 2, "★ the area's own control")
        XCTAssertEqual(l.areaGrading[g2]?.rimWidthMM, 1.5)
        XCTAssertEqual(l.areaGrading[g2]?.skin, "rim", "★ and its skin")
    }

    func testManualShowsEachRowWhereTheEngineReadsIt() throws {
        let p = try project().project
        p.lattice.setSimulateStresses(false)
        p.lattice.gradingMode = .fitShape
        p.lattice.boundary = .none
        var rows = LatticeManualControl.shown(p.lattice)
        XCTAssertFalse(rows.contains(.strutWidth) || rows.contains(.response) || rows.contains(.target),
                       "control: nothing by stress, no stress rows")
        XCTAssertTrue(rows.contains(.cellsAcross), "★ always")
        XCTAssertFalse(rows.contains(.rimWidth) || rows.contains(.skinBars), "control: None has no rim or skin rows")
        byStress(p)
        p.lattice.boundary = .rim
        rows = LatticeManualControl.shown(p.lattice)
        XCTAssertTrue(rows.contains(.strutWidth) && rows.contains(.response) && rows.contains(.target), "★ By stress")
        XCTAssertTrue(rows.contains(.rimWidth), "★ Rim")
        XCTAssertTrue(LatticeManualControl.shown(p.lattice, areaFinish: .skin).contains(.skinBars), "★ an area on Skin")
        p.lattice.stageMode = .structural
        XCTAssertEqual(LatticeManualControl.cellsAcrossWarning(3, p.lattice), LatticeManualControl.structuralBelowLine,
                       "★ below Structural's five, said")
        XCTAssertNil(LatticeManualControl.cellsAcrossWarning(5, p.lattice), "control: at the rule, nothing")
    }

    func testThePagesOwnRulesReachTheEngine() throws {
        let p = try project().project
        // Covered at the printer's own wall
        p.lattice.boundary = .covered
        let ring = p.printParams.wallRingMM
        XCTAssertGreaterThan(ring, 0, "premise: his printer's wall")
        XCTAssertEqual(LatticeLayoutPreview.settings(p).coverMM, ring, accuracy: 1e-9, "★ Covered at the printer's wall")
        // single-cell members tie with Skin
        p.lattice.boundary = .none
        XCTAssertFalse(LatticeLayoutPreview.settings(p).skin, "control: None, no skin")
        p.lattice.singleCellMembers = true
        // ★ RE-PINNED (notes29, his 11-25: "there is NO single-cell available in structural"): single-cell members are
        // Aesthetic's; a Structural (or unset) stage with the flag left on adds no skin
        p.lattice.stageMode = .structural
        XCTAssertFalse(LatticeLayoutPreview.settings(p).skin, "★ notes29: Structural ignores single-cell members")
        p.lattice.stageMode = .aesthetic
        XCTAssertTrue(LatticeLayoutPreview.settings(p).skin, "★ single-cell members: Skin")
        // Stepped is Aesthetic only
        p.lattice.gradingMode = .full
        p.lattice.algorithm = "stepped"
        p.lattice.stageMode = .aesthetic
        XCTAssertEqual(LatticeLayoutPreview.settings(p).algorithm, "stepped", "control: Aesthetic lays Stepped")
        p.lattice.stageMode = .structural
        XCTAssertEqual(LatticeLayoutPreview.settings(p).algorithm, "default_grade", "★ Structural never lays Stepped")
    }

    // MARK: control 6 — the worst of the loads switched on

    func result(_ vm: [Float], stress: Double) -> TopOptKit.SimAnalysisResult {
        TopOptKit.SimAnalysisResult(accepted: true, nonConvergent: false, maxStressMPa: stress, marginWorstCase: 10 / stress,
                                    marginRequired: 1.5, maxDisplacementMM: stress / 100, vonMisesField: vm,
                                    stressTensorField: vm.flatMap { v in [Double(v), 0, 0, 0, 0, 0] },
                                    gridNX: vm.count, gridNY: 1, gridNZ: 1, gridOrigin: .zero, spacingMM: 1)
    }

    func testTheWorstOfTheLoadsAtEachPlace() async throws {
        let a = result([5, 1, 0], stress: 5), b = result([1, 4, 2], stress: 4)
        let w = LatticeSimModel.worstOf([a, b])
        XCTAssertEqual(w.vonMisesField, [5, 4, 2], "★ the worst at each place")
        XCTAssertEqual(w.stressTensorField[6], 4, "★ with that load's own stress there")
        XCTAssertEqual(w.maxStressMPa, 5)
        XCTAssertEqual(w.marginWorstCase, 2, "★ the smallest margin")
        let ctxA = LatticeSimModel.Context(modelPath: "/m", material: "PLA", materialsPath: "m", rulesPath: "r", resolution: 64,
                                           anchorFaceIDs: [1], loadGroups: [])
        let ctxB = LatticeSimModel.Context(modelPath: "/m", material: "PLA", materialsPath: "m", rulesPath: "r", resolution: 64,
                                           anchorFaceIDs: [2], loadGroups: [])
        let sim = LatticeSimModel(runner: { $0.anchorFaceIDs == [1] ? a : b })
        sim.run([ctxA])
        try await until { if case .complete = sim.phase { return true }; return false }
        XCTAssertEqual(sim.field?.vonMises, [5, 1, 0], "RED CONTROL: Scenario 1's solve alone misses Scenario 2's stress")
        XCTAssertFalse(sim.isStale(against: [ctxA]), "one scenario: the same fingerprint as before")
        XCTAssertFalse(sim.isStale(against: ctxA.fingerprint))
        XCTAssertTrue(sim.isStale(against: [ctxA, ctxB]), "★ a second scenario switched on asks again")
        sim.run([ctxA, ctxB])
        try await until { if case .complete = sim.phase { return sim.field?.vonMises != [5, 1, 0] }; return false }
        XCTAssertEqual(sim.field?.vonMises, [5, 4, 2], "★ both scenarios, the worst at each place")
        XCTAssertFalse(sim.isStale(against: [ctxA, ctxB]))
    }

    func testTheScenariosSwitchedOnAreSolved() throws {
        let r = try project()
        let p = r.project
        let one = r.app.makeLatticeSimContexts()
        XCTAssertEqual(one.count, 1, "premise: one scenario")
        if p.latticeLeftOutGroups.isEmpty {
            XCTAssertEqual(LatticeSimModel.fingerprint(of: one), r.app.makeLatticeSimContext()?.fingerprint,
                           "★ one scenario, nothing switched off: exactly as before")
        }
        let loads = p.selection.groups.filter { p.force.kind(for: $0.id).isLoad }
        let load = try XCTUnwrap(loads.first, "premise: a load")
        let s2 = p.force.addScenario()
        // ★ his 2040 stand (11-21): one load, two scenarios — the scenario holding no load adds no stress and is left out (its
        // solve used to fail and sink the whole check). Here the load is moved to Scenario 2: Scenario 1 is the empty one.
        p.force.scenarios?.owner[load.id] = s2
        let moved = r.app.makeLatticeSimContexts()
        XCTAssertEqual(moved.count, 1, "★ the scenario with no load is not solved")
        XCTAssertEqual(moved.first?.scenarioName, p.force.scenarioList[1].name, "★ the one with the load is, by its name")
        XCTAssertFalse(moved.first?.loadGroups.isEmpty ?? true)
        p.lattice.topologyExcluded.insert(s2)
        XCTAssertEqual(r.app.makeLatticeSimContexts().count, 0, "★ a scenario switched off for the lattice is not solved")
        p.lattice.topologyExcluded.remove(s2)
        p.force.scenarios?.owner[load.id] = nil   // the load back in Scenario 1; Scenario 2 empty, exactly as on his stand
        let his = r.app.makeLatticeSimContexts()
        XCTAssertEqual(his.count, 1, "★ his stand: Scenario 2 holds no load, left out")
        XCTAssertEqual(his.first?.scenarioName, p.force.scenarioList[0].name)
        // (two scenarios each with loads, combined as the worst at each place: IPadNotes1120Tests)
    }

    func until(_ done: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(done(), "timed out")
    }
}
#endif
