// FlexibleC1Tests — round 7, step C1 (his words of 2026-10-20: "the edge/corner squishes barely squish, is there a reason for that?
// Is that mainly because it does not go to core? Please go ahead and finalize the send to core now."; his order: after U1 and U2).
// On HIS pad as he left it at 13:46 that day (round7/batch_u1/his_live_1020: Group C = Face 3 + Face 5 with stamps, Group 2 = Edge 12
// + Edge 9). Each RED control is asserted red inside its test.
//   1 the switch is kept and ON; "Shape only · core support comes later" is gone          — testTheSwitchIsOnAndTheShapeOnlyLineIsGone
//   2 his Group 2 is designed by core: sent, the lattice graded inside each flat prism only,
//     the chip gone, Play/Bend/Heat calibrated to core's press stacks, deeper than the
//     interim sim (the switch off, as U2 shipped)                                          — testHisEdgesGroupIsCoresDesignAndSquishesDeeper
//   3 an edge whose two ends are unknown is kept out with a line (E2 verify minor 16)      — testAnEdgeWithoutItsEndsIsKeptOutWithALine
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleC1Tests: XCTestCase {
    static var liveDir: URL { FlexibleU1Tests.liveDir }

    override func tearDown() {
        FlexibleBackend.sendsPresses = true
        FlexibleStageModel.controlNoTune = false
        FlexibleStageModel.controlUniformMapForNoEnds = false
        super.tearDown()
    }

    // MARK: 1

    func testTheSwitchIsOnAndTheShapeOnlyLineIsGone() throws {
        XCTAssertTrue(FlexibleBackend.sendsPresses, "★ C1: presses are sent (the switch kept, on)")
        func facts(_ on: Bool) -> FlexiblePressSupport.Facts {
            FlexiblePressSupport.Facts(schema: true, bridge: true, api: FlexiblePressSupport.expectedAPI, stacked: nil, twoEntries: nil,
                                       shared: nil, designed: true, designRefusal: nil, conflict: nil, backend: on)
        }
        XCTAssertTrue(FlexiblePressSupport.verdict(facts(FlexibleBackend.sendsPresses)).inJob, "★ in the job once core takes it")
        let off = FlexiblePressSupport.verdict(facts(false))
        XCTAssertFalse(off.inJob, "RED CONTROL (the switch off, as U2 shipped): kept out")
        XCTAssertEqual(off.line, FlexibleRowCopy.pressNotSent)
        // no source line says it any more
        let dir = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        var hits: [String] = []
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let s = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            for l in s.split(separator: "\n") where l.contains("core support comes later\"") && !l.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && !l.contains("///") { hits.append(f) }
        }
        XCTAssertEqual(hits, [], "★ the shape-only line is gone from the app")
    }

    // MARK: 2

    struct Run {
        let m: FlexibleStageModel
        let simID: String
        let field: FlexibleFEField
        let combined: FlexDensityField?
        /// Per press (his label): the deepest compression along its arrow over core's press stack (mm, as Play shows it).
        let deepest: [String: Double]
    }

    func run(sends: Bool) async throws -> Run {
        FlexibleBackend.sendsPresses = sends
        let r = try FlexibleHisProject.restore(Self.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-20 (sends \(sends))")
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(strips.compactMap { $0.strip?.label }.sorted(), ["Edge 12", "Edge 9"], "premise: his Group 2")
        try await FlexibleHisProject.waitFor(240, "his presses registered") { strips.allSatisfy { m.pressKey($0.id) != nil } }
        if sends {
            try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
                strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
            }
        }
        try await FlexibleSquishFixture.settle(m, "his pad (sends \(sends)) again")
        print("FLEX-C1 sends \(sends): gate " + strips.map { "\($0.strip!.label) in job \(m.pressSupport[$0.id]?.inJob ?? false) '\(m.pressWarning($0.id)?.line ?? "-")'" }.joined(separator: " | ")
              + " · top line '\(m.readiness.oneLine)'")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let id = FlexibleSim.groupID(g.number)
        _ = try await FlexibleSquishFixture.build(m, "his pad (sends \(sends))")
        try await FlexibleSquishFixture.solve(m, first: id, "his pad (sends \(sends))")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "Group 2's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        let field = try XCTUnwrap(m.squish[id]?.field, "landed: \(m.squish[id]?.failure ?? "-")")
        var deepest: [String: Double] = [:]
        for p in strips {
            let st = try XCTUnwrap(m.pressRegistrations[p.id]?.stack, "core's press stack")
            deepest[p.strip!.label] = st.columns.indices.map { field.columnCompression(stack: st, col: $0, pinched: false) }.max() ?? 0
        }
        return Run(m: m, simID: id, field: field, combined: m.lastCombinedField, deepest: deepest)
    }

    func testHisEdgesGroupIsCoresDesignAndSquishesDeeper() async throws {
        // the interim sim, as U2 shipped (the switch off): the current lattice, its own size
        let a = try await run(sends: false)
        XCTAssertTrue(a.m.sentPresses.isEmpty, "premise: nothing sent")
        XCTAssertTrue(a.field.uncalibrated, "premise (WHY it was shallow): the interim sim had no core prediction to scale to")
        XCTAssertEqual(a.m.notTunedLine(simID: a.simID), FlexibleRowCopy.latticeNotTunedForPress, "premise: the chip")

        // C1: sent
        let b = try await run(sends: true)
        let m = b.m
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(m.sentPresses, Set(strips.map(\.id)), "★ Edge 12 and Edge 9 are in the job")
        let job = try m.runJobJSON(resting: Set(FlexibleAngledGoldens.sends(m).first { $0.title.contains("Group 2") }?.resting ?? []))
        XCTAssertTrue(job.contains("press_direction") && job.contains("face_region_ids"), "★ the job carries his presses")
        XCTAssertEqual(Set(m.latticeTunedPresses.keys), Set(strips.map(\.id)), "★ the lattice carries core's design for both")
        XCTAssertNil(m.notTunedLine(simID: b.simID), "★ the chip goes once core designs the lattice for the press")
        XCTAssertFalse(b.field.uncalibrated, "★ Play calibrated to core's press stacks")
        let saved = m.latticeTunedPresses
        m.latticeTunedPresses = [:]
        XCTAssertEqual(m.notTunedLine(simID: b.simID), FlexibleRowCopy.latticeNotTunedForPress, "RED CONTROL (untuned): the chip")
        m.latticeTunedPresses = saved

        // the lattice designed along the arrow: inside each flat prism core's design, past it nothing moves (E2 verify blocker)
        let fa = try XCTUnwrap(a.combined), fb = try XCTUnwrap(b.combined)
        XCTAssertEqual(fa.density.count, fb.density.count, "premise: one grid")
        let cuts = strips.compactMap { FlexibleFlatPrism.cut(of: $0) }
        var inside = 0, movedIn = 0, movedOut = 0
        for k in 0..<fb.nz { for j in 0..<fb.ny { for i in 0..<fb.nx {
            let n = fb.index(i, j, k)
            guard n < fa.density.count else { continue }
            let p = fb.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * fb.spacing
            let isIn = cuts.contains { $0.height(p) <= $0.depthMM && $0.height(p) >= 0 }
            if isIn { inside += 1 }
            if fa.density[n] != fb.density[n] { if isIn { movedIn += 1 } else { movedOut += 1 } }
        } } }
        print("FLEX-C1 lattice: voxels inside the two flat prisms \(inside) · moved inside \(movedIn) · moved past them \(movedOut)")
        XCTAssertGreaterThan(movedIn, 0, "★ under his presses the lattice is core's design along the arrow")
        XCTAssertEqual(movedOut, 0, "★ past the flat prisms the lattice is what it was")

        // DEEPER than the interim sim
        print("FLEX-C1 Group 2 deepest along the arrow: interim (switch off) \(a.deepest) scale \(a.field.scale) uncalibrated \(a.field.uncalibrated)"
              + " · C1 \(b.deepest) scale \(b.field.scale) asked k \(b.field.coreRatio) clamped \(b.field.clamped) fold share \(b.field.foldShare ?? 1)"
              + " · core's targets " + saved.map { "\(m.press($0.key)?.strip?.label ?? "-"): max \($0.value.depthsMM.compactMap { $0 }.max() ?? 0)" }.joined(separator: ", "))
        for p in strips {
            guard let d = m.pressDesign(p.id), let st = m.pressRegistrations[p.id]?.stack else { continue }
            let sg = FlexiblePinch.core(d, stack: st)
            let bd = sg.buildableDepthMM.compactMap { $0 }, hh = sg.heightMM.filter { $0 > 0 }
            let span = st.columns.map { $0.exitT - $0.entryT }
            print("FLEX-C1 core's design \(p.strip!.label): h \(FlexibleFlatPrism.depth(of: p) ?? -1) mm · \(d.columns.count) columns · ok \(d.columns.count - d.tooSoft - d.tooFirm - d.beyondData)"
                  + " soft \(d.tooSoft) firm \(d.tooFirm) beyond \(d.beyondData) · status \(Dictionary(grouping: sg.status, by: { $0 }).mapValues(\.count))"
                  + " · buildable depth \(bd.min() ?? -1)…\(bd.max() ?? -1) mm (\(bd.count) cols) · lattice height \(hh.min() ?? -1)…\(hh.max() ?? -1) mm"
                  + " · column span \(span.min() ?? -1)…\(span.max() ?? -1) mm · ρ \(sg.buildableDensity.min() ?? -1)…\(sg.buildableDensity.max() ?? -1)"
                  + " · pressure \(d.columns.map(\.pressureMPa).max() ?? -1) MPa max")
        }
        for (label, d) in b.deepest {
            XCTAssertGreaterThan(d, a.deepest[label] ?? .infinity, "★ \(label) squishes deeper than the interim sim's")
        }
    }

    // MARK: 3

    func testAnEdgeWithoutItsEndsIsKeptOutWithALine() async throws {
        let r = try FlexibleHisProject.restore(Self.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad")
        let p = try XCTUnwrap(m.presses.first { $0.strip?.label == "Edge 12" })
        try await FlexibleHisProject.waitFor(240, "Edge 12 registered") { m.pressRegistrations[p.id] != nil }
        XCTAssertNotNil(m.pressMap(p.id), "premise: with its ends it has core's map")
        var reg = try XCTUnwrap(m.pressRegistrations[p.id])
        reg.endsUVT = []   // its line unknown (member.along or span missing)
        m.pressRegistrations[p.id] = reg
        XCTAssertNil(m.pressMap(p.id), "★ no uniform map")
        let v = try XCTUnwrap(m.pressSupport[p.id])
        XCTAssertFalse(v.inJob, "★ kept out")
        XCTAssertEqual(m.pressWarning(p.id)?.line, FlexibleRowCopy.pressEdgeNotFound, "★ said")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.pressEdgeNotFound.count, 44)
        FlexibleStageModel.controlUniformMapForNoEnds = true
        XCTAssertEqual(m.pressMap(p.id)?.mode, "both", "RED CONTROL (E2): a uniform 'both' map, silently")
        XCTAssertNotEqual(m.pressSupport[p.id]?.line, FlexibleRowCopy.pressEdgeNotFound, "RED CONTROL: not said")
    }
}
