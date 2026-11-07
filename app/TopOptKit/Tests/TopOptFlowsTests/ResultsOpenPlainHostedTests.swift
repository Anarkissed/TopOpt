// ResultsOpenPlainHostedTests — B4, ledger note 13 (approved design 2026-11-02, plan.md §B4, mockup #topo-results).
//
// His words: "The results page starts with the stress view. It should always start with the default view and there shouldn't
// be a view button for the default view. Default should happen when no views are selected." Results opens with no view lit
// (the plain part, no key); there is no Solid button; tapping the lit view again turns it off, back to the plain part.
// RED before B4 (saved: scratchpad b2red/ResultsOpenPlain.txt): Stress lit on open, and a Solid button.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsOpenPlainHostedTests: XCTestCase {
    func testResultsOpensPlainWithNoSolidAndTheLitViewTurnsOff() throws {
        let t = ResultsRedesignHostedTests()
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let (h, rm) = try t.screen(size)
            let what = "\(size)"
            XCTAssertTrue(rm.hasStress, "premise: a run with stress")
            XCTAssertNil(h.frames.all["resultsView-Solid"], "\(what): ★ no Solid button")
            XCTAssertFalse(rm.stressOn, "\(what): ★ no view lit: the plain part")
            XCTAssertNil(h.frames.all["resultsStressKey"], "\(what): ★ no key on the plain part")
            let st = try XCTUnwrap(h.frames.all["resultsView-Stress"], "\(what): the Stress button")
            t.ui.click(h, CGPoint(x: st.midX, y: st.midY))
            XCTAssertTrue(rm.stressOn, "\(what): Stress lights")
            t.ui.click(h, CGPoint(x: st.midX, y: st.midY))
            XCTAssertFalse(rm.stressOn, "\(what): ★ the lit view tapped again: back to the plain part")
        }
    }
}
#endif
