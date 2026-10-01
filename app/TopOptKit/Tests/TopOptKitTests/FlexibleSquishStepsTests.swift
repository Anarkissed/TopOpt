// FlexibleSquishStepsTests — the squish solved in STEPS, through the bridge, on C1's 100 × 100 × 20
// pad (task 2026-09-29-flexible-screens, round 5 batch N; maintainer, on batch G's fold cut: "Is
// there no way to fold realistically instead?"). The pad, its grid, its lattice mask and its stacks
// are core's (FlexibleSquishFETests' fixture); the presses are built here so each claim stands on
// its own. Every claim has a RED control that fails the same assertion:
//   * the law IS core's curve up to its last tested strain, then densifies (RED: the curve held at
//     its last tested secant — what the tested data alone says);
//   * the over-squished zone FIRMS UP: its peak principal compressive strain drops against the
//     linear sim's (RED: the linear moduli; and the law held at its data's end, which SOFTENS);
//   * at full size no element inverts where the linear sim folds (RED: the linear sim);
//   * the free sides still bulge (RED: ν = 0);
//   * a symmetric pad stays symmetric (RED: an off-centre stamp);
//   * a step is the SAME problem as the linear solve (one solve at the initial moduli is the linear
//     field — RED: another load factor);
//   * a session ends (RED: one left open is counted).
import XCTest
import simd
@testable import TopOptKit

final class FlexibleSquishStepsTests: XCTestCase {

    typealias FE = FlexibleSquishFETests
    /// His filament as he left it for round 5 (varioShore TPU, gyroid, 240 °C — the gyroid's tested
    /// curve SOFTENS up to its last tested strain, 0.25).
    static let law240 = FlexSquishLawInfo(materialsPath: FE.materialsPath, materialID: "varioshore_tpu", topology: "gyroid",
                                          tempC: 240, shapeOnly: false)

    static func request(_ pad: FE.Pad, pressed: [FlexSquishPressInfo], resting: [Int], rho: [Float]? = nil,
                        control: Int = 0) -> FlexSquishRequestInfo {
        var r = FE.request(pad, pressed: pressed, resting: resting, rho: rho, control: control)
        r.law = law240
        return r
    }

    /// A press of `weightN` on the top's columns within `radius` mm of (cx, cy) (none elsewhere).
    static func patch(_ pad: FE.Pad, weightN: Double, radius: Double, cx: Double = 50, cy: Double = 50) throws -> FlexSquishPressInfo {
        let st = try pad.scene.stack(face: FE.top, rotation: 0)
        let inside = st.columns.map { c -> Bool in
            let p = st.centroid + st.xAxis * (c.uMM + st.uMin) + st.yAxis * (c.vMM + st.vMin)
            return hypot(p.x - cx, p.y - cy) <= radius
        }
        let area = zip(st.columns, inside).filter { $0.1 }.reduce(0.0) { $0 + $1.0.areaMM2 }
        return FlexSquishPressInfo(face: FE.top, rotation: 0, columnPressureMPa: inside.map { $0 ? weightN / area : 0 })
    }

    /// The stepped solve to `lambda` × the design force in `n` increments (FlexibleFERefine's loop,
    /// without its calibration): (the last field, every step converged).
    static func stepped(_ pad: FE.Pad, _ r: FlexSquishRequestInfo, lambda: Double = 1, increments n: Int = 8,
                        pastData: FlexSquishPastData = .densifies) throws -> (FlexSquishSolutionInfo, Bool, [FlexSquishSolutionInfo]) {
        let steps = try pad.scene.squishSteps(r, pastData: pastData)
        defer { steps.end() }
        XCTAssertTrue(steps.setup.ok, steps.setup.failure)
        var all: [FlexSquishSolutionInfo] = []
        for i in 1...n {
            let s = try steps.step(loadFactor: lambda * Double(i) / Double(n), iterations: i == n ? 6 : 3, tolerance: 0.02)
            XCTAssertTrue(s.ok, s.failure)
            all.append(s)
        }
        return (all.last!, all.last!.fixedPointConverged, all)
    }

    /// Over the PART's cells (8 nodes solved): the peak principal compressive strain at the centre
    /// (max(0, −λ_min(sym ∇u)) — the bridge's measure), how many cells invert (det(I + ∇u) ≤ 0 at a
    /// corner) and the smallest corner det.
    static func stats(_ s: FlexSquishSolutionInfo) -> (peak: Double, inverted: Int, minDet: Double) {
        var peak = 0.0, inv = 0
        var lo = Double.infinity
        let h = s.spacing
        for c in 0..<(s.nz - 1) { for b in 0..<(s.ny - 1) { for a in 0..<(s.nx - 1) {
            var all = true
            for dc in 0...1 { for db in 0...1 { for da in 0...1 where !s.solved[s.node(a + da, b + db, c + dc)] { all = false } } }
            guard all else { continue }
            var gx = SIMD3<Double>.zero, gy = SIMD3<Double>.zero, gz = SIMD3<Double>.zero
            var bad = false
            for k in 0...1 { for j in 0...1 { for i in 0...1 {
                let cx = (s.displacement(s.node(a + 1, b + j, c + k)) - s.displacement(s.node(a, b + j, c + k))) / h
                let cy = (s.displacement(s.node(a + i, b + 1, c + k)) - s.displacement(s.node(a + i, b, c + k))) / h
                let cz = (s.displacement(s.node(a + i, b + j, c + 1)) - s.displacement(s.node(a + i, b + j, c))) / h
                let d = simd_determinant(matrix_identity_double3x3 + simd_double3x3(cx, cy, cz))
                lo = min(lo, d)
                if d <= 0 { bad = true }
                if i == 0 { gx += cx }
                if j == 0 { gy += cy }
                if k == 0 { gz += cz }
            } } }
            if bad { inv += 1 }
            let G = simd_double3x3(gx / 4, gy / 4, gz / 4)
            let sym = 0.5 * (G + G.transpose)
            peak = max(peak, max(0, -minEig(sym)))
        } } }
        return (peak, inv, lo)
    }

    static func minEig(_ m: simd_double3x3) -> Double {
        let a = m[0][0], b = m[1][1], c = m[2][2], d = m[1][0], e = m[2][1], f = m[2][0]
        let p1 = d * d + e * e + f * f
        if p1 < 1e-30 { return min(a, b, c) }
        let q = (a + b + c) / 3
        let p = (((a - q) * (a - q) + (b - q) * (b - q) + (c - q) * (c - q) + 2 * p1) / 6).squareRoot()
        let B = (m - simd_double3x3(diagonal: SIMD3(repeating: q))) * (1 / p)
        let r = min(1, max(-1, simd_determinant(B) / 2))
        return q + 2 * p * cos(acos(r) / 3 + 2 * .pi / 3)
    }

    // MARK: - the law

    func testTheSteppedLawIsCoresCurveUpToItsDataThenDensifies() throws {
        let lim = 0.25
        for rho in [0.12, 0.15, 0.2, 0.3] {
            // up to the last tested strain: EXACTLY the linear law's secant there (core's curve)
            for eps in [0.02, 0.05, 0.1, 0.15, 0.2, 0.25] {
                let stepped = try FlexibleCore.squishStepModulus(law: Self.law240, rho: rho, strain: eps)
                let curve = try FlexibleCore.squishModulus(law: Self.law240, rho: rho, strain: eps, skinFrac: 0)
                XCTAssertEqual(stepped, curve, accuracy: 1e-12 * curve, "ρ \(rho) ε \(eps): core's curve")
            }
            func sigma(_ e: Double, _ past: FlexSquishPastData = .densifies) throws -> Double {
                try FlexibleCore.squishStepModulus(law: Self.law240, rho: rho, strain: e, pastData: past) * e
            }
            // joined C¹ at the last tested strain: the stress and its slope carry on
            let d = 1e-3
            let sL = try sigma(lim), below = (sL - (try sigma(lim - d))) / d, above = ((try sigma(lim + d)) - sL) / d
            let eL = sL / lim
            // past it the cells close: by ε_D = 1 − 1.4 ρ the secant has passed 3× its value at the data's end
            let eD = max(lim + 0.05, 1 - 1.4 * rho)
            let near = try FlexibleCore.squishStepModulus(law: Self.law240, rho: rho, strain: eD - 0.01)
            let at = try FlexibleCore.squishStepModulus(law: Self.law240, rho: rho, strain: eD)
            var rises = true
            var prev = try sigma(lim)
            for k in 1...40 {
                let s = try sigma(lim + (eD - lim) * Double(k) / 41)
                if s <= prev { rises = false }
                prev = s
            }
            print(String(format: "FLEX-N LAW ρ %.2f: secant at the data's end %.4f MPa · slope below %.4f above %.4f · ε_D %.2f · secant at ε_D − 0.01 %.3f (×%.1f) · at ε_D %.1f MPa",
                         rho, eL, below, above, eD, near, near / eL, at))
            XCTAssertEqual(above, below, accuracy: 0.05 * abs(below) + 1e-6, "ρ \(rho): the slope carries on past the data")
            XCTAssertTrue(rises, "ρ \(rho): the stress rises all the way to ε_D")
            XCTAssertGreaterThanOrEqual(near / eL, 3, "ρ \(rho): the cells close — the secant firms up")
            XCTAssertEqual(at, 50, accuracy: 1e-9, "ρ \(rho): fully closed is the solid filament (50 MPa)")
            // ★ RED CONTROL: the curve held at its last tested secant — what the tested data alone says
            let held = try FlexibleCore.squishStepModulus(law: Self.law240, rho: rho, strain: eD - 0.01, pastData: .heldAtLastTest)
            print(String(format: "FLEX-N LAW control (held) ρ %.2f: secant at ε_D − 0.01 %.4f (×%.2f)", rho, held, held / eL))
            XCTAssertLessThan(held / eL, 3, "control: held at the data's end, nothing firms up")
        }
        // ★ the premise his curve forces (varioShore gyroid, 240 °C): up to its data the secant FALLS
        let s10 = try FlexibleCore.squishStepModulus(law: Self.law240, rho: 0.15, strain: 0.1)
        let s25 = try FlexibleCore.squishStepModulus(law: Self.law240, rho: 0.15, strain: 0.25)
        print(String(format: "FLEX-N LAW premise ρ 0.15: secant at 0.10 %.4f, at 0.25 %.4f (%.0f%%)", s10, s25, 100 * (s25 / s10 - 1)))
        XCTAssertLessThan(s25, s10, "premise: the tested gyroid curve softens up to its last tested strain")
    }

    // MARK: - the over-squished zone firms up

    func testTheOverSquishedZoneFirmsUpAndNothingInverts() throws {
        let pad = try FE.pad()
        let rho = pad.rho { _ in 0.15 }
        let press = try Self.patch(pad, weightN: Double(ProcessInfo.processInfo.environment["FLEX_N_PATCH_N"] ?? "") ?? 210, radius: 15)
        let r = Self.request(pad, pressed: [press], resting: [FE.bottom], rho: rho)
        // ★ RED CONTROL 1 — the linear sim (the batch G law: every voxel at its initial modulus here)
        let lin = try pad.scene.squishSolve(r)
        XCTAssertTrue(lin.ok, lin.failure)
        let l = Self.stats(lin)
        let (st, converged, all) = try Self.stepped(pad, r)
        let s = Self.stats(st)
        // ★ RED CONTROL 2 — the stepped solve with the curve held at its data's end (no densification)
        let (held, heldConverged, _) = try Self.stepped(pad, r, pastData: .heldAtLastTest)
        let h = Self.stats(held)
        print(String(format: "FLEX-N ZONE linear: peak strain %.3f · inverted %d (min det %.3f) · max|u| %.2f mm", l.peak, l.inverted, l.minDet, FE.maxU(lin)))
        print(String(format: "FLEX-N ZONE stepped: peak strain %.3f (bridge %.3f) · inverted %d (min det %.3f) · max|u| %.2f mm · converged %@ · solves %@",
                     s.peak, st.strainMax, s.inverted, s.minDet, FE.maxU(st), "\(converged)", "\(all.map(\.fixedPointIterations))"))
        print(String(format: "FLEX-N ZONE control held: peak strain %.3f · inverted %d (min det %.3f) · converged %@", h.peak, h.inverted, h.minDet, "\(heldConverged)"))
        // premise: the press over-squishes the zone past the tested data, and the linear sim folds there
        XCTAssertGreaterThan(l.peak, 0.25, "premise: past the curves' last tested strain")
        XCTAssertGreaterThan(l.inverted, 0, "premise / RED control 1: the linear sim folds at full size")
        XCTAssertTrue(converged, "the stepped solve settles")
        XCTAssertEqual(st.strainMax, s.peak, accuracy: 1e-3 * s.peak, "the bridge's strain receipt is this measure")
        XCTAssertLessThanOrEqual(s.peak, 0.8 * l.peak, "the over-squished zone firms up (RED control 1: the linear moduli)")
        XCTAssertEqual(s.inverted, 0, "no element inverts at full size")
        XCTAssertGreaterThan(s.minDet, 0.05)
        XCTAssertGreaterThan(h.peak, 0.8 * l.peak, "RED control 2: held at its data's end the zone does NOT firm up")
    }

    // MARK: - the sides, the symmetry, the problem

    func testTheFreeSidesStillBulge() throws {
        let pad = try FE.pad()
        let press = try pad.press(FE.top, weightN: 600)
        for (name, control) in [("stepped", 0), ("RED control ν = 0", 1)] {
            let (s, converged, _) = try Self.stepped(pad, Self.request(pad, pressed: [press], resting: [FE.bottom], control: control))
            XCTAssertTrue(converged, name)
            let deepest = FE.topDeepest(s)
            let sides: [(SIMD3<Double>, SIMD3<Double>)] = [(SIMD3(0, 50, 10), SIMD3(-1, 0, 0)), (SIMD3(100, 50, 10), SIMD3(1, 0, 0)),
                                                            (SIMD3(50, 0, 10), SIMD3(0, -1, 0)), (SIMD3(50, 100, 10), SIMD3(0, 1, 0))]
            let out = sides.map { simd_dot(FE.u(s, $0.0), $0.1) }
            print(String(format: "FLEX-N BULGE %@: top %.3f mm · sides out %@ mm (%.1f%%) · strain p99 %.3f",
                         name, deepest, out.map { String(format: "%.3f", $0) }.joined(separator: " / "), 100 * (out.min() ?? 0) / deepest, s.strainP99))
            if control == 0 {
                for o in out { XCTAssertGreaterThanOrEqual(o, 0.03 * deepest, "each free side bulges out") }
            } else {
                XCTAssertLessThan(out.map(abs).max() ?? 0, 0.01 * deepest, "control: ν = 0 does not bulge")
            }
        }
    }

    /// A symmetric dome of density pressed evenly past the tested data (a stamp's edge would not do:
    /// the loads sample the columns at the FE cells' face centres, which mirror only for an even press
    /// — the linear sim's own 12 % on a 15 mm patch).
    func testASymmetricPadStaysSymmetric() throws {
        let pad = try FE.pad()
        let rho = pad.rho { p in 0.15 + 0.2 * (abs(p.x - 50) + abs(p.y - 50)) / 100 }
        let w = Double(ProcessInfo.processInfo.environment["FLEX_N_SYM_N"] ?? "") ?? 1500
        let press = try pad.press(FE.top, weightN: w)
        let (s, converged, _) = try Self.stepped(pad, Self.request(pad, pressed: [press], resting: [FE.bottom], rho: rho))
        XCTAssertTrue(converged)
        let e = FE.mirrorError(s)
        print(String(format: "FLEX-N SYMMETRY stepped: %.3g (x) · %.3g (y) of max|u| %.3f · strain max %.3f · beyond data %d", e.x, e.y, FE.maxU(s), s.strainMax, s.beyondDataElements))
        XCTAssertGreaterThan(s.strainMax, 0.25, "premise: past the tested data, where the law is nonlinear")
        XCTAssertLessThanOrEqual(max(e.x, e.y), 2e-3)
        // ★ RED CONTROL: an OFF-CENTRE stamp (columns at u, v in [60, 80], as batch G's control)
        let st = try pad.scene.stack(face: FE.top, rotation: 0)
        let stamp = st.columns.map { c -> Double in (60...80).contains(c.uMM) && (60...80).contains(c.vMM) ? w / 400 : 0 }
        let off = FlexSquishPressInfo(face: FE.top, rotation: 0, columnPressureMPa: stamp)
        let (o, _, _) = try Self.stepped(pad, Self.request(pad, pressed: [off], resting: [FE.bottom], rho: rho))
        let eo = FE.mirrorError(o)
        print(String(format: "FLEX-N SYMMETRY control (off-centre): %.3g (x) · %.3g (y)", eo.x, eo.y))
        XCTAssertGreaterThan(max(eo.x, eo.y), 0.05, "control: an off-centre stamp is not symmetric")
    }

    func testAStepIsTheLinearProblemAndASessionEnds() throws {
        let pad = try FE.pad()
        let before = FlexSquishSteps.liveSessions
        let press = try pad.press(FE.top, weightN: 294.3)
        let r = Self.request(pad, pressed: [press], resting: [FE.bottom])
        let lin = try pad.scene.squishSolve(r)
        let steps = try pad.scene.squishSteps(r)
        XCTAssertEqual(FlexSquishSteps.liveSessions, before + 1)
        XCTAssertEqual(steps.setup.pinnedDOFs, lin.pinnedDOFs, "the same rests and pins")
        XCTAssertEqual(steps.setup.pressForceN, lin.pressForceN, "the same loads")
        // one solve from rest at λ = 1: every voxel at its initial modulus — the linear law's at strain 0
        let one = try steps.step(loadFactor: 1, iterations: 1, tolerance: 0.02)
        XCTAssertTrue(one.ok, one.failure)
        let m = FE.maxU(lin), d = FE.maxDifference(lin, one)
        print(String(format: "FLEX-N SAME: one step vs the linear solve %.3g of max|u| %.4f · load factor %.2f · %d solve(s)", d / m, m, one.loadFactor, one.fixedPointIterations))
        XCTAssertLessThanOrEqual(d, 2e-3 * m, "the same problem")
        // ★ RED CONTROL: another load factor (a fresh session at ×1.5) is another field
        let other = try pad.scene.squishSteps(r)
        let x15 = try other.step(loadFactor: 1.5, iterations: 1, tolerance: 0.02)
        XCTAssertGreaterThan(FE.maxDifference(lin, x15), 0.3 * m, "control: ×1.5 moves 1.5×")
        other.end()
        steps.end()
        XCTAssertEqual(FlexSquishSteps.liveSessions, before, "every session ended")
        XCTAssertThrowsError(try steps.step(loadFactor: 1, iterations: 1, tolerance: 0.02), "an ended session refuses")
        // ★ RED CONTROL: a session left open is counted
        let open = try pad.scene.squishSteps(r)
        XCTAssertEqual(FlexSquishSteps.liveSessions, before + 1, "control: an open session is live")
        open.end()
    }
}

