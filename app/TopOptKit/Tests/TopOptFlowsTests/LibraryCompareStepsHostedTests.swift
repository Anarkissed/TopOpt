// LibraryCompareStepsHostedTests — ★ his iPad notes 11-05 (ledger L3, his "Yes, as written"): "nothing happens when you have
// gone through ALL comparisons … It should automatically go back to the Parts' page … set whichever the user thought was
// 'Better' … automatically go to the 'Next' comparison after selecting 'Better' and have some sort of animation … show each
// rejection from the comparison ON the parts' page … add some kind of 'Skip' … If skipped again, the comparison exits with a
// flag of 'In consideration'." His name ask: one word — Tie.
//
// RED before (saved: scratchpad b2red/LibraryCompareSteps_build.txt): Better only marked a side and a › brought the next one;
// nothing was rejected, there was no Tie, and after the last pair Compare stayed open.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LibraryCompareStepsHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-lib-compare-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// LibraryPartRowsHostedTests' Carriage Arms; `rejectFirst` results already Rejected, so Skip rejected (on) leaves the rest.
    private func compare(rejectFirst: [(String, Int)]) throws -> (AppBuildHost, AppModel, [String: UUID]) {
        let (app, f) = try LibraryPartRowsHostedTests.arms(root: root)
        for (v, r) in rejectFirst { app.library.toggleReject(folder: try XCTUnwrap(f[v]), result: r) }
        app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"]))).id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        let c = try h.probe("library-compare", "the part page's Compare")
        h.click(CGPoint(x: c.midX, y: c.midY), settle: 2)
        return (h, app, f)
    }

    /// A result sliding in: wait (up to 2 s) until it has landed in the window; then it must be wholly on screen.
    /// The host's window is off screen, with no display link: a slide ends DRAWN in place (its picture shows it, 11-05) but
    /// its frames are sometimes not sent again. One layout pass sends them as they are; a panel truly stuck off screen
    /// still reports off screen, so the check keeps its teeth.
    @discardableResult
    private func landed(_ h: AppBuildHost, _ key: String, _ what: String) throws -> CGRect {
        let window = CGRect(origin: .zero, size: h.size).insetBy(dx: -0.5, dy: -0.5)
        func inside() -> Bool { h.frames.all[key].map { window.contains($0) } ?? false }
        var waited = 0.0
        while waited < 2, !inside() { h.pump(0.25); waited += 0.25 }
        if !inside() {
            h.view.setFrameSize(NSSize(width: h.size.width, height: h.size.height + 1)); h.pump(0.2)
            h.view.setFrameSize(NSSize(width: h.size.width, height: h.size.height)); h.pump(0.3)
        }
        return try h.onScreen(key, what)
    }

    /// A tap on a control that may still be sliding in: once it has landed.
    private func tap(_ h: AppBuildHost, _ key: String, _ what: String, settle: Double = 1.5) throws {
        try landed(h, key, what)
        let r = try h.probe(key, what)
        h.click(CGPoint(x: r.midX, y: r.midY), settle: settle)
    }

    /// ★ Better rejects the other side at once (red stamp), the next slides in, the winner stays; after the last pair Compare
    /// goes back to the part page by itself, the winner chosen, each rejection on the page.
    func testBetterRejectsTheOtherTheNextComesInAndTheLastOneLeftIsChosen() throws {
        let (h, app, f) = try compare(rejectFirst: [("1", 0), ("1", 1), ("1", 2), ("1.1", 0), ("1.1", 1), ("1.1", 2)])
        let v2 = try XCTUnwrap(f["2"])
        _ = try h.onScreen("compare-showing-v2a", "it opens on v2a")
        _ = try h.onScreen("compare-showing-v2b", "against v2b")
        let b0 = try h.probe("compare-better-0", "v2a's Better")
        let b1 = try h.probe("compare-better-1", "v2b's Better")
        let tie = try h.probe("compare-tie", "★ Tie, a 44 pt target")
        XCTAssertTrue(b0.maxX < tie.minX && tie.maxX < b1.minX, "★ Tie sits between the two Betters")
        XCTAssertEqual(tie.midY, b0.midY, accuracy: 24, "★ level with them")

        try tap(h, "compare-better-0", "v2a's Better", settle: 0.15)
        XCTAssertTrue(try XCTUnwrap(app.library.version(v2)).mark(for: 1).rejected, "★ v2b is Rejected the moment Better is pressed")
        _ = try h.onScreen("compare-stamp-1", "★ a red Rejected stamp on v2b before it goes")
        try landed(h, "compare-showing-v2c", "★ the next one comes in, no › to press")
        _ = try h.onScreen("compare-showing-v2a", "★ the winner stays")
        XCTAssertNil(h.frames.all["compare-showing-v2b"], "v2b has gone")
        XCTAssertNil(h.frames.all["compare-next"], "★ no › any more")

        try tap(h, "compare-better-0", "v2a's Better again", settle: 2.5)
        XCTAssertNil(h.frames.all["compare-tie"], "★ the last pair decided: Compare has gone back to the part page")
        _ = try h.onScreen("library-version-v2", "the part page")
        let part = try XCTUnwrap(app.library.index.part(containing: v2))
        XCTAssertEqual(app.library.chosen(of: part), LibraryChosen(folder: v2, result: 0), "★ the last one left is the part's chosen")
        XCTAssertEqual(app.toast, "v2a chosen · 2 rejected", "★ his toast")
        _ = try h.onScreen("library-result-v2a-picked", "★ v2a reads Picked on its card")
        _ = try h.onScreen("library-result-v2b-rejected", "★ each rejection shows on the part page")
        _ = try h.onScreen("library-result-v2c-rejected", "★ both")
    }

    /// ★ Tie sets both aside and the next two come in; once all are seen they come back against the winner; a second Tie ends
    /// Compare with the undecided In consideration (amber, removable like any flag).
    func testTieThenASecondTieEndsInConsideration() throws {
        let (h, app, f) = try compare(rejectFirst: [("1", 0), ("1", 1), ("1", 2), ("1.1", 0), ("1.1", 1)])
        let v2 = try XCTUnwrap(f["2"]), v11 = try XCTUnwrap(f["1.1"])
        _ = try h.onScreen("compare-showing-v2a", "v2a")
        _ = try h.onScreen("compare-showing-v2b", "against v2b")

        try tap(h, "compare-tie", "Tie")
        try landed(h, "compare-showing-v2c", "★ Tie: the next two come in")
        try landed(h, "compare-showing-v1.1c", "★ both")
        XCTAssertNil(h.frames.all["compare-showing-v2a"], "v2a is set aside")
        XCTAssertFalse(try XCTUnwrap(app.library.version(v2)).mark(for: 0).rejected, "★ a Tie rejects nothing")

        try tap(h, "compare-better-1", "v1.1c's Better")
        XCTAssertTrue(try XCTUnwrap(app.library.version(v2)).mark(for: 2).rejected, "v2c rejected")
        try landed(h, "compare-showing-v2a", "★ every result seen: a set-aside one comes back against the winner")
        _ = try h.onScreen("compare-showing-v1.1c", "the winner stays")

        try tap(h, "compare-tie", "the second Tie", settle: 2.5)
        XCTAssertNil(h.frames.all["compare-tie"], "★ the second Tie ends Compare")
        let part = try XCTUnwrap(app.library.index.part(containing: v2))
        XCTAssertEqual(app.library.chosen(of: part), LibraryChosen(folder: v2, result: 1), "no new chosen: the fixture's v2b stays")
        XCTAssertEqual(app.toast, "3 in consideration · 1 rejected")
        for (folder, r) in [(v2, 0), (v2, 1), (v11, 2)] {
            XCTAssertTrue(try XCTUnwrap(app.library.version(folder)).mark(for: r).inConsideration, "★ \(r) is In consideration")
        }
        XCTAssertEqual(LibraryFlag.considering.colour, DS.Color.warning, "★ amber")
        let chip = try h.probe("library-result-v2a-considering", "★ v2a's In consideration flag, a 44 pt target")
        h.click(CGPoint(x: chip.midX, y: chip.midY), settle: 1)
        XCTAssertFalse(try XCTUnwrap(app.library.version(v2)).mark(for: 0).inConsideration, "★ a tap takes it off")
        XCTAssertEqual(app.library.flagUndo?.text, "In consideration removed", "with Undo")
    }
}
#endif
