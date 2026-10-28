// FlexibleBatchNProbe — what the linear sim's fold IS, before the stepped solve is designed (task
// 2026-09-29-flexible-screens, round 5 batch N). Opt-in (FLEX_N_PROBE=1): the law's secant over
// strain, and per group on his round-5 project the strain the LINEAR field asks of each element —
// its principal compressive strain (the curves' own axis), its rotation, where the fold is.
#if canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchNProbe: XCTestCase {

    static var on: Bool { ProcessInfo.processInfo.environment["FLEX_N_PROBE"] == "1" }

    /// Per element (all 8 corners solved): its centre gradient G (columns ∂u/∂x, ∂u/∂y, ∂u/∂z) of `u` / `per`.
    static func elementGradients(_ f: FlexibleFEField, divide per: Float) -> [(e: Int, g: simd_float3x3)] {
        var out: [(Int, simd_float3x3)] = []
        let h = f.spacing
        for c in 0..<(f.nz - 1) { for b in 0..<(f.ny - 1) { for a in 0..<(f.nx - 1) {
            var all = true
            for dc in 0...1 { for db in 0...1 { for da in 0...1 where !f.solved[f.node(a + da, b + db, c + dc)] { all = false } } }
            guard all else { continue }
            var gx = SIMD3<Float>.zero, gy = SIMD3<Float>.zero, gz = SIMD3<Float>.zero
            for j in 0...1 { for k in 0...1 {
                gx += f.u[f.node(a + 1, b + j, c + k)] - f.u[f.node(a, b + j, c + k)]
                gy += f.u[f.node(a + j, b + 1, c + k)] - f.u[f.node(a + j, b, c + k)]
                gz += f.u[f.node(a + j, b + k, c + 1)] - f.u[f.node(a + j, b + k, c)]
            } }
            let s = 0.25 / (h * per)
            out.append(((c * (f.ny - 1) + b) * (f.nx - 1) + a, simd_float3x3(gx * s, gy * s, gz * s)))
        } } }
        return out
    }

    /// The eigenvalues of a symmetric 3×3 (ascending).
    static func symEig(_ m: simd_float3x3) -> SIMD3<Double> {
        let a = Double(m[0][0]), b = Double(m[1][1]), c = Double(m[2][2])
        let d = Double(m[1][0]), e = Double(m[2][1]), f = Double(m[2][0])
        let p1 = d * d + e * e + f * f
        if p1 < 1e-30 { let v = [a, b, c].sorted(); return SIMD3(v[0], v[1], v[2]) }
        let q = (a + b + c) / 3
        let p2 = (a - q) * (a - q) + (b - q) * (b - q) + (c - q) * (c - q) + 2 * p1
        let p = (p2 / 6).squareRoot()
        let B00 = (a - q) / p, B11 = (b - q) / p, B22 = (c - q) / p, B01 = d / p, B12 = e / p, B02 = f / p
        let det = B00 * (B11 * B22 - B12 * B12) - B01 * (B01 * B22 - B12 * B02) + B02 * (B01 * B12 - B11 * B02)
        let r = min(1, max(-1, det / 2))
        let phi = acos(r) / 3
        let e1 = q + 2 * p * cos(phi), e3 = q + 2 * p * cos(phi + 2 * .pi / 3)
        return SIMD3(e3, 3 * q - e1 - e3, e1)
    }

    /// Cells of the PART (8 corners solved) where det(I + s ∇u) ≤ 0 at any corner (the trilinear
    /// Jacobian's corner values), and the smallest det seen.
    static func inverted(_ f: FlexibleFEField, _ s: Float) -> (count: Int, minDet: Float) {
        var n = 0
        var lo: Float = .infinity
        let h = f.spacing
        for c in 0..<(f.nz - 1) { for b in 0..<(f.ny - 1) { for a in 0..<(f.nx - 1) {
            var all = true
            for dc in 0...1 { for db in 0...1 { for da in 0...1 where !f.solved[f.node(a + da, b + db, c + dc)] { all = false } } }
            guard all else { continue }
            var bad = false
            for k in 0...1 { for j in 0...1 { for i in 0...1 {
                let cx = (f.u[f.node(a + 1, b + j, c + k)] - f.u[f.node(a, b + j, c + k)]) / h
                let cy = (f.u[f.node(a + i, b + 1, c + k)] - f.u[f.node(a + i, b, c + k)]) / h
                let cz = (f.u[f.node(a + i, b + j, c + 1)] - f.u[f.node(a + i, b + j, c)]) / h
                let d = simd_determinant(matrix_identity_float3x3 + simd_float3x3(cx * s, cy * s, cz * s))
                lo = min(lo, d)
                if d <= 0 { bad = true }
            } } }
            if bad { n += 1 }
        } } }
        return (n, lo)
    }

    /// His round-5 project's groups refined (both laws past the data), against the linear field.
    func testTheSteppedSolveOnHisRound5Project() async throws {
        guard Self.on else { throw XCTSkip("FLEX_N_PROBE=1") }
        let (r, m) = try await Self.round5(self)
        _ = r
        try await Self.refineAll(m, "his r5")
    }

    func testTheSteppedSolveOnC1sPadsAndTheM2Stand() async throws {
        guard Self.on else { throw XCTSkip("FLEX_N_PROBE=1") }
        let which = ProcessInfo.processInfo.environment["FLEX_N_CASES"] ?? "bare,covered,m2"
        if which.contains("his0004") {
            // his project 0004 as saved (one group: the top and the Face 3 | Face 5 pinch)
            let (r, m) = try await FlexibleSquishFixture.his(self, "his 0004")
            _ = r
            try await Self.refineAll(m, "his 0004")
        }
        if which.contains("bare") {
            let bare = try await FlexibleSquishFixture.pad(self, finish: "none")
            try await Self.refineAll(bare, "C1 pad bare")
        }
        if which.contains("covered") {
            let cov = try await FlexibleSquishFixture.pad(self, finish: "covered")
            try await Self.refineAll(cov, "C1 pad covered")
        }
        if which.contains("m2") {
            let m2 = try await Self.m2Stand(self)
            try await Self.refineAll(m2, "M2 stand")
        }
    }

    static func m2Stand(_ test: XCTestCase) async throws -> FlexibleStageModel {
        let pm = try FlexibleSquishFixture.stlProject("app/TopOptKit/Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, 1))?.face)
        let bottom = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, -1))?.face)
        return try await FlexibleSquishFixture.model(test, pm, "the M2 stand") { m in
            _ = m.press(top, kg: 5)
            m.rest(bottom)
        }
    }

    static func refineAll(_ m: FlexibleStageModel, _ what: String) async throws {
        await m.squishSolver.waitForIdle()   // (the model's own refine cancelled: the probe times one refine at a time)
        let req = try XCTUnwrap(m.lastFERequest)
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let env = ProcessInfo.processInfo.environment
        let modes: [FlexSquishPastData] = env["FLEX_N_PAST"] == "held" ? [.heldAtLastTest]
            : env["FLEX_N_PAST"] == "both" ? [.densifies, .heldAtLastTest] : [.densifies]
        for sim in req.sims {
            guard let lin = m.squish[sim.id]?.field else { print("FLEX-N \(what) \(sim.id): no linear field — \(String(describing: m.squish[sim.id]))"); continue }
            let kBand = lin.scale / (lin.foldShare ?? 1)
            let full = lin.scaled(by: 1 / (lin.foldShare ?? 1))   // the linear field at its uncut calibrated size
            let li = inverted(full, 1)
            let lp = FlexibleFEVerifyGTests.pullback(full, 1)
            print(String(format: "FLEX-N LINEAR %@ %@: k %.3f (asked %.2f, cut %@) · uncut: gmax part %.3f · max|u| %.2f mm · inverted cells %d (min det %.3f) · pull-back misses %d (worst %.2f mm) · solve %.0f ms",
                         what, sim.id, kBand, lin.coreRatio, lin.foldShare.map { String(format: "%.2f", $0) } ?? "none",
                         full.gmaxPart, full.maxDisplacement, li.count, li.minDet, lp.1, lp.2, lin.solveMS))
            for mode in modes {
                let t0 = Date()
                // ★ BATCH N VERIFICATION: how far the field it stopped on is from its fixed point — more
                // undamped solves at the same load (the session continues the converged increment)
                var distance = ""
                let extra = Int(env["FLEX_N_EXTRA"] ?? "") ?? 0
                let o = FlexibleFERefine.run(sim, of: req, on: scene, linear: lin, pastData: mode,
                                             increments: Int(env["FLEX_N_INC"] ?? "") ?? FlexibleFERefine.increments,
                                             inspect: extra <= 0 ? nil : { steps, stop in
                    var changes: [String] = []
                    var lastU = stop.u
                    for _ in 0..<extra {
                        guard let x = try? steps.step(loadFactor: stop.loadFactor, iterations: 1, tolerance: 0), x.ok else { break }
                        changes.append(String(format: "%.4f", x.fixedPointChange))
                        lastU = x.u
                    }
                    var du: Float = 0, big: Float = 0
                    for i in 0..<min(lastU.count, stop.u.count) { du = max(du, abs(lastU[i] - stop.u[i])); big = max(big, abs(lastU[i])) }
                    distance = String(format: " · %d more undamped solves: %@ · the stop is %.2f mm (%.1f%% of max|u|) from them",
                                      changes.count, changes.joined(separator: " "), du, big > 0 ? 100 * du / big : 0)
                })
                let wall = Date().timeIntervalSince(t0)
                let rc: FlexibleFERefine.Receipt
                switch o {
                case .refined(let f):
                    rc = f.refine!
                    let inv = inverted(f, 1)
                    let pb = FlexibleFEVerifyGTests.pullback(f, 1)
                    print(String(format: "FLEX-N STEPPED %@ %@ past %d: REFINED λ %.3f (asked %.2f) · gmax part %.3f · max|u| %.2f mm · inverted %d (min det %.3f) · pull-back misses %d of %d (worst %.2f mm) · %d solves · %.1f s (the refine; %.1f s with the extra solves) · past the data %d of %d (%.0f%%) · grow > 30%% %d (max det %.2f)%@",
                                 what, sim.id, mode.rawValue, f.scale, f.coreRatio, f.gmaxPart, f.maxDisplacement, inv.count, inv.minDet, pb.1, pb.0, pb.2, rc.solves, rc.totalMS / 1000, wall,
                                 rc.beyondData, rc.solid, 100 * Double(rc.beyondData) / Double(max(1, rc.solid)), rc.inflated,
                                 rc.steps.last?.volumeRatioMax ?? 0, distance))
                case .kept(let why, let detail, let receipt):
                    rc = receipt
                    print("FLEX-N STEPPED \(what) \(sim.id) past \(mode.rawValue): KEPT '\(why)' — \(detail) · \(String(format: "%.1f", wall)) s")
                case .cancelled:
                    print("FLEX-N STEPPED \(sim.id): cancelled"); continue
                }
                for (i, s) in rc.steps.enumerated() {
                    print(String(format: "FLEX-N   step %d λ %.3f: %d solves · change %.4f %@ (last ω %.2f) · CG %d · %.0f ms · strain p99 %.3f max %.3f · beyond data %d · by stress %d · grow > 30%% %d%@",
                                 i + 1, s.loadFactor, s.solves, s.change, s.converged ? "✓" : "✗", s.omega, s.cgIterations, s.ms, s.strainP99, s.strainMax, s.beyondData, s.stressUpdates,
                                 s.inflated, s.mgSkipped ? " · Jacobi-CG" : ""))
                }
            }
        }
    }

    static func round5(_ test: XCTestCase) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        test.addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = ProcessInfo.processInfo.environment["FLEX_N_PROBE"] == "1"   // (the probe refines itself)
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        return (r, m)
    }

    func testTheLinearFieldsStrainOnHisRound5Project() async throws {
        guard Self.on else { throw XCTSkip("FLEX_N_PROBE=1") }
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = ProcessInfo.processInfo.environment["FLEX_N_PROBE"] == "1"   // (the probe refines itself)
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        let req = try XCTUnwrap(m.lastFERequest)
        let law = req.law
        print("FLEX-N LAW \(law.materialID) \(law.topology) \(law.tempC) °C shapeOnly \(law.shapeOnly)")
        for rho in [0.1, 0.15, 0.2, 0.25, 0.3, 0.35] {
            var line = String(format: "FLEX-N SECANT ρ %.2f:", rho)
            for eps in [0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5] {
                let e = try FlexibleCore.squishModulus(law: law, rho: rho, strain: eps, skinFrac: 0)
                line += String(format: " ε%.2f %.3f", eps, e)
            }
            print(line)
        }
        let rhos = req.rho.filter { $0 >= 0 }.sorted()
        if !rhos.isEmpty {
            print(String(format: "FLEX-N RHO lattice voxels %d · p10 %.3f p50 %.3f p90 %.3f", rhos.count,
                         rhos[rhos.count / 10], rhos[rhos.count / 2], rhos[rhos.count * 9 / 10]))
        }
        for sim in req.sims {
            guard let f = m.squish[sim.id]?.field else { print("FLEX-N \(sim.id): no field"); continue }
            let k = Float(f.scale / (f.foldShare ?? 1))   // the band's k (uncut)
            let raw = Self.elementGradients(f, divide: Float(f.scale))
            var ec: [Double] = [], rot: [Double] = [], gn: [Double] = []
            var worst = (g: 0.0, e: -1, ec: 0.0, rot: 0.0)
            var inverted = 0
            for (e, g) in raw {
                let sym = 0.5 * (g + g.transpose), skew = 0.5 * (g - g.transpose)
                let l = Self.symEig(sym)
                let c = max(0, -l.x)
                let w = Double(simd_length(SIMD3(skew[1][0], skew[2][0], skew[2][1])))
                let n = Double(FlexibleFEField.spectralNorm(g[0], g[1], g[2]))
                ec.append(c); rot.append(w); gn.append(n)
                if n > worst.g { worst = (n, e, c, w) }
                if simd_determinant(matrix_identity_float3x3 + g * k) <= 0 { inverted += 1 }
            }
            let s = ec.sorted(), sr = rot.sorted(), sg = gn.sorted()
            func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
            let ex = worst.e % (f.nx - 1), ey = (worst.e / (f.nx - 1)) % (f.ny - 1), ez = worst.e / ((f.nx - 1) * (f.ny - 1))
            let pos = f.origin + (SIMD3<Float>(Float(ex), Float(ey), Float(ez)) + 0.5) * f.spacing
            print(String(format: "FLEX-N %@: k %.3f (band k %.3f, asked %.2f, cut %@) · %d elements · RAW principal compressive strain p50 %.3f p90 %.3f p99 %.3f max %.3f · > 0.25: %d · > 0.5: %d · rotation p99 %.3f max %.3f · ‖∇u‖ p99 %.3f max %.3f at (%.1f, %.1f, %.1f) [ε_c %.3f, rot %.3f] · det(I + k∇u) ≤ 0 at the centre: %d",
                         sim.id, f.scale, k, f.coreRatio, f.foldShare.map { String(format: "%.2f", $0) } ?? "none", raw.count,
                         pct(s, 0.5), pct(s, 0.9), pct(s, 0.99), s.last ?? 0, s.filter { $0 > 0.25 }.count, s.filter { $0 > 0.5 }.count,
                         pct(sr, 0.99), sr.last ?? 0, pct(sg, 0.99), sg.last ?? 0, pos.x, pos.y, pos.z, worst.ec, worst.rot, inverted))
        }
    }
}
#endif
