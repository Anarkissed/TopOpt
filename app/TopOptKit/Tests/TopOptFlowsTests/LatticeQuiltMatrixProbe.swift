import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE EVIDENCE TABLE — every setting combination that produces a lattice, on
/// his own part, scored against the rules he stated on 2026-08-26.
///
/// One row per combination, with:
///   * how many distinct cell sizes the wall carries and the smallest,
///   * how many cells sit at exactly S/2 (a FAILURE on the stepped path — "any
///     number but 1/2 is ok"; on default grade halving IS the step),
///   * the fraction finer than S/3 (the fabric measure),
///   * SEE-THROUGH from front and back: a pixel inside the part's own silhouette
///     that reads as background, i.e. you are looking clean through material.
///
/// Frames are written to `$QUILT_OUT` so each row has a picture behind it.
///
/// This is NOT a verdict. A row that scores clean here still has to be looked at in
/// the simulator, zoomed, before it counts.
final class LatticeQuiltMatrixProbe: XCTestCase {

    typealias B = LatticeQuiltBakeProbe
    typealias F = LatticeQuiltFrameProbe

    struct Combo {
        var singleCell: Bool
        var finish: LatticeBoundaryTreatment
        var grade: String              // "shape" | "no-grade"
        /// ★★★ NOT the UI's "Default Grade". `LatticeCellTransition.defaultGrade`
        /// maps to `algorithm: "doubled"` (`coreAlgorithm`), which the preview bakes
        /// through `gradedCellField` — the dyadic LADDER, a different function
        /// entirely — and `steppedCellField` is not called at all
        /// (`DIAG steppedCells GUARD algo='doubled'`). This flag is the stepped
        /// bake's own `dyadicSteps` option, which rounds each fit division up to a
        /// power of two. The doubled path is untouched by anything in this file and
        /// needs its own coverage.
        var dyadic: Bool               // stepped bake, dyadic step style
        var density: Double            // uniform relative density
        var name: String {
            String(format: "%@ · %-8@ · %-8@ · %@ · rho %.2f",
                   singleCell ? "1-cell " : "2-cell " as NSString,
                   finish.rawValue as NSString, grade as NSString,
                   dyadic ? "dyadic-steps" : "stepped-steps" as NSString, density)
        }
    }

    /// Scene inputs are expensive (occupancy, SDF, two BFS fields, two width walks)
    /// and depend only on the finish flags — so they are built once per distinct pair.
    static var cache: [String: B.Inputs] = [:]

    static func inputs(for c: Combo) throws -> B.Inputs {
        var h = B.His()
        // ★ `boundaryFinishWritten` is `singleCellMembers && boundary != .none` — the
        // app's own expression. So single-cell with NO finish still gets core's floor
        // of 2: core will only allow one cell across a member when a finish re-ties
        // the struts that a one-cell member severs. That interaction is real and the
        // table has to show it rather than pretend the toggle acts alone.
        h.boundaryFinishWritten = c.singleCell && c.finish != .none
        h.skinMM = c.finish == .covered ? 0.9 : (c.finish == .fullSkin ? 0.9 : 0)
        h.shapeFit = c.grade == "shape"
        h.shapeFitBandMM = c.grade == "shape" ? 10 : 0
        h.dyadicSteps = c.dyadic
        let key = "\(h.boundaryFinishWritten)|\(h.skinMM)"
        if let hit = cache[key] {
            var i = hit
            i.h = h
            return i
        }
        let built = try B.inputs(h)
        cache[key] = built
        return built
    }

    static let combos: [Combo] = {
        var out: [Combo] = []
        for single in [true, false] {
            for finish in LatticeBoundaryTreatment.allCases {
                for grade in ["shape", "no-grade"] {
                    for dyadic in [false, true] {
                        out.append(Combo(singleCell: single, finish: finish,
                                         grade: grade, dyadic: dyadic, density: 0.05))
                    }
                }
            }
        }
        // ★ AND THE DENSITY BAND, on the configuration he actually uses. Density
        // cannot change the CELL, but it changes the strut, and "too dense to see
        // through" and "too thin to see" are both failures he has reported.
        for rho in [0.20, 0.50, 0.90] {
            out.append(Combo(singleCell: true, finish: .fullSkin, grade: "shape",
                             dyadic: false, density: rho))
        }
        return out
    }()

    func testTheWholeMatrix() throws {
        let device = MTLCreateSystemDefaultDevice()
        let size = 900
        var lines: [String] = []
        var failures: [String] = []

        for c in Self.combos {
            let i = try Self.inputs(for: c)
            guard let baked = B.bake(i) else {
                failures.append("\(c.name): NO BAKE")
                continue
            }
            let hist = B.histogram(baked)
            let painted = hist.values.reduce(0, +)
            let ordered = hist.keys.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
            let minMM = ordered.first.flatMap { Double($0) } ?? 0
            let S = i.cells.filter { $0 > 0 }.max() ?? 1
            let fabric = hist.filter { (Double($0.key) ?? 0) < S / 3.0001 }
                .values.reduce(0, +)
            // S/2 on the stepped path only.
            var atHalf = 0
            if !c.dyadic {
                for (k, n) in hist {
                    guard let v = Double(k) else { continue }
                    for cell in i.cells where cell > 0 {
                        if abs(v - cell / 2) <= 0.02 { atHalf += n }
                    }
                }
            }

            // See-through, front and back.
            var see = "n/a"
            if let device {
                var worst = 0.0
                if let plain = MeshRenderer(device: device, sampleCount: 4) {
                    plain.setMesh(i.scene.mesh)
                    plain.showGround = false
                    plain.beginSettle(to: F.settle, duration: 0)
                    if let mr = F.renderer(i, device: device, tweak: {
                        $0.latticeDressingLevel = c.finish.previewDressingLevel
                        var p = $0.latticeParams
                        p.uniformRelativeDensity = c.density
                        p.minRelativeDensity = c.density
                        p.maxRelativeDensity = Swift.max(c.density, i.h.rhoMax)
                        $0.latticeParams = p
                    }) {
                        for (label, az) in [("front", Float.pi), ("back", Float(0))] {
                            F.aim(plain, i.scene.bounds, azimuth: az, elevation: 0.18,
                                  zoom: 0.30, height: 0.20)
                            F.aim(mr, i.scene.bounds, azimuth: az, elevation: 0.18,
                                  zoom: 0.30, height: 0.20)
                            guard let sil = plain.renderOffscreen(size: size, clear: F.clear),
                                  let f = mr.renderOffscreen(size: size, clear: F.clear)
                            else { continue }
                            let n = LatticeHoleMetricProbe.count(
                                silhouette: sil, frame: f, size: size)
                            let pct = n.silhouette > 0
                                ? 100 * Double(n.seeThrough) / Double(n.silhouette) : 0
                            worst = Swift.max(worst, pct)
                            let slug = c.name
                                .replacingOccurrences(of: " ", with: "")
                                .replacingOccurrences(of: "·", with: "_")
                            F.writePNG(f, size: size,
                                       to: F.outDir + "/mx_\(slug)_\(label).png")
                        }
                    }
                }
                see = String(format: "%.2f%%", worst)
                if worst > 0.05 { failures.append("\(c.name): see-through \(see)") }
            }
            if atHalf > 0 { failures.append("\(c.name): \(atHalf) cells at S/2") }

            lines.append(String(format:
                "%@  sizes %2d  min %5.2f  below-S/3 %4d (%4.1f%%)  at-S/2 %3d  see-through %@",
                c.name as NSString, ordered.count, minMM, fabric,
                100 * Double(fabric) / Double(Swift.max(1, painted)),
                atHalf, see as NSString))
        }

        print("=== THE EVIDENCE TABLE ===")
        for l in lines { print("  " + l) }
        print("=== FAILURES ===")
        if failures.isEmpty { print("  none") }
        for f in failures { print("  " + f) }
        print("frames -> \(F.outDir)")
    }
}
