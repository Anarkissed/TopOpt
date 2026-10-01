// FlexibleMergeR5SMTests — what the merge of round 5's batch S (the Settings page: each squeeze
// group's own colour, framing its faces on BOTH pages and in every main-page view) into batch M
// (the main page: each group's own sim, "Play all" playing each group ALONE with its own tints)
// had to decide (task 2026-09-29-flexible-screens, round 5 merge). Each with its RED control:
//   * every "Play all" turn wears EVERY group's frame — the renderer swaps a turn's own tints in
//     with its field (batch G verification), and those were composed without S's frames, so under
//     the default "Play all" the frames vanished from the main page. RED: the turns without the
//     merge's paint (`controlTurnsWithoutFrames`);
//   * the player's dot is the PLAYING group's (batch M) in its CHOSEN colour (batch S). RED: each
//     side's own rule — S's (the pick only: no dot under "Play all") and M's (the default palette).
#if canImport(MetalKit)
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleMergeR5SMTests: XCTestCase {

    /// His project split as his img 4 (group 1: the top; group 2: Faces 3 and 5), through Save &
    /// Exit, until every sim has landed — FlexibleSquishVerifyGTests' own route.
    func stage() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        m.edit { s in
            _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
            FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
        }
        try await FlexibleSquishFixture.settle(m, "his split")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 400 {
            if m.lattice != nil, !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }   // the page's debounced refreshes
        XCTAssertFalse(m.squish.isEmpty, "the sims ran")
        return (r, stage, m)
    }

    /// Over every group's framed columns in `t` (8 floats per flat vertex, 6 vertices per column):
    /// how many vertices were checked, and how many do NOT wear their band's colour (the group's
    /// colour on the frame, the near-black on the gap).
    func frameCheck(_ t: [Float], _ o: FlexibleOverlayMesh, _ m: FlexibleStageModel) -> (checked: Int, wrong: Int) {
        var checked = 0, wrong = 0
        for g in FlexibleSqueezeGroups.groups(m.settings) {
            let c = FlexibleColours.token(FlexibleSqueezeGroups.colourChoice(of: g, in: m.settings).rgba, 1)
            for r in g.regions {
                guard let k = m.key(r), let st = m.stacks[k], let start = o.flatStart[k] else { continue }
                for (i, b) in FlexibleGroupFrames.bands(st).enumerated() where b != .heat {
                    let want = b == .frame ? c : FlexibleGroupFrames.gapColour
                    for j in 0..<6 {
                        let v = start + i * 6 + j
                        guard v * 8 + 3 < t.count else { continue }
                        checked += 1
                        if SIMD4(t[v * 8], t[v * 8 + 1], t[v * 8 + 2], t[v * 8 + 3]) != want { wrong += 1 }
                    }
                }
            }
        }
        return (checked, wrong)
    }

    func testEveryPlayAllTurnWearsEveryGroupsFrame() async throws {
        let (r, s, m) = try await stage()
        let o = try XCTUnwrap(s.overlay)
        XCTAssertEqual(s.shownSimInfo?.kind, .playAll, "Play all is the default")
        XCTAssertTrue(s.playAllLive)
        let seq = s.fe.sequence
        XCTAssertEqual(seq.map { s.fe.fields[$0].simID }, ["group-1", "group-2"])
        XCTAssertEqual(Set(s.feBaseTints.keys), ["group-1", "group-2"])
        func turns() throws -> [(id: String, checked: Int, wrong: Int)] {
            try seq.map { i in
                s.loop.shownIndex = i
                let t = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
                let id = s.fe.fields[i].simID
                XCTAssertEqual(t, s.feTintBox.tints(id), "the page hands the turn the renderer shows")
                let f = frameCheck(t, o, m)
                return (id, f.checked, f.wrong)
            }
        }
        let after = try turns()
        let composed = frameCheck(try XCTUnwrap(s.composed), o, m)
        print("FLEX-MERGE-R5 frames under Play all: " + after.map { "\($0.id) \($0.wrong) of \($0.checked) off" }.joined(separator: " · ")
              + " · the composed (no turn) \(composed.wrong) of \(composed.checked) off")
        for t in after {
            XCTAssertGreaterThan(t.checked, 0)
            XCTAssertEqual(t.wrong, 0, "\(t.id)'s turn: every group's faces framed in its colour")
        }
        XCTAssertEqual(composed.wrong, 0)
        // ★ RED CONTROL: the turns composed without the merge's paint (batch S's frames on the
        // composed tints only) — the renderer swaps those in, and the frames are gone
        s.controlTurnsWithoutFrames = true
        s.refresh()
        let red = try turns()
        print("FLEX-MERGE-R5 control (turns without frames): " + red.map { "\($0.id) \($0.wrong) of \($0.checked) off" }.joined(separator: " · "))
        for t in red { XCTAssertGreaterThan(t.wrong, t.checked / 2, "control: \(t.id)'s turn lost the frames") }
    }

    func testThePlayersDotIsThePlayingGroupInItsChosenColour() {
        let loop = FlexibleSquishLoop()
        let g1 = FlexibleSim(id: FlexibleSim.groupID(1), kind: .group(1), title: "Group 1", short: "Group 1", keys: [])
        let g2 = FlexibleSim(id: FlexibleSim.groupID(2), kind: .group(2), title: "Group 2", short: "Group 2", keys: [])
        let all = FlexibleSim(id: FlexibleSim.allID, kind: .playAll, title: "Play all", short: "All", keys: [])
        let picked = DS.Color.accent   // his pick for group 2: blue (its default is orange)
        let chosen: (Int) -> RGBA = { $0 == 2 ? picked : FlexibleGroupColour.byNumber($0).rgba }
        loop.notePlaying(g2.id)
        let p = FlexibleSquishPlayer(loop: loop, fullLabel: "", playAllLive: true, sims: [all, g1, g2], shown: all, colour: chosen)
        XCTAssertEqual(p.playingGroup?.id, g2.id)
        XCTAssertEqual(p.dotColour, picked, "Play all, group 2's turn: its dot in his pick")
        // a group picked: its own dot, its own colour
        let one = FlexibleSquishPlayer(loop: loop, fullLabel: "", playAllLive: false, sims: [all, g1, g2], shown: g1, colour: chosen)
        XCTAssertEqual(one.dotColour, FlexibleGroupColour.green.rgba)
        // ★ RED CONTROLS: each side's own rule on the same player
        var sRule: RGBA?   // batch S: the PICK's group only — under Play all there is none
        if case .group(let n)? = p.shown?.kind { sRule = chosen(n) }
        XCTAssertNil(sRule, "control (S): no dot while Play all plays a group")
        var mRule: RGBA?   // batch M: the playing group, in the DEFAULT palette
        if case .group(let n)? = (p.playingGroup ?? p.shown)?.kind { mRule = FlexibleSqueezeGroups.colour(number: n) }
        XCTAssertNotEqual(mRule, picked, "control (M): the default orange, not his blue")
    }
}
#endif
