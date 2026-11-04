// FlexibleManualP1Tests — round 7 · MANUAL P1: the full set, the model and the estimate.
//   His notes of 2026-10-23 ~00:00: "Why can't the density change but the bead stay the same size … Each lattice should have the
//   same set of settings as the entire model, otherwise, what is the point? … If we are saying this is going to be a manual
//   implementation of the lattice, then we should GIVE them a manual implementation of the lattice." His decisions ~00:35: walls
//   WHOLE beads, the density FREE, the CELL follows; a TYPE per group; out-of-data densities EXTRAPOLATED and MARKED.
// On HIS live projects of 2026-10-21 (his pad, his l-bracket). Each RED control is asserted red inside its test.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualP1Tests: XCTestCase {
    typealias Fx = FlexibleLatticeFixtures

    override func tearDown() {
        FlexibleStageModel.controlM1Tie = false
        FlexibleStageModel.controlHeldCell = [:]
        FlexibleStageModel.controlOneLatticePerPart = false
        super.tearDown()
    }

    func opened(_ dir: URL, _ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return (r, m)
    }
    func jobBytes(_ m: FlexibleStageModel) -> String {
        let run: String
        do { run = try m.runJobJSON() } catch { run = "refused: \(error)" }
        return run + "\n" + ((try? m.sceneJob()?.json) ?? "none")
    }
    static let projects = [(FlexibleU21DeleteUndoTests.padDir, "his pad"), (FlexibleU21DeleteUndoTests.lbracketDir, "his l-bracket")]

    // MARK: 1 — a free density keeps WHOLE beads and moves the cell (RED control: M1's tie → fractional beads)

    func testAFreeDensityKeepsWholeBeadsAndMovesTheCell() async throws {
        for (dir, what) in Self.projects {
            let (r, m) = try await opened(dir, what)
            let job = jobBytes(m)
            m.setManual(true)
            let bw = r.project.printParams.strutLineWidthMM
            let top = try XCTUnwrap(m.manualLattice(group: nil)).topology
            let u = FlexibleManualMath.unitCellMM(top, beadWidthMM: bw)
            for rho in [0.10, 0.15, 0.20, 0.30, 0.07] {   // his 10 %, 15 %, 20 %, 30 % of screenshots 29–32
                m.setManualDensity(rho, group: nil)
                XCTAssertEqual(m.manualLattice(group: nil)?.density ?? 0, rho, accuracy: 1e-12, "\(what): ★ the density is his")
                XCTAssertEqual(m.manualWalls(group: nil), 1, "\(what): ★ walls stay 1 whole bead at \(rho)")
                XCTAssertEqual(m.manualCellMM(group: nil) ?? 0, u / rho, accuracy: 1e-9, "\(what): ★ the cell follows: unit / ρ")
            }
            m.setManualDensity(0.20, group: nil)
            let c1 = try XCTUnwrap(m.manualCellMM(group: nil))
            m.setManualBeads(2, group: nil)
            XCTAssertEqual(m.manualLattice(group: nil)?.density ?? 0, 0.20, accuracy: 1e-12, "\(what): ★ 2 beads: the density stays")
            XCTAssertEqual(m.manualCellMM(group: nil) ?? 0, 2 * c1, accuracy: 1e-9, "\(what): ★ 2 beads: the cell doubles")
            XCTAssertEqual(try FlexibleCore.cellSizeMM(topology: top, density: 0.2, beadsPerWall: 2, beadWidthMM: bw), 2 * c1, accuracy: 1e-9,
                           "\(what): ★ core's own relation agrees")
            m.setManualBeads(7, group: nil)
            XCTAssertEqual(m.manualWalls(group: nil), 3, "\(what): walls held to 1–3 beads")
            XCTAssertEqual(jobBytes(m), job, "\(what): ★ Manual never reaches core's job")
            print(String(format: "FLEX-P1 %@: %@ 20 %% → cell %.2f mm at 1 bead, %.2f mm at 2 beads", what, top, c1, 2 * c1))

            // RED CONTROL: M1's tie — the cell held, the walls follow the density (his "Walls 1.4 beads · not a whole bead")
            m.setManualBeads(1, group: nil)
            m.setManualDensity(0.15, group: nil)
            FlexibleStageModel.controlM1Tie = true
            FlexibleStageModel.controlHeldCell = [:]
            m.setManualDensity(0.20, group: nil)
            let tied = try XCTUnwrap(m.manualWalls(group: nil))
            XCTAssertGreaterThan(abs(tied - tied.rounded()), 0.05, "\(what): RED control (M1's tie) must give fractional beads (\(tied))")
            FlexibleStageModel.controlM1Tie = false
            FlexibleStageModel.controlHeldCell = [:]
        }
    }

    // MARK: 2 — the linked trio, both ways (density ⇄ cell ⇄ cells across), the part's and a group's own

    func testTheLinkedTrioBothWays() async throws {
        for (dir, what) in Self.projects {
            let (r, m) = try await opened(dir, what)
            m.setManual(true)
            let bw = r.project.printParams.strutLineWidthMM
            let g = try XCTUnwrap(m.squeezeGroups.first)
            m.setGroupOwnLattice(g.id, own: true)
            for grp in [nil, Optional(g.id)] {
                let tag = "\(what) · \(grp.map { "group \($0)" } ?? "part")"
                m.setManualBeads(2, group: grp)
                let depth = try XCTUnwrap(m.manualDepthMM(group: grp), "\(tag): the lattice's depth from its face-prisms")
                // density → cell, cells across
                m.setManualDensity(0.25, group: grp)
                var l = try XCTUnwrap(m.manualLattice(group: grp))
                let cell = FlexibleManualMath.cellMM(l, beadWidthMM: bw)
                XCTAssertEqual(m.manualCellMM(group: grp) ?? 0, cell, accuracy: 1e-12)
                XCTAssertEqual(m.manualCellsAcross(group: grp) ?? 0, depth / cell, accuracy: 1e-9, "\(tag): ★ cells across = depth ÷ cell")
                // cell → density
                m.setManualCell(cell * 1.5, group: grp)
                l = try XCTUnwrap(m.manualLattice(group: grp))
                XCTAssertEqual(l.density, 0.25 / 1.5, accuracy: 1e-9, "\(tag): ★ the cell moves the density at 2 beads")
                XCTAssertEqual(l.beads, 2, "\(tag): ★ the walls stay")
                XCTAssertEqual(m.manualCellsAcross(group: grp) ?? 0, depth / (cell * 1.5), accuracy: 1e-9)
                // cells across → cell → density
                m.setManualCellsAcross(3, group: grp)
                XCTAssertEqual(m.manualCellMM(group: grp) ?? 0, depth / 3, accuracy: 1e-6, "\(tag): ★ 3 across: cell = depth / 3")
                XCTAssertEqual(m.manualCellsAcross(group: grp) ?? 0, 3, accuracy: 1e-6)
                l = try XCTUnwrap(m.manualLattice(group: grp))
                XCTAssertEqual(l.density, 2 * FlexibleManualMath.unitCellMM(l.topology, beadWidthMM: bw) / (depth / 3), accuracy: 1e-9,
                               "\(tag): ★ … and the density follows")
                // the facts: under 2 cells flagged, never blocking
                m.setManualCellsAcross(1.5, group: grp)
                let facts = m.manualFacts(group: grp)
                XCTAssertTrue(facts.contains { $0.text == FlexibleManualCopy.underTwoCells && $0.warning }, "\(tag): ★ under 2 flagged (\(facts))")
                m.setManualCellsAcross(4, group: grp)
                XCTAssertFalse(m.manualFacts(group: grp).contains { $0.text == FlexibleManualCopy.underTwoCells })
                for f in m.manualFacts(group: grp) {
                    XCTAssertLessThanOrEqual(f.text.count, FlexibleRowCopy.maxChars, "one line: \(f.text)")
                    XCTAssertFalse(f.text.hasSuffix("…"), "never cut: \(f.text)")
                }
                print(String(format: "FLEX-P1 %@: depth %.2f mm · %@", tag, depth, m.manualFacts(group: grp).map(\.text).joined(separator: " | ")))
            }
            XCTAssertTrue(m.settings.manual?.hasOwn(group: g.id) == true, "\(what): the group keeps its own")
        }
        // every label one line
        let C = FlexibleManualCopy.self
        for s in [C.title, C.sameAsPart, C.ownLattice, C.underTwoCells, C.cellOutsideDrawn, C.dataLine(min: 0.143, max: 0.362, past: true),
                  C.cellsLine(12.3, wallMM: 1.35), C.cellsLine(nil, wallMM: 1.35), C.cellsAcross + " · no prism yet"] {
            XCTAssertLessThanOrEqual(s.count, FlexibleRowCopy.maxChars, "one line: \(s)")
            XCTAssertFalse(s.hasSuffix("…"), "never cut: \(s)")
        }
        XCTAssertEqual(FlexibleManualLatticeRows.rows(group: nil, gradeOn: true),
                       ["type", "walls", "density", "cell", "cellsAcross", "grade", "gradeBy", "from", "to", "along", "style", "facts"],
                       "★ RE-PINNED (his words of 2026-10-23 ~03:05: \"shouldn't they be the same???\"): the temperature is More's one Nozzle °C row")
        XCTAssertEqual(FlexibleManualLatticeRows.rows(group: 2, gradeOn: false),
                       ["type", "walls", "density", "cell", "cellsAcross", "grade", "facts"], "★ a group: the same set (no temperature)")
    }

    // MARK: 3 — a group's own type / walls / density round-trip, and the card IS what is drawn (RED control: M1's one lattice per part)

    func testAGroupsOwnTypeWallsAndDensityRoundTripAndTheCardIsWhatIsDrawn() async throws {
        let (r, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.keepCombinedField = true
        m.setManual(true)
        let bw = r.project.printParams.strutLineWidthMM
        m.setManualType("gyroid", group: nil)
        m.setManualDensity(0.20, group: nil)
        let g = try XCTUnwrap(m.squeezeGroups.first)
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("honeycomb", group: g.id)
        m.setManualBeads(2, group: g.id)
        m.setManualDensity(0.25, group: g.id)
        let temps = m.material?.testedTempsC ?? []
        let hot = try XCTUnwrap(temps.max(), "premise: tested temperatures")
        m.setManualTemp(hot)
        // round-trip
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: try JSONEncoder().encode(m.settings))
        XCTAssertEqual(back.manual, m.settings.manual, "★ round-trips")
        let own = try XCTUnwrap(back.manual?.lattice(group: g.id))
        XCTAssertEqual(own.topology, "honeycomb"); XCTAssertEqual(own.beads, 2); XCTAssertEqual(own.density, 0.25, accuracy: 1e-12)
        XCTAssertEqual(back.manual?.part.topology, "gyroid", "★ the part keeps its own type")
        // ★ RE-PINNED (his words of 2026-10-23 ~03:05: "what's the difference between "temperature" and "nozzle" shouldn't they be
        // the same???"): ONE nozzle setting — Manual writes it, no second copy
        XCTAssertNil(back.manual?.tempC); XCTAssertEqual(back.nozzleTempC, hot, "★ one nozzle setting")
        let cardCell = try XCTUnwrap(m.manualCellMM(group: g.id))
        XCTAssertEqual(cardCell, 2 * 2 * bw / 0.25, accuracy: 1e-9, "★ the card: honeycomb d = 2t/ρ at 2 beads")

        let built = try await FlexibleSquishFixture.build(m, "his pad · Manual P1")
        let f = built.inputs
        let mw = try XCTUnwrap(f.manualWall, "★ the field carries his walls"), mt = try XCTUnwrap(f.manualType, "★ … and his types")
        let field = try XCTUnwrap(m.lastCombinedField)
        let mine = Set(m.manualOwnerGroups().filter { $0.value == g.id }.map(\.key))
        var checked = 0, other = 0
        var probe: SIMD3<Float>?
        for v in field.density.indices where field.density[v] >= 0 {
            guard v < f.rho.values.count else { break }
            let ownV = mine.contains(field.owner[v])
            let wantT: Float = ownV ? Float(2 * bw) : Float(bw), wantK: Float = ownV ? 1 : 0, wantR: Float = ownV ? 0.25 : 0.20
            XCTAssertEqual(mw.values[v], wantT, accuracy: 1e-6); XCTAssertEqual(mt.values[v], wantK)
            XCTAssertEqual(f.rho.values[v], wantR, accuracy: 1e-6)
            if ownV { checked += 1 } else { other += 1 }
            if abs(mw.values[v] - wantT) > 1e-6 || abs(f.rho.values[v] - wantR) > 1e-6 { break }
            // a voxel deep inside the group (all 26 neighbours its own): the drawn wall is checked there
            if ownV, probe == nil {
                let i = v % f.rho.nx, j = (v / f.rho.nx) % f.rho.ny, k = v / (f.rho.nx * f.rho.ny)
                if i > 1, j > 1, k > 1, i < f.rho.nx - 2, j < f.rho.ny - 2, k < f.rho.nz - 2 {
                    var all = true
                    for dk in -1...1 { for dj in -1...1 { for di in -1...1 {
                        let w = ((k + dk) * f.rho.ny + (j + dj)) * f.rho.nx + (i + di)
                        if mt.values[w] != 1 || f.rho.values[w] != 0.25 || mw.values[w] != Float(2 * bw) { all = false }
                    } } }
                    if all { probe = f.rho.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * f.rho.spacing }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "the group's voxels"); XCTAssertGreaterThan(other, 0, "the part's voxels")
        let p = try XCTUnwrap(probe, "a voxel inside the group")
        let drawn = FlexibleLatticeField.wall(p, f)
        let card = FlexibleLatticeField.honeycombWall(p, f, d: Float(cardCell), t: Float(2 * bw))
        XCTAssertEqual(drawn, card, accuracy: 1e-5, "★ the wall drawn there is the card's honeycomb (its cell, its 2-bead wall)")
        // the sims: his temperature, the extended law, the group's own type
        let req = try XCTUnwrap(m.lastFERequest)
        XCTAssertEqual(req.law.tempC, hot, "★ the estimate uses his temperature")
        XCTAssertTrue(req.law.extrapolate, "★ Manual's law extends past the data")
        XCTAssertEqual(req.simTopology[FlexibleSim.groupID(g.number)], "honeycomb", "★ the group's sim reads its own type")
        if let s = req.sims.first(where: { $0.id == FlexibleSim.groupID(g.number) }) {
            XCTAssertEqual(req.request(s).law.topology, "honeycomb")
        }
        print(String(format: "FLEX-P1 his pad: group voxels %d · part voxels %d · card d %.3f mm · drawn − card %.2e mm · probe %@",
                     checked, other, cardCell, abs(drawn - card), "\(p)"))

        // RED CONTROL: M1's one lattice per part — the group's card says honeycomb / 2 beads, the drawing is the part's gyroid
        FlexibleStageModel.controlOneLatticePerPart = true
        m.discardLattice()
        let red = try await FlexibleSquishFixture.build(m, "his pad · Manual P1 · RED")
        XCTAssertNil(red.inputs.manualType, "RED control: no per-group type")
        XCTAssertGreaterThan(abs(FlexibleLatticeField.wall(p, red.inputs) - card), 1e-3, "RED control (one lattice per part) must not draw the card")
        FlexibleStageModel.controlOneLatticePerPart = false
    }

    // MARK: 4 — the estimate EXTRAPOLATES below 14.3 % (monotone, no kink) and the card marks it (RED control: the clamp)

    func testTheEstimateExtrapolatesPastTheDataAndTheCardMarksIt() async throws {
        let path = FlexibleHisProject.materialsPath
        let set = try FlexibleCore.curveSet(path: path, materialID: "varioshore_tpu", tempC: 190, topology: "gyroid")
        let lo = set.densityMin, hi = set.densityMax
        func law(_ x: Bool, _ t: Double = 190) -> FlexSquishLawInfo {
            FlexSquishLawInfo(materialsPath: path, materialID: "varioshore_tpu", topology: "gyroid", tempC: t, shapeOnly: false, extrapolate: x)
        }
        func e(_ rho: Double, _ x: Bool = true, strain: Double = 0.1) throws -> Double {
            try FlexibleCore.squishModulus(law: law(x), rho: rho, strain: strain, skinFrac: 0)
        }
        // monotone: never falls; strictly rises above the solver's own floor (1e-4 of the solid modulus, every voxel's least)
        let floor = try e(0.01)
        var prev = 0.0
        for rho in stride(from: 0.05, through: 0.6, by: 0.01) {
            let v = try e(rho)
            if prev > floor * (1 + 1e-9) { XCTAssertGreaterThan(v, prev, "★ monotone at ρ \(rho)") } else { XCTAssertGreaterThanOrEqual(v, prev) }
            prev = v
        }
        let nFit = log(try e(lo) / e(lo - 0.01)) / log(lo / (lo - 0.01))
        print(String(format: "FLEX-P1 the fitted exponent below the data ≈ %.2f (Gibson–Ashby's textbook: 2); the solver's floor %.4f MPa", nFit, floor))
        XCTAssertEqual(try e(lo), try e(lo, false), accuracy: 1e-12, "★ at the end row: the data itself")
        XCTAssertEqual(try e(0.25), try e(0.25, false), accuracy: 1e-12, "★ inside the data: unchanged")
        let dl = 0.004
        let below = (try e(lo) - e(lo - dl)) / dl, above = (try e(lo + dl) - e(lo)) / dl
        XCTAssertEqual(below / above, 1, accuracy: 0.25, "★ no kink at the softest row (slopes \(below) / \(above))")
        let dh = (try e(hi) - e(hi - dl)) / dl, uh = (try e(hi + dl) - e(hi)) / dl
        XCTAssertEqual(uh / dh, 1, accuracy: 0.25, "★ no kink at the firmest row (slopes \(dh) / \(uh))")
        XCTAssertLessThan(try e(0.05), 0.5 * (try e(lo)), "★ a 5 % lattice is clearly softer than 14.3 %")
        print(String(format: "FLEX-P1 extrapolation (gyroid 190 °C, ε 0.1): rows %.3f–%.3f · E(0.05) %.4f · E(0.10) %.4f · E(%.3f) %.4f · E(0.50) %.4f MPa; slopes at lo %.3f/%.3f",
                     lo, hi, try e(0.05), try e(0.10), lo, try e(lo), try e(0.5), below, above))
        // RED CONTROL: the clamp — every soft lattice is the 14.3 % row
        XCTAssertEqual(try e(0.05, false), try e(lo, false), accuracy: 1e-12, "RED control (the clamp) must be flat below the data")
        // ★ the temperature changes the estimate
        XCTAssertGreaterThan(abs(try FlexibleCore.squishModulus(law: law(true, 240), rho: 0.2, strain: 0.1, skinFrac: 0) - (try e(0.2))), 1e-6,
                             "★ 240 °C is another curve set")

        // the card says so, on his pad
        let (_, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.setManual(true)
        let g = try XCTUnwrap(m.squeezeGroups.first)
        m.setManualDensity(0.10, group: nil)
        XCTAssertTrue(m.manualPastData(group: g.id), "★ 10 %: past the data")
        let past = m.manualFacts(group: g.id).first { $0.text.hasPrefix("Estimate past tested data") }
        XCTAssertNotNil(past, "★ the card marks it (\(m.manualFacts(group: g.id)))")
        XCTAssertEqual(past?.warning, true)
        m.setManualDensity(0.20, group: nil)
        XCTAssertFalse(m.manualPastData(group: g.id))
        XCTAssertTrue(m.manualFacts(group: g.id).contains { $0.text.hasPrefix("Data covers") }, "★ inside: the data's span")
        m.setManualGrade(on: true, group: nil)
        m.setManualGradeValue(end: true, 0.5, group: nil)
        XCTAssertTrue(m.manualPastData(group: g.id), "★ a grade reaching 50 % is past the data too")
        print("FLEX-P1 his pad facts: \(m.manualFacts(group: g.id).map(\.text))")
    }

    // MARK: 5 — the grade: along the depth, smooth and stepped, by density and by cell (pure)

    func testTheGradeAlongTheDepth() {
        var l = FlexibleManualLattice(topology: "gyroid", beads: 1, density: 0.15)
        XCTAssertEqual(FlexibleManualMath.density(l, at: 0.7, steps: 4, beadWidthMM: 0.45), 0.15, "off: one density")
        l.grade = FlexibleManualGrade(on: true, by: "density", toDensity: 0.35, along: "depth")
        XCTAssertEqual(FlexibleManualMath.density(l, at: 0, steps: 4, beadWidthMM: 0.45), 0.15, accuracy: 1e-12)
        XCTAssertEqual(FlexibleManualMath.density(l, at: 0.5, steps: 4, beadWidthMM: 0.45), 0.25, accuracy: 1e-12)
        XCTAssertEqual(FlexibleManualMath.density(l, at: 1, steps: 4, beadWidthMM: 0.45), 0.35, accuracy: 1e-12)
        l.stepped = true
        let st = stride(from: 0.0, through: 1.0, by: 0.05).map { FlexibleManualMath.density(l, at: $0, steps: 4, beadWidthMM: 0.45) }
        XCTAssertEqual(Set(st.map { ($0 * 1e6).rounded() }).count, 4, "★ stepped: 4 flat bands")
        l.stepped = false
        l.grade.by = "cell"
        let a = FlexibleManualMath.cellMM(density: 0.15, beads: 1, topology: "gyroid", beadWidthMM: 0.45)
        let b = FlexibleManualMath.cellMM(density: 0.35, beads: 1, topology: "gyroid", beadWidthMM: 0.45)
        let mid = FlexibleManualMath.density(l, at: 0.5, steps: 4, beadWidthMM: 0.45)
        XCTAssertEqual(FlexibleManualMath.cellMM(density: mid, beads: 1, topology: "gyroid", beadWidthMM: 0.45), (a + b) / 2, accuracy: 1e-9,
                       "★ by cell: the cell moves evenly, the density follows")
        XCTAssertEqual(FlexibleManualMath.gradeValue(l, end: true, beadWidthMM: 0.45), b, accuracy: 1e-9)
        let l2 = FlexibleManualMath.withGradeValue(l, end: false, 2 * a, beadWidthMM: 0.45)
        XCTAssertEqual(l2.density, 0.075, accuracy: 1e-9, "★ From in mm moves the start's density")
    }

    // MARK: 6 — old (M1) saves map: their cell → a density at 1 bead, nothing jumps

    func testOldSavesMapTheirCellToADensityAtOneBead() async throws {
        let bw = 0.45, u = 3.0915 * bw
        let old = #"{"groups":{"1":{"cellMM":9.3,"density":0.3,"topology":"honeycomb"}},"on":true,"part":{"cellMM":9.3,"density":0.15,"topology":"gyroid"}}"#
        let dec = try JSONDecoder().decode(FlexibleManualSettings.self, from: Data(old.utf8))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try enc.encode(dec), as: UTF8.self), old, "★ an unmapped old save writes back byte-identical")
        let r = dec.resolved(beadWidthMM: bw)
        XCTAssertEqual(r.part.beads, 1)
        XCTAssertEqual(r.part.density, u / 9.3, accuracy: 1e-9)
        XCTAssertEqual(FlexibleManualMath.cellMM(r.part, beadWidthMM: bw), 9.3, accuracy: 1e-9, "★ the part's cell kept")
        let g = try XCTUnwrap(r.groups?["1"])
        let wPart = 9.3 * 0.15 / u
        XCTAssertEqual(g.topology, "gyroid", "★ the group was drawn at the part's type")
        XCTAssertEqual(g.density, 0.3 / wPart, accuracy: 1e-9)
        XCTAssertEqual(FlexibleManualMath.cellMM(g, beadWidthMM: bw), u * wPart / 0.3, accuracy: 1e-9, "★ the group's DRAWN cell kept")
        XCTAssertNil(r.part.legacyCellMM); XCTAssertNil(g.legacyCellMM)
        XCTAssertTrue(String(decoding: try enc.encode(r), as: UTF8.self).contains("\"beads\":1"), "★ the new form once mapped")

        // through the model on his pad: the old save opens at its cell; its first edit writes the new form
        let (rp, m) = try await opened(FlexibleU21DeleteUndoTests.padDir, "his pad")
        m.edit { $0.manual = dec }
        let pbw = rp.project.printParams.strutLineWidthMM
        let top = FlexibleManualMath.unitCellMM("gyroid", beadWidthMM: pbw)
        XCTAssertEqual(m.manualCellMM(group: nil) ?? 0, 9.3, accuracy: 1e-9, "★ his old cell, at 1 bead")
        XCTAssertEqual(m.manualLattice(group: nil)?.density ?? 0, top / 9.3, accuracy: 1e-9)
        m.setManualBeads(2, group: nil)
        XCTAssertNil(m.settings.manual?.part.legacyCellMM, "★ the first edit writes the new form")
        XCTAssertNil(m.settings.manual?.groups?["1"]?.legacyCellMM)
        XCTAssertEqual(m.manualCellMM(group: nil) ?? 0, 18.6, accuracy: 1e-9)
    }

    // MARK: 7 — the GPU draws the per-group walls and types exactly as the Swift field (RED control: the grids dropped)

    func testTheGPUDrawsThePerGroupWallsAndTypes() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        var f = Fx.boxInputs(.gyroid)
        let g = f.rho
        var w = g.values, t = g.values, rho = g.values
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let v = (k * g.ny + j) * g.nx + i
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
            w[v] = p.x < 20 ? 0.45 : 0.9          // 1 bead | 2 beads
            t[v] = p.y < 20 ? 0 : 1               // gyroid | honeycomb
            if p.x < 12 { rho[v] = 0.2 }          // a uniform group (the exact cell) beside the graded rest
        } } }
        f.rho = FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: rho)
        f.wallMM = 0.45; f.lMinMM = 3.0915 * 0.45 / 0.9; f.lMaxMM = 3.0915 * 0.9 / 0.05
        f.manualWall = FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: w)
        f.manualType = FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: t)
        pass.upload(Fx.layer(f, token: 41))
        let ref = try XCTUnwrap(pass.referenceInputs)
        XCTAssertNotNil(ref.manualWall, "the grids reach the GPU")
        let pts = Fx.probePoints(400)
        let gpu = try XCTUnwrap(pass.probe(pts))
        var worst: Float = 0, honey = 0, gyro = 0
        for (i, p) in pts.enumerated() {
            worst = max(worst, abs(gpu[i] - FlexibleLatticeField.lattice(at: p, ref)))
            if ref.manualType!.sample(p) >= 0.5 { honey += 1 } else { gyro += 1 }
        }
        var plain = ref; plain.manualWall = nil; plain.manualType = nil
        let miss = pts.indices.map { abs(gpu[$0] - FlexibleLatticeField.lattice(at: pts[$0], plain)) }.max() ?? 0
        print("FLEX-P1 GPU manual: max |gpu − swift| = \(worst) mm over \(pts.count) points (\(gyro) gyroid side, \(honey) honeycomb side); RED control (grids dropped) \(miss) mm")
        XCTAssertLessThanOrEqual(worst, 5e-3, "★ the GPU's per-group walls and types are the Swift field's")
        XCTAssertGreaterThan(honey, 20); XCTAssertGreaterThan(gyro, 20)
        XCTAssertGreaterThan(miss, 0.1, "RED control (the grids dropped) must miss")
    }
}
