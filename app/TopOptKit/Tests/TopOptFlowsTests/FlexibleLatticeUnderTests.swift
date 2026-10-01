import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ BATCH E (the Flexible half of his item 4). A split piece is now latticed (LatticeSectorOutline),
/// so the Flexible lattice sits where the main page's Lattice roles put it — on his pad (img 4 state)
/// under 'top A' only. 'top B' is still pressed with no lattice under it. That is SAID at once (never a
/// blocker: the lattice still builds), with [Lattice under it] [Top B rests].
final class FlexibleLatticeUnderTests: XCTestCase {

    // MARK: the rule, on values

    private func face(_ r: Int, share: Double?) -> FlexibleReadiness.Face {
        FlexibleReadiness.Face(region: r, weightKg: 10, stacked: true, design: .ok, drawn: true, areaMM2: 100,
                               latticedShare: share)
    }

    private func inputs(_ faces: [FlexibleReadiness.Face], canFix: Bool = true) -> FlexibleReadiness.Inputs {
        var i = FlexibleReadiness.Inputs(materialID: "varioshore_tpu", materialName: "colorFabb varioShore TPU (foaming)",
                                         calibrateFirst: false, withData: (id: "varioshore_tpu", name: "colorFabb varioShore TPU"),
                                         pressed: faces, nozzleIsAuto: true)
        i.canLatticeUnder = { _ in canFix }
        return i
    }

    func testAFaceWithNoLatticeUnderItIsSaidNeverBlocking() throws {
        let r = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)]))
        let i = try XCTUnwrap(r.issues.first { $0.kind == .noLatticeUnder }, "★ said")
        XCTAssertEqual(i.region, 2)
        XCTAssertEqual(i.oneLine, "Face 2 has no lattice under it, so it can't squish")
        XCTAssertFalse(i.blocking, "★ never a blocker: the lattice still builds")
        XCTAssertEqual(i.fixes, [.latticeUnder(2), .rest(2)])
        XCTAssertTrue(r.isReady)
        XCTAssertEqual(FlexibleExitDecision.decide(r), .exit, "★ Exit still builds")
        XCTAssertTrue(r.popping.contains { $0.id == i.id }, "★ it pops on the action that caused it")
        XCTAssertEqual(r.advisory?.id, i.id, "the readiness line's [Fix] opens it")
        XCTAssertEqual(r.oneLine, "Ready · No lattice under Face 2")
        XCTAssertEqual(FlexibleFix.latticeUnder(2).title { "Face \($0)" }, "Lattice under it")
        // a little lattice, said with its number; enough lattice, nothing; no stack yet, nothing
        let little = FlexibleReadiness.evaluate(inputs([face(3, share: 0.234)]))
        XCTAssertEqual(little.issues.first { $0.kind == .noLatticeUnder }?.oneLine, "Only 23 % of Face 3 has lattice under it")
        XCTAssertNil(FlexibleReadiness.evaluate(inputs([face(3, share: 0.8)])).issues.first { $0.kind == .noLatticeUnder })
        XCTAssertNil(FlexibleReadiness.evaluate(inputs([face(3, share: nil)])).issues.first { $0.kind == .noLatticeUnder })
        // no one-tap edit ⇒ only [rests]
        let noFix = FlexibleReadiness.evaluate(inputs([face(2, share: 0)], canFix: false))
        XCTAssertEqual(noFix.issues.first { $0.kind == .noLatticeUnder }?.fixes, [.rest(2)])
    }

    // MARK: his project (img 4 state), restored the way the app restores it

    @MainActor
    func testOnHisPadTopBIsSaidAndOneTapLatticesIt() async throws {
        let his = try FlexibleHisProject.restore(asSaved: true)
        addTeardownBlock { his.cleanup() }
        let p = his.project
        let m = try await FlexibleHisProject.openedModel(p, test: self, timeout: 120)
        // ★ the Flexible job now carries top A's prism (it was EMPTY: the whole part)
        let job = try XCTUnwrap(try m.sceneJob())
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.json.utf8)) as? [String: Any])
        func regions(_ o: Any) -> [[String: Any]]? {
            if let d = o as? [String: Any] {
                if let r = d["regions"] as? [[String: Any]] { return r }
                for v in d.values { if let r = regions(v) { return r } }
            }
            return nil
        }
        let wire = try XCTUnwrap(regions(obj), "★ FlexibleJob.regions is non-empty for his project")
        XCTAssertEqual(wire.count, 1, "top A's prism")
        // core's own count: top A latticed, top B none
        let a = FlexibleHisProject.topA, b = FlexibleHisProject.topB
        XCTAssertEqual(m.latticedShare(a) ?? -1, 1, accuracy: 1e-9, "top A: lattice under every column")
        XCTAssertEqual(m.latticedShare(b) ?? -1, 0, accuracy: 1e-9, "★ top B: none")
        let issue = try XCTUnwrap(m.readiness.issues.first { $0.kind == .noLatticeUnder }, "★ said at once")
        XCTAssertEqual(issue.region, b)
        XCTAssertEqual(issue.oneLine, "Top B has no lattice under it, so it can't squish")
        XCTAssertEqual(issue.fixes, [.latticeUnder(b), .rest(b)])
        XCTAssertTrue(m.readiness.isReady, "never a blocker")
        // ★ the main page says it too (once a lattice is built), and its tap opens this fix
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.latticeBuilding }
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        let status = FlexibleMainStatus.of(model: m)
        print("E-FLEX main status: \(status.line) · lattice \(m.lattice != nil) error \(m.latticeError ?? "-")")
        XCTAssertEqual(status.line, "No lattice under Top B", "★ the main page's pill")
        XCTAssertEqual(status.fix?.id, issue.id, "it carries the fix")
        // ★ RE-PINNED (batch E review): a preview tone — the big button still SENDS (its fix is on
        // Settings' line and the pop-up that opens with the page); the fix tone opened Settings on every tap
        XCTAssertEqual(status.tone, .preview)
        XCTAssertEqual(status.tap, .send)
        XCTAssertEqual(m.readiness.oneLine, "Ready · No lattice under Top B", "the Settings line")
        // the one tap: a main-page group of its own, protected + Lattice, as deep as the pad under it
        XCTAssertEqual(m.latticeUnderPlan(b), .newGroup(face: nil, region: 104, name: "Top B", depthMM: 20))
        let groupsBefore = p.selection.groups.count
        let kindsBefore = p.selection.groups.map { "\($0.id):\(p.force.kind(for: $0.id))" }
        FlexibleFixPopup.apply(.latticeUnder(b), to: m)
        let g = try XCTUnwrap(p.selection.groups.first { $0.regionIDs.contains(104) })
        XCTAssertEqual(p.selection.groups.count, groupsBefore + 1)
        XCTAssertEqual(g.name, "Top B")
        XCTAssertTrue(p.force.isProtected(g.id), "protect + lattice = lattice (his words)")
        XCTAssertEqual(p.lattice.groupRoles[g.id], .include)
        XCTAssertEqual(p.selection.groups.filter { $0.id != g.id }.map { "\($0.id):\(p.force.kind(for: $0.id))" }, kindsBefore,
                       "★ no main-page group's load or anchor moved")
        XCTAssertEqual(p.latticeJobRegions().regions.filter { $0.role == .include }.count, 2, "top A and top B")
        try await FlexibleHisProject.waitFor(120, "the scene re-opened on the new lattice") {
            m.sceneState == .ready && m.stacks[FlexFaceKey(region: b, rotation: 0)] != nil
        }
        await m.waitForIdle()
        XCTAssertEqual(m.latticedShare(b) ?? -1, 1, accuracy: 1e-9, "★ top B now has lattice under every column")
        XCTAssertNil(m.readiness.issues.first { $0.kind == .noLatticeUnder }, "★ nothing left to say")
    }

    /// ★ THE FIXTURE'S TAPS ARE THE PAGE'S OWN OFFER. `FlexibleHisProject.restore` replays, on each
    /// copy of his project, exactly the [Lattice under it] plans the readiness offers once a split piece
    /// is latticed — and with them every pressed face has lattice under EVERY column again (the
    /// placement the suites written on the whole-part lattice measure). RED control (mutation): with
    /// the old member rule the union is dropped, nothing is flagged, and the list reads [].
    @MainActor
    func testTheFixturesTapsAreWhatThePageOffers() async throws {
        for dir in [FlexibleHisProject.dir, FlexibleHisProject.round5Dir] {
            let saved = try FlexibleHisProject.restore(dir, asSaved: true)
            addTeardownBlock { saved.cleanup() }
            let m = try await FlexibleHisProject.openedModel(saved.project, test: self, timeout: 120)
            let offered = m.readiness.issues.filter { $0.kind == .noLatticeUnder }
                .compactMap { i in i.region.flatMap { m.latticeUnderPlan($0) } }
            print("E-FLEX \(dir.lastPathComponent) offers \(offered)")
            XCTAssertEqual(offered, FlexibleHisProject.latticeUnderTaps(dir), "★ \(dir.lastPathComponent): the fixture replays the page's offer")
            XCTAssertFalse(offered.isEmpty, "control: his project needs a tap")
            // with the taps: lattice under every column of every pressed face
            let tapped = try FlexibleHisProject.restore(dir)
            addTeardownBlock { tapped.cleanup() }
            let t = try await FlexibleHisProject.openedModel(tapped.project, test: self, timeout: 120)
            for k in t.loadedKeys {
                let st = try XCTUnwrap(t.stacks[k])
                XCTAssertEqual(st.latticedColumns, st.columns.count, "★ \(t.displayName(k.region)): lattice under every column")
                let full = st.columns.map { $0.exitT - $0.entryT }.reduce(0, +) / Double(st.columns.count)
                XCTAssertEqual(st.latticeMMMean, full, accuracy: 0.5, "★ \(t.displayName(k.region)): through the part, as before")
            }
            XCTAssertNil(t.readiness.issues.first { $0.kind == .noLatticeUnder }, "nothing left to say")
        }
    }
}
