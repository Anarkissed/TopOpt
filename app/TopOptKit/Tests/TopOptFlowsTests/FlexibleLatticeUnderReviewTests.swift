import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ BATCH E REVIEW (the Flexible half). What the verifier found on his pad AS SAVED once a split
/// piece was latticed:
///   * the big Lattice pill took the `fix` tone, whose tap opens Settings — every tap re-opened the
///     pop-up and core was out of reach (his round 4 rule: the big buttons start core / export);
///   * nothing popped when the page opened; Faces 3 and 5 took one tap each;
///   * a calibrate-first filament lost HIS label ("<filament>: shape only — no squish predicted");
///   * Top B's deepest squish read 3.0 mm and silently clamped every edit to 0.5 mm.
/// The suites written on the whole-part lattice restore his project WITH the [Lattice under it] taps
/// (FlexibleHisProject); THIS file pins his project AS SAVED — what he sees when he opens it.
final class FlexibleLatticeUnderReviewTests: XCTestCase {

    // MARK: values

    private func face(_ r: Int, share: Double?) -> FlexibleReadiness.Face {
        FlexibleReadiness.Face(region: r, weightKg: 10, stacked: true, design: .ok, drawn: true, areaMM2: 100,
                               latticedShare: share)
    }

    private func inputs(_ faces: [FlexibleReadiness.Face], calibrateFirst: Bool = false,
                        canFix: @escaping (Int) -> Bool = { _ in true }) -> FlexibleReadiness.Inputs {
        var i = FlexibleReadiness.Inputs(materialID: calibrateFirst ? "tpu95a_generic" : "varioshore_tpu",
                                         materialName: calibrateFirst ? "TPU 95A" : "colorFabb varioShore TPU (foaming)",
                                         calibrateFirst: calibrateFirst,
                                         withData: (id: "varioshore_tpu", name: "colorFabb varioShore TPU"),
                                         pressed: faces, nozzleIsAuto: true)
        i.canLatticeUnder = canFix
        return i
    }

    private func lattice(shapeOnly label: String? = nil) -> FlexibleGeneratedLattice {
        let g = FlexibleSquishTests.generated()
        return FlexibleGeneratedLattice(inputs: g.inputs, faces: g.faces, topology: "gyroid", tempC: 220,
                                        settingsKey: 0, shapeOnlyLabel: label)
    }

    /// ★ The pill says the face — and its tap still SENDS (the Export step), never Settings again.
    /// CONTROLS: nothing to say ⇒ "Ready"; batch E's tone (`fix`) is the one whose tap opened Settings.
    func testThePillSaysItAndStillSends() {
        let bad = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)]))
        let n = try? XCTUnwrap(FlexibleLatticeUnder.first(bad))
        let s = FlexibleMainStatus.of(readiness: bad, sceneReady: true, isBuilding: false, lattice: lattice(), stale: false)
        XCTAssertEqual(s.line, "No lattice under Face 2", "★ said on the main page")
        XCTAssertEqual(s.tone, .preview, "★ never the fix tone")
        XCTAssertEqual(s.tap, .send, "★ the big button still starts core")
        XCTAssertEqual(s.fix?.id, n?.id)
        // with core's own hold (his pinch): the face is said, the tap still sends (the step says the pinch)
        let pinch = FlexibleCoreHold.pill(.pinch, shapeOnlyLabel: nil)
        let held = FlexibleMainStatus.of(readiness: bad, sceneReady: true, isBuilding: false, lattice: lattice(),
                                         stale: false, hold: pinch)
        XCTAssertEqual(held.line, "No lattice under Face 2")
        XCTAssertEqual(held.tap, .send)
        // CONTROLS
        let ok = FlexibleReadiness.evaluate(inputs([face(1, share: 1)]))
        XCTAssertEqual(FlexibleMainStatus.of(readiness: ok, sceneReady: true, isBuilding: false, lattice: lattice(), stale: false).line,
                       FlexibleMainStatus.ready, "control: nothing to say")
        XCTAssertEqual(FlexibleMainStatus.of(readiness: ok, sceneReady: true, isBuilding: false, lattice: lattice(),
                                             stale: false, hold: pinch).line, pinch, "control: the hold alone")
        XCTAssertEqual(FlexibleMainStatus(line: s.line, tone: .fix, fix: s.fix).tap, .openSettings,
                       "control: batch E's tone opened Settings on every tap")
        XCTAssertFalse(bad.blocking.contains { $0.kind == .noLatticeUnder }, "premise: never a blocker")
    }

    /// ★ A calibrate-first filament keeps HIS label on the pill and "shape only" on the Settings line.
    /// CONTROL: without the face to say, the line is the shape-only Ready line it always was.
    func testTheShapeOnlyLabelSurvives() {
        let label = FlexibleReadiness.shapeOnlyLabel("TPU 95A")
        let hold = FlexibleCoreHold.pill(.shapeOnly, shapeOnlyLabel: label)
        let bad = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)], calibrateFirst: true))
        let ok = FlexibleReadiness.evaluate(inputs([face(1, share: 1)], calibrateFirst: true))
        let s = FlexibleMainStatus.of(readiness: bad, sceneReady: true, isBuilding: false, lattice: lattice(shapeOnly: label),
                                      stale: false, hold: hold)
        XCTAssertEqual(s.line, label, "★ his label stays on the pill")
        XCTAssertEqual(s.tap, .send)
        XCTAssertEqual(s.fix?.kind, .noLatticeUnder, "the face is still carried")
        XCTAssertEqual(bad.oneLine, "Ready · shape only · No lattice under Face 2", "★ 'shape only' stays on the line")
        XCTAssertEqual(ok.oneLine, FlexibleReadiness.readyShapeOnly, "control")
        XCTAssertEqual(FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)])).oneLine,
                       "Ready · No lattice under Face 2", "control: a filament with data")
    }

    /// ★ It pops ONCE when the page opens (his rule: "I should know about it right away"), as soon as
    /// the scene settles. CONTROLS: an action-only prompt stays silent; a blocker still pops first.
    func testItPopsOnceWhenThePageOpens() {
        let r = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)]))
        var p = FlexibleFixPrompt(actionSerial: 3, popExisting: true)
        XCTAssertNil(p.next(r, actionSerial: 3, settled: false), "not while the scene is in flight")
        XCTAssertEqual(p.next(r, actionSerial: 3, settled: true)?.kind, .noLatticeUnder, "★ at once, when settled")
        XCTAssertNil(p.next(r, actionSerial: 3, settled: true), "once")
        var quiet = FlexibleFixPrompt(actionSerial: 3)
        XCTAssertNil(quiet.next(r, actionSerial: 3, settled: true), "control: no pop without the open")
        let blocked = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0),
                                                         FlexibleReadiness.Face(region: 4, weightKg: 0, stacked: true)]))
        var q = FlexibleFixPrompt(actionSerial: 3, popExisting: true)
        XCTAssertEqual(q.next(blocked, actionSerial: 3, settled: true)?.kind, .noWeight, "control: a blocker first")
    }

    /// ★ SEVERAL FACES, ONE TAP: [Lattice under both] / [Lattice under all 3], and the pop-up pulses
    /// every face it covers. CONTROLS: one face keeps [Lattice under it]; a face with no one-tap
    /// edit keeps only [rests] and is not in the all.
    func testSeveralFacesAreFixedInOneTap() throws {
        let two = FlexibleReadiness.evaluate(inputs([face(3, share: 0.23), face(5, share: 0.23)]))
        let i3 = try XCTUnwrap(two.issues.first { $0.kind == .noLatticeUnder && $0.region == 3 })
        XCTAssertEqual(i3.fixes, [.latticeUnderAll([3, 5]), .rest(3)])
        XCTAssertEqual(i3.fixes.first?.title { "Face \($0)" }, "Lattice under both")
        XCTAssertEqual(i3.named, [3, 5], "★ the pop-up pulses both")
        let three = FlexibleReadiness.evaluate(inputs([face(1, share: 0), face(3, share: 0.2), face(5, share: 0.2)]))
        XCTAssertEqual(three.issues.first { $0.kind == .noLatticeUnder }?.fixes.first?.title { "Face \($0)" }, "Lattice under all 3")
        // CONTROLS
        let one = FlexibleReadiness.evaluate(inputs([face(1, share: 1), face(2, share: 0)]))
        XCTAssertEqual(one.issues.first { $0.kind == .noLatticeUnder }?.fixes, [.latticeUnder(2), .rest(2)])
        let partly = FlexibleReadiness.evaluate(inputs([face(3, share: 0.2), face(5, share: 0.2)], canFix: { $0 == 3 }))
        XCTAssertEqual(partly.issues.filter { $0.kind == .noLatticeUnder }.map(\.fixes), [[.latticeUnder(3), .rest(3)], [.rest(5)]])
    }

    /// ★ No lattice at all under a pressed face: the deepest-squish row says so (the box and the 3D
    /// chip clamped every edit to 0.5 mm). The stack line says the latticed share.
    func testNothingToSquishAndTheStackLine() {
        XCTAssertTrue(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: 0), "★ Top B as saved: chip-max 0")
        XCTAssertTrue(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: 0.4))
        XCTAssertFalse(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: 20), "control: lattice under it")
        XCTAssertFalse(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: nil), "control: no stack yet")
        XCTAssertEqual(FlexibleDepthPrism.clamp(3, latticeMM: 0), 0.5, "control: what the box did with a typed 3")
        let all = FlexibleLatticeUnder.stackInfo(uMM: 100, vMM: 50, columns: 2048, pitchMM: 1.6, latticed: 2048, minMM: 20, maxMM: 20)
        XCTAssertEqual(all, String(format: "%.0f × %.0f mm · %d columns, %.1f mm apart · lattice %.1f–%.1f mm deep",
                                   100.0, 50.0, 2048, 1.6, 20.0, 20.0), "control: every column latticed — the line it always was")
        XCTAssertEqual(FlexibleLatticeUnder.stackInfo(uMM: 100, vMM: 20, columns: 832, pitchMM: 1.6, latticed: 192, minMM: 100, maxMM: 100),
                       "100 × 20 mm · 832 columns, 1.6 mm apart · lattice under 23 % · 100.0–100.0 mm deep", "★ the share")
        XCTAssertTrue(FlexibleLatticeUnder.stackInfo(uMM: 100, vMM: 50, columns: 2048, pitchMM: 1.6, latticed: 0, minMM: 0, maxMM: 0)
                        .hasSuffix("· no lattice under it"))
        // the toast names a PROTECTED selection on the main page
        let t = FlexibleLatticeUnder.toast(.newGroup(face: nil, region: 104, name: "Top B", depthMM: 20), name: "Top B", group: "Top B")
        XCTAssertEqual(t, "Top B: lattice under it, 20 mm deep · new protected selection \u{201C}Top B\u{201D}")
        XCTAssertEqual(FlexibleLatticeUnder.toastAll(["Face 3", "Face 5"], newSelections: 2),
                       "Face 3 and Face 5: lattice under them · 2 new protected selections")
    }

    // MARK: his pad, AS SAVED

    /// ★ ROUND 3 COPY AS SAVED (img 4): Top B has no lattice under it. Said on Settings' line, popped
    /// when the page opens, on the main pill — whose tap still reaches the Export step, which says
    /// his pinch. The deepest-squish row cannot be clamped. CONTROL: with the fixture's tap, the same
    /// pill reads the pinch preview and every column of Top B is latticed.
    @MainActor
    func testHisRound3PadAsSaved() async throws {
        let r = try FlexibleHisProject.restore(asSaved: true)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(120, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing }
        let b = FlexibleHisProject.topB
        XCTAssertEqual(m.latticedShare(b) ?? -1, 0, accuracy: 1e-9, "premise: no lattice under Top B as saved")
        XCTAssertEqual(m.latticedShare(FlexibleHisProject.topA) ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(m.readiness.oneLine, "Ready · No lattice under Top B", "Settings' line")
        var open = FlexibleFixPrompt(actionSerial: m.actionSerial, popExisting: true)
        let popped = open.next(m.readiness, actionSerial: m.actionSerial, settled: true)
        XCTAssertEqual(popped?.region, b, "★ it pops when the page opens")
        XCTAssertEqual(popped?.fixes, [.latticeUnder(b), .rest(b)])
        // the deepest row: nothing to squish into, the value kept
        let maxB = m.stack(b).map { FlexibleDepthPrism.latticeMax($0, pinched: m.pinchedColumns(b)) }
        XCTAssertTrue(FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: maxB), "★ the row says it (chip-max \(maxB ?? -1))")
        XCTAssertGreaterThan(m.settings.face(b)?.deepestMM ?? 0, 0.5, "premise: his 3.0 mm is kept")
        // the main page: built, then the pill
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(240, "his lattice") {
            (m.lattice != nil && !m.latticeIsStale && !m.latticeBuilding) || m.latticeError != nil
        }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertNil(m.latticeError)
        let s = stage.status
        print("E-REVIEW r3 as saved: pill '\(s.line)' tone \(s.tone) tap \(s.tap)")
        XCTAssertEqual(s.line, "No lattice under Top B")
        XCTAssertEqual(s.tone, .preview, "★ not the fix tone")
        XCTAssertEqual(s.tap, .send, "★ the big button still reaches core")
        stage.pillTapped(s, open: { XCTFail("★ never Settings again") }, goToLattice: { XCTFail("already there") })
        let run = stage.coreRun
        XCTAssertTrue(run.shown, "the Export step")
        XCTAssertEqual(run.line, "Not sent: core can\u{2019}t press \(m.displayName(3)) and \(m.displayName(5)) at once",
                       "the step says his pinch")
        XCTAssertEqual(run.runs, 0)
    }

    /// ★ ROUND 5 COPY AS SAVED: Faces 3 and 5 have lattice under 23 % of their columns. ONE tap
    /// ([Lattice under both]) puts lattice under every column of both, as ONE undo step; undo puts
    /// his project back. CONTROL: before the tap, 192 of 832 columns.
    @MainActor
    func testHisRound5PadAsSavedIsFixedInOneTap() async throws {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let p = r.project
        let m = try await FlexibleHisProject.openedModel(p, test: self, timeout: 120)
        await m.waitForIdle()
        let k3 = try XCTUnwrap(m.loadedKeys.first { $0.region == 3 }), k5 = try XCTUnwrap(m.loadedKeys.first { $0.region == 5 })
        print("E-REVIEW r5 as saved: Face 3 \(m.stacks[k3]?.latticedColumns ?? -1)/\(m.stacks[k3]?.columns.count ?? -1) · Face 5 \(m.stacks[k5]?.latticedColumns ?? -1)/\(m.stacks[k5]?.columns.count ?? -1) · line '\(m.readiness.oneLine)'")
        XCTAssertLessThan(m.latticedShare(3) ?? 1, FlexibleLatticeUnder.minShare, "premise: little lattice under Face 3")
        XCTAssertLessThan(m.latticedShare(5) ?? 1, FlexibleLatticeUnder.minShare)
        let issue = try XCTUnwrap(m.readiness.issues.first { $0.kind == .noLatticeUnder })
        XCTAssertEqual(issue.fixes.first, .latticeUnderAll([3, 5]), "★ one tap for both")
        p.seedUndoBaseline()
        let before = p.editSnapshot
        let groups = p.selection.groups.count
        FlexibleFixPopup.apply(.latticeUnderAll([3, 5]), to: m)
        XCTAssertEqual(p.selection.groups.count, groups + 2, "'Face 3' and 'Face 5'")
        XCTAssertEqual(m.toast, "Face 3 and Face 5: lattice under them · 2 new protected selections")
        try await FlexibleHisProject.waitFor(150, "the scene re-opened on the new lattice") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        for k in [k3, k5] {
            let st = try XCTUnwrap(m.stacks[k])
            XCTAssertEqual(st.latticedColumns, st.columns.count, "★ \(m.displayName(k.region)): lattice under every column")
        }
        XCTAssertNil(m.readiness.issues.first { $0.kind == .noLatticeUnder }, "nothing left to say")
        p.performUndo()
        XCTAssertEqual(p.selection.groups.count, groups, "★ ONE undo step takes both back")
        XCTAssertEqual(p.editSnapshot, before)
    }
}
