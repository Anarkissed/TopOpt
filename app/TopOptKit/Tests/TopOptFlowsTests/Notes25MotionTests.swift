// Notes25MotionTests — ★ his iPad notes 2026-11-23 on release 16 (img 2 + 3), builder C ("motion"):
//   C1 "The exaggeration goes wayyy too high ... 60x is way too high for *half* the exaggeration": the slider is scaled to the part.
//   C2 "make it actually look like it was bending/breaking. Ensure the stress map changes along with the movement. I should be able
//      to see through the stress map where the yield is happening ahead of time": the motion runs the LOAD; shape and colours share
//      it; one fixed colour scale; the marker where the colours first reach the top.
//   C3 (362's investigation, numbers/REPORT.md): a print file's result is a LATTICED result with ONE strength answer — core's
//      governing margin (the weakest strut 1.34× vs the solid 2.66× at 50 %), one place where it gives first, the same words in the
//      Checks, Details, the versions line and Break; its colours = how close each place is to giving way.
// The fixtures go through the real path his results take (a print file's report + fields.bin + its mesh → LatticeFileButton.outcome
// → ResultsModel), with his v8 stand's NUMBERS (job f1cd34dce90548b5, read 11-23) on a small grid — never his job's files.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// His stand's print-file result in miniature.
enum Notes25Fixture {
    static let nx = 6, ny = 4, nz = 4
    static let spacing = 5.0
    /// The weakest strut (his: 1.34×, 2.25 mm, 15.6 mm, axial 0.13 N against 29.8 N·mm — it bends).
    static let weakestAt = SIMD3<Double>(20, 10, 10)
    /// A triangle along the weakest strut, one in the solid's weakest voxel, one where nothing was judged.
    static let onStrut: [SIMD3<Float>] = [SIMD3(20, 10.5, 9), SIMD3(20.5, 10, 10), SIMD3(20, 10, 11)]
    static let onSolid: [SIMD3<Float>] = [SIMD3(2, 2, 2), SIMD3(3, 2, 2), SIMD3(2, 3, 2)]
    static let unjudged: [SIMD3<Float>] = [SIMD3(17, 17, 17), SIMD3(18, 17, 17), SIMD3(17, 18, 17)]

    static func stl(_ tris: [[SIMD3<Float>]]) -> Data {
        var d = Data(count: 80)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        u32(UInt32(tris.count))
        for t in tris {
            f32(0); f32(0); f32(1)
            for p in t { f32(p.x); f32(p.y); f32(p.z) }
            d.append(Data(count: 2))
        }
        return d
    }

    /// Its displacement at a node: a cantilever-like sag that grows along x (his part's largest is 0.57 mm).
    static func sag(_ x: Double) -> Float { Float(0.0005 * x * x) }

    /// fields.bin v1 (core/include/topopt/fields.hpp): block 1 the solve (stress + displacement), block 2 the solid's margin per
    /// voxel (requested_volume_fraction −1: judged for x-index ≤ 1, NaN elsewhere).
    static func fieldsBin() -> Data {
        var d = Data([1, 0, 0, 0])
        func i32(_ v: Int32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func i64(_ v: Int64) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f64(_ v: Double) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 8)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        let voxels = nx * ny * nz, nodes = (nx + 1) * (ny + 1) * (nz + 1)
        i32(Int32(nx)); i32(Int32(ny)); i32(Int32(nz)); f64(0); f64(0); f64(0); f64(spacing); f64(spacing * spacing * spacing)
        i32(2); i32(0)
        // block 1: the solve — stress everywhere (so every node touches material), the sag
        f64(1); f64(67.3); i32(0); i32(0); i64(Int64(voxels)); i64(0); i64(Int64(3 * nodes))
        for v in 0..<voxels { f32(1 + Float(v % 7) * 0.5) }
        for c in 0...nz { for b in 0...ny { for a in 0...nx {
            _ = (b, c); f32(0); f32(sag(Double(a) * spacing)); f32(0)
        } } }
        // block 2: the solid's margin per voxel
        f64(-1); f64(0); i32(0); i32(0); i64(Int64(voxels)); i64(0); i64(0)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            f32(i <= 1 ? Float(2.663863157 + 0.1 * Double(i + j + k)) : .nan)
        } } }
        return d
    }

    static func report() -> [String: Any] {
        [
            "ok": true, "why": "", "code": "ok", "file": "lattice.stl", "file_bytes": 44_427_970, "file_format": "stl",
            "layout": ["bars": 64_204, "strands": 12_605],
            "mesh": ["triangles": 3, "mm3": 154_897.155, "part_mm3": 109_782.82, "bridges": 8771],
            "print_check": ["clean": true, "layers": 350, "posts": [Any]()],
            "strength": [
                "accepted": false, "verdict": "fail", "fail_reason": "strut_margin", "struts_pass": false,
                "margin_worst_case": 2.74648551, "margin_in_plane": 2.74648551, "margin_interlayer": 7.432419123,
                "safety_margin": 1.5, "not_certified": false, "mass_grams": 67.29915745, "max_effective_von_mises_mpa": 13.835864,
                "max_interlayer_tension_mpa": 3.834552321, "build_direction": [0, 0, 1], "fields": "fields.bin",
                "strut_margins": "strut_margins.bin",
                "strut": ["law": "frame of beams", "margin_worst_case": 1.339873856],
                "struts": ["judged": 8181, "under_safety": 3, "under_one": 0, "smallest_margin": 1.339873856],
                "solid_margin": ["worst_case": 3.332424202, "in_plane": 3.332424202, "interlayer": 7.534542811,
                                 "effective": 2.663863157, "passes_at_infill_percent": 35],
                "frame": ["load_share": 0.7735238156, "load_total_n": 402.0726624],
                "weakest": [
                    ["at": [20.0, 10.0, 10.0], "width_mm": 2.25, "length_mm": 15.61799078, "margin": 1.339873856, "by": "tension",
                     "axial_n": 0.1276853912, "moment_nmm": 29.81389973,
                     "ends": [["at": [20.0, 10.0, 5.0], "kind": "joint"], ["at": [20.0, 10.0, 15.0], "kind": "free"]]],
                    ["at": [25.0, 5.0, 10.0], "width_mm": 2.198565371, "length_mm": 3.49783437, "margin": 1.421194071,
                     "by": "tension", "axial_n": 5.297582214, "moment_nmm": 19.57194093,
                     "ends": [["at": [25.0, 5.0, 8.0]], ["at": [25.0, 5.0, 12.0]]]],
                ],
            ] as [String: Any],
            LatticeFileButton.strengthenKey: [
                "code": "done", "passing": false, "rounds_fixed": 6, "seconds": 2400.0,
                "rounds": [["added": ["struts_widened": 751, "struts_braced": 16,
                                      "limit": ["past_limit": ["struts": 34, "widest_mm": 3.2]]]],
                           ["added": ["struts_widened": 288, "struts_braced": 3,
                                      "limit": ["past_limit": ["struts": 12, "widest_mm": 4.063]]]],
                           ["struts": ["judged": 8181]]],
            ] as [String: Any],
        ]
    }

    static func made() throws -> LatticeFileRun.Made {
        let rd = try JSONSerialization.data(withJSONObject: report())
        let r = try XCTUnwrap(LatticeFileReport.parse(rd))
        return LatticeFileRun.Made(stl: stl([onStrut, onSolid, unjudged]), report: r, reportJSON: rd, fields: fieldsBin(),
                                   scenarioFields: nil, timing: nil,
                                   strutMargins: Data([Float(1.339873856), .nan, 30].flatMap { v -> [UInt8] in
                                       withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }))
    }

    @MainActor static func model() throws -> ResultsModel {
        let o = try LatticeFileButton.outcome(try made(), densityGCm3: 1.01, organic: true)
        return ResultsModel(projectName: "2040 Extrusion Stand copy", outcome: o, materialName: "PA12", yieldStrengthMPa: 38,
                            appliedLoadKg: 41.0, infillPercent: 50, infillPattern: "gyroid", materialDensityGCm3: 1.01)
    }

    /// A solid (topology) result: a 40 × 10 × 10 mm bar, its sides drawn, stress highest at the root, sagging along x.
    static func solidOutcome(peakAtSurface: Bool = true) -> OptimizeOutcome {
        let gx = 8, gy = 2, gz = 2, s: Float = 5
        var vm = [Float](repeating: 0, count: gx * gy * gz)
        for k in 0..<gz { for j in 0..<gy { for i in 0..<gx { vm[(k * gy + j) * gx + i] = Float(gx - i) * 2 } } }
        var disp: [Float] = []
        for _ in 0...gz { for _ in 0...gy { for a in 0...gx { disp += [0, 0, -0.001 * Float(a * a) * s] } } }
        // the side z = 0 as a strip of triangles (vertices sit on voxel corners)
        var verts: [Float] = [], idx: [Int32] = []
        for i in 0..<gx {
            let x0 = Float(i) * s, x1 = Float(i + 1) * s
            let base = Int32(verts.count / 3)
            verts += [x0, 0, 0.1, x1, 0, 0.1, x1, 10, 0.1, x0, 10, 0.1]
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        if !peakAtSurface {
            // RED CONTROL: the highest voxel is one no drawn vertex reads
            vm[(1 * gy + 1) * gx + 7] = 99
        }
        let v = OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 20, supportVolumeVoxels: 0,
                                meshTriangleCount: idx.count / 3, worstCaseMargin: 2, accepted: true, v3Passes: true,
                                maxStressMPa: Double(vm.max() ?? 0), meshVertices: verts, meshIndices: idx, vonMisesField: vm,
                                displacementField: disp)
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: 1, gridNx: gx, gridNy: gy,
                               gridNz: gz, spacing: Double(s))
    }
}

@MainActor
final class Notes25MotionTests: XCTestCase {

    // MARK: C1 — the exaggeration scaled to the part

    /// His stand: 127 mm long, 0.57 mm at most at his load (job f1cd34dce90548b5). RED before: 10…300×, opening at 60× (34 mm of
    /// sag drawn on a 127 mm part).
    func testTheSliderForHisStandSizedPart() {
        let r = LoadMotion.exaggeration(longestSideMM: 127, largestMovementMM: 0.569)
        XCTAssertEqual(r.low, 1, "★ the bottom is the true size")
        XCTAssertEqual(r.high, 0.08 * 127 / 0.569, accuracy: 1e-9, "★ the top: the largest movement reaches 8 % of the part")
        XCTAssertEqual(r.high * 0.569, 0.08 * 127, accuracy: 1e-9, "never above 8 %")
        XCTAssertEqual(r.standard * 0.569 / 127, 0.03, accuracy: 1e-9, "★ it opens at about 3 %")
        XCTAssertEqual(LoadMotion.label(r.high), "18×"); XCTAssertEqual(LoadMotion.label(r.standard), "6.7×")
        XCTAssertEqual(LoadMotion.label(1), "1×")
        XCTAssertLessThan(r.high, Double(FlexAnimation.defaultExaggeration), "RED CONTROL: the old default (60×) is past his part's top")
        // the slider's 0…1 runs the range, both ends
        XCTAssertEqual(r.value(at: 0), 1, accuracy: 1e-9); XCTAssertEqual(r.value(at: 1), r.high, accuracy: 1e-9)
        XCTAssertEqual(r.value(at: r.position(of: r.standard)), r.standard, accuracy: 1e-9)
    }

    /// A stiff small part: barely moves, so the top is high; and a part already past the cap at its true size: 1× only.
    func testTheSliderForAStiffSmallPartAndOneAlreadyPastTheCap() {
        let stiff = LoadMotion.exaggeration(longestSideMM: 20, largestMovementMM: 0.0005)
        XCTAssertEqual(stiff.high, 3200, accuracy: 1e-6)
        XCTAssertEqual(stiff.standard, 1200, accuracy: 1e-6)
        XCTAssertEqual(LoadMotion.label(stiff.high), "3200×", "rounded sensibly")
        XCTAssertEqual(LoadMotion.label(123.4), "120×")
        let soft = LoadMotion.exaggeration(longestSideMM: 10, largestMovementMM: 2)
        XCTAssertEqual(soft.high, 1, "★ the true deflection is already past the cap: the top is 1×")
        XCTAssertEqual(soft.standard, 1)
        XCTAssertFalse(soft.adjustable)
    }

    /// Source pin: the formula.
    func testTheFormulaIsPinned() throws {
        let src = try FlexibleSource.code("ResultsLoadMotion.swift")
        XCTAssertTrue(src.contains("public static let capShare = 0.08"))
        XCTAssertTrue(src.contains("public static let standardShare = 0.03"))
        XCTAssertTrue(src.contains("let high = Swift.max(1, capShare * L / m)"))
        XCTAssertTrue(src.contains("standard: Swift.min(high, Swift.max(1, standardShare * L / m))"))
        let screen = try FlexibleSource.code("ResultsScreen.swift")
        XCTAssertTrue(screen.contains("set: { model.loadMotion.pickExaggeration(s.range.value(at: $0), selection: model.motionSelection) })"),
                      "★ Bend / Break's slider writes the part-scaled value (the old 10…300× one drives nothing on screen)")
        let panels = try FlexibleSource.code("ResultsPanels.swift")
        XCTAssertTrue(panels.contains("Slider(value: ex, in: 0...1)"))
        XCTAssertFalse(panels.contains("Slider(value: ex, in: Double(FlexAnimation.minExaggeration)"), "RED CONTROL: the 10…300× range")
    }

    // MARK: C2 — the load runs the shape and the colours

    func testEachFrameScalesTheShapeAndTheColoursByTheOneLoad() {
        for share in stride(from: 0.0, through: 1.0, by: 0.125) {
            let f = LoadMotion.frame(start: 1, top: 1.34, share: share, giveWay: 0, exaggeration: 6.7)
            XCTAssertEqual(f.load, 1 + 0.34 * share, accuracy: 1e-12, "linear in the climb")
            XCTAssertEqual(Double(f.shapeScale), f.load * 6.7, accuracy: 1e-4, "★ the shape = the displacement × the load × the exaggeration")
            XCTAssertEqual(Double(f.colourLoad), f.load, accuracy: 1e-6, "★ the colours = the share at your load × the SAME load")
        }
        let bend = LoadMotion.frame(start: 0, top: 1, share: 0.5, giveWay: 0, exaggeration: 10)
        XCTAssertEqual(bend.load, 0.5); XCTAssertEqual(bend.shapeScale, 5); XCTAssertEqual(bend.colourLoad, 0.5)
    }

    /// Eased up, held, eased back, rested — no jump anywhere, the loop's seam included; never frozen.
    func testTheLoopEasesHoldsAndNeverJumps() {
        for k in [LoadMotionKind.bend, .breakIt] {
            let tl = LoadMotion.timeline(k)
            XCTAssertEqual(LoadMotion.share(time: 0, tl), 0)
            XCTAssertEqual(LoadMotion.share(time: tl.up, tl), 1, accuracy: 1e-12)
            XCTAssertEqual(LoadMotion.share(time: tl.up + tl.hold / 2, tl), 1, "★ a short hold at the top")
            XCTAssertEqual(LoadMotion.share(time: tl.up + tl.hold + tl.down, tl), 0, accuracy: 1e-12, "eased back")
            var last = LoadMotion.share(time: 0, tl), biggest = 0.0, moved = false
            for n in 1...Int(2 * tl.cycle * 30) {
                let s = LoadMotion.share(time: Double(n) / 30, tl)
                biggest = max(biggest, abs(s - last)); if s != last { moved = true }
                last = s
            }
            XCTAssertLessThan(biggest, 0.05, "★ \(k): no frame moves more than a twentieth of the climb (the seam included)")
            XCTAssertTrue(moved, "never frozen")
            XCTAssertLessThan(LoadMotion.share(time: 1.0 / 30, tl), 0.005, "it starts gently")
        }
        let tl = LoadMotion.breakTimeline
        XCTAssertEqual(LoadMotion.giveWay(time: tl.up * 0.9, tl), 0, "Break gives way only at the top")
        XCTAssertEqual(LoadMotion.giveWay(time: tl.up + tl.hold * 0.8, tl), 1)
        XCTAssertEqual(LoadMotion.giveWay(time: tl.cycle - 0.01, tl), 0, "and is gone before the loop starts again")
    }

    /// A solid result through the real path: the marker sits where the colours first reach the top, at the load Break climbs to;
    /// the scale is fixed (the same per-vertex shares every frame, only the load moves).
    func testASolidResultsMarkerIsWhereTheColoursFirstReachTheTop() throws {
        let m = ResultsModel(projectName: "Bar", outcome: Notes25Fixture.solidOutcome(), materialName: "PLA", yieldStrengthMPa: 40,
                             appliedLoadKg: 10)
        XCTAssertTrue(m.canBreak && m.hasFlex)
        let a = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        let first = try XCTUnwrap(a.prep.firstRed)
        XCTAssertEqual(a.place, first.position, "★ the marker's place = the colouring's first place to reach the top")
        XCTAssertEqual(a.top * Double(first.share), 1, accuracy: 1e-5, "★ …exactly at Break's top load")
        XCTAssertEqual(ResultsModel.stressColor(fraction: a.top * Double(first.share)), ResultsModel.stressColor(fraction: 1))
        for u in a.prep.ramp where u.isFinite {
            XCTAssertLessThanOrEqual(Double(u) * a.top, 1 + 1e-5, "nothing reaches the top before it")
        }
        // the fixed scale: the shares never move with the load; only the load does
        m.loadMotion.setPosition(0.1, .breakIt)
        let b = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        m.loadMotion.setPosition(0.4, .breakIt)
        let c = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        XCTAssertEqual(b.ramp.key, c.ramp.key, "★ one upload, never re-normalised per frame")
        XCTAssertTrue(b.ramp.values.elementsEqual(c.ramp.values) { $0 == $1 || ($0.isNaN && $1.isNaN) })
        XCTAssertNotEqual(b.ramp.load, c.ramp.load, "the load moves")
        XCTAssertEqual(Double(c.ramp.load), c.frame.load, accuracy: 1e-6)
        XCTAssertLessThan(Double(b.ramp.load) * Double(first.share), 1, "below the top load the first place is not yet red")
    }

    /// RED CONTROL for the report (C2, not fixed — 362's call): a voxel no drawn vertex reads can hold the field's peak. The old
    /// marker went there (StressField.peak, the failure prediction's place) and its colour never showed it; the marker now follows
    /// the colours, and the two places differ.
    func testAVoxelPeakNoDrawnVertexReadsIsNotWhereTheColoursTurnRed() throws {
        let m = ResultsModel(projectName: "Bar", outcome: Notes25Fixture.solidOutcome(peakAtSurface: false), materialName: "PLA",
                             yieldStrengthMPa: 40, appliedLoadKg: 10)
        let fp = try XCTUnwrap(m.failurePrediction)
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        let place = try XCTUnwrap(s.place)
        XCTAssertGreaterThan(simd_distance(place, fp.position), 5, "the voxel peak and the colours' first red are different places")
        XCTAssertGreaterThan(s.top, fp.multiplier, "and different loads")
    }

    /// Smooth: a vertex beside empty space keeps the material's motion (never pinned to a node of no material, the spikes of img 3).
    func testTheShapeIsSampledFromTheMaterialsOwnNodes() {
        let f = DisplacementField(nx: 2, ny: 1, nz: 1, origin: .zero, spacing: 1,
                                  values: (0..<(3 * 2 * 2)).flatMap { n -> [Float] in n % 3 == 2 ? [0, 0, 0] : [0, 0, 1] })
        let stress = StressField(nx: 2, ny: 1, nz: 1, origin: .zero, spacing: 1, values: [5, 0])
        let mask = ResultsMotionPrep.nodeMask(stress: stress, nx: 2, ny: 1, nz: 1)
        // a point in the empty voxel, near its far corner (whose nodes touch no material: zero by core's contract)
        let p = SIMD3<Float>(1.9, 0.5, 0.5)
        XCTAssertEqual(f.displacement(at: p).z, 0, "RED CONTROL: the nearest node is a node of no material — the old tear")
        XCTAssertEqual(ResultsMotionPrep.smoothDisplacement(f, mask: mask, at: p).z, 1, accuracy: 1e-6,
                       "★ the material's own nodes: it moves with the part")
        XCTAssertEqual(ResultsMotionPrep.smoothDisplacement(f, mask: mask, at: SIMD3(0.5, 0.5, 0.5)).z, 1, accuracy: 1e-6)
    }

    // MARK: C3 — a print file's one answer

    func testHisPrintFileIsALatticedResultWithCoresOneAnswer() throws {
        let m = try Notes25Fixture.model()
        let a = try XCTUnwrap(m.latticeAnswer)
        XCTAssertEqual(a.governing ?? 0, 1.339873856, accuracy: 1e-9, "★ the smaller of the strut's 1.34 and the solid's 2.66")
        XCTAssertEqual(a.governs, .strut)
        XCTAssertEqual(a.place, Notes25Fixture.weakestAt, "★ where it gives first: the weakest strut")
        XCTAssertEqual(m.selected?.worstCaseMargin ?? 0, 1.339873856, accuracy: 1e-9,
                       "★ never knocked down for infill (RED before: 2.75 × 0.354 = 0.97, '1.0×')")
        XCTAssertNil(m.failurePrediction, "★ the voxel estimate ('40 kg · 1.0×') is gone for a lattice")
        XCTAssertNil(m.hotSpot, "no voxel-spike marker")
        XCTAssertNil(m.selectedMassComparison, "★ no mesh vs grid (a soup of tubes)")
        XCTAssertTrue(m.recommendationLine?.contains("the latticed part") == true, m.recommendationLine ?? "")
        XCTAssertEqual(m.solidMargins?.weakestAt, SIMD3(2.5, 2.5, 2.5), "the solid's weakest voxel (fields.bin block 2) rides along")
        let saved = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(
            try LatticeFileButton.outcome(try Notes25Fixture.made(), densityGCm3: 1.01, organic: true).reportJSON))) as? [String: Any])
        XCTAssertNotNil(saved["app_strut_margins"], "★ strut_margins.bin is fetched and kept with the result")
        XCTAssertEqual(try LatticeFileButton.outcome(try Notes25Fixture.made(), densityGCm3: 1.01, organic: true).variants[0]
            .worstCaseMargin, 1.339873856, accuracy: 1e-9, "the saved result's margin is the governing one (the Library's tiles)")
    }

    func testEveryPlaceSaysTheSameNumber() throws {
        let m = try Notes25Fixture.model()
        let a = try XCTUnwrap(m.latticeAnswer)
        let rows = ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks, requestedVF: { m.requestedVolumeFraction(of: $0) })
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.value.contains("1.34×"), "★ the versions line: \(row.value)")
        let checks = ResultsChecks.checks(tab: m.selected, margin: row.margin, required: 1.5, safetyMargin: 1.5, scenarios: [],
                                          thinJoints: 0, bridged: false, weakest: a.place, struts: m.reportBlocks?.latticeFile,
                                          printFile: m.reportBlocks?.printFile, answer: a)
        XCTAssertEqual(checks.first?.title, "Not strong enough")
        XCTAssertEqual(checks.first?.detail, "Holds 1.34× · needs 1.5×", "★ ONE strength line")
        XCTAssertEqual(checks.first?.places, [Notes25Fixture.weakestAt], "★ the lit place is the governing one")
        XCTAssertFalse(checks.contains { $0.title.hasPrefix("Struts") }, "★ no second strength line: \(checks.map(\.title))")
        let strengthened = try XCTUnwrap(checks.first { $0.title == "Strengthened · 6 rounds" })
        XCTAssertEqual(strengthened.detail, "3 struts still short")
        XCTAssertEqual(strengthened.more, "19 braced · thickest now 4.06 mm", "★ only numbers true for the final lattice")
        XCTAssertEqual(checks.first { $0.title == "Print file ready" }?.detail, "STL · 44.4 MB", "★ no strut count")

        let details = m.detailRows(.strength, version: row)
        func v(_ l: String) -> String? { details.first { $0.label == l }?.value }
        XCTAssertEqual(v("Holds"), "1.34× your load (55 kg)")
        XCTAssertEqual(v("Needs"), "1.5× your load (62 kg)")
        XCTAssertEqual(v("Gives first at"), "A strut · bends · 2.25 mm thick, 15.6 mm long", "★ bending-led (0.13 N vs 29.8 N·mm)")
        XCTAssertEqual(v("Struts short"), "3 of 8,181 checked")
        XCTAssertEqual(v("Solid part"), "2.66× at 50% infill · OK at 35%")
        XCTAssertEqual(v("Plastic"), "67 g · 39% less than solid")
        XCTAssertEqual(v("Load on struts"), "77% of your load, where it presses")
        XCTAssertEqual(v("Strengthened"), "6 rounds · 19 braced")
        for gone in ["Verified margin", "Mesh vs grid", "Peak stress", "Breaks at about", "Built for", "Stress scale", "Struts",
                     "Weakest strut", "Struts checked", "Infill"] {
            XCTAssertNil(v(gone), "★ '\(gone)' is gone: \(details.map(\.label))")
        }
        XCTAssertTrue(v("Recommended")?.hasPrefix("The latticed part") == true, v("Recommended") ?? "")
        for r in details { XCTAssertLessThanOrEqual(r.label.split(separator: " ").count, 5, "★ labels of at most 5 words") }
        let printing = m.detailRows(.printing, version: row)
        XCTAssertEqual(printing.first { $0.label == "Strands" }?.value, "12,605")
        XCTAssertFalse(printing.contains { $0.label == "Struts" }, "the bars' count is not on Printing")
        XCTAssertEqual(m.detailRows(.run, version: row).first { $0.label == "Bars in the file" }?.value, "64,204")

        // Break: from your load to the governing margin, its words the same number; Bend to your load
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true))
        XCTAssertEqual(s.start, 1, "★ from 1.00× (41 kg)")
        XCTAssertEqual(s.top, 1.339873856, accuracy: 1e-9, "★ the scrub ends at the governing margin")
        XCTAssertEqual(m.breakReadout(s), "55 kg · 1.34× · GIVES WAY")
        let lines = m.breakMarkerLines(s)
        XCTAssertEqual(lines.title, "GIVES WAY HERE"); XCTAssertEqual(lines.load, "55 kg"); XCTAssertEqual(lines.multiple, "1.34× your load")
        XCTAssertEqual(s.place.map { SIMD3<Double>($0) }, Notes25Fixture.weakestAt, "★ the marker at the governing place")
        m.loadMotion.setPosition(0, .breakIt)
        XCTAssertEqual(m.breakReadout(try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))), "41 kg · 1.00× load")
        XCTAssertEqual(try XCTUnwrap(m.motionState(.bend, reduceMotion: true)).top, 1, "Bend runs up to your load")
    }

    /// ★ C3 (8): a print file's colour is how close each place is to giving way at the shown load, on one fixed scale (red = it
    /// gives way); the weakest strut is the first thing to turn red, exactly at the governing margin.
    func testHisPrintFilesColoursAreHowCloseEachPlaceIsToGivingWay() throws {
        let m = try Notes25Fixture.model()
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true))
        XCTAssertEqual(s.prep.colouring, .utilisation)
        let mesh = try XCTUnwrap(m.selectedMesh)
        func share(at p: SIMD3<Float>) -> Float? {
            let j = (0..<mesh.flat.vertexCount).first {
                simd_distance(SIMD3(mesh.flat.positions[3 * $0], mesh.flat.positions[3 * $0 + 1], mesh.flat.positions[3 * $0 + 2]), p) < 1e-4
            }
            return j.map { s.prep.ramp[$0] }
        }
        for p in Notes25Fixture.onStrut {
            XCTAssertEqual(Double(try XCTUnwrap(share(at: p))), 1 / 1.339873856, accuracy: 1e-5, "the weakest strut: 1 ÷ its margin")
        }
        XCTAssertEqual(Double(try XCTUnwrap(share(at: Notes25Fixture.onSolid[0]))), 1 / 2.663863157, accuracy: 1e-5,
                       "the solid: 1 ÷ its margin there")
        XCTAssertTrue(try XCTUnwrap(share(at: Notes25Fixture.unjudged[0])).isNaN, "nothing judged it: the plain part")
        let first = try XCTUnwrap(s.prep.firstRed)
        XCTAssertEqual(Double(first.share) * s.top, 1, accuracy: 1e-5, "★ red exactly at the governing margin")
        XCTAssertLessThan(simd_distance(SIMD3<Double>(first.position), Notes25Fixture.weakestAt), 2,
                          "★ …on the weakest strut, where the marker is")
        XCTAssertEqual(ResultsGiveWayKey.topWords(.share), "Gives way", "★ the key says what red means")
        XCTAssertEqual(ResultsGiveWayKey.topWords(.stress(topMPa: 21)), "Yields")
        XCTAssertLessThanOrEqual(ResultsGiveWayKey.topWords(.share).split(separator: " ").count, 5)
        XCTAssertNotNil(m.stillRamp(), "the still Stress view of a print file wears the same colours at your load")
        XCTAssertEqual(m.stillRamp()?.load, 1)
        // the tapped reading says what the colour says
        XCTAssertEqual(m.shareOfLimit(at: Notes25Fixture.onStrut[2], load: s.top) ?? 0, 1, accuracy: 1e-5)
    }

    /// The give-way stays restrained: inside the 8 % cap with the slider at its top.
    func testBreakGivesWayInsideTheCap() throws {
        let m = try Notes25Fixture.model()
        let tl = LoadMotion.breakTimeline
        m.loadMotion.setPosition((tl.up + tl.hold * 0.9) / tl.cycle, .breakIt)
        let s0 = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        m.loadMotion.pickExaggeration(s0.range.high, selection: m.motionSelection)
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        XCTAssertTrue(s.frame.atTop)
        XCTAssertEqual(s.frame.giveWay, 1, accuracy: 1e-9)
        let patch = try XCTUnwrap(s.patch, "★ it gives way where it gives first")
        XCTAssertFalse(patch.indices.isEmpty)
        var largest: Float = 0
        for j in 0..<(s.prep.disp.count / 3) {
            var d = SIMD3(s.prep.disp[3 * j], s.prep.disp[3 * j + 1], s.prep.disp[3 * j + 2])
            if let k = patch.indices.firstIndex(of: Int32(j)) { d = SIMD3(patch.values[3 * k], patch.values[3 * k + 1], patch.values[3 * k + 2]) }
            largest = max(largest, simd_length(d) * s.frame.shapeScale)
        }
        XCTAssertLessThanOrEqual(Double(largest), LoadMotion.capShare * s.prep.longestSideMM + 1e-4, "★ never past 8 % of the part")
        XCTAssertGreaterThan(Double(largest), 0.02 * s.prep.longestSideMM, "and still visible")
    }
}
