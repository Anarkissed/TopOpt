// Notes23PrintFlowTests — his iPad notes 2026-11-22 (img 47): "If not selected, do we really need to generate a print-accurate
// preview before exporting? If so, do it *after* pressing the 'Export' button. Generate the print-accurate preview first, then
// change the button to 'Approved' and that should lead to the export page/modal."
// Yes (the print file IS the exact lattice): only his press for the file lays it; the button reads "Making the print file"
// for the exact lay and the file's job together, then "Approved" · "Tap to export", whose tap opens the export; any change
// of the part or the lattice settings gives the button back; a file that fails its checks keeps today's way. ⌃ Export… is
// live whenever a lattice preview is on screen (a Draft included) and does the same.
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes23PrintFlowTests: XCTestCase {

    private let id = UUID()
    private let normal = LatticePrintFlow.Look(title: "Lattice", subtitle: "Organic Grown · 1 group · 1 zone", state: .ready,
                                               progress: nil)

    private func project() throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        p.lattice.algorithm = "organic"
        p.lattice.wholePart = true
        return p
    }
    private func key(_ p: ProjectModel) -> LatticeLayoutPreview.LayInputs? {
        p.importedFile.map { LatticeLayoutPreview.layInputs(p, path: $0.path, LatticeLayoutPreview.settings(p, referenceMPa: 20),
                                                            stress: .init(key: 3, field: nil, referenceMPa: 20)) }
    }

    /// ★ The button: laying → "Making the print file" (exact lay and file job together, its ring) → "Approved" · "Tap to export"
    /// (its tap opens the export) → a settings change gives it back. RED CONTROL: another version never shows it.
    func testMakingThenApprovedThenBackOnAChange() throws {
        let p = try project()
        let flow = LatticePrintFlow()
        let lay = LatticeLayoutPreview.LayProgress(quality: .exact, started: Date(), expectedS: 120, draftShown: true)
        XCTAssertEqual(flow.look(for: id, normal: normal, layProgress: lay, fileRunning: false, current: { self.key(p) }).title, "Lattice")
        XCTAssertEqual(flow.look(for: id, normal: normal, layProgress: lay, fileRunning: false, current: { self.key(p) }).subtitle,
                       normal.subtitle, "nothing asked: today's button")

        flow.begin(project: id, key: key(p))
        var l = flow.look(for: id, normal: normal, layProgress: lay, fileRunning: false, current: { self.key(p) })
        XCTAssertEqual(l.subtitle, "Making the print file", "★ never \"Draft · checking print\" for the file")
        XCTAssertEqual(l.progress?.words, "Making the print file", "★ its ring")
        XCTAssertEqual(l.state, .running("Making the print file"))
        XCTAssertEqual(l.tap, .wait, "a second press while it lays starts nothing")
        XCTAssertEqual(l.marker, "latticeMakingFile")
        XCTAssertEqual(flow.look(for: UUID(), normal: normal, layProgress: lay, fileRunning: false, current: { self.key(p) }).subtitle,
                       normal.subtitle, "RED CONTROL: another version's button is its own")

        flow.fileSent()
        l = flow.look(for: id, normal: normal, layProgress: nil, fileRunning: true, current: { self.key(p) })
        XCTAssertEqual(l.subtitle, "Making the print file", "★ the file's job: the same words")
        XCTAssertEqual(l.tap, .viewRun, "a tap views the run, as today")

        XCTAssertTrue(flow.landed(passes: true), "★ it passed: Approved (Results not opened by itself)")
        l = flow.look(for: id, normal: normal, layProgress: nil, fileRunning: false, current: { self.key(p) })
        XCTAssertEqual(l.title, "Approved")
        XCTAssertEqual(l.subtitle, "Tap to export")
        XCTAssertEqual(l.state, .ready)
        XCTAssertNil(l.progress)
        XCTAssertEqual(l.tap, .openExport, "★ its tap opens the export")
        XCTAssertEqual(l.marker, "latticeApproved")

        var look = p.lattice.organicLook ?? LatticeOrganicLook(); look.lookPercent = 40; p.lattice.organicLook = look
        l = flow.look(for: id, normal: normal, layProgress: nil, fileRunning: false, current: { self.key(p) })
        XCTAssertEqual(l.title, "Lattice", "★ a settings change: the button is back")
        XCTAssertEqual(l.tap, .normal)
        look.lookPercent = nil; p.lattice.organicLook = look
    }

    /// A file that fails its checks keeps today's way (no Approved: Results opens and the wizard walks it); a refusal, failure
    /// or cancel gives the button back.
    func testAFailedCheckOrAStopGivesTheButtonBack() throws {
        let p = try project()
        let flow = LatticePrintFlow()
        flow.begin(project: id, key: key(p))
        flow.fileSent()
        XCTAssertFalse(flow.landed(passes: false), "★ not approved: today's way")
        XCTAssertEqual(flow.look(for: id, normal: normal, layProgress: nil, fileRunning: false, current: { self.key(p) }).title, "Lattice")
        flow.begin(project: id, key: key(p))
        flow.ended()
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertFalse(flow.landed(passes: true), "nothing asked: nothing approved")
    }

    /// The words: five at most.
    func testTheWordsAreFew() {
        for w in [LatticePrintFlowCopy.making, LatticePrintFlowCopy.approved, LatticePrintFlowCopy.approvedLine] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, w)
        }
        let t0 = Date()
        let p = DSRunButton.Progress(started: t0, expected: 300, words: LatticePrintFlowCopy.making)
        XCTAssertEqual(p.line(at: t0.addingTimeInterval(100)), "Making the print file \u{00B7} 4 min")
    }

    /// ★ Only his press for the file lays the exact lattice while Print-accurate preview is off: the one `exact: true` is the
    /// print file's wait (organicInputsWhenReady); every other lay leaves `exact` out. ⌃ Export… is live with a lattice preview
    /// on screen and does what the press does; Approved's tap opens the export (Results, as Export… did); a landed file that
    /// passes is Approved instead of opening Results by itself.
    func testOnlyThePressLaysTheExactLatticeAndExportFollowsIt() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        // ★ RE-PINNED (his 11-22, no Mac: "try again", cancel, or make it on the iPad): + the pop-up's "Make it on the iPad",
        // his own press too (macNotAnsweringPopup)
        // ★ RE-PINNED (notes28, his img 82: Check strength on a result with nothing kept lays its exact lattice on the iPad first,
        // on Results too): + Check strength's lay, his own press too (organicCheckPreview)
        XCTAssertEqual(ws.components(separatedBy: "exact: true").count - 1, 3, "★ three exact asks, all his presses")
        let check = try XCTUnwrap(ws.range(of: "private func organicCheckPreview("))
        XCTAssertTrue(String(ws[check.upperBound...].prefix(900)).contains("checkNozzle: false, exact: true)"),
                      "★ the third: Check strength's own lay")
        let ipad = try XCTUnwrap(ws.range(of: "func macNotAnsweringPopup("))
        XCTAssertTrue(String(ws[ipad.upperBound...].prefix(600)).contains("refreshLatticePreview(exact: true)"))
        let wait = try XCTUnwrap(ws.range(of: "func organicInputsWhenReady()"))
        XCTAssertTrue(String(ws[wait.upperBound...].prefix(900)).contains("refreshLatticePreview(checkNozzle: false, exact: true)"))
        for call in ws.components(separatedBy: "newEngine.update(").dropFirst() {
            let args = String(call.prefix(220))
            XCTAssertTrue(!args.contains("exact:") || args.contains("exact: exact)"), "only the pass-through: \(args.prefix(120))")
        }
        // (the ⌃ is a drawer since notes23-chrome: its Export… row carries the same gate and tap)
        XCTAssertTrue(ws.contains("items.append(.action(LatticeSetupCopy.export, enabled: latticeExportLive, id: \"lattice-split-export\") { latticeExportTapped() })"),
                      "★ ⌃ Export… does the press, live with a lattice preview on screen")
        XCTAssertTrue(ws.contains("case .openExport: viewOriginal = false"), "★ Approved's tap opens the export")
        XCTAssertTrue(ws.contains("if !latticePrintRunMoved(ph), LatticeFileButton.opensResults("),
                      "★ a passing file is Approved, a failing one opens Results as before")
    }

    #if canImport(AppKit) && canImport(MetalKit)
    /// What passes: an accepted, strong-enough result (an Organic one that certifies: no wizard).
    func testWhatPassesItsChecks() {
        let ok = AppBuildFixtures.outcome()
        XCTAssertTrue(ok.variants.contains { $0.accepted && $0.v3Passes }, "premise")
        XCTAssertTrue(LatticePrintFlow.passes(ok, organic: false, infillNow: 20))
        XCTAssertFalse(LatticePrintFlow.passes(nil, organic: false, infillNow: 20))
        XCTAssertTrue(LatticePrintFlow.passes(ok, organic: true, infillNow: 20), "no spots: it certifies")
    }

    /// ★ Hosted, his two sizes: the Approved button is the corner's run button (64 pt, the same key), and its tap is the export.
    func testApprovedIsTheRunButtonAndItsTapExports() throws {
        let p = try project()
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let flow = LatticePrintFlow()
            flow.begin(project: id, key: key(p))
            flow.fileSent()
            _ = flow.landed(passes: true)
            final class Taps { var all: [LatticePrintFlow.Tap] = [] }
            let taps = Taps()
            let v = LatticeRunButtonFlow(flow: flow, projectID: id, normal: normal, layProgress: nil, fileRunning: false,
                                         current: { self.key(p) }, tap: { taps.all.append($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(24)
            let h = AppBuildHost(v, size: size, test: self)
            h.pump(0.5)
            let b = try h.onScreen("latticeButton", "\(size): the run button")
            XCTAssertNotNil(h.frames.all["latticeApproved"], "\(size): ★ Approved")
            XCTAssertEqual(b.height, 64, accuracy: 1, "\(size): the 64 pt run button")
            try h.tap("latticeButton", "\(size): Approved", settle: 0.3)
            XCTAssertEqual(taps.all, [.openExport], "\(size): ★ its tap opens the export")
        }
    }
    #endif
}
