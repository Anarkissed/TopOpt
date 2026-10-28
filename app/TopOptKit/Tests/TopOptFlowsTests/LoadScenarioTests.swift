import XCTest
@testable import TopOptFlows
@testable import TopOptKit

/// ★ LOAD SCENARIOS (his order 2026-10-26, the 03:32 anchor addendum, the overnight release's shared key).
final class LoadScenarioTests: XCTestCase {
    private let anchorA = UUID(), anchorB = UUID(), load1 = UUID(), load2 = UUID(), keep = UUID()

    private func twoScenarios() -> (ForceModel, s1: UUID, s2: UUID) {
        var f = ForceModel()
        f.makeAnchor(anchorA); f.makeAnchor(anchorB); f.makeLoad(load1)
        let s2 = f.addScenario()
        f.makeLoad(load2)   // made while Scenario 2 is open
        return (f, f.scenarioList[0].id, s2)
    }

    func testNoScenariosIsExactlyToday() throws {
        var f = ForceModel()
        f.makeAnchor(anchorA); f.makeLoad(load1)
        XCTAssertNil(f.scenarios)
        XCTAssertFalse(f.hasScenarios)
        XCTAssertEqual(f.scenarioList.map(\.name), ["Scenario 1"])
        XCTAssertTrue(f.showsInActiveScenario(load1)); XCTAssertTrue(f.showsInActiveScenario(anchorA))
        let enc = try JSONEncoder().encode(f)
        XCTAssertFalse(String(decoding: enc, as: UTF8.self).contains("scenarios"), "★ a project with no scenarios stores nothing new")
    }

    func testExistingLoadsMoveIntoScenario1AndNewOnesJoinTheOpenScenario() {
        let (f, s1, s2) = twoScenarios()
        XCTAssertEqual(f.scenarioList.map(\.name), ["Scenario 1", "Scenario 2"])
        XCTAssertEqual(f.activeScenarioID, s2, "adding a scenario opens it")
        XCTAssertEqual(f.scenarioID(of: load1), s1, "★ the existing load is Scenario 1's")
        XCTAssertEqual(f.scenarioID(of: load2), s2, "a load made in Scenario 2 is Scenario 2's")
        XCTAssertNil(f.scenarioID(of: anchorA), "anchors are shared by default")
        XCTAssertFalse(f.showsInActiveScenario(load1), "★ only the open scenario's loads show")
        XCTAssertTrue(f.showsInActiveScenario(load2))
        XCTAssertTrue(f.showsInActiveScenario(anchorA))
        XCTAssertTrue(f.showsInActiveScenario(keep), "a group with no load/anchor role shows in every scenario")
    }

    func testAnAnchorAddedInScenario2HoldsThereOnly() {
        var (f, s1, s2) = twoScenarios()
        let own = UUID()
        f.makeAnchor(own)
        XCTAssertEqual(f.scenarioID(of: own), s2)
        XCTAssertTrue(f.anchorIsOn(own, in: s2)); XCTAssertFalse(f.anchorIsOn(own, in: s1))
        f.makeAnchor(anchorA)   // re-tapping Anchor on a shared anchor never moves it
        XCTAssertNil(f.scenarioID(of: anchorA))
    }

    func testRenameAndRemove() {
        var (f, s1, s2) = twoScenarios()
        f.renameScenario(s2, to: "  Held by one plate ")
        XCTAssertEqual(f.scenarioList[1].name, "Held by one plate")
        f.renameScenario(s2, to: "   ")
        XCTAssertEqual(f.scenarioList[1].name, "Held by one plate", "a blank name is ignored")
        f.removeScenario(s1)
        XCTAssertEqual(f.scenarioList.count, 2, "Scenario 1 cannot be removed")
        let s3 = f.addScenario()
        let own = UUID(); f.makeAnchor(own)
        f.removeScenario(s3)
        XCTAssertEqual(f.scenarioID(of: own), s1, "★ a removed scenario's own anchor goes to Scenario 1, never shared")
        f.openScenario(s2)
        f.removeScenario(s2)
        XCTAssertNil(f.scenarios, "back to one scenario = today's project")
        XCTAssertTrue(f.showsInActiveScenario(load2), "its load moved to Scenario 1, nothing deleted")
    }

    /// Addendum 03:32: switch anchors off in Scenario 2, Scenario 1 unchanged, the last one on refuses, relaunch keeps both.
    func testAnchorSwitchIsPerScenarioKeepsOneOnAndSurvivesARelaunch() throws {
        var (f, s1, s2) = twoScenarios()
        let order = [anchorA, anchorB, load1, load2]
        XCTAssertNil(f.setAnchor(anchorA, on: false, in: s2, order: order))
        XCTAssertFalse(f.anchorIsOn(anchorA, in: s2))
        XCTAssertTrue(f.anchorIsOn(anchorA, in: s1), "★ Scenario 1 is unchanged")
        XCTAssertEqual(f.setAnchor(anchorB, on: false, in: s2, order: order), LoadScenarioRule.lastAnchorRefusal,
                       "★ the last anchor on refuses with the inline line")
        XCTAssertTrue(f.anchorIsOn(anchorB, in: s2))
        XCTAssertEqual(f.anchorsOn(in: s2, order: order), [anchorB])
        XCTAssertEqual(f.anchorsOn(in: s1, order: order), [anchorA, anchorB])
        // relaunch
        let back = try JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.anchorsOn(in: s2, order: order), [anchorB])
        XCTAssertEqual(back.anchorsOn(in: s1, order: order), [anchorA, anchorB])
        XCTAssertEqual(back.scenarioID(of: load2), s2)
    }

    func testDeletingAGroupDropsItFromEveryScenario() {
        var (f, _, s2) = twoScenarios()
        _ = f.setAnchor(anchorA, on: false, in: s2, order: [anchorA, anchorB])
        f.sync(groups: [])
        XCTAssertEqual(f.scenarios?.owner.isEmpty, true)
        XCTAssertEqual(f.scenarios?.scenarios[1].anchorsOff.isEmpty, true)
    }

    /// ★ HIS iPad 14:13 (1): in a scenario, nothing of another scenario draws; a switched-off anchor draws faint.
    func testOtherScenariosDrawNothingAndAnOffAnchorDrawsFaint() {
        var (f, s1, s2) = twoScenarios()
        XCTAssertEqual(f.scenarioDraw(load1, applies: true), .hidden, "★ Scenario 1's load, in Scenario 2")
        XCTAssertEqual(f.scenarioDraw(load2, applies: true), .shown)
        XCTAssertEqual(f.scenarioDraw(keep, applies: true), .shown, "no load/anchor role: every scenario")
        _ = f.setAnchor(anchorA, on: false, in: s2, order: [anchorA, anchorB])
        XCTAssertEqual(f.scenarioDraw(anchorA, applies: true), .dimmed, "★ off here: faint, never gone")
        XCTAssertEqual(f.scenarioDraw(anchorA, applies: false), .shown, "off Topology: everything")
        f.openScenario(s1)
        XCTAssertEqual(f.scenarioDraw(load1, applies: true), .shown); XCTAssertEqual(f.scenarioDraw(load2, applies: true), .hidden)
        XCTAssertEqual(f.scenarioDraw(anchorA, applies: true), .shown, "on in Scenario 1")
        // the keep-out volumes as drawn
        let vol = ClearanceVolume(faceID: 1, kind: .bolt, shape: .degenerate)
        let items = [anchorA, load1, load2].map { _ in ClearanceRenderItem(volume: vol, selected: false) }
        f.openScenario(s2)
        let drawn = SelectionArrowRule.keepOuts(items, pieces: [(anchorA, 1), (load1, 2), (load2, 3)], hidden: [],
                                                draw: { f.scenarioDraw($0, applies: true) })
        XCTAssertEqual(drawn.count, 2, "★ Scenario 1's load draws no keep-out in Scenario 2")
        XCTAssertEqual(drawn[0].faceAlpha, SelectionArrowRule.faintFaceAlpha, "★ the off anchor's keep-out is faint")
        XCTAssertNil(drawn[1].faceAlpha)
        let pieceHidden = SelectionArrowRule.keepOuts(items, pieces: [(anchorA, 1), (load1, 2), (load2, 3)],
                                                      hidden: [.init(group: load2, key: 3)], draw: { _ in .shown })
        XCTAssertEqual(pieceHidden.count, 2, "a hidden piece draws none")
    }

    // MARK: the wire (overnight release's shared key)

    private func request(_ scenarios: [LoadScenarioWire]) -> RunRequest {
        var r = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/x", rulesPath: "/y", resolution: 40, projectName: "p",
                           anchorFaceIDs: [1, 2], loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -10))])
        r.scenarios = scenarios
        return r
    }

    func testOneScenarioSendsTodaysJobByteIdentical() throws {
        let a = try RemoteRun.buildJobJSON(request([]))
        let b = try RemoteRun.buildJobJSON(request([LoadScenarioWire(name: "Scenario 1", anchorFaceIDs: [1, 2],
                                                                        loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -10))])]))
        let ja = try JSONSerialization.jsonObject(with: a) as! NSDictionary, jb = try JSONSerialization.jsonObject(with: b) as! NSDictionary
        XCTAssertEqual(ja, jb, "★ 0 or 1 scenario: the job is exactly today's")
        XCTAssertFalse(String(decoding: a, as: UTF8.self).contains("scenarios"))
    }

    func testTwoScenariosSendLoadsScenarios() throws {
        let s = [LoadScenarioWire(name: "Scenario 1", anchorFaceIDs: [1, 2], loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -10))]),
                 LoadScenarioWire(name: "Held by one plate", anchorFaceIDs: [2], loadGroups: [.init(faceIDs: [7], force: SIMD3(10, 0, 0))])]
        let job = try JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(request(s))) as! [String: Any]
        let loads = job["loads"] as! [String: Any]
        let sc = loads["scenarios"] as! [[String: Any]]
        XCTAssertEqual(sc.map { $0["name"] as! String }, ["Scenario 1", "Held by one plate"])
        XCTAssertEqual(sc[1]["anchor_face_ids"] as! [Int], [2], "★ each scenario's ON anchors")
        let g = (sc[1]["groups"] as! [[String: Any]])[0]
        XCTAssertEqual(g["face_ids"] as! [Int], [7]); XCTAssertEqual(g["force"] as! [Double], [10, 0, 0])
        XCTAssertEqual(loads["anchor_face_ids"] as! [Int], [1, 2], "the top level mirrors Scenario 1")
        XCTAssertEqual(((loads["groups"] as! [[String: Any]])[0]["face_ids"]) as! [Int], [5])
    }

    // MARK: results

    func testResultsNameTheGoverningScenarioAndSayUnheldPlainly() {
        let r = ScenarioResult.parse(["scenarios": [
            ["name": "Scenario 1", "margin": 2.4, "governs": false, "unheld": false],
            ["name": "Held by one plate", "margin": 1.31, "governs": true, "unheld": false],
            ["name": "Scenario 3", "margin": 0, "governs": false, "unheld": true]]])
        XCTAssertEqual(ScenarioResult.lines(r), ["Worst case: Held by one plate · 1.31×",
                                                 "Scenario 3's load has no path to its anchors"])
        XCTAssertEqual(ScenarioResult.lines(ScenarioResult.parse([:])), [], "no scenarios block: no line")
    }

    /// Ruling 2026-10-26 12:46: each strengthen version card names its governing scenario from versions[].scenarios.
    func testEachStrengthenCardNamesItsWorstScenario() {
        let sc: [[String: Any]] = [["name": "Scenario 1", "margin": 3.1, "governs": false, "unheld": false],
                                   ["name": "Left plate off", "margin": 2.04, "governs": true, "unheld": false]]
        let blocks = RunReportBlocks.decode(report: ["strengthen": [
            "as_drawn_margin": 1.5, "margin_required": 1.5, "ceiling_margin": 9, "original_mass_grams": 40, "coarse_resolution": 24,
            "versions": [["version": 1, "stress_cut": 0.25, "status": "verified", "volume_fraction": 0.3, "verified_margin": 2.04,
                          "mass_grams": 30, "mass_fraction_of_original": 0.75, "note": "", "target_margin": 2.0, "scenarios": sc],
                         ["version": 2, "stress_cut": 0.5, "status": "verified", "volume_fraction": 0.4, "verified_margin": 3.0,
                          "mass_grams": 36, "mass_fraction_of_original": 0.9, "note": ""]]]])
        let cards = StrengthenText.cards(blocks)
        XCTAssertTrue(cards[0].lines.contains("Worst case: Left plate off · 2.04×"), "\(cards[0].lines)")
        XCTAssertFalse(cards[1].lines.contains { $0.hasPrefix("Worst case") }, "a one-scenario version: no line")
        // 362's order: margin, mass, (note), Worst case, thin joints last; a refused best try names the worst in its line
        XCTAssertEqual(cards[0].lines, ["Margin 2.04×", "30.0 g · 75 % of the original", "Worst case: Left plate off · 2.04×"])
        let refused = RunReportBlocks.decode(report: ["strengthen": [
            "as_drawn_margin": 1.0, "margin_required": 1.5, "ceiling_margin": 9, "original_mass_grams": 40, "coarse_resolution": 24,
            "versions": [["version": 1, "stress_cut": 0.25, "status": "unreachable", "volume_fraction": 0.3, "verified_margin": 1.42,
                          "mass_grams": 30, "mass_fraction_of_original": 0.75, "note": "", "target_margin": 1.5,
                          "scenarios": [["name": "Scenario 1", "margin": 2.0, "governs": false, "unheld": false],
                                        ["name": "Scenario 2", "margin": 1.42, "governs": true, "unheld": false]]]]]])
        XCTAssertEqual(StrengthenText.cards(refused)[0].lines, ["Best try 1.42×, needed 1.50× — worst: Scenario 2"])
    }

    // MARK: the safety margin (ruling 2026-10-26 13:12)

    func testSafetyMarginDefaultsTo150StoresNothingAndRefusesBelow() throws {
        var f = ForceModel()
        XCTAssertEqual(f.safetyMarginValue, 1.5)
        XCTAssertEqual(f.setSafetyMargin(1.2), "The safety margin can't be below 150% of the load")
        XCTAssertEqual(f.safetyMarginValue, 1.5, "a refusal changes nothing")
        XCTAssertNil(f.setSafetyMargin(2.0)); XCTAssertEqual(f.safetyMarginValue, 2.0)
        let back = try JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back.safetyMarginValue, 2.0, "survives a relaunch")
        f.setSafetyMargin(1.5)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(f), as: UTF8.self).contains("safetyMargin"), "150 % stores nothing")
        XCTAssertEqual(SafetyMargin.parseCustom("175%"), .success(1.75))
        XCTAssertEqual(SafetyMargin.parseCustom("149"), .failure(.init(line: SafetyMargin.belowMinimumLine)))
        XCTAssertEqual(SafetyMargin.presets.map(\.label), ["Light use: 150% of your load", "Everyday part: 200%",
                                                         "Repeated loads, or hard to replace: 300%"])
        XCTAssertEqual(SafetyMargin.label(for: 1.75), "Custom: 175%")
        XCTAssertEqual(SafetyMargin.info, "150% means a safety factor of 1.5. Printing's weaker layers and infill are already counted.")
        XCTAssertEqual(SafetyMargin.builtForLine(2), "Built for 200% of your load")
    }

    /// TO-core's key (13:34): loads.safety_margin, a multiple of the load; 150 % (the default) sends nothing, so an untouched
    /// project's job is byte-identical.
    func testTheSafetyMarginGoesOutAsLoadsSafetyMarginOnlyWhenNot150() throws {
        XCTAssertEqual(SafetyMargin.jobKey, "safety_margin")
        var r = request([]); r.safetyMargin = 2
        let job = try JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(r)) as! [String: Any]
        XCTAssertEqual((job["loads"] as? [String: Any])?["safety_margin"] as? Double, 2)
        let plain = try JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(request([]))) as! [String: Any]
        XCTAssertNil((plain["loads"] as? [String: Any])?["safety_margin"], "150 %: no key")
    }

    /// The new ladder's words, only on a report that carries `safety_margin`; a 25/50/75 % report keeps its titles.
    func testTheNewLadderTitlesOnlyWithANewReport() {
        func report(_ margin: Double?) -> [String: Any] {
            var s: [String: Any] = ["as_drawn_margin": 1.2, "margin_required": 1.5, "ceiling_margin": 9, "original_mass_grams": 40,
                                    "coarse_resolution": 24,
                                    "versions": [1, 2, 3].map { ["version": $0, "stress_cut": 0.25 * Double($0), "status": "verified",
                                                                 "volume_fraction": 0.1 * Double($0), "verified_margin": 1.5, "mass_grams": 30,
                                                                 "mass_fraction_of_original": 0.7, "note": ""] as [String: Any] }]
            if let margin { s["safety_margin"] = margin }
            return ["strengthen": s]
        }
        XCTAssertEqual(StrengthenText.cards(RunReportBlocks.decode(report: report(1.5))).map(\.title),
                       ["Version 1: just safe", "Version 2: +10%", "Version 3: +10%"])
        XCTAssertEqual(StrengthenText.cards(RunReportBlocks.decode(report: report(nil))).map(\.title),
                       ["Version 1 · 25 % less worst stress", "Version 2 · 50 % less worst stress", "Version 3 · 75 % less worst stress"])
        XCTAssertEqual(RunReportBlocks.decode(report: report(2)).safetyMargin, 2)
        XCTAssertNil(RunReportBlocks.decode(report: report(nil)).safetyMargin)
    }

    /// His ask (resizable): the grip's drag moves the height twice the finger (the panel grows about its centre), floored at
    /// two lines and capped at the screen's room; the room is the canvas less the chrome PageLeftModal keeps.
    func testTheGripResizesWithinTheScreen() {
        XCTAssertEqual(SelectionsList.resized(from: 500, drag: -100, max: 900), 300)
        XCTAssertEqual(SelectionsList.resized(from: 500, drag: 300, max: 900), 900, "capped at the screen")
        XCTAssertEqual(SelectionsList.resized(from: 200, drag: -400, max: 900), SelectionsList.lineHeight * 2, "never gone")
        let portrait = SelectionsList.screenMax(canvasHeight: 1376, footerReserve: 190)
        let landscape = SelectionsList.screenMax(canvasHeight: 1032, footerReserve: 190)
        XCTAssertGreaterThan(portrait, 700, "★ much bigger than the old 420 in portrait (\(portrait))")
        XCTAssertLessThan(landscape, portrait)
        XCTAssertGreaterThanOrEqual(landscape, SelectionsList.maxListHeight)
    }

    func testTheInfoIsHisSentence() {
        XCTAssertEqual(LoadScenarioRule.info, "Each scenario is checked on its own. Loads in different scenarios never act together; loads in the same scenario act together. Each scenario shapes the part in proportion to its load: a light one adds only a light connection, and one under 3% of the heaviest can't shape the part and is refused.")
    }

    // MARK: Optimize's pre-flight (362's ruling 2026-10-26): core's own words, before the send

    private func wire(_ name: String, anchors: [Int], loads: Int) -> LoadScenarioWire {
        LoadScenarioWire(name: name, anchorFaceIDs: anchors,
                         loadGroups: Array(repeating: .init(faceIDs: [5], force: SIMD3(0, 0, -10)), count: loads))
    }

    func testOptimizeRefusesWhatCoreRefusesInItsWords() {
        let ok = [wire("Scenario 1", anchors: [1], loads: 1), wire("Held by one plate", anchors: [2], loads: 1)]
        XCTAssertNil(LoadScenarioRule.refusal(for: request(ok), workerSelected: true))
        XCTAssertNil(LoadScenarioRule.refusal(for: request([]), workerSelected: false), "no scenarios: never refused here")
        XCTAssertEqual(LoadScenarioRule.refusal(for: request([ok[0], wire("Held by one plate", anchors: [], loads: 1)]), workerSelected: true),
                       "Scenario “Held by one plate” has no anchor switched on")
        XCTAssertEqual(LoadScenarioRule.refusal(for: request([ok[0], wire("Scenario 2", anchors: [2], loads: 0)]), workerSelected: true),
                       "Scenario “Scenario 2” has no load")
        XCTAssertEqual(LoadScenarioRule.refusal(for: request(ok), workerSelected: false), LoadScenarioRule.onDeviceLine,
                       "★ the iPad's solver would check Scenario 1 alone")
        var strengthen = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/x", rulesPath: "/y", resolution: 40,
                                    projectName: "p", anchorFaceIDs: [1], loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -10))],
                                    minimizePlastic: false, designBox: .init(min: SIMD3(0, 0, 0), max: SIMD3(1, 1, 1)))
        strengthen.scenarios = ok
        XCTAssertNil(LoadScenarioRule.refusal(for: strengthen, workerSelected: true),
                     "★ scenarios WITH Redesign to strengthen are sent (his order 2026-10-26 12:46)")
        XCTAssertEqual(strengthen.forWorker().redesign, StrengthenRoute.redesignValue, "and carry loads.redesign")
    }

    /// The gap: an anchor group deleted while the other is off leaves a scenario with none on; the request is refused
    /// and the one-tap fix switches its anchors back on.
    func testADeletedAnchorGroupNeverSendsAScenarioWithNoAnchor() {
        var (f, s1, s2) = twoScenarios()
        XCTAssertNil(f.setAnchor(anchorA, on: false, in: s2, order: [anchorA, anchorB]))
        f.clearKind(anchorB)   // the group with the last anchor on is deleted
        XCTAssertEqual(f.anchorsOn(in: s2, order: [anchorA, anchorB]), [], "★ the gap")
        XCTAssertEqual(f.anchorsOn(in: s1, order: [anchorA, anchorB]), [anchorA])
        f.switchAllAnchorsOn(in: s2)
        XCTAssertEqual(f.anchorsOn(in: s2, order: [anchorA, anchorB]), [anchorA], "the one-tap fix")
    }

    /// The workspace wiring (source pins).
    func testTheWorkspaceUsesTheScenarios() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("force.kind(for: $0.id).isLoad && scenarioDraws($0.id)"), "load arrows + chips: the open scenario only")
        XCTAssertTrue(src.contains("!project.groupView.isHidden(g.id) && scenarioDraws(g.id)"), "tints: the open scenario only")
        XCTAssertTrue(src.contains("scenarioAnchorOff(g.id)"), "an anchor off here is dimmed, not hidden")
        XCTAssertTrue(src.contains("force.addScenario()"), "+ Add a load scenario")
        XCTAssertTrue(src.contains("LoadScenarioRule.info"), "the (i)")
        XCTAssertTrue(src.contains("if let no = LoadScenarioRule.refusal(for: request, workerSelected: compute.activeRemote != nil) { model.toast = no; return }"), "Optimize's pre-flight")
        XCTAssertTrue(src.contains("force.switchAllAnchorsOn(in: s.id)"), "the gap's one-tap fix")
        // (the controls themselves are found ON SCREEN in LoadScenarioHostedTests; these only pin the wiring)
        XCTAssertFalse(src.contains("selectionsListBody"), "★ no dead copy in the old library card")
    }
}
