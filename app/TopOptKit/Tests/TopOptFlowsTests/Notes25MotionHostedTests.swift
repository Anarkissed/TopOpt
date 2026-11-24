// Notes25MotionHostedTests — ★ his iPad notes 2026-11-23 (img 2 + 3), on HIS two iPad sizes, hosted offscreen (never the app):
// his print file's result (Notes25Fixture: his stand's numbers through the real path) on Results, Break played to the top: the
// Break panel sits under the view buttons inside the screen and overlaps no panel, its exaggeration slider is the part's, its line
// says core's one number ("55 kg · 1.34× · GIVES WAY"), the colour key says what red means, Bend plays and pauses.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes25MotionHostedTests: XCTestCase {
    let ui = LoadScenarioHostedTests()

    func frame(_ h: LoadScenarioHostedTests.Host, _ k: String) throws -> CGRect {
        let f = try XCTUnwrap(h.frames.all[k], "★ '\(k)' is not on the screen; frames: \(h.frames.all.keys.sorted())")
        XCTAssertTrue(CGRect(origin: .zero, size: h.size).insetBy(dx: -1, dy: -1).contains(f), "★ '\(k)' leaves the window: \(f)")
        return f
    }

    func testTheBreakPanelOnBothIPadSizes() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let rm = try Notes25Fixture.model()
            let o = try LatticeFileButton.outcome(try Notes25Fixture.made(), densityGCm3: 1.01, organic: true)
            let h = ui.host(ResultsScreen(projectName: "2040 Extrusion Stand copy", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            XCTAssertTrue(rm.canBreak, "premise: a displacement and core's governing margin")
            let brk = try frame(h, "resultsView-Break")
            ui.click(h, CGPoint(x: brk.midX, y: brk.midY))
            let bar = try frame(h, "resultsMotionBar"), views = try frame(h, "resultsViewModes")
            XCTAssertGreaterThan(bar.minY, views.maxY - 1, "★ \(size): right under the view buttons")
            for other in ["resultsChecks", "resultsVersions", "resultsExport"] {
                if let f = h.frames.all[other] {
                    XCTAssertFalse(bar.insetBy(dx: 1, dy: 1).intersects(f.insetBy(dx: 1, dy: 1)), "★ \(size): the Break panel overlaps '\(other)'")
                }
            }
            XCTAssertGreaterThanOrEqual(try frame(h, "resultsMotionPlay").width, 40, "the play button is a finger's size")
            _ = try frame(h, "resultsExaggeration")
            // it plays: the load climbs from his load
            let c0 = rm.loadMotion.clock
            ui.pump(0.8)
            XCTAssertGreaterThan(rm.loadMotion.clock, c0, "★ \(size): Break plays on its own")
            let s = try XCTUnwrap(rm.motionState(.breakIt, reduceMotion: false))
            XCTAssertGreaterThan(s.frame.load, 1, "★ the load climbs from 1.00×")
            XCTAssertLessThanOrEqual(s.frame.load, s.top + 1e-9, "never past the governing margin")
            // the slider to the hold: core's number, where it gives way
            let tl = LoadMotion.breakTimeline
            let slider = try frame(h, "resultsMotionSlider")
            ui.click(h, CGPoint(x: slider.minX + slider.width * (tl.up + tl.hold * 0.5) / tl.cycle, y: slider.midY))
            let top = try XCTUnwrap(rm.motionState(.breakIt, reduceMotion: false))
            XCTAssertTrue(top.frame.atTop, "★ \(size): the slider moves it by hand to the top (\(rm.loadMotion.position(.breakIt)))")
            XCTAssertEqual(rm.breakReadout(top), "55 kg · 1.34× · GIVES WAY")
            let paused = rm.loadMotion.clock
            ui.pump(0.5)
            XCTAssertEqual(rm.loadMotion.clock, paused, accuracy: 1e-9, "★ a hand on the slider pauses it")
            // the colour key: what red means
            let key = try frame(h, "resultsStressKey")
            ui.click(h, CGPoint(x: key.midX, y: key.midY))
            let words = try frame(h, "resultsStressKeyTop")
            XCTAssertTrue(try frame(h, "resultsStressKey").contains(words), "★ \(size): 'Gives way' sits on the key")
            try ui.picture(h, "notes25_break_\(Int(size.width))x\(Int(size.height)).png")
        }
    }

    func testBendPlaysPausesAndScrubsAtBothSizes() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let rm = try Notes25Fixture.model()
            let o = try LatticeFileButton.outcome(try Notes25Fixture.made(), densityGCm3: 1.01, organic: true)
            let h = ui.host(ResultsScreen(projectName: "Stand", outcome: o, undo: {}, redo: {}, resultsModel: rm)
                                .frame(width: size.width, height: size.height), size: size)
            ui.pump(2)
            let bend = try frame(h, "resultsView-Bend")
            ui.click(h, CGPoint(x: bend.midX, y: bend.midY))
            _ = try frame(h, "resultsMotionBar")
            let c0 = rm.loadMotion.clock
            ui.pump(0.6)
            XCTAssertNotEqual(rm.loadMotion.clock, c0, "★ \(size): the part bends on its own")
            let play = try frame(h, "resultsMotionPlay")
            ui.click(h, CGPoint(x: play.midX, y: play.midY))
            let held = rm.loadMotion.clock
            ui.pump(0.5)
            XCTAssertEqual(rm.loadMotion.clock, held, accuracy: 1e-9, "★ Pause holds it")
            let s = try XCTUnwrap(rm.motionState(.bend, reduceMotion: false))
            XCTAssertEqual(s.top, 1, "Bend runs up to his load")
            XCTAssertLessThanOrEqual(s.exaggeration, s.range.high + 1e-9, "the exaggeration inside the part's own top")
            try ui.picture(h, "notes25_bend_\(Int(size.width))x\(Int(size.height)).png")
        }
    }
}
#endif
