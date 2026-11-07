// LatticeE2WiringHostedTests — release (2) (the reviewer's ruling 11-06 09:41Z, part 1: UI-Notes' half of the app): B6's
// saved keys reach the job. Start from − goes as `lattice.whole_part` and the scenario folder switches as `lattice.scenarios`,
// each once the linked core takes its key (E2, in release (2)'s core 1635694a21b3; the probes read the schema, so they pin no
// fingerprint), and each "until the engine
// update" line goes with it. A switched-off Topology group leaves the lattice job's loads and holds app-side, with no core
// key (as agreed 11-04 19:30Z), except on "Lattice an optimized result", whose load case is its run's own: one plain line
// says so (pick (a), asked 09:49Z). Protect skin keeps "runs as No lattice" until E2.4.
//
// RED before (saved: scratchpad b2red/LatticeE2Wiring_build.txt): no `LatticeSpec.wholePart` / `scenariosLeftOut`, no
// `loadCase(leavingOut:)`, no plain line for the result.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeE2WiringHostedTests: XCTestCase {

    /// The pad (three scenarios, two holds, the 51 kg push on Group C) on Structural, one lattice group of his Top, saved.
    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel, AppModel) {
        let (h, p, app) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let f = try XCTUnwrap(p.selection.groups.first?.faces.first)
        _ = p.latticeStageTap(face: f, loop: [f])
        let g = try XCTUnwrap(p.latticeList.activeGroupID)
        p.lattice.groupRoles[g] = .include
        p.lattice.enabled = true   // as Save on the Lattice page leaves it
        p.latticeList.clearActive()
        h.pump(1)
        return (h, p, app)
    }

    func job(_ r: RunRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(r)) as? [String: Any])
    }

    /// ★ Start from − is `lattice.whole_part` once core takes it; + writes nothing; the plain line shows exactly until then.
    func testStartFromMinusGoesAsWholePart() throws {
        let (h, p, app) = try stage()
        let live = TopOptKit.latticeWholePartWired
        XCTAssertNil(try job(try XCTUnwrap(app.makeLatticeRunRequest()))["lattice"].flatMap { ($0 as? [String: Any])?["whole_part"] },
                     "+ : no key")
        p.lattice.wholePart = true
        h.pump(0.5)
        let r = try XCTUnwrap(app.makeLatticeRunRequest())
        let block = try XCTUnwrap(try job(r)["lattice"] as? [String: Any])
        XCTAssertEqual(block["whole_part"] as? Bool, live ? true : nil, "★ − reaches the job exactly when core takes the key")
        XCTAssertEqual(h.frames.all["latticeWholePartWaits"] != nil, !live, "★ the plain line goes when the key is live")
        // Optimize, then lattice carries the same block
        let both = try XCTUnwrap(try job(try XCTUnwrap(app.makeRunRequest(lattice: true)))["lattice"] as? [String: Any])
        XCTAssertEqual(both["whole_part"] as? Bool, live ? true : nil)
        if live { XCTAssertNil(TopOptKit.jobSchemaError(try RemoteRun.buildJobJSON(r)), "★ core takes the job the app builds") }
    }

    /// ★ The scenario folder switches are `lattice.scenarios`: every scenario the job carries but the switched-off ones. The
    /// job still sends all three (the optimization's and the certificate's sizing list); the plain line shows until live.
    func testScenarioSwitchesGoAsLatticeScenarios() throws {
        let (h, p, app) = try stage()
        let live = TopOptKit.latticeScenariosWired
        // ★ the probe's control passes on every core — else "not live" would mean "the probe's job is wrong" (its first
        // draft carried the base job's fixture_faces / gravity / ladder / margin_stop, which core refuses beside "loads")
        XCTAssertNil(TopOptKit.latticeScenariosProbe().control, "the scenarios probe's control job must pass")
        if TopOptKit.latticeSchemaAccepts(key: "whole_part") {
            XCTAssertTrue(live, "E2 ships both keys: the scenarios probe's own job is wrong")
        }
        XCTAssertNil((try job(try XCTUnwrap(app.makeLatticeRunRequest()))["lattice"] as? [String: Any])?["scenarios"],
                     "all on: no key — core's own every scenario")
        let held = try XCTUnwrap(p.force.scenarioList.first { $0.name == "Held by right plate" })
        try h.tap("latticeTopologyPanelHeader", "Topology's header", settle: 1)
        try h.tap("latticeInclude-\(held.id.uuidString)", "Held by right plate's switch", settle: 1)
        XCTAssertEqual(p.lattice.topologyExcluded, [held.id])
        let r = try XCTUnwrap(app.makeLatticeRunRequest())
        let doc = try job(r)
        let block = try XCTUnwrap(doc["lattice"] as? [String: Any])
        XCTAssertEqual(block["scenarios"] as? [String], live ? ["Normal use", "Held by left plate"] : nil, "★ the switched-on two")
        XCTAssertEqual(((doc["loads"] as? [String: Any])?["scenarios"] as? [[String: Any]])?.count, 3, "★ the job keeps all three")
        XCTAssertEqual(h.frames.all["latticeIncludeWaits"] != nil, !live, "★ the plain line goes when the key is live")
        XCTAssertNil(h.frames.all["latticeResultKeepsGroups"], "a scenario is not a group: no result line")
        if live { XCTAssertNil(TopOptKit.jobSchemaError(try RemoteRun.buildJobJSON(r)), "★ core takes the job the app builds") }
        XCTAssertEqual(LatticeSetupCopy.includeWaits, "The run still uses every scenario until the engine update")
    }

    /// ★ "Lattice an optimized result": the names go only where its run carried them — every one the run had but the
    /// switched-off ones; none when its run had no scenarios, or none it had is off.
    func testAResultsReLatticeNamesItsRunsScenarios() throws {
        let (_, p, _) = try stage()
        var spec = try XCTUnwrap(p.latticeRunSpec(emission: p.latticeJobRegions()))
        func names(_ original: [String: Any], leftOut: [String]) throws -> [String]? {
            spec.scenariosLeftOut = leftOut
            let data = try RelatticeJobBuilder.build(original: try JSONSerialization.data(withJSONObject: original),
                                                     designFingerprint: 7, achievedVolumeFraction: 0.4,
                                                     designFileName: "design.bin", lattice: spec)
            let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (doc["lattice"] as? [String: Any])?["scenarios"] as? [String]
        }
        let one: (String) -> [String: Any] = { ["name": $0, "groups": [["force": [0, 0, -10], "face_ids": [1]]], "anchor_face_ids": [2]] }
        let ran: [String: Any] = ["model": "part.step", "loads": ["scenarios": ["a", "b", "c"].map(one)]]
        XCTAssertEqual(try names(ran, leftOut: ["b"]), ["a", "c"], "★ its run's own, less the switched-off")
        XCTAssertNil(try names(ran, leftOut: ["added since"]), "none it had is off: no key")
        XCTAssertNil(try names(ran, leftOut: []), "all on: no key")
        XCTAssertNil(try names(["model": "part.step", "loads": [:] as [String: Any]], leftOut: ["b"]), "its run had none: no key")
        XCTAssertEqual(try names(ran, leftOut: ["a", "b", "c"]), [], "every one off: core refuses it in its own words")
    }

    /// ★ A switched-off group leaves the lattice job's loads and holds — Lattice the original part and Optimize, then lattice
    /// (its optimization too, his 23b) — and Topology's own Optimize keeps it. The result's re-lattice keeps every group, and
    /// the panel says so in one plain line.
    func testASwitchedOffGroupLeavesTheLatticeJob() throws {
        let (h, p, app) = try stage()
        let push = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "the 51 kg push")
        let hold = try XCTUnwrap(p.selection.groups.first { p.force.kind(for: $0.id).isAnchor }, "a hold")
        let before = try XCTUnwrap(app.makeLatticeRunRequest())
        XCTAssertFalse(before.loadGroups.isEmpty)
        try h.tap("latticeTopologyPanelHeader", "Topology's header", settle: 1)
        let normal = try XCTUnwrap(p.force.scenarioList.first)
        try h.tap("latticeTopoFolder-\(normal.id.uuidString)", "Normal use's folder: its groups", settle: 1)
        XCTAssertNil(h.frames.all["latticeResultKeepsGroups"], "all on: nothing to say")
        p.lattice.topologyExcluded.insert(push.id)   // its switch (in Normal use's folder; LatticeTopologyPanelHostedTests taps one)
        h.pump(1)
        let lp = try XCTUnwrap(app.makeLatticeRunRequest())
        XCTAssertTrue(lp.loadGroups.isEmpty, "★ Normal use's push leaves Lattice the original part")
        XCTAssertTrue(try XCTUnwrap(lp.scenarios.first { $0.name == "Normal use" }).loadGroups.isEmpty, "★ and its scenario")
        XCTAssertEqual(lp.scenarios.first { $0.name == "Held by left plate" }?.loadGroups.count, 1, "the others keep theirs")
        XCTAssertTrue(try XCTUnwrap(app.makeRunRequest(lattice: true)).loadGroups.isEmpty, "★ Optimize, then lattice too")
        XCTAssertEqual(try XCTUnwrap(app.makeRunRequest(lattice: false)).loadGroups, before.loadGroups,
                       "★ Topology's own Optimize keeps every group")
        _ = try h.onScreen("latticeResultKeepsGroups", "★ the result's re-lattice keeps every group, said once")
        XCTAssertNil(h.frames.all["latticeIncludeWaits"], "a group's switch is live in the app: no engine line")

        p.lattice.topologyExcluded.insert(hold.id)
        h.pump(0.5)
        let unheld = try XCTUnwrap(app.makeLatticeRunRequest())
        let gone = Set(before.anchorFaceIDs).subtracting(unheld.anchorFaceIDs)
        XCTAssertEqual(gone.count, hold.faces.count, "★ a switched-off hold leaves the job (core's guard speaks if unheld)")
        XCTAssertTrue(Set(unheld.anchorFaceIDs).isSubset(of: before.anchorFaceIDs), "the other hold stays")
        for s in unheld.scenarios { XCTAssertTrue(gone.isDisjoint(with: s.anchorFaceIDs), "★ in \(s.name) too") }

        // (b), the reviewer's ruling 10:45Z: Protect and Keep clear always apply. The pad's second hold carries the Protect
        // (Group D): switched off, its hold leaves the job, its Protect stays, and one line says so.
        XCTAssertNil(h.frames.all["latticeProtectStillApplies"], "no Protect is off yet")
        let protected = try XCTUnwrap(p.selection.groups.first { p.force.isProtected($0.id) }, "the pad's Protect (Group D)")
        let protections = try XCTUnwrap(app.makeLatticeRunRequest()).faceProtections
        XCTAssertFalse(protections.isEmpty)
        _ = try h.probe("latticeInclude-\(protected.id.uuidString)", "a hold that carries a Protect has its switch")
        p.lattice.topologyExcluded.insert(protected.id)
        h.pump(0.5)
        _ = try h.onScreen("latticeProtectStillApplies", "★ Protect still applies, said once")
        XCTAssertEqual(try XCTUnwrap(app.makeLatticeRunRequest()).faceProtections, protections, "★ the job keeps the Protect")
        XCTAssertEqual(LatticeSetupCopy.protectStillApplies, "Protect and Keep clear still apply to switched-off groups.")
        // a Protect-only group shows no switch, and a stored "off" for it (an older s2a project) leaves nothing out
        let used = Set(p.selection.groups.flatMap(\.faces))
        let free = try XCTUnwrap((0..<64).map { FaceID($0) }.first { !used.contains($0) && p.viewerMesh?.faceIDs.contains($0) == true })
        let skin = p.selection.addGroup()
        p.selection.addFaces([free], to: skin)
        p.force.setProtected(skin, true)
        p.force.sync(groups: p.selection.groups)
        h.pump(1)
        _ = try h.onScreen("latticeTopo-\(skin.uuidString)", "the Protect-only group's row")
        XCTAssertNil(h.frames.all["latticeInclude-\(skin.uuidString)"], "★ (b): no switch on a Protect-only row")
        XCTAssertFalse(p.latticeGroupSwitches(skin))
        p.lattice.topologyExcluded.insert(skin)
        XCTAssertFalse(p.latticeLeftOutGroups.contains(skin), "★ a stored off leaves no Protect out")

        p.lattice.enabled = false
        XCTAssertEqual(try XCTUnwrap(app.makeRunRequest()).loadGroups, before.loadGroups, "no lattice in the job: every group")
        XCTAssertEqual(LatticeSetupCopy.resultKeepsGroups,
                       "Lattice an optimized result keeps every group: it is checked under the loads it was optimized with.")
    }
}
#endif
