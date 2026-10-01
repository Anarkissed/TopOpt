// FlexibleBatchMVerifyTests — the batch M verification's findings, fixed (task 2026-09-29-flexible-screens,
// round 5 batch M verification). Each with the control that goes RED on the code as batch M left it.
//   * STRESS ROUTE: Save & Exit after an edit (the old lattice stale, the new one building), a main-page edit
//     and a solve held back behind a sim never ask the SOLID part's solve while the page has squeeze groups;
//     the row keeps the groups' words ("each group in turn" while Play all's sims run) — RED: batch M's route
//     (a FRESH lattice only: 3 solid solves on his project, "Stress in the solid part"), its words.
//   * STRESS SCALE: each group's field on ITS OWN scale, topped at its 95th percentile — on his part under 55 %
//     of the part the bottom colour for Group 1, Group 2 and each "Play all" turn, about 5 % in the last; the
//     row names the turn and its "≥ x MPa" — RED: one scale at the sequence's peak (98 % the bottom colour).
//   * THE DENT'S "×k": what the map is DRAWN at against the mm it is coloured by (the fold cut) — RED: "×1".
//   * THE COLUMN FALLBACK keeps the dent view's body solid (a failed sim: core's per-column planes cross) —
//     RED: batch M's X-ray there.
//   * DEPTH ORDER: a far plane seen through the part shows the ghost walls in front of it; a near plane is
//     never striped by the walls behind it, in the dent view (ghost walls) or the Stress view (opaque walls)
//     — RED: the planes' depth left out of the G-buffer.
//   * THE FOLDED CARD is the octet's minimised key: on the very edge, 18 × 150 pt bars 30 pt apart.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMVerifyTests: XCTestCase {

    static var probeDir: URL? {
        ProcessInfo.processInfo.environment["FLEX_M_PROBE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func round5(failing: Set<String> = []) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlFailSimIDs = failing
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

    // MARK: the Stress route — never the solid solve while the page has squeeze groups

    func testStressNeverAsksTheSolidSolveAcrossSaveAndExitAnEditAndARebuild() async throws {
        let (_, stage, m) = try await round5()
        var calls = 0
        stage.stressSolver = { calls += 1 }
        stage.toggleStress(); stage.refresh()
        XCTAssertTrue(stage.feStressRoute)
        let allTitle = "Stress · each group in turn · MPa"
        XCTAssertEqual(stage.legendTitle(.stress), allTitle, "premise: Play all, its sims landed")
        // an edit in Settings, then Save & Exit: the old lattice stale, the new one building
        let g0 = try XCTUnwrap(m.lattice?.generation)
        m.setWeight(5, kg: 12)
        stage.didExitSettings()
        XCTAssertTrue(m.latticeIsStale || m.latticeBuilding, "premise: the lattice is not current")
        var seen: [String] = []
        func note(_ tag: String) {
            stage.refresh()
            let t = "\(tag): route \(stage.feStressRoute ? "groups" : "SOLID") · \(stage.legendTitle(.stress)) · \(stage.stressLine ?? "draws")"
            if seen.last.map({ !$0.hasSuffix(t.components(separatedBy: ": ").dropFirst().joined(separator: ": ")) }) ?? true { seen.append(t) }
        }
        note("Save & Exit")
        XCTAssertTrue(stage.feStressRoute, "the lattice rebuilds: Stress stays the groups' sims")
        XCTAssertEqual(stage.legendTitle(.stress), allTitle, "…in the groups' words, never 'Stress in the solid part'")
        XCTAssertEqual(stage.stressLine, FlexibleStressState.running.line, "Simulating… (the new sims follow the lattice)")
        // a main-page edit while Stress shows (projectChanged asks again)
        stage.projectChanged()
        note("a main-page edit")
        try await FlexibleHisProject.waitFor(300, "the rebuild") {
            note("rebuilding")
            return (m.lattice?.generation ?? g0) > g0 && !m.latticeIsStale && !m.latticeBuilding
        }
        note("rebuilt")
        // the new sims run: Play all is still Play all (batch M read 'Group 1' here)
        let pendingTitle = stage.legendTitle(.stress)
        let simsRunning = m.squish.values.contains(.pending)
        stage.controlStressWordsByActiveOnly = true
        let oldWords = stage.legendTitle(.stress)
        stage.controlStressWordsByActiveOnly = false
        try await FlexibleHisProject.waitFor(300, "the new sims") {
            note("simulating")
            return !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        note("sims landed")
        // a solve that waited behind a sim: re-checked, never started on the groups' route
        stage.stressWaiting = true
        stage.squishIdle()
        for s in seen { print("FLEX-MV ROUTE \(s)") }
        print("FLEX-MV ROUTE sims running \(simsRunning): title '\(pendingTitle)' (batch M's words: '\(oldWords)') · solid solves asked \(calls)")
        XCTAssertEqual(calls, 0, "the solid part's solve is never asked while the page has squeeze groups")
        XCTAssertFalse(seen.contains { $0.contains("SOLID") || $0.contains("solid part") }, "never the solid part's row")
        if simsRunning {
            XCTAssertEqual(pendingTitle, allTitle, "Play all while its sims run")
            XCTAssertEqual(oldWords, "Stress · Group 1 · MPa", "control: batch M's words named Group 1 then")
        }
        // ★ RED CONTROL: batch M's route (a FRESH lattice only) — the same Save & Exit asks the solid solve
        stage.controlStressRouteNeedsFreshLattice = true
        m.setWeight(5, kg: 13)
        stage.didExitSettings()
        let afterExit = calls
        stage.stressWaiting = true
        stage.squishIdle()
        print("FLEX-MV ROUTE control (batch M's route): solid solves asked on Save & Exit \(afterExit) · after a held-back solve \(calls) · row '\(stage.legendTitle(.stress))'")
        XCTAssertGreaterThan(afterExit, 0, "control: batch M's route asked the solid solve on Save & Exit")
        XCTAssertGreaterThan(calls, afterExit, "control: …and again when a held-back solve was let go")
        XCTAssertEqual(stage.legendTitle(.stress), FlexibleReadKind.stress.title, "control: …and the row said 'the solid part'")
        stage.controlStressRouteNeedsFreshLattice = false
        await m.waitForIdle()
    }

    // MARK: the Stress scale — each group's own, so the part is not one colour

    /// The share of the part's vertices in each fifth of the ramp, as the colours are drawn (v / top).
    /// …and, as a sixth entry, the share at or above the top (the last colour, saturated).
    static func fifths(_ stage: FlexibleMainStage, _ o: FlexibleOverlayMesh, field: LatticeDemandField, top: Double) -> [Double] {
        let pos = o.mesh.flat.positions
        var bins = [Int](repeating: 0, count: 5), n = 0, sat = 0
        for v in stride(from: 0, to: o.partFlatVertices, by: 3) {
            let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            guard let s = FlexibleProbe.stress(field, at: p) else { continue }
            bins[min(4, Int(min(1, s / top) * 5))] += 1; n += 1
            if s >= top { sat += 1 }
        }
        return (bins + [sat]).map { Double($0) / Double(max(1, n)) }
    }

    func testEachGroupsStressIsOnItsOwnScaleAndThePartIsNotOneColour() async throws {
        let (r, stage, m) = try await round5()
        let o = try XCTUnwrap(stage.overlay)
        stage.toggleStress()
        func pct(_ f: [Double]) -> String {
            f.prefix(5).map { String(format: "%.1f%%", 100 * $0) }.joined(separator: "/") + String(format: " (saturated %.1f%%)", 100 * f[5])
        }
        /// The picture reads: under 55 % the bottom colour (batch M: 98 %), ≥ 15 % in the top three fifths
        /// (0.5 %), and the percentile's promise — about 5 % in the last colour, never a red slab.
        func reads(_ f: [Double], _ what: String) {
            XCTAssertLessThan(f[0], 0.55, "\(what): less than 55 % of the part is the bottom colour")
            XCTAssertGreaterThan(f[2] + f[3] + f[4], 0.15, "\(what): the upper three fifths hold the spread")
            XCTAssertLessThanOrEqual(f[5], 0.07, "\(what): the last colour is a few spots, not a slab")
        }
        // each group picked alone
        for g in ["group-1", "group-2"] {
            stage.pick(g); stage.refresh()
            let s = try XCTUnwrap(stage.feShownStress)
            let f = Self.fifths(stage, o, field: s.field, top: s.top)
            // ★ RED CONTROL: one scale at the peak
            let atPeak = Self.fifths(stage, o, field: s.field, top: s.peak)
            print(String(format: "FLEX-MV SCALE %@: peak %.4f MPa · top (p%.0f) %.4f · fifths %@ (at the peak: %@) · ends %@ … %@ · row '%@'",
                         g, s.peak, 100 * FlexibleFEStress.scalePercentile, s.top, pct(f), pct(atPeak), stage.stressEnds.lo, stage.stressEnds.hi, stage.legendTitle(.stress)))
            reads(f, g)
            XCTAssertEqual(stage.stressEnds.hi, "≥ " + FlexibleProbe.mpa(s.top) + " MPa", "\(g): the end says it is a top, not the peak")
            XCTAssertEqual(stage.legendTitle(.stress), "Stress · Group \(g.last!) · MPa")
            if g == "group-1" { XCTAssertGreaterThan(atPeak[0], 0.9, "control: at the 0.799 MPa peak the part is one colour") }
            // a tap still reads the TRUE MPa (above the top too)
            let pos = o.mesh.flat.positions
            let p = SIMD3<Float>(pos[0], pos[1], pos[2])
            XCTAssertEqual(stage.surfaceReading(.stress, at: p)?.value, FlexibleProbe.mpa(try XCTUnwrap(FlexibleProbe.stress(s.field, at: p))))
        }
        // Play all: each turn on its OWN scale, named in the row (as the renderer swaps the turn in)
        let all = try XCTUnwrap(stage.sims.first { $0.kind == .playAll })
        stage.pick(all.id); stage.refresh()
        XCTAssertTrue(stage.playAllLive)
        XCTAssertEqual(stage.legendTitle(.stress), "Stress · each group in turn · MPa", "before a turn plays")
        var tops: [String: Double] = [:]
        for i in stage.fe.sequence {
            let id = stage.fe.fields[i].simID
            stage.loop.shownIndex = i
            stage.loop.notePlaying(id)
            let s = try XCTUnwrap(stage.feShownStress)
            tops[id] = s.top
            let f = Self.fifths(stage, o, field: s.field, top: s.top)
            // the composed tints the renderer swaps in for this turn: its own field on its own top
            let t = try XCTUnwrap(stage.tints(r.project, on: .lattice, roles: [:], stress: nil))
            let pos = o.mesh.flat.positions
            var match = 0, n = 0
            for v in stride(from: 0, to: o.partFlatVertices, by: 11) {
                let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
                let c = FlexibleColours.stressTint(fraction: (FlexibleProbe.stress(s.field, at: p) ?? 0) / s.top)
                n += 1
                if simd_distance(SIMD3(t[v * 8], t[v * 8 + 1], t[v * 8 + 2]), SIMD3(c.x, c.y, c.z)) < 1e-4 { match += 1 }
            }
            let onePeak = stage.fe.sequence.compactMap { stage.feStress(stage.fe.fields[$0])?.peak }.max() ?? 0
            let atOnePeak = Self.fifths(stage, o, field: s.field, top: onePeak)
            print(String(format: "FLEX-MV SCALE play all, turn %@: row '%@' · ends %@ … %@ · fifths %@ (batch M's one peak %.4f: %@) · its colours %d/%d",
                         id, stage.legendTitle(.stress), stage.stressEnds.lo, stage.stressEnds.hi, pct(f), onePeak, pct(atOnePeak), match, n))
            let short = try XCTUnwrap(stage.sims.first { $0.id == id }?.short)
            XCTAssertEqual(stage.legendTitle(.stress), "Stress · \(short) · MPa", "the row names the turn playing")
            reads(f, "\(id)'s turn")
            XCTAssertEqual(match, n, "\(id)'s turn: its colours are its own field on its own top")
            if id == "group-2" { XCTAssertGreaterThan(atOnePeak[0], 0.9, "control: on Group 1's peak Group 2's turn is one colour") }
        }
        XCTAssertNotEqual(tops["group-1"], tops["group-2"], "two turns, two scales")
        // ★ RED CONTROL at the call site: batch M's one peak — the stage's own colours go flat again
        stage.controlStressScaleIsPeak = true
        stage.feStressCache = [:]
        stage.pick("group-1"); stage.refresh()
        let s = try XCTUnwrap(stage.feShownStress)
        XCTAssertEqual(s.top, s.peak, "control: the top is the peak")
        XCTAssertGreaterThan(Self.fifths(stage, o, field: s.field, top: s.top)[0], 0.9, "control: one colour")
        stage.controlStressScaleIsPeak = false
        _ = m
    }

    // MARK: the dent's "×k" says what the map is drawn at

    func testTheDentRowsFactorIsWhatTheMapIsDrawnAt() async throws {
        let (_, stage, m) = try await round5()
        for g in ["group-1", "group-2"] {
            stage.pick(g); stage.refresh()
            let f = try XCTUnwrap(stage.feShownField)
            let k = try XCTUnwrap(stage.channels?.exaggeration)
            let share = f.foldShare ?? 1
            // what the map is DRAWN at: each map vertex's displacement in the mesh the renderer is handed (× the
            // page's k), over the mm its colour reads there (the far ends rest, so the press is the dent)
            let o = try XCTUnwrap(stage.overlay)
            let dents = try XCTUnwrap(stage.shownDents), heat = try XCTUnwrap(stage.shownHeatValues)
            let keys = Set(m.lattice?.sims.first(where: { $0.id == g })?.keys ?? [])
            let top = heat.filter(\.isFinite).max() ?? 0
            var ratios: [Double] = []
            for (key, start) in o.flatStart where keys.contains(key) {
                guard let st = m.stacks[key] else { continue }
                for v in start..<(start + 6 * st.columns.count) where heat[v].isFinite && Double(heat[v]) > 0.3 * Double(top) {
                    let d = simd_length(SIMD3<Float>(dents[3 * v], dents[3 * v + 1], dents[3 * v + 2]))
                    ratios.append(Double(d) * k / Double(heat[v]))
                }
            }
            ratios.sort()
            let median = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
            stage.controlDentLabelIgnoresFold = true
            let old = stage.dentFactorLabel
            stage.controlDentLabelIgnoresFold = false
            print(String(format: "FLEX-MV FACTOR %@: page ×%.0f · fold cut %.2f · drawn/coloured (median of %d vertices) %.3f · row '%@' (batch M's '%@')",
                         g, k, share, ratios.count, median, stage.dentFactorLabel, old))
            XCTAssertGreaterThan(ratios.count, 100, "\(g): premise: the map's pressed vertices")
            XCTAssertEqual(stage.dentDrawnFactor, k * share, accuracy: 1e-9)
            XCTAssertEqual(median / stage.dentDrawnFactor, 1, accuracy: 0.35, "\(g): the row's factor is what the map is drawn at")
            if share < 0.7 { XCTAssertGreaterThan(abs(median / k - 1), 0.35, "control: batch M's '×\(Int(k))' is not what is drawn") }
            XCTAssertEqual(stage.dentFactorLabel, FlexibleMainStage.factorLabel(k * share))
            if share < 0.9 { XCTAssertNotEqual(old, stage.dentFactorLabel, "control: batch M's '×\(Int(k))' over a cut motion") }
        }
        XCTAssertEqual(FlexibleMainStage.factorLabel(1), "×1")
        XCTAssertEqual(FlexibleMainStage.factorLabel(2.02), "×2")
        XCTAssertEqual(FlexibleMainStage.factorLabel(0.227), "×0.2")
        XCTAssertEqual(FlexibleMainStage.factorLabel(1.06), "×1.1")
        XCTAssertEqual(FlexibleMainStage.factorLabel(0.06), "×0.06")
    }

    // MARK: the column fallback keeps the dent view's body solid

    func testTheColumnFallbackKeepsTheDentViewSolid() async throws {
        let (r, stage, _) = try await round5(failing: ["group-1", "group-2"])
        let pm = r.project
        XCTAssertNotNil(stage.fe.failure, "premise: every sim failed — the column squish plays")
        XCTAssertTrue(stage.heat && stage.dentMapShown, "premise: the dent view shows a map")
        XCTAssertTrue(stage.dentOnColumnFallback)
        // the lattice shown: X-ray is the lattice's (the walls opaque, as before batch M)
        XCTAssertTrue(stage.latticeShown && stage.xray)
        XCTAssertFalse(stage.ghostWalls)
        XCTAssertEqual(stage.layer(pm, stage: .lattice, pageUp: false)?.ghostWalls, false)
        // the lattice hidden: the solid part
        stage.toggleLattice(); stage.refresh()
        XCTAssertFalse(stage.xray)
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), 1, "the column planes are never seen through a ghost")
        // ★ RED CONTROL: batch M's rule — the dent view X-rays the fallback too
        stage.controlDentXrayOnFallback = true; stage.refresh()
        XCTAssertEqual(stage.bodyAlpha(pm, on: .lattice), FlexibleStagePage.xrayBodyAlpha, "control: batch M ghosted the body")
        stage.toggleLattice(); stage.refresh()
        XCTAssertTrue(stage.ghostWalls, "control: …and the walls")
        stage.controlDentXrayOnFallback = false; stage.refresh()
        // the FE route keeps it (a pick of a group whose sim landed)
        let (_, ok, _) = try await round5()
        XCTAssertFalse(ok.dentOnColumnFallback)
        XCTAssertTrue(ok.dentXray && ok.ghostWalls, "the 3D sim's dent view: X-ray, ghost walls")
    }

    // MARK: depth order — the ghost walls against the solid planes

    /// One frame of what the stage hands MetalMeshView, with knobs: the body's alpha, the pass's controls.
    static func frame(_ stage: FlexibleMainStage, _ pm: ProjectModel, layer: FlexibleLatticeLayerInputs?, tints: [Float]? = nil,
                      bodyAlpha: Float? = nil, view: (Float, Float), size: Int,
                      configure: (FlexibleLatticePass) -> Void = { _ in }) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try XCTUnwrap(stage.mesh(pm, on: .lattice)))
        let settle = pm.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.0, elevation: view.1)
        if let t = tints ?? stage.tints(pm, on: .lattice, roles: [:], stress: nil) { mr.setVertexTints(t) }
        mr.setBodyAlpha(bodyAlpha ?? stage.bodyAlpha(pm, on: .lattice) ?? 1)
        mr.applyFlexibleLattice(layer, device: device)
        if let pass = mr.flexibleLattice { configure(pass) }
        if let l = layer, !l.feSequence.isEmpty, let pass = mr.flexibleLattice {
            pass.bindFE(l.feSequence[0])
            mr.setFlexDisplacements(l.feMesh[l.feSequence[0]])
        }
        mr.setFlexScale(Float(stage.channels?.exaggeration ?? 1))
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    /// The map's interior pixels (2 px in from its outline), split NEAR (seen with the body solid) and FAR
    /// (seen only through the ghost body).
    static func mapPixels(_ stage: FlexibleMainStage, _ pm: ProjectModel, _ m: FlexibleStageModel, layer: FlexibleLatticeLayerInputs,
                          view: (Float, Float), size: Int) throws -> (near: [Int], far: [Int]) {
        var key = try XCTUnwrap(stage.tints(pm, on: .lattice, roles: [:], stress: nil))
        let o = try XCTUnwrap(stage.overlay)
        for (k, start) in o.flatStart {
            guard let st = m.stacks[k] else { continue }
            for v in start..<(start + 6 * st.columns.count) where key[v * 8 + 5] > 0.5 {
                key[v * 8] = 0; key[v * 8 + 1] = 1; key[v * 8 + 2] = 0
            }
        }
        var hidden = layer; hidden.hidden = true
        let ghost = try frame(stage, pm, layer: hidden, tints: key, view: view, size: size)
        let solid = try frame(stage, pm, layer: hidden, tints: key, bodyAlpha: 1, view: view, size: size)
        func keyed(_ px: [UInt8], _ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            let p = y * size + x
            let b = Int(px[4 * p]), g = Int(px[4 * p + 1]), r = Int(px[4 * p + 2])
            return g > 90 && g > 2 * r && g > 2 * b
        }
        func interior(_ px: [UInt8], _ p: Int) -> Bool {
            let x = p % size, y = p / size
            for dy in -2...2 { for dx in -2...2 where !keyed(px, x + dx, y + dy) { return false } }
            return true
        }
        var near: [Int] = [], far: [Int] = []
        for p in 0..<(size * size) {
            if interior(solid, p) { near.append(p) } else if interior(ghost, p) { far.append(p) }
        }
        return (near, far)
    }

    static func changed(_ a: [UInt8], _ b: [UInt8], _ px: [Int], over: Int = 20) -> Int {
        px.filter { p in (0..<3).map { abs(Int(a[4 * p + $0]) - Int(b[4 * p + $0])) }.max()! > over }.count
    }

    func testTheGhostWallsAreDepthOrderedAgainstTheSolidPlanes() async throws {
        let (r, stage, m) = try await round5()
        let pm = r.project
        let size = 640
        let cases: [(String, String, Float, Float)] = [("group-1 top", "group-1", .pi / 5, 1.2), ("group-1 iso", "group-1", .pi / 4, .pi / 6),
                                                      ("group-2 iso", "group-2", .pi / 4, .pi / 6), ("group-2 backleft", "group-2", -3 * .pi / 4, 0.55)]
        var farTotal = 0, farShown = 0, farOld = 0
        for (name, g, az, el) in cases {
            stage.pick(g); stage.refresh()
            let v = (az, el)
            let layer = try XCTUnwrap(stage.layer(pm, stage: .lattice, pageUp: false))
            XCTAssertTrue(layer.ghostWalls)
            var hidden = layer; hidden.hidden = true
            var opaque = layer; opaque.ghostWalls = false
            let px = try Self.mapPixels(stage, pm, m, layer: layer, view: v, size: size)
            let none = try Self.frame(stage, pm, layer: hidden, view: v, size: size)
            let ghost = try Self.frame(stage, pm, layer: layer, view: v, size: size)
            // positive control: the opaque walls, depth-tested against the plane in the main pass, show where
            // walls really are IN FRONT of a far plane (and stripe a near one where they fight it)
            let opaqueOld = try Self.frame(stage, pm, layer: opaque, view: v, size: size) { $0.controlNoMapDepth = true }
            // ★ RED CONTROL: the planes' depth left out of the G-buffer (batch M): the walls behind a near plane
            // are marched, and drawn after the body they show through it
            let noDepth = try Self.frame(stage, pm, layer: layer, view: v, size: size) { $0.controlNoMapDepth = true }
            // the bias's part: the planes' depth with no bias (the walls' cut faces level with the lifted plane)
            let noBias = try Self.frame(stage, pm, layer: layer, view: v, size: size) { $0.controlNoMapDepthBias = true }
            let nearGhost = Self.changed(ghost, none, px.near), nearNoDepth = Self.changed(noDepth, none, px.near)
            let nearNoBias = Self.changed(noBias, none, px.near)
            print(String(format: "FLEX-MV DEPTH %@: the planes' depth without the %.1f mm bias: walls through the near plane %d (%.2f%%)",
                         name, FlexibleLatticePass.mapDepthBiasMM, nearNoBias, 100 * Double(nearNoBias) / Double(max(1, px.near.count))))
            let farGhost = Self.changed(ghost, none, px.far), farOpaque = Self.changed(opaqueOld, none, px.far)
            print(String(format: "FLEX-MV DEPTH %@: near plane %d px · ghost walls through it %d (%.2f%%) · no planes' depth %d (%.1f%%) | far plane %d px · ghost walls in front %d (%.1f%%) · opaque walls in front %d (%.1f%%)",
                         name, px.near.count, nearGhost, 100 * Double(nearGhost) / Double(max(1, px.near.count)),
                         nearNoDepth, 100 * Double(nearNoDepth) / Double(max(1, px.near.count)),
                         px.far.count, farGhost, 100 * Double(farGhost) / Double(max(1, px.far.count)),
                         farOpaque, 100 * Double(farOpaque) / Double(max(1, px.far.count))))
            if px.near.count > 2_000 {
                XCTAssertLessThan(Double(nearGhost) / Double(px.near.count), 0.002, "\(name): nothing of the walls behind a near plane shows through it")
                XCTAssertGreaterThan(Double(nearNoDepth) / Double(px.near.count), 0.01, "\(name): control: without the planes' depth they do")
            }
            farTotal += px.far.count; farShown += farGhost; farOld += farOpaque
            if let d = Self.probeDir {
                for (tag, img) in [("ghost", ghost), ("none", none), ("opaque_old", opaqueOld), ("nodepth", noDepth)] {
                    try FlexibleLatticeEvidenceProbe.writeBGRA(img, size: size, to: d.appendingPathComponent("MV_depth_\(name.replacingOccurrences(of: " ", with: "_"))_\(tag).png"))
                }
            }
        }
        print(String(format: "FLEX-MV DEPTH far planes: %d px · the ghost walls in front show on %.1f%% · the opaque walls (where walls ARE in front) %.1f%%",
                     farTotal, 100 * Double(farShown) / Double(max(1, farTotal)), 100 * Double(farOld) / Double(max(1, farTotal))))
        XCTAssertGreaterThan(farTotal, 5_000, "premise: a far plane is on screen (group 2 from the back left)")
        XCTAssertGreaterThan(Double(farOld) / Double(farTotal), 0.2, "premise: walls ARE in front of the far plane")
        XCTAssertGreaterThan(Double(farShown) / Double(farTotal), 0.05, "the ghost walls in front of a far plane are drawn over it (batch M: 0.34 %)")
    }

    func testTheStressViewsOpaqueWallsNeverStripeTheSolidPlanes() async throws {
        let (r, stage, m) = try await round5()
        let pm = r.project
        stage.pick("group-1"); stage.toggleStress(); stage.refresh()
        XCTAssertTrue(stage.stress && stage.latticeShown && !stage.ghostWalls, "premise: Stress with the walls opaque")
        // 640 px (the G-buffer 1:1) and 1600 px (past its 1152 px cap — the device's case)
        for (size, v) in [(640, (Float.pi / 4, Float.pi / 6)), (1600, (Float(-2.4), Float(0.75)))] {
            let layer = try XCTUnwrap(stage.layer(pm, stage: .lattice, pageUp: false))
            XCTAssertTrue(layer.stressWalls)
            var hidden = layer; hidden.hidden = true
            let px = try Self.mapPixels(stage, pm, m, layer: layer, view: v, size: size)
            let none = try Self.frame(stage, pm, layer: hidden, view: v, size: size)
            let walls = try Self.frame(stage, pm, layer: layer, view: v, size: size)
            let noDepth = try Self.frame(stage, pm, layer: layer, view: v, size: size) { $0.controlNoMapDepth = true }
            let striped = Self.changed(walls, none, px.near), old = Self.changed(noDepth, none, px.near)
            print(String(format: "FLEX-MV STRESS STRIPES %d px: near plane %d px · walls through it %d (%.2f%%) · without the planes' depth %d (%.1f%%)",
                         size, px.near.count, striped, 100 * Double(striped) / Double(max(1, px.near.count)), old, 100 * Double(old) / Double(max(1, px.near.count))))
            XCTAssertGreaterThan(px.near.count, 2_000)
            // (at 1600 px what remains is ONE line, 1 px wide, along the crease where the top's plane meets Face 5's —
            // the two lifted planes leave a seam the G-buffer, at 1152 px, resolves; 1259 of 1306 pixels there)
            XCTAssertLessThan(Double(striped) / Double(px.near.count), size > 1152 ? 0.005 : 0.002, "\(size) px: the Stress view's solid planes are not striped")
            XCTAssertGreaterThan(Double(old) / Double(px.near.count), 0.01, "\(size) px: control: without the planes' depth they are")
            if let d = Self.probeDir {
                try FlexibleLatticeEvidenceProbe.writeBGRA(walls, size: size, to: d.appendingPathComponent("MV_stress_\(size)_walls.png"))
                try FlexibleLatticeEvidenceProbe.writeBGRA(noDepth, size: size, to: d.appendingPathComponent("MV_stress_\(size)_nodepth.png"))
            }
        }
    }

    // MARK: his img 6's rows, at the device's pixel count (an opt-in probe: FLEX_MV_DEVICE=1 + FLEX_M_PROBE_DIR)

    /// Pixels of the near plane's interior that differ from BOTH the row above and the row below (a one-row
    /// dash — his img 6's stripes) by more than 25 levels.
    static func oneRowDashes(_ px: [UInt8], _ near: [Int], size: Int) -> Int {
        func luma(_ p: Int) -> Int { (Int(px[4 * p]) + 2 * Int(px[4 * p + 1]) + Int(px[4 * p + 2])) / 4 }
        return near.filter { p in
            let y = p / size
            guard y > 0, y < size - 1 else { return false }
            let c = luma(p)
            return abs(c - luma(p - size)) > 25 && abs(c - luma(p + size)) > 25
        }.count
    }

    /// His img 6 (13" iPad, Fine, the dent view with the lattice): at 2752 px the lattice G-buffer is capped
    /// at 1152 px — the walls' cut faces level with the plane fight it in ROWS. The build he saw (opaque
    /// walls, no planes' depth, the column squish) against this one, and the Stress view with the lattice.
    func testHisImg6RowsAtTheDevicesPixelCount() async throws {
        guard ProcessInfo.processInfo.environment["FLEX_MV_DEVICE"] != nil, let dir = Self.probeDir else { throw XCTSkip("FLEX_MV_DEVICE + FLEX_M_PROBE_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        r.project.quality = .fine
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5, Fine")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(600, "Fine: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.latticeIsStale && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.pick("group-1"); stage.refresh()
        let size = 2752, pm = r.project
        let v: (Float, Float) = (-2.4, 0.75)   // behind-left, above: his img 6's BACK / LEFT / TOP gizmo
        func shoot(_ tag: String, configure: (FlexibleLatticePass) -> Void = { _ in }, opaque: Bool = false) throws {
            var layer = try XCTUnwrap(stage.layer(pm, stage: .lattice, pageUp: false))
            if opaque { layer.ghostWalls = false }
            let px = try Self.mapPixels(stage, pm, m, layer: layer, view: v, size: size)
            let img = try Self.frame(stage, pm, layer: layer, view: v, size: size, configure: configure)
            var hidden = layer; hidden.hidden = true
            let none = try Self.frame(stage, pm, layer: hidden, view: v, size: size)
            let dashes = Self.oneRowDashes(img, px.near, size: size), base = Self.oneRowDashes(none, px.near, size: size)
            let through = Self.changed(img, none, px.near)
            print(String(format: "FLEX-MV IMG6 %@ (%d px): near plane %d px · one-row dashes %d (no walls: %d) · walls through it %d (%.2f%%)",
                         tag, size, px.near.count, dashes, base, through, 100 * Double(through) / Double(max(1, px.near.count))))
            try FlexibleLatticeEvidenceProbe.writeBGRA(img, size: size, to: dir.appendingPathComponent("MV_img6_\(tag).png"))
        }
        // the build he saw: the column squish, the walls opaque, no planes' depth
        stage.controlColumnSquish = true; stage.refresh()
        try shoot("before_column_opaque", configure: { $0.controlNoMapDepth = true }, opaque: true)
        try shoot("now_column", configure: { _ in })
        stage.controlColumnSquish = false; stage.refresh()
        try shoot("now_fe_dent")
        try shoot("batchM_fe_dent", configure: { $0.controlNoMapDepth = true })
        stage.toggleStress(); stage.refresh()
        try shoot("now_fe_stress")
        try shoot("batchM_fe_stress", configure: { $0.controlNoMapDepth = true })
    }

    // MARK: the folded card is the octet's minimised key

    func testTheFoldedCardIsTheOctetsMinimisedKeyOnTheVeryEdge() {
        let stage = FlexibleMainStage()
        for (name, v) in [("13 portrait", CGSize(width: 1032, height: 1376)), ("13 landscape", CGSize(width: 1376, height: 1032)),
                          ("11 portrait", CGSize(width: 834, height: 1194)), ("11 landscape", CGSize(width: 1194, height: 834))] {
            for rows in 1...2 {
                let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: 94, chipColumnWidth: 222)
                let folded = FlexibleMainLegendLayout.placeCard(rows: rows, minimized: true, viewport: v, keepOut: keep,
                                                                edge: FlexibleMainLegendLayout.foldedEdge)
                let card = try? XCTUnwrap(folded, "\(name): the folded card is placed")
                guard let c = card else { continue }
                XCTAssertEqual(c.frame.maxX, v.width, accuracy: 0.5, "\(name): on the very edge, like the octet's key")
                XCTAssertGreaterThanOrEqual(c.frame.height, FlexibleMainLegendLayout.foldedBar.height, "\(name): 150 pt bars")
                for k in keep { XCTAssertFalse(c.frame.intersects(k.insetBy(dx: -FlexibleLegendPlacement.gap, dy: -FlexibleLegendPlacement.gap)), "\(name): covers no button") }
                // ★ RED CONTROL: batch M's folded card sat a page edge in
                let old = FlexibleMainLegendLayout.placeCard(rows: rows, minimized: true, viewport: v, keepOut: keep)
                XCTAssertNotEqual(old?.frame.maxX ?? 0, v.width, accuracy: 0.5, "control: batch M's sat PageChrome.edge in")
            }
        }
        XCTAssertEqual(FlexibleMainLegendLayout.foldedBar, CGSize(width: 18, height: 150), "the octet's bars")
        XCTAssertEqual(FlexibleMainLegendLayout.foldedSpacing, 30, "the octet's gap")
        // the stage places it so (folded ⇒ the edge)
        stage.legendMinimized = true
        _ = stage.legendCard(viewport: CGSize(width: 1032, height: 1376), bottomClearance: 94, chipColumnWidth: 222)   // (no kinds: nil)
        let src = (try? FlexibleSource.code("FlexibleMainStage+Views.swift")) ?? ""
        XCTAssertTrue(src.contains("edge: legendMinimized ? FlexibleMainLegendLayout.foldedEdge : PageChrome.edge"))
        let legends = (try? FlexibleSource.code("FlexibleMainLegends.swift")) ?? ""
        XCTAssertTrue(legends.contains("HStack(alignment: .center, spacing: FlexibleMainLegendLayout.foldedSpacing)"))
        XCTAssertTrue(legends.contains(".overlay(alignment: .top) { foldedArrow(k) }"), "the reading's arrow on its bar")
    }
}
#endif
