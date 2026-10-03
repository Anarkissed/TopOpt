// FlexibleBatchNVerifyTests — batch N's verification findings, each with its RED control computed
// beside it (task 2026-09-29-flexible-screens, round 5 batch N verification). The app is NOT launched.
//   * a cancel (and a solve waiting for core) is heard between SOLVES, not only between increments
//     — RED: batch N's loop (one bridge call per increment) runs the whole increment after it;
//   * while the quick field is still on screen, a refine that lands moves NEITHER the legend's top,
//     NOR the colours on screen, NOR the (i) — they follow the renderer's swap at rest, and the page
//     refreshes on that swap — RED: the newest version read at once; no refresh on the swap;
//   * the refine's line appears the moment the refine claims core, names the group, counts the
//     increment being solved (8/8 while the last runs) — and every line the player can show from the
//     sims sits WHOLE beside the live Play-all picker on every iPad (batch G's two fallbacks were cut as
//     well) — RED: batch N's 40-character line is cut at 11" portrait.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class NVHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleBatchNVerifyTests: XCTestCase {

    /// C1's pad, its top pressed (30 kg) and its bottom resting, through Save & Exit on the page's own
    /// refresh; returns once the QUICK sim landed. `notes`: every line the player showed on the way,
    /// polled every 20 ms ("-" for none).
    func pad(notes: inout [String], _ prepare: (FlexibleStageModel) -> Void = { _ in })
        async throws -> (FlexibleMainStage, FlexibleStageModel, ProjectModel) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        prepare(m)
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        _ = m.press(FlexibleHisProject.topFace(mesh), kg: 30)
        m.rest(FlexibleSquishFixture.bottomFace(mesh))
        _ = try await FlexibleSquishFixture.build(m, "the pad")
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        var seen: [String] = []
        try await FlexibleHisProject.waitFor(300, "the pad's quick sim") {
            stage.refresh()
            let n = stage.simNote ?? "-"
            if seen.last != n { seen.append(n) }
            return !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        notes = seen
        return (stage, m, pm)
    }

    // MARK: - a cancel is heard between SOLVES

    func testACancelIsHeardBetweenSolvesNotOnlyBetweenIncrements() async throws {
        var notes: [String] = []
        let (_, m, _) = try await pad(notes: &notes)
        await m.squishSolver.waitForIdle()   // (the model's own refine cancelled: this one is driven here)
        let req = try XCTUnwrap(m.lastFERequest)
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let sim = try XCTUnwrap(req.sims.first)
        let lin = try XCTUnwrap(m.squish[sim.id]?.field)
        var report: [String] = []
        for perIncrement in [false, true] {
            // three solves an increment, never settling (a tolerance no field meets); the cancel is
            // requested as increment 2 STARTS — after increment 1's three solves
            var requested = false
            var requestedAt = Date()
            var yieldsBeforeRequest = 0
            let before = FlexSquishSteps.liveSessions
            let o = FlexibleFERefine.run(sim, of: req, on: scene, linear: lin, increments: 4, iterations: (each: 3, last: 3),
                                         tolerance: 1e-12, pollPerIncrement: perIncrement,
                                         cancelled: { requested },
                                         between: { if !requested { yieldsBeforeRequest += 1 } },
                                         progress: { step, _ in if step == 2 { requested = true; requestedAt = Date() } })
            let stopS = Date().timeIntervalSince(requestedAt)
            guard case .cancelled(let rc) = o else { XCTFail("cancelled: \(o)"); continue }
            let after = rc.solves - 3
            report.append(String(format: "%@: %d solve(s) after the cancel (%.2f s) · the waiting solve could take core %d time(s) during increment 1 · solves %@",
                                 perIncrement ? "RED control (batch N: per increment)" : "rule (per solve)", after, stopS, yieldsBeforeRequest,
                                 "\(rc.steps.map(\.solves))"))
            XCTAssertEqual(FlexSquishSteps.liveSessions, before, "its session ended")
            if !perIncrement {
                XCTAssertEqual(after, 1, "the cancel is heard after the solve in flight")
                XCTAssertEqual(yieldsBeforeRequest, 3, "a waiting solve gets core between every two solves (2 in increment 1, 1 after it)")
            } else {
                // ★ RED CONTROL: batch N's loop finishes the whole increment (his Group 1's last: 6 solves, 6.5 s)
                XCTAssertEqual(after, 3, "control: the whole increment runs after the cancel")
                XCTAssertEqual(yieldsBeforeRequest, 1, "control: a waiting solve gets core only between increments")
            }
        }
        print("FLEX-NV CANCEL\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - the legend, the colours and the (i) follow the version ON SCREEN

    func testTheLegendTheColoursAndTheInfoFollowTheVersionOnScreen() async throws {
        var report: [String] = []
        for mode in ["rule", "RED control: the newest version", "RED control: no refresh on the swap"] {
            var notes: [String] = []
            let (stage, m, pm) = try await pad(notes: &notes) { $0.squishSolver.controlRefineStepDelayS = 0 }
            stage.controlLegendByNewestVersion = mode == "RED control: the newest version"
            stage.controlNoSwapRefresh = mode == "RED control: no refresh on the swap"
            // the renderer shows the QUICK version (what its swap leaves behind), mid-squeeze
            stage.loop.noteShown(index: 0, key: "group-1", simID: "group-1")
            stage.refresh()
            let top1 = stage.dentMaxMM, info1 = stage.dentInfo, row1 = stage.dentFactorLabel
            let t1 = try XCTUnwrap(stage.tints(pm, on: .lattice, roles: [:], stress: nil))
            // the refine lands while the quick field is still on screen
            await m.waitForRefines()
            guard case .ready(let refined)? = m.refine["group-1"] else { XCTFail("\(mode): refined: \(String(describing: m.refine["group-1"]))"); continue }
            try await Task.sleep(nanoseconds: 500_000_000)   // (the model's debounced publish has refreshed the page: nothing else will)
            stage.refresh()
            let top2 = stage.dentMaxMM, info2 = stage.dentInfo, row2 = stage.dentFactorLabel
            let t2 = try XCTUnwrap(stage.tints(pm, on: .lattice, roles: [:], stress: nil))
            let shown2 = stage.feShownField?.versionKey
            let refinedColours = stage.feTintBox.tints(refined.versionKey)
            let d12 = zip(t1, t2).map { abs($0 - $1) }.max() ?? 0
            // the renderer swaps the refined version in at rest (its colours, made on the scale they play on)
            stage.loop.noteShown(index: 0, key: refined.versionKey, simID: "group-1")
            try await Task.sleep(nanoseconds: 300_000_000)   // (the page's refresh is the next runloop turn)
            let top3 = stage.dentMaxMM, info3 = stage.dentInfo
            let t3 = try XCTUnwrap(stage.tints(pm, on: .lattice, roles: [:], stress: nil))
            let d23 = refinedColours.map { rc in zip(rc, t3).map { abs($0 - $1) }.max() ?? 0 }
            report.append(String(format: "%@: legend top %.3f → (landed, quick on screen %@) %.3f → (swapped) %.3f mm · row %@ → %@ · colours on screen changed by %.4f at the landing · the swap's colours vs the page's after it %@ · (i) at the landing stepped %@, after the swap stepped %@",
                                 mode, top1, shown2 ?? "-", top2, top3, row1, row2, d12, d23.map { String(format: "%.4f", $0) } ?? "-",
                                 "\(info2.contains("solved in steps"))", "\(info3.contains("solved in steps"))"))
            switch mode {
            case "rule":
                XCTAssertEqual(shown2, "group-1", "the quick version is still on screen")
                XCTAssertEqual(top2, top1, "the legend's top does not move while the quick field plays")
                XCTAssertEqual(info2, info1, "nor the (i)")
                XCTAssertEqual(row2, row1, "nor the dent row")
                XCTAssertLessThanOrEqual(d12, 1e-6, "nor the colours on screen")
                XCTAssertNotEqual(top3, top1, "after the swap the legend reads the refined field")
                XCTAssertTrue(info3.contains("solved in steps"), "…and the (i) says it")
                XCTAssertLessThanOrEqual(try XCTUnwrap(d23), 1e-6, "the swap at rest is the colours' only change")
            case "RED control: the newest version":
                XCTAssertNotEqual(top2, top1, "control: the legend's top moves at the landing, mid-squeeze")
                XCTAssertTrue(info2.contains("solved in steps"), "control: the (i) says 'stepped' while the quick field plays")
                XCTAssertGreaterThan(d12, 1e-6, "control: the quick field's colours change mid-squeeze")
            default:
                XCTAssertFalse(info3.contains("solved in steps"), "control: after the swap the (i) still reads the quick field")
                XCTAssertEqual(top3, top1, "control: …and so does the legend")
            }
            await m.waitForIdle()
        }
        print("FLEX-NV LEGEND\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - the refine's line

    func testTheRefineLineAppearsAtOnceNamesTheGroupAndCountsTheIncrementBeingSolved() async throws {
        var notes: [String] = []
        let (stage, m, _) = try await pad(notes: &notes)
        let start = Date()
        while !m.squishSolver.refineIdle, Date().timeIntervalSince(start) < 600 {
            stage.refresh()
            let n = stage.simNote ?? "-"
            if notes.last != n { notes.append(n) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        stage.refresh()
        notes.append(stage.simNote ?? "-")
        print("FLEX-NV LINE the pad: \(notes)")
        let i = try XCTUnwrap(notes.lastIndex(of: FlexibleFE.pending), "the quick sim first")
        XCTAssertTrue(notes[i + 1].hasPrefix("Refining Group 1… "), "the line follows at once — never a blank: \(notes)")
        let refining = notes.filter { $0.hasPrefix("Refining") }
        XCTAssertEqual(refining.first, FlexibleFERefine.refining("Group 1", 1, of: FlexibleFERefine.increments), "it starts at 1/8")
        XCTAssertTrue(refining.contains(FlexibleFERefine.refining("Group 1", FlexibleFERefine.increments, of: FlexibleFERefine.increments)),
                      "8/8 while the last increment runs")
        XCTAssertEqual(notes.last, "-", "gone once it landed")
        for n in refining { XCTAssertLessThanOrEqual(n.count, FlexibleRowCopy.maxChars, n) }
    }

    // MARK: - every line WHOLE beside the live Play-all picker

    final class FrameBox { var all: [String: CGRect] = [:] }

    func frames<V: View>(_ v: V, size: CGSize) -> [String: CGRect] {
        let box = FrameBox()
        let hv = NSHostingView(rootView: AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { box.all = $0 }.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = NVHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.orderFrontRegardless()
        let end = Date().addingTimeInterval(0.4)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        hv.layoutSubtreeIfNeeded()
        let out = box.all
        w.orderOut(nil); w.contentView = nil
        return out
    }

    func testEveryRefineLineIsWholeBesideTheLivePlayAllPicker() throws {
        let sims = [FlexibleSim(id: "group-1", kind: .group(1), title: "Group 1 · Top A + Top B + Face 5", short: "Group 1", keys: []),
                    FlexibleSim(id: "group-2", kind: .group(2), title: "Group 2 · Face 3", short: "Group 2", keys: []),
                    FlexibleSim(id: "all", kind: .playAll, title: "Play all", short: "All", keys: [])]
        // every line the player's note shows from the sims (batch G's two fallbacks too: they were cut as well)
        let lines = [FlexibleFE.pending, FlexibleFERefine.refining("Group 2", 8, of: 8), FlexibleFERefine.refining("Group 1", 3, of: 8),
                     FlexibleFERefine.kept(FlexibleFERefine.notSettled), FlexibleFERefine.kept(FlexibleFERefine.tooLong),
                     FlexibleFERefine.kept(FlexibleFERefine.failedShort), FlexibleFE.failed, FlexibleFE.skipped("Group 2")]
        let oldLine = "Quick squish · the refine did not settle"   // batch N's
        let others = ["Simple squish · the sim failed", "Group 2 skipped · its sim failed"]   // batch G's (printed)
        var report: [String] = []
        var oldCut = 0
        for (tag, size) in FlexibleRound5SettingsHostedTests.sizes {
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120)
            let legends = FlexibleMainLegendLayout.place([.dent, .lattice], minimized: [], viewport: size, keepOut: keep,
                                                         priority: nil).values.map(\.frame)
            let blockers = FlexibleMainPlayerSlot.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120, legends: legends)
            let wanted = FlexibleSquishPlayer.size(picker: true, note: true)
            let r = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: size, bottomClearance: 90, keepOut: blockers, size: wanted))
            for (place, live) in [("Play all live", true), ("a pick", false)] {
                for note in lines + [oldLine] + others {
                    let loop = FlexibleSquishLoop()
                    if live { loop.notePlaying("group-2") }
                    let v = FlexibleSquishPlayer(loop: loop, fullLabel: "10 kg each", width: r.width, playAllLive: live, noteFor: nil,
                                                 sims: sims, shown: live ? sims[2] : sims[0], note: note)
                        .frame(width: r.width + 40, height: r.height + 40)
                    let f = frames(v, size: CGSize(width: r.width + 40, height: r.height + 40))
                    let drawn = try XCTUnwrap(f["playerNote"], "\(tag) \(place): the note is drawn").width
                    let natural = NSHostingView(rootView: Text(note).dsStyle(DS.TypeScale.footnote).fixedSize()).fittingSize.width
                        + 2 * DS.Space.m
                    let whole = drawn + 0.5 >= natural
                    if !whole || note == oldLine {
                        report.append(String(format: "%@ %@ (capsule %.0f pt): '%@' drawn %.0f of %.0f pt%@", tag, place, r.width, note,
                                             drawn, natural, whole ? "" : " — CUT"))
                    }
                    if lines.contains(note) {
                        XCTAssertTrue(whole, "\(tag) \(place): '\(note)' is drawn whole (\(drawn) of \(natural) pt)")
                    } else if note == oldLine, !whole {
                        oldCut += 1
                    }
                }
            }
        }
        print("FLEX-NV PLAYER LINES\n  " + report.joined(separator: "\n  "))
        // ★ RED CONTROL: batch N's line is cut beside the live picker (11" portrait)
        XCTAssertGreaterThan(oldCut, 0, "control: '\(oldLine)' is cut somewhere")
    }
}
#endif
