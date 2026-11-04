// FlexibleU21RTests — round 7 · U21 batch R: the reviewer's still-to-do items of 2026-10-21 (ruling E, approved by the maintainer).
//   E(1) "E2 Q2: one [More…] listing every group, one per row; no fourth fixed button" — the Export step's sends (three face groups
//        and an edges group): two sends and [More…], which lists every group's send, one per row.   — testMoreListsEveryGroupOnePerRow
//   E(3) "X20b(a) walls drifting from the ghost past the ½ bound: pull-back iterations until residual < tolerance, with a cap; cap
//        hit ⇒ say so on screen; no silent drift."                                   — testPullbackMeetsToleranceOrSaysSo (his pad)
//                                                                                     + testTheCapIsSaidInOneLine
//   E(5) "X20b(c) a newer drawn map ALWAYS supersedes an in-flight design; the stale answer is discarded ('an answer counts only
//        for the job on screen'); add a test."                           — testANewerDrawnMapSupersedesAnInFlightDesign (his pad)
// On HIS live pad of 2026-10-21 (round7/batch_u21/his_live_1021_pad: Face 5 Stamp, Face 3 Curves, Edge 12 + Edge 9). Each RED
// control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleU21RTests: XCTestCase {
    static var padDir: URL { FlexibleU21DeleteUndoTests.fixtures.appendingPathComponent("his_live_1021_pad", isDirectory: true) }

    override func tearDown() {
        FlexibleCoreHold.controlSendsCapAtThree = false
        FlexibleStageModel.controlStaleDesignShown = false
        FlexibleStageModel.holdDesignLandingForTests = false
        super.tearDown()
    }

    func hisPad(_ what: String) async throws -> FlexibleStageModel {
        let r = try FlexibleHisProject.restore(Self.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        addTeardownBlock { @MainActor in
            FlexibleStageModel.holdDesignLandingForTests = false
            await m.waitForIdle()
        }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, what)
        try await FlexibleHisProject.waitFor(120, "\(what): designs") { !m.designsInFlight }
        return m
    }

    // MARK: E(1) — [More…]

    func testMoreListsEveryGroupOnePerRow() {
        let name: (Int) -> String = { "Face \($0)" }
        // three face groups and an edges group (its press in the job by its marker)
        let press = UUID()
        let groups = [FlexibleSqueezeGroup(id: 1, number: 1, regions: [3]),
                      FlexibleSqueezeGroup(id: 2, number: 2, regions: [5]),
                      FlexibleSqueezeGroup(id: 3, number: 3, regions: [6]),
                      FlexibleSqueezeGroup(id: 4, number: 4, regions: [], presses: [press], kind: .edges)]
        let sends = FlexibleCoreHold.sends(groups: groups, pinches: [], name: name, pressMarker: { $0 == press ? -1001 : nil })
        XCTAssertEqual(sends.map(\.title), ["Send Group 1 only", "Send Group 2 only", "Send Group 3 only", "Send Group 4 only"],
                       "★ every group can be sent (the edges group too)")
        let slots = FlexibleCoreHold.slots(sends)
        XCTAssertEqual(slots.count, FlexibleCoreHold.fixedButtons, "★ no fourth fixed button")
        XCTAssertEqual(slots.prefix(2).map { if case .send(let f) = $0 { return f.title } else { return "" } },
                       ["Send Group 1 only", "Send Group 2 only"])
        guard case .more(let rows) = slots.last else { return XCTFail("★ the last slot is [More…]") }
        XCTAssertEqual(rows, sends, "★ [More…] lists EVERY group, one per row")
        XCTAssertEqual(FlexibleRowCopy.moreSends, "More\u{2026}")
        // up to three: the buttons as today, no [More…]
        let three = Array(sends.prefix(3))
        XCTAssertEqual(FlexibleCoreHold.slots(three), three.map { .send($0) })
        XCTAssertEqual(FlexibleCoreHold.slots(Array(sends.prefix(1))).count, 1)
        // the card lists them all too (its Core rows = the hold's sends)
        // RED CONTROL: before — three sends, Group 4 has no button anywhere
        FlexibleCoreHold.controlSendsCapAtThree = true
        let red = FlexibleCoreHold.sends(groups: groups, pinches: [], name: name, pressMarker: { $0 == press ? -1001 : nil })
        XCTAssertEqual(red.count, 3, "RED CONTROL: the cap at three")
        XCTAssertFalse(FlexibleCoreHold.slots(red).contains { s in
            if case .send(let f) = s { return f.title == "Send Group 4 only" }
            if case .more(let r) = s { return r.contains { $0.title == "Send Group 4 only" } }
            return false
        }, "RED CONTROL: Group 4 cannot be sent")
        print("FLEX-U21R-E1 sends \(sends.map(\.title)) · slots \(slots.count) (2 + More… with \(rows.count) rows) · RED \(red.map(\.title))")
    }

    // MARK: E(3) — pull-back to tolerance, or said

    /// His Group 2 (Edge 12 + Edge 9) at core's full design depth, as Play shows it (X20b's path).
    func playEdges() async throws -> (FlexibleStageModel, String, FlexibleFEField) {
        let m = try await hisPad("his pad of 10-21")
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(strips.compactMap { $0.strip?.label }.sorted(), ["Edge 12", "Edge 9"], "premise: his Group 2")
        try await FlexibleHisProject.waitFor(240, "his presses registered") { strips.allSatisfy { m.pressKey($0.id) != nil } }
        try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
            strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
        }
        try await FlexibleSquishFixture.settle(m, "his pad again")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let id = FlexibleSim.groupID(g.number)
        _ = try await FlexibleSquishFixture.build(m, "his pad")
        try await FlexibleSquishFixture.solve(m, first: id, "his pad")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "Group 2's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        let field = try XCTUnwrap(m.squish[id]?.field, "landed: \(m.squish[id]?.failure ?? "-")")
        return (m, id, field)
    }

    func testPullbackMeetsToleranceOrSaysSo() async throws {
        let (m, id, field) = try await playEdges()
        XCTAssertTrue(field.designDepth, "premise: X20b's field at core's full design depth")
        let s = Float(FlexiblePressHeat.shownScale(field))
        XCTAssertEqual(s, 1, "premise: shown at × 1")
        let before = field.pullbackCheck(scale: s, iterations: FlexibleFE.pullbackIterationsX20b)
        let now = field.pullbackCheck(scale: s, iterations: FlexibleFE.pullbackIterations)
        let line = m.notTunedLine(simID: id)
        print("FLEX-U21R-E3 his Group 2: gmax \(field.gmax) part \(field.gmaxPart) · min det \(field.minDeterminant(k: 1)) · "
              + "X20b's \(FlexibleFE.pullbackIterationsX20b) iterations: \(before.unconverged)/\(before.samples) over tolerance, worst \(before.maxResidualMM) mm · "
              + "now (cap \(FlexibleFE.pullbackIterations)): \(now.unconverged)/\(now.samples), worst \(now.maxResidualMM) mm · "
              + "shortfall \(field.pullbackShortfall.map { "\($0)" } ?? "none") · chip '\(line ?? "-")'")
        XCTAssertGreaterThan(FlexibleFE.pullbackIterations, FlexibleFE.pullbackIterationsX20b, "★ more pull-back iterations")
        XCTAssertLessThanOrEqual(now.unconverged, before.unconverged, "★ never worse")
        if now.unconverged == 0 {
            XCTAssertLessThan(now.maxResidualMM, FlexibleFE.pullbackTolMM, "★ every wall back on the ghost, under tolerance")
            XCTAssertNil(field.pullbackShortfall, "★ nothing to say")
            if field.trueFoldCut == nil { XCTAssertNil(line, "★ no line") }
        } else {
            XCTAssertNotNil(field.pullbackShortfall, "★ the cap was hit: kept on the field")
            if field.trueFoldCut == nil { XCTAssertEqual(line, FlexibleRowCopy.pullbackCapHit, "★ … and said on screen, one line") }
        }
        // RED CONTROL: X20b's eight iterations leave walls off the ghost on his Group 2, and nothing says so
        XCTAssertGreaterThan(before.unconverged, 0, "RED CONTROL: X20b's pull-back drifts past tolerance on his pad")
    }

    func testTheCapIsSaidInOneLine() {
        XCTAssertNil(FlexibleStageModel.pressSimLine(trueFoldCut: nil, pullbackShortfall: nil), "nothing held back, nothing said")
        XCTAssertEqual(FlexibleStageModel.pressSimLine(trueFoldCut: nil, pullbackShortfall: 0.02), FlexibleRowCopy.pullbackCapHit,
                       "★ the cap hit is said")
        XCTAssertEqual(FlexibleStageModel.pressSimLine(trueFoldCut: 0.885, pullbackShortfall: 0.02), FlexibleRowCopy.pressFoldCut(percent: 88),
                       "one line: a true fold's cut first")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.pullbackCapHit.count, 44, "one line on the legend card")
    }

    // MARK: E(5) — a newer drawn map supersedes an in-flight design

    static func depths(_ v: [FlexShownValue]?) -> [Double?]? {
        v?.map { if case .depth(let d) = $0 { return d } else { return nil } }
    }

    func testANewerDrawnMapSupersedesAnInFlightDesign() async throws {
        let m = try await hisPad("his pad of 10-21")
        let face = 5
        let k = try XCTUnwrap(m.key(face), "his Face 5")
        XCTAssertTrue(m.settings.face(face)?.isStampShape ?? false, "premise: his Face 5 on Stamp")
        let stampDesign = try XCTUnwrap(m.designs[k], "premise: core's design of his stamp")
        // the design for the new drawing is held in flight (X20b's check: "in flight" for more than 4 minutes)
        FlexibleStageModel.holdDesignLandingForTests = true
        m.setShape(face, "curves")
        let f = try XCTUnwrap(m.settings.face(face))
        XCTAssertFalse(f.isStampShape)
        let map = f.map
        let drawn = try await m.workerForTests.withScene { try $0.squishFraction(face: k.region, rotation: k.rotation, map: map) }
        try await FlexibleHisProject.waitFor(60, "the new drawn map") { m.liveS[k] == drawn }
        XCTAssertTrue(m.designsInFlight, "premise: the design for the new drawing is still in flight")
        XCTAssertEqual(m.designs[k], stampDesign, "premise: the stamp's design is the one in hand")
        let want: [Double?] = drawn.map { $0 * f.deepestMM }
        let shown = FlexibleShownValues(model: m)
        XCTAssertEqual(Self.depths(shown.values[k]), want, "★ the newer drawn map is what shows, not the stamp's design")
        XCTAssertEqual(shown.label, "What you drew")
        // RED CONTROL: before — the stamp's (stale) design showed until the new one landed (never, while it stayed in flight)
        FlexibleStageModel.controlStaleDesignShown = true
        let red = FlexibleShownValues(model: m)
        XCTAssertNotEqual(Self.depths(red.values[k]), want, "RED CONTROL: the old design's dent shows over the newer drawing")
        FlexibleStageModel.controlStaleDesignShown = false
        // a second drawing while still held: only the job on screen counts when the answers land
        m.edit { s in guard var g = s.face(face) else { return }; g.curveX = FlexCurve(x: [0, 0.5, 1], y: [0, 1, 0]); s.setFace(g) }
        m.curveChanged(region: face)
        let now = try XCTUnwrap(m.settings.face(face))
        FlexibleStageModel.holdDesignLandingForTests = false
        try await FlexibleHisProject.waitFor(120, "the designs land") { !m.designsInFlight }
        await m.waitForIdle()
        XCTAssertEqual(m.designedInputs[k], FlexibleStageModel.designInputKey(now), "★ the answer that counts is for the drawing on screen")
        XCTAssertNotEqual(m.designs[k], stampDesign, "★ the stale answer is gone")
        XCTAssertEqual(FlexibleShownValues(model: m).values[k]?.count, m.stacks[k]?.columns.count, "the design shows again once current")
        print("FLEX-U21R-E5 Face 5 Stamp → Curves held in flight: shown = the drawn map (\(drawn.count) columns, S max \(drawn.max() ?? 0)) · "
              + "RED showed the stamp's design · landed for the drawing on screen: \(m.designedInputs[k] == FlexibleStageModel.designInputKey(now))")
    }
}
