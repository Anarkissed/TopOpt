// FlexibleCornerPairTests — round 7, batch R7-D1: A1's CORNER PAIR on the main Lattice page (his pick 1: "I like A2 but
// with the corner pair from A1 on the main Lattice screen (see image 1)"), with his answers: "Optimize on the Flexible
// stage: DROP both the muted Optimize row and the iPad/Mac compute chip; the Lattice card holds only Preview → Core →
// Export", his img1 words ("Remove the 'Protect 3mm' chip … Is there any need for 'Minimize Plastic' for this process at
// all?") and his CAD-surfaces answer ("leave it OFF the Flexible stage").
//
//   Setup     the chip "▦ Fast · ↑ +Z · ↓ −Z ⌃" (live) and its tray: Quality, Plate up, Gravity, Print parameters — nothing
//             else (RED: today's column on his pad, img1's five chips, Protect and Minimize plastic among them)
//   the split "Lattice" over one status line; the main zone does the next step, ⌃ opens the card and never sends
//             (RED: today's pill — Preview opened the full-screen Export step; Ready could not be looked at without sending)
//   the card  ① Preview ② Core ③ Export, nothing else (RED: a card with an Optimize row)
//   callout   a blocker pops at once above the pair, once per issue (RED: a callout keyed on every recompute pops twice)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleCornerPairTests: XCTestCase {

    func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Pad 100 x 100 x 20 (Flexible)", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        return p
    }

    // MARK: - Setup

    func testTheSetupChipReadsQualityPlateAndGravityLive() {
        let p = project()
        XCTAssertEqual(FlexibleSetupChip.label(project: p), "Fast \u{00B7} +Z \u{00B7} \u{2212}Z", "his pad: Fast · +Z · −Z")
        p.quality = .balanced
        XCTAssertEqual(FlexibleSetupChip.parts(project: p).quality, "Balanced", "the quality follows")
        p.force.setGravity(direction: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(FlexibleSetupChip.parts(project: p).gravity, "+X", "gravity follows")
        let none = ProjectModel(id: UUID(), name: "N", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        XCTAssertEqual(FlexibleSetupChip.parts(project: none).gravity, "not set", "no gravity: 'not set'")
        XCTAssertLessThanOrEqual(FlexibleSetupChip.label(project: p).count, 44, "one line")
    }

    func testTheTrayIsQualityPlateUpGravityAndPrintParametersOnly() {
        XCTAssertEqual(FlexibleSetupRow.allCases, [.quality, .plateUp, .gravity, .printParameters], "exactly four rows")
        XCTAssertEqual(FlexibleSetupRow.allCases.map(\.title), ["Quality", "Plate up", "Gravity", "Print parameters"])
        let gone: Set<SettingsChipID> = [.faceProtectDepth, .minimizePlastic, .cadFaces, .designBox, .paint, .bandChips]
        XCTAssertTrue(Set(FlexibleSetupRow.allCases.compactMap(\.chip)).isDisjoint(with: gone),
                      "★ no Protect N mm, Minimize plastic, CAD surfaces (his answers) — nor the compute chip")
        // RED CONTROL: today's chip column on the Flexible stage of his pad (img1: Fast · 64³, Protect 3 mm, Minimize
        // plastic, Plate up +Z, Gravity set), which H24 stops drawing there
        let todays: [SettingsChipID] = [.quality, .faceProtectDepth, .minimizePlastic, .buildOrientation, .gravity]
        XCTAssertEqual(todays.count, 5)
        XCTAssertFalse(Set(todays).isDisjoint(with: gone), "★ RED CONTROL: today's column carries Protect and Minimize plastic")
        XCTAssertTrue(Set(SettingsChipID.allCases).isSuperset(of: gone), "(the ids are #354's, untouched)")
    }

    func testTheTraysRowsDoOneThingEach() {
        let p = project()
        let app = AppModel(materialsPath: nil)
        let chrome = FlexibleChromeState()
        let tray = FlexibleSetupTrayState()
        var gravity = 0
        chrome.show(.setup)
        FlexibleSetupActions.changeGravity(chrome: chrome, tray: tray, changeGravity: { gravity += 1 })
        XCTAssertEqual(gravity, 1, "Gravity [Change] → H30's closure, once")
        XCTAssertNil(chrome.open, "… and the tray folds (gravity setup folds every card)")
        chrome.show(.setup)
        FlexibleSetupActions.printParameters(app: app, chrome: chrome)
        XCTAssertTrue(app.printParamsSheetPresented, "Print parameters → today's sheet")
        XCTAssertNil(chrome.open)
        XCTAssertEqual(tray.page, .rows)
        FlexibleSetupActions.plateUp(tray: tray)
        XCTAssertEqual(tray.page, .plate, "Plate up [Change] → BuildOrientationView in the tray")
        FlexibleSetupActions.back(tray: tray)
        XCTAssertEqual(tray.page, .rows, "‹ goes back to the rows")
        FlexibleSetupActions.quality(.fine, project: p)
        XCTAssertEqual(p.quality, .fine, "Quality writes project.quality")
    }

    // MARK: - the split button

    static let weightIssue = FlexibleStageCapsuleTests.weightIssue

    /// The table: state → (line, action).
    func testTheSplitButtonsTable() {
        typealias B = FlexibleLatticeButton
        let ran = FlexibleCoreRunReport(refusal: nil, faces: 3, topology: "gyroid", tempC: 230, outDir: "/tmp/x", files: [], seconds: 1)
        let refused = FlexibleCoreRunReport(refusal: FlexRefusal(code: "calibrate_first", reason: "No data."), faces: 0, topology: nil, tempC: nil, outDir: "/tmp/x", files: [], seconds: 1)
        let rows: [(String, FlexibleMainStatus, FlexibleCoreRun.Phase, Bool, B.State, String, B.MainAction)] = [
            ("opening", .init(line: FlexibleMainStatus.opening, tone: .building, fix: nil), .idle, false, .opening, "Opening the part\u{2026}", .note(.opening)),
            ("fix", .init(line: "Fix: the weight on Face 1", tone: .fix, fix: Self.weightIssue), .idle, false, .fix, "Fix: the weight on Face 1", .callout),
            ("building", .init(line: FlexibleMainStatus.building, tone: .building, fix: nil), .idle, false, .building, "Building\u{2026}", .note(.building)),
            ("view off", .init(line: FlexibleMainStatus.deferred, tone: .idle, fix: nil), .idle, false, .viewOff, "View off \u{00B7} tap to build", .showLattice),
            ("preview", .init(line: "Preview \u{00B7} core runs one group at a time", tone: .preview, fix: nil), .idle, false, .preview, "Preview \u{00B7} core runs one group at a time", .card),
            ("ready", .init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), .idle, false, .ready, "Ready \u{00B7} tap to send", .sendAndCard),
            ("sending", .init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), .sending, false, .sending, "Sending to core\u{2026}", .card),
            ("sent", .init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), .ran(ran), true, .sent, ran.line, .card),
            ("refused", .init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), .ran(refused), true, .refused, refused.line, .card),
            ("no prism", .init(line: FlexibleRowCopy.noFacePrism, tone: .blocked, fix: nil), .idle, false, .blocked, FlexibleRowCopy.noFacePrism, .none),
            ("nothing to squish", .init(line: "Nothing to squish yet", tone: .idle, fix: nil), .idle, false, .idle, "Nothing to squish yet", .openSquish),
        ]
        for (name, s, phase, current, st, line, act) in rows {
            let got = B.state(s, phase: phase, answerIsCurrent: current)
            XCTAssertEqual(got, st, name)
            XCTAssertEqual(B.line(s, state: got, runLine: FlexibleCoreRun.line(phase)), line, name)
            XCTAssertEqual(B.action(got), act, name)
            XCTAssertEqual(B.title, "Lattice", "\(name): the title never changes")
            XCTAssertLessThanOrEqual(line.count, 44, "\(name): one line")
        }
        // an answer for an older lattice is not "sent": the button is Ready again
        XCTAssertEqual(B.state(.init(line: FlexibleMainStatus.ready, tone: .ready, fix: nil), phase: .ran(ran), answerIsCurrent: false), .ready)
        XCTAssertEqual(B.action(.exports), .card, "Exports: the card")
    }

    /// The main zone and the ⌃, on a stage with a stand-in core: Ready sends ONCE and opens the card on ②; Preview opens the
    /// card and sends nothing; ⌃ never sends.
    func testReadySendsOncePreviewAndTheCaretNeverSend() {
        let main = FlexibleMainStage()
        var sends = 0, callouts = 0, squish = 0, shown = 0
        let hooks = FlexibleLatticeButton.Hooks(send: { sends += 1 }, showCard: { shown += 1 }, showLattice: {}, note: { _ in },
                                                openSquish: { squish += 1 }, callout: { callouts += 1 })
        FlexibleLatticeButton.perform(.sendAndCard, chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(sends, 1, "Ready: sendToCore exactly once")
        XCTAssertEqual(main.chrome.open, .latticeCard, "… and the card opens on ②")
        main.chrome.foldAll()
        FlexibleLatticeButton.perform(.card, chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(sends, 1, "Preview: nothing is sent")
        XCTAssertEqual(main.chrome.open, .latticeCard)
        XCTAssertEqual(shown, 2, "the card shows the hold's sends (looked at, never sent)")
        FlexibleLatticeButton.caret(chrome: main.chrome, hooks: hooks)
        XCTAssertNil(main.chrome.open, "⌃ toggles the card closed")
        FlexibleLatticeButton.caret(chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(main.chrome.open, .latticeCard, "⌃ toggles it open")
        XCTAssertEqual(sends, 1, "★ ⌃ never sends")
        FlexibleLatticeButton.perform(.callout, chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(main.chrome.open, .callout, "Fix: the callout")
        main.chrome.close(.callout)
        FlexibleLatticeButton.perform(.callout, chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(main.chrome.open, .callout, "… and again after he dismissed it")
        FlexibleLatticeButton.perform(.openSquish, chrome: main.chrome, hooks: hooks)
        XCTAssertEqual(squish, 1)
        XCTAssertNil(main.chrome.open, "the Squish page opening folds the cards")
    }

    /// The same through the stage's own core run, with a stand-in runner: the ⌃ (show) never changes sentJob.
    func testShowLooksWithoutSending() {
        let run = FlexibleCoreRun()
        XCTAssertNil(run.sentJob)
        run.setForTests(phase: .idle, hold: nil, sentJob: "job-A")
        let before = run.sentJob
        run.showHold(FlexibleCoreHold(kind: .squeezeGroups, line: FlexibleCoreRun.notSentLine(.squeezeGroups), why: "w",
                                      fixes: [.send(resting: [3], title: "Send Group 1 only", scope: "Group 1 only")]))
        XCTAssertEqual(run.sentJob, before, "★ looking never changes what was sent")
        XCTAssertEqual(run.phase, .idle, "… nor core's answer")
        XCTAssertEqual(run.hold?.fixes.count, 1, "the card has the hold's sends")
        XCTAssertFalse(run.shown, "the full-screen step never opens on the Flexible stage")
        XCTAssertEqual(run.runs, 0)
    }

    /// RED CONTROL: today's pill — its Preview tap opened the full-screen Export step (shown), and on Ready there was no way
    /// to see the steps without sending.
    func testTodaysPillIsTheRedControl() {
        let s = FlexibleMainStatus(line: "Preview \u{00B7} core runs one group at a time", tone: .preview, fix: nil)
        XCTAssertEqual(s.tap, .send, "★ RED CONTROL: today's Preview tap sends (opening the full-screen step on 'Not sent')")
        XCTAssertEqual(FlexibleMainStatus(line: "Ready", tone: .ready, fix: nil).tap, .send, "★ … and Ready can only send")
        XCTAssertEqual(FlexibleLatticeButton.action(.preview), .card, "the split: Preview only looks")
    }

    // MARK: - the card

    func testTheCardIsPreviewCoreExportOnly() {
        let run = FlexibleCoreRun()
        let ready = FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil)
        let steps = FlexibleLatticeCard.steps(state: .ready, status: ready, run: run, preview: "built \u{00B7} 2 face-prisms \u{00B7} 25.0 mm")
        XCTAssertEqual(steps.map(\.id), ["preview", "core", "export"], "exactly three steps")
        XCTAssertEqual(steps.map(\.title), ["Preview", "Core", "Export"])
        XCTAssertEqual(steps.map(\.marker), [.done, .current, .future])
        // preview: the hold's sends ARE the Core rows
        let hold = FlexibleCoreHold(kind: .squeezeGroups, line: FlexibleCoreRun.notSentLine(.squeezeGroups), why: "w",
                                    fixes: [.send(resting: [3], title: "Send Group 1 only", scope: "Group 1 only"),
                                            .send(resting: [1], title: "Send Group 2 only", scope: "Group 2 only")])
        run.showHold(hold)
        let pv = FlexibleMainStatus(line: "Preview \u{00B7} core runs one group at a time", tone: .preview, fix: nil)
        XCTAssertEqual(FlexibleLatticeCard.coreSends(state: .preview, status: pv, run: run), hold.fixes, "the Core rows = FlexibleCoreHold.sends")
        XCTAssertTrue(FlexibleLatticeCard.exportsDisabled(run: run), "exports wait until core returns a mesh (it returns none yet)")
        let fix = FlexibleLatticeCard.steps(state: .fix, status: .init(line: "Fix: the weight on Face 1", tone: .fix, fix: Self.weightIssue), run: run, preview: "x")
        XCTAssertEqual(fix[1].marker, .blocked)
        XCTAssertEqual(fix[1].line, Self.weightIssue.oneLine, "the issue is the card's Core row while it is open")
        let blocked = FlexibleLatticeCard.steps(state: .blocked, status: .init(line: FlexibleRowCopy.noFacePrism, tone: .blocked, fix: nil), run: run, preview: "x")
        XCTAssertEqual(blocked[1].line, FlexibleRowCopy.noFacePrism, "★ ruling 4: Export disabled with the stated reason")
        XCTAssertEqual(blocked[1].marker, .blocked)
    }

    /// The full-screen step's strings now live ONCE, in FlexibleExportRows (the sheet and the card both draw them).
    func testTheExportStringsLiveOnceInTheSharedRows() throws {
        let rows = try FlexibleSource.code("FlexibleExportRows.swift")
        let sheet = try FlexibleSource.code("FlexibleExportSheet.swift")
        for s in ["\"Export STL\"", "\"Export G-code\"", "FlexibleCoreRun.exportsWait", "\"flexible-export-core-line\"",
                  "\"flexible-export-hold-note\"", "\"flexible-export-wait\"", "run.hold?.note", "run.onFix?(f)"] {
            XCTAssertEqual(rows.components(separatedBy: s).count - 1, 1, "\(s) once in FlexibleExportRows")
            XCTAssertFalse(sheet.contains(s), "\(s) is no longer copied in the sheet")
        }
        XCTAssertTrue(sheet.contains("FlexibleExportRows"), "the sheet draws the shared rows")
        let card = try FlexibleSource.code("FlexibleLatticeCard.swift")
        XCTAssertTrue(card.contains("FlexibleExportRows"), "the card draws the same rows")
        XCTAssertFalse(card.lowercased().contains("optimize"), "★ no Optimize in the card")
        XCTAssertFalse(card.contains("ComputeLocation"), "★ no compute chip in the card")
    }

    // MARK: - the callout

    func testTheCalloutPopsOncePerNewIssueAndNeverForAnAdvisory() {
        var rule = FlexibleCalloutRule()
        let fix = FlexibleMainStatus(line: "Fix: the weight on Face 1", tone: .fix, fix: Self.weightIssue)
        XCTAssertEqual(rule.next(fix), Self.weightIssue, "a blocker pops at once")
        XCTAssertNil(rule.next(fix), "the same issue recomputed: no second pop")
        XCTAssertNil(rule.next(fix), "… dismissed, it never pops again by itself")
        let advisory = FlexibleMainStatus(line: "No lattice under Face 3", tone: .preview,
                                          fix: FlexibleIssue(id: "noLatticeUnder-3", kind: .noLatticeUnder, region: 3, oneLine: "No lattice under Face 3",
                                                             blocking: false, fixes: [.latticeUnder(3)]))
        XCTAssertNil(rule.next(advisory), "★ an advisory never pops (it stays on the button's line)")
        let other = FlexibleIssue(id: "noFilament", kind: .noFilament, region: nil, oneLine: "Pick a filament", blocking: true, fixes: [])
        XCTAssertEqual(rule.next(.init(line: "Fix: pick a filament", tone: .fix, fix: other)), other, "a NEW issue pops")
        // RED CONTROL: a callout keyed on every readiness recompute pops twice for one issue
        var control = FlexibleCalloutRule()
        control.controlEveryRecompute = true
        XCTAssertNotNil(control.next(fix))
        XCTAssertNotNil(control.next(fix), "★ RED CONTROL: keyed on every recompute, one issue pops twice")
    }

    func testTheCalloutsButtonsApplyFixesOrSendHimToSquish() {
        // the weight lives on the Squish page: one button, "Fix in Squish ›"; a rest applies at once
        let b = FlexibleBlockerCallout.buttons(Self.weightIssue, pressNeedsWeight: { _ in false })
        XCTAssertEqual(b, [.squish, .apply(.rest(1))])
        XCTAssertEqual(FlexibleBlockerCallout.squishTitle, "Fix in Squish \u{203A}")
        var openFix = 0, squish = 0
        FlexibleBlockerCallout.goToSquish(openFix: { openFix += 1 }, openSquish: { squish += 1 })
        XCTAssertEqual([openFix, squish], [1, 1], "a fix that lives on the Squish page: openFix + openSquish")
        // at most three buttons; a press that needs a weight is the Squish page's too, said once
        let many = FlexibleIssue(id: "x", kind: .noPressedFace, region: 1, oneLine: "Press a face", blocking: true,
                                 fixes: [.press(1), .press(2), .rest(3), .remove(4)])
        let mb = FlexibleBlockerCallout.buttons(many, pressNeedsWeight: { _ in true })
        XCTAssertEqual(mb, [.squish, .apply(.rest(3)), .apply(.remove(4))])
        XCTAssertLessThanOrEqual(mb.count, 3)
    }
}
