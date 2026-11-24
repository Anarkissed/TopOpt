// Notes27ResultsTests — ★ his iPad notes 2026-11-23 ~23:45 on release 17 (items 1 and 2), builder F ("results27"):
//   F1 "The stress map is meant to be on the *entire* model, the stress colours should change as the bend/breaks happen. It
//      shouldn't JUST BE on the few struts. What happened here?" — every strut by its own bar (bars.bin), the solid by its margin per
//      voxel, the rest (an older file) from the stress field: never plain, and moving with the load.
//   F2 "I don't understand the "gives first at: A strut • bends • 4.25 mm thick, 8.7mm long" ... Explain it simply. If more
//      information is required, add an (i)." / "Load on struts: 77% of your load, where it presses — What does that mean?" /
//      "There are 6 struts noted/coloured - why? ... What changes were made to strengthen it?"
// The fixtures go through the real path his results take (a print file's report + fields.bin + strut_margins.bin + bars.bin + its
// mesh → LatticeFileButton.outcome → ResultsModel), on Notes25Fixture's grid and numbers — never his job's files.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// A print file with bars.bin: the solid's two triangles first (`base_triangles` 2), then a small tube round each bar.
enum Notes27Fixture {
    /// ax ay az bx by bz width: the weakest strut (Notes25's, 1.34×), one core did not judge, a long one (30×), a thin one (4×).
    static let bars: [[Float]] = [
        [20, 10, 5, 20, 10, 15, 2.25],
        [25, 5, 8, 25, 5, 12, 2.2],
        [12, 14, 4, 18, 14, 4, 1.6],
        [27, 12, 16, 27, 18, 16, 1.0],
    ]
    static let margins: [Float] = [1.339873856, .nan, 30, 4]
    /// The solid: one triangle in a voxel core judged (its margin 2.66…), one in a voxel it did not (the field there).
    static let solidJudged: [SIMD3<Float>] = Notes25Fixture.onSolid
    static let solidUnjudged: [SIMD3<Float>] = [SIMD3(17, 17, 2), SIMD3(18, 17, 2), SIMD3(17, 18, 2)]
    /// A bridge between bar 3's end and nothing near: further from its surface than the grid's pad (the ring search finds it).
    static let bridge: [SIMD3<Float>] = [SIMD3(28.5, 19, 16), SIMD3(28.6, 19, 16.2), SIMD3(28.4, 19.1, 16.1)]

    /// A six-sided tube round a bar: 12 triangles.
    static func tube(_ b: [Float]) -> [[SIMD3<Float>]] {
        let a = SIMD3(b[0], b[1], b[2]), c = SIMD3(b[3], b[4], b[5]), r = b[6] / 2
        let axis = simd_normalize(c - a)
        let u = simd_normalize(simd_cross(axis, abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)))
        let v = simd_cross(axis, u)
        func ring(_ o: SIMD3<Float>) -> [SIMD3<Float>] {
            (0..<6).map { k in let t = Float(k) * .pi / 3; return o + r * (cos(t) * u + sin(t) * v) }
        }
        let p = ring(a), q = ring(c)
        var out: [[SIMD3<Float>]] = []
        for k in 0..<6 {
            let k1 = (k + 1) % 6
            out.append([p[k], p[k1], q[k1]]); out.append([p[k], q[k1], q[k]])
        }
        return out
    }

    static var strutTriangles: [[SIMD3<Float>]] { bars.flatMap(tube) + [bridge] }
    static var triangles: [[SIMD3<Float>]] { [solidJudged, solidUnjudged] + strutTriangles }

    static func floats(_ v: [Float]) -> Data {
        Data(v.flatMap { f -> [UInt8] in withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) } })
    }
    /// bars.bin as core writes it: "TOBARS1\0", uint32 N, uint32 0, N × 7 float32.
    static func barsBin(_ b: [[Float]] = bars) -> Data {
        var d = Data(PrintFileParts.magic)
        var n = UInt32(b.count).littleEndian, z = UInt32(0)
        d.append(Data(bytes: &n, count: 4)); d.append(Data(bytes: &z, count: 4))
        d.append(floats(b.flatMap { $0 }))
        return d
    }

    static func report(withBars: Bool = true) -> [String: Any] {
        var r = Notes25Fixture.report()
        var s = r["strength"] as! [String: Any]
        if withBars { s["bars"] = "bars.bin" }
        r["strength"] = s
        r["base_triangles"] = 2
        var m = r["mesh"] as! [String: Any]
        m["triangles"] = triangles.count
        r["mesh"] = m
        return r
    }

    static func made(withBars: Bool = true) throws -> LatticeFileRun.Made {
        let rd = try JSONSerialization.data(withJSONObject: report(withBars: withBars))
        var made = LatticeFileRun.Made(stl: Notes25Fixture.stl(triangles), report: try XCTUnwrap(LatticeFileReport.parse(rd)),
                                       reportJSON: rd, fields: Notes25Fixture.fieldsBin(), scenarioFields: nil, timing: nil,
                                       strutMargins: floats(margins))
        if withBars { made.bars = barsBin() }
        return made
    }

    @MainActor static func model(withBars: Bool = true) throws -> ResultsModel {
        let o = try LatticeFileButton.outcome(try made(withBars: withBars), densityGCm3: 1.01, organic: true)
        return ResultsModel(projectName: "2040 Extrusion Stand copy", outcome: o, materialName: "PA12", yieldStrengthMPa: 38,
                            appliedLoadKg: 41.0, infillPercent: 50, infillPattern: "gyroid", materialDensityGCm3: 1.01)
    }

    /// The flat vertices of triangle `t` in a prep's ramp (the file's triangle order is the mesh's).
    static func shares(_ ramp: [Float], triangle t: Int) -> [Float] { (0..<3).map { ramp[3 * t + $0] } }
    /// The field's share at a point, as the colouring reads it there (its voxel against the material's limit at his infill).
    @MainActor static func fieldShare(_ m: ResultsModel, _ p: SIMD3<Float>) throws -> Float {
        let f = try XCTUnwrap(m.selectedStressField)
        return f.value(at: p) / Float(m.stressScaleMaxMPa)
    }
}

@MainActor
final class Notes27ResultsTests: XCTestCase {

    // MARK: F1 — the whole model coloured

    func testBarsBinIsReadAsCoreWritesItAndNothingElse() {
        let bars = PrintFileParts.parseBars(Notes27Fixture.barsBin())
        XCTAssertEqual(bars?.count, 4 * 7)
        XCTAssertEqual(bars?[7 * 3 + 6], 1.0, "the fourth bar's width")
        var wrong = Notes27Fixture.barsBin(); wrong[6] = 0x32   // "TOBARS2"
        XCTAssertNil(PrintFileParts.parseBars(wrong), "RED CONTROL: another file is never read as bars")
        XCTAssertNil(PrintFileParts.parseBars(Notes27Fixture.barsBin().prefix(16 + 27)), "RED CONTROL: a cut-off file")
        XCTAssertNil(PrintFileParts.parseBars(Data()), "RED CONTROL: nothing")
    }

    /// The print file's report names bars.bin; the app keeps it with the result (saved, so a reopened result colours the same).
    func testBarsBinIsFetchedWithTheMarginsAndKeptWithTheResult() throws {
        let rd = try JSONSerialization.data(withJSONObject: Notes27Fixture.report())
        XCTAssertEqual(LatticeFileReport.parse(rd)?.strength?.barsFile, "bars.bin", "★ the strength block's `bars`")
        let o = try LatticeFileButton.outcome(try Notes27Fixture.made(), densityGCm3: 1.01, organic: true)
        let saved = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(o.reportJSON))) as? [String: Any])
        XCTAssertNotNil(saved[PrintFileParts.barsKey], "★ bars.bin rides the result")
        XCTAssertNotNil(saved[PrintFileParts.marginsKey], "with the margins")
        let parts = try XCTUnwrap(PrintFileParts.decode(report: saved))
        XCTAssertEqual(parts.barCount, 4)
        XCTAssertEqual(parts.baseTriangles, 2, "★ the file's first triangles are the solid")
        XCTAssertEqual(parts.margins.count, 4)
        // the Mac's fetch and the iPad-only run fetch it by the name the report gives, beside strut_margins.bin
        let src = try FlexibleSource.code("LatticeFileExport.swift")
        XCTAssertTrue(src.contains("bars: named(report.strength?.barsFile))"), "★ fetched from the Mac")
        XCTAssertTrue(src.contains("bars: report.strength?.barsFile.flatMap(file))"), "★ read beside an iPad-only run's file")
        XCTAssertTrue(src.contains("strutMargins: m.strutMargins, bars: m.bars)"), "★ kept with the result")
    }

    /// ★ A file with bars.bin: EVERY strut vertex takes its own bar's margin (bar 0: the weakest, 1.34×; bar 2: 30×; bar 3: 4×),
    /// a bar core did not judge and the bridge are still coloured; the solid by its margin per voxel, else the field. Nothing plain.
    func testAFileWithBarsColoursEveryStrutVertexByItsBar() throws {
        let m = try Notes27Fixture.model()
        XCTAssertEqual(m.printFileParts?.barCount, 4, "premise: the bars came through")
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true))
        XCTAssertEqual(s.prep.colouring, .utilisation)
        let ramp = s.prep.ramp
        XCTAssertEqual(ramp.count, 3 * Notes27Fixture.triangles.count)
        XCTAssertFalse(ramp.contains { !$0.isFinite }, "★ never plain: every vertex of the part is coloured")
        // the struts: each tube's 12 triangles, after the solid's 2
        for (b, margin) in Notes27Fixture.margins.enumerated() {
            for t in (2 + 12 * b)..<(2 + 12 * (b + 1)) {
                for u in Notes27Fixture.shares(ramp, triangle: t) {
                    if margin.isFinite {
                        XCTAssertEqual(u, 1 / margin, accuracy: 1e-6, "★ bar \(b)'s every vertex: 1 ÷ its own margin")
                    } else {
                        XCTAssertTrue(u.isFinite && u >= 0, "★ bar \(b) (not judged) is still coloured")
                        XCTAssertLessThanOrEqual(u, 1 / 1.339873856 + 1e-6, "never past the place that gives way first")
                    }
                }
            }
        }
        let bridge = 2 + 12 * Notes27Fixture.bars.count
        for u in Notes27Fixture.shares(ramp, triangle: bridge) {
            XCTAssertEqual(u, 0.25, accuracy: 1e-6, "★ a bridge past the bar's skin takes its nearest bar (bar 3, 4×)")
        }
        // the solid: its margin per voxel, else the field
        for u in Notes27Fixture.shares(ramp, triangle: 0) {
            XCTAssertEqual(u, 1 / 2.663863157, accuracy: 1e-5, "★ the solid: 1 ÷ its own margin there")
        }
        for (k, u) in Notes27Fixture.shares(ramp, triangle: 1).enumerated() {
            XCTAssertEqual(u, try Notes27Fixture.fieldShare(m, Notes27Fixture.solidUnjudged[k]), accuracy: 1e-5,
                           "★ the solid where no margin was kept: the stress field against the limit at his infill")
            XCTAssertGreaterThan(u, 0)
        }
        // the weakest strut is still the first to turn red, exactly at core's governing margin
        let first = try XCTUnwrap(s.prep.firstRed)
        XCTAssertEqual(Double(first.share) * s.top, 1, accuracy: 1e-5)
        XCTAssertLessThan(simd_distance(SIMD3<Double>(first.position), Notes25Fixture.weakestAt), 6, "on the weakest strut")
        // RED CONTROL: release 17's colouring (the 20 listed struts + the solid's voxels) left bars 2 and 3 plain
        for t in (2 + 12 * 2)..<(2 + 12 * 4) {
            for k in 0..<3 {
                let p = Notes27Fixture.triangles[t][k]
                XCTAssertNil(m.printFileColouringForTest?.tubeShare(p), "RED CONTROL: no listed strut there (release 17: plain)")
            }
        }
    }

    /// ★ An older file (no bars.bin — his v8.1, made before it): the WHOLE model is still coloured, from the stress field where
    /// nothing else judged it; the listed weakest strut and the solid's margins as before.
    func testAFileWithoutBarsIsColouredFromTheField() throws {
        let m = try Notes27Fixture.model(withBars: false)
        XCTAssertEqual(m.printFileParts?.barCount, 0, "premise: no bars")
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true))
        let ramp = s.prep.ramp
        XCTAssertFalse(ramp.contains { !$0.isFinite }, "★ never plain, even with no bars.bin")
        // bar 3's tube (not a listed strut): the field there, never past the struts' own smallest margin
        for t in (2 + 12 * 3)..<(2 + 12 * 4) {
            for (k, u) in Notes27Fixture.shares(ramp, triangle: t).enumerated() {
                let p = Notes27Fixture.triangles[t][k]
                XCTAssertEqual(u, Swift.min(try Notes27Fixture.fieldShare(m, p), Float(1 / 1.339873856)), accuracy: 1e-5,
                               "★ from the field")
            }
        }
        // the listed weakest strut keeps its own margin (C3)
        for t in 2..<14 { for u in Notes27Fixture.shares(ramp, triangle: t) { XCTAssertEqual(u, 1 / 1.339873856, accuracy: 1e-5) } }
    }

    /// ★ His v8.1 exactly: a result saved before release 17 kept neither the solid's margins nor bars (Notes25's fixture, its
    /// report stripped of what the app added) — before: only the listed struts coloured, the solid plain.
    func testAResultSavedBeforeRelease17IsWhollyColoured() throws {
        let made = try Notes25Fixture.made()
        let full = try LatticeFileButton.outcome(made, densityGCm3: 1.01, organic: true)
        var r = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(full.reportJSON))) as? [String: Any])
        r[SolidMarginVoxels.reportKey] = nil; r[PrintFileParts.marginsKey] = nil
        let o = OptimizeOutcome(variants: full.variants, stoppedOnMargin: false, cancelled: false, acceptedCount: 1,
                                voxelVolumeMM3: full.voxelVolumeMM3, gridNx: full.gridNx, gridNy: full.gridNy, gridNz: full.gridNz,
                                gridOrigin: full.gridOrigin, spacing: full.spacing, computedRemotely: true,
                                reportJSON: try JSONSerialization.data(withJSONObject: r))
        let m = ResultsModel(projectName: "v8.1", outcome: o, materialName: "PA12", yieldStrengthMPa: 38, appliedLoadKg: 41,
                             infillPercent: 50, infillPattern: "gyroid", materialDensityGCm3: 1.01)
        XCTAssertNil(m.solidMargins, "premise: no solid margins in a release-16 save")
        let ramp = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true)).prep.ramp
        XCTAssertFalse(ramp.contains { !$0.isFinite }, "★ the solid and every strut are coloured (release 17: plain)")
        for (k, u) in Notes27Fixture.shares(ramp, triangle: 1).enumerated() {
            XCTAssertEqual(u, try Notes27Fixture.fieldShare(m, Notes25Fixture.onSolid[k]), accuracy: 1e-5, "★ the solid from the field")
        }
    }

    /// ★ The colours move with Break's (and Bend's) load on ONE fixed scale: the same per-vertex shares every frame, × the load.
    func testTheColoursChangeWithTheLoad() throws {
        let m = try Notes27Fixture.model()
        let tl = LoadMotion.breakTimeline
        m.loadMotion.setPosition(0.02 / tl.cycle, .breakIt)
        let low = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        m.loadMotion.setPosition((tl.up + tl.hold / 2) / tl.cycle, .breakIt)
        let high = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: false))
        XCTAssertEqual(low.ramp.key, high.ramp.key, "one upload: the shares never move")
        XCTAssertLessThan(low.ramp.load, high.ramp.load, "the load climbs")
        var moved = 0, coloured = 0
        for u in high.ramp.values where u > 1e-4 {
            coloured += 1
            let a = ResultsModel.stressColor(fraction: Double(u * low.ramp.load))
            let b = ResultsModel.stressColor(fraction: Double(u * high.ramp.load))
            if a != b { moved += 1 }
        }
        XCTAssertEqual(moved, coloured, "★ every coloured place changes colour as the load grows (\(moved) of \(coloured))")
        XCTAssertGreaterThan(coloured, high.ramp.values.count / 2, "most of the part carries load")
        // Bend: from none to your load — at the start every place is the bottom colour
        m.loadMotion.setPosition(0, .bend)
        let rest = try XCTUnwrap(m.motionState(.bend, reduceMotion: false))
        XCTAssertEqual(rest.ramp.load, 0, accuracy: 1e-6)
        // the shader colours each vertex at this frame's load (source pin: the GPU half)
        let shader = try FlexibleSource.code("MetalMeshView.swift")
        XCTAssertTrue(shader.contains("load_ramp(tn.r * u.flex.y)"), "★ the colour = the share × the frame's load, on the GPU")
    }

    /// A tap reads what the colour says: on a strut, its bar's share; on the solid, its own.
    func testATapReadsTheColourThere() throws {
        let m = try Notes27Fixture.model()
        let s = try XCTUnwrap(m.motionState(.breakIt, reduceMotion: true))
        let onBar3 = Notes27Fixture.triangles[2 + 12 * 3][0]
        XCTAssertEqual(m.shareOfLimit(at: onBar3, load: 1) ?? 0, 0.25, accuracy: 1e-5)
        XCTAssertEqual(m.shareOfLimit(at: Notes25Fixture.onSolid[0], load: s.top) ?? 0, s.top / 2.663863157, accuracy: 1e-4)
    }

    // MARK: F2 — Details › Strength in plain words

    func testDetailsSayTheWeakestSpotSimplyWithTheDetailInAnI() throws {
        let m = try Notes27Fixture.model()
        let row = try XCTUnwrap(ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks,
                                                     requestedVF: { m.requestedVolumeFraction(of: $0) }).first)
        let rows = m.detailRows(.strength, version: row)
        func r(_ l: String) -> ResultsDetailRow? { rows.first { $0.label == l } }
        XCTAssertNil(r("Gives first at"), "RED CONTROL: the confusing line is gone: \(rows.map(\.label))")
        XCTAssertNil(r("Load on struts"), "RED CONTROL: gone")
        let weakest = try XCTUnwrap(r("Weakest spot"))
        XCTAssertEqual(weakest.value, "A strut", "★ simply")
        let info = try XCTUnwrap(weakest.info, "★ the detail in an (i)")
        XCTAssertTrue(info.contains("bends rather than stretches"), info)
        XCTAssertTrue(info.contains("2.25 mm thick") && info.contains("15.6 mm long"), info)
        XCTAssertTrue(info.contains("lit on the part"), "★ where it is: \(info)")
        let carries = try XCTUnwrap(r("Lattice carries"))
        XCTAssertEqual(carries.value, "77% of the load")
        XCTAssertEqual(carries.info, "Where your load pushes on the part, the lattice takes 77% of that force. The solid walls take "
                       + "the other 23%.")
        XCTAssertNil(r("Colours"), "★ 362 11-24 (his): no extra colour line — the Colour key explains the colours")
        for x in rows {
            XCTAssertLessThanOrEqual(x.label.split(separator: " ").count, 5, "★ labels of at most 5 words: \(x.label)")
        }
        // the solid governing: says so
        var a = try XCTUnwrap(m.latticeAnswer)
        a.strutMargin = 9
        XCTAssertEqual(a.weakestSpot, "The solid part")
        XCTAssertTrue(a.weakestSpotInfo?.hasPrefix("If the load keeps growing, the solid part gives way first") == true)
    }

    /// ★ "What changes were made to strengthen it?" — with core's summary keys, the row lists them plainly; an older report only
    /// what is true of its final lattice; the Checks line says the same.
    func testStrengthenedListsTheChangesPlainly() throws {
        var r = Notes27Fixture.report()
        var g = r[LatticeFileButton.strengthenKey] as! [String: Any]
        g["thickened_distinct"] = 1554; g["braced"] = 19; g["widest_mm"] = 4.063; g["past_thickest"] = 34
        g["groups"] = [["name": "Light", "thickened_distinct": 1200, "widest_mm": 2.7],
                       ["name": "Heavy", "thickened_distinct": 354, "widest_mm": 4.063]]
        r[LatticeFileButton.strengthenKey] = g
        let f = try XCTUnwrap(LatticeFileFacts.decode(r))
        let row = try XCTUnwrap(f.rows(.strength).first { $0.label == "Strengthened" })
        XCTAssertEqual(row.value, "6 rounds · 1,554 struts thickened · 19 braces added · thickest now 4.06 mm")
        let info = try XCTUnwrap(row.info)
        XCTAssertTrue(info.contains("It thickened 1,554 struts, 34 of them past your thickest strut."), info)
        XCTAssertTrue(info.contains("It added 19 braces"), info)
        XCTAssertTrue(info.contains("Light: 1,200 struts thickened, thickest 2.70 mm."), info)
        XCTAssertTrue(info.contains("3 struts are still short."), info)
        XCTAssertEqual(f.checks.first?.more, "1,554 struts thickened · 19 braces added · thickest now 4.06 mm",
                       "★ the Checks line says the same")
        // in `summary` too
        g = r[LatticeFileButton.strengthenKey] as! [String: Any]
        let sum = ["thickened_distinct": g["thickened_distinct"]!, "braced": g["braced"]!, "widest_mm": g["widest_mm"]!]
        for k in ["thickened_distinct", "braced", "widest_mm", "past_thickest", "groups"] { g[k] = nil }
        g["summary"] = sum
        r[LatticeFileButton.strengthenKey] = g
        XCTAssertEqual(LatticeFileFacts.decode(r)?.rows(.strength).first?.value,
                       "6 rounds · 1,554 struts thickened · 19 braces added · thickest now 4.06 mm")
        // an older report: none of the keys — only what is true (the per-round "widened" sums are never a strut count)
        let old = try XCTUnwrap(LatticeFileFacts.decode(Notes27Fixture.report()))
        XCTAssertEqual(old.rows(.strength).first?.value, "6 rounds · 19 struts braced · thickest now 4.06 mm")
        XCTAssertFalse(old.rows(.strength).first?.value.contains("thickened") == true, "RED CONTROL: 1,039 was never a strut count")
    }
}

extension ResultsModel {
    /// The print file's colouring as the motion prep builds it (tests only).
    var printFileColouringForTest: PrintFileColouring? {
        guard let a = latticeAnswer else { return nil }
        let count = selectedStressField.map { $0.nx * $0.ny * $0.nz } ?? 0
        return PrintFileColouring(answer: a, parts: printFileParts, solidMargins: solidMargins?.grid(count: count),
                                  field: selectedStressField, limitMPa: stressScaleMaxMPa)
    }
}
