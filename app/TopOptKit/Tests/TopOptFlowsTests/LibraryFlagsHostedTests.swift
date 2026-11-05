// LibraryFlagsHostedTests — ★ his iPad notes 11-05 (ledger L2, his answers): "There should be a way to filter out 'Rejected'
// versions - or to view them alone. The 'Rejected' icon/flag should be RED. There should be a way to remove any flag (Print
// this OR rejected)." His answers: a chip beside Newest, "Rejected: Shown ⌄" — Shown │ Hidden │ Only rejected (Shown first);
// tap a flag to remove it, wherever it shows, with Undo.
//
// RED before (saved: scratchpad b2red/LibraryFlags.txt): Rejected was a grey tag, there was no Rejected chip, and a flag only
// came off from the result's ⋯ ("Not for print", "Not rejected").
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LibraryFlagsHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topopt-lib-flags-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// LibraryPartRowsHostedTests' Carriage Arms (v1, v2 with a · b · c, v3 a draft, v1.1 a branch) on its part page.
    private func host() throws -> (AppBuildHost, AppModel, [String: UUID]) {
        let (app, f) = try LibraryPartRowsHostedTests.arms(root: root)
        app.library.route = .part(try XCTUnwrap(app.library.index.part(containing: try XCTUnwrap(f["2"]))).id)
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        return (h, app, f)
    }

    func testRejectedIsRedAndATapTakesAFlagOffWithUndo() throws {
        let (h, app, f) = try host()
        let v2 = try XCTUnwrap(f["2"])
        app.library.toggleReject(folder: v2, result: 2)
        app.library.togglePrint(folder: v2, result: 0)
        h.pump(1)
        XCTAssertEqual(LibraryFlag.rejected.colour, DS.Color.danger, "★ Rejected is red")
        XCTAssertEqual(LibraryFlag.printThis.colour, DS.Color.okGreen, "Print this keeps its green")
        let chip = try h.probe("library-result-v2c-rejected", "★ v2c's Rejected flag, a 44 pt target")
        _ = try h.probe("library-result-v2a-print", "★ v2a's Print flag, a 44 pt target")
        // a tap takes it off, and Undo puts it back
        h.click(CGPoint(x: chip.midX, y: chip.midY), settle: 1)
        XCTAssertFalse(try XCTUnwrap(app.library.version(v2)).mark(for: 2).rejected, "★ the tap removes the flag")
        XCTAssertNil(h.frames.all["library-result-v2c-rejected"], "it is gone from the card")
        let undo = try h.probe("libraryFlagUndo", "★ \"Rejected removed · Undo\"")
        XCTAssertEqual(app.library.flagUndo?.text, "Rejected removed")
        h.click(CGPoint(x: undo.midX, y: undo.midY), settle: 1)
        XCTAssertTrue(try XCTUnwrap(app.library.version(v2)).mark(for: 2).rejected, "★ Undo puts it back")
        XCTAssertNil(app.library.flagUndo, "and the Undo goes")
        _ = try h.onScreen("library-result-v2c-rejected", "back on the card")
        // Print this the same way
        let print = try h.probe("library-result-v2a-print", "v2a's Print flag")
        h.click(CGPoint(x: print.midX, y: print.midY), settle: 1)
        XCTAssertFalse(try XCTUnwrap(app.library.version(v2)).mark(for: 0).printThis, "★ Print this comes off too")
        XCTAssertEqual(app.library.flagUndo?.text, "Print removed")
    }

    /// Quick look's Print this / Reject take a flag off the same way (with Undo).
    func testQuickLookTakesAFlagOffWithUndo() throws {
        let (h, app, f) = try host()
        let v2 = try XCTUnwrap(f["2"])
        app.library.toggleReject(folder: v2, result: 2)
        h.pump(1)
        let c = try h.onScreen("library-mini-v2c", "v2c, small")
        h.click(CGPoint(x: c.midX, y: c.midY), settle: 1.5)
        let reject = try h.probe("libraryQuickLook-reject", "Quick look's Reject, on")
        h.click(CGPoint(x: reject.midX, y: reject.midY), settle: 1)
        XCTAssertFalse(try XCTUnwrap(app.library.version(v2)).mark(for: 2).rejected, "★ off")
        _ = try h.probe("libraryFlagUndo", "★ the Undo shows over Quick look too")
    }

    func testTheRejectedChipShowsHidesOrShowsOnlyThem() throws {
        let (h, app, f) = try host()
        app.library.toggleReject(folder: try XCTUnwrap(f["2"]), result: 2)
        h.pump(1)
        let chip = try h.onScreen("library-rejected-filter", "★ the Rejected chip")
        let sort = try h.onScreen("library-sort", "Newest")
        XCTAssertEqual(chip.midY, sort.midY, accuracy: 2, "beside Newest")
        XCTAssertLessThan(chip.maxX, sort.minX, "before it")
        // Shown (the default): everything, the rejected one in red
        _ = try h.onScreen("library-result-v2c-rejected", "Shown: v2c with its red flag")
        _ = try h.onScreen("library-version-v3", "Shown: the draft")
        let items = try h.pickFromMenu("library-rejected-filter", "Hidden", what: "the Rejected chip")
        XCTAssertEqual(items, ["Shown", "Hidden", "Only rejected"], "★ his three")
        h.pump(1)
        XCTAssertNil(h.frames.all["library-result-v2c"], "★ Hidden: v2c's line is gone")
        XCTAssertNil(h.frames.all["library-mini-v2c"], "and its small picture")
        _ = try h.onScreen("library-result-v2a", "v2's other results stay")
        _ = try h.onScreen("library-version-v1", "other versions stay")
        _ = try h.pickFromMenu("library-rejected-filter", "Only rejected", what: "the Rejected chip")
        h.pump(1)
        _ = try h.onScreen("library-result-v2c", "★ Only rejected: v2c")
        XCTAssertNil(h.frames.all["library-result-v2a"], "★ only the rejected results")
        XCTAssertNil(h.frames.all["library-version-v1"], "a version with none rejected goes")
        XCTAssertNil(h.frames.all["library-version-v3"], "and the draft")
        _ = try h.pickFromMenu("library-rejected-filter", "Shown", what: "the Rejected chip")
        h.pump(1)
        _ = try h.onScreen("library-result-v2a", "Shown again: everything")
    }
}
#endif
