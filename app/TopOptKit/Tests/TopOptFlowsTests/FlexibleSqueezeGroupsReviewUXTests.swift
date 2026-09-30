// FlexibleSqueezeGroupsReviewUXTests — the D2 verifier's UX findings on HIS project 0004 (task
// 2026-09-29-flexible-screens, round 4 batch D2 review), each with its RED control.
//   * separate groups that compete for material say so BEFORE Exit — the estimate lands with the
//     designs, the top line says "Group 1 squishes ~0.3 of 2.6 mm", and the pop-up opens on the
//     action that caused it with [Join the groups] [Keep apart] — RED: D2's prompt popped only
//     blockers, and nothing on the Settings page said it; the estimate agrees with the built
//     lattice's own reading; with no other group's material it misses nothing (positive control);
//   * "All at once" says the miss too — RED: D2 looked up the "all" note only;
//   * the pass's four squish slots never split a pinch — RED: the four largest split 3 | 5;
//   * a Top + Bottom pinch's two dents never cross — RED: D2's cap drew both 12 mm into 20 mm;
//   * the card says only the face's SHARE (no second force control) and its dot is its group's —
//     RED: D2's card said "10 kg ✎" and its dot was green in Group 2.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSqueezeGroupsReviewUXTests: XCTestCase {

    @MainActor
    private func his(_ before: (ProjectModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        before(r.project)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
    }

    @MainActor
    private func build(_ m: FlexibleStageModel) async throws -> FlexibleGeneratedLattice {
        m.discardLattice()
        m.generateLattice()
        try await FlexibleHisProject.waitFor(180, "the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        return try XCTUnwrap(m.lattice)
    }

    /// His img 4: the top in group 1, the two sides (3 and 5) in group 2.
    @MainActor
    private func sidesApart(_ m: FlexibleStageModel) {
        m.newGroup(with: 3)
        if let g = m.squeezeGroup(of: 3) { m.moveToGroup(5, g.id) }
    }

    // MARK: the miss, said before Exit, with the choice

    @MainActor
    func testSeparateGroupsSayTheMissBeforeExitAndOfferTheChoice() async throws {
        let (_, m) = try await his()
        var prompt = FlexibleFixPrompt(actionSerial: m.actionSerial, popExisting: false)
        XCTAssertNil(prompt.next(m.readiness, actionSerial: m.actionSerial, settled: true), "premise: nothing to pop")
        XCTAssertTrue(m.groupMisses.isEmpty, "premise: one group, no miss")
        sidesApart(m)
        try await settle(m)
        let g1 = m.squeezeGroups[0], g2 = m.squeezeGroups[1]
        let miss = try XCTUnwrap(m.groupMiss(g1.id), "the top will squish less than drawn")
        XCTAssertNil(m.groupMiss(g2.id), "the sides get their own firm lattice")
        XCTAssertEqual(miss.firmerID, g2.id)
        let r = m.readiness
        let issue = try XCTUnwrap(r.competing)
        print("FLEX-REVIEW compete: estimate \(miss.asBuiltMM) of \(miss.designedMM) mm · top line '\(r.oneLine)' · pop-up '\(issue.oneLine)' · fixes \(issue.fixes)")
        XCTAssertTrue(r.isReady, "never a blocker")
        XCTAssertEqual(issue.fixes, [.joinGroups(from: g1.id, into: g2.id), .keepApart])
        XCTAssertEqual(issue.fixes.map { $0.title { "Face \($0)" } }, ["Join the groups", "Keep apart"])
        XCTAssertEqual(issue.region, g1.regions.first, "the pop-up selects the group's face")
        XCTAssertEqual(r.oneLine, "Ready · " + FlexibleRowCopy.groupMissesEstimate(number: 1, asBuiltMM: miss.asBuiltMM, designedMM: miss.designedMM))
        XCTAssertTrue(issue.oneLine.contains("Group 2 needs firmer material"))
        // the pop-up opens on the action that caused it — once
        let popped = prompt.next(r, actionSerial: m.actionSerial, settled: true)
        XCTAssertEqual(popped?.id, issue.id, "it pops at once")
        XCTAssertNil(prompt.next(r, actionSerial: m.actionSerial, settled: true), "once")
        XCTAssertEqual(FlexibleFixPrompt.live(issue, in: r)?.id, issue.id, "the pop-up shows it live")
        // …but never merely on opening the page (only a blocker pops then)
        var opening = FlexibleFixPrompt(actionSerial: m.actionSerial, popExisting: true)
        XCTAssertNil(opening.next(r, actionSerial: m.actionSerial, settled: true))
        // ★ RED CONTROL: D2's prompt looked at the blockers only — there are none
        XCTAssertTrue(r.blocking.isEmpty, "control: D2's prompt had nothing to pop")
        // the group's header says it too, under its row
        let header = try XCTUnwrap(FlexibleSqueezeGroupRows.rows(model: m).first)
        XCTAssertEqual(header.miss, FlexibleRowCopy.groupMissLine(asBuiltMM: miss.asBuiltMM, designedMM: miss.designedMM, firmer: 2))
        XCTAssertLessThanOrEqual(header.miss?.count ?? 99, FlexibleRowCopy.maxChars)

        // the estimate agrees with the built lattice's own reading (the voxel field)
        let g = try await build(m)
        let builtGot = g1.regions.compactMap { r -> Double? in
            g.columnDepths[FlexFaceKey(region: r, rotation: 0)]?.compactMap { $0 }.max()
        }.max() ?? 0
        print("FLEX-REVIEW compete: built lattice \(builtGot) mm · estimate \(miss.asBuiltMM) mm · note '\(g.simNotes["group-1"] ?? "-")'")
        XCTAssertEqual(miss.asBuiltMM, builtGot, accuracy: 0.25, "the estimate reads what the lattice will squish")
        XCTAssertNotNil(g.simNotes["group-1"], "the lattice says the same miss")
        // "All at once" says it too
        XCTAssertEqual(g.simNote(for: FlexibleSim.allID), g.simNotes["group-1"])
        // ★ RED CONTROL: D2 read the "all" note alone — there is none
        XCTAssertNil(g.simNotes[FlexibleSim.allID], "control: D2's all-at-once showed no note")

        // ★ POSITIVE CONTROL: without group 2's material the top misses nothing
        let law = try FlexiblePinch.Law.core(materialsPath: FlexibleHisProject.materialsPath, materialID: try XCTUnwrap(m.settings.materialID),
                                             tempC: try XCTUnwrap(m.designTempC), build: m.build)
        let faces1 = try g1.regions.map { r -> FlexibleGroupEstimate.Face in
            let k = FlexFaceKey(region: r, rotation: 0)
            let d = try XCTUnwrap(m.designs[k]), st = try XCTUnwrap(m.stacks[k])
            return FlexibleGroupEstimate.Face(region: r, stack: st, cuts: m.regions.cuts(of: r),
                                              segments: m.segments[k] ?? FlexiblePinch.core(d, stack: st), pressureMPa: d.columns.map(\.pressureMPa))
        }
        let alone = try FlexibleGroupEstimate.estimate([.init(id: g1.id, number: 1, faces: faces1), .init(id: g2.id, number: 2, faces: [])],
                                                       strainUnder: law.strainUnder)
        XCTAssertTrue(alone.isEmpty, "control: its own material alone meets the drawing (\(alone))")

        // [Keep apart] leaves the groups; [Join the groups] makes one squeeze and the miss goes
        FlexibleFixPopup.apply(.keepApart, to: m)
        XCTAssertEqual(m.squeezeGroups.count, 2)
        FlexibleFixPopup.apply(.joinGroups(from: g1.id, into: g2.id), to: m)
        try await settle(m)
        XCTAssertEqual(m.squeezeGroups.count, 1)
        XCTAssertTrue(m.groupMisses.isEmpty)
        XCTAssertNil(m.readiness.competing)
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 10...10, "one force")
    }

    // MARK: the four squish slots keep a pinch whole

    func testThePassSlotsNeverSplitAPinch() {
        // his pad with the bottom pressed: 0 (largest) pinched with top A and top B; 3 with 5
        let order = [0, FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]
        let pinched: [Int: [Int]] = [0: [FlexibleHisProject.topA, FlexibleHisProject.topB],
                                     FlexibleHisProject.topA: [0], FlexibleHisProject.topB: [0], 3: [5], 5: [3]]
        let s = FlexibleSqueezeGroups.squishSlots(order, pinchedWith: pinched)
        XCTAssertEqual(s.shown, 3)
        XCTAssertEqual(Array(s.order.prefix(s.shown)), [0, FlexibleHisProject.topA, FlexibleHisProject.topB])
        XCTAssertEqual(Set(s.order), Set(order), "every face is still there (the walls use them all)")
        // the sides alone (group 2's pick): both
        XCTAssertEqual(FlexibleSqueezeGroups.squishSlots([3, 5], pinchedWith: pinched).shown, 2)
        // nothing pinched, or four faces: the four largest, as before
        XCTAssertEqual(FlexibleSqueezeGroups.squishSlots(order, pinchedWith: [:]).order, order)
        XCTAssertEqual(FlexibleSqueezeGroups.squishSlots(Array(order.prefix(4)), pinchedWith: pinched).shown, 4)
        // ★ RED CONTROL: the four largest split the 3 | 5 pinch
        let d2 = Set(order.prefix(FlexibleSquishField.maxFaces))
        XCTAssertTrue(d2.contains(3) && !d2.contains(5), "control: D2 squished face 3 without face 5")
    }

    @MainActor
    func testFivePressedFacesSquishEveryPinchWholeOnHisPad() async throws {
        let (_, m) = try await his()
        XCTAssertTrue(m.press(0), "the bottom joins group 1 at its force")
        try await settle(m)
        XCTAssertEqual(m.settings.loadedFaces.count, 5)
        print("FLEX-REVIEW five faces: pinches \(m.pinches.map { "\($0.a)|\($0.b)" }) · line '\(m.readiness.oneLine)'")
        XCTAssertEqual(m.readiness.oneLine, "Ready · Squish shown on 3 of 5 faces · pinches whole")
        sidesApart(m)
        try await settle(m)
        let g = try await build(m)
        // a pinch is whole: its faces are all squished or none are
        let units: [Set<Int>] = [[3, 5], [0, FlexibleHisProject.topA, FlexibleHisProject.topB]]
        func whole(_ keys: [FlexFaceKey]) -> Bool {
            let r = Set(keys.map(\.region))
            return units.allSatisfy { u in u.isSubset(of: r) || u.isDisjoint(with: r) }
        }
        for id in g.sims.map(\.id) {
            let v = g.showing(id)
            print("FLEX-REVIEW five faces · \(id): squished \(v.squishedKeys.map(\.region)) · pass faces \(v.squishFaces.count)")
            XCTAssertTrue(whole(v.squishedKeys), "\(id): no pinch split")
            XCTAssertEqual(v.squishFaces.count, v.squishedKeys.count, "\(id): the pass gets exactly the squished faces")
            XCTAssertEqual(FlexibleLatticePreview.inputs(xray: true, lattice: v, building: false)?.faces.count, v.squishedKeys.count)
        }
        XCTAssertEqual(Set(g.showing("group-2").squishedKeys.map(\.region)), [3, 5])
        // ★ RED CONTROL: the four largest of the lattice's faces, as D2 handed them to the pass
        let byArea = FlexibleStageModel.squishOrder(m.loadedKeys.compactMap { k in m.stacks[k].map { (key: k, areaMM2: $0.areaMM2) } })
        let d2 = Set(byArea.prefix(FlexibleSquishField.maxFaces).map(\.region))
        XCTAssertFalse(d2.contains(3) == d2.contains(5), "control: D2 split the 3 | 5 pinch")
    }

    // MARK: a Top + Bottom pinch — the two dents never cross

    @MainActor
    func testATopAndBottomPinchNeverCrossesInTheMiddle() async throws {
        let (_, m) = try await his()
        XCTAssertTrue(m.press(0))
        try await settle(m)
        let kA = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0), k0 = FlexFaceKey(region: 0, rotation: 0)
        let pA = try XCTUnwrap(m.pinchedColumns(FlexibleHisProject.topA), "top A is pinched with the bottom")
        XCTAssertNotNil(m.pinchedColumns(0))
        let shown = FlexibleShownValues(model: m)
        let k = shown.exaggeration
        let stA = try XCTUnwrap(m.stacks[kA])
        var worst = 0.0, oldCross = 0
        let kOld = FlexibleShownValues.thinCap(values: shown.values, stacks: m.stacks) ?? k
        for key in [kA, k0] {
            let st = try XCTUnwrap(m.stacks[key]), p = try XCTUnwrap(m.pinchedColumns(key.region))
            for (i, v) in (shown.values[key] ?? []).enumerated() where i < st.columns.count && p[i] {
                guard case .depth(let d) = v, st.columns[i].latticeMM > 0 else { continue }
                let l = st.columns[i].latticeMM
                worst = max(worst, k * d / (0.5 * l))
                if 2 * kOld * d > l { oldCross += 1 }
            }
        }
        print("FLEX-REVIEW top+bottom: k \(k) (D2's cap \(kOld)) · worst k·d / half \(worst) · D2 crossing columns \(oldCross) · top A lattice \(stA.latticeMMMax) mm, chip stops at \(FlexibleDepthPrism.latticeMax(stA, pinched: pA)) mm")
        XCTAssertLessThanOrEqual(worst, FlexibleShownValues.thinShare + 1e-9, "each dent stays in its own half")
        // ★ RED CONTROL: D2's cap (whole column) drew both dents past the middle
        XCTAssertGreaterThan(oldCross, 0, "control: D2's dents crossed")
        XCTAssertGreaterThan(kOld, k)
        // the chip and the pad stop at the half
        XCTAssertLessThanOrEqual(FlexibleDepthPrism.latticeMax(stA, pinched: pA), 0.5 * stA.latticeMMMax + 1e-9)
        XCTAssertLessThanOrEqual(FlexibleDepthPrism.dragLimit(stack: stA, k: 1, pinched: pA), 0.5 * stA.latticeMMMax + 1e-9)
        XCTAssertEqual(FlexibleDepthPrism.latticeMax(stA, pinched: nil), stA.latticeMMMax, "control: the whole column without the pinch")
        let chips = try FlexibleSource.code("FlexibleDepthChips.swift")
        XCTAssertTrue(chips.contains("limitMM: FlexibleDepthPrism.dragLimit(stack: st, k: kk, pinched: pinched)"))
    }

    // MARK: the card: the face's share, its group's dot

    @MainActor
    func testTheCardSaysOnlyTheFacesShareAndItsDotIsItsGroups() async throws {
        let (_, m) = try await his()
        XCTAssertNil(FlexibleFaceRows.weightLine(model: m, region: 3), "10 kg is the group's force: said once, on the header")
        XCTAssertNil(FlexibleFaceRows.weightLine(model: m, region: FlexibleHisProject.topA))
        // ★ RED CONTROL: D2's card row said "10 kg" with a pencil that set the whole group
        let f3 = try XCTUnwrap(m.settings.face(3))
        XCTAssertEqual(FlexibleRowCopy.weight(face: f3, entry: m.mainPageLoads.entry(3)), "10 kg", "control: D2's card line")
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertFalse(panel.contains("FlexEditPill(key: \"weight-"), "no second force control on the card")
        sidesApart(m)
        XCTAssertEqual(FlexibleFaceRows.dot(model: m, region: 5), FlexibleSqueezeGroups.colour(number: 2), "Face 5's card in Group 2's blue")
        XCTAssertEqual(FlexibleFaceRows.dot(model: m, region: FlexibleHisProject.topA), FlexibleSqueezeGroups.colour(number: 1))
        XCTAssertEqual(FlexibleFaceRows.dot(model: m, region: 0), DS.Color.accentCyan, "a resting face")
        XCTAssertNotEqual(FlexibleSqueezeGroups.colour(number: 2), DS.Color.accentGreen, "control: D2's card was green")
        // a share of a main-page group over two faces is said on the card
        let (_, m2) = try await his { p in
            if let top = p.selection.groups.first(where: { $0.name == "Top" }) { p.selection.addRegions([104], to: top.id) }
        }
        let line = try XCTUnwrap(FlexibleFaceRows.weightLine(model: m2, region: FlexibleHisProject.topA))
        print("FLEX-REVIEW card share: '\(line)'")
        XCTAssertTrue(line.hasSuffix("of Top's 10 kg"), line)
    }
}
