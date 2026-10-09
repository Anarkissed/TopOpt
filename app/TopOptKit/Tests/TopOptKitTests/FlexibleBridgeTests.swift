// FlexibleBridgeTests — the Flexible stage's bridge wrappers round-tripped against
// core (task 2026-09-29-flexible-screens, A1). Every expected value is either a
// published table number (Iacob 2024 Table 2 via core's own lookup) or read from
// another core call — never a depth typed here (C1 is still moving the strain
// convention; the tests must follow core, not freeze it).
import XCTest
import simd
@testable import TopOptKit

final class FlexibleBridgeTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    static var materialsPath: String {
        repoRoot.appendingPathComponent("core/src/materials/flexible_materials.json").path
    }
    /// C1's own evidence job: a 100 × 100 × 20 pad, top face 101 loaded, bottom 100 resting.
    static var padDir: URL {
        repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-28-flexible-squish-maths/a_pad_centre_soft")
    }
    static func padJob() throws -> String {
        try String(contentsOf: padDir.appendingPathComponent("job.json"), encoding: .utf8)
    }

    // MARK: catalogue (F1, R10)

    func testCatalogueOffersOnlyTestedTemperatures() throws {
        let mats = try FlexibleCore.materials(path: Self.materialsPath)
        let vario = try XCTUnwrap(mats.first { $0.id == "varioshore_tpu" })
        XCTAssertEqual(vario.tier, "literature")
        XCTAssertTrue(vario.foaming)
        XCTAssertEqual(vario.testedTempsC, [190, 220, 240])
        XCTAssertNil(vario.noPrediction)
        // every calibrate_first filament predicts nothing and carries core's reason
        let cal = mats.filter { $0.tier == "calibrate_first" }
        XCTAssertFalse(cal.isEmpty)
        for m in cal {
            XCTAssertTrue(m.testedTempsC.isEmpty, m.id)
            XCTAssertEqual(m.noPrediction?.code, "calibrate_first", m.id)
            XCTAssertFalse(m.noPrediction?.reason.isEmpty ?? true, m.id)
        }
    }

    func testTemperatureNoteComesFromCore() throws {
        let note = try FlexibleCore.temperatureNote(path: Self.materialsPath,
                                                    materialID: "varioshore_tpu", tempC: 190)
        XCTAssertTrue(note.contains("below the manufacturer"), note)
        XCTAssertEqual(try FlexibleCore.temperatureNote(path: Self.materialsPath,
                                                        materialID: "varioshore_tpu", tempC: 220), "")
    }

    // MARK: the table (F3)

    /// 0.292 MPa: 20 % gyroid (core density 0.226) at 190 °C, at the last tabulated
    /// strain (nominal 0.20 — whatever core's strain convention calls it).
    func testTableValueThroughTheBridge() throws {
        let set = try FlexibleCore.curveSet(path: Self.materialsPath, materialID: "varioshore_tpu",
                                            tempC: 190, topology: "gyroid")
        XCTAssertNil(set.refusal)
        let s = try FlexibleCore.stressAt(path: Self.materialsPath, materialID: "varioshore_tpu",
                                          tempC: 190, topology: "gyroid",
                                          strain: set.strainMeasuredMax, density: 0.226)
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.stressMPa, 0.292, accuracy: 1e-9)
        XCTAssertFalse(s.extrapolated)
        // past the refusal limit: refused with a reason, no number
        let beyond = try FlexibleCore.stressAt(path: Self.materialsPath, materialID: "varioshore_tpu",
                                               tempC: 190, topology: "gyroid",
                                               strain: set.strainLimit + 0.01, density: 0.226)
        XCTAssertFalse(beyond.ok)
        XCTAssertEqual(beyond.refusal?.code, "strain_beyond_data")
    }

    func testUntestedTemperatureIsRefusedNotInterpolated() throws {
        let set = try FlexibleCore.curveSet(path: Self.materialsPath, materialID: "varioshore_tpu",
                                            tempC: 205, topology: "gyroid")
        XCTAssertEqual(set.refusal?.code, "temperature_not_tested")
    }

    func testInverseRoundTripsThroughForward() throws {
        let p = Self.materialsPath
        let inv = try FlexibleCore.densityFor(path: p, materialID: "varioshore_tpu", tempC: 220,
                                              topology: "gyroid", targetStrain: 0.15, pressureMPa: 0.1)
        guard inv.status == "ok" else { return XCTFail("status \(inv.status)") }
        let fwd = try FlexibleCore.strainUnder(path: p, materialID: "varioshore_tpu", tempC: 220,
                                               topology: "gyroid", pressureMPa: 0.1,
                                               density: inv.coreDensity)
        XCTAssertEqual(fwd.strain, 0.15, accuracy: 1e-9)
    }

    func testCurveSamplesAreCoreStress() throws {
        let p = Self.materialsPath
        let set = try FlexibleCore.curveSet(path: p, materialID: "varioshore_tpu", tempC: 190,
                                            topology: "gyroid")
        let strains = [0, set.strainMeasuredMax, set.strainLimit + 0.05]
        let c = try FlexibleCore.curveSamples(path: p, materialID: "varioshore_tpu", tempC: 190,
                                              topology: "gyroid", density: 0.226, strains: strains)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].stressMPa ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(c[1].stressMPa ?? -1, 0.292, accuracy: 1e-9)
        XCTAssertNil(c[2].stressMPa, "past the data: no number")
    }

    // MARK: pen curves (F4)

    func testPenCurvePassesThroughItsPoints() throws {
        let x = [0.0, 0.3, 0.7, 1.0], y = [0.1, 0.9, 0.2, 0.6]   // an S-curve
        XCTAssertEqual(FlexibleCore.penCurveError(x: x, y: y), "")
        let v = try FlexibleCore.penCurveValues(x: x, y: y, t: x)
        for (a, b) in zip(v, y) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        // never overshoots its two neighbours
        let dense = try FlexibleCore.penCurveValues(x: x, y: y, t: stride(from: 0.3, through: 0.7, by: 0.01).map { $0 })
        XCTAssertTrue(dense.allSatisfy { $0 >= 0.2 - 1e-12 && $0 <= 0.9 + 1e-12 })
    }

    func testPenCurveErrorIsCoresSentence() {
        XCTAssertFalse(FlexibleCore.penCurveError(x: [0, 0.5, 0.4, 1], y: [0, 0, 0, 0]).isEmpty)
        XCTAssertFalse(FlexibleCore.penCurveError(x: [0.1, 1], y: [0, 0]).isEmpty)
        XCTAssertThrowsError(try FlexibleCore.penCurveValues(x: [0, 1], y: [0, 2], t: [0.5]))
    }

    // MARK: stamps (F8)

    func testStampGridForceCheck() {
        var g = FlexStamp(name: "block", originU: 10, originV: 10, cellMM: 1, nu: 10, nv: 10,
                          valuesMPa: Array(repeating: 0.2, count: 100), forceN: 20, rigid: false)
        XCTAssertEqual(FlexibleCore.stampError(g), "")
        XCTAssertEqual(FlexibleCore.stampForceN(g), 20, accuracy: 1e-9)
        g.forceN = 21
        XCTAssertFalse(FlexibleCore.stampError(g).isEmpty, "1 N off (5 %) is refused")
    }

    // MARK: scenes (F5–F9) on C1's pad

    func testBoxTopFaceFrameAndLinkedEnd() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let st = try scene.stack(face: 101, rotation: 0)
        XCTAssertTrue(st.frameValid)
        XCTAssertEqual(st.load.z, -1, accuracy: 1e-9, "top face: load into the part, -Z")
        XCTAssertEqual(st.uExtentMM, 100, accuracy: 1e-6)
        XCTAssertEqual(st.vExtentMM, 100, accuracy: 1e-6)
        XCTAssertTrue(st.principalAxisTied, "a square face has no longest direction")
        XCTAssertFalse(st.side)
        // Y = load × X (core's rule; the app only draws it)
        let y = simd_cross(st.load, st.xAxis)
        XCTAssertEqual(simd_length(y - st.yAxis), 0, accuracy: 1e-9)
        // the linked other end is the bottom, the whole footprint
        XCTAssertEqual(st.exitRegions.first?.id, 100)
        XCTAssertEqual(st.exitRegions.first?.fraction ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(st.columns.count, st.cell.filter { $0 >= 0 }.count)
        // from_uv: the (0, 0) corner and the far corner lie on the top plane
        let pts = try scene.fromUV(face: 101, rotation: 0, [SIMD2(0, 0), SIMD2(100, 100)])
        XCTAssertEqual(pts[0].z, 20, accuracy: 1e-6)
        XCTAssertEqual(simd_length(pts[1] - pts[0]), 100 * 2.0.squareRoot(), accuracy: 1e-6)
    }

    func testRotationTurnsTheFrame() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let a = try scene.stack(face: 101, rotation: 0), b = try scene.stack(face: 101, rotation: 90)
        XCTAssertEqual(simd_dot(a.xAxis, b.xAxis), 0, accuracy: 1e-9)
        XCTAssertEqual(b.rotationDeg, 90)
    }

    func testDesignComesFromCore() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          centreEdge: FlexCurve(x: [0, 1], y: [0, 1]), deepestMM: 4)
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        let d = try scene.design(materialsPath: Self.materialsPath, materialID: "varioshore_tpu",
                                 tempC: 220, face: 101, rotation: 0, map: map, weightN: 294.3,
                                 stamp: nil, build: build)
        XCTAssertNil(d.refusal)
        let n = try scene.stack(face: 101, rotation: 0).columns.count
        XCTAssertEqual(d.columns.count, n)
        XCTAssertEqual(d.ok + d.tooFirm + d.tooSoft + d.beyondData + d.noLattice, n)
        // target = S × deepest, S from core's own squish map
        let s = try scene.squishFraction(face: 101, rotation: 0, map: map)
        for k in stride(from: 0, to: n, by: 97) {
            XCTAssertEqual(d.columns[k].targetDepthMM, s[k] * 4, accuracy: 1e-9)
        }
        XCTAssertEqual(d.tier.tier, "literature")
        let bands = try FlexibleCore.errorBands(path: Self.materialsPath)
        XCTAssertEqual(d.tier.band, bands.literature, accuracy: 1e-12)
        // the density field is assembled from that design: its slice is lattice with ρ
        let slice = try scene.densitySlice(faces: [101], rotations: [0], build: build, axis: 2,
                                           index: 10)
        XCTAssertGreaterThan(slice.assignedVoxels, 0)
        XCTAssertTrue(slice.owner.contains(101))
    }

    func testCalibrateFirstDesignIsRefusedWithReason() throws {
        let mats = try FlexibleCore.materials(path: Self.materialsPath)
        let cal = try XCTUnwrap(mats.first { $0.tier == "calibrate_first" })
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let d = try scene.design(materialsPath: Self.materialsPath, materialID: cal.id, tempC: 220,
                                 face: 101, rotation: 0,
                                 map: FlexMap(mode: "centre_edge", x: .flat, y: .flat,
                                              centreEdge: FlexCurve(x: [0, 1], y: [0, 1]), deepestMM: 3),
                                 weightN: 100, stamp: nil,
                                 build: FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42))
        XCTAssertEqual(d.refusal?.code, "calibrate_first")
        XCTAssertTrue(d.columns.isEmpty, "no number is guessed")
    }

    func testSameStackConflictNamesBothFaces() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let c = try scene.conflicts(faces: [101, 100], rotations: [0, 0])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(Set([c[0].faceA, c[0].faceB]), [100, 101])
        XCTAssertGreaterThan(c[0].overlapMM3, 0)
    }

    func testCheckStampUsesTheDesignedDensities() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        _ = try scene.design(materialsPath: Self.materialsPath, materialID: "varioshore_tpu", tempC: 220,
                             face: 101, rotation: 0,
                             map: FlexMap(mode: "centre_edge", x: .flat, y: .flat,
                                          centreEdge: FlexCurve(x: [0, 1], y: [0.2, 1]), deepestMM: 3),
                             weightN: 294.3, stamp: nil, build: build)
        // a 20 × 20 mm soft block of 5 N in the middle, at half the column pitch
        let pitch = try scene.stack(face: 101, rotation: 0).pitchMM
        let cell = pitch / 2, n = Int((20 / cell).rounded())
        let p = 5 / (Double(n * n) * cell * cell)
        let stamp = FlexStamp(name: "block", originU: 40, originV: 40, cellMM: cell, nu: n, nv: n,
                              valuesMPa: Array(repeating: p, count: n * n), forceN: 5, rigid: false)
        XCTAssertEqual(FlexibleCore.stampError(stamp), "")
        let c = try scene.checkStamp(materialsPath: Self.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: 101, rotation: 0, stamp: stamp, build: build)
        XCTAssertTrue(c.ok)
        XCTAssertGreaterThan(c.pressedColumns, 0)
        XCTAssertGreaterThan(c.maxDepthMM, 0)
        XCTAssertFalse(c.offFace)
        // honesty: a pressed column has a depth, or says it is past the data — never both
        for k in c.depthMM.indices where !c.status[k].isEmpty {
            XCTAssertEqual(c.depthMM[k] == nil, c.status[k] == "beyond_data")
        }
        // a heavier press on the same soft design can leave the data: core says so per column
        let heavy = FlexStamp(name: "block", originU: 40, originV: 40, cellMM: cell, nu: n, nv: n,
                              valuesMPa: Array(repeating: p * 40, count: n * n), forceN: 200, rigid: false)
        let h = try scene.checkStamp(materialsPath: Self.materialsPath, materialID: "varioshore_tpu",
                                     tempC: 220, face: 101, rotation: 0, stamp: heavy, build: build)
        XCTAssertGreaterThan(h.beyondDataColumns, 0)
    }

    func testAutoGivesASentenceAndReasons() throws {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let map = FlexMap(mode: "centre_edge", x: .flat, y: .flat,
                          centreEdge: FlexCurve(x: [0, 1], y: [0.3, 1]), deepestMM: 3)
        let r = try scene.recommend(materialsPath: Self.materialsPath, materialID: "varioshore_tpu",
                                    temps: [190, 220, 240], topologies: ["gyroid", "honeycomb"],
                                    feel: "springy", beadsPerWall: 1, beadWidthMM: 0.42,
                                    faces: [FlexFaceRequest(face: 101, rotation: 0, map: map,
                                                            weightN: 294.3, stamp: nil)])
        XCTAssertTrue(r.chosen)
        XCTAssertFalse(r.sentence.isEmpty)
        XCTAssertFalse(r.reasons.isEmpty)
        XCTAssertEqual(r.candidates.count, 6, "2 families × 3 tested temperatures")
    }

    // MARK: the job block (F11) through core's parser

    func testJobBlockReadsBackThroughCoresParser() throws {
        let b = try FlexibleCore.parseJobBlock(try Self.padJob())
        XCTAssertEqual(b.materialID, "varioshore_tpu")
        XCTAssertEqual(b.nozzleTempC, 220)
        XCTAssertFalse(b.nozzleTempAuto)
        XCTAssertEqual(b.minExtrudableWidthMM, 0.42)
        XCTAssertEqual(b.faces.map(\.faceRegionID), [101, 100])
        XCTAssertEqual(b.faces[0].map.x.y, [0.3, 1, 0.3])
        XCTAssertEqual(b.faces[1].role, "resting")
    }
}

/// Timing probe (not a gate): FLEX_TIMING=1 swift test --filter FlexibleTimingProbe.
/// Prints what a curve drag costs: squish map + design, with the stack cached.
final class FlexibleTimingProbe: XCTestCase {
    func testPrintTimings() throws {
        guard ProcessInfo.processInfo.environment["FLEX_TIMING"] == "1" else { throw XCTSkip("FLEX_TIMING not set") }
        func t(_ f: () throws -> Void) rethrows -> Double {
            let a = Date(); try f(); return Date().timeIntervalSince(a) * 1000
        }
        var scene: FlexibleScene!
        let open = try t { scene = try FlexibleScene(jobJSON: try FlexibleBridgeTests.padJob(),
                                                    jobDir: FlexibleBridgeTests.padDir.path) }
        let st = try t { _ = try scene.stack(face: 101, rotation: 0) }
        let st2 = try t { _ = try scene.stack(face: 101, rotation: 0) }
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 4)
        let sq = try t { _ = try scene.squishFraction(face: 101, rotation: 0, map: map) }
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        var design = 0.0
        for _ in 0..<3 {
            design = try t { _ = try scene.design(materialsPath: FlexibleBridgeTests.materialsPath,
                                                  materialID: "varioshore_tpu", tempC: 220, face: 101,
                                                  rotation: 0, map: map, weightN: 294.3, stamp: nil, build: build) }
        }
        print(String(format: "FLEX_TIMING open %.0f ms · stack %.0f ms (cached %.1f ms) · squish %.1f ms · design %.0f ms",
                     open, st, st2, sq, design))
    }
}

/// Slice probe (not a gate): FLEX_SLICE=1 — prints a Z slice's per-column make-up.
final class FlexibleSliceProbe: XCTestCase {
    func testPrintSlice() throws {
        guard ProcessInfo.processInfo.environment["FLEX_SLICE"] == "1" else { throw XCTSkip("FLEX_SLICE not set") }
        var job = try FlexibleBridgeTests.padJob()
        job = job.replacingOccurrences(of: "\"resolution\": 100", with: "\"resolution\": 64")
        let scene = try FlexibleScene(jobJSON: job, jobDir: FlexibleBridgeTests.padDir.path)
        let info = try scene.info()
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 3)
        for f in [101, 103] {
            _ = try scene.design(materialsPath: FlexibleBridgeTests.materialsPath, materialID: "varioshore_tpu",
                                 tempC: 190, face: f, rotation: 0, map: map, weightN: 392, stamp: nil, build: build)
        }
        let s = try scene.densitySlice(faces: [101, 103], rotations: [0, 0], build: build, axis: 2, index: info.nz / 2)
        print("FLEX_SLICE grid \(info.nx)x\(info.ny)x\(info.nz) slice \(s.width)x\(s.height)")
        let row = s.height / 2
        let line = (0..<s.width).map { i -> String in
            let d = s.density[row * s.width + i], o = s.owner[row * s.width + i]
            return d < 0 ? "." : (o < 0 ? "0" : String(o % 10))
        }.joined()
        print("FLEX_SLICE mid row: \(line)")
    }
}
