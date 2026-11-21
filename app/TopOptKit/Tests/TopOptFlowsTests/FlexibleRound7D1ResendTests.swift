// FlexibleRound7D1ResendTests — round 7, the REVIEW of batch R7-D1 (2026-10-17): the Lattice button must be able to send
// again. D1 counted core's last answer as current whenever it was for the lattice on screen (its generation) — never asking
// whether it answered the JOB on screen. With H31 the full-screen step is gone from this stage, so:
//   (1) core couldn't run it (it threw): the button said "Core couldn't run it", its main zone only opened the card, and the
//       card offered nothing to send — today's pill re-sent on Ready (FlexibleCoreRun.send re-runs anything but a .ran of
//       the same job);
//   (2) a "Not sent" (a stamp not on its face yet) that cleared with no rebuild stayed "Not sent";
//   (3) a job that changed while the lattice did not kept "Core designed it …" for the OLD job, and nothing could send.
// Now: an answer is current only when it answers the job on screen (FlexibleMainStage.answerIsCurrent compares the job core
// was sent — memoised by what the job reads); a failed run offers "Send again" in the card. Core's runner is a stand-in.
// RED at 999c6025: (1) no "Send again"; (2) and (3) stayed Refused / Sent and the main zone only opened the card.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound7D1ResendTests: XCTestCase {

    final class Flag: @unchecked Sendable { var fail = true }
    final class Box { var said: [String] = [] }

    func texts<V: View>(_ v: V, size: CGSize = CGSize(width: 420, height: 900)) -> [String] {
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

    /// The pad with its top pressed (10 kg) and its face-prism (ruling 4), the lattice built — Ready.
    func readyPad() async throws -> (FlexibleMainStage, FlexibleStageModel, Flag) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"), facePrism: true)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        await m.waitForIdle()
        let top = FlexibleHisProject.topFace(try XCTUnwrap(pm.viewerMesh))
        XCTAssertTrue(m.press(top, kg: 10))
        _ = try await FlexibleSquishFixture.build(m, "the pad")
        // (the visible stage may start its own build on the press: wait until the lattice on screen is the settled one)
        try await FlexibleHisProject.waitFor(240, "the pad's lattice settled") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        await m.waitForIdle()
        stage.refresh()
        let flag = Flag()
        stage.coreRun.runner = { _, _, _, _ in
            if flag.fail { throw NSError(domain: "bridge", code: 7, userInfo: [NSLocalizedDescriptionKey: "the bridge threw"]) }
            return FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: [])
        }
        return (stage, m, flag)
    }

    func state(_ stage: FlexibleMainStage, _ m: FlexibleStageModel) -> FlexibleLatticeButton.State {
        FlexibleLatticeButton.state(stage.cornerStatus(m), phase: stage.coreRun.phase, answerIsCurrent: stage.answerIsCurrent(m))
    }

    func mainZone(_ stage: FlexibleMainStage, _ m: FlexibleStageModel) {
        FlexibleLatticeButton.perform(FlexibleLatticeButton.action(state(stage, m)), chrome: stage.chrome, hooks: stage.cornerHooks(openSquish: {}))
    }

    func testAFailedRunOffersSendAgainAndAChangedJobIsReadyAgain() async throws {
        let (stage, m, flag) = try await readyPad()
        let run = stage.coreRun
        XCTAssertEqual(stage.cornerStatus(m).tone, .ready, "premise: \(stage.cornerStatus(m).line)")
        XCTAssertEqual(state(stage, m), .ready)
        var lines: [String] = []
        // ★ the review (minor, cheap): Ready says WHAT goes to core above [Send to core] — the mockup's "Group 1 · 22 lb ·
        // 1 face · bead 0.45 mm" (RED at D1: nothing)
        let summary = FlexibleLatticeCard.jobSummary(model: m)
        XCTAssertNotNil(summary, "★ Ready names the job")
        if let summary {
            XCTAssertTrue(summary.hasPrefix("Group 1 \u{00B7} 10 kg \u{00B7} 1 face \u{00B7} bead "), "the job: '\(summary)'")
            XCTAssertLessThanOrEqual(summary.count, 44, "one line")
            let readyCard = texts(FlexibleLatticeCardView(run: run, status: stage.cornerStatus(m), state: .ready, preview: "built",
                                                          width: 420, maxHeight: 900, summary: summary))
            XCTAssertTrue(readyCard.contains(summary) && readyCard.contains("Send to core"), "the summary over [Send to core]")
        }

        // (1) core couldn't run it
        mainZone(stage, m)
        try await FlexibleHisProject.waitFor(30, "core's (stand-in's) answer") { !run.isSending }
        XCTAssertEqual(run.runs, 1, "Ready sent once")
        guard case .failed = run.phase else { return XCTFail("premise: core threw — \(run.phase)") }
        XCTAssertEqual(state(stage, m), .refused, "the failed answer is for the job on screen: said on the button")
        let card = texts(FlexibleLatticeCardView(run: run, status: stage.cornerStatus(m), state: state(stage, m), preview: "built",
                                                 width: 420, maxHeight: 900, sendAgain: { stage.resendFromCard() }))
        XCTAssertTrue(card.contains("Core couldn\u{2019}t run it"), "core's line in the card")
        XCTAssertTrue(card.contains(FlexibleLatticeCard.sendAgainTitle), "★ (1) the card offers \"\(FlexibleLatticeCard.sendAgainTitle)\" (RED at D1: nothing to send)")
        flag.fail = false
        stage.resendFromCard()
        try await FlexibleHisProject.waitFor(30, "the second answer") { !run.isSending }
        XCTAssertEqual(run.runs, 2, "★ Send again re-sends the same job")
        guard case .ran = run.phase else { return XCTFail("core designed it the second time — \(run.phase)") }
        XCTAssertEqual(state(stage, m), .sent, "★ an answer for the job on screen: Sent (no false 'Ready')")
        lines.append("(1) failed → Send again → runs \(run.runs), \(state(stage, m))")

        // a display-only edit (the weight unit) leaves the job — and the answer — as they were
        m.edit { $0.weightUnit = FlexibleWeightUnit.lb.rawValue }
        stage.refresh()
        XCTAssertEqual(state(stage, m), .sent, "★ a unit is not the job: still Sent")
        mainZone(stage, m)
        XCTAssertEqual(run.runs, 2, "… and the main zone only opens the card")

        // (3) the job core answered is not the job on screen any more (the lattice unchanged)
        let gen = try XCTUnwrap(m.lattice?.generation)
        run.setForTests(phase: run.phase, hold: nil, sentJob: "{\"an\":\"older job\"}")
        XCTAssertEqual(run.sentFor, gen, "premise: the answer is for the lattice on screen")
        XCTAssertEqual(state(stage, m), .ready, "★ (3) the job changed: Ready again (RED at D1: 'Sent' for the old job)")
        mainZone(stage, m)
        try await FlexibleHisProject.waitFor(30, "the third answer") { !run.isSending }
        XCTAssertEqual(run.runs, 3, "★ … and the main zone sends it, once")
        XCTAssertEqual(state(stage, m), .sent)
        mainZone(stage, m)
        XCTAssertEqual(run.runs, 3, "an unchanged job never re-sends")
        lines.append("(3) job changed at generation \(gen) → Ready → runs \(run.runs)")

        // (2) a "Not sent" that cleared with no rebuild
        run.setForTests(phase: .notSent(line: FlexibleCoreRun.notSentLine(.missingStampGrid(UUID())), why: "w"), hold: nil, sentJob: nil)
        run.sentFor = gen
        XCTAssertEqual(state(stage, m), .ready, "★ (2) what kept it from core is gone: Ready (RED at D1: 'Not sent' stayed)")
        lines.append("(2) a cleared Not sent → Ready")
        print("FLEX-R7D1R-RESEND\n" + lines.joined(separator: "\n"))
    }
}
#endif
