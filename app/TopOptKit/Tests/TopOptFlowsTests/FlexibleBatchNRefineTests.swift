// FlexibleBatchNRefineTests — each squeeze group's squish solved again IN STEPS, on the app's own
// pipeline (task 2026-09-29-flexible-screens, round 5 batch N; maintainer, on batch G's fold cut:
// "Is there no way to fold realistically instead?"). Every claim with its RED control, computed
// beside it and failing the same assertion:
//   * his round-5 project through Save & Exit: the quick fields first, "Refining the squish… n/8",
//     then each group's refined field — 0 inverted cells at FULL size where the quick field (uncut)
//     inverts (RED: the quick field), never cut (RED: the page ignoring the refine — "cut to 23 %"),
//     each group its own (RED: the two groups' presses in one request), the (i) says "solved in
//     steps … no buckling or self-contact", the dent row is "×1", Stress reads it;
//   * the renderer swaps the refined version in at the cycle's REST point, with its mesh and its
//     colours (RED: the swap at once — mid-squeeze);
//   * a refine that does not settle keeps the quick field, its fold cut (the fallback) and one line
//     why (RED: the converged refine — no cut, no line);
//   * a new lattice cancels a refine between increments and its session ends; a solve waiting for
//     core gets it between increments, never beside a sim (RED: a refine that ignores the cancel; one
//     that never yields).
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchNRefineTests: XCTestCase {

    typealias Fx = FlexibleLatticeFixtures

    /// His round-5 project through Save & Exit on the page's own refresh; returns once the QUICK sims
    /// landed (the refines then run). `notes` collects the player's lines seen on the way.
    func round5(notes: inout [String]) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        var seen: [String] = []
        try await FlexibleHisProject.waitFor(300, "his round 5: the quick sims") {
            stage.refresh()
            if let n = stage.simNote, seen.last != n { seen.append(n) }
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        notes = seen
        return (r, stage, m)
    }

    /// Waits for every refine, recording the player's lines on the way.
    func refines(_ stage: FlexibleMainStage, _ m: FlexibleStageModel, notes: inout [String], timeoutS: Double = 900) async throws {
        let start = Date()
        while !m.squishSolver.refineIdle {
            stage.refresh()
            if let n = stage.simNote, notes.last != n { notes.append(n) }
            if Date().timeIntervalSince(start) > timeoutS { XCTFail("the refines never ended"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stage.refresh()
    }

    // MARK: - his round-5 project

    func testHisRound5GroupsRefineAndNeverInvertAtFullSize() async throws {
        var notes: [String] = []
        let (_, stage, m) = try await round5(notes: &notes)
        let r = try XCTUnwrap(m.lastFERequest)
        let quick1 = try XCTUnwrap(m.squish["group-1"]?.field), quick2 = try XCTUnwrap(m.squish["group-2"]?.field)
        try await refines(stage, m, notes: &notes)
        print("FLEX-N NOTES his r5: \(notes)")
        XCTAssertTrue(notes.contains(FlexibleFE.pending), "the quick sims first: \(notes)")
        // ★ RE-PINNED (batch N verification): the line names the group and counts the increment being solved
        XCTAssertTrue(notes.contains { $0.hasPrefix("Refining Group 1… ") && $0.hasSuffix("/\(FlexibleFERefine.increments)") },
                      "then the steps, counted: \(notes)")
        for (id, quick) in [("group-1", quick1), ("group-2", quick2)] {
            guard case .ready(let f)? = m.refine[id] else { XCTFail("\(id): \(String(describing: m.refine[id]))"); continue }
            let rc = try XCTUnwrap(f.refine)
            let full = quick.scaled(by: 1 / (quick.foldShare ?? 1))   // the quick field at its UNCUT calibrated size
            let qi = FlexibleBatchNProbe.inverted(full, 1), si = FlexibleBatchNProbe.inverted(f, 1)
            let qp = FlexibleFEVerifyGTests.pullback(full, 1), sp = FlexibleFEVerifyGTests.pullback(f, 1)
            print(String(format: "FLEX-N HIS %@: quick k %.3f (asked %.2f, cut %@) · uncut inverted %d (min det %.3f), pull-back misses %d (worst %.2f mm) → stepped λ %.3f (asked %.2f) · inverted %d (min det %.3f) · pull-back misses %d (worst %.2f mm) · gmax part %.3f → %.3f · %d increments, %d solves, %.1f s, converged %@",
                         id, quick.scale / (quick.foldShare ?? 1), quick.coreRatio, quick.foldShare.map { String(format: "to %.0f%%", 100 * $0) } ?? "none",
                         qi.count, qi.minDet, qp.1, qp.2, f.scale, f.coreRatio, si.count, si.minDet, sp.1, sp.2, full.gmaxPart, f.gmaxPart,
                         rc.steps.count, rc.solves, rc.totalMS / 1000, "\(rc.converged)"))
            XCTAssertTrue(rc.converged, "\(id): the stepped solve settles")
            // ★ BATCH N VERIFICATION: …on an UNDAMPED solve (his Group 1 had stopped on a ¼-damped one, 7 % short)
            XCTAssertEqual(rc.steps.last?.omega ?? 0, 1, "\(id): the solve that stopped was undamped")
            let last = try XCTUnwrap(rc.steps.last)
            print(String(format: "FLEX-NV HIS %@: last increment λ %.3f · %d solves · change %.4f · ω %.2f · beyond data %d of %d (%.0f%%) · inflated (det > 1.3) %d (max det %.2f) · increments %@",
                         id, last.loadFactor, last.solves, last.change, last.omega, last.beyondData, last.solid,
                         100 * Double(last.beyondData) / Double(max(1, last.solid)), last.inflated, last.volumeRatioMax,
                         rc.steps.map { String(format: "%.2f:%d%@%@", $0.loadFactor, $0.solves, $0.converged ? "✓" : "✗", $0.omega < 1 ? "d" : "") }.joined(separator: " ")))
            XCTAssertNil(f.foldShare, "\(id): converged — the fold cut is NOT applied")
            XCTAssertEqual(si.count, 0, "\(id): no cell inverts at full size")
            XCTAssertGreaterThan(si.minDet, 0)
            XCTAssertTrue(FlexibleFE.calibrationBand.contains(f.scale), "\(id): the load factor inside the band")
            if id == "group-1" {
                // ★ RED CONTROL: the quick field at the same (uncut) size inverts — batch G's reason to cut it
                XCTAssertGreaterThan(qi.count, 0, "control: the quick sim folds at full size")
                XCTAssertNotNil(quick.foldShare, "control: …so batch G cut it")
            }
        }
        // ── each group its own field (no combo) ──
        let f1 = try XCTUnwrap(m.refine["group-1"]?.field), f2 = try XCTUnwrap(m.refine["group-2"]?.field)
        let g1 = try XCTUnwrap(r.sims.first { $0.id == "group-1" }), g2 = try XCTUnwrap(r.sims.first { $0.id == "group-2" })
        let face3 = try XCTUnwrap(g2.pressed.firstIndex { $0.face == 3 }), face5 = try XCTUnwrap(g1.pressed.firstIndex { $0.face == 5 })
        let topA = try XCTUnwrap(g1.pressed.firstIndex { $0.face == FlexibleHisProject.topA })
        let in3 = FlexibleFEVerifyGTests.inward(f2, g2.targets[face3]), far5 = FlexibleFEVerifyGTests.inward(f2, g1.targets[face5])
        let inA = FlexibleFEVerifyGTests.inward(f1, g1.targets[topA])
        let aUnder2 = FlexibleFEVerifyGTests.inward(f2, g1.targets[topA])
        print(String(format: "FLEX-N HIS per group: group 2 → Face 3 in %.3f mm, Face 5 %.3f mm, Top A %.3f mm · group 1 → Top A in %.3f mm",
                     in3, far5, aUnder2, inA))
        XCTAssertGreaterThan(in3, 0, "group 2 presses Face 3 in")
        XCTAssertGreaterThan(inA, 0, "group 1 presses Top A in")
        XCTAssertLessThanOrEqual(abs(far5), 0.05 * in3, "group 2 alone: Face 5 (its far end) stays")
        XCTAssertLessThan(aUnder2, 0.5 * inA, "group 2 alone does not press Top A")
        // ★ RED CONTROL: the two groups' presses in ONE request (a combo) moves both groups' faces
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let combo = FlexibleFERequest.Sim(id: "combo", pressed: g1.pressed + g2.pressed, strainOp: g2.strainOp, targets: g1.targets + g2.targets)
        let cs = try scene.squishSolve(r.request(combo))
        XCTAssertTrue(cs.ok, cs.failure)
        let cf = FlexibleFEField(solution: cs, simID: "combo", generation: r.generation)
        let cA = FlexibleFEVerifyGTests.inward(cf, g1.targets[topA]), c3 = FlexibleFEVerifyGTests.inward(cf, g2.targets[face3])
        print(String(format: "FLEX-N HIS control (combo): Top A %.3f mm and Face 3 %.3f mm in one field", cA, c3))
        XCTAssertGreaterThan(cA, 0, "control: the combo presses Top A …")
        XCTAssertGreaterThan(c3, 0, "control: … and Face 3 in the same field")

        // ── the page: the refined fields on screen, never cut, said in one sentence ──
        for id in ["group-1", "group-2"] {
            stage.pick(id)
            stage.refresh()
            XCTAssertTrue(stage.fe.active && stage.fe.stepped, "\(id): the page shows the refined field")
            XCTAssertEqual(stage.feShownField?.versionKey, id + FlexibleFERefine.versionSuffix, "\(id): the refined version on screen")
            let info = stage.dentInfo
            print("FLEX-N HIS (i) \(id): \(info) · dent row \(stage.dentFactorLabel) · note \(stage.simNote ?? "-")")
            XCTAssertTrue(info.contains("solved in steps") && info.contains("no buckling or self-contact"), info)
            // ★ BATCH N VERIFICATION: the force it is at, and (Group 1 only) the turns drawn as stretches
            let f = try XCTUnwrap(stage.feShownField)
            let inflated = f.refine?.inflated ?? -1
            if id == "group-1" {
                XCTAssertTrue(info.contains("pressed at 2× your weights"), "\(id): at the band's edge — said: \(info)")
                XCTAssertGreaterThan(inflated, 0, "\(id): its edge above the thumb grows under the press (a turn drawn as a stretch)")
                XCTAssertTrue(info.contains("big turns drawn as stretches"), "\(id): …said: \(info)")
            } else {
                // ★ RED CONTROL of the turn clause: Group 2 has no element that grows — nothing said
                XCTAssertEqual(inflated, 0, "\(id): no element grows under its press")
                XCTAssertFalse(info.contains("turns drawn as stretches"), "\(id): nothing to say")
                XCTAssertTrue(info.contains(String(format: "pressed at %.1f× your weights", f.scale)), "\(id): its own load factor: \(info)")
            }
            XCTAssertFalse(info.contains("cut to"), "\(id): no cut said")
            XCTAssertFalse(info.contains(". "), "one sentence")
            XCTAssertEqual(stage.dentFactorLabel, "×1", "\(id): drawn at its full size")
            XCTAssertNil(stage.simNote, "\(id): the refine's line is gone once it landed")
            XCTAssertEqual(stage.stressSimWord, "stepped", "\(id): Stress reads the refined field")
        }
        // ── the Settings page shows the selected group's refined field once it exists ──
        for g in m.squeezeGroups {
            let f = FlexibleSettingsSquish.field(model: m, group: g)
            XCTAssertEqual(f?.versionKey, FlexibleSim.groupID(g.number) + FlexibleFERefine.versionSuffix, "Settings: group \(g.number)'s refined field")
        }
        // ★ RED CONTROL: the page ignoring the refines — batch M's quick field, cut, said
        stage.controlNoRefineView = true
        stage.pick("group-1")
        stage.refresh()
        let old = stage.dentInfo
        print("FLEX-N HIS control (no refine view): \(old) · dent row \(stage.dentFactorLabel)")
        XCTAssertTrue(old.contains("cut to"), "control: the quick field is cut")
        XCTAssertNotEqual(stage.dentFactorLabel, "×1", "control: drawn at a fraction")
        stage.controlNoRefineView = false
    }

    // MARK: - the swap at rest

    func uniformField(_ id: String, _ d: SIMD3<Float>, refined: Bool = false) -> FlexibleFEField {
        var f = FlexibleFEField(simID: id, generation: 1, nx: 3, ny: 3, nz: 3, origin: SIMD3(-1, -1, -1), spacing: 25,
                                u: [SIMD3<Float>](repeating: d, count: 27))
        if refined { f.refine = FlexibleFERefine.Receipt() }
        return f
    }

    func testTheRefinedFieldSwapsInAtRest() throws {
        for atOnce in [false, true] {
            let device = try Fx.device()
            let box = Fx.boxMesh()
            let r = try Fx.renderer(device: device, box: box)
            let n = box.mesh.flat.vertexCount * 3
            let quickMesh = [Float](repeating: 0.1, count: n), refinedMesh = [Float](repeating: 0.3, count: n)
            let loop = FlexibleSquishLoop()
            var t: CFTimeInterval = 10
            loop.clock = { t }
            let P = FlexibleSquishLoop.periodS
            let tints = FlexibleFETints()
            let quickTints = [Float](repeating: 0.25, count: box.mesh.flat.vertexCount * 8)
            let refinedTints = [Float](repeating: 0.75, count: box.mesh.flat.vertexCount * 8)
            tints.set(["group-1": quickTints, "group-1" + FlexibleFERefine.versionSuffix: refinedTints])
            var l = FlexibleLatticeLayerInputs(lattice: Fx.boxInputs(.gyroid), faces: [], token: 1, loop: loop)
            let quick = uniformField("group-1", SIMD3(0, 0, -1)), refined = uniformField("group-1", SIMD3(0, 0, -2), refined: true)
            l.fe = [quick]; l.feMesh = [quickMesh]; l.feSequence = [0]; l.feToken = 1; l.feTints = tints
            r.applyFlexibleLattice(l, device: device)
            let pass = try XCTUnwrap(r.flexibleLattice)
            pass.controlVersionSwapAtOnce = atOnce
            loop.restartFromRest(reduceMotion: false)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
            func step(_ at: Double) { t = 10 + at * P; r.stepFlexibleLoop(in: view, now: t) }
            step(0.4)
            XCTAssertEqual(pass.feShown, 0)
            XCTAssertEqual(loop.shownKey, "group-1", "the quick version on screen")
            // the refined version lands mid-squeeze: the page hands it in the group's place and keeps the
            // quick one beside it (the renderer still shows it)
            l.fe = [refined, quick]; l.feMesh = [refinedMesh, quickMesh]; l.feSequence = [0]; l.feToken = 2
            r.applyFlexibleLattice(l, device: device)
            step(0.5)
            let midField = pass.feShown, midKey = loop.shownKey, midAmount = loop.amount(at: t)
            step(0.999)
            let lateKey = loop.shownKey
            step(1.001)
            let restKey = loop.shownKey, restAmount = loop.amount(at: t)
            print(String(format: "FLEX-N SWAP %@: mid-cycle (amount %.2f) field %d %@ · at 0.999 P %@ · at the rest point (amount %.4f) %@ · mesh %d · tints %@",
                         atOnce ? "control (at once)" : "rule", midAmount, midField, midKey ?? "-", lateKey ?? "-", restAmount, restKey ?? "-",
                         pass.feMeshShown, pass.feTintsShown ?? "-"))
            if !atOnce {
                XCTAssertEqual(midKey, "group-1", "mid-squeeze: the quick version stays on screen")
                XCTAssertEqual(lateKey, "group-1", "…to the end of the cycle")
                XCTAssertEqual(restKey, "group-1" + FlexibleFERefine.versionSuffix, "at rest: the refined version")
                XCTAssertEqual(pass.feShown, 0)
                XCTAssertEqual(pass.feMeshShown, 0, "its mesh in the same step")
                XCTAssertEqual(pass.feTintsShown, "group-1" + FlexibleFERefine.versionSuffix, "…and its colours")
                XCTAssertLessThanOrEqual(restAmount, 1e-3)
            } else {
                // ★ RED CONTROL: batch G's rule — the refined version bound at once, mid-squeeze
                XCTAssertNotEqual(midKey, "group-1", "control: the swap lands mid-squeeze")
                XCTAssertGreaterThan(midAmount, 0.5)
            }
        }
    }

    // MARK: - not settled, cancelled, the gate

    /// C1's covered pad with its top pressed and its bottom resting, the quick sim landed.
    func pad(_ prepare: (FlexibleStageModel) -> Void = { _ in }) async throws -> (FlexibleMainStage, FlexibleStageModel) {
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
        try await FlexibleHisProject.waitFor(300, "the pad's quick sim") {
            stage.refresh()
            return !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        return (stage, m)
    }

    func testARefineThatDoesNotSettleKeepsTheQuickFieldAndSaysWhy() async throws {
        for unsettled in [true, false] {
            let (stage, m) = try await pad { $0.squishSolver.controlRefineUnsettled = unsettled }
            var notes: [String] = []
            try await refines(stage, m, notes: &notes)
            let state = m.refine["group-1"]
            print("FLEX-N KEPT \(unsettled ? "unsettled" : "control (settled)"): \(String(describing: state).prefix(160)) · note '\(stage.simNote ?? "-")' · (i) '\(stage.dentInfo)' · seen \(notes)")
            if unsettled {
                guard case .kept(let why, _)? = state else { XCTFail("kept: \(String(describing: state))"); continue }
                XCTAssertEqual(why, FlexibleFERefine.notSettled)
                XCTAssertEqual(stage.simNote, FlexibleFERefine.kept(FlexibleFERefine.notSettled), "one line why")
                // ★ RE-PINNED (batch N verification): "Refine didn't settle" — the drawn width is pinned in
                // FlexibleBatchNVerifyTests (the 40-character line was cut beside the live picker at 11" portrait)
                XCTAssertEqual(stage.simNote, "Refine didn't settle")
                for w in [FlexibleFERefine.notSettled, FlexibleFERefine.tooLong, FlexibleFERefine.failedShort] {
                    XCTAssertLessThanOrEqual(FlexibleFERefine.kept(w).count, FlexibleRowCopy.maxChars, "one line: \(FlexibleFERefine.kept(w))")
                }
                XCTAssertLessThanOrEqual(FlexibleFERefine.refining("Group 1", 8, of: 8).count, FlexibleRowCopy.maxChars)
                // ★ RED CONTROL: the first wording ran past the line
                XCTAssertGreaterThan("Quick squish kept · the stepped sim did not settle".count, FlexibleRowCopy.maxChars, "control: too long")
                // …and the (i) still says the cut and why
                XCTAssertTrue(stage.dentInfo.contains("(the refine did not settle)"), stage.dentInfo)
                XCTAssertFalse(stage.fe.stepped, "the quick field stays")
                XCTAssertEqual(stage.feShownField?.versionKey, "group-1")
                XCTAssertFalse(stage.dentInfo.contains("solved in steps"))
            } else {
                // ★ RED CONTROL: the settled refine — its field on screen, no line
                guard case .ready? = state else { XCTFail("ready: \(String(describing: state))"); continue }
                XCTAssertNil(stage.simNote, "control: nothing to say once it landed")
                XCTAssertTrue(stage.fe.stepped, "control: the refined field on screen")
            }
        }
    }

    func testANewLatticeCancelsTheRefineAndAWaitingSolveGetsCoreBetweenIncrements() async throws {
        // "rule": the lattice's sims dropped (a lattice with none lands) — only the model's cancel stops the
        // refine; "new lattice": Save & Exit again — the page schedules the new lattice's sims (which cancels
        // the old token too); the two controls on the first path
        for mode in ["rule", "new lattice", "ignores cancel", "never yields"] {
            let before = FlexSquishSteps.liveSessions
            let (stage, m) = try await pad {
                $0.squishSolver.controlRefineStepDelayS = 0.4
                $0.squishSolver.controlRefineIgnoresCancel = mode == "ignores cancel"
                $0.squishSolver.controlRefineNoYield = mode == "never yields"
            }
            _ = stage
            FlexibleCoreGate.shared.resetPeak()
            try await FlexibleHisProject.waitFor(120, "the refine starts") {
                if case .running? = m.refine["group-1"] { return true }
                return false
            }
            let oldGen = try XCTUnwrap(m.squishSolver.refiningGeneration)
            // a solve that wants core while the refine runs (the Stress / octet solve's claim)
            let yieldsBefore = FlexibleCoreGate.shared.yieldCount
            let t1 = Date()
            let simsInside: Int = await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    FlexibleCoreGate.shared.enterOther()
                    let inside = FlexibleCoreGate.shared.value
                    FlexibleCoreGate.shared.leaveOther()
                    cont.resume(returning: inside)
                }
            }
            let waited = Date().timeIntervalSince(t1)
            let yields = FlexibleCoreGate.shared.yieldCount - yieldsBefore
            let stillRunning = m.squishSolver.refiningGeneration == oldGen
            let t0: Date
            if mode == "new lattice" {
                // Save & Exit after an edit: the old lattice's refine stops between increments
                m.squishSolver.controlNoRefine = true   // (the new lattice refines nothing — only the old one is watched)
                m.generateLattice()
                try await FlexibleHisProject.waitFor(120, "the new lattice") { (m.lattice?.generation ?? oldGen) != oldGen }
                t0 = Date()
            } else {
                // the lattice's sims dropped (FlexibleStageModel.latticeLanded with no request): the model's cancel
                t0 = Date()
                m.latticeLanded(nil)
            }
            while m.squishSolver.refiningGeneration == oldGen, Date().timeIntervalSince(t0) < 120 { try await Task.sleep(nanoseconds: 50_000_000) }
            let stopS = Date().timeIntervalSince(t0)
            try await Task.sleep(nanoseconds: 300_000_000)
            print(String(format: "FLEX-N CANCEL %@: the waiting solve got core after %.2f s with %d sims inside · yields %d · refine still running then %@ · it stopped %.1f s after the new lattice · sessions %d (before %d) · peak sims %d · old refine's result %@",
                         mode, waited, simsInside, yields, "\(stillRunning)", stopS, FlexSquishSteps.liveSessions, before,
                         FlexibleCoreGate.shared.maximum, String(String(describing: m.refine["group-1"]).prefix(40))))
            XCTAssertEqual(simsInside, 0, "never beside a sim")
            XCTAssertLessThanOrEqual(FlexibleCoreGate.shared.maximum, 1, "one sim in core at a time")
            XCTAssertEqual(FlexSquishSteps.liveSessions, before, "its session ended")
            switch mode {
            case "rule", "new lattice":
                XCTAssertNil(m.refine["group-1"], "\(mode): the cancelled refine left no result")
                XCTAssertGreaterThan(yields, 0, "the refine yielded core between increments")
                XCTAssertLessThan(waited, 5, "…so the waiting solve got core within an increment")
                XCTAssertTrue(stillRunning, "…and the refine went on after it")
                XCTAssertLessThan(stopS, 6, "\(mode): stopped at the next increment")
            case "ignores cancel":
                // ★ RED CONTROL: a refine that ignores the cancel runs every remaining increment, and its
                // result lands on a lattice that dropped its sims
                XCTAssertGreaterThan(stopS, 6, "control: it ran on")
                XCTAssertNotNil(m.refine["group-1"], "control: its result landed")
            default:
                // ★ RED CONTROL: a refine that never yields — the waiting solve waits for its END
                XCTAssertEqual(yields, 0, "control: no yield")
                XCTAssertGreaterThan(waited, 5, "control: the solve got core only once the refine ended")
            }
        }
    }
}
#endif
