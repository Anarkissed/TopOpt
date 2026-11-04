// FlexibleRound7FitHostedTests — round 7, batch R7-D1, look-and-fix 3 (2026-10-17). What looking at the mini found: the
// corner pair's panels and button, drawn for the mini's 336 pt (and a 240 pt split), CUT his words — the Setup tray's
// Quality read "Fa… Bal…", Plate up "+Z · assu…", "Print paramet…"; the card's sends "Send Group 2 only, Face 2 re…" and
// "Export G-/code" on two lines; the button "Preview · core runs one group at a ti…". His rule (2026-09-29): one visible
// line per setting, whole.
//
// Each one-line text (and each whole Setup row) publishes, while a test measures, how wide it is drawn and how wide it needs
// to be at its smallest allowed size (FlexibleSaid.measuring, `saidWhole`). Here the tray, the card in every core-run
// scenario of condition (a)'s list plus the mini's three-send preview, and the button in every state are hosted at the
// widths the layout gives them on the mini and on the 13" — and nothing may be cut.
// RED CONTROL inside each: the first drawing (the tray's 130 pt title column and roomy segments at 336, the card's body
// beside its titles at 336, the 240 pt split) is caught.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7FitHostedTests: XCTestCase {

    final class Box { var fits: [UUID: FlexibleFit] = [:]; var said: [String] = [] }

    /// Every one-line text the view draws, with its two widths.
    func fits<V: View>(_ v: V, size: CGSize) -> (fits: [FlexibleFit], said: [String]) {
        FlexibleSaid.recording = true
        FlexibleSaid.measuring = true
        defer { FlexibleSaid.recording = false; FlexibleSaid.measuring = false }
        let box = Box()
        let root = v.onPreferenceChange(FlexibleFitKey.self) { box.fits = $0 }
            .onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }
            .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
            .environment(\.colorScheme, .dark)
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        w.contentView = nil
        let measured = box.fits.values.filter { $0.actual != nil && $0.ideal != nil }.sorted { $0.text < $1.text }
        return (measured, box.said)
    }

    static func cut(_ f: [FlexibleFit]) -> [String] {
        f.filter { !$0.whole }.map { "'\($0.text)' drawn \(Int($0.actual ?? 0)) of \(Int(($0.ideal ?? 0) * $0.minScale))" }
    }

    /// A Setup row drawn wider than its tray's inside (the panel's width less its 14 pt sides): it spills past the panel.
    static func spill(_ f: [FlexibleFit], width: CGFloat) -> [String] {
        f.filter { $0.text.hasPrefix("Setup row") && ($0.actual ?? 0) > width - 2 * DS.Space.ml + 0.5 }
            .map { "'\($0.text)' drawn \(Int($0.actual ?? 0)) in \(Int(width - 2 * DS.Space.ml))" }
    }

    static let mini = CGSize(width: 744, height: 1133)
    static let pad13 = CGSize(width: 1032, height: 1376)

    // MARK: the Setup tray

    func tray(_ r: FlexibleHisProject.Restored, width: CGFloat, narrow: Bool) -> (fits: [FlexibleFit], said: [String]) {
        let chrome = FlexibleChromeState()
        let tray = FlexibleSetupTrayState()
        let v = FlexibleCornerPairStyle.panel(width: width, maxHeight: 900) {
            FlexibleSetupTray(project: r.project, tray: tray, chrome: chrome, app: r.app, changeGravity: {}, narrow: narrow)
        }
        return fits(v, size: CGSize(width: width, height: 400))
    }

    func testTheSetupTraysRowsReadWholeOnTheMiniAndTheThirteen() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        var lines: [String] = []
        for (name, v) in [("mini", Self.mini), ("13p", Self.pad13)] {
            let w = FlexibleChromeLayout.panelWidth(v)
            let got = tray(r, width: w, narrow: FlexibleChromeLayout.panelIsNarrow(w))
            XCTAssertGreaterThanOrEqual(got.fits.count, 4 + 3 + 4, "\(name): the four rows, their titles and words were measured")
            for row in ["Quality", "Plate up", "Gravity", "Print parameters"] {
                XCTAssertTrue(got.fits.contains { $0.text == "Setup row \u{00B7} \(row)" }, "\(name): the \(row) row measured")
            }
            XCTAssertEqual(Self.cut(got.fits), [], "★ \(name) (\(Int(w)) pt): every Setup row reads whole")
            XCTAssertEqual(Self.spill(got.fits, width: w), [], "★ \(name) (\(Int(w)) pt): no row is wider than its tray")
            let rows = got.fits.filter { $0.text.hasPrefix("Setup row") }.map { "\($0.text.dropFirst(12)) needs \(Int($0.ideal ?? 0))" }
            lines.append("\(name) \(Int(w)) pt (rows \(Int(w - 2 * DS.Space.ml)) wide): \(got.fits.count) measured, cut \(Self.cut(got.fits).count), "
                         + "spilling \(Self.spill(got.fits, width: w).count) · " + rows.joined(separator: ", "))
        }
        // RED CONTROL: the first drawing at the mini's 336 (the 130 pt title column, the roomy segments)
        let red = tray(r, width: 336, narrow: false)
        let cut = Self.cut(red.fits)
        let spill = Self.spill(red.fits, width: 336)
        lines.append("RED (the first drawing at 336): cut \(cut) · spilling \(spill)")
        print("FLEX-R7D1-FIT tray\n" + lines.joined(separator: "\n"))
        XCTAssertFalse(cut.isEmpty && spill.isEmpty, "★ RED CONTROL: the first drawing does not fit a row in 336")
    }

    // MARK: the card

    /// The mini's preview (his pad's three groups): the hold's sentence and three sends with their resting faces.
    static let threeSends = FlexibleCoreHold(kind: .squeezeGroups, line: FlexibleCoreRun.notSentLine(.squeezeGroups),
                                             why: "Core designs one squeeze group per job.",
                                             fixes: [.send(resting: [3, 5], title: "Send Group 1 only", scope: "Group 1 only"),
                                                     .send(resting: [2], title: "Send Group 2 only, Face 2 resting", scope: "Group 2 only, Face 2 resting"),
                                                     .send(resting: [5], title: "Send Group 3 only, Face 5 resting", scope: "Group 3 only, Face 5 resting")])

    func card(_ sc: FlexibleRound7CardMessagesTests.Scenario, idle: Bool, width: CGFloat, narrow: Bool?) -> (fits: [FlexibleFit], said: [String]) {
        let run = FlexibleCoreRun()
        // idle: looked at, nothing sent (the Preview card: the hold's sends) — else core's answer as the scenario says
        run.setForTests(phase: idle ? .idle : sc.phase, hold: sc.hold, sentJob: nil)
        let state = FlexibleLatticeButton.state(sc.status, phase: idle ? .idle : sc.phase, answerIsCurrent: true)
        let v = FlexibleLatticeCardView(run: run, status: sc.status, state: state, preview: "built \u{00B7} 2 face-prisms \u{00B7} 25.0 mm",
                                        width: width, maxHeight: 2000, narrow: narrow)
        return fits(v, size: CGSize(width: width, height: 1000))
    }

    func testTheCardReadsWholeInEveryCoreRunScenarioOnTheMiniAndTheThirteen() {
        let mini = FlexibleRound7CardMessagesTests.Scenario(name: "the mini's preview (three sends, nothing sent)", phase: .idle, hold: Self.threeSends,
                                                            status: FlexibleRound7CardMessagesTests.preview(Self.threeSends), messages: [])
        var lines: [String] = []
        for (name, v) in [("mini", Self.mini), ("13p", Self.pad13)] {
            let w = FlexibleChromeLayout.panelWidth(v)
            var total = 0
            for (sc, idle) in [(mini, true)] + FlexibleRound7CardMessagesTests.scenarios.map({ ($0, false) }) {
                let got = card(sc, idle: idle, width: w, narrow: nil)
                total += got.fits.count
                XCTAssertTrue(got.fits.contains { $0.text == "Export G-code" }, "\(name) · \(sc.name): the exports measured")
                XCTAssertEqual(Self.cut(got.fits), [], "★ \(name) (\(Int(w)) pt) · \(sc.name): every one-line word reads whole")
            }
            let sends = card(mini, idle: true, width: w, narrow: nil)
            for t in ["Send Group 1 only", "Send Group 2 only, Face 2 resting", "Send Group 3 only, Face 5 resting"] {
                XCTAssertTrue(sends.fits.contains { $0.text == t }, "\(name): '\(t)' measured")
            }
            lines.append("\(name) \(Int(w)) pt: \(1 + FlexibleRound7CardMessagesTests.scenarios.count) scenarios, \(total) measured, none cut")
        }
        // ★ RE-PINNED, extended (round 7, the review of R7-D1 — his rule, one visible line per setting; the review: "Core runs
        // one squeeze group at / a time" wrapped at EVERY size): the hold's line is ONE line, measured whole, at 420 and 336;
        // and the Ready card's job summary (the mockup's "Group 1 · 22 lb · 1 face · bead 0.45 mm") reads whole too.
        // Was: the hold's line could take two lines (`said`, never measured).
        let holdLine = FlexibleLatticeCard.lookLine(Self.threeSends.line)
        let readySummary = "Group 1 \u{00B7} 22 lb \u{00B7} 1 face \u{00B7} bead 0.45 mm"
        for (name, v) in [("mini", Self.mini), ("13p", Self.pad13), ("11p", CGSize(width: 834, height: 1194))] {
            let w = FlexibleChromeLayout.panelWidth(v)
            let got = card(mini, idle: true, width: w, narrow: nil)
            XCTAssertTrue(got.fits.contains { $0.text == holdLine }, "★ \(name): the hold's line '\(holdLine)' is drawn as ONE line, measured")
            XCTAssertEqual(Self.cut(got.fits), [], "★ \(name) (\(Int(w)) pt): the hold's line reads whole on one line")
            let run = FlexibleCoreRun()
            let ready = FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil)
            let rc = fits(FlexibleLatticeCardView(run: run, status: ready, state: .ready, preview: "built \u{00B7} Face 1 \u{00B7} 20.0 mm",
                                                  width: w, maxHeight: 2000, summary: readySummary), size: CGSize(width: w, height: 1000))
            XCTAssertTrue(rc.fits.contains { $0.text == readySummary }, "★ \(name): Ready says what goes to core ('\(readySummary)')")
            XCTAssertEqual(Self.cut(rc.fits), [], "★ \(name): the Ready card reads whole")
            lines.append("\(name) \(Int(w)) pt: the hold's line and the Ready summary on one line, whole")
        }
        // RED CONTROL: the first drawing at the mini's 336 — the body beside a 64 pt title column
        let red = card(mini, idle: true, width: 336, narrow: false)
        let cut = Self.cut(red.fits)
        lines.append("RED (the body beside the titles at 336): cut \(cut)")
        print("FLEX-R7D1-FIT card\n" + lines.joined(separator: "\n"))
        XCTAssertFalse(cut.isEmpty, "★ RED CONTROL: the side-by-side card cuts a send or an export at 336")
    }

    // MARK: the plate page (the review of R7-D1)

    /// ★ ROUND 7, the review of R7-D1 (his rules: visual over text, one line per setting, 44 pt targets — the review found
    /// #354's BuildOrientationView in the tray: paragraphs, 40 × 28 pt chips): the Flexible plate page is the mockup's — ONE
    /// question line and six buttons, each at least 44 × 44, in two rows of three. RED at 999c6025: no such page.
    func testThePlatePageIsOneLineAndSixBigButtonsOnTheMiniAndTheThirteen() throws {
        final class F { var frames: [String: CGRect] = [:] }
        let r = try FlexiblePressFixtures.a1Project(3, self)
        var out: [String] = []
        for (name, v) in [("mini", Self.mini), ("13p", Self.pad13)] {
            let w = FlexibleChromeLayout.panelWidth(v)
            let tray = FlexibleSetupTrayState()
            tray.page = .plate
            let f = F()
            let view = FlexibleCornerPairStyle.panel(width: w, maxHeight: 900) {
                FlexibleSetupTray(project: r.project, tray: tray, chrome: FlexibleChromeState(), app: r.app, changeGravity: {},
                                  narrow: FlexibleChromeLayout.panelIsNarrow(w))
            }
            .onPreferenceChange(FlexibleKeepOutKey.self) { f.frames = $0 }
            let got = fits(view, size: CGSize(width: w, height: 500))
            XCTAssertTrue(got.fits.contains { $0.text == FlexiblePlatePage.question }, "★ \(name): the one question line, measured")
            XCTAssertEqual(Self.cut(got.fits), [], "★ \(name) (\(Int(w)) pt): every word on the plate page reads whole")
            let buttons = f.frames.filter { $0.key.hasPrefix("plateAxis-") }
            XCTAssertEqual(buttons.count, 6, "★ \(name): six axis buttons (\(buttons.keys.sorted()))")
            for (k, b) in buttons {
                XCTAssertGreaterThanOrEqual(b.width, 44, "★ \(name): \(k) at least 44 wide (\(b.integral))")
                XCTAssertGreaterThanOrEqual(b.height, 44, "★ \(name): \(k) at least 44 tall (\(b.integral))")
            }
            XCTAssertEqual(Set(buttons.values.map { Int($0.minY.rounded()) }).count, 2, "★ \(name): two rows of three")
            out.append("\(name) \(Int(w)) pt: \(buttons.count) buttons \(buttons.values.map { "\(Int($0.width))x\(Int($0.height))" }.sorted().first ?? "-") … · words whole")
        }
        print("FLEX-R7D1R-FIT plate\n" + out.joined(separator: "\n"))
    }

    // MARK: the button

    func button(_ line: String, tone: FlexibleMainStatus.Tone, state: FlexibleLatticeButton.State, width: CGFloat) -> [FlexibleFit] {
        let v = FlexibleLatticeButtonView(status: .init(line: line, tone: tone, fix: nil), state: state, line: line, width: width,
                                          cardOpen: false, main: {}, caret: {})
        return fits(v, size: CGSize(width: width, height: 64)).fits
    }

    func testTheButtonsLineReadsWholeInEveryStateOnEveryPad() {
        typealias B = FlexibleLatticeButton
        let ran = FlexibleCoreRunReport(refusal: nil, faces: 3, topology: "gyroid", tempC: 230, outDir: "/tmp/x", files: [], seconds: 1)
        let lines: [(String, FlexibleMainStatus.Tone, B.State)] = [
            (FlexibleMainStatus.opening, .building, .opening), ("Fix: the weight on Face 3", .fix, .fix),
            (FlexibleMainStatus.building, .building, .building), (FlexibleMainStatus.deferred, .idle, .viewOff),
            ("Preview \u{00B7} core runs one group at a time", .preview, .preview), (B.readyLine, .ready, .ready),
            (FlexibleCoreRun.sendingLine, .ready, .sending), (B.line(.init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), state: .sent, runLine: ran.line), .ready, .sent),
            (B.refusedLine, .ready, .refused), (B.notSentLine, .ready, .refused), (B.exportsLine, .ready, .exports),
            (FlexibleRowCopy.noFacePrism, .blocked, .blocked), ("Nothing to squish yet", .idle, .idle), (FlexibleMainStatus.notOpened, .idle, .idle),
        ]
        var out: [String] = []
        for (name, v) in [("mini", Self.mini), ("11p", CGSize(width: 834, height: 1194)), ("13p", Self.pad13)] {
            let w = FlexibleChromeLayout.latticeButtonSize(v).width
            for (line, tone, st) in lines {
                let got = button(line, tone: tone, state: st, width: w)
                XCTAssertTrue(got.contains { $0.text == line }, "\(name): '\(line)' measured")
                XCTAssertEqual(Self.cut(got), [], "★ \(name) (\(Int(w)) pt): '\(line)' reads whole")
            }
            out.append("\(name) \(Int(w)) pt: \(lines.count) lines whole")
        }
        // RED CONTROL: the first drawing's main zone on the mini (a 240 split less its 52 pt ⌃ = 187; the same zone is a 232
        // split less today's 44) cuts the Preview line
        let redWidth = 240 - 52 + FlexibleChromeLayout.latticeCaretWidth
        let red = button("Preview \u{00B7} core runs one group at a time", tone: .preview, state: .preview, width: redWidth)
        out.append("RED (the first drawing's main zone, a \(Int(redWidth)) split): cut \(Self.cut(red))")
        print("FLEX-R7D1-FIT button\n" + out.joined(separator: "\n"))
        XCTAssertFalse(Self.cut(red).isEmpty, "★ RED CONTROL: the first drawing's main zone cuts the Preview line")
    }
}
#endif
