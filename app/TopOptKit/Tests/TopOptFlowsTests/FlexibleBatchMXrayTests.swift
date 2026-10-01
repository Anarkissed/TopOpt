// FlexibleBatchMXrayTests — his round-5 M6 (img 6): "When the dent view is selected, the xray view
// should also initiate (that's why there is no point to include the actual button), showing the
// lattice (if selected) as a ghost and the dents bending through the ghosts. Get rid of the stripes
// and make it solid." — task 2026-09-29-flexible-screens, round 5 batch M.
//   * the dent view turns X-ray on (the body a ghost) even with the lattice hidden; with the lattice
//     shown its walls are ghosts too — RED: C2's rule (X-ray = the Lattice view);
//   * THE STRIPES: the walls' cut faces at the part's surface, drawn opaque by #354's lsdf_shade with
//     depth, won the depth test over the 0.05 mm-lifted dent plane in rows (his img 6) — now the walls
//     are a ghost with no depth and the solid plane covers them: on his project's top view the map's
//     pixels are the same with the lattice shown as hidden — RED: the opaque walls (the old frame).
//     ★ RE-PINNED (batch M verification): the NEAR planes' interior only — a FAR plane (seen through the
//     part) now shows the ghost walls in front of it, as it must (FlexibleBatchMVerifyTests); and the
//     control is the old frame in full: the opaque walls WITHOUT the planes' depth in the G-buffer.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMXrayTests: XCTestCase {

    func round5() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (r, stage, m)
    }

    func testTheDentViewTurnsXRayOnAndGhostsTheWalls() async throws {
        let (r, stage, _) = try await round5()
        let pm = r.project
        func layer() -> FlexibleLatticeLayerInputs? { stage.layer(pm, stage: .lattice, pageUp: false) }
        // the defaults: Dent heat and Lattice on — the body a ghost, the walls a ghost, the planes solid
        XCTAssertTrue(stage.heat && stage.latticeShown)
        XCTAssertTrue(stage.xray && stage.ghostWalls)
        XCTAssertEqual(layer()?.ghostWalls, true)
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), FlexibleStagePage.xrayBodyAlpha)
        // the lattice hidden: the DENT view keeps X-ray (the planes bend through the ghost body)
        stage.toggleLattice(); stage.refresh()
        XCTAssertFalse(stage.latticeShown)
        XCTAssertTrue(stage.xray, "the dent view initiates X-ray")
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), FlexibleStagePage.xrayBodyAlpha)
        XCTAssertEqual(layer()?.hidden, true, "no walls")
        // ★ RED CONTROL: C2's rule (X-ray IS the Lattice view) left the body solid here
        XCTAssertFalse(stage.latticeShown, "control: C2's X-ray (= the Lattice view) would be off")
        // Dent heat off (Stress on — the two never on together): the lattice decides alone
        stage.toggleStress(); stage.refresh()
        XCTAssertFalse(stage.heat)
        XCTAssertFalse(stage.xray, "no dent, no lattice: the solid part")
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), 1)
        stage.toggleLattice(); stage.refresh()
        XCTAssertTrue(stage.xray && stage.latticeShown)
        XCTAssertFalse(stage.ghostWalls, "Stress: the walls are drawn solid (in its colours)")
        XCTAssertEqual(layer()?.ghostWalls, false)
        // the renderer: the ghost walls replace #354's opaque shade only while asked
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try XCTUnwrap(stage.mesh(pm, on: .lattice)))
        mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
        mr.applyFlexibleLattice(layer(), device: device)
        XCTAssertFalse(mr.flexibleWallsGhosted)
        stage.toggleHeat(); stage.refresh()
        mr.applyFlexibleLattice(layer(), device: device)
        XCTAssertTrue(mr.flexibleWallsGhosted, "the dent view: the walls are drawn as a ghost")
        // the two hook lines in #354's MetalMeshView
        let mv = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("if wantsLattice, !flexibleWallsGhosted, let lpipe = latticeShadePipeline, let gb = gbuffer {"))
        let ghostLine = "if wantsLattice, flexibleWallsGhosted, let gb = gbuffer { encodeFlexibleGhostWalls(enc, gbuffer: gb, mainSize: mainSize) }"
        XCTAssertEqual(mv.components(separatedBy: ghostLine).count, 2, "one ghost-walls hook")
        // ★ BATCH M VERIFICATION: drawn AFTER the see-through body (a far plane painted over them before it)
        let body = try XCTUnwrap(mv.range(of: "countedDraw(enc, .triangle, vertexDrawCount) }\n"), "the see-through body's draw")
        XCTAssertGreaterThan(try XCTUnwrap(mv.range(of: ghostLine)).lowerBound, body.lowerBound, "the ghost walls come after the body")
        // …and the solid planes' depth is in the G-buffer before the march
        let mapDepth = try XCTUnwrap(mv.range(of: "encodeFlexibleMapDepth(penc, depthState: depthState, vertices: vbuf, flex: fbuf, tints: tintBuffer, count: vertexDrawCount, clipFromModel: uniforms.mvp, squish: flexScale)"))
        XCTAssertLessThan(mapDepth.lowerBound, try XCTUnwrap(mv.range(of: "fx.encodeGBuffer(penc, depthState: depthState")).lowerBound)
    }

    /// One frame of what the stage hands MetalMeshView (MSAA 4×, X-ray), at `amount` of the page's ×k.
    static func frame(_ stage: FlexibleMainStage, _ pm: ProjectModel, layer: FlexibleLatticeLayerInputs?, tints: [Float]? = nil,
                      amount: Float, view: (Float, Float), size: Int = 640,
                      configure: (FlexibleLatticePass) -> Void = { _ in }) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try XCTUnwrap(stage.mesh(pm, on: .lattice)))
        let settle = pm.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.0, elevation: view.1)
        if let t = tints ?? stage.tints(pm, on: .lattice, roles: [:], stress: nil) { mr.setVertexTints(t) }
        mr.setBodyAlpha(stage.bodyAlpha(pm, on: .lattice) ?? 1)
        mr.applyFlexibleLattice(layer, device: device)
        if let pass = mr.flexibleLattice { configure(pass) }
        if let l = layer, !l.feSequence.isEmpty, let pass = mr.flexibleLattice {
            pass.bindFE(l.feSequence[0])
            mr.setFlexDisplacements(l.feMesh[l.feSequence[0]])
        }
        mr.setFlexScale(Float(stage.channels?.exaggeration ?? 1) * amount)
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    func testTheSolidDentPlaneIsNeverStripedByTheWalls() async throws {
        let (r, stage, m) = try await round5()
        let pm = r.project
        stage.pick("group-1"); stage.refresh()
        let size = 640
        for view: (String, Float, Float) in [("top", .pi / 5, 1.2), ("iso", .pi / 4, .pi / 6)] {
            let v = (view.1, view.2)
            let lattice = try XCTUnwrap(stage.layer(pm, stage: .lattice, pageUp: false))
            XCTAssertTrue(lattice.ghostWalls)
            var hiddenLayer = lattice; hiddenLayer.hidden = true
            var opaqueLayer = lattice; opaqueLayer.ghostWalls = false   // ★ RED: the walls drawn as before
            let withWalls = try Self.frame(stage, pm, layer: lattice, amount: 1, view: v, size: size)
            let noWalls = try Self.frame(stage, pm, layer: hiddenLayer, amount: 1, view: v, size: size)
            let opaque = try Self.frame(stage, pm, layer: opaqueLayer, amount: 1, view: v, size: size) { $0.controlNoMapDepth = true }
            // ★ RE-PINNED (verification): the NEAR planes only (seen with the body solid)
            let near = Set(try FlexibleBatchMVerifyTests.mapPixels(stage, pm, m, layer: lattice, view: v, size: size).near)
            // the map's pixels: a frame with the map's quads painted a flat key colour, no walls
            var key = try XCTUnwrap(stage.tints(pm, on: .lattice, roles: [:], stress: nil))
            let o = try XCTUnwrap(stage.overlay)
            for (k, start) in o.flatStart {
                guard let st = m.stacks[k] else { continue }
                for vtx in start..<(start + 6 * st.columns.count) where key[vtx * 8 + 5] > 0.5 {
                    key[vtx * 8] = 0; key[vtx * 8 + 1] = 1; key[vtx * 8 + 2] = 0
                }
            }
            let keyed = try Self.frame(stage, pm, layer: hiddenLayer, tints: key, amount: 1, view: v, size: size)
            // the map's INTERIOR pixels (2 px in from its outline: the outline's MSAA samples blend whatever
            // lies behind, which is antialiasing, not a stripe)
            func keyedAt(_ x: Int, _ y: Int) -> Bool {
                guard x >= 0, y >= 0, x < size, y < size else { return false }
                let p = y * size + x
                let b = Int(keyed[4 * p]), g = Int(keyed[4 * p + 1]), rr = Int(keyed[4 * p + 2])   // BGRA
                return g > 90 && g > 2 * rr && g > 2 * b
            }
            func interior(_ p: Int) -> Bool {
                guard near.contains(p) else { return false }
                let x = p % size, y = p / size
                for dy in -2...2 { for dx in -2...2 where !keyedAt(x + dx, y + dy) { return false } }
                return true
            }
            var mapPx = 0, striped = 0, stripedOld = 0
            for p in 0..<(size * size) {
                guard interior(p) else { continue }
                mapPx += 1
                func diff(_ a: [UInt8]) -> Int { (0..<3).map { abs(Int(a[4 * p + $0]) - Int(noWalls[4 * p + $0])) }.max()! }
                if diff(withWalls) > 20 { striped += 1 }
                if diff(opaque) > 20 { stripedOld += 1 }
            }
            if let d = ProcessInfo.processInfo.environment["FLEX_M_PROBE_DIR"] {
                let dir = URL(fileURLWithPath: d, isDirectory: true)
                try FlexibleLatticeEvidenceProbe.writeBGRA(withWalls, size: size, to: dir.appendingPathComponent("M_stripes_\(view.0)_ghost.png"))
                try FlexibleLatticeEvidenceProbe.writeBGRA(noWalls, size: size, to: dir.appendingPathComponent("M_stripes_\(view.0)_nowalls.png"))
                try FlexibleLatticeEvidenceProbe.writeBGRA(opaque, size: size, to: dir.appendingPathComponent("M_stripes_\(view.0)_opaque.png"))
                var diff = [UInt8](repeating: 0, count: size * size * 4)
                for p in 0..<(size * size) {
                    let inMap = interior(p)
                    let dd = (0..<3).map { abs(Int(withWalls[4 * p + $0]) - Int(noWalls[4 * p + $0])) }.max()!
                    diff[4 * p + 1] = inMap ? 60 : 0
                    if inMap && dd > 20 { diff[4 * p + 2] = 255; diff[4 * p + 1] = 255; diff[4 * p] = 255 }
                }
                try FlexibleLatticeEvidenceProbe.writeBGRA(diff, size: size, to: dir.appendingPathComponent("M_stripes_\(view.0)_diff.png"))
            }
            print(String(format: "FLEX-M STRIPES %@: the solid map covers %d px · walls through it: ghost %d (%.2f%%) · the old opaque walls %d (%.1f%%)",
                         view.0, mapPx, striped, 100 * Double(striped) / Double(max(1, mapPx)), stripedOld, 100 * Double(stripedOld) / Double(max(1, mapPx))))
            XCTAssertGreaterThan(mapPx, 20_000, "\(view.0): the map is on screen")
            XCTAssertLessThan(Double(striped) / Double(mapPx), 0.002, "\(view.0): nothing of the walls shows through the solid plane")
            XCTAssertGreaterThan(Double(stripedOld) / Double(mapPx), 0.01, "\(view.0): control: the opaque walls striped the plane")
            // the ghost walls ARE drawn (outside the map): the frame differs from the hidden one there
            var ghostPx = 0
            for p in 0..<(size * size) where (0..<3).map({ abs(Int(withWalls[4 * p + $0]) - Int(noWalls[4 * p + $0])) }).max()! > 6 { ghostPx += 1 }
            XCTAssertGreaterThan(ghostPx, 2_000, "\(view.0): the walls are there, as a ghost")
        }
    }
}
#endif
