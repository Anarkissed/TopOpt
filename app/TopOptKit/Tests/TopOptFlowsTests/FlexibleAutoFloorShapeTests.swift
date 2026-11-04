// FlexibleAutoFloorShapeTests — round 7 · AUTO FLOOR + GRADE ALONG THE SHAPE.
//   His decisions of 2026-10-23 ~00:35 (Auto when everything clamps): "SAY IT + SHAPE-ONLY GRADE" — one plain line
//   ("Every column at the softest tested lattice (14 %)" + the depth range Auto can reach at this weight) AND the drawn lattice
//   graded by the face's shape, like a no-data filament, marked as not designed from data. His words of ~02:45: "Just to confirm,
//   the grading follows the curve OR stamp, not just the curves, right? If I set a custom stamp, I'd want the grading based on
//   that" — so the Auto fallback AND Manual's grade read the face's ACTIVE shape (the curves, or the stamp).
// On HIS l-bracket of 2026-10-21 (restored the app's way), at 10 lb / 7 mm, its face on Stamp · Elbow 60 × 75 mm turned 90°.
// Each RED control is asserted red inside its test:
//   testAutoSaysEveryColumnIsAtTheFloor           the truth line + the reachable range; RED: today's blocker line alone
//   testAutoAtTheFloorGradesByTheStamp            the drawn lattice follows the stamp (and the curves on Curves); job bytes
//                                                 unchanged; RED: uniform 14.3 %; POSITIVE: 20 lb / 0.5 mm keeps core's field
//   testManualGradeAlongShapeFollowsTheStamp      10 → 30 % along Shape follows the stamp's outline; RED: the curve's grade;
//                                                 an old save's "curve" reads as "shape"
//   testManualPolish                              Nozzle row hidden in Manual (source pin), cells across from the drawing's own
//                                                 depth, To ≥ From, the data line names the type, the legend/tap read the pieces
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleAutoFloorShapeTests: XCTestCase {

    override func tearDown() {
        FlexibleStageModel.controlNoAutoFloorLine = false
        FlexibleStageModel.controlNoShapeFallback = false
        FlexibleStageModel.controlGradeAlongCurvesOnly = false
        super.tearDown()
    }

    static let face = 2000008   // his bracket's one pressed face ("Face 6" on his screen)

    func opened(_ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        return (r, m)
    }
    /// His set-up of 2026-10-23: 7 mm, 10 lb, Stamp · Elbow 60 × 75 mm turned 90° (`stamp` false: his curves).
    func hisSetup(_ m: FlexibleStageModel, kg: Double = 4.535929094356398, mm: Double = 7, stamp: Bool = true) async throws {
        let r = Self.face
        m.edit { s in guard var f = s.face(r) else { return }; f.deepestMM = mm; s.setFace(f) }
        m.setWeight(r, kg: kg)
        if stamp {
            m.setShape(r, "stamp")
            m.setStamp(r, source: .library("elbow"), shape: m.library?.shape("elbow"))
            m.updateStamp(r) { $0.widthMM = 60; $0.lengthMM = 75; $0.rotationDeg = 90 }
        } else {
            m.setShape(r, "curves")
        }
        try await FlexibleSquishFixture.settle(m, "his set-up")
    }
    func jobBytes(_ m: FlexibleStageModel) -> String {
        let run: String
        do { run = try m.runJobJSON() } catch { run = "refused: \(error)" }
        return run + "\n" + ((try? m.sceneJob()?.json) ?? "none")
    }
    func build(_ m: FlexibleStageModel, _ what: String) async throws -> FlexibleGeneratedLattice {
        m.discardLattice()
        m.keepCombinedField = true
        return try await FlexibleSquishFixture.build(m, what)
    }

    /// Per column of the face: (its shape value 0…1, the mean drawn density of its owned voxels), latticed columns only.
    func columnDensities(_ m: FlexibleStageModel, shape: [Double]) throws -> [(s: Double, rho: Double)] {
        let field = try XCTUnwrap(m.lastCombinedField)
        let k = try XCTUnwrap(m.key(Self.face))
        let st = try XCTUnwrap(m.stacks[k])
        var sum = [Double](repeating: 0, count: st.columns.count), n = [Int](repeating: 0, count: st.columns.count)
        for v in field.density.indices where field.density[v] >= 0 {
            guard v < field.owner.count, field.owner[v] == Self.face else { continue }
            let i = v % field.nx, j = (v / field.nx) % field.ny, kk = v / (field.nx * field.ny)
            let p = field.origin + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(kk) + 0.5) * field.spacing
            guard let hit = FlexibleStackMembership.hit(p, st) else { continue }
            sum[hit.col] += Double(field.density[v]); n[hit.col] += 1
        }
        return st.columns.indices.compactMap { c in
            n[c] > 0 && c < shape.count ? (shape[c], sum[c] / Double(n[c])) : nil
        }
    }

    // MARK: A — the truth line

    func testAutoSaysEveryColumnIsAtTheFloor() async throws {
        let (_, m) = try await opened("his l-bracket")
        try await hisSetup(m)
        let d = try XCTUnwrap(m.design(Self.face))
        let pressed = d.columns.filter { $0.status != "no_lattice" && $0.pressureMPa > 0 }
        print("FLEX-FLOOR A: \(m.displayName(Self.face)): columns \(d.columns.count), pressed \(pressed.count), too_firm \(d.tooFirm), ok \(d.ok), "
              + "too_soft \(d.tooSoft), beyond \(d.beyondData), no_lattice \(d.noLattice); buildable max "
              + String(format: "%.3f", d.columns.map(\.buildableDepthMM).filter(\.isFinite).max() ?? -1))
        let floor = try XCTUnwrap(m.autoFloor(region: Self.face), "★ his bracket at 10 lb / 7 mm: every column at the floor")
        print("FLEX-FLOOR A lines: \(floor.lines)")
        XCTAssertGreaterThanOrEqual(floor.atFloor, Int(0.95 * Double(floor.pressed)), "★ ≥ 95 % of the pressed columns")
        XCTAssertEqual(floor.lines.first, "Every column at the softest tested lattice (14 %)")
        XCTAssertTrue(floor.lines.count == 2 && floor.lines[1].hasPrefix("Auto reaches ") && floor.lines[1].hasSuffix(" at 10 lb"),
                      "★ the reachable range at his weight, his units: \(floor.lines)")
        XCTAssertLessThan(floor.reachMinMM, floor.reachMaxMM)
        let deepest = d.columns.compactMap { $0.nearestDepthMM }.max() ?? -1
        XCTAssertEqual(floor.reachMaxMM, deepest, accuracy: 1e-9, "★ core's own nearest depths (the stamp concentrates his 10 lb)")
        // his own words for the first line (49 characters — kept verbatim, one line on the 13" card); the range ≤ 44
        XCTAssertLessThanOrEqual(floor.lines[1].count, FlexibleRowCopy.maxChars, floor.lines[1])
        // the Auto row and the face card carry the lines
        XCTAssertTrue(m.autoFloorLines().contains(floor.lines[0]), "★ the Auto row")
        XCTAssertTrue(FlexibleFaceRows.floorLines(model: m, region: Self.face).contains(floor.lines[0]), "★ the face card")
        // RED CONTROL: today's line alone ("needs more weight or less depth")
        FlexibleStageModel.controlNoAutoFloorLine = true
        XCTAssertNil(m.autoFloor(region: Self.face), "RED control: no truth line")
        XCTAssertTrue(m.autoFloorLines().isEmpty, "RED control: the Auto row says only what it takes")
        FlexibleStageModel.controlNoAutoFloorLine = false
        // on his curves (the investigation's case): core builds 0.64 mm at most
        try await hisSetup(m, stamp: false)
        let c = try XCTUnwrap(m.autoFloor(region: Self.face), "★ his curves at 10 lb / 7 mm: at the floor too")
        print("FLEX-FLOOR A curves lines: \(c.lines) · \(c.atFloor)/\(c.pressed)")
        XCTAssertEqual(c.reachMaxMM, 0.64, accuracy: 0.05, "the investigation: 0.636 mm")
    }

    // MARK: B — the shape-only fallback

    func testAutoAtTheFloorGradesByTheStamp() async throws {
        let (_, m) = try await opened("his l-bracket")
        try await hisSetup(m)
        let job = jobBytes(m)
        let foot = try XCTUnwrap(m.shapeValues(region: Self.face), "the stamp's footprint, 0…1")
        XCTAssertEqual(foot.max() ?? 0, 1, accuracy: 1e-9)
        _ = try await build(m, "stamp, 10 lb / 7 mm")
        let cols = try columnDensities(m, shape: foot)
        let under = cols.filter { $0.s > 0.9 }.map(\.rho), outside = cols.filter { $0.s < 0.01 }.map(\.rho)
        func mean(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.reduce(0, +) / Double(a.count) }
        print(String(format: "FLEX-FLOOR B stamp: %d columns under (ρ %.3f), %d outside (ρ %.3f)", under.count, mean(under), outside.count, mean(outside)))
        XCTAssertFalse(under.isEmpty); XCTAssertFalse(outside.isEmpty)
        XCTAssertLessThan(mean(under) + 0.08, mean(outside), "★ softer (larger cells) under the stamp, firmer outside")
        let range = try XCTUnwrap(m.autoDataRange())
        XCTAssertEqual(mean(under), range.lowerBound, accuracy: 0.03, "★ the stamp's deepest press → the softest tested")
        XCTAssertEqual(mean(outside), range.upperBound, accuracy: 0.03, "★ no press → the firmest tested")
        XCTAssertEqual(m.autoShapeLine(region: Self.face), "Lattice shaped by your stamp \u{00B7} not from data")
        XCTAssertEqual(jobBytes(m), job, "★ core's job bytes unchanged")
        // RED CONTROL: core's flat field — every column at 14.3 %
        FlexibleStageModel.controlNoShapeFallback = true
        _ = try await build(m, "RED: no fallback")
        let flat = try columnDensities(m, shape: foot).map(\.rho)
        print(String(format: "FLEX-FLOOR B RED: ρ %.4f … %.4f", flat.min() ?? -1, flat.max() ?? -1))
        XCTAssertLessThan((flat.max() ?? 1) - (flat.min() ?? 0), 0.01, "RED control: core's uniform floor")
        XCTAssertNil(m.autoShapeLine(region: Self.face), "RED control: no marked line")
        FlexibleStageModel.controlNoShapeFallback = false

        // on Curves: graded by his curve (the soft centre's cells larger than the firm edge's)
        try await hisSetup(m, stamp: false)
        let s = try XCTUnwrap(m.shapeValues(region: Self.face))
        _ = try await build(m, "curves, 10 lb / 7 mm")
        let cc = try columnDensities(m, shape: s)
        let centre = cc.filter { $0.s > 0.9 }.map(\.rho), edge = cc.filter { $0.s < 0.2 }.map(\.rho)
        print(String(format: "FLEX-FLOOR B curves: centre ρ %.3f (%d), edge ρ %.3f (%d)", mean(centre), centre.count, mean(edge), edge.count))
        XCTAssertLessThan(mean(centre) + 0.05, mean(edge), "★ the curve's soft centre has the larger cells")
        XCTAssertEqual(m.autoShapeLine(region: Self.face), "Lattice shaped by your curve \u{00B7} not from data")

        // POSITIVE CONTROL: 20 lb / 0.5 mm — core reaches it: core's field, byte-identical
        try await hisSetup(m, kg: 2 * 4.535929094356398, mm: 0.5, stamp: false)
        XCTAssertNil(m.autoFloor(region: Self.face), "positive control: core reaches 0.5 mm at 20 lb")
        _ = try await build(m, "20 lb / 0.5 mm")
        let a = try XCTUnwrap(m.lastCombinedField).density
        FlexibleStageModel.controlNoShapeFallback = true
        _ = try await build(m, "20 lb / 0.5 mm, control")
        let b = try XCTUnwrap(m.lastCombinedField).density
        XCTAssertEqual(a, b, "★ positive control: core's field byte-identical")
    }

    // MARK: D — Manual's grade along the shape

    func testManualGradeAlongShapeFollowsTheStamp() async throws {
        let (_, m) = try await opened("his l-bracket")
        try await hisSetup(m)
        m.setManual(true)
        m.setManualType("gyroid", group: nil)
        m.setManualBeads(1, group: nil)
        m.setManualDensity(0.10, group: nil)
        m.setManualGrade(on: true, group: nil)
        m.setManualGradeValue(end: true, 0.30, group: nil)
        m.setManualGradeAlong("shape", group: nil)
        XCTAssertEqual(m.manualLattice(group: nil)?.grade.along, "shape")
        XCTAssertEqual(FlexibleManualCopy.alongOptions.map(\.label), ["Depth", "Across", "Shape"])
        let foot = try XCTUnwrap(m.shapeValues(region: Self.face))
        _ = try await build(m, "Manual 10 → 30 % along Shape")
        let cols = try columnDensities(m, shape: foot)
        let under = cols.filter { $0.s > 0.9 }.map(\.rho), outside = cols.filter { $0.s < 0.01 }.map(\.rho)
        func mean(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.reduce(0, +) / Double(a.count) }
        let outSpread = (outside.max() ?? 0) - (outside.min() ?? 0)
        print(String(format: "FLEX-SHAPE D: under ρ %.3f (%d), outside ρ %.3f (%d, spread %.4f)", mean(under), under.count, mean(outside),
                     outside.count, outSpread))
        XCTAssertEqual(mean(under), 0.30, accuracy: 0.02, "★ under the stamp's deepest press: To")
        XCTAssertEqual(mean(outside), 0.10, accuracy: 0.005, "★ outside the stamp: From")
        XCTAssertLessThan(outSpread, 0.005, "★ outside the stamp's outline the cells do not change")
        // RED CONTROL: today's grade along the drawn curves (the stamp ignored) — the cells change outside the stamp
        FlexibleStageModel.controlGradeAlongCurvesOnly = true
        _ = try await build(m, "RED: along the curves")
        let red = try columnDensities(m, shape: foot).filter { $0.s < 0.01 }.map(\.rho)
        print(String(format: "FLEX-SHAPE D RED: outside ρ %.3f … %.3f", red.min() ?? -1, red.max() ?? -1))
        let redMean = red.isEmpty ? -1 : red.reduce(0, +) / Double(red.count)
        XCTAssertTrue(abs(redMean - 0.10) > 0.05 || (red.max() ?? 0) - (red.min() ?? 0) > 0.05,
                      "RED control: the curve's grade ignores the stamp (outside the stamp not at From)")
        FlexibleStageModel.controlGradeAlongCurvesOnly = false

        // an old save's "curve" reads as "shape"
        let old = #"{"on":true,"by":"density","toDensity":0.3,"along":"curve"}"#
        let g = try JSONDecoder().decode(FlexibleManualGrade.self, from: Data(old.utf8))
        XCTAssertEqual(g.along, "shape", "★ an old save's Curve is Shape")
    }

    // MARK: C — Manual polish

    func testManualPolish() async throws {
        // the data line names the type
        XCTAssertEqual(FlexibleManualCopy.dataLine(min: 0.143, max: 0.362, past: false, topology: "gyroid"), "Data covers 14–36 % (gyroid)")
        XCTAssertEqual(FlexibleManualCopy.dataLine(min: 0.16, max: 0.45, past: false, topology: "honeycomb"), "Data covers 16–45 % (honeycomb)")
        for t in ["gyroid", "honeycomb"] {
            XCTAssertLessThanOrEqual(FlexibleManualCopy.dataLine(min: 0.16, max: 0.45, past: true, topology: t).count, FlexibleRowCopy.maxChars)
            XCTAssertTrue(FlexibleManualCopy.dataLine(min: 0.16, max: 0.45, past: true, topology: t).hasPrefix("Estimate past tested data"))
        }
        // ★ RE-PINNED (his words of 2026-10-23 ~03:05: "what's the difference between "temperature" and "nozzle" shouldn't they be the
        // same???"): More's ONE Nozzle °C row is drawn in Auto AND Manual (FlexibleNozzleGradeTests pins it; RED there: two rows)
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleFacePanel.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("FlexibleNozzleRows(model: model, padTarget: $padTarget)"), "★ the one Nozzle row, both modes")
        XCTAssertEqual(FlexibleStageModel.nozzleRows(manual: true, hasData: true, gradeOn: false), ["nozzle", "grade"])

        let (_, m) = try await opened("his l-bracket")
        try await hisSetup(m)
        m.setManual(true)
        m.setManualDensity(0.20, group: nil)
        // To ≥ From, even when a stored To sits below From (an older save)
        m.editManual(group: nil) { var o = $0; o.grade.toDensity = 0.12; return o }
        m.setManualGrade(on: true, group: nil)
        let l = try XCTUnwrap(m.manualLattice(group: nil))
        XCTAssertEqual(l.grade.toDensity, 0.30, accuracy: 1e-9, "★ To defaults to 1.5 × From")
        // the cells across use the drawing's own depth (the owners' own depth on their columns)
        m.setManualGrade(on: false, group: nil)
        let before = try XCTUnwrap(m.manualDepthMM(group: nil))
        _ = try await build(m, "Manual polish")
        let drawn = try XCTUnwrap(m.manualDepthMM(group: nil))
        let ownerDepths = m.manualDrawnDepths
        print(String(format: "FLEX-POLISH C: depth before build %.2f mm (column mean), drawn %.2f mm; owners %@", before, drawn,
                     ownerDepths.map { "\($0.key): \(String(format: "%.2f", $0.value.depth)) × \($0.value.columns)" }.joined(separator: ", ")))
        XCTAssertFalse(ownerDepths.isEmpty, "★ the drawing's own depths kept")
        let e = try XCTUnwrap(ownerDepths[Self.face])
        XCTAssertEqual(drawn, e.depth, accuracy: 1e-9, "★ one owner: the row's depth IS the drawing's")
        // the legend and a tap read the drawn piece in Manual
        let g = try XCTUnwrap(m.lattice)
        let ends = try XCTUnwrap(FlexibleManualCopy.legendEnds(g.inputs))
        let bw = m.manualBeadWidthMM
        let cell = FlexibleManualMath.cellMM(density: 0.20, beads: 1, topology: "gyroid", beadWidthMM: bw)
        print("FLEX-POLISH C legend: \(ends.lo) … \(ends.hi)")
        XCTAssertEqual(ends.lo, String(format: "20%% · gyroid %.1f mm", cell), "★ the legend reads the piece: type and exact cell")
        XCTAssertEqual(FlexibleManualCopy.tapUnit(type: 0, beads: 1, cellMM: cell), String(format: "density · gyroid · 1 bead · %.1f mm cell", cell))
    }
}
