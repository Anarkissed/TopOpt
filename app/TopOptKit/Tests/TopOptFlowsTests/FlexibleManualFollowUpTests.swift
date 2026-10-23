// FlexibleManualFollowUpTests — round 7 · MANUAL follow-up (after the Manual install, 2026-10-22).
//   His orders of 2026-10-22 ~02:30: "The views become what the app assumes based on your values, so cards should say that when a
//   view is selected … Just because it's manual doesn't mean we want it to look like shit." The install left two open items and one
//   card that disagreed with the screen:
//   (A) the MAIN (Lattice) page read the stored depth / core's design in Manual — now the Squish page's estimate; core's design
//       captions ("N of the design stamp lands off this face") hidden; a group with no sim entry never says "working it out…" for
//       ever (it says "Save & Exit to see it").
//   (B) a group's own TYPE and CELL were saved but never drawn (the shader draws one type and one cell per part) — a group's "Set
//       its own" is now Density % and Walls (beads) only, under "Type and cell follow the part".
// On HIS live pad of 2026-10-21. Each RED control is asserted red inside its test. Written before the code (red first).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualFollowUpTests: XCTestCase {

    override func tearDown() {
        FlexibleMainStage.controlStoredDepthInManual = false
        FlexibleMainStage.controlCalibratedHeatInManual = false
        FlexibleFaceResult.controlDesignCaptionsInManual = false
        FlexibleStageModel.controlNoEntryIsWorking = false
        FlexibleStageModel.controlGroupOwnTypeAndCell = false
        super.tearDown()
    }

    // MARK: A — Manual on the main Lattice page: the Squish page's estimate, no core design

    func testOnHisPadInManualTheMainPageReadsTheEstimateAndNoCoreDesign() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let p = r.project
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: p, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces }, "premise: a faces group")
        let stampFace = g.regions.first { m.settings.face($0)?.isStampShape == true }
        let r0 = try XCTUnwrap(stampFace ?? g.regions.first)
        let f0 = try XCTUnwrap(m.settings.face(r0))
        let design = try XCTUnwrap(m.design(r0), "premise: Auto's design of \(m.name(r0))")
        XCTAssertTrue(FlexibleFaceResult.showsDesign(model: m), "Auto: core's design lines shown")
        XCTAssertEqual(FlexibleFaceResult.stampOffCaption(design, model: m) != nil, design.designStampOffFace, "Auto unchanged")
        XCTAssertEqual(s.mainDepthText(m, f0), String(format: "%.1f mm", f0.deepestMM), "Auto: the stored depth")

        // Manual, Save & Exit: the lattice from his values, the sims his lattice's estimate
        m.setManual(true)
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        if m.lattice == nil, !m.latticeBuilding { m.generateLattice() }
        try await FlexibleHisProject.waitFor(300, "the Manual lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleSquishFixture.solve(m, first: FlexibleSim.groupID(g.number), "his pad · Manual")
        s.refresh()
        guard case .mm(let est) = m.estimate(region: r0) else { return XCTFail("no estimate: \(m.estimate(region: r0))") }
        print(String(format: "FLEX-MF main page %@: estimate %.3f mm · stored Deepest squish %.3f mm", m.name(r0), est, f0.deepestMM))
        XCTAssertGreaterThan(est, 0)
        XCTAssertGreaterThan(abs(est - f0.deepestMM), 0.1, "premise: the estimate is not the stored depth")

        // (1) the main page's squish prism (drawn under [Prisms] by its control) is drawn to the estimate
        s.controlSquishPrismsOnMain = true
        m.views.insert(.prisms)
        func reach(_ depth: Double) throws -> Double {
            let key = try XCTUnwrap(m.key(r0)), st = try XCTUnwrap(m.stacks[key]), geo = try XCTUnwrap(m.geometry[key])
            let v = try XCTUnwrap(FlexibleDepthPrism.volume(region: r0, stack: st, centres: geo.centres, depthMM: depth, k: s.prismK,
                                                            footprint: m.prismFootprint(r0)))
            guard case .shell(let sh) = v.shape else { throw XCTSkip("not a shell") }
            return sh.reachedDepthMM
        }
        func drawn() throws -> Double {
            let item = try XCTUnwrap(s.squishVolumes(p, m).first { $0.volume.faceID == r0 }, "\(m.name(r0))'s prism")
            guard case .shell(let sh) = item.volume.shape else { throw XCTSkip("not a shell") }
            return sh.reachedDepthMM
        }
        let shown = try drawn(), want = try reach(est), stored = try reach(f0.deepestMM)
        print(String(format: "FLEX-MF prism reach: drawn %.3f · estimate's %.3f · stored's %.3f (k %.2f)", shown, want, stored, s.prismK))
        XCTAssertEqual(shown, want, accuracy: 1e-9, "★ the main page's prism is drawn to the estimate")
        XCTAssertEqual(s.mainDepthText(m, f0), FlexibleManualCopy.chip(est), "★ its reading is the estimate ('≈ 2.8 mm')")
        // RED CONTROL: the stored depth on the main page in Manual (M2's)
        FlexibleMainStage.controlStoredDepthInManual = true
        XCTAssertEqual(try drawn(), stored, accuracy: 1e-9, "RED control (stored depth) must draw the stored depth")
        XCTAssertNotEqual(try drawn(), want, "RED control must differ from the estimate")
        XCTAssertEqual(s.mainDepthText(m, f0), String(format: "%.1f mm", f0.deepestMM), "RED control: the stored reading")
        FlexibleMainStage.controlStoredDepthInManual = false
        m.views.remove(.prisms)
        s.controlSquishPrismsOnMain = false

        // (2) the main page's heat / legend / TAP TO READ: the estimate, column for column
        let id = FlexibleSim.groupID(g.number)
        let field = try XCTUnwrap(m.squish[id]?.field, "group \(g.number)'s sim (Manual)")
        let key = try XCTUnwrap(m.key(r0))
        let heat = try XCTUnwrap(s.feColumnValues(field, m)?[key], "the main page's heat on \(m.name(r0))")
        let top = heat.compactMap { $0 }.max() ?? -1
        XCTAssertEqual(top, est, accuracy: 1e-9, "★ the main page's deepest heat is the card's estimate")
        FlexibleMainStage.controlCalibratedHeatInManual = true
        let calibrated = s.feColumnValues(field, m)?[key]?.compactMap { $0 }.max() ?? -1
        FlexibleMainStage.controlCalibratedHeatInManual = false
        print(String(format: "FLEX-MF heat top: Manual %.4f mm (the estimate %.4f) · the calibrated route's %.4f (control)", top, est, calibrated))

        // (3) core's design captions: none in Manual ("N of the design stamp lands off this face")
        XCTAssertFalse(FlexibleFaceResult.showsDesign(model: m), "★ Manual: core's design lines hidden")
        XCTAssertNil(FlexibleFaceResult.stampOffCaption(design, model: m), "★ Manual: no 'N of the design stamp lands off this face'")
        FlexibleFaceResult.controlDesignCaptionsInManual = true
        XCTAssertTrue(FlexibleFaceResult.showsDesign(model: m), "RED control (design captions in Manual) must show them")
        if design.designStampOffFace {
            XCTAssertNotNil(FlexibleFaceResult.stampOffCaption(design, model: m), "RED control: the stamp caption back")
        }
        FlexibleFaceResult.controlDesignCaptionsInManual = false

        // (4) a group with no sim entry once the sims were handed over: "Save & Exit to see it", never "working it out…" for ever
        let saved = m.squish[id]
        m.squish[id] = nil
        XCTAssertEqual(m.estimate(region: r0), .later, "★ no sim coming: Save & Exit")
        XCTAssertEqual(m.estimateLine(region: r0), FlexibleManualCopy.estimateLater)
        FlexibleStageModel.controlNoEntryIsWorking = true
        XCTAssertEqual(m.estimate(region: r0), .working, "RED control (M2's rule) must say working")
        FlexibleStageModel.controlNoEntryIsWorking = false
        // …before the main page hands them over, the same group IS coming: working
        let sched = m.squishScheduled
        m.squishScheduled = nil
        XCTAssertEqual(m.estimate(region: r0), .working, "★ not yet handed over and his group has a sim: working")
        m.squishScheduled = sched
        m.squish[id] = saved
        XCTAssertEqual(m.estimate(region: r0), .mm(est), "restored")
    }

    // MARK: B — a group's own lattice = what is drawn: Density % and Walls (beads), type and cell the part's

    func testAGroupsOwnLatticeIsDensityAndWallsUnderThePartsTypeAndCell() async throws {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, "his pad")
        m.setManual(true)
        let g = try XCTUnwrap(m.squeezeGroups.first)
        let bw = m.manualBeadWidthMM
        m.setGroupOwnLattice(g.id, own: true)
        let part = try XCTUnwrap(m.manualLattice(group: nil))

        // the card: Density and Walls under one quiet line
        XCTAssertEqual(FlexibleManualLatticeRows.rows(group: nil), ["type", "cell", "density", "walls"], "the part's four lines")
        XCTAssertEqual(FlexibleManualLatticeRows.rows(group: g.id), ["follows", "density", "walls"], "★ a group: Density and Walls only")
        XCTAssertEqual(FlexibleManualCopy.followsPart, "Type and cell follow the part")
        XCTAssertLessThanOrEqual(FlexibleManualCopy.followsPart.count, 44)

        // its walls are worked out with the PART's type and cell, and follow the part's cell
        m.setManualDensity(0.30, group: g.id)
        var own = try XCTUnwrap(m.manualLattice(group: g.id))
        XCTAssertEqual(own.topology, part.topology)
        XCTAssertEqual(own.cellMM, part.cellMM)
        XCTAssertEqual(own.density, 0.30, accuracy: 1e-12)
        let unit = FlexibleManualMath.unitCellMM(part.topology, beadWidthMM: bw)
        XCTAssertEqual(m.manualWalls(group: g.id) ?? 0, part.cellMM * 0.30 / unit, accuracy: 1e-9, "★ walls from the part's cell")
        m.setManualCell(part.cellMM + 2, group: nil)
        XCTAssertEqual(m.manualWalls(group: g.id) ?? 0, (part.cellMM + 2) * 0.30 / unit, accuracy: 1e-9, "★ the part's cell moves them")
        m.setManualWalls(2, group: g.id)
        own = try XCTUnwrap(m.manualLattice(group: g.id))
        XCTAssertEqual(m.manualWalls(group: g.id) ?? 0, 2, accuracy: 1e-6, "★ his walls give the group's density at the part's cell")
        // a group type / cell edit does nothing (no row for it)
        let before = m.settings.manual
        m.setManualType(part.topology == "gyroid" ? "honeycomb" : "gyroid", group: g.id)
        m.setManualCell(20, group: g.id)
        XCTAssertEqual(m.settings.manual, before, "★ a group has no type or cell of its own")

        // an older save with a group type and cell: decoded, kept, never drawn nor shown
        let other = part.topology == "gyroid" ? "honeycomb" : "gyroid"
        let json = """
        {"on":true,"part":{"topology":"\(part.topology)","cellMM":\(part.cellMM + 2),"density":\(part.density)},
         "groups":{"\(g.id)":{"topology":"\(other)","cellMM":20,"density":0.3}}}
        """
        let old = try JSONDecoder().decode(FlexibleManualSettings.self, from: Data(json.utf8))
        m.edit { s in s.manual = old }
        XCTAssertEqual(m.settings.manual?.groups?[String(g.id)]?.topology, other, "the save's group type is kept")
        own = try XCTUnwrap(m.manualLattice(group: g.id))
        XCTAssertEqual(own.topology, part.topology, "★ shown: the part's type")
        XCTAssertEqual(own.cellMM, part.cellMM + 2, "★ shown: the part's cell")
        XCTAssertEqual(own.density, 0.3, accuracy: 1e-12)
        // drawn: the group's density only (its type and cell change nothing in the field)
        let f = FlexDensityField(nx: 2, ny: 1, nz: 1, spacing: 1, origin: .zero, density: [0.2, 0.2], owner: [7, 8])
        var same = old
        same.groups?[String(g.id)] = FlexibleManualLattice(topology: part.topology, cellMM: part.cellMM + 2, density: 0.3)
        XCTAssertEqual(FlexibleManualField.field(f, manual: old, ownerGroups: [7: g.id]).density,
                       FlexibleManualField.field(f, manual: same, ownerGroups: [7: g.id]).density, "★ the drawn field ignores them")

        // RED CONTROL: the group's own type and cell shown (M1's card) — the card and the screen disagree
        FlexibleStageModel.controlGroupOwnTypeAndCell = true
        XCTAssertTrue(FlexibleManualLatticeRows.rows(group: g.id).contains("type"), "RED control must show the group's type line")
        XCTAssertEqual(m.manualLattice(group: g.id)?.topology, other, "RED control: the group's saved type shown")
        FlexibleStageModel.controlGroupOwnTypeAndCell = false
    }
}
