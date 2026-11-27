// FlexiblePictureParityTests — ★ notes30 FF1 (the Flexible page's picture made off the main thread): the picture the WORKER
// makes (FlexiblePictureWorker: its own thread, from the values gathered on main) is the picture today's refresh made on the
// main thread, BIT FOR BIT — the overlay's tints and dent, the exaggeration, the heat values, each field's mesh, the walls' heat,
// "Play all"'s colours, the composed H4' tints and each field version's GPU bytes (FlexibleLatticePass.makeFieldTexture's packing
// and its half-rounded field). "Today's" is made here, on main, from the live model by the page's own main-actor functions
// (FlexiblePageChannels.channels(model:), FlexibleShownValues(model:), feMesh / feHeat / playAllBaseTints / makeWallHeat, the
// H4' compose inline) — so a value the gather forgot to carry shows as a difference. The same job made inline (on main) is the
// worker's too. On C1's pad (a squeeze group, its quick sim landed, no refine), with Heat, then with Stress.
// RED CONTROL `FlexiblePictureEngine.controlDropStep` ("tints": the overlay's tints dropped): the parity catches it.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePictureParityTests: XCTestCase {

    /// C1's pad, its top pressed (30 kg) and its bottom resting (FlexibleBatchNVerifyTests' pad), its quick sim landed, no refine.
    func pad() async throws -> (FlexibleMainStage, FlexibleStageModel, ProjectModel) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = true
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
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (stage, m, pm)
    }

    /// Today's refresh's picture, made HERE on main from the live model, by the page's own main-actor functions.
    struct Today {
        var channels: FlexiblePageChannels.Channels
        var dentMaxMM: Double
        var meshes: [[Float]]
        var playAll: [String: [Float]]
        var walls: FlexibleWallHeat?
        var composed: [Float]?
        var composedPer: [String: [Float]]
        var gpu: [FlexibleFEGPUField?]
        var lattice: FlexibleLatticeGPU?
    }

    func today(_ s: FlexibleMainStage, _ m: FlexibleStageModel, _ pm: ProjectModel) -> Today {
        s.feMeshCache = [:]; s.feValueCache = [:]; s.feColumnCache = [:]; s.feStressCache = [:]; s.openCache = nil
        let drawn = s.drawn
        let meshes = s.fe.fields.map { s.feMesh(for: $0) }
        let feNow = s.feHeat(m)
        let latticeHeat = m.facePrismsSet && (drawn != nil || feNow != nil || FlexibleMainStage.controlDrawnCurveOnMain)
        let pressHeat = s.heat && latticeHeat ? FlexiblePressHeat.entries(model: m, groups: s.mainPressHeatGroups) : []
        var c = FlexiblePageChannels.channels(model: m, overlay: s.overlay, xray: false, drawnLattice: drawn, heat: s.heat && latticeHeat,
                                              depthScaleMM: pressHeat.isEmpty ? feNow?.scaleMM
                                                : feNow.map { Swift.max($0.scaleMM, FlexiblePressHeat.top(pressHeat)) },
                                              mapValues: feNow?.first, controlColumnColours: s.controlColumnHeat, groupColours: false,
                                              roleMarks: s.controlRolesOnMain, pressHeat: pressHeat)
        if !latticeHeat { c.dents = nil; c.exaggeration = 0; c.mapValues = nil }
        let shown = FlexibleShownValues(model: m, drawnLattice: drawn)
        let dentMax = latticeHeat ? (pressHeat.isEmpty ? (feNow?.scaleMM ?? shown.maxDepth) : c.heatScaleMM) : 0
        let playAll = s.playAllBaseTints(m, scaleMM: dentMax, nextScaleMM: feNow?.nextScaleMM)
        let walls = s.makeWallHeat(m, shown: shown)
        if s.fe.active {
            c.exaggeration = FlexibleShownValues.cappedExaggeration(rule: shown.uncappedExaggeration, maxSafeScale: s.fe.safeScale)
            let i = s.feShownIndex(s.fe)
            c.dents = i < meshes.count ? meshes[i] : nil
        }
        // today's H4' compose, inline in the body's call
        let wasInline = FlexiblePictureWorker.inline
        FlexiblePictureWorker.inline = true
        s.composedKey = nil
        _ = s.tints(pm, on: .lattice, roles: [:], stress: nil)
        FlexiblePictureWorker.inline = wasInline
        // today's GPU bytes: FlexibleLatticePass.makeFieldTexture's packing, its stress made here
        let gpu = s.fe.fields.map { FlexibleFEGPUField.make($0) }
        // today's lattice upload's CPU half (the pass's own, on main)
        let lattice = m.lattice.map { FlexibleLatticePass.prepare($0.inputs, generation: $0.generation) }
        return Today(channels: c, dentMaxMM: dentMax, meshes: meshes, playAll: playAll, walls: walls,
                     composed: s.composed, composedPer: s.feTintBox.bySim, gpu: gpu, lattice: lattice)
    }

    /// The picture the next refresh makes — on the worker (`inline` false) or on main — as handed to the commit.
    func picture(_ s: FlexibleMainStage, inline: Bool) async throws -> FlexiblePicture {
        let wasInline = FlexiblePictureWorker.inline
        defer { FlexiblePictureWorker.inline = wasInline; s.onPictureForTests = nil }
        FlexiblePictureWorker.inline = inline
        s.pictureEngine.forget()   // everything made again
        var got: FlexiblePicture?
        var onMain = false
        // this refresh's job (or a newer one that replaced it) — never a picture still on its way from before
        let mine = s.pictureSerial + 1
        s.onPictureForTests = { p in if got == nil, p.serial >= mine { got = p; onMain = Thread.isMainThread } }
        s.refresh()
        let end = Date().addingTimeInterval(180)
        while got == nil, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(onMain, "the picture is committed on the main thread")
        return try XCTUnwrap(got, "a picture (inline \(inline))")
    }

    static func bits(_ a: [Float]?) -> [UInt32]? { a?.map(\.bitPattern) }

    /// Every difference between the worker's picture and today's (empty: bit for bit).
    func differences(_ w: FlexiblePicture, _ t: Today) -> [String] {
        var out: [String] = []
        func same(_ what: String, _ a: [Float]?, _ b: [Float]?) { if Self.bits(a) != Self.bits(b) { out.append(what) } }
        same("the tints", w.channels.tints, t.channels.tints)
        same("the dent", w.channels.dents, t.channels.dents)
        same("the heat values", w.channels.mapValues, t.channels.mapValues)
        if w.channels.exaggeration != t.channels.exaggeration { out.append("the exaggeration") }
        if w.channels.heatScaleMM.bitPattern != t.channels.heatScaleMM.bitPattern { out.append("the heat's scale") }
        if w.channels.legendLine != t.channels.legendLine { out.append("the legend line") }
        if w.channels.animated != t.channels.animated { out.append("animated") }
        if w.dentMaxMM.bitPattern != t.dentMaxMM.bitPattern { out.append("the legend's top") }
        if w.fe.mesh.map({ $0.map(\.bitPattern) }) != t.meshes.map({ $0.map(\.bitPattern) }) { out.append("the fields' meshes") }
        if w.feBaseTints.mapValues({ $0.map(\.bitPattern) }) != t.playAll.mapValues({ $0.map(\.bitPattern) }) { out.append("Play all's colours") }
        if w.wallHeat?.token != t.walls?.token || w.wallHeat?.cells.map({ $0.map(\.bitPattern) }) != t.walls?.cells.map({ $0.map(\.bitPattern) }) {
            out.append("the walls' heat")
        }
        same("the composed tints", w.composed, t.composed)
        if w.composedPer.mapValues({ $0.map(\.bitPattern) }) != t.composedPer.mapValues({ $0.map(\.bitPattern) }) { out.append("each version's tints") }
        if w.gpu.map({ $0?.packed }) != t.gpu.map({ $0?.packed }) { out.append("the GPU bytes") }
        if w.gpu.map({ $0?.halfRounded.u.map { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] } })
            != t.gpu.map({ $0?.halfRounded.u.map { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] } }) {
            out.append("the half-rounded fields")
        }
        if w.latticeGPU?.rm?.bytes.map(\.bitPattern) != t.lattice?.rm?.bytes.map(\.bitPattern) || w.latticeGPU?.ds?.bytes != t.lattice?.ds?.bytes
            || w.latticeGPU?.regionMin != t.lattice?.regionMin || w.latticeGPU?.regionMax != t.lattice?.regionMax
            || w.latticeGPU?.rhoSpan != t.lattice?.rhoSpan || w.latticeGPU?.generation != t.lattice?.generation {
            out.append("the lattice's volumes")
        }
        return out
    }

    func testTheWorkersPictureIsTodaysBitForBit() async throws {
        let (s, m, pm) = try await pad()
        XCTAssertTrue(s.fe.active, "premise: the pad's field plays (FE route)")
        var report: [String] = []
        for view in ["Heat", "Stress"] {
            if view == "Stress" { s.toggleStress(); s.refresh() }
            let worker = try await picture(s, inline: false)
            let inline = try await picture(s, inline: true)
            let t = today(s, m, pm)
            XCTAssertNotNil(worker.channels.tints, "premise \(view): tints made")
            XCTAssertFalse(worker.gpu.isEmpty, "premise \(view): a field's GPU bytes")
            if view == "Stress" { XCTAssertTrue(s.stress, "premise: Stress on (drawable: \(s.stressDrawable))") }
            let dWorker = differences(worker, t), dInline = differences(inline, t)
            XCTAssertEqual(dWorker, [], "★ \(view): the worker's picture is today's, bit for bit")
            XCTAssertEqual(dInline, [], "★ \(view): the same job made on main is today's too")
            XCTAssertEqual(worker.key, inline.key, "★ \(view): what is drawn, the same key")
            report.append("\(view) (heat \(s.heat), stress \(s.stress), stress drawn \(s.stressDrawable)): worker vs today \(dWorker.isEmpty ? "identical" : dWorker.joined(separator: ", ")); inline vs today \(dInline.isEmpty ? "identical" : dInline.joined(separator: ", ")); \(worker.fe.fields.count) field(s), \(worker.channels.tints?.count ?? 0) tint floats")
        }
        // RED CONTROL: a step dropped is caught
        FlexiblePictureEngine.controlDropStep = "tints"
        defer { FlexiblePictureEngine.controlDropStep = nil }
        let dropped = try await picture(s, inline: false)
        FlexiblePictureEngine.controlDropStep = nil
        let dRed = differences(dropped, today(s, m, pm))
        XCTAssertTrue(dRed.contains("the tints"), "★ RED (the overlay's tints dropped): the parity sees it — \(dRed)")
        report.append("RED control (the tints dropped): \(dRed.joined(separator: ", "))")
        for l in report { print("FF1 PARITY \(l)") }
    }
}
#endif
