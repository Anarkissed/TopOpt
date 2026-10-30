// FlexibleR7E2ParkTests — R7-E2 PARKED (round 7, 2026-10-19). His words: "Please finalize the sending edges to core as soon as
// possible - as we are more focussed on the front-end now. The back-end will come AFTER we have implemented the actual process."
// ONE switch (`FlexibleBackend.sendsPresses`, off) keeps every edge and corner press OUT of every request to core — the scene's
// designs, Auto, the preview lattice, the run job and the export — so the lattice, the face groups' squish and every job byte are
// what they were before E2 (E1's rule). The flat prism, its handles and its limits stay (the front-end). The press card says one
// plain line. E2's own tests run with the switch ON. RED CONTROL in each test, asserted red: the switch on.
// ★ RE-PINNED (C1, his words of 2026-10-20: "Please go ahead and finalize the send to core now"): the switch is KEPT and ON by
// default; these tests turn it OFF to pin that it still keeps every press out, and the card's line off is "Set up · core support
// pending" ("Shape only · core support comes later" is gone).

import XCTest
@testable import TopOptFlows
import TopOptKit

@MainActor
final class FlexibleR7E2ParkTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    override func setUp() {
        super.setUp()
        XCTAssertTrue(FlexibleBackend.sendsPresses, "★ C1: on by default")
        FlexibleBackend.sendsPresses = false
    }

    override func tearDown() {
        FlexibleBackend.sendsPresses = true   // ★ C1: the default
        FlexibleStageModel.controlStripPresses = false
        super.tearDown()
    }

    /// The gate itself: with every fact for (core takes it, stacked, designed, nothing shared), the switch off keeps it out with
    /// his one line, said as a plain caption. RED CONTROL: the switch on — the same facts send it.
    func testTheSwitchOffKeepsEveryPressOutOfTheJobWithOneLine() {
        func facts(_ backend: Bool) -> FlexiblePressSupport.Facts {
            FlexiblePressSupport.Facts(schema: true, bridge: true, api: FlexiblePressSupport.expectedAPI, stacked: nil, twoEntries: nil,
                                       shared: nil, designed: true, designRefusal: nil, conflict: nil, backend: backend)
        }
        XCTAssertFalse(FlexibleBackend.sendsPresses, "★ turned off by this test (C1: on by default)")
        let v = FlexiblePressSupport.verdict(facts(FlexibleBackend.sendsPresses))
        XCTAssertFalse(v.inJob, "★ never in the job")
        XCTAssertEqual(v.reason, .backendLater)
        XCTAssertEqual(v.line, FlexibleRowCopy.pressNotSent, "★ C1: the shape-only line is gone")
        XCTAssertLessThanOrEqual(v.line?.count ?? 99, FlexibleRowCopy.maxChars, "his rule: one line")
        // RED CONTROL: the switch on
        let red = FlexiblePressSupport.verdict(facts(true))
        XCTAssertTrue(red.inJob, "RED CONTROL (the switch on): the same facts send it")
    }

    /// What reaches core from his pad with his live lattice (FlexibleFlatPrismFixtures.hisLivePad: Group C = Face 3 + Face 5) and
    /// an edges group of Edge 16 + Edge 18 (the shape of his Group 3): with the switch off no press is designed by core, none is in
    /// Auto's request, the lattice's key is the faces' alone (E1's), every send's job writes no press and is byte-identical to E1's
    /// rule (the presses stripped), and each press card says the one plain line.
    /// RED CONTROL: the switch on — the presses are in the lattice's key and asked of core.
    func testHisPadsEdgePressesReachNoRequestToCore() async throws {
        let (_, m) = try await FlexibleFlatPrismFixtures.hisLivePad(self)
        let e16 = try await FlexibleFlatPrismFixtures.edge16(m)
        let first = try await FlexibleFlatPrismFixtures.commit(m, e16.c)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        m.rail = .group(try XCTUnwrap(m.squeezeGroup(ofPress: first.id)).id)
        m.syncEdgeAdd()
        try await FlexibleHisProject.waitFor(240, "the open group's edges") { m.edgeAdd.map { !$0.loading && !$0.checking } ?? false }
        let a = try XCTUnwrap(m.edgeAdd)
        let e18 = try XCTUnwrap(FlexibleM2Fixtures.edge(m, a, faces: [3, 4]), "Edge 18")
        let addWhy = await m.addEdgeToGroup(e18.number)
        XCTAssertNil(addWhy)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        let strips = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(strips.count, 2, "premise: an edges group of Edge 16 + Edge 18")
        try await FlexibleHisProject.waitFor(120, "his presses registered") { strips.allSatisfy { m.pressKey($0.id) != nil } }
        await m.waitForIdle()

        func ignored() -> [String] {
            var why: [String] = []
            if !m.sentPresses.isEmpty { why.append("sent \(m.sentPresses.count)") }
            if !m.pressDesignTargets.isEmpty { why.append("designed by core \(m.pressDesignTargets.count)") }
            if m.settings.designInputs.presses != nil { why.append("in the lattice's key") }
            if m.latticeSettingsKey != m.settings.designInputs.hashValue { why.append("lattice key moved") }
            if m.designs.keys.contains(where: { $0.region <= FlexibleStageModel.syntheticPressMax }) { why.append("a press design held") }
            return why
        }
        XCTAssertEqual(ignored(), [], "★ the switch off: no press reaches core")
        for p in strips {
            let w = try XCTUnwrap(m.pressWarning(p.id), "\(p.strip?.label ?? "") has its line")
            XCTAssertEqual(w.line, FlexibleRowCopy.pressNotSent, "★ C1: the card's line off (the shape-only line is gone)")
            XCTAssertTrue(w.fixes.isEmpty)
        }
        // every send's job: no press written, and the bytes of E1's rule
        var jobs: [String: String] = [:]
        let sends = G.sends(m)
        for send in sends { jobs[send.title] = try? m.runJobJSON(resting: Set(send.resting)) }
        jobs["(all)"] = try? m.runJobJSON(resting: [])
        for (title, job) in jobs {
            XCTAssertFalse(job.contains("press_direction"), "\(title): no press written")
            XCTAssertFalse(job.contains("face_region_ids"), "\(title): no press written")
        }
        FlexibleStageModel.controlStripPresses = true   // E1's rule (before E2): every press stripped
        for send in sends { XCTAssertEqual(try? m.runJobJSON(resting: Set(send.resting)), jobs[send.title], "★ \(send.title): E1's bytes") }
        XCTAssertEqual(try? m.runJobJSON(resting: []), jobs["(all)"], "★ the whole job: E1's bytes")
        FlexibleStageModel.controlStripPresses = false
        print("FLEX-E2P-2 his pad (live lattice) + Edge 16 + Edge 18: \(strips.count) presses · sends \(sends.map(\.title)) · jobs \(jobs.mapValues { $0.count })"
              + " · lines \(strips.map { m.pressWarning($0.id)?.line ?? "-" })")

        // RED CONTROL: the switch on
        FlexibleBackend.sendsPresses = true
        let red = ignored()
        print("FLEX-E2P-2 RED CONTROL (the switch on): \(red)")
        XCTAssertFalse(red.isEmpty, "RED CONTROL (the switch on): the presses reach core")
        FlexibleBackend.sendsPresses = false
    }
}
