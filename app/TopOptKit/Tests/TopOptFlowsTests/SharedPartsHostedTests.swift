// SharedPartsHostedTests — B2's shared parts whose pages come later (U13 the clear-all confirm → B9's Print plan › Reset;
// §4.24 the one drag Handle → B6's prism ends and zones, B8's cut; §4.35 the Play timeline → B9's Print plan and #362's
// Squish / Setup Play). Each is mounted on an iPad-sized page of its own and driven with real events.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

private final class PartsState: ObservableObject {
    @Published var asking = false
    @Published var cleared = 0
    @Published var along: CGFloat = 0
    @Published var released: CGFloat?
    @Published var position = 0.0
}

private struct PartsPage: View {
    @ObservedObject var s: PartsState
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DS.Color.background.color
            // the clear-all action at one edge (bottom-left), as Print plan › Reset sits
            Button("Reset") { s.asking = true }
                .frame(width: 88, height: 44).background(CornerPairStyle.publish("reset"))
                .padding(.leading, PageChrome.edge).padding(.bottom, PageChrome.edge)
            DragHandle(key: "test", axis: CGVector(dx: 1, dy: -1), value: String(format: "%.1f mm", s.along)) { a, ended in
                s.along = a; if ended { s.released = a }
            }
            .position(x: 500, y: 500)
            PlayTimeline(caption: "2 pieces · apart, as they print", leftEnd: "Apart", rightEnd: "Together",
                         position: $s.position)
                .frame(maxWidth: .infinity).padding(.bottom, 120)
            if s.asking {
                ClearAllConfirm(question: "Clear every print plan?", detail: "Its cuts, joints, add-ons and places go.",
                                keep: { s.asking = false }, clear: { s.cleared += 1; s.asking = false })
            }
        }
    }
}

@MainActor
final class SharedPartsHostedTests: XCTestCase {
    fileprivate func host() -> (AppBuildHost, PartsState) {
        let s = PartsState()
        let h = AppBuildHost(PartsPage(s: s), size: AppBuildHost.landscape13, test: self)
        h.pump(1)
        return (h, s)
    }

    /// U13: the yes is ≥ 300 pt from the button that opened it; Keep them (left) keeps; Clear all (right) clears.
    func testTheClearAllYesIsFarFromItsButton() throws {
        let (h, s) = host()
        try h.tap("reset", "Reset")
        let reset = try h.onScreen("reset", "Reset")
        let yes = try h.probe("clearAllYes", "★ Clear all", minHit: 44)
        let keep = try h.probe("clearAllKeep", "Keep them", minHit: 44)
        let card = try h.onScreen("clearAllCard", "the confirm")
        let d = hypot(yes.midX - reset.midX, yes.midY - reset.midY)
        XCTAssertGreaterThanOrEqual(d, 300, "★ U13 — the finger travels \(d) pt to say yes")
        XCTAssertEqual(card.midX, h.size.width / 2, accuracy: 1, "at the top middle")
        XCTAssertLessThan(keep.midX, yes.midX, "Keep them left, Clear all right")
        try h.tap("clearAllKeep", "Keep them")
        XCTAssertEqual(s.cleared, 0); XCTAssertFalse(s.asking, "Keep them keeps them")
        try h.tap("reset", "Reset again")
        try h.tap("clearAllYes", "Clear all")
        XCTAssertEqual(s.cleared, 1, "Clear all clears")
    }

    /// §4.24: the handle — 44 pt, its number beside it — and a move counts only along its axis. (A drag synthesised on an
    /// offscreen page of its own never reaches a plain view's gesture — the window is not key in a test run; the drags are
    /// proven where the handle is mounted on a real page: B6's prism ends, B8's cut.)
    func testTheHandleIsATargetAndMovesAlongItsAxisOnly() throws {
        let (h, _) = host()
        let f = try h.probe("handle-test", "★ the handle, 44 pt", minHit: 44)
        let v = try h.onScreen("handleValue-test", "its number")
        XCTAssertEqual(v.midY, f.midY, accuracy: 1, "★ its number rides beside it")
        XCTAssertGreaterThan(v.minX, f.maxX - 0.5)
        XCTAssertEqual(DragHandle.along(CGSize(width: 60, height: -60), axis: CGVector(dx: 1, dy: -1)), 60 * 2.0.squareRoot(),
                       accuracy: 1e-6, "★ along its axis")
        XCTAssertEqual(DragHandle.along(CGSize(width: 50, height: 50), axis: CGVector(dx: 1, dy: -1)), 0, accuracy: 1e-6,
                       "★ across its axis: nothing")
        XCTAssertEqual(DragHandle.along(CGSize(width: 0, height: 30), axis: CGVector(dx: 0, dy: -1)), -30, accuracy: 1e-6,
                       "down on an up handle: less")
    }

    /// §4.35: the timeline — 64 pt, bottom centre — ▶ plays (a real click), ❚❚ stops it; the track maps a finger to its place.
    func testTheTimelinePlaysAndItsTrackScrubs() throws {
        let (h, s) = host()
        let t = try h.onScreen("timeline", "the timeline")
        XCTAssertEqual(t.height, PlayTimeline.height, accuracy: 0.5, "64 pt")
        XCTAssertEqual(t.midX, h.size.width / 2, accuracy: 1, "bottom centre")
        _ = try h.probe("timelinePlay", "★ ▶, a 44 pt target", minHit: 44)
        let track = try h.onScreen("timelineTrack", "its track")
        XCTAssertGreaterThanOrEqual(track.height, 44 - 0.5, "the track is a 44 pt target")
        XCTAssertEqual(PlayTimeline.position(atX: 8 + (track.width - 16) * 0.75, trackWidth: track.width), 0.75, accuracy: 1e-9,
                       "★ a finger on the track puts it there")
        XCTAssertEqual(PlayTimeline.position(atX: -40, trackWidth: track.width), 0, "never past its ends")
        try h.tap("timelinePlay", "▶", settle: 0.8)
        let a = s.position
        h.pump(0.6)
        XCTAssertNotEqual(s.position, a, "★ ▶ plays")
        try h.tap("timelinePlay", "❚❚", settle: 0.2)
        let b = s.position
        h.pump(0.5)
        XCTAssertEqual(s.position, b, accuracy: 1e-9, "❚❚ stops it")
    }
}

final class PlayTimelineClockTests: XCTestCase {
    func testThereAndBackWithAPauseAtEachEnd() {
        let c = PlayTimelineClock(travel: 2, pause: 0.5)
        XCTAssertEqual(c.position(at: 0), 0)
        XCTAssertEqual(c.position(at: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.position(at: 2.2), 1, "paused at the far end")
        XCTAssertEqual(c.position(at: 3.5), 0.5, accuracy: 1e-9, "and back")
        XCTAssertEqual(c.position(at: 4.7), 0, "paused at the near end")
        XCTAssertEqual(c.position(at: 5 + 1), 0.5, accuracy: 1e-9, "again and again")
        XCTAssertEqual(PlayTimelineClock.step(from: 0.2), 1, "reduced motion: a step to the other end")
        XCTAssertEqual(PlayTimelineClock.step(from: 0.9), 0)
    }
}
#endif
