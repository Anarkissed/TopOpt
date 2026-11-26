// PrintResolutionHostedTests — ★ his 11-25 ("Offer print resolutions when exporting. Full detail vs medium vs coarse. All with
// information about their file size estimates and resolution."), on the real Results page at his two iPad sizes (13″ landscape
// and 820 × 1180 portrait), clicked with real mouse events: Export on a print file opens ONE centred card with the three levels,
// each row a 44 pt target saying its level, its resolution (five words at most), its size and — not made yet — the Mac's time;
// the made one exports at once; another shows the making card, then the share sheet; the ⌃'s Export as STL opens the same card
// in STL sizes. Hosted tests have no SwiftUI accessibility tree: they read frames (ChromeKeepOutKey) and the words drawn
// (FlexibleSaid).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PrintResolutionHostedTests: VersionNotes1123Base {
    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    final class Said { var words: [String] = [] }

    override func tearDownWithError() throws {
        PrintResolutionFlow.shared.reset()
        PrintResolutionFlow.controlNoChoice = false
        AppPopups.shared.current = nil
        ResultsScreen.exportWriteFailsForTests = false
        ResultsScreen.exportAttemptProbe = nil
        PrintFileKeep.open = nil
        FlexibleSaid.recording = false
        try super.tearDownWithError()
    }

    /// A print file's result (a gyroid made at Full as lattice.stl), its file kept with its version.
    private func printFileResult() throws -> OptimizeOutcome {
        let (_, cube) = try optimizedCube()
        let file = Data(repeating: 7, count: 4096)
        let report = try JSONSerialization.data(withJSONObject: printResolutionReport(bytes: file.count))
        let one = AppBuildFixturesLite.outcome(1)
        let outcome = OptimizeOutcome(variants: one.variants, stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                      reportJSON: report)
        PrintFileKeep.stash(file, name: "lattice.stl", projectID: cube.id)
        PrintFileKeep.keep(projectID: cube.id, outcomes: [outcome], store: store)
        PrintFileKeep.open = { [store] in (cube.id, store!) }
        return outcome
    }

    private func page(_ outcome: OptimizeOutcome, _ size: CGSize, said: Said) -> AppBuildHost {
        let v = ResultsScreen(projectName: "Stand", outcome: outcome, undo: {}, redo: {},
                              resultsModel: ResultsModel(projectName: "Stand", outcome: outcome))
            .onPreferenceChange(FlexibleSaidKey.self) { said.words = $0 }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(2)
        return h
    }

    private func waitFor(_ h: AppBuildHost, _ key: String, gone: Bool = false, seconds: Double = 8) -> Bool {
        var waited = 0.0
        while (h.frames.all[key] == nil) != gone, waited < seconds { h.pump(0.25); waited += 0.25 }
        return (h.frames.all[key] == nil) == gone
    }

    /// ★ Export on a print file: the card, centred, its three rows (44 pt) saying what each is; the made one exports at once.
    func testExportOffersTheThreeResolutions() throws {
        FlexibleSaid.recording = true
        var attempts: [String] = []
        ResultsScreen.exportWriteFailsForTests = true
        ResultsScreen.exportAttemptProbe = { attempts.append($0) }
        let outcome = try printFileResult()
        for size in Self.sizes {
            attempts = []
            let said = Said()
            let h = page(outcome, size, said: said)
            try h.tap("resultsExport", "\(size): Export", settle: 1)
            XCTAssertEqual(attempts, ["resolutions"], "\(size): ★ Export opens the levels first (RED CONTROL below: as before)")
            XCTAssertTrue(waitFor(h, "printResolutionCard"), "\(size): ★ the card")
            let card = try h.onScreen("printResolutionCard", "\(size): ★ the levels' card")
            XCTAssertEqual(card.midX, size.width / 2, accuracy: 2, "\(size): ★ centred")
            XCTAssertEqual(card.midY, size.height / 2, accuracy: 2, "\(size): ★ centred")
            var last: CGFloat = 0
            for id in ["full", "medium", "coarse"] {
                let row = try h.probe("printResolution-" + id, "\(size): ★ the \(id) row, a 44 pt target")
                XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(row), "\(size): \(id) inside the card")
                XCTAssertGreaterThan(row.minY, last, "\(size): the levels in order")
                last = row.minY
            }
            try h.probe("printResolutionInfo", "\(size): ★ its (i), a 44 pt target")
            try h.probe("printResolutionCancel", "\(size): Cancel")
            let f = try XCTUnwrap(PrintResolutionFacts.decode(printResolutionReport(bytes: 4096)))
            for l in f.levels {
                XCTAssertTrue(said.words.contains(l.name), "\(size): ★ \(l.name) said: \(said.words)")
                XCTAssertTrue(said.words.contains(l.words), "\(size): ★ its resolution: \(l.words)")
                let b = f.bytes(l, format: "stl")
                XCTAssertTrue(said.words.contains(PrintResolutionCopy.size(b.bytes, estimated: b.estimated)), "\(size): ★ its size")
            }
            XCTAssertTrue(said.words.contains(PrintResolutionCopy.made), "\(size): ★ the made one says so")
            XCTAssertTrue(said.words.contains(PrintResolutionCopy.size(4096, estimated: false)), "\(size): ★ the made file's own size")
            XCTAssertTrue(said.words.contains(PrintResolutionCopy.macTime(31)), "\(size): ★ the Mac's time for Medium")
            XCTAssertTrue(said.words.contains(PrintResolutionCopy.macTime(24)), "\(size): ★ and for Coarse")
            for w in said.words where f.levels.contains(where: { $0.words == w }) || w.hasSuffix("on Mac") || w == PrintResolutionCopy.made {
                XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, "\(size): ★ his rule, five words: \"\(w)\"")
            }
            // the (i): its explanation in the centred card
            try h.tap("printResolutionInfo", "\(size): (i)", settle: 1)
            XCTAssertEqual(AppPopups.shared.current?.title, PrintResolutionCopy.infoTitle)
            XCTAssertEqual(AppPopups.shared.current?.info, true)
            AppPopups.shared.current = nil
            // the made level: exported at once, as before
            try h.tap("printResolution-full", "\(size): Full detail", settle: 1)
            XCTAssertEqual(attempts, ["resolutions", "3mf"], "\(size): ★ the made file, at once")
            XCTAssertTrue(waitFor(h, "printResolutionCard", gone: true), "\(size): the card shut")
        }
    }

    /// ★ Another level: the making card (the hexagons, Cancel), then the share sheet; the ⌃'s Export as STL opens the same card
    /// in STL sizes.
    func testAnotherLevelIsMadeThenShared() throws {
        FlexibleSaid.recording = true
        var attempts: [String] = []
        ResultsScreen.exportAttemptProbe = { attempts.append($0) }
        let outcome = try printFileResult()
        let size = AppBuildHost.landscape13
        let said = Said()
        let h = page(outcome, size, said: said)
        var go = false
        var asked: [String] = []
        PrintResolutionFlow.shared.host = PrintResolutionHost(macReady: { true }, make: { level, format, _, _, _, _ in
            asked.append(level + "." + format)
            while !go { try await Task.sleep(nanoseconds: 50_000_000) }
            return (Data("made".utf8), printResolutionReport(made: level))
        })
        try h.tap("resultsSplitMore", "⌃", settle: 1)
        try h.tap("results-split-export-stl", "Export as STL", settle: 1)
        XCTAssertTrue(waitFor(h, "printResolutionCard"), "★ the same card from the ⌃'s STL")
        XCTAssertEqual(PrintResolutionFlow.shared.ask?.format, "stl")
        try h.tap("printResolution-coarse", "Coarse", settle: 1)
        XCTAssertTrue(waitFor(h, "printResolutionMaking"), "★ the making card")
        let making = try h.onScreen("printResolutionMaking", "★ the making card")
        XCTAssertEqual(making.midX, size.width / 2, accuracy: 2, "★ centred")
        try h.probe("printResolutionMakingCancel", "★ its Cancel, a 44 pt target")
        XCTAssertTrue(said.words.contains(PrintResolutionCopy.makingTitle))
        XCTAssertTrue(said.words.contains("Coarse \u{00B7} surface within 0.1 mm"), "★ which level: \(said.words)")
        go = true
        XCTAssertTrue(waitFor(h, "printResolutionMaking", gone: true), "the card goes once it is made")
        XCTAssertEqual(asked, ["coarse.stl"])
        XCTAssertEqual(PrintResolutionFlow.shared.share?.lastPathComponent.hasSuffix("-coarse.stl"), true, "★ shared")
        XCTAssertEqual(attempts, ["resolutions"], "the made file was never exported")
        // Cancel on the making card stops it
        PrintResolutionFlow.shared.share = nil   // the share sheet put away
        h.pump(1.5)
        go = false
        try h.tap("resultsExport", "Export", settle: 1)
        XCTAssertTrue(waitFor(h, "printResolutionCard"), "the card again: \(attempts)")
        try h.tap("printResolution-medium", "Medium", settle: 1)
        XCTAssertTrue(waitFor(h, "printResolutionMaking"))
        try h.tap("printResolutionMakingCancel", "Cancel", settle: 1)
        XCTAssertTrue(waitFor(h, "printResolutionMaking", gone: true), "★ Cancel stops it")
        go = true
        h.pump(1)
        XCTAssertNil(PrintResolutionFlow.shared.share, "★ nothing shared after a Cancel")
    }

    /// RED CONTROL: before his 11-25 — Export hands out the made file at once, with no choice and no card.
    func testRedControlNoChoice() throws {
        PrintResolutionFlow.controlNoChoice = true
        var attempts: [String] = []
        ResultsScreen.exportWriteFailsForTests = true
        ResultsScreen.exportAttemptProbe = { attempts.append($0) }
        let outcome = try printFileResult()
        let h = page(outcome, AppBuildHost.landscape13, said: Said())
        try h.tap("resultsExport", "Export", settle: 1)
        XCTAssertEqual(attempts, ["3mf"], "RED: the made file, at once")
        XCTAssertNil(h.frames.all["printResolutionCard"], "RED: no card")
    }
}
#endif
