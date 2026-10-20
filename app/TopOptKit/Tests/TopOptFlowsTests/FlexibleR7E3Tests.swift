// FlexibleR7E3Tests — round 7, batch R7-E3 with his notes of 2026-10-19 (tasks.md, binding) and E1b's three carry-overs. Each RED
// CONTROL runs inside its test and is asserted red.
//   (a) E1b's check: "with an edges group open, the on-part numbers stop matching the card's press names" — ONE number per edge or
//       corner of the part, on its tag and in the press's name, before and after a flat prism cuts its faces.
//   (b) plain words for the depth stop "its lattice is in two places".  (c) the Tilt row first, then Twist.
//   (iv) ~14:40 "When in a group do *not* highlight other edges/corners. Allow users to tap them to add OR add a "+" button".
//   (iii) ~14:40 "the edges do not seem to actually squish when played? … It should absolutely have a simulation going." — the
//       interim sim along the arrow over the whole footprint (the reviewer's AP ruling (a)); it never writes a job; the chip.
//   (i)/(ii) ~14:40 the group selector on the LATTICE page's legend ("All (one after another)" then each group by name); the Squish
//       page has none.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E3Tests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias M2 = FlexibleM2Fixtures

    override func tearDown() {
        FlexibleEdgeCandidates.Candidate.controlPieceNumbers = false
        FlexibleStageModel.controlAlwaysLit = false
        FlexibleFlatPrismUI.controlThetaAlwaysFirst = false
        FlexibleStageModel.controlNoPressSims = false
        FlexibleSettingsSquish.controlSquishPagePicker = false
        FlexibleMainStage.controlNoGroupSelector = false
        super.tearDown()
    }

    func reopened(_ m: FlexibleStageModel) async throws {
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
    }

    /// An edge or corner OF THE PART: its kind and its members' faces (a piece's faces — the same before and after a cut).
    func identity(_ m: FlexibleStageModel, _ c: FlexibleEdgeCandidates.Candidate) -> String {
        let mesh = m.project.viewerMesh
        return c.kind.rawValue + "|" + Set(c.members.flatMap { m.regions.faces(of: $0, mesh: mesh) }).sorted().map(String.init).joined(separator: ",")
    }

    func openGroup(_ m: FlexibleStageModel, press: UUID) async throws -> FlexibleEdgePick {
        m.rail = .group(try XCTUnwrap(m.squeezeGroup(ofPress: press)).id)
        m.syncEdgeAdd()
        try await FlexibleHisProject.waitFor(240, "the open group's edges") { m.edgeAdd.map { !$0.loading && !$0.checking } ?? false }
        return try XCTUnwrap(m.edgeAdd)
    }

    // MARK: - (a) one number; (iv) nothing lit until [+]

    func testOneNumberOnThePartAndTheCardAndNothingLitUntilPlus() async throws {
        let (_, m) = try await F.hisPad(self)
        let e16 = try await F.edge16(m)
        var before: [String: Int] = [:]
        for c in e16.pick.candidates {
            XCTAssertEqual(c.shownNumber, c.number, "★ on the uncut part the shown numbers ARE the numbers (E1b's, his saved labels)")
            before[identity(m, c)] = c.shownNumber
        }
        let press = try await F.commit(m, e16.c)
        try await reopened(m)
        XCTAssertEqual(press.strip?.label, "Edge \(e16.c.number)", "premise: the card's name")
        let a = try await openGroup(m, press: press.id)
        // (a): every edge and corner after the cut wears the number it wore before
        func mismatched() -> [String] {
            a.candidates.compactMap { c in
                let k = identity(m, c)
                guard let b = before[k] else { return "new \(k) #\(c.shownNumber)" }
                return b == c.shownNumber ? nil : "\(k): \(b) → \(c.shownNumber)"
            }
        }
        let off = mismatched()
        print("FLEX-E3-a his pad after Edge \(e16.c.number)'s cut: \(a.candidates.count) candidates (was \(e16.pick.candidates.count)) · mismatched \(off)")
        XCTAssertEqual(off, [], "★ one number per edge or corner, before and after the cut")
        // found by looking (E3_02): two pieces of one split edge wore two tags with one number — one tag per number now
        let pieces = Dictionary(grouping: a.candidates, by: \.shownNumber).filter { $0.value.count > 1 }
        XCTAssertFalse(pieces.isEmpty, "premise: the cut split an edge of the part into pieces sharing its number")
        let proj = a.candidates.map { FlexibleEdgePickRules.Projected(number: $0.number, kind: $0.kind, point: .zero, lines: [], front: true, tag: .zero) }
        let owners = FlexibleEdgePickRules.tagOwners(proj) { a.candidate($0)?.shownNumber }
        XCTAssertEqual(owners.count, Set(a.candidates.map(\.shownNumber)).count, "★ one tag per number")
        XCTAssertLessThan(owners.count, a.candidates.count, "premise: more pieces than numbers (E1b drew a tag on each piece)")
        let lit = a.drawn.compactMap { a.candidate($0.number)?.shownNumber }
        XCTAssertFalse(lit.contains(e16.c.number), "★ no lit spot wears Edge \(e16.c.number)'s number")
        XCTAssertTrue(a.candidates.contains { $0.shownNumber != $0.number }, "premise: the cut renumbered the pieces")
        FlexibleEdgeCandidates.Candidate.controlPieceNumbers = true
        let red = mismatched()
        FlexibleEdgeCandidates.Candidate.controlPieceNumbers = false
        print("FLEX-E3-a RED CONTROL (E1b's piece numbers): \(red.count) mismatched · \(red.prefix(4))")
        XCTAssertFalse(red.isEmpty, "RED CONTROL: the pieces renumbered (his bug)")

        // (iv): in the open group nothing else is lit until [+]; a tap on the part still adds (edgeAddTap reads the same list)
        XCTAssertFalse(m.edgeAddLit, "★ nothing lit in the open group")
        m.toggleEdgeAdding()
        XCTAssertTrue(m.edgeAddLit, "★ [+] lights the pressable ones")
        m.toggleEdgeAdding()
        XCTAssertFalse(m.edgeAddLit, "★ [Done] turns them off")
        XCTAssertFalse(a.drawn.isEmpty, "premise: something can be added")
        FlexibleStageModel.controlAlwaysLit = true
        XCTAssertTrue(m.edgeAddLit, "RED CONTROL: E1b — always lit")
        FlexibleStageModel.controlAlwaysLit = false
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleEdgePickViews.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("if add, !model.edgeAddLit { return [] }"), "★ the overlay draws the open group's lit ones only with [+]")
    }

    // MARK: - (b) plain words; (c) Tilt first

    func testPlainWordsForTheSplitAndTiltFirst() {
        let line = FlexibleRowCopy.maxDepthSplits(18.1)
        print("FLEX-E3-b '\(line)' (\(line.count)) · '\(FlexibleRowCopy.latticeInTwoPlaces("Edge 16"))'")
        XCTAssertEqual(line, "Max 18.1 mm \u{00B7} deeper splits its lattice")
        XCTAssertLessThanOrEqual(line.count, 44)
        XCTAssertFalse(FlexibleRowCopy.latticeInTwoPlaces("Edge 16").contains("in two places"), "★ no 'in two places'")
        XCTAssertEqual(FlexibleStageModel.reasonOnly(FlexibleRowCopy.latticeInTwoPlaces("Edge 16"), label: "Edge 16"),
                       FlexibleRowCopy.splitsTheLattice, "the depth stop recognises core's refusal")
        // (c): a steep edge's θ row reads "Twist" → it goes second; a level edge's θ row reads "Tilt" → first; corners unchanged
        XCTAssertFalse(FlexibleFlatPrismUI.thetaRowFirst(corner: false, steep: true), "★ steep: Tilt (the along-edge row) first")
        XCTAssertTrue(FlexibleFlatPrismUI.thetaRowFirst(corner: false, steep: false))
        XCTAssertTrue(FlexibleFlatPrismUI.thetaRowFirst(corner: true, steep: true))
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: false, corner: false, steep: true), FlexibleRowCopy.flatTiltWord(corner: false, steep: false),
                       "premise: on a steep edge the second (along-edge) row reads Tilt")
        FlexibleFlatPrismUI.controlThetaAlwaysFirst = true
        XCTAssertTrue(FlexibleFlatPrismUI.thetaRowFirst(corner: false, steep: true), "RED CONTROL: E1b's order (Twist first)")
    }

    // MARK: - (iii) the edges group squishes along its arrow; (i)/(ii) the selector; the chip; no job written

    func testAnEdgesGroupSquishesAlongItsArrowOnBothPages() async throws {
        // ★ RE-PINNED (C1, his words of 2026-10-20 "finalize the send to core now"): presses are sent by default; this pins the
        // INTERIM sim, now the fallback — the switch off (C1's FlexibleC1Tests pins the sent, calibrated sim)
        FlexibleBackend.sendsPresses = false
        defer { FlexibleBackend.sendsPresses = true }
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(120, "A1_0003: the scene") { m.sceneState == .ready }
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        let e16 = try await F.edge16(m)
        let first = try await F.commit(m, e16.c)
        try await reopened(m)
        let a = try await openGroup(m, press: first.id)
        let e18 = try XCTUnwrap(M2.edge(m, a, faces: [3, 4]), "Edge 18")
        let addWhy = await m.addEdgeToGroup(e18.number)
        XCTAssertNil(addWhy)
        try await reopened(m)
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: first.id))
        XCTAssertEqual(g.kind, .edges)
        XCTAssertEqual(g.presses.count, 2, "premise: an edges group of Edge 16 + Edge 18 (his Group 3's shape)")
        let id = FlexibleSim.groupID(g.number)
        // the request: each press over its footprint, along its arrow, with its force
        let want = try XCTUnwrap(m.pressSimWants.first { $0.sim.id == id }, "★ the edges group has a sim")
        let sim = FlexibleFERequest.pressSim(id: id, presses: want.presses, voxels: 8)
        for (i, pid) in g.presses.enumerated() {
            let p = try XCTUnwrap(m.press(pid))
            XCTAssertEqual(sim.pressed[i].footprintRegionIDs, p.regions, "★ its whole footprint")
            XCTAssertEqual(sim.pressed[i].direction.map(\.bitPattern), [p.direction.x, p.direction.y, p.direction.z].map(\.bitPattern), "★ d's bits")
            XCTAssertEqual(sim.pressed[i].weightN, p.settings.weightN)
            XCTAssertGreaterThan(p.settings.weightN, 0)
        }
        XCTAssertTrue(sim.targets.isEmpty, "★ no core prediction to calibrate to")

        let lattice = try await FlexibleSquishFixture.build(m, "A1_0003 + Edge 16 + Edge 18")
        // every send's job (one squeeze per job: his pad has two face groups) — before the edges group's sim
        func jobs() -> [String: String] {
            var out: [String: String] = [:]
            for send in FlexibleAngledGoldens.sends(m) { out[send.title] = (try? m.runJobJSON(resting: Set(send.resting))) ?? "throws" }
            return out
        }
        let jobBefore = jobs()
        XCTAssertFalse(jobBefore.isEmpty, "premise: something to send")
        try await FlexibleSquishFixture.solve(m, "A1_0003 + edges")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "the edges group's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        let field = try XCTUnwrap(m.squish[id]?.field, "★ the edges group's sim landed: \(m.squish[id]?.failure ?? "-")")
        XCTAssertEqual(field.generation, lattice.generation, "★ on the CURRENT lattice")
        // along the arrow over each press's footprint: sample each member face inside the flat prism's inner half
        var lines: [String] = []
        for pid in g.presses {
            let p = try XCTUnwrap(m.press(pid))
            let st = try XCTUnwrap(p.strip), cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: p))
            var pts: [Float] = []
            for tris in F.faceTris(m, st) {
                for t in tris where t.count == 3 {
                    for i in 0...24 { for j in 0...(24 - i) {
                        let q = t[0] + (t[1] - t[0]) * (Double(i) / 24) + (t[2] - t[0]) * (Double(j) / 24)
                        if cut.height(q) < 0.5 * cut.depthMM { pts += [Float(q.x), Float(q.y), Float(q.z)] }
                    } }
                }
            }
            XCTAssertFalse(pts.isEmpty, "premise: points inside \(st.label)'s footprint")
            let u = field.meshDisplacements(positions: pts)
            var along = 0.0, mag = 0.0
            let n = u.count / 3
            for k in 0..<n {
                let v = SIMD3<Double>(Double(u[3 * k]), Double(u[3 * k + 1]), Double(u[3 * k + 2]))
                along += simd_dot(v, p.direction)
                mag += simd_length(v)
            }
            along /= Double(max(1, n)); mag /= Double(max(1, n))
            lines.append("\(st.label): \(n) points · mean u·d \(String(format: "%.4f", along)) mm · mean |u| \(String(format: "%.4f", mag)) mm")
            XCTAssertGreaterThan(along, 0, "★ \(st.label) moves ALONG its arrow")
            XCTAssertGreaterThan(along, 0.3 * mag, "★ \(st.label): mostly along the arrow")
        }
        print("FLEX-E3-iii his pad, Group \(g.number) (Edge 16 + Edge 18): " + lines.joined(separator: " | ")
              + " · scale \(field.scale) uncalibrated \(field.uncalibrated)")
        // never a job: nothing sent, the job bytes unchanged by the sim
        XCTAssertTrue(m.sentPresses.isEmpty, "★ no press sent")
        XCTAssertEqual(jobs(), jobBefore, "★ the sim wrote no job (every send's bytes unchanged)")
        XCTAssertFalse(jobBefore.values.contains { $0.contains("press_direction") }, "★ no press in any job")
        // the chip, on both pages, only for the edges group
        let faceGroup = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        XCTAssertEqual(m.notTunedLine(simID: id), FlexibleRowCopy.latticeNotTunedForPress)
        XCTAssertNil(m.notTunedLine(simID: FlexibleSim.groupID(faceGroup.number)), "★ never on a face group")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.latticeNotTunedForPress.count, 44)
        m.rail = .group(g.id)
        XCTAssertEqual(m.playingGroup?.id, g.id)
        XCTAssertEqual(FlexibleSettingsSquish.note(model: m, fe: true), FlexibleRowCopy.latticeNotTunedForPress, "★ the Squish page says it")
        XCTAssertNotNil(FlexibleSettingsSquish.field(model: m, group: g), "★ the Squish page plays the open edges group's field")
        // (ii): no picker on the Squish page
        XCTAssertEqual(FlexibleSettingsSquish.playerSims(model: m), [], "★ no selector on the Squish page")
        FlexibleSettingsSquish.controlSquishPagePicker = true
        XCTAssertGreaterThan(FlexibleSettingsSquish.playerSims(model: m).count, 1, "RED CONTROL: the old picker")
        FlexibleSettingsSquish.controlSquishPagePicker = false
        // (i): the Lattice page's selector — All, then each group by name (the edges group too); a pick is the page's squeeze
        let choices = stage.groupChoices
        print("FLEX-E3-i selector: \(choices.map(\.title))")
        XCTAssertEqual(choices.first?.title, FlexibleRowCopy.selectorAll)
        XCTAssertEqual(choices.dropFirst().map(\.title), m.squeezeGroups.map { m.groupName($0) }, "★ each group by its name")
        stage.pick(id)
        XCTAssertEqual(stage.selectedSim, id)
        XCTAssertEqual(stage.notTunedChip, FlexibleRowCopy.latticeNotTunedForPress, "★ the chip under the selector")
        stage.pick(FlexibleSim.groupID(faceGroup.number))
        XCTAssertNil(stage.notTunedChip)
        XCTAssertTrue(stage.sims.contains { $0.id == id }, "★ the main page can play it ('All' too)")
        FlexibleMainStage.controlNoGroupSelector = true
        XCTAssertEqual(stage.groupChoices, [], "RED CONTROL: no selector")
        FlexibleMainStage.controlNoGroupSelector = false
        // RED CONTROL: today's bug — no sim for an edges group, nothing plays
        FlexibleStageModel.controlNoPressSims = true
        XCTAssertNil(m.pressSimWants.first { $0.sim.id == id }, "RED CONTROL: no sim for the edges group (he saw it not move)")
        XCTAssertFalse(stage.sims.contains { $0.id == id }, "RED CONTROL: nothing to play")
        FlexibleStageModel.controlNoPressSims = false
    }
}
