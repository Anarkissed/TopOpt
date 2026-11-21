// FlexibleNozzleGradeTests — round 7 · ONE nozzle row and its GRADE option.
//   His words of 2026-10-23 ~03:05 (verbatim): "temperature also needs a grade... also, what's the difference between "temperature"
//   and "nozzle" shouldn't they be the same???" then "Temperature needs a grade **option**".
// On HIS live pad of 2026-10-21. Each RED control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleNozzleGradeTests: XCTestCase {

    override func tearDown() {
        FlexibleStageModel.controlTwoTemperatureRows = false
        FlexibleStageModel.controlGradeSetsNozzle = false
        FlexibleStageModel.controlNoGradeInSim = false
        FlexibleNozzleGradeMath.controlSteppedSmooth = false
        super.tearDown()
    }

    func opened(_ what: String) async throws -> FlexibleStageModel {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return m
    }
    func jobBytes(_ m: FlexibleStageModel) -> String {
        let run: String
        do { run = try m.runJobJSON() } catch { run = "refused: \(error)" }
        return run + "\n" + ((try? m.sceneJob()?.json) ?? "none")
    }
    func deepest(_ m: FlexibleStageModel) -> Double { m.squeezeGroups.compactMap { m.estimateDeepest($0) }.max() ?? 0 }

    // MARK: 1 — ONE "Nozzle °C" row in Auto and Manual, ONE stored value (RED control: today's two rows, two values)

    func testOneNozzleRowInAutoAndManual() async throws {
        XCTAssertFalse(FlexibleManualLatticeRows.rows(group: nil, gradeOn: true).contains("temperature"), "★ no Temperature row on [Model]")
        for manual in [false, true] {
            XCTAssertEqual(FlexibleStageModel.nozzleRows(manual: manual, hasData: true, gradeOn: false), ["nozzle", "grade"], "★ manual \(manual)")
            XCTAssertEqual(FlexibleStageModel.nozzleRows(manual: manual, hasData: true, gradeOn: true),
                           ["nozzle", "grade", "from", "to", "style", "facts"])
        }
        XCTAssertEqual(FlexibleRowCopy.temperature, "Nozzle °C")
        XCTAssertEqual(FlexibleRowCopy.temperatureOptionsManual([190, 220, 240]).map(\.id), ["190", "220", "240"], "★ Manual: no Auto chip")
        XCTAssertEqual(FlexibleRowCopy.temperatureOptions([190, 220, 240]).first?.id, "auto", "★ Auto keeps its Auto chip")

        let m = try await opened("his pad")
        m.setNozzleTemp(220)
        XCTAssertEqual(m.settings.nozzleTempC, 220)
        m.setManual(true)
        XCTAssertEqual(m.nozzleRowTempC, 220, "★ Manual reads the one setting")
        m.setManualTemp(190)
        XCTAssertEqual(m.settings.nozzleTempC, 190, "★ Manual writes the one setting")
        XCTAssertNil(m.settings.manual?.tempC, "★ no second copy")
        m.setManual(false)
        XCTAssertEqual(m.nozzleRowTempC, 190, "★ Auto shows what Manual set")
        m.setNozzleTemp(nil)
        m.setManual(true)
        XCTAssertEqual(m.nozzleRowTempC, m.designTempC, "★ the Auto chip in Auto: Manual holds Auto's pick")

        // RED CONTROL: today's two rows (Manual's Temperature on [Model], More's Nozzle row Auto's) and two values
        FlexibleStageModel.controlTwoTemperatureRows = true
        XCTAssertTrue(FlexibleManualLatticeRows.rows(group: nil, gradeOn: false).contains("temperature"), "RED control: the second row is back")
        XCTAssertEqual(FlexibleStageModel.nozzleRows(manual: true, hasData: true, gradeOn: false), [], "RED control: More's row is Auto's")
        let before = m.settings.nozzleTempC
        m.setManualTemp(240)
        XCTAssertEqual(m.settings.nozzleTempC, before, "RED control: Manual's own copy leaves the nozzle setting behind")
        XCTAssertEqual(m.settings.manual?.tempC, 240)
        FlexibleStageModel.controlTwoTemperatureRows = false
    }

    // MARK: 2 — Stepped makes bands, Default is smooth; the slicer line (pure; RED control: Stepped ignored)

    func testSteppedMakesBandsAndTheSlicerLine() {
        let up = SIMD3<Double>(0, 0, 1)
        let span = 0.0...36.0
        func field(_ g: FlexibleNozzleGrade) -> [Float] {
            FlexibleNozzleGradeMath.field(g, nx: 2, ny: 2, nz: 36, origin: .zero, spacing: 1, up: up, span: span)
        }
        let st = FlexibleNozzleGrade(on: true, fromC: 190, toC: 240, stepped: true)
        XCTAssertEqual(FlexibleNozzleGradeMath.bandTemps(st), [190, 215, 240])
        let fs = field(st)
        XCTAssertEqual(Set(fs), [190, 215, 240], "★ Stepped: three bands")
        XCTAssertEqual(fs[0], 190, "★ the bottom layer is From"); XCTAssertEqual(fs[fs.count - 1], 240, "★ the top layer is To")
        let layer = { (k: Int) in fs[k * 4] }
        XCTAssertEqual(layer(11), 190); XCTAssertEqual(layer(12), 215, "★ the band edge at 12 mm"); XCTAssertEqual(layer(24), 240)
        let sm = FlexibleNozzleGrade(on: true, fromC: 190, toC: 240, stepped: false)
        let fd = field(sm)
        XCTAssertEqual(Set(fd).count, 36, "★ Default: a temperature per layer")
        for k in 1..<36 { XCTAssertGreaterThan(fd[k * 4], fd[(k - 1) * 4], "★ rises up the part") }
        let lines = FlexibleNozzleGradeMath.slicerLines(st, heightMM: 36)
        XCTAssertEqual(lines, ["190 °C to 12 mm · 215 °C to 24 mm · 240 °C"])
        let four = FlexibleNozzleGradeMath.slicerLines(FlexibleNozzleGrade(on: true, fromC: 180, toC: 260, stepped: true), heightMM: 123.4)
        let dflt = FlexibleNozzleGradeMath.slicerLines(sm, heightMM: 36)
        XCTAssertEqual(dflt, ["190 °C at the bed → 240 °C at 36 mm", "+5 °C every 3.6 mm up the part"])
        for l in lines + four + dflt {
            XCTAssertLessThanOrEqual(l.count, FlexibleRowCopy.maxChars, l); XCTAssertFalse(l.hasSuffix("…"), l)
        }
        XCTAssertLessThanOrEqual(four.count, 2, "★ two lines at most: \(four)")
        XCTAssertTrue(FlexibleNozzleGradeMath.pastTested(FlexibleNozzleGrade(on: true, fromC: 180, toC: 220), tested: [190, 220, 240]))
        XCTAssertFalse(FlexibleNozzleGradeMath.pastTested(sm, tested: [190, 220, 240]))
        print("FLEX-NG slicer lines: \(lines) · \(four) · \(dflt)")
        // RED CONTROL: Stepped ignored — a temperature per layer
        FlexibleNozzleGradeMath.controlSteppedSmooth = true
        XCTAssertGreaterThan(Set(field(st)).count, 3, "RED control (Stepped ignored) must not make bands")
        FlexibleNozzleGradeMath.controlSteppedSmooth = false
    }

    // MARK: 3 — Manual: a graded temperature changes the estimate layer by layer — hotter layers squish more (RED: no grade in the sim)

    func testAGradedTemperatureChangesTheEstimateLayerByLayer() async throws {
        let m = try await opened("his pad")
        m.setManual(true)
        m.setManualTemp(190)
        _ = try await FlexibleSquishFixture.build(m, "his pad · Manual 190 °C")
        try await FlexibleSquishFixture.solve(m, "his pad · Manual 190 °C")
        let gen = try XCTUnwrap(m.lattice?.generation)
        let e0 = deepest(m)
        let r0 = try XCTUnwrap(m.simRequest)
        XCTAssertTrue(r0.tempC.isEmpty, "no grade: the law's one temperature")

        m.setNozzleGrade(on: true)
        let g = try XCTUnwrap(m.settings.nozzleGrade)
        XCTAssertEqual(g.fromC, 190, "★ From starts at the row's temperature"); XCTAssertEqual(g.toC, 220, "★ To: the next tested above")
        let r1 = try XCTUnwrap(m.simRequest)
        XCTAssertEqual(r1.tempC.count, r1.rho.count, "★ a temperature per scene voxel")
        // (voxel CENTRES: the lowest sits half a voxel above the bed)
        XCTAssertEqual(Double(r1.tempC.min() ?? 0), 190, accuracy: 1.5); XCTAssertEqual(Double(r1.tempC.max() ?? 0), 220, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(r1.tempC.min() ?? 0, 190); XCTAssertLessThanOrEqual(r1.tempC.max() ?? 0, 220)
        XCTAssertEqual(m.lattice?.generation, gen, "★ the lattice is not rebuilt (the sims re-solve)")
        try await FlexibleSquishFixture.solve(m, "his pad · Manual 190 → 220 °C")
        let e1 = deepest(m)
        XCTAssertGreaterThan(e1, e0 * 1.05, "★ softer hot layers (220 °C) squish more: \(e0) → \(e1) mm")
        let lines = m.nozzleGradeLines().map(\.text)
        XCTAssertFalse(lines.isEmpty); XCTAssertFalse(lines.contains { $0.hasPrefix("Shown in the sim only") }, "Manual: no Auto note")

        // layer by layer: the same sim solved at 190 °C everywhere and graded — per FE element, the modulus ratio by height
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let sim = try XCTUnwrap(r1.sims.first)
        let flat = try scene.squishSolve(r1.with(tempC: [], key: "").request(sim))
        let graded = try scene.squishSolve(r1.request(sim))
        XCTAssertTrue(flat.ok && graded.ok, "\(flat.failure) \(graded.failure)")
        XCTAssertEqual(flat.elementE.count, graded.elementE.count)
        let up = simd_normalize(m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1))
        let (ex, ey) = (flat.nx - 1, flat.ny - 1)
        let eMax = Double(flat.elementE.max() ?? 1)
        var cells: [(h: Double, ratio: Double)] = []
        for e in flat.elementE.indices where Double(flat.elementE[e]) < 0.5 * eMax && flat.elementE[e] > 0 {
            let i = e % ex, j = (e / ex) % ey, k = e / (ex * ey)
            let c = flat.origin + (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * flat.spacing
            cells.append((simd_dot(c, up), Double(graded.elementE[e]) / Double(flat.elementE[e])))
        }
        XCTAssertGreaterThan(cells.count, 40, "lattice elements")
        cells.sort { $0.h < $1.h }
        let q = cells.count / 4
        let bottom = cells.prefix(q).map(\.ratio).reduce(0, +) / Double(q)
        let top = cells.suffix(q).map(\.ratio).reduce(0, +) / Double(q)
        var bands: [String] = []
        for b in 0..<6 {
            let s = cells[(b * cells.count / 6)..<((b + 1) * cells.count / 6)]
            bands.append(String(format: "%.0f mm %.2f", s.map(\.h).reduce(0, +) / Double(s.count), s.map(\.ratio).reduce(0, +) / Double(s.count)))
        }
        print(String(format: "FLEX-NG his pad Manual: deepest %.3f mm at 190 °C → %.3f mm graded 190→220 · E graded/flat bottom quarter %.3f · top quarter %.3f · bands [%@] · lines %@",
                     e0, e1, bottom, top, bands.joined(separator: " | "), "\(lines)"))
        XCTAssertGreaterThan(bottom, 0.8, "★ the bottom layers print near 190 °C (as firm)")
        XCTAssertLessThan(top, bottom - 0.15, "★ the top layers print hotter, softer")

        // Stepped on his pad: the voxels carry the bands' temperatures only — toggled quickly (two re-solves before either hands
        // over, resuming in any order), the sims still land
        m.setNozzleGradeStepped(true)
        XCTAssertEqual(Set(m.simRequest?.tempC ?? []), Set(FlexibleNozzleGradeMath.bandTemps(m.settings.nozzleGrade!).map { Float($0) }), "★ Stepped: bands")
        m.setNozzleGradeStepped(false)
        try await FlexibleSquishFixture.solve(m, "his pad · Stepped on / off quickly")
        XCTAssertEqual(deepest(m), e1, accuracy: 1e-6 * e1, "★ back to Default: the same estimate")
        m.setNozzleGradeStepped(true); m.setNozzleGradeStepped(false); m.setNozzleGradeStepped(true); m.setNozzleGradeStepped(false)
        try await FlexibleSquishFixture.solve(m, "his pad · four quick re-solves")
        XCTAssertEqual(deepest(m), e1, accuracy: 1e-6 * e1, "★ four quick re-solves still land")

        // RED CONTROL: the grade never reaches the sim — the estimate stays the 190 °C one
        FlexibleStageModel.controlNoGradeInSim = true
        m.regradeIfNeeded()
        XCTAssertTrue(m.simRequest?.tempC.isEmpty ?? false, "RED control: no per-layer temperature")
        try await FlexibleSquishFixture.solve(m, "his pad · RED")
        let eRed = deepest(m)
        XCTAssertEqual(eRed, e0, accuracy: 1e-6 * Swift.max(e0, 1), "RED control (no grade in the sim) must not change the estimate (\(eRed))")
        XCTAssertLessThan(eRed, e1)
        FlexibleStageModel.controlNoGradeInSim = false
    }

    // MARK: 4 — Auto: the grade drives the display sim, Auto's JOB BYTES unchanged (RED control: the grade leaks into the nozzle setting)

    func testAutoTakesTheGradeInTheSimAndItsJobBytesAreUnchanged() async throws {
        let m = try await opened("his pad")
        XCTAssertFalse(m.isManual)
        let job = jobBytes(m)
        let key = m.latticeSettingsKey
        _ = try await FlexibleSquishFixture.build(m, "his pad · Auto")
        let gen = try XCTUnwrap(m.lattice?.generation)
        m.setNozzleGrade(on: true)
        m.setNozzleGradeEnd(top: false, 190)
        m.setNozzleGradeEnd(top: true, 240)
        m.setNozzleGradeStepped(true)
        XCTAssertEqual(jobBytes(m), job, "★ Auto's job bytes unchanged by the grade")
        XCTAssertEqual(m.latticeSettingsKey, key, "★ the lattice's key unchanged")
        XCTAssertEqual(m.lattice?.generation, gen, "★ no rebuild")
        XCTAssertFalse(m.latticeIsStale)
        XCTAssertFalse(m.simRequest?.tempC.isEmpty ?? true, "★ Auto's display sim takes each layer's temperature")
        let lines = m.nozzleGradeLines().map(\.text)
        XCTAssertTrue(lines.contains(FlexibleRowCopy.nozzleGradeAutoNote), "★ Auto says the job keeps one °C: \(lines)")
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: try JSONEncoder().encode(m.settings))
        XCTAssertEqual(back.nozzleGrade, m.settings.nozzleGrade, "★ round-trips")
        print("FLEX-NG his pad Auto: grade \(String(describing: m.settings.nozzleGrade)) · lines \(lines)")

        // RED CONTROL: the grade leaks into Auto's one temperature — the job changes
        m.setNozzleGrade(on: false)
        let other = try XCTUnwrap((m.material?.testedTempsC ?? []).first { $0 != m.settings.nozzleTempC }, "premise: another tested °C")
        m.setNozzleGradeEnd(top: false, other)
        FlexibleStageModel.controlGradeSetsNozzle = true
        m.setNozzleGrade(on: true)
        XCTAssertNotEqual(jobBytes(m), job, "RED control (grade written as the nozzle setting) must change the job")
        FlexibleStageModel.controlGradeSetsNozzle = false
    }
}
