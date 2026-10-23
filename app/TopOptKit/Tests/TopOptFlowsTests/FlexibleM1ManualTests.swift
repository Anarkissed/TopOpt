// FlexibleM1ManualTests — round 7 · MANUAL, part M1: the toggle, the values, the lattice and the views.
//   His orders of 2026-10-22 ~02:30: "implement the manual add-on. Remove any of the auto processes and make it as simple to
//   understand as possible. The views become what the app assumes based on your values, so cards should say that when a view is
//   selected." His picks: a toggle Manual | Auto at the very top of the Squish modal, default Auto; density as BOTH % and walls in
//   beads; the whole part + an optional per-group override.
// On HIS live projects of 2026-10-21 (his pad, his l-bracket). Each RED control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleM1ManualTests: XCTestCase {

    override func tearDown() {
        FlexibleStageSettings.controlManualOffInDesignInputs = false
        FlexibleStageModel.controlManualLatticeOff = false
        super.tearDown()
    }

    func opened(_ dir: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return (r, m)
    }

    /// What reaches core: the run job (or its refusal) and the scene job.
    func jobBytes(_ m: FlexibleStageModel) -> String {
        let run: String
        do { run = try m.runJobJSON() } catch { run = "refused: \(error)" }
        let scene = (try? m.sceneJob()?.json) ?? "none"
        return run + "\n" + scene
    }

    // MARK: 1 — the toggle defaults to Auto; Auto stays byte-identical; Manual never reaches the job

    func testToggleDefaultsToAutoAndAutoStaysByteIdentical() async throws {
        for (dir, what) in [(FlexibleU21DeleteUndoTests.lbracketDir, "his l-bracket"), (FlexibleU21DeleteUndoTests.padDir, "his pad")] {
            let (_, m) = try await opened(dir, what)
            XCTAssertNil(m.settings.manual, "\(what): ★ an old save decodes as Auto")
            XCTAssertFalse(m.isManual, "\(what): ★ the toggle defaults to Auto")
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            let saved = String(decoding: try enc.encode(m.settings), as: UTF8.self)
            XCTAssertFalse(saved.contains("\"manual\""), "\(what): ★ Auto writes no manual key (old projects encode byte-identical)")
            let job = jobBytes(m), key = m.latticeSettingsKey, inputs = m.settings.designInputs

            m.setManual(true)
            XCTAssertTrue(m.isManual)
            XCTAssertNotNil(m.settings.manual?.part)
            XCTAssertEqual(jobBytes(m), job, "\(what): ★ Manual never reaches core's job (CORE LIST item 11)")
            XCTAssertNotEqual(m.latticeSettingsKey, key, "\(what): ★ Manual re-keys the lattice (his values build it)")
            let mine = try XCTUnwrap(m.settings.manual)

            m.setManual(false)
            XCTAssertFalse(m.isManual)
            XCTAssertEqual(m.settings.manual?.part, mine.part, "\(what): ★ his values kept for later")
            XCTAssertEqual(jobBytes(m), job, "\(what): ★ Auto's job bytes unchanged")
            XCTAssertEqual(m.settings.designInputs, inputs, "\(what): ★ Auto's lattice inputs unchanged")
            XCTAssertEqual(m.latticeSettingsKey, key, "\(what): ★ Auto's lattice key unchanged")

            // RED CONTROL: his values left in the lattice's key while Auto is on — Auto would rebuild
            FlexibleStageSettings.controlManualOffInDesignInputs = true
            XCTAssertNotEqual(m.latticeSettingsKey, key, "\(what): RED control (manual values in Auto's key) must differ")
            FlexibleStageSettings.controlManualOffInDesignInputs = false

            m.setManual(true)
            XCTAssertEqual(m.settings.manual?.part, mine.part, "\(what): ★ back on Manual, his values (no re-seed)")
        }
    }

    // MARK: 2 — the values round-trip

    func testManualValuesRoundTripAndOldSavesDecodeAsAuto() throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let dec = JSONDecoder()
        XCTAssertNil(try dec.decode(FlexibleStageSettings.self, from: try JSONEncoder().encode(s)).manual)
        s.manual = FlexibleManualSettings(on: true, part: FlexibleManualLattice(topology: "honeycomb", beads: 2, density: 0.24),
                                          groups: ["2": FlexibleManualLattice(topology: "gyroid", beads: 3, density: 0.155)])
        let back = try dec.decode(FlexibleStageSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertEqual(back, s, "★ Manual round-trips")
        XCTAssertEqual(back.manual?.lattice(group: 2).beads, 3)
        XCTAssertEqual(back.manual?.lattice(group: 1), back.manual?.part, "a group without its own uses the part's")
        // through the project's lattice settings (what project.json holds)
        let pm = try FlexibleHisProject.padProject(s)
        let lat = try dec.decode(LatticeSettings.self, from: try JSONEncoder().encode(pm.lattice))
        XCTAssertEqual(lat.flexible?.manual, s.manual, "★ through LatticeSettings")
        // off keeps the values
        s.manual?.on = false
        let off = try dec.decode(FlexibleStageSettings.self, from: try JSONEncoder().encode(s))
        XCTAssertFalse(off.isManual)
        XCTAssertEqual(off.manual?.part.beads, 2)
        XCTAssertNil(off.designInputs.manual, "★ off: not in the lattice's key")
    }

    // MARK: 3, 4 — RETIRED by P1 (his decisions of 2026-10-23: walls are WHOLE beads, the density is free and the cell follows; no
    // fractional-bead warning, no one-tap fix). The new relation, both ways, is FlexibleManualP1Tests.

    // MARK: 5 — a group's own lattice, and its removal

    func testGroupOverrideAndItsRemoval() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.setManual(true)
        let gs = m.squeezeGroups
        XCTAssertGreaterThanOrEqual(gs.count, 2, "premise: his pad has two groups (\(gs.map(\.id)))")
        let g = gs[0], other = gs[1]
        let part = try XCTUnwrap(m.manualLattice(group: nil))
        XCTAssertEqual(m.manualLattice(group: g.id), part, "★ same as the part")
        m.setGroupOwnLattice(g.id, own: true)
        XCTAssertEqual(m.settings.manual?.groups?[String(g.id)], part, "★ [Set its own] starts from the part's")
        m.setManualDensity(0.32, group: g.id)
        XCTAssertEqual(m.manualLattice(group: g.id)?.density ?? 0, 0.32, accuracy: 1e-12, "★ its own density")
        XCTAssertEqual(m.manualLattice(group: nil), part, "★ the part's untouched")
        XCTAssertEqual(m.manualLattice(group: other.id), part, "★ another group keeps the part's")
        m.setGroupOwnLattice(g.id, own: false)
        XCTAssertNil(m.settings.manual?.groups, "★ [Use the part's] drops it (nil, never [:])")
        XCTAssertEqual(m.manualLattice(group: g.id), part)
        // a group renumbered carries its own lattice; a group gone drops it
        let x = FlexibleManualLattice(topology: "gyroid", density: 0.2)
        XCTAssertEqual(FlexibleManualSettings.remap(["2": x, "3": part], rank: [2: 1]), ["1": x])
        XCTAssertNil(FlexibleManualSettings.remap(["3": x], rank: [2: 1]))
    }

    // MARK: 6 — the lattice field is built from his values (RED control: core's design)

    func testTheLatticeIsBuiltFromHisValues() async throws {
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.keepCombinedField = true
        let auto = try await FlexibleSquishFixture.build(m, "his pad · Auto")
        let autoReq = try XCTUnwrap(m.lastFERequest)
        XCTAssertTrue(autoReq.sims.contains { !$0.targets.isEmpty }, "premise: Auto's sims calibrate to core's design")
        func rhoSet(_ i: FlexibleLatticeInputs) -> Set<Float> {
            var s = Set<Float>()
            for (v, k) in zip(i.rho.values, i.mask.values) where k > 0.5 { s.insert((v * 1e4).rounded() / 1e4) }
            return s
        }
        let autoRhos = rhoSet(auto.inputs)
        XCTAssertGreaterThan(autoRhos.count, 2, "premise: Auto's lattice is graded (\(autoRhos.count) densities)")
        var mean = 0.0, n = 0
        for (v, k) in zip(auto.inputs.rho.values, auto.inputs.mask.values) where k > 0.5 { mean += Double(v); n += 1 }
        mean /= Double(max(n, 1))

        m.setManual(true)
        let seed = try XCTUnwrap(m.manualLattice(group: nil))
        XCTAssertEqual(seed.topology, m.designTopology, "★ starts from Auto's type")
        XCTAssertEqual(m.manualWalls(group: nil) ?? 0, 1, accuracy: 1e-9, "★ Auto's 1-bead walls")
        XCTAssertEqual(seed.density, mean, accuracy: 1e-6, "★ Auto's mean density at 1 bead (P1: the cell follows)")
        print(String(format: "FLEX-M1 his pad seed: %@ cell %.2f mm density %.4f (Auto's mean %.4f over %d voxels, %d densities)",
                     seed.topology, m.manualCellMM(group: nil) ?? -1, seed.density, mean, n, autoRhos.count))

        m.setManualDensity(0.30, group: nil)
        let g = m.squeezeGroups[0]
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualDensity(0.20, group: g.id)
        m.discardLattice()
        let built = try await FlexibleSquishFixture.build(m, "his pad · Manual")
        let rhos = rhoSet(built.inputs)
        XCTAssertTrue(rhos.isSubset(of: [0.2, 0.3]), "★ every lattice voxel at his densities (\(rhos.sorted().prefix(6)))")
        XCTAssertTrue(rhos.contains(0.3) && rhos.contains(0.2), "★ the part's AND Group 1's own (\(rhos))")
        XCTAssertEqual(built.inputs.topology, seed.topology == "honeycomb" ? .honeycomb : .gyroid, "★ his type")
        let part = try XCTUnwrap(m.manualLattice(group: nil))
        let bw = m.build.beadWidthMM
        XCTAssertEqual(Double(built.inputs.wallMM), FlexibleManualMath.wallMM(part, beadWidthMM: bw), accuracy: 1e-5, "★ his walls")
        if built.inputs.topology == .gyroid {
            XCTAssertEqual(Double(3.0915 * built.inputs.wallMM / 0.3), FlexibleManualMath.cellMM(part, beadWidthMM: bw), accuracy: 1e-3,
                           "★ the drawn cell is his cell")
        }
        // the combined field: Group 1's voxels at its own 0.2, every other lattice voxel at the part's 0.3
        let field = try XCTUnwrap(m.lastCombinedField)
        let mine = Set(m.manualOwnerGroups().filter { $0.value == g.id }.map(\.key))
        var g1 = 0, rest = 0
        for v in field.density.indices where field.density[v] >= 0 {
            let want: Float = mine.contains(field.owner[v]) ? 0.2 : 0.3
            XCTAssertEqual(field.density[v], want, accuracy: 1e-6)
            if want == 0.2 { g1 += 1 } else { rest += 1 }
            if abs(field.density[v] - want) > 1e-6 { break }
        }
        XCTAssertGreaterThan(g1, 0); XCTAssertGreaterThan(rest, 0)
        // the sims: his lattice's own estimate (no core depth to calibrate to), his type's law
        let req = try XCTUnwrap(m.lastFERequest)
        XCTAssertFalse(req.sims.isEmpty)
        XCTAssertTrue(req.sims.allSatisfy { $0.targets.isEmpty && $0.strainOp.allSatisfy { $0 == 0 } }, "★ the app's estimate, uncalibrated")
        XCTAssertEqual(req.law.topology, part.topology, "★ his type's law")
        XCTAssertTrue(m.latticeTunedPresses.isEmpty, "★ no press tuned to core's design")
        print("FLEX-M1 his pad Manual: densities \(rhos.sorted()) · Group 1 voxels \(g1) · others \(rest) · wall \(built.inputs.wallMM) mm · sims \(req.sims.count)")

        // RED CONTROL: core's design in Manual — the lattice is graded again, not his values
        FlexibleStageModel.controlManualLatticeOff = true
        m.recomputeAll()   // ★ M2: Manual asks core for no design — the red control's core design is asked for again
        m.discardLattice()
        let red = try await FlexibleSquishFixture.build(m, "his pad · Manual · RED")
        XCTAssertFalse(rhoSet(red.inputs).isSubset(of: [0.2, 0.3]), "RED control (core's design) must not be his densities")
        FlexibleStageModel.controlManualLatticeOff = false
    }

    // MARK: 8 — the Walls box reads "1 bead", never "1 beads" (reviewer check of M1, plain words)

    func testTheWallsUnitIsSingularForOneBead() {
        XCTAssertEqual(FlexibleManualCopy.wallsUnitFor(1), "bead")
        XCTAssertEqual(FlexibleManualCopy.wallsUnitFor(1.0), "bead")
        XCTAssertEqual(FlexibleManualCopy.wallsUnitFor(2), "beads")
        XCTAssertEqual(FlexibleManualCopy.wallsUnitFor(1.4), "beads")
        XCTAssertEqual(FlexibleManualCopy.wallsUnitFor(0.6), "beads")
    }

    // MARK: 7 — the view line, in Manual only

    func testTheViewLineIsInManualOnly() async throws {
        XCTAssertNil(FlexibleManualCopy.viewLine(views: [.bend], manual: false, weight: "10 lb"), "★ Auto: no line")
        XCTAssertEqual(FlexibleManualCopy.viewLine(views: [.bend], manual: true, weight: "10 lb"), "Bend · what your lattice does at 10 lb")
        XCTAssertEqual(FlexibleManualCopy.viewLine(views: [.play, .heatOff], manual: true, weight: "10 lb"), "Play · what your lattice does at 10 lb")
        XCTAssertEqual(FlexibleManualCopy.viewLine(views: [.xray, .heatOff], manual: true, weight: nil), "X-ray · bend estimated from your lattice")
        XCTAssertEqual(FlexibleManualCopy.viewLine(views: [], manual: true, weight: nil), "Heat · estimated from your lattice")
        XCTAssertNil(FlexibleManualCopy.viewLine(views: [.heatOff], manual: true, weight: nil), "no view on: no line")

        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.views = [.bend, .heatOff]
        XCTAssertNil(m.manualViewLine, "★ Auto: the card says nothing new")
        m.setManual(true)
        let line = try XCTUnwrap(m.manualViewLine, "★ Manual: the card says it is the app's estimate")
        XCTAssertTrue(line.hasPrefix("Bend · what your lattice does at "), line)
        XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars)
        XCTAssertFalse(line.hasSuffix("…"), line)
        print("FLEX-M1 his pad view line: '\(line)'")
        m.setManual(false)
        XCTAssertNil(m.manualViewLine)
    }
}
