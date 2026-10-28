// FlexibleMainStageTests — "Exit always leaves a lattice on the main Flexible page" (task
// 2026-09-29-flexible-screens, round 3 batch B, item 7.1).
//   * Exit with a ready setup ⇒ the main stage's lattice is built and SURVIVES the page: the
//     page only observes the stage's one model. RED CONTROL: a page-owned model (a fresh
//     FlexibleStageModel, what the @StateObject was) has none;
//   * Exit while designs are still in flight ⇒ the lattice builds once they land;
//   * the bottom pill says the one thing to fix (its short form) while something blocks, then
//     "Building…", then "Ready";
//   * the squish never publishes into WorkspacePlaceholder: during a 2 s loop the stage's
//     objectWillChange fires at most twice. RED CONTROL: a stage that publishes the phase
//     fires about 60 times;
//   * previewBakeInputs ignores Flexible edits (H12 — no octet bake under Flexible). RED
//     CONTROL: the settings themselves differ;
//   * more than four pressed faces: walls for all, the squish on the four LARGEST (the pass
//     takes the first four; the dent moves only those). RED CONTROL: build order.
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleMainStageTests: XCTestCase {

    @MainActor
    private func hisStage(material: String? = nil) throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        if let material { r.project.lattice.flexible?.materialID = material }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        return (r, stage, m)
    }

    @MainActor
    func testTheLatticeOutlivesThePage() async throws {
        let (r, stage, m) = try hisStage()
        // the Settings page's own life: open, fix (Face 5 rests), Exit
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        m.rest(5)
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the lattice on the main page") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        XCTAssertNotNil(m.lattice, "Exit built the lattice")
        // the page is gone; the main page asks again — the SAME model, the SAME lattice
        let again = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertTrue(again === m, "one model per project, kept across the page")
        XCTAssertNotNil(again.lattice)
        let layer = stage.layer(r.project, stage: .lattice, pageUp: false)
        XCTAssertNotNil(layer, "the main MetalMeshView gets the lattice")
        XCTAssertEqual(layer?.token, m.lattice?.generation)
        XCTAssertNil(stage.layer(r.project, stage: .topology, pageUp: false), "only on the Flexible lattice stage")
        // ★ RED CONTROL: what the page-owned @StateObject was — a fresh model per page
        let pageOwned = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                           stampsPath: FlexibleHisProject.stampsPath, persist: {})
        XCTAssertNil(pageOwned.lattice, "control: a page-owned model loses the lattice with the page")
    }

    @MainActor
    func testExitWhileDesigningBuildsWhenTheDesignsLand() async throws {
        let (_, stage, m) = try hisStage()
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "the scene") { m.sceneState == .ready }
        m.rest(5)
        // Exit at once — the stacks / designs are still in flight
        let designingAtExit = m.readiness.designing || m.designs.isEmpty
        stage.didExitSettings()
        XCTAssertNil(m.lattice, "premise: nothing built at the moment of Exit")
        try await FlexibleHisProject.waitFor(120, "the lattice after the designs land") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        print("FLEX-MAIN designing at Exit: \(designingAtExit); lattice built: \(m.lattice != nil)")
        XCTAssertTrue(designingAtExit, "premise: the designs were still in flight at Exit")
        XCTAssertNotNil(m.lattice)
    }

    @MainActor
    func testThePillSaysTheReadinessLine() async throws {
        let (_, stage, m) = try hisStage()
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his designs") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } && !m.readiness.designing
        }
        await m.waitForIdle()
        // ★ RE-PINNED (round 4 batch D2): his project as saved no longer blocks — faces 3 and 5
        // are a pinch, which builds. The pill's rule is shown on a blocker he can still make: a
        // face with no weight
        XCTAssertTrue(m.readiness.isReady, "his pinch never blocks")
        m.edit { s in var f = s.face(5)!; f.weightKg = 0; s.setFace(f) }
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(60, "the designs") { !m.readiness.designing }
        let s = stage.status
        XCTAssertEqual(s.tone, .fix)
        // ★ batch B review: the pill's SHORT form (the whole sentence truncated at 11" portrait)
        XCTAssertEqual(s.line, m.readiness.blocking.first?.pill, "the pill says the one thing to fix")
        XCTAssertEqual(s.line, "Fix: the weight on Face 5")
        XCTAssertEqual(s.fix?.kind, .noWeight)
        stage.openFix()
        XCTAssertEqual(m.pendingFix?.kind, .noWeight, "a tap opens Settings on that fix")
        m.setWeight(5, kg: 10)
        stage.didExitSettings()
        XCTAssertEqual(stage.status.line, FlexibleMainStatus.building)
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        // ★ RE-PINNED (round 4 C2 verification): faces 3 and 5 pinch again — the preview is built,
        // but core can't take a pinch yet, so the pill is a PREVIEW, never the green Ready (a tap
        // opens the Export step on each end resting — FlexibleCoreHold)
        XCTAssertEqual(stage.status.line, FlexibleCoreHold.pill(.pinch, shapeOnlyLabel: nil))
        XCTAssertEqual(stage.status.tone, .preview)
        XCTAssertEqual(FlexibleMainStatus.of(model: nil).line, FlexibleMainStatus.notOpened, "before the stage ever opened")
    }

    /// TPU 95A: the pill carries his words for the shape-only lattice.
    @MainActor
    func testThePillSaysShapeOnlyForACalibrateFirstFilament() async throws {
        let (_, stage, m) = try hisStage(material: "tpu95a_generic")
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        m.rest(5)
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the shape-only lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertEqual(stage.status.line, "TPU 95A: shape only — no squish predicted")
        // ★ RE-PINNED (round 4 C2 verification): his label, on a PREVIEW pill — core refuses a
        // calibrate-first filament, so it is never the green Ready
        XCTAssertEqual(stage.status.tone, .preview)
    }

    // MARK: the loop never publishes into the workspace

    @MainActor
    func testTheSquishLoopDoesNotPublish() {
        let stage = FlexibleMainStage()
        var t: CFTimeInterval = 100
        stage.loop.clock = { t }
        var fired = 0
        let c = stage.objectWillChange.sink { _ in fired += 1 }
        stage.loop.exaggeration = 4
        stage.loop.play()
        var scales: [Float] = []
        for _ in 0..<60 {     // 2 s at 30 fps — the renderer's steps
            t += 1.0 / 30.0
            scales.append(stage.loop.scale(at: t))
        }
        c.cancel()
        print("FLEX-MAIN 2 s loop: stage publishes \(fired), scale \(scales.min()!)…\(scales.max()!)")
        XCTAssertLessThanOrEqual(fired, 2, "the squish is stepped by the renderer, not published")
        XCTAssertGreaterThan(scales.max()! - scales.min()!, 3, "…and it moved (k = 4)")
        // ★ RED CONTROL: a stage that publishes the phase (the old page's 30 fps @State)
        final class Publishing: ObservableObject { @Published var phase = 0.0 }
        let p = Publishing()
        var redFired = 0
        let c2 = p.objectWillChange.sink { _ in redFired += 1 }
        for i in 0..<60 { p.phase = Double(i) / 60 }
        c2.cancel()
        XCTAssertGreaterThanOrEqual(redFired, 55, "control: publishing the phase fires ~60 times")
    }

    // MARK: H12 — no octet bake under Flexible

    func testPreviewBakeInputsIgnoreFlexibleEdits() {
        var s = LatticeSettings()
        s.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        let before = s.previewBakeInputs
        s.flexible?.setFace(FlexibleFaceSettings(faceRegionID: 3, weightKg: 12))
        XCTAssertEqual(s.previewBakeInputs, before, "a Flexible edit must not re-key the octet bake")
        // ★ RED CONTROL: the edit is real — without H12 the bake key moves
        var raw = s; var rawBefore = LatticeSettings(); rawBefore.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        raw.selectableWallCoreDead = [:]; raw.organicForecast = nil
        rawBefore.selectableWallCoreDead = [:]; rawBefore.organicForecast = nil
        XCTAssertNotEqual(raw, rawBefore, "control: the settings themselves differ")
    }

    // MARK: more than four faces

    func testMoreThanFourFacesSquishTheFourLargest() {
        let faces: [(key: Int, areaMM2: Double)] = [(1, 50), (2, 400), (3, 120), (4, 900), (5, 80), (6, 300), (7, 10)]
        let order = FlexibleStageModel.squishOrder(faces)
        XCTAssertEqual(order, [4, 2, 6, 3, 5, 1, 7], "largest first")
        XCTAssertEqual(Array(order.prefix(FlexibleSquishField.maxFaces)), [4, 2, 6, 3], "the four largest squish")
        // ★ RED CONTROL: the order faces were pressed in squishes 1, 2, 3, 4 — face 6 (300 mm²)
        // would hold still while face 1 (50 mm²) moved
        XCTAssertNotEqual(Array(faces.map(\.key).prefix(4)), Array(order.prefix(4)))
        // the readiness never blocks on the count
        let r = FlexibleReadiness.evaluate(FlexibleReadiness.Inputs(
            materialID: "varioshore_tpu", materialName: "varioShore", calibrateFirst: false, withData: nil,
            pressed: faces.map { FlexibleReadiness.Face(region: $0.key, weightKg: 10, stacked: true, design: .ok, areaMM2: $0.areaMM2) }))
        XCTAssertTrue(r.isReady)
    }

    /// With a lattice drawn, only the squished faces dent (his project, a lattice that squishes
    /// top A alone): top B's quads hold still.
    @MainActor
    func testOnlyTheSquishedFacesDent() async throws {
        let (_, _, m) = try hisStage()
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "stacks") { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil } }
        m.rest(5)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(60, "designs") { !m.readiness.designing }
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        let g = try XCTUnwrap(m.lattice)
        let a = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0), b = FlexFaceKey(region: FlexibleHisProject.topB, rotation: 0)
        let only = FlexibleGeneratedLattice(inputs: g.inputs, faces: g.faces, keys: g.keys, columnDepths: g.columnDepths,
                                            columnNoLattice: g.columnNoLattice, extentMM: g.extentMM, generation: g.generation,
                                            topology: g.topology, tempC: g.tempC, settingsKey: g.settingsKey, squishedKeys: [a])
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let all = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: g)
        let one = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: only)
        func moved(_ d: [Float]?, _ k: FlexFaceKey) -> Int {
            guard let d, let start = overlay.flatStart[k], let st = m.stacks[k] else { return 0 }
            var n = 0
            for v in start..<(start + st.columns.count * 6) {
                let x: Float = abs(d[v * 3]), y: Float = abs(d[v * 3 + 1]), z: Float = abs(d[v * 3 + 2])
                if x + y + z > 1e-6 { n += 1 }
            }
            return n
        }
        print("FLEX-MAIN dented quad vertices: all squished A \(moved(all.dents, a)) B \(moved(all.dents, b)) | only A: A \(moved(one.dents, a)) B \(moved(one.dents, b))")
        XCTAssertGreaterThan(moved(one.dents, a), 0)
        XCTAssertEqual(moved(one.dents, b), 0, "a face whose squish is not shown holds still")
        // ★ RED CONTROL: with every face squished, top B moves
        XCTAssertGreaterThan(moved(all.dents, b), 0, "control: top B dents when it is squished")
    }
}
