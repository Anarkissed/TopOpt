// FlexibleReadinessTests — "requirements are shown at once, fixed in one tap, and exit is
// blocked only when truly needed" (task 2026-09-29-flexible-screens, round 3 batch B, item 9;
// maintainer: "I can't make Lattice run").
//   * HIS project as saved (faces 3 and 5 pressed at 10 kg by the old taps): exactly ONE
//     blocking issue — 3/5 share a stack — with its fixes [Face 5 rests] [Face 3 rests].
//     RED CONTROL: with TPU 95A the OLD gate (copied verbatim below) says "calibrate-first"
//     first — the sentence that no longer blocks hid the one that did;
//   * after [Face 5 rests]: nothing blocks; Exit ⇒ a lattice (varioShore) or a SHAPE-ONLY
//     lattice labelled "TPU 95A: shape only — no squish predicted" (TPU 95A);
//   * the rule on values: calibrate-first, more than four faces and "still designing" never
//     block; no weight / no stack / a refusal with no automatic fix do; the auto-fix codes
//     become toasts (RED: with the setting already Auto / Gyroid they block);
//   * one face's throw no longer stops the next face's design (RED: the old single catch);
//   * the Exit decision as a value (its call site on the page: FlexibleMainPageHookTests); the
//     pop-up opens only on a NEW blocking issue HIS action caused.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleReadinessTests: XCTestCase {

    // MARK: his project

    /// His project restored, its scene open and every pressed face designed (the pipeline idle).
    @MainActor
    private func his(material: String? = nil) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        if let material { r.project.lattice.flexible?.materialID = material }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel, _ what: String = "the designs") async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(60, what) { !m.readiness.designing && !m.latticeBuilding }
        await m.waitForIdle()
    }

    /// THE OLD GATE (FlexibleLatticeGate.refusal at 3b6460fb), verbatim — the red control.
    @MainActor
    private func oldGate(_ m: FlexibleStageModel) -> String? {
        guard let mat = m.material else { return "Pick a filament first." }
        if mat.noPrediction != nil { return "\(mat.displayName) is calibrate-first: there is no squish data to size the lattice from." }
        let loaded = m.settings.loadedFaces
        guard !loaded.isEmpty else { return "Mark at least one face that carries weight." }
        if loaded.count > FlexibleSquishField.maxFaces { return "The preview squishes up to 4 faces that carry weight — mark the others as where it rests." }
        if let c = m.conflicts.first {
            return "\(m.name(c.faceA).capitalized) and \(m.name(c.faceB)) share a stack — mark one of them as where it rests."
        }
        for f in loaded {
            guard let d = m.design(f.faceRegionID) else { return "\(m.name(f.faceRegionID).capitalized) is still being designed." }
            if let r = d.refusal { return "\(m.name(f.faceRegionID).capitalized): \(m.text(r.reason))" }
        }
        return nil
    }

    @MainActor
    func testHisProjectAsSavedHasOneThingToFix() async throws {
        let (_, m) = try await his()
        XCTAssertEqual(m.settings.materialID, "varioshore_tpu", "premise: his project as saved")
        XCTAssertEqual(Set(m.settings.loadedFaces.map(\.faceRegionID)),
                       Set([FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]), "premise: the old taps pressed 3 and 5")
        let r = m.readiness
        print("FLEX-READY his project as saved: \(r.blocking.count) blocking — \(r.oneLine) | fixes \(r.blocking.first?.fixes ?? [])")
        XCTAssertEqual(r.blocking.count, 1, "exactly one thing blocks: \(r.blocking.map(\.oneLine))")
        let i = try XCTUnwrap(r.blocking.first)
        XCTAssertEqual(i.kind, .sharedStack)
        XCTAssertEqual(Set([3, 5]), Set([i.region].compactMap { $0 } + i.fixes.compactMap { if case .rest(let x) = $0 { return x } else { return nil } }))
        XCTAssertEqual(i.fixes, [.rest(5), .rest(3)], "[Face 5 rests] [Face 3 rests]")
        XCTAssertEqual(i.fixes.map { $0.title { m.displayName($0) } }, ["Face 5 rests", "Face 3 rests"])
        XCTAssertEqual(r.oneLine, "1 thing to fix: Face 3 and Face 5 press the same material")
        XCTAssertEqual(FlexibleExitDecision.decide(r), .fix(i))
        XCTAssertEqual(FlexibleExitDecision.title(r), "Fix 1 thing")
        XCTAssertLessThanOrEqual(r.oneLine.count, 60, "one line")
    }

    @MainActor
    func testWithTPU95AStillOnlyTheSharedStackBlocks() async throws {
        let (_, m) = try await his(material: "tpu95a_generic")
        let r = m.readiness
        print("FLEX-READY his project, TPU 95A: \(r.blocking.map(\.oneLine)) | info \(r.issues.filter { !$0.blocking }.map(\.oneLine))")
        XCTAssertEqual(r.blocking.map(\.kind), [.sharedStack], "calibrate-first never blocks")
        XCTAssertTrue(r.shapeOnly)
        XCTAssertEqual(r.issues.first { $0.kind == .shapeOnly }?.oneLine, "TPU 95A: shape only — no squish predicted")
        // ★ RED CONTROL: the old gate's ORDER — it said calibrate-first first
        let old = try XCTUnwrap(oldGate(m))
        XCTAssertTrue(old.contains("calibrate-first"), "control: the old gate led with calibrate-first: \(old)")
        XCTAssertNotEqual(old, r.refusal)
    }

    @MainActor
    func testAfterFace5RestsExitBuildsTheLattice() async throws {
        let (_, m) = try await his()
        let fix = try XCTUnwrap(m.readiness.blocking.first?.fixes.first)
        FlexibleFixPopup.apply(fix, to: m)
        try await settle(m)
        let r = m.readiness
        XCTAssertTrue(r.isReady, "nothing blocks after [Face 5 rests]: \(r.blocking.map(\.oneLine))")
        XCTAssertEqual(r.oneLine, FlexibleReadiness.ready)
        XCTAssertEqual(FlexibleExitDecision.decide(r), .exit)
        XCTAssertEqual(FlexibleExitDecision.title(r), "Exit")
        m.generateLattice()
        try await FlexibleHisProject.waitFor(90, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        let g = try XCTUnwrap(m.lattice)
        XCTAssertFalse(g.shapeOnly, "varioShore: a designed lattice")
        print("FLEX-READY varioShore after [Face 5 rests]: lattice of \(g.keys.count) faces, squished \(g.squishedKeys.count)")
    }

    @MainActor
    func testTPU95AExitBuildsAShapeOnlyLattice() async throws {
        let (_, m) = try await his(material: "tpu95a_generic")
        FlexibleFixPopup.apply(.rest(5), to: m)
        try await settle(m)
        XCTAssertTrue(m.readiness.isReady, "\(m.readiness.blocking.map(\.oneLine))")
        XCTAssertTrue(m.designs.isEmpty, "premise: a calibrate-first filament designs nothing")
        m.generateLattice()
        try await FlexibleHisProject.waitFor(90, "the shape-only lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        let g = try XCTUnwrap(m.lattice, "Exit always leaves a lattice — even with no squish data")
        XCTAssertTrue(g.shapeOnly)
        XCTAssertEqual(g.shapeOnlyLabel, "TPU 95A: shape only — no squish predicted")
        // the dent beside it is the drawing, never a prediction
        let shown = FlexibleShownValues(model: m, drawnLattice: g)
        XCTAssertEqual(shown.label, "What you drew")
        print("FLEX-READY TPU 95A shape only: \(g.keys.count) faces, ρ span \(g.inputs.rho.values.min() ?? 0)…\(g.inputs.rho.values.max() ?? 0)")
    }

    // MARK: the rule, on values

    private func face(_ r: Int, kg: Double = 10, design: FlexibleReadiness.DesignState = .ok,
                      stacked: Bool = true, stackError: String? = nil, drawn: Bool = true, area: Double = 100) -> FlexibleReadiness.Face {
        FlexibleReadiness.Face(region: r, weightKg: kg, stacked: stacked, stackError: stackError, design: design,
                               drawn: drawn, areaMM2: area)
    }

    private func inputs(_ faces: [FlexibleReadiness.Face], calibrateFirst: Bool = false,
                        conflicts: [(a: Int, b: Int)] = [], material: String? = "varioshore_tpu",
                        nozzleAuto: Bool = false, gyroid: Bool = false) -> FlexibleReadiness.Inputs {
        FlexibleReadiness.Inputs(materialID: material, materialName: calibrateFirst ? "TPU 95A (Bambu 95A HF)" : "colorFabb varioShore TPU (foaming)",
                                 calibrateFirst: calibrateFirst, withData: (id: "varioshore_tpu", name: "colorFabb varioShore TPU"),
                                 pressed: faces, conflicts: conflicts, nozzleIsAuto: nozzleAuto, topologyIsGyroid: gyroid)
    }

    func testOnlyWhatTrulyStopsALatticeBlocks() {
        // never blocking
        let calib = FlexibleReadiness.evaluate(inputs([face(1, design: .pending)], calibrateFirst: true))
        XCTAssertTrue(calib.isReady); XCTAssertTrue(calib.shapeOnly)
        let seven = FlexibleReadiness.evaluate(inputs((0..<7).map { face($0) }))
        XCTAssertTrue(seven.isReady, "more than four faces never blocks")
        XCTAssertEqual(seven.oneLine, "Ready · Squish shown on the 4 largest of 7 faces")
        let designing = FlexibleReadiness.evaluate(inputs([face(1, design: .pending)]))
        XCTAssertTrue(designing.isReady); XCTAssertTrue(designing.designing)
        // blocking, each with its fix
        let noWeight = FlexibleReadiness.evaluate(inputs([face(1, kg: 0)]))
        XCTAssertEqual(noWeight.blocking.map(\.kind), [.noWeight])
        XCTAssertEqual(noWeight.blocking.first?.fixes.first, .weight(1))
        let noStack = FlexibleReadiness.evaluate(inputs([face(2, stacked: false, stackError: "face 2 has no lattice under it. More text.")]))
        XCTAssertEqual(noStack.blocking.first?.oneLine, "Face 2 can't be squished here: face 2 has no lattice under it")
        XCTAssertEqual(noStack.blocking.first?.fixes, [.rest(2), .remove(2)])
        let refused = FlexibleReadiness.evaluate(inputs([face(3, design: .refused(code: "no_pressure", reason: "an unloaded column."))]))
        XCTAssertEqual(refused.blocking.map(\.kind), [.refused])
        let none = FlexibleReadiness.evaluate(inputs([]))
        XCTAssertEqual(none.blocking.map(\.kind), [.noPressedFace])
        let noFilament = FlexibleReadiness.evaluate(inputs([face(1)], material: nil))
        XCTAssertEqual(noFilament.blocking.first?.fixes, [.pickFilament(id: "varioshore_tpu", name: "colorFabb varioShore TPU")])
        // the shared stack comes before a per-face issue; a pair is said once
        let pair = FlexibleReadiness.evaluate(inputs([face(3), face(5, kg: 0)], conflicts: [(a: 3, b: 5), (a: 5, b: 3)]))
        XCTAssertEqual(pair.blocking.map(\.kind), [.sharedStack, .noWeight])
        XCTAssertEqual(FlexibleExitDecision.title(pair), "Fix 2 things")
    }

    func testTheObviousRefusalsAreFixedSilently() {
        let temp = FlexibleReadiness.evaluate(inputs([face(1, design: .refused(code: "temperature_not_tested", reason: "not tested"))]))
        XCTAssertTrue(temp.isReady)
        XCTAssertEqual(temp.autoFixes.map(\.what), [.temperatureAuto])
        let topo = FlexibleReadiness.evaluate(inputs([face(1, design: .refused(code: "honeycomb_side_stack", reason: "side"))]))
        XCTAssertEqual(topo.autoFixes.map(\.what), [.topologyGyroid])
        // ★ RED CONTROL: with the setting already Auto / Gyroid there is nothing to switch to —
        // the same refusal then BLOCKS (a fix that changes nothing would loop)
        let stuckT = FlexibleReadiness.evaluate(inputs([face(1, design: .refused(code: "temperature_not_tested", reason: "x"))], nozzleAuto: true))
        XCTAssertEqual(stuckT.blocking.map(\.kind), [.refused])
        let stuckG = FlexibleReadiness.evaluate(inputs([face(1, design: .refused(code: "topology_no_data", reason: "x"))], gyroid: true))
        XCTAssertEqual(stuckG.blocking.map(\.kind), [.refused])
    }

    func testThePopUpOpensOnlyOnANewIssueHisActionCaused() {
        let block = FlexibleReadiness.evaluate(inputs([face(3), face(5)], conflicts: [(a: 3, b: 5)]))
        let clear = FlexibleReadiness.evaluate(inputs([face(3)]))
        // opening a project that already has it: its line says so, no pop-up
        var p = FlexibleFixPrompt(actionSerial: 4)
        XCTAssertNil(p.next(block, actionSerial: 4, settled: true), "no action on this visit")
        // noise (a recompute re-reports it) never pops
        XCTAssertNil(p.next(block, actionSerial: 4, settled: true))
        // he rests 5 (action 5) — cleared; he presses 5 again (action 6) — the pop-up opens
        XCTAssertNil(p.next(clear, actionSerial: 5, settled: true))
        XCTAssertEqual(p.next(block, actionSerial: 6, settled: false)?.kind, .sharedStack)
        XCTAssertNil(p.next(block, actionSerial: 6, settled: true), "once")
        // ★ RED CONTROL: a prompt that pops on every evaluation would have popped at open
        var naive = 0
        for r in [block, block, clear, block, block] where !r.isReady { naive += 1 }
        XCTAssertEqual(naive, 4, "control: popping on every blocked evaluation is four pop-ups for one action")
    }

    // MARK: one face's throw no longer stops the next

    func testOneFacesThrowDoesNotStopTheNext() async {
        struct Boom: Error {}
        let design = "designed"
        let r = await FlexibleStageModel.designEach([1, 2, 3], key: { $0 }, cancelled: { false }) { f -> String in
            if f == 1 { throw Boom() }
            return design
        }
        XCTAssertEqual(Set(r.designs.keys), [2, 3], "the faces after the one that threw are designed")
        XCTAssertEqual(Set(r.errors.keys), [1])
        // ★ RED CONTROL: the old single do/catch around the whole loop
        var old: [Int: String] = [:]
        do { for f in [1, 2, 3] { if f == 1 { throw Boom() }; old[f] = design } } catch {}
        XCTAssertTrue(old.isEmpty, "control: one throw left every later face undesigned")
    }

    /// The real pipeline: a pressed face at weight 0 (core: "weight must be > 0") and a good one.
    @MainActor
    func testAFaceAtWeightZeroDoesNotStopTheNextDesign() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let pmProbe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(pmProbe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: 2, weightKg: 0))     // a side, no weight — FIRST
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10))
        let pm = try FlexibleHisProject.padProject(s)
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        try await settle(m)
        let kTop = FlexFaceKey(region: top, rotation: 0), kSide = FlexFaceKey(region: 2, rotation: 0)
        print("FLEX-READY weight 0 first: designs \(m.designs.keys.map(\.region)) errors \(m.designErrors.mapValues { $0.prefix(60) })")
        XCTAssertNotNil(m.designs[kTop], "the face after the weight-0 one is designed")
        XCTAssertNotNil(m.designErrors[kSide], "the weight-0 face keeps core's words")
        XCTAssertEqual(m.readiness.blocking.first?.kind, .noWeight)
        XCTAssertEqual(m.readiness.blocking.first?.fixes.first, .weight(2))
    }

    // MARK: the call sites (memory: value-type tests miss call sites)

    func testThePipelineDesignsEachFaceInItsOwnCatch() throws {
        let model = try FlexibleSource.code("FlexibleStageModel.swift")
        XCTAssertTrue(model.contains("let r = await Self.designEach(faces"), "the pipeline designs each face in its own catch")
        XCTAssertTrue(model.contains("public var latticeRefusal: String? { readiness.refusal }"))
        XCTAssertTrue(model.contains("stackErrors[k] == nil else { return }"), "no blind retry of a face core refused to stack")
    }
}
