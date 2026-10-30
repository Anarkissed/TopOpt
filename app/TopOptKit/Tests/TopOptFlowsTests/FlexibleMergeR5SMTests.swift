// FlexibleMergeR5SMTests — what the merge of round 5's batch S (the Settings page: each squeeze
// group's own colour, framing its faces on BOTH pages and in every main-page view) into batch M
// (the main page: each group's own sim, "Play all" playing each group ALONE with its own tints)
// had to decide (task 2026-09-29-flexible-screens, round 5 merge). Each with its RED control:
//   * (★ ROUND 6: "every Play-all turn wears every group's frame" is REPLACED — his img1: the main page
//     wears no group colour at all — by FlexibleRound6HostedTests.testTheMainPageWearsNoGroupColourInAnyViewOrTurn;
//     `frameCheck` stays here, the positive control's counter);
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

    /// Over every group's framed columns in `t` (8 floats per flat vertex, 6 vertices per column):
    /// how many vertices were checked, and how many do NOT wear their band's colour (the group's
    /// colour on the frame, the near-black on the gap).
    static func frameCheck(_ t: [Float], _ o: FlexibleOverlayMesh, _ m: FlexibleStageModel) -> (checked: Int, wrong: Int) {
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
