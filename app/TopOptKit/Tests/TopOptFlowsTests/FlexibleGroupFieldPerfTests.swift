// FlexibleGroupFieldPerfTests — what the app's pinch assembly and two-segment design COST
// (task 2026-09-29-flexible-screens, round 4 batch D2; the plan: "measure per-case assembly time
// on a Release build … if it is slow, run it only on Exit or debounced"). Both run only when a
// lattice is BUILT (Save & Exit, an edit on the main page), never per drag.
//   * the assembler on a 128 × 128 × 128 all-lattice grid with FOUR faces (two pinches, the
//     sides of a 100 mm cube): the voxel loop the app runs where core refuses;
//   * the two-segment design of a 64 × 64 = 4,096-column face through core's own table.
// Opt-in (FLEX_D2_PERF=1): a timing is only meaningful on a Release build (memory: "cost only on
// Release"); in Debug it prints and asserts nothing about time.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleGroupFieldPerfTests: XCTestCase {

    /// A face of the cube [0, 100]³ pressed along `load`, `n × n` columns over the whole face.
    static func face(load: SIMD3<Double>, n: Int, region: Int) -> FlexibleGroupField.Face {
        let pitch = 100.0 / Double(n)
        // the frame: x / y axes in the face's plane, the centroid on the face, u / v from 0
        let (x, y): (SIMD3<Double>, SIMD3<Double>) = abs(load.x) > 0.5 ? (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
            : abs(load.y) > 0.5 ? (SIMD3(1, 0, 0), SIMD3(0, 0, 1)) : (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        let centroid = SIMD3<Double>(repeating: 50) - load * 50
        var cols: [FlexColumn] = [], cell: [Int] = []
        for iv in 0..<n { for iu in 0..<n {
            cell.append(cols.count)
            cols.append(FlexColumn(iu: iu, iv: iv, uMM: (Double(iu) + 0.5) * pitch, vMM: (Double(iv) + 0.5) * pitch,
                                   areaMM2: pitch * pitch, entryT: 0, exitT: 100, latticeMM: 100, exitFace: -1))
        } }
        let st = FlexStackInfo(frameValid: true, frameReason: "", load: load, xAxis: x, yAxis: y, centroid: centroid,
                               rotationDeg: 0, uMin: -50, vMin: -50, uExtentMM: 100, vExtentMM: 100, areaMM2: 10_000,
                               projectedAreaMM2: 10_000, normalSpreadDeg: 0, normalSpreadFlag: false, buildAngleDeg: 0,
                               side: false, principalAxisTied: false, pitchMM: pitch, nu: n, nv: n, cell: cell, columns: cols,
                               exitFaces: [], exitRegions: [], exitUnresolvedFraction: 0, footprintAreaMM2: 10_000,
                               latticedColumns: cols.count, latticeMMMin: 100, latticeMMMean: 100, latticeMMMax: 100, stackMMMax: 100)
        return FlexibleGroupField.Face(region: region, stack: st, cuts: [],
                                       density: cols.indices.map { 0.2 + 0.1 * Double($0 % 7) / 7 },
                                       cellMM: [Double](repeating: 6, count: cols.count))
    }

    @MainActor
    func testTheAssemblerAndTheSegmentDesignCost() throws {
        guard ProcessInfo.processInfo.environment["FLEX_D2_PERF"] == "1" else { throw XCTSkip("opt-in: FLEX_D2_PERF=1 (Release)") }
        let n = 128
        let mask = FlexDensityField(nx: n, ny: n, nz: n, spacing: 100.0 / Double(n), origin: .zero,
                                    density: [Float](repeating: 0, count: n * n * n), owner: [Int](repeating: -1, count: n * n * n))
        let faces = [Self.face(load: SIMD3(1, 0, 0), n: 64, region: 5), Self.face(load: SIMD3(-1, 0, 0), n: 64, region: 3),
                     Self.face(load: SIMD3(0, 1, 0), n: 64, region: 2), Self.face(load: SIMD3(0, -1, 0), n: 64, region: 4)]
        var times: [Double] = []
        var assigned = 0
        for _ in 0..<3 {
            let t0 = Date()
            let f = FlexibleGroupField.assemble(mask: mask, faces: faces)
            times.append(Date().timeIntervalSince(t0))
            assigned = f.density.filter { $0 > 0 }.count
        }
        let firmerT0 = Date()
        let one = FlexibleGroupField.assemble(mask: mask, faces: Array(faces.prefix(2)))
        let two = FlexibleGroupField.assemble(mask: mask, faces: Array(faces.suffix(2)))
        let assembleTwo = Date().timeIntervalSince(firmerT0)
        let t1 = Date()
        let c = FlexibleGroupField.firmer([one, two])
        let firmerTime = Date().timeIntervalSince(t1)
        print(String(format: "FLEX-PERF assemble 128³ (%d voxels), 4 faces, 2 pinches: %@ s (3 runs) · %d assigned · two groups %.3f s + firmer %.3f s (%d shared)",
                     n * n * n, times.map { String(format: "%.3f", $0) }.joined(separator: " / "), assigned, assembleTwo, firmerTime, c.shared))
        // the two-segment design of a 4,096-column face through core's own table
        let path = FlexibleHisProject.materialsPath
        let build = FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.45)
        let temps = try FlexibleCore.materials(path: path).first { $0.id == "varioshore_tpu" }?.testedTempsC ?? []
        let temp = try XCTUnwrap(temps.first)
        let law = try FlexiblePinch.Law.core(materialsPath: path, materialID: "varioshore_tpu", tempC: temp, build: build)
        let st = Self.face(load: SIMD3(0, 0, -1), n: 64, region: 1).stack
        let cols = st.columns.map { _ in
            FlexColumnDesign(s: 1, pressureMPa: 0.02, heightMM: 100, targetDepthMM: 3, targetStrain: 0.03, status: "ok",
                             targetExtrapolated: false, targetDensity: 0.3, nearestDepthMM: nil, nearestKnown: false,
                             clampedDensity: 0.3, clampedDepthMM: nil, buildableDensity: 0.3, buildableDepthMM: 3,
                             buildableOK: true, buildableExtrapolated: false, cellMM: 6, sigmaMM: 3)
        }
        let d = FlexFaceDesignInfo(refusal: nil, columns: cols, tier: FlexTier(tier: "t", band: 0, why: ""), ok: cols.count,
                                   tooFirm: 0, tooSoft: 0, beyondData: 0, noLattice: 0, solidUnderMap: 0, targetExtrapolated: 0,
                                   buildableExtrapolated: 0, buildableBeyondData: 0, nearEdge: 0, designPressureEvenMPa: 0.02,
                                   designStampUsed: false, designStampRigidAveraged: false, designStampOffFace: false,
                                   designStampOffFaceN: 0, maxSmoothingChangeMM: 0, materialVolumeMM3: 0, targetDepthRange: nil,
                                   buildableDepthRange: nil, buildableDensityRange: nil, cellRange: nil, sigmaRange: nil)
        let t2 = Date()
        let s = try FlexiblePinch.design(d, stack: st, pinched: [Bool](repeating: true, count: cols.count), law: law)
        let designTime = Date().timeIntervalSince(t2)
        print(String(format: "FLEX-PERF two-segment design, %d columns through core's table: %.3f s (ρ %.3f…%.3f)",
                     cols.count, designTime, s.buildableDensity.min() ?? 0, s.buildableDensity.max() ?? 0))
        XCTAssertGreaterThan(assigned, 0)
    }
}
