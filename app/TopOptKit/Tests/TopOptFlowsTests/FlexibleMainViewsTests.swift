// FlexibleMainViewsTests — the main Flexible page's views, legends and tap-to-read (task
// 2026-09-29-flexible-screens, round 3 batch C: items 1.4, T and 7; his rules: "each data
// view with its OWN legend whose tap enters tap-to-read", "legends never cover buttons").
//   * every read kind has its own stable id (never an octet class's), unit and ramp — RED: a
//     pair sharing an id is caught;
//   * no legend ramp is purple — RED: the instrument sees the DS purple and the octet violet;
//   * the DENT probe reads the column he SEES (the drawn dent, ×7, at an oblique view) — RED:
//     the rest surface under the same ray is a neighbour column;
//   * the STRESS probe is the field at the rest point (LatticeStressTint.sample), and a surface
//     point half a voxel outside the grid still reads — RED: sample() is nil there;
//   * the LATTICE probe reads the REST point of a squished wall — RED: the drawn point's ρ;
//   * Heat + Stress compose into ONE vertexTints array (the map quads heat, the part stress) —
//     RED: the stress buffer for the part mesh is the wrong size for the overlay mesh and the
//     renderer drops it;
//   * Stress under Flexible solves once — RED: the octet's gate never opens for a fresh part;
//   * the legends never cover a button, the player never covers a legend — RED: a stack of
//     three centred on the trailing edge runs under the view toggles / the chip column;
//   * a tap while a Flexible legend is drilled in is consumed and read (the stage's routing);
//     the wall probe is armed only for the lattice legend.
import XCTest
import CoreGraphics
import Metal
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleMainViewsTests: XCTestCase {

    // MARK: kinds

    @MainActor
    func testEveryReadKindHasItsOwnIdUnitAndRamp() {
        let kinds = FlexibleReadKind.allCases
        XCTAssertEqual(Set(kinds.map(\.id)).count, kinds.count, "one stable id per kind")
        XCTAssertEqual(Set(kinds.map(\.unit)).count, kinds.count, "one unit per kind")
        XCTAssertEqual(Set(kinds.map(\.title)).count, kinds.count)
        let octet = Set(LatticeStructureClass.allCases.map(\.id))
        XCTAssertTrue(octet.isDisjoint(with: Set(kinds.map(\.id))), "never an octet class's id (the key's drill-in would read it)")
        for k in kinds {
            XCTAssertEqual(FlexibleReadKind(mode: k.mode), k, "the mode round-trips")
            XCTAssertFalse(k.title.isEmpty); XCTAssertFalse(k.info.isEmpty)
            XCTAssertEqual(k.id, FlexibleReadKind(rawValue: k.rawValue)?.id, "stable")
        }
        XCTAssertNil(FlexibleReadKind(mode: .groups))
        XCTAssertNil(FlexibleReadKind(mode: .colour(LatticeStructureClass.allCases[0].id)))
        XCTAssertEqual(FlexibleReadKind.dent.title, "Squish · mm")
        XCTAssertEqual(FlexibleReadKind.stress.title, "Stress in the solid part · MPa")
        XCTAssertEqual(FlexibleReadKind.lattice.title, "Lattice · density")
        XCTAssertTrue(FlexibleReadKind.duplicateIDs(kinds.map { ($0.rawValue, $0.id) }).isEmpty)
        // ★ RED CONTROL: two kinds sharing an id are caught
        let shared = FlexibleReadKind.dent.id
        XCTAssertEqual(FlexibleReadKind.duplicateIDs([("dent", shared), ("stress", shared), ("lattice", FlexibleReadKind.lattice.id)]),
                       ["stress"], "control: a shared id is found")
        // ★ RE-PINNED (batch M, M7 — his round-5 img 6: "we can use the same colours. Please switch the
        // dent colours to the original FEA legend colours"): the dent and Stress read ONE rainbow (the two
        // views are never on together); the walls keep their own pale → green
        func hues(_ k: FlexibleReadKind) -> [Double] {
            (0...20).map { k.rampColour(Double($0) / 20) }
                .map(FlexibleShownValuesTests.hueSat).filter { $0.s > 0.15 }.map(\.h)
        }
        let dent = hues(.dent), stress = hues(.stress), walls = hues(.lattice)
        XCTAssertEqual(dent, stress, "the dent and Stress share the FEA rainbow")
        XCTAssertGreaterThan((dent.max() ?? 0) - (dent.min() ?? 0), 150, "a rainbow")
        XCTAssertLessThan((walls.max() ?? 0) - (walls.min() ?? 0), 40, "control: the walls' ramp is one hue family, not the rainbow")
    }

    @MainActor
    func testNoLegendRampIsPurple() {
        for k in FlexibleReadKind.allCases {
            for i in 0...40 {
                let c = k.rampColour(Double(i) / 40)
                XCTAssertFalse(FlexibleShownValuesTests.isPurple(c), "\(k) at \(i)/40 is never purple")
            }
        }
        // ★ RED CONTROL: the instrument sees the DS purple (groupPalette[4], 0xBF5AF2)
        XCTAssertTrue(FlexibleShownValuesTests.isPurple(DS.Color.groupPalette[4]), "control: groupPalette[4] is purple")
    }

    // MARK: the dent probe — what he SEES, read at its rest column

    @MainActor
    private func hisModel() async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        m.rest(5)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "his designs") { !m.readiness.designing && !m.designsInFlight }
        await m.waitForIdle()
        return (r, m)
    }

    /// Top A's deepest shown column that is not on the face's edge.
    @MainActor
    private func deepColumn(_ m: FlexibleStageModel, _ key: FlexFaceKey, drawn: FlexibleGeneratedLattice? = nil) throws -> (column: Int, mm: Double) {
        let shown = FlexibleShownValues(model: m, drawnLattice: drawn)
        let vals = try XCTUnwrap(shown.values[key])
        let st = try XCTUnwrap(m.stacks[key])
        var best: (Int, Double)?
        for (i, v) in vals.enumerated() {
            guard case .depth(let d) = v else { continue }
            let c = st.columns[i]
            let interior = [(1, 0), (-1, 0), (0, 1), (0, -1)].allSatisfy { st.column(c.iu + $0.0, c.iv + $0.1) >= 0 }
            if interior, best == nil || d > best!.1 { best = (i, d) }
        }
        return try XCTUnwrap(best.map { (column: $0.0, mm: $0.1) })
    }

    @MainActor
    func testTheDentProbeReadsTheColumnHeSees() async throws {
        let (_, m) = try await hisModel()
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let ch = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: nil)
        let dents = try XCTUnwrap(ch.dents, "his drawing dents")
        let a = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)
        let st = try XCTUnwrap(m.stacks[a])
        let (c, mm) = try deepColumn(m, a)
        let start = try XCTUnwrap(overlay.flatStart[a])
        let pos = overlay.mesh.flat.positions
        let k: Float = 7
        // the DRAWN centre of column c's quad (its six flat vertices, dented × 7)
        var drawn = SIMD3<Float>.zero
        for j in 0..<6 {
            let v = start + c * 6 + j
            drawn += SIMD3(pos[3 * v] + k * dents[3 * v], pos[3 * v + 1] + k * dents[3 * v + 1], pos[3 * v + 2] + k * dents[3 * v + 2])
        }
        drawn /= 6
        // an oblique view, 30° off the load (from above, over the face)
        let load = simd_normalize(SIMD3<Float>(st.load)), side = simd_normalize(SIMD3<Float>(st.xAxis))
        let dir = simd_normalize(load + 0.58 * side)
        let origin = drawn - dir * 400
        // what the CPU picker hands the page: the REST surface along that ray
        let rest = try XCTUnwrap(FacePicker.hit(rayOrigin: origin, rayDir: dir, mesh: overlay.mesh))
        var cols: [FlexFaceKey: Int] = [:]
        for (key, s) in m.stacks { cols[key] = s.columns.count }
        let hit = try XCTUnwrap(FlexibleProbe.dentHit(origin: rest.point - dir * 400, dir: dir, overlay: overlay,
                                                      columns: cols, dents: dents, scale: k), "the drawn map is on the ray")
        let reading = try XCTUnwrap(FlexibleProbe.dentReading(model: m, overlay: overlay, dents: dents, scale: k, drawnLattice: nil,
                                                              point: rest.point, dir: dir))
        // ★ RED CONTROL: the rest surface under the same ray (the dent not followed) is another column
        let atRest = FlexibleProbe.dentHit(origin: rest.point - dir * 400, dir: dir, overlay: overlay, columns: cols, dents: dents, scale: 0)
        print("FLEX-PROBE dent: column \(c) (\(String(format: "%.2f", mm)) mm) ⇒ drawn hit \(hit.key.region)/\(hit.column) · reading '\(reading.text)' · rest surface under the ray: \(atRest.map { "\($0.key.region)/\($0.column)" } ?? "none")")
        XCTAssertEqual(hit.key, a)
        XCTAssertEqual(hit.column, c, "the tap on the drawn dent reads the column he sees")
        XCTAssertEqual(reading.kind, .dent)
        // ★ RE-PINNED (batch M, M5): the value AT THE POINT — the hit triangle's corner values blended as the
        // GPU blends their colours (the column's own number sits at its centre; the corners are the
        // means of the columns round them), so the number is the colour under the tap
        let corner = overlay.mapCornerValues(FlexibleShownValues(model: m).values.mapValues { v in
            v.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }, stacks: m.stacks)
        let blend = Double(hit.bary.x * corner[hit.verts[0]] + hit.bary.y * corner[hit.verts[1]] + hit.bary.z * corner[hit.verts[2]])
        XCTAssertEqual(reading.value, String(format: "%.2f", blend), "the value under the tap, with its unit")
        XCTAssertEqual(blend, mm, accuracy: 0.15 * mm, "…near the column's own number")
        XCTAssertEqual(reading.unit, "mm")
        XCTAssertLessThan(simd_distance(reading.anchor, drawn), 1.5, "the callout sits where he tapped")
        XCTAssertNotNil(atRest)
        XCTAssertNotEqual(atRest?.column, c, "control: reading the rest surface under the ray is a neighbour column")
    }

    // MARK: the stress probe

    static func field(nx: Int = 4, ny: Int = 4, nz: Int = 4, origin: SIMD3<Double> = .zero, spacing: Double = 2,
                      _ f: (Int, Int, Int) -> Float = { i, j, k in Float(i + 10 * j + 100 * k) }) -> LatticeDemandField {
        var v = [Float](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx { v[i + nx * (j + ny * k)] = f(i, j, k) } } }
        return LatticeDemandField(vonMises: v, nx: nx, ny: ny, nz: nz, origin: origin, spacingMM: spacing,
                                  provenance: .solidSim(date: Date(), resolution: 64))
    }

    func testTheStressProbeIsTheFieldAtTheRestPoint() throws {
        let f = Self.field()
        for p in [SIMD3<Float>(1.3, 2.1, 3.7), SIMD3(0, 0, 0), SIMD3(5.9, 4.2, 0.5)] {
            let want = try XCTUnwrap(LatticeStressTint.sample(f, at: SIMD3<Double>(p)))
            XCTAssertEqual(try XCTUnwrap(FlexibleProbe.stress(f, at: p)), want, accuracy: 1e-9, "the field at \(p)")
        }
        // a surface point just outside the voxel-centre grid (half a voxel) still reads its voxel
        let edge = SIMD3<Float>(-1.0, 2, 2)
        XCTAssertEqual(try XCTUnwrap(FlexibleProbe.stress(f, at: edge)),
                       try XCTUnwrap(LatticeStressTint.sample(f, at: SIMD3(0, 2, 2))), accuracy: 1e-9)
        XCTAssertNil(FlexibleProbe.stress(f, at: SIMD3(-5, 2, 2)), "far outside the solve: no number, never a guess")
        // ★ RED CONTROL: the plain sample has no answer half a voxel out — the part's own surface
        XCTAssertNil(LatticeStressTint.sample(f, at: SIMD3<Double>(edge)))
    }

    // MARK: the lattice probe — the REST point of a squished wall

    func testTheLatticeProbeReadsTheRestPointOfASquishedWall() throws {
        var inputs = FlexibleLatticeFixtures.boxInputs(.gyroid)
        // ρ graded along the LOAD (z), so the drawn point and the rest point read differently
        let g = inputs.rho
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let z = g.c0.z + Float(k) * g.spacing
            inputs.rho.values[(k * g.ny + j) * g.nx + i] = 0.15 + 0.2 * Swift.min(Swift.max(z / 20, 0), 1)
        } } }
        let face = FlexibleLatticeFixtures.topFace(depth: 3)
        let s: Float = 2
        let p0 = SIMD3<Float>(13, 17, 12)
        let drawn = FlexibleSquishField.forward(p0, faces: [face], squish: s)
        XCTAssertGreaterThan(simd_distance(drawn, p0), 1, "premise: the wall moved")
        let read = try XCTUnwrap(FlexibleProbe.lattice(inputs, faces: [face], squish: s, at: drawn))
        XCTAssertLessThan(simd_distance(read.rest, p0), 1e-3, "the rest point")
        let rho = Double(inputs.rho.sample(p0))
        XCTAssertEqual(read.rho, rho, accuracy: 1e-6)
        let L = Swift.min(Swift.max(3.0915 * Double(inputs.wallMM) / Swift.min(Swift.max(rho, 0.05), 0.9),
                                    Double(inputs.lMinMM)), Double(inputs.lMaxMM))
        // ★ RE-PINNED (batch C verification): the cell DRAWN there — the ladder's rung (or the
        // blend of two), not the continuous law it is aimed at
        let r = FlexibleLatticeField.rungs(L: Float(L), lMin: inputs.lMinMM)
        let drawnCell = r.w <= 0 ? Double(r.La) : (r.w >= 1 ? Double(r.Lb)
            : Double(2 * Float.pi / ((1 - r.w) * 2 * Float.pi / r.La + r.w * 2 * Float.pi / r.Lb)))
        XCTAssertEqual(read.cellMM, drawnCell, accuracy: 1e-4, "the gyroid's drawn cell at that ρ")
        XCTAssertEqual(read.cellBlended, r.w > 0 && r.w < 1)
        var honey = inputs; honey.topology = .honeycomb
        XCTAssertEqual(FlexibleProbe.cellMM(rho: rho, honey), Double(honey.honeycombCellMM), accuracy: 1e-6, "honeycomb: one cell")
        // the legend's span is the pass's own (the masked ρ, min…max)
        let span = FlexibleProbe.latticeSpan(inputs)
        XCTAssertEqual(span.lowerBound, Double(inputs.rho.values.min()!), accuracy: 1e-6)
        XCTAssertEqual(span.upperBound, Double(inputs.rho.values.max()!), accuracy: 1e-6)
        // ★ RED CONTROL: the drawn point's own ρ is another number
        XCTAssertGreaterThan(abs(Double(inputs.rho.sample(drawn)) - rho), 0.005, "control: reading where it is drawn is wrong")
    }

    // MARK: one tint array

    @MainActor
    func testHeatAndStressComposeIntoOneTintArray() async throws {
        let (r, m) = try await hisModel()
        let part = try XCTUnwrap(r.project.viewerMesh)
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let b = part.bounds
        let field = Self.field(nx: 60, ny: 60, nz: 14, origin: SIMD3<Double>(b.min) - 1, spacing: 2) { i, _, _ in Float(1 + i) }
        let peak = LatticeStressTint.peakMPa(field)
        let ghost = FlexibleColours.ghost
        let heatBase = try XCTUnwrap(FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: nil).tints)
        let out = try XCTUnwrap(FlexibleMainTints.compose(base: heatBase, overlay: overlay, part: part, heat: true, roles: [:],
                                                          stress: (field, peak), ghost: ghost))
        let n = overlay.mesh.flat.vertexCount
        XCTAssertEqual(out.count, n * 8, "ONE array, sized to the drawn (overlay) mesh")
        let pos = overlay.mesh.flat.positions
        func stressRGB(_ v: Int) -> SIMD3<Float> {
            let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            // ★ RE-PINNED (batch M, M7): the Flexible Stress view reads the ONE FEA rainbow
            let c = FlexibleColours.stressTint(fraction: (FlexibleProbe.stress(field, at: p) ?? 0) / peak)
            return SIMD3(c.x, c.y, c.z)
        }
        func rgb(_ a: [Float], _ v: Int) -> SIMD3<Float> { SIMD3(a[v * 8], a[v * 8 + 1], a[v * 8 + 2]) }
        var partOK = 0, mapHeat = 0, mapVerts = 0
        for v in 0..<overlay.partFlatVertices where simd_distance(rgb(out, v), stressRGB(v)) < 1e-5 && out[v * 8 + 6] == 1 { partOK += 1 }
        for (_, s) in overlay.flatStart {
            for v in s..<n where v < s + 6 * 400 && heatBase[v * 8 + 5] == 1 {
                mapVerts += 1
                if rgb(out, v) == rgb(heatBase, v), out[v * 8 + 5] == 1 { mapHeat += 1 }
            }
        }
        print("FLEX-TINT heat + stress: part \(partOK)/\(overlay.partFlatVertices) stress (ghosted), map \(mapHeat)/\(mapVerts) heat (opaque)")
        XCTAssertEqual(partOK, overlay.partFlatVertices, "Stress owns the part")
        XCTAssertGreaterThan(mapVerts, 0)
        XCTAssertEqual(mapHeat, mapVerts, "Heat owns the pressed faces' map quads")
        // Heat off: the map takes the stress too, and is not opaque
        let plain = try XCTUnwrap(FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: nil, heat: false).tints)
        let noHeat = try XCTUnwrap(FlexibleMainTints.compose(base: plain, overlay: overlay, part: part, heat: false, roles: [:],
                                                             stress: (field, peak), ghost: nil))
        let firstMap = try XCTUnwrap(overlay.flatStart.values.min())
        XCTAssertLessThan(simd_distance(rgb(noHeat, firstMap), stressRGB(firstMap)), 1e-5, "Stress takes the map when Heat is off")
        // ★ RE-PINNED (batch C verification): held opaque like the heat it replaces, so it reads in X-ray
        XCTAssertEqual(noHeat[firstMap * 8 + 5], 1, "…held opaque, like the heat it replaces")
        // no stress: a main-page role colour fills a part triangle Flexible leaves clay (on his pad
        // every face is pressed or resting, so triangle 0 is made clay here), and never one it tints
        var clay = plain
        for j in 0..<24 { clay[j] = 0 }
        let role = SIMD4<Float>(0.2, 0.9, 0.3, 1)
        let tinted = try XCTUnwrap((1..<(overlay.partFlatVertices / 3)).first { plain[$0 * 24 + 3] > 0 && overlay.keptFace[$0] != overlay.keptFace[0] })
        let withRoles = try XCTUnwrap(FlexibleMainTints.compose(base: clay, overlay: overlay, part: part, heat: false,
                                                                roles: [FaceID(overlay.keptFace[0]): role, FaceID(overlay.keptFace[tinted]): role],
                                                                stress: nil, ghost: nil))
        XCTAssertEqual(withRoles[1], 0.9, accuracy: 1e-6, "the group's colour, composed in where Flexible leaves clay")
        XCTAssertEqual(withRoles[tinted * 24 + 1], plain[tinted * 24 + 1], accuracy: 1e-6, "…the Flexible face tint wins where it has one")
        // ★ RED CONTROL: the stress buffer made for the PART mesh (stressTints) does not fit the overlay
        // mesh the page draws, and the renderer drops it without a word
        let asStressTints = LatticeStressTint.tints(for: part, field: field)
        XCTAssertNotEqual(asStressTints.count, n, "control: the part's stress buffer is the wrong size for the overlay mesh")
        if let device = MTLCreateSystemDefaultDevice(), let rr = MeshRenderer(device: device, sampleCount: 1) {
            rr.setMesh(overlay.mesh)
            let bg = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let before = try XCTUnwrap(rr.renderOffscreen(size: 128, clear: bg))
            rr.setStressTints(asStressTints)
            let dropped = try XCTUnwrap(rr.renderOffscreen(size: 128, clear: bg))
            rr.setStressTints([SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: n))
            let taken = try XCTUnwrap(rr.renderOffscreen(size: 128, clear: bg))
            let droppedDiff = FlexibleLatticeFixtures.differing(before, dropped).differ
            let takenDiff = FlexibleLatticeFixtures.differing(before, taken).differ
            print("FLEX-TINT control: a part-sized stress buffer on the overlay mesh changes \(droppedDiff) px; an overlay-sized one \(takenDiff) px")
            XCTAssertEqual(droppedDiff, 0, "control: MetalMeshView's count guard drops it without a word")
            XCTAssertGreaterThan(takenDiff, 100, "positive control: a buffer of the right size is drawn")
        }
    }

    // MARK: stress under Flexible

    @MainActor
    func testStressUnderFlexibleSolvesOnce() async throws {
        XCTAssertTrue(FlexibleStressTrigger.shouldRun(hasField: false, stale: false, running: false))
        XCTAssertTrue(FlexibleStressTrigger.shouldRun(hasField: true, stale: true, running: false))
        XCTAssertFalse(FlexibleStressTrigger.shouldRun(hasField: true, stale: false, running: false))
        XCTAssertFalse(FlexibleStressTrigger.shouldRun(hasField: false, stale: false, running: true), "never twice")
        // ★ RE-WRITTEN (batch C verification): the REAL solver over a stub sim — the hand-over is
        // driven, not assigned (the old test set `stressSolver` itself and could not see that it
        // only arrived from the toggles' body)
        let gate = FlexibleBatchCVerifyTests.Gate()
        let sim = LatticeSimModel(runner: FlexibleBatchCVerifyTests.stubRunner(gate))
        let solver = FlexibleStressSolver(sim: sim, context: { FlexibleBatchCVerifyTests.context() })
        let stage = FlexibleMainStage()
        stage.attach(solver)
        stage.toggleStress()
        XCTAssertTrue(stage.stress)
        XCTAssertEqual(sim.phase, .running, "Stress on with no field: the solve runs")
        XCTAssertTrue(stage.xray, "X-ray is left alone (it used to turn off, and the walls with it)")
        stage.toggleStress(); stage.toggleStress()
        try await FlexibleBatchCVerifyTests.settle { sim.phase != .running }
        XCTAssertEqual(gate.runs, 1, "…once: it was running")
        stage.toggleStress(); stage.toggleStress()
        XCTAssertNotEqual(sim.phase, .running, "a field in hand is not solved again")
        try await FlexibleBatchCVerifyTests.settle { true }
        XCTAssertEqual(gate.runs, 1)
        XCTAssertEqual(stage.stressState, .ready)
        // ★ RED CONTROL: the octet's gate (startStressSolveIfNeeded) never opens for a fresh Flexible part
        var s = LatticeSettings(); s.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        XCTAssertFalse(FlexibleStressTrigger.octetGate(s), "control: routed through the octet gate it never runs")
    }

    // MARK: placement

    static let viewports = FlexibleLegendPlacementTests.viewports

    func mainChrome(_ v: CGSize, chip: CGFloat) -> [String: CGRect] {
        let e = PageChrome.edge, bar: CGFloat = 50, clearance = bar + DS.Space.xl4
        var k: [String: CGRect] = [
            "bottomBar": CGRect(x: 0, y: v.height - clearance, width: v.width, height: clearance),
            "settingsButton": CGRect(x: v.width - PageChrome.gizmoClearance - 150, y: DS.Space.xl3, width: 140, height: 44),
            "viewToggles": FlexibleMainViewToggles.frame(viewport: v),
            "gizmo": CGRect(x: v.width - PageChrome.gizmoInset - PageChrome.gizmoSize, y: PageChrome.gizmoInset,
                            width: PageChrome.gizmoSize, height: PageChrome.gizmoSize),
            "selectionsPanel": CGRect(x: e, y: 170, width: PageChrome.panelWidth, height: v.height - 170 - clearance - DS.Space.m),
        ]
        if chip > 0 {
            let h = FlexibleMainPlayerSlot.chipColumnHeight
            k["chipColumn"] = CGRect(x: v.width - e - chip, y: v.height - clearance - DS.Space.m - h, width: chip, height: h)
        }
        return k
    }

    func testTheLegendsCoverNoButtonAndThePlayerCoversNoLegend() throws {
        let clearance: CGFloat = 50 + DS.Space.xl4
        let sets: [[FlexibleReadKind]] = [[.dent], [.dent, .stress], [.dent, .lattice], [.dent, .stress, .lattice]]
        var allExpanded13 = false
        for (name, v) in Self.viewports {
            for chip: CGFloat in [0, 221] {
                let chrome = mainChrome(v, chip: chip)
                let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: chip)
                for kinds in sets {
                    let placed = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep)
                    XCTAssertEqual(Set(placed.keys), Set(kinds), "every legend has a place at \(name)")
                    let frames = placed.values.map(\.frame)
                    for (kind, p) in placed {
                        XCTAssertTrue(CGRect(origin: .zero, size: v).insetBy(dx: PageChrome.edge - 0.5, dy: PageChrome.edge - 0.5).contains(p.frame),
                                      "\(kind) on screen at \(name)")
                        for (b, r) in chrome where r.intersects(p.frame) { XCTFail("\(kind) covers \(b) at \(name) chip \(chip): \(p.frame) ∩ \(r)") }
                        for other in frames where other != p.frame && other.intersects(p.frame) { XCTFail("legends overlap at \(name)") }
                    }
                    if name.hasPrefix("13\" landscape"), chip > 0, kinds.count == 3, placed.values.allSatisfy(\.expanded) { allExpanded13 = true }
                    // the player, placed after them, covers none of them
                    let p = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: clearance,
                                                                         keepOut: FlexibleMainPlayerSlot.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: chip, legends: frames)),
                                          "a player place at \(name)")
                    for f in frames { XCTAssertFalse(p.intersects(f), "the player covers a legend at \(name)") }
                    if kinds.count == 3 {
                        print("FLEX-PLACE legends \(name) chip \(Int(chip)): " + kinds.map { k in placed[k].map { "\(k.rawValue) \($0.frame.integral)\($0.expanded ? "" : " (pill)")" } ?? "\(k.rawValue) none" }.joined(separator: " · ") + " · player \(p.integral)")
                    }
                }
            }
        }
        XCTAssertTrue(allExpanded13, "13\" landscape holds all three open")
        // ★ RED CONTROL: three legends stacked, centred on the trailing edge (the batch-B slot, extended)
        let v = CGSize(width: 1194, height: 834)
        let h = 3 * FlexibleMainLegendLayout.height + 2 * PageChrome.gap
        let naive = CGRect(x: v.width - PageChrome.edge - FlexibleMainLegendLayout.width, y: (v.height - h) / 2,
                           width: FlexibleMainLegendLayout.width, height: h)
        let chrome = mainChrome(v, chip: 221)
        XCTAssertTrue(naive.intersects(chrome["viewToggles"]!) || naive.intersects(chrome["chipColumn"]!),
                      "control: a centred stack of three runs under the view toggles or the chip column at 11\" landscape")
    }

    // MARK: tap routing

    @MainActor
    func testATapWhileAFlexibleLegendIsDrilledInIsConsumedAndTheWallProbeIsArmedOnlyForTheLattice() throws {
        let project = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        XCTAssertFalse(stage.read(project, mode: .groups, face: 0, point: .zero), "not drilled in: the face path decides")
        let octet = LatticeLegendMode.colour(LatticeStructureClass.allCases[0].id)
        XCTAssertFalse(stage.read(project, mode: octet, face: 0, point: .zero), "the octet key's reading is the octet's")
        XCTAssertFalse(stage.readLattice(project, mode: octet, model: .zero))
        for k in FlexibleReadKind.allCases {
            XCTAssertTrue(stage.read(project, mode: k.mode, face: 0, point: nil), "\(k): a tap while drilled in never selects")
            XCTAssertTrue(stage.readLattice(project, mode: k.mode, model: .zero), "\(k): …nor falls to the octet's reading")
        }
        XCTAssertFalse(stage.wantsWallProbe(FlexibleReadKind.dent.mode), "a tap for the dent must reach the surface")
        XCTAssertFalse(stage.wantsWallProbe(FlexibleReadKind.stress.mode))
        XCTAssertTrue(stage.wantsWallProbe(FlexibleReadKind.lattice.mode))
        XCTAssertTrue(stage.wantsWallProbe(octet), "the octet key keeps its probe")
        XCTAssertTrue(stage.wantsWallProbe(.groups))
    }

    /// The whole path on his project: the stage's own read, from the tap's rest point and the
    /// view's projection — the dent under the finger; a tap off the map with Stress on switches
    /// to the stress legend.
    @MainActor
    func testTheStageReadsHisDentAndSwitchesToStress() async throws {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "his stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
        }
        m.rest(5)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "his designs") { !m.readiness.designing && !m.designsInFlight }
        await m.waitForIdle()
        // the stage builds the lattice once the designs are in (the main page after Exit); the map
        // then shows the lattice's own depths
        stage.buildIfReady()
        try await FlexibleHisProject.waitFor(120, "the lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        stage.refresh()
        XCTAssertNotNil(stage.drawn, "premise: the lattice is drawn, the map is its depths")
        // ★ BATCH C VERIFICATION: a lattice core designed (varioShore) — "Squish · mm"; the lattice
        // legend's ends are scanned ONCE per generation, never per body pass (every orbit frame)
        XCTAssertEqual(stage.legendTitle(.dent), "Squish · mm")
        let scans = stage.latticeSpanScans
        let e1 = try XCTUnwrap(stage.latticeEnds()), e2 = try XCTUnwrap(stage.latticeEnds())
        print("FLEX-LEGEND lattice ends '\(e1.lo)' … '\(e1.hi)' · scans for two reads: \(stage.latticeSpanScans - scans)")
        XCTAssertEqual(stage.latticeSpanScans - scans, 1, "one scan per lattice generation")
        XCTAssertEqual(e1.lo, e2.lo); XCTAssertEqual(e1.hi, e2.hi)
        let overlay = try XCTUnwrap(stage.overlay)
        let dents = try XCTUnwrap(stage.channels?.dents)
        let a = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)
        let (c, mm) = try deepColumn(m, a, drawn: stage.drawn)
        stage.loop.hold(1)
        let k = stage.loop.scale(at: 0)
        let start = try XCTUnwrap(overlay.flatStart[a]), pos = overlay.mesh.flat.positions
        var drawn = SIMD3<Float>.zero
        for j in 0..<6 {
            let v = start + c * 6 + j
            drawn += SIMD3(pos[3 * v] + k * dents[3 * v], pos[3 * v + 1] + k * dents[3 * v + 1], pos[3 * v + 2] + k * dents[3 * v + 2])
        }
        drawn /= 6
        // a camera looking at that point 60° off the load (settle: none, so model = world) — the
        // lattice's k is smaller than the probe test's 7, so the view is steeper to tell columns apart
        let st = try XCTUnwrap(m.stacks[a])
        let toEye = -simd_normalize(simd_normalize(SIMD3<Float>(st.load)) + 1.73 * simd_normalize(SIMD3<Float>(st.xAxis)))
        let cam = OrbitCamera(target: drawn, distance: 250, azimuth: atan2(toEye.x, toEye.z), elevation: asin(toEye.y))
        let proj = CameraProjection(camera: cam, viewportSize: CGSize(width: 1194, height: 834))
        stage.noteView(projection: proj, settle: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
        // the tap: the CPU picker's rest point along the eye's ray through the drawn point
        let dir = simd_normalize(drawn - cam.eye)
        let rest = try XCTUnwrap(FacePicker.hit(rayOrigin: cam.eye, rayDir: dir, mesh: overlay.mesh))
        XCTAssertTrue(stage.read(r.project, mode: FlexibleReadKind.dent.mode, face: FaceID(rest.faceID), point: rest.point))
        let reading = try XCTUnwrap(stage.reading)
        print("FLEX-PROBE stage: column \(c) \(String(format: "%.2f", mm)) mm · k \(k) · reading '\(reading.text)'")
        XCTAssertEqual(reading.kind, .dent)
        XCTAssertEqual(reading.value, String(format: "%.2f", mm))
        XCTAssertLessThan(simd_distance(reading.anchor, drawn), 1.5, "the callout is pinned on the drawn dent he tapped")
        // ★ RED CONTROL: the undented surface under the same ray is another column
        var cols: [FlexFaceKey: Int] = [:]
        for (key, s) in m.stacks { cols[key] = s.columns.count }
        let restCol = FlexibleProbe.dentHit(origin: cam.eye, dir: dir, overlay: overlay, columns: cols, dents: dents, scale: 0)
        print("FLEX-PROBE stage control: the rest surface under the ray is column \(restCol.map { "\($0.column)" } ?? "none")")
        XCTAssertNotEqual(restCol?.column, c, "control: read off the undented surface, the tap lands on another column")
        // Stress on (X-ray off, so a tap on the solid part reads the part), a field in hand: a tap on
        // a side of the part that is not pressed reads the stress — and the key follows
        let b = try XCTUnwrap(r.project.viewerMesh).bounds
        let field = Self.field(nx: 60, ny: 60, nz: 14, origin: SIMD3<Double>(b.min) - 1, spacing: 2) { i, _, _ in Float(1 + i) }
        stage.stress = true
        stage.latticeOn = false   // ★ round 4 (C2): X-ray off = the lattice view hidden (no X-ray button)
        _ = stage.tints(r.project, on: .lattice, roles: [:], stress: field)
        let low = b.min.z + 2, mid = (b.min + b.max) / 2
        var side: (hit: FacePicker.Hit, toEye: SIMD3<Float>)?
        for toEye in [SIMD3<Float>(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0)] {
            let target = SIMD3<Float>(mid.x, mid.y, low)
            guard let h = FacePicker.hit(rayOrigin: target + toEye * 300, rayDir: -toEye, mesh: overlay.mesh),
                  h.triangle < overlay.keptTriangles.count else { continue }   // a part triangle, not a map quad
            side = (h, toEye); break
        }
        let (sideRest, sideEye) = try XCTUnwrap(side, "an unpressed side of his pad")
        let cam2 = OrbitCamera(target: sideRest.point, distance: 250, azimuth: atan2(sideEye.x, sideEye.z), elevation: asin(sideEye.y))
        stage.noteView(projection: CameraProjection(camera: cam2, viewportSize: CGSize(width: 1194, height: 834)),
                       settle: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
        XCTAssertTrue(stage.read(r.project, mode: FlexibleReadKind.dent.mode, face: FaceID(sideRest.faceID), point: sideRest.point))
        let s = try XCTUnwrap(stage.reading)
        print("FLEX-PROBE stage side tap with the dent drilled in: '\(s.text)' (\(s.kind))")
        XCTAssertEqual(s.kind, .stress, "no dent on the ray, Stress on: it reads the stress (and the key follows)")
        XCTAssertEqual(s.value, FlexibleProbe.mpa(try XCTUnwrap(FlexibleProbe.stress(field, at: sideRest.point))))
    }
}
