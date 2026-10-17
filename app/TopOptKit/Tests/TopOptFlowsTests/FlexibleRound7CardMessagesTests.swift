// FlexibleRound7CardMessagesTests — round 7, batch R7-D1, the reviewer's condition (a) on H31 (2026-10-14 19:45):
// "EVERY warning, refusal and answer from core that the full-screen step shows today must appear in the corner card —
// nothing dropped, incl. the no-prism refusal (step 2), the edges-beside-faces notice, the drawer's background
// confirmation, the Save & Exit sealed-pocket check. Add a test that LISTS the full-screen step's messages and asserts each
// reaches the corner card."
//
// THE LIST below is every message FlexibleExportSheet (the full-screen Export step, which H31 stops mounting on the
// Flexible stage) can show: its title, core's one line in each phase (sending, designed, refused, every "Not sent" the
// encoder and the holds give, core couldn't run it), the (i) with core's whole sentence, the hold's second line (the
// edges-beside-faces notice), the hold's 1–3 sends, the exports' wait and the two disabled exports. Each scenario hosts the
// SHEET and the CARD over the same core run and asserts (1) the sheet shows the listed messages — so the list is the
// sheet's — and (2) the card shows every one of them (each row publishes the words it draws: FlexibleSaidKey).
//
// NOT IN THE LIST, and why (said to the reviewer): the Flexible full-screen step has no "drawer's background confirmation"
// and no "Save & Exit sealed-pocket check" — neither string nor check exists in FlexibleExportSheet or any file it reads
// (grep). Those belong to #354's lattice run (RunScreen / RelatticeRunner), which the Flexible stage never mounts, and
// H31 does not touch it. Save & Exit's own check (FlexibleSettingsExit.decide) is the Squish page's, unchanged, and every
// way off the Squish page through the capsule runs it first (FlexibleStageCapsuleTests).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7CardMessagesTests: XCTestCase {

    struct Scenario {
        let name: String
        let phase: FlexibleCoreRun.Phase
        let hold: FlexibleCoreHold?
        let status: FlexibleMainStatus
        /// What the full-screen step shows (texts and ids), listed.
        let messages: [String]
    }

    static let report = FlexibleCoreRunReport(refusal: nil, faces: 3, topology: "gyroid", tempC: 230, outDir: "/tmp/x", files: ["a", "b"], seconds: 1)
    static let refusal = FlexibleCoreRunReport(refusal: FlexRefusal(code: "calibrate_first", reason: "No squish data for TPU 95A."), faces: 0,
                                               topology: nil, tempC: nil, outDir: "/tmp/x", files: [], seconds: 1)
    static let groupsHold = FlexibleCoreHold(kind: .squeezeGroups, line: FlexibleCoreRun.notSentLine(.squeezeGroups), why: "Core designs one squeeze group per job.",
                                             fixes: [.send(resting: [3], title: "Send Group 1 only", scope: "Group 1 only"),
                                                     .send(resting: [1], title: "Send Group 2 only", scope: "Group 2 only")])
    static let edgesHold = FlexibleCoreHold(kind: .edgesBeside, line: FlexibleRowCopy.exportMakesOnly("Group 2"), why: "Core designs one squeeze group per job.",
                                            fixes: [.send(resting: [], title: "Send Group 2 only", scope: "Group 2 only")],
                                            note: FlexibleRowCopy.edgesExportSeparately)
    static let shapeHold = FlexibleCoreHold(kind: .shapeOnly, line: "Not sent: TPU 95A has no squish data yet", why: "No data (calibrate_first)",
                                            fixes: [.useFilament(id: "vs", name: "varioShore TPU")])
    static let ready = FlexibleMainStatus(line: FlexibleMainStatus.ready, tone: .ready, fix: nil)
    static func preview(_ h: FlexibleCoreHold) -> FlexibleMainStatus {
        FlexibleMainStatus(line: FlexibleCoreHold.pill(h.kind, shapeOnlyLabel: nil), tone: .preview, fix: nil)
    }
    /// What every scenario's step shows under core's line (the exports and their wait).
    static let exports = ["Export", FlexibleCoreRun.exportsWait, "Export STL", "Export G-code"]

    static var scenarios: [Scenario] {
        var s: [Scenario] = [
            Scenario(name: "sending", phase: .sending, hold: nil, status: ready, messages: [FlexibleCoreRun.sendingLine] + exports),
            Scenario(name: "core designed it", phase: .ran(report), hold: nil, status: ready,
                     messages: [report.line, "#flexible-export-core-info"] + exports),
            Scenario(name: "core refused it", phase: .ran(refusal), hold: nil, status: ready,
                     messages: ["Core refused it: no squish data for this filament yet", "#flexible-export-core-info"] + exports),
            Scenario(name: "squeeze groups (hold)", phase: .notSent(line: groupsHold.line, why: groupsHold.why), hold: groupsHold, status: preview(groupsHold),
                     messages: [groupsHold.line, "#flexible-export-core-info", "Send Group 1 only", "Send Group 2 only"] + exports),
            Scenario(name: "edges beside faces (hold, the notice)", phase: .notSent(line: edgesHold.line, why: edgesHold.why), hold: edgesHold,
                     status: preview(edgesHold),
                     messages: ["This export makes Group 2 only.", "Edges and faces go in separate exports for now.", "#flexible-export-core-info",
                                "Send Group 2 only"] + exports),
            Scenario(name: "shape only (hold)", phase: .notSent(line: shapeHold.line, why: shapeHold.why), hold: shapeHold, status: preview(shapeHold),
                     messages: [shapeHold.line, "#flexible-export-core-info", "Use varioShore TPU"] + exports),
            Scenario(name: "no face-prism (ruling 4, step 2)", phase: .notSent(line: FlexibleCoreRun.notSentLine(.noFacePrism), why: FlexibleJob.EncodeError.noFacePrism.description),
                     hold: nil, status: FlexibleMainStatus(line: FlexibleRowCopy.noFacePrism, tone: .blocked, fix: nil),
                     messages: [FlexibleRowCopy.noFacePrism, "#flexible-export-core-info"] + exports),
            Scenario(name: "core couldn't run it", phase: .failed("bridge threw"), hold: nil, status: ready,
                     messages: ["Core couldn\u{2019}t run it", "#flexible-export-core-info"] + exports),
        ]
        for e: FlexibleJob.EncodeError in [.noFilament, .noLoadedFace, .noPart, .missingStampGrid(UUID()), .squeezeGroups, .pinch] {
            s.append(Scenario(name: "not sent: \(e)", phase: .notSent(line: FlexibleCoreRun.notSentLine(e), why: e.description), hold: nil, status: ready,
                              messages: [FlexibleCoreRun.notSentLine(e), "#flexible-export-core-info"] + exports))
        }
        return s
    }

    // MARK: hosting

    final class Box { var said: [String] = [] }

    /// What a view DRAWS in words: every message row publishes its text (FlexibleSaidKey, recorded in tests only — a test
    /// process builds no accessibility tree for SwiftUI on macOS, so the rows say it themselves).
    func texts<V: View>(_ v: V, size: CGSize) -> [String] {
        FlexibleSaid.recording = true
        defer { FlexibleSaid.recording = false }
        let box = Box()
        let hv = NSHostingView(rootView: v.onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }.environment(\.colorScheme, .dark))
        hv.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        w.contentView = nil
        return box.said
    }

    func testEveryMessageOfTheFullScreenStepReachesTheCornerCard() {
        var lines: [String] = []
        defer { FlexibleLatticeCard.controlDropsHoldNote = false }
        for sc in Self.scenarios {
            let run = FlexibleCoreRun()
            run.setForTests(phase: sc.phase, hold: sc.hold, sentJob: nil)
            let sheet = texts(FlexibleExportSheet(run: run, onClose: {}), size: CGSize(width: 1032, height: 1376))
            let state = FlexibleLatticeButton.state(sc.status, phase: sc.phase, answerIsCurrent: true)
            let card = texts(FlexibleLatticeCardView(run: run, status: sc.status, state: state, preview: "built \u{00B7} 1 face-prism \u{00B7} 20.0 mm",
                                                     width: 420, maxHeight: 900),
                             size: CGSize(width: 420, height: 900))
            for m in sc.messages {
                XCTAssertTrue(sheet.contains(m), "\(sc.name): the list is the sheet's — '\(m)' is on the full-screen step")
                XCTAssertTrue(card.contains(m), "★ \(sc.name): '\(m)' reaches the corner card")
            }
            lines.append("\(sc.name): \(sc.messages.count) messages · sheet has all \(sc.messages.allSatisfy(sheet.contains)) · card has all \(sc.messages.allSatisfy(card.contains))")
        }
        print("FLEX-R7D1-CARD-MESSAGES\n" + lines.joined(separator: "\n"))
        // RED CONTROL: a card that drops the hold's second line (the edges-beside-faces notice) is caught
        FlexibleLatticeCard.controlDropsHoldNote = true
        let sc = Self.scenarios.first { $0.name.hasPrefix("edges beside") }!
        let run = FlexibleCoreRun()
        run.setForTests(phase: sc.phase, hold: sc.hold, sentJob: nil)
        let card = texts(FlexibleLatticeCardView(run: run, status: sc.status, state: .refused, preview: "x", width: 420, maxHeight: 900),
                         size: CGSize(width: 420, height: 900))
        XCTAssertFalse(card.contains(FlexibleRowCopy.edgesExportSeparately), "★ RED CONTROL: without the notice the check goes red")
    }

    /// The (i)'s text is the run's own (`info`), shared by the two: the card draws FlexibleExportRows' core row.
    func testTheInfoBehindTheCardsCoreLineIsCoresWholeSentence() throws {
        let run = FlexibleCoreRun()
        run.setForTests(phase: .ran(Self.refusal), hold: nil, sentJob: nil)
        XCTAssertEqual(run.info, "No squish data for TPU 95A. (calibrate_first)")
        let rows = try FlexibleSource.code("FlexibleExportRows.swift")
        XCTAssertTrue(rows.contains("if let info = run.info {"), "the (i) reads run.info")
        XCTAssertTrue(rows.contains("FlexInfoButton(title: \"Core\", text: info, id: \"flexible-export-core-info\")"))
    }
}
#endif
