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
        XCTAssertEqual(ScenarioResult.lines(r), ["Worst case: Held by one plate · margin 1.31×",
                                                 "Scenario 3's load has no path to its anchors"])
        XCTAssertEqual(ScenarioResult.lines(ScenarioResult.parse([:])), [], "no scenarios block: no line")
    }

    func testTheInfoIsHisSentence() {
        XCTAssertEqual(LoadScenarioRule.info, "Each scenario is checked on its own. Loads in different scenarios never act together; loads in the same scenario act together.")
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
    }
}
