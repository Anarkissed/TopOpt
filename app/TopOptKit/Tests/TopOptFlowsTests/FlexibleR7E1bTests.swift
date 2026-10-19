// FlexibleR7E1bTests — round 7, batch R7-E1b: his notes of 2026-10-19 on R7-E1, after he tried it (tasks.md, binding; his
// screenshots r7e/img_1019_5.png and img_1019_6.png). Each RED CONTROL runs inside its test and is asserted red.
//   1 "why are so many greyed out??" ("Face 1 · lattice A is out of Flexible") — a face he DELETED (removedRegions) greyed its
//     edges and corners; on HIS live pad as saved none is greyed for that now.
//   2 "It is best not to list greyed out corners/edges" — no list; only the pressable are drawn on the part; a tap on a spot that
//     cannot be pressed says why in one line, with its fix.
//   3 "When in a group, I should be able to tap onto an edge/corner to select it. And there should be a Group selection just like the
//     faces." — a tap adds to the OPEN edges group (one undo step); the chips move a press to another edges group (its one force).
//   4 "A corner/edge prism should be the same purple as a face-prism."
//   5 "'Tilt' generally comes off as up/down … Please reverse this." — Tilt = up/down, Twist = left/right on the part.
//   6 "passing a pre-defined limit, going back to an arbitrary number and then not being able to extend further. There should be some
//     sort red notification … bringing the default to the furthest possible amount … A solution should be provided if there is one."
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E1bTests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias M2 = FlexibleM2Fixtures
    typealias A = FlexibleFlatPrismAngles

    override func tearDown() {
        FlexibleEdgeCandidates.controlRemovedBlocks = false
        FlexibleEdgePickRules.controlDrawAll = false
        FlexibleStageModel.controlAddMakesNewGroup = false
        FlexibleStageModel.controlMoveKeepsForce = false
        FlexibleFlatPrismUI.controlGroupColour = false
        FlexibleRowCopy.controlOldWords = false
        FlexibleStageModel.controlNoFurthest = false
        FlexibleStageModel.controlToastOnly = false
        super.tearDown()
    }

    func reopened(_ m: FlexibleStageModel) async throws {
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
    }

    /// His live pad AS HE SAVED IT (copied from the simulator 2026-10-18 15:06; his removedRegions: 11 faces), opened and settled.
    func hisLive() async throws -> FlexibleStageModel {
        try FlexibleTopLayerFixtures.assertHisFiles()
        let r = try FlexibleHisProject.restore(FlexibleTopLayerFixtures.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleAngledGoldens.openModel(self, r.project, "his live pad")
        try await FlexibleSquishFixture.settle(m, "his live pad")
        return m
    }

    // MARK: - 1 why so many were greyed

    func testHisLivePadOffersTheEdgesOfADeletedFace() async throws {
        let m = try await hisLive()
        XCTAssertEqual(m.settings.removedRegions?.count, 11, "premise: his 11 deleted faces (Reset all / the trash)")
        let p = try await M2.pickMode(m)
        let pressable = p.candidates.filter { p.pickable($0.number) }.count
        print("FLEX-E1b-1 his live pad: \(p.candidates.count) candidates, \(pressable) pressable · greyed "
              + p.greyed.sorted { $0.key < $1.key }.map { "#\($0.key) '\($0.value)'" }.joined(separator: " | "))
        XCTAssertEqual(p.greyed.filter { $0.value.contains("out of Flexible") }.count, 0, "★ a deleted face greys none of its edges and corners")
        XCTAssertGreaterThan(pressable, 0)
        // RED CONTROL: the old rule (his img_1019_5)
        m.cancelEdgePick()
        FlexibleEdgeCandidates.controlRemovedBlocks = true
        let c = try await M2.pickMode(m)
        FlexibleEdgeCandidates.controlRemovedBlocks = false
        let red = c.greyed.filter { $0.value.contains("out of Flexible") }.count
        print("FLEX-E1b-1 RED CONTROL: \(red) greyed 'out of Flexible', \(c.candidates.filter { c.pickable($0.number) }.count) pressable")
        XCTAssertGreaterThan(red, 0, "RED CONTROL: the old rule greys them")
    }

    // MARK: - 2 no list; only the pressable drawn; a tap elsewhere says why

    func testOnlyThePressableAreDrawnAndAGreySpotSaysWhy() async throws {
        let (_, m) = try await F.hisPad(self)
        let e16 = try await F.edge16(m)
        _ = try await F.commit(m, e16.c)
        let p = try await M2.pickMode(m)
        let greyed = Set(p.greyed.keys)
        XCTAssertFalse(greyed.isEmpty, "premise: the edges and corners over Edge 16 are in its group")
        XCTAssertTrue(Set(p.drawn.map(\.number)).isDisjoint(with: greyed), "★ what cannot be pressed is not drawn")
        XCTAssertEqual(p.drawn.count, p.candidates.filter { p.pickable($0.number) }.count, "★ every pressable one is drawn")
        FlexibleEdgePickRules.controlDrawAll = true
        XCTAssertFalse(Set(try XCTUnwrap(m.edgePick).drawn.map(\.number)).isDisjoint(with: greyed), "RED CONTROL: every candidate drawn")
        FlexibleEdgePickRules.controlDrawAll = false
        // the tap: the lit one is reached past a nearer grey one; a grey spot alone names that one
        let g = try XCTUnwrap(greyed.min()), ok = try XCTUnwrap(p.drawn.first?.number)
        func pj(_ n: Int, _ x: CGFloat) -> FlexibleEdgePickRules.Projected {
            .init(number: n, kind: .corner, point: CGPoint(x: x, y: 0), lines: [], front: true, tag: nil)
        }
        XCTAssertEqual(FlexibleEdgePickRules.hit([pj(g, 0), pj(ok, 15)], at: .zero, last: nil, pressable: [ok]).toggle, ok, "★ the lit one")
        XCTAssertEqual(FlexibleEdgePickRules.hit([pj(g, 0), pj(ok, 15)], at: .zero, last: nil).toggle, g, "RED CONTROL: the grey one, nearer")
        let alone = FlexibleEdgePickRules.hit([pj(g, 0)], at: .zero, last: nil, pressable: [ok])
        XCTAssertNil(alone.toggle)
        XCTAssertEqual(alone.blocked, g, "★ a grey spot is named")
        let line = m.blockedLine(g, in: \.edgePick)
        print("FLEX-E1b-2 grey spot #\(g): '\(line)' · fix group \(m.edgePick?.fixGroup.map(String.init) ?? "-")")
        XCTAssertTrue(line.contains("In "), "★ one line why: \(line)")
        XCTAssertLessThanOrEqual(line.count, 44)
        XCTAssertNotNil(m.edgePick?.fixGroup, "★ its fix: [Open Group N]")
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleEdgePickViews.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("ForEach(p.candidates)"), "★ no list on the pick card")
    }

    // MARK: - 3 add to the open group, the chips; 4 the purple; 5 the words

    func testATapAddsToTheOpenGroupChipsMoveItPurpleAndWords() async throws {
        let (r, m) = try await F.hisPad(self)
        let e16 = try await F.edge16(m)
        let first = try await F.commit(m, e16.c)
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: first.id))
        let groups0 = m.squeezeGroups.count
        func openAdd() async throws -> FlexibleEdgePick {
            m.rail = .group(try XCTUnwrap(m.squeezeGroup(ofPress: first.id)).id)
            m.syncEdgeAdd()
            try await FlexibleHisProject.waitFor(240, "the open group's edges") { m.edgeAdd.map { !$0.loading && !$0.checking } ?? false }
            return try XCTUnwrap(m.edgeAdd)
        }
        let a = try await openAdd()
        XCTAssertEqual(a.into, g.id)
        let e18 = try XCTUnwrap(M2.edge(m, a, faces: [3, 4]), "Edge 18")
        XCTAssertTrue(a.pickable(e18.number), "premise: Edge 18 can be pressed")
        let why = await m.addEdgeToGroup(e18.number)
        try await reopened(m)
        XCTAssertNil(why)
        XCTAssertEqual(m.squeezeGroup(ofPress: first.id)?.presses.count, 2, "★ added to the OPEN group")
        XCTAssertEqual(m.squeezeGroups.count, groups0, "★ no new group")
        r.project.performUndo()
        m.openScene()   // (the page re-opens the part after an undo)
        try await reopened(m)
        XCTAssertEqual(m.squeezeGroup(ofPress: first.id)?.presses.count, 1, "★ one undo step")
        // RED CONTROL: an add that makes a new group
        FlexibleStageModel.controlAddMakesNewGroup = true
        let a2 = try await openAdd()
        _ = await m.addEdgeToGroup(try XCTUnwrap(M2.edge(m, a2, faces: [3, 4])).number)
        try await reopened(m)
        FlexibleStageModel.controlAddMakesNewGroup = false
        XCTAssertEqual(m.squeezeGroups.count, groups0 + 1, "RED CONTROL: a new group")
        r.project.performUndo()
        m.openScene()   // (the page re-opens the part after an undo)
        try await reopened(m)
        // the chips: a second edges group (a corner, 9 kg); Edge 16 moves there and takes its one force
        let pk = try await M2.pickMode(m)
        let corner = try await F.commit(m, try XCTUnwrap(F.corner(m, pk)), kg: 9)
        let g3 = try XCTUnwrap(m.squeezeGroup(ofPress: corner.id))
        m.movePress(first.id, to: g3.id)
        XCTAssertEqual(m.squeezeGroup(ofPress: first.id)?.id, m.squeezeGroup(ofPress: corner.id)?.id, "★ moved")
        XCTAssertEqual(try XCTUnwrap(m.press(first.id)).settings.weightKg, 9, accuracy: 1e-9, "★ the group's one force")
        r.project.performUndo()
        XCTAssertEqual(try XCTUnwrap(m.press(first.id)).settings.weightKg, 5, accuracy: 1e-9, "★ one undo step")
        FlexibleStageModel.controlMoveKeepsForce = true
        m.movePress(first.id, to: try XCTUnwrap(m.squeezeGroup(ofPress: corner.id)).id)
        XCTAssertEqual(try XCTUnwrap(m.press(first.id)).settings.weightKg, 5, accuracy: 1e-9, "RED CONTROL: its own force kept")
        r.project.performUndo()
        FlexibleStageModel.controlMoveKeepsForce = false
        // 4 the purple
        let eg = try XCTUnwrap(m.squeezeGroup(ofPress: first.id))
        XCTAssertNotEqual(m.groupColour(eg), FlexibleStageStyle.facePrismToken, "premise: the group wears its own colour")
        XCTAssertEqual(FlexibleFlatPrismUI.prismColour(m, eg), FlexibleStageStyle.facePrismToken, "★ the face-prism purple")
        FlexibleFlatPrismUI.controlGroupColour = true
        XCTAssertEqual(FlexibleFlatPrismUI.prismColour(m, eg), m.groupColour(eg), "RED CONTROL: the group's colour")
        FlexibleFlatPrismUI.controlGroupColour = false
        // 5 the words: Edge 16 is a steep side — tipping toward a face is left/right (Twist), one end deeper is up/down (Tilt)
        let f = try XCTUnwrap(FlexibleFlatPrismUI.frame(m, first.id))
        XCTAssertTrue(f.thetaIsTwist, "Edge 16 is the pad's 20 mm side")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: true, corner: false, steep: true), "Twist")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: false, corner: false, steep: true), "Tilt")
        XCTAssertTrue(FlexibleRowCopy.flatTwistRow(end: f.namedEnd, steep: true).hasPrefix("Tilt top end"), FlexibleRowCopy.flatTwistRow(end: f.namedEnd, steep: true))
        XCTAssertTrue(FlexibleRowCopy.flatTiltRow(toward: "Face 3", steep: true).hasPrefix("Twist"))
        let up = FlexibleFlatPrismKnob.angles(start: (0, 0), translation: CGSize(width: 0, height: -40), jac: nil, thetaAcross: true)
        let across = FlexibleFlatPrismKnob.angles(start: (0, 0), translation: CGSize(width: 40, height: 0), jac: nil, thetaAcross: true)
        XCTAssertEqual(up.theta, 0); XCTAssertGreaterThan(up.phi, 3, "★ up = Tilt (φ here)")
        XCTAssertEqual(across.phi, 0); XCTAssertGreaterThan(across.theta, 3, "★ across = Twist (θ here)")
        // a level edge keeps E1's words (its θ tips up/down)
        let level = pk.candidates.compactMap { c -> A.Frame? in
            guard c.kind == .edge, let st = pk.strips[c.number], let d0 = st.halfway else { return nil }
            return A.frame(st, d0: d0, up: m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1))
        }.first { !$0.thetaIsTwist }
        XCTAssertNotNil(level, "a level edge on his pad")
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: true, corner: false, steep: false), "Tilt")
        FlexibleRowCopy.controlOldWords = true
        XCTAssertEqual(FlexibleFlatPrismUI.boxLabel(tilt: true, corner: false, steep: true), "Tilt", "RED CONTROL: E1's words")
        FlexibleRowCopy.controlOldWords = false
    }

    // MARK: - 6 each bound: the furthest possible, said in red, with its fix

    func testEachBoundHoldsAtTheFurthestInRedWithItsFix() async throws {
        let (_, m) = try await F.hisLivePad(self)
        let e16 = try await F.edge16(m)
        let press = try await F.commit(m, e16.c)
        let id = press.id, st = try XCTUnwrap(m.press(id)?.strip)
        XCTAssertEqual(FlexStopLine.colour, DS.Color.danger, "★ a stop is said in RED")
        // DEPTH, typed far past
        let w60 = await m.setFlatCut(id, depthMM: 200, direction: press.direction, snap: press.snap)
        try await reopened(m)
        print("FLEX-E1b-6 depth 200 typed: why \(w60 ?? "-") · toast \(m.toast ?? "-")")
        let h1 = try XCTUnwrap(m.press(id)).settings.deepestMM
        let stop = try XCTUnwrap(m.lastFlatStop, "★ a red line says why")
        print("FLEX-E1b-6 depth 200 → \(h1) mm · '\(stop.line)' · fix prism \(stop.prismMM.map { String($0) } ?? "-")")
        XCTAssertEqual(stop.press, id)
        XCTAssertTrue(stop.line.contains(String(format: "%.1f", h1)), "★ with the number it stopped at: \(stop.line)")
        // the furthest: 0.5 mm deeper does not fit (core's exact check on the cut, or each face keeping some of itself)
        let keep = m.lastFlatStop
        let fitsCore: Bool
        if case .ready = await m.prepareFlexibleStrips(.init(cut: [id: FlatCutChange(depthMM: h1 + 0.5, direction: press.direction, snap: press.snap)])) {
            fitsCore = true
        } else { fitsCore = false }
        m.lastFlatStop = keep
        let l3 = A.depthRange(st, d: press.direction, limits: m.flatLimits(id, withLattice: false)).max
        XCTAssertFalse(fitsCore && l3 >= h1 + 0.5, "★ held at the FURTHEST (0.5 mm deeper fits neither): core \(fitsCore), rule max \(l3)")
        XCTAssertLessThanOrEqual(stop.line.count, 44)
        XCTAssertFalse(stop.line.contains("\u{2026}"), "★ whole: \(stop.line)")
        if stop.line.contains("lattice ends") { XCTAssertNotNil(stop.prismMM, "★ the fix: deepen the face-prism") }
        // he can always extend back up to it
        _ = await m.setFlatCut(id, depthMM: h1 - 2, direction: press.direction, snap: press.snap)
        try await reopened(m)
        XCTAssertEqual(try XCTUnwrap(m.press(id)).settings.deepestMM, h1 - 2, accuracy: 1e-9)
        _ = await m.setFlatCut(id, depthMM: h1, direction: press.direction, snap: press.snap)
        try await reopened(m)
        XCTAssertEqual(try XCTUnwrap(m.press(id)).settings.deepestMM, h1, accuracy: 1e-9, "★ back up to the furthest")
        // RED CONTROL: core's first N (from the deeper footprint) — short of the furthest when the lattice is the bound
        if stop.line.contains("lattice") {
            FlexibleStageModel.controlNoFurthest = true
            m.flatExactStops[id] = nil
            _ = await m.setFlatCut(id, depthMM: h1 - 2, direction: press.direction, snap: press.snap)
            try await reopened(m)
            _ = await m.setFlatCut(id, depthMM: 200, direction: press.direction, snap: press.snap)
            try await reopened(m)
            let hc = try XCTUnwrap(m.press(id)).settings.deepestMM
            FlexibleStageModel.controlNoFurthest = false
            print("FLEX-E1b-6 RED CONTROL depth: core's first N \(hc) mm vs the furthest \(h1) mm")
            XCTAssertLessThan(hc, h1 - 0.1, "RED CONTROL: lands short (an arbitrary number)")
            _ = await m.setFlatCut(id, depthMM: h1, direction: press.direction, snap: press.snap)
            try await reopened(m)
        }
        // TWIST (φ) past its bound, typed
        let f = try XCTUnwrap(FlexibleFlatPrismUI.frame(m, id))
        m.lastFlatStop = nil
        _ = await m.setFlatAngle(id, degrees: 80, tilt: false)
        try await reopened(m)
        let d1 = try XCTUnwrap(m.press(id)).direction, a1 = A.decompose(f, d1)
        let ts = try XCTUnwrap(m.lastFlatStop, "★ the twist's red line")
        let lim = m.flatLimits(id, withLattice: false)
        let far = A.limit(st, frame: f, h: try XCTUnwrap(m.press(id)).settings.deepestMM, at: (a1.theta, 0), tilt: false, sign: 1, limits: lim).deg
        print("FLEX-E1b-6 twist 80° → \(a1.phi)° (rule's furthest \(far)°) · '\(ts.line)' · fix \(ts.setMM.map { String($0) } ?? "-")")
        if !ts.line.contains("lattice") { XCTAssertEqual(a1.phi, far, accuracy: 0.05, "★ the furthest the rule allows") }
        if let mm = ts.setMM, let d = ts.direction {
            _ = await m.setFlatCut(id, depthMM: mm, direction: d, snap: nil)
            try await reopened(m)
            let a2 = A.decompose(f, try XCTUnwrap(m.press(id)).direction)
            print("FLEX-E1b-6 the fix [Deepen to \(mm) mm] → twist \(a2.phi)°")
            XCTAssertGreaterThan(a2.phi, a1.phi + 0.5, "★ the fix lets it twist further")
        }
        // TILT (θ) past its bound, typed
        m.lastFlatStop = nil
        _ = await m.setFlatAngle(id, degrees: 85, tilt: true)
        try await reopened(m)
        let tl = try XCTUnwrap(m.lastFlatStop, "★ the tilt's red line")
        print("FLEX-E1b-6 tilt 85° → \(A.decompose(f, try XCTUnwrap(m.press(id)).direction).theta)° · '\(tl.line)'")
        XCTAssertTrue(tl.line.contains("\u{00B0}") || tl.line.contains("mm"), "★ with its number: \(tl.line)")
        // RED CONTROL: the toast only — no red line on the card
        FlexibleStageModel.controlToastOnly = true
        m.lastFlatStop = nil
        _ = await m.setFlatAngle(id, degrees: -85, tilt: true)
        try await reopened(m)
        FlexibleStageModel.controlToastOnly = false
        XCTAssertNil(m.lastFlatStop?.line.contains("Held") == true ? m.lastFlatStop : nil, "RED CONTROL: no red line (a 2 s toast only)")
    }
}
