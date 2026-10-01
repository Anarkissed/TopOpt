// FlexibleFERefine — each squeeze group's squish solved again IN STEPS, so it folds the way the
// material does (task 2026-09-29-flexible-screens, round 5 batch N; maintainer, on batch G's fold
// cut: "Is there no way to fold realistically instead?").
//
// ★ WHAT IT IS. Batch G's sim is linear: every voxel keeps the modulus its COLUMN would have under
// core's 1D squish, so where the 3D field squeezes a zone far past its column (the edge above his
// 10 kg thumb) nothing firms up, and at its calibrated size the field folds — so batch G cut it
// (to 23 % on his Group 1). Here the load is applied in INCREMENTS (8) up to the calibrated load;
// within each, damped secant iterations give every voxel the modulus the tested curve gives at ITS
// OWN principal compressive strain (FlexibleKit+SquishSteps, flexible_squish_fe.cpp) — each a
// core MG-CG solve warm-started from the last. The calibration is then RE-DECIDED on the stepped
// field (the load factor whose deepest zone compresses core's depth, inside the band [0.5, 2]).
// ★ WHAT IT IS NOT: no buckling, no snap-through, no self-contact, no large rotations (small
// strain — core brief). Past the curves' last tested strain (0.25) the tested data says nothing;
// the law densifies there (Gibson & Ashby), a textbook law said in the (i).
// ★ WHEN. After the quick linear sims of a lattice have landed (they show first); one group at a
// time, the shown group first; a new lattice cancels it between increments; it yields core to a
// solve that waits for it between increments (FlexibleCoreGate). A refine that does not converge,
// fails or runs past its budget keeps the linear field (with the fold cut) and says why in one line.

import Foundation
import TopOptKit

/// ★ BATCH N: a group's refine on the model (FlexibleStageModel.refine).
public enum FlexibleRefineState: Equatable, Sendable {
    case running(done: Int, total: Int)
    case ready(FlexibleFEField)
    /// The quick field stays: one short line, and the detail behind the (i).
    case kept(why: String, detail: String)

    public var field: FlexibleFEField? { if case .ready(let f) = self { return f }; return nil }
}

public enum FlexibleFERefine {
    /// Load increments to the calibrated load (the progress line counts them).
    public static let increments = 8
    /// Secant solves per increment (the last increment, and each correction, get `finalIterations`).
    public static let iterationsPerIncrement = 3
    public static let finalIterations = 6
    /// An increment has converged when the last solve moved the field by ≤ this × its largest motion.
    public static let tolerance = 0.02
    /// The calibration is re-decided until the deepest zone compresses core's depth within this.
    public static let calibrationTolerance = 0.03
    /// …by at most this many extra steps.
    public static let correctionSteps = 2
    /// The whole refine's wall-clock budget (past it the linear field stays).
    public static let budgetS = 120.0
    /// The versions' key suffix (FlexibleFEField.versionKey).
    public static let versionSuffix = "·stepped"
    /// The law past the tested data (the red control holds the curve at its last tested secant).
    public static let pastData: FlexSquishPastData = .densifies

    // MARK: copy (one line each)

    /// The player's note while the shown group refines.
    public static func refining(_ done: Int, of total: Int) -> String { "Refining the squish… \(done)/\(total)" }
    /// The player's note when the refine failed and the quick linear squish stays (≤ 44 characters —
    /// FlexibleRowCopy.maxChars; the reason also stands in the (i)'s cut sentence).
    public static func kept(_ why: String) -> String { "Quick squish · \(why)" }
    /// The short reasons (one line each).
    public static let notSettled = "the refine did not settle"
    public static let tooLong = "the refine took too long"
    public static let failedShort = "the refine failed"

    /// One increment's receipt.
    public struct Step: Sendable, Equatable {
        public var loadFactor: Double
        public var solves: Int
        public var change: Double
        public var converged: Bool
        public var cgIterations: Int
        public var ms: Double
        public var strainP99: Double
        public var strainMax: Double
        public var beyondData: Int
        public var mgSkipped: Bool
        /// Elements updated by their stress (the curve stiffening there) in the last iterate.
        public var stressUpdates: Int = 0
    }

    /// The whole refine's receipt (the handoff's numbers).
    public struct Receipt: Sendable, Equatable {
        public var steps: [Step] = []
        /// The last increment (and correction) converged.
        public var converged = false
        /// The load factor the stepped field's deepest zone asked for (before the band) and the one used.
        public var asked = 1.0
        public var loadFactor = 1.0
        /// The linear sim's k: asked, and as the band held it.
        public var linearAsked = 1.0
        public var linearK = 1.0
        public var totalMS = 0.0
        public var pastData: Int32 = FlexibleFERefine.pastData.rawValue
        public var solves: Int { steps.reduce(0) { $0 + $1.solves } }
    }

    public enum Outcome: Sendable {
        case refined(FlexibleFEField)
        /// Not converged / failed / over budget: the linear field stays (`why`: one short line;
        /// `detail`: core's words or the numbers, behind the (i)).
        case kept(why: String, detail: String, receipt: Receipt)
        case cancelled
    }

    /// The load factors of the increments up to `target`.
    public static func schedule(target: Double, increments n: Int = increments) -> [Double] {
        (1...max(1, n)).map { target * Double($0) / Double(max(1, n)) }
    }

    /// The load factor whose deepest zone compresses core's depth, from the last two increments
    /// (the compression ∝ λ^p locally): λ* = λ_n · r_n^(1/p), r = core / sim.
    static func nextLoadFactor(_ a: (lambda: Double, fe: Double), _ b: (lambda: Double, fe: Double), core: Double) -> Double {
        guard b.fe > 1e-12, core > 0 else { return b.lambda }
        let r = core / b.fe
        var p = 1.0
        if a.fe > 1e-12, a.lambda > 0, abs(b.lambda - a.lambda) > 1e-9 {
            p = log(b.fe / a.fe) / log(b.lambda / a.lambda)
            if !p.isFinite || p < 0.2 { p = 0.2 }
            if p > 5 { p = 5 }
        }
        return b.lambda * pow(r, 1 / p)
    }

    /// Σ core depth and Σ sim compression over the deepest zone (FlexibleFEField.calibration's sums).
    static func zoneSums(_ f: FlexibleFEField, _ targets: [FlexibleFEField.Target]) -> (core: Double, fe: Double)? {
        let deepest = targets.flatMap { $0.depthsMM.compactMap { $0 } }.max() ?? 0
        guard deepest > 0 else { return nil }
        var core = 0.0, fe = 0.0
        for t in targets {
            for (c, d) in t.depthsMM.enumerated() {
                guard let d, d >= FlexibleFE.deepZone * deepest, c < t.stack.columns.count else { continue }
                core += d
                fe += f.columnCompression(stack: t.stack, col: c, pinched: c < t.pinched.count && t.pinched[c])
            }
        }
        return (core, fe)
    }

    /// Refine `sim` (seconds — on the sims' serial queue, never the main thread). `linear`: its
    /// landed linear field (its k and its rests). `between` runs after each increment (the yield to
    /// a waiting solve); `progress` reports (done, total) increments; `cancelled` is polled between
    /// increments.
    public static func run(_ sim: FlexibleFERequest.Sim, of r: FlexibleFERequest, on scene: FlexibleScene,
                           linear: FlexibleFEField, control: Int = 0, pastData: FlexSquishPastData = pastData,
                           increments n: Int = increments, budgetS: Double = budgetS, unsettled: Bool = false,
                           cancelled: () -> Bool = { false }, between: () -> Void = {},
                           progress: (Int, Int) -> Void = { _, _ in }) -> Outcome {
        let t0 = Date()
        var receipt = Receipt()
        receipt.linearAsked = linear.coreRatio
        receipt.linearK = linear.scale / (linear.foldShare ?? 1)
        receipt.pastData = pastData.rawValue
        let band = r.law.shapeOnly ? nil : Optional(FlexibleFE.calibrationBand)
        func clampBand(_ x: Double) -> Double { band.map { Swift.min($0.upperBound, Swift.max($0.lowerBound, x)) } ?? x }
        func elapsed() -> Double { Date().timeIntervalSince(t0) }
        // the same rests as the linear field that landed (its one bonded retry carried over)
        let bits = control | (linear.restsBonded ? FlexibleFE.bondedRests : 0)
        let steps: FlexSquishSteps
        do {
            steps = try scene.squishSteps(r.request(sim, control: bits), pastData: pastData)
        } catch {
            return .kept(why: failedShort, detail: "\(error)", receipt: receipt)
        }
        defer { steps.end() }
        guard steps.setup.ok else { return .kept(why: failedShort, detail: steps.setup.failure, receipt: receipt) }
        let target = linear.uncalibrated ? 1 : clampBand(linear.coreRatio)
        let lambdas = schedule(target: target, increments: n)
        var last: FlexSquishSolutionInfo?
        var history: [(lambda: Double, fe: Double)] = []
        var core = 0.0
        func doStep(_ lambda: Double, final: Bool) -> String? {
            let out: FlexSquishSolutionInfo
            do {
                // (the red control `unsettled`: one solve per increment and a tolerance no field meets)
                out = try steps.step(loadFactor: lambda, iterations: unsettled ? 1 : (final ? finalIterations : iterationsPerIncrement),
                                     tolerance: unsettled ? 1e-12 : tolerance)
            } catch { return "\(error)" }
            receipt.steps.append(Step(loadFactor: lambda, solves: out.fixedPointIterations, change: out.fixedPointChange,
                                      converged: out.fixedPointConverged, cgIterations: out.cgIterationsTotal, ms: out.stepMS,
                                      strainP99: out.strainP99, strainMax: out.strainMax, beyondData: out.beyondDataElements,
                                      mgSkipped: out.mgSkipped, stressUpdates: out.stressUpdates))
            guard out.ok else { return out.failure }
            last = out
            let f = FlexibleFEField(solution: out, simID: sim.id, generation: r.generation)
            if let z = zoneSums(f, sim.targets) { core = z.core; history.append((lambda, z.fe)) }
            return nil
        }
        for (i, lambda) in lambdas.enumerated() {
            if cancelled() { return .cancelled }
            if let why = doStep(lambda, final: i == lambdas.count - 1) {
                return .kept(why: why.contains("deadline") ? tooLong : failedShort, detail: why, receipt: receipt)
            }
            progress(i + 1, lambdas.count)
            if elapsed() > budgetS {
                return .kept(why: tooLong, detail: String(format: "%.0f s past the %.0f s budget at increment %d of %d", elapsed(), budgetS, i + 1, lambdas.count), receipt: receipt)
            }
            between()
        }
        // ★ THE CALIBRATION, RE-DECIDED on the stepped field: the load factor whose deepest zone
        // compresses core's depth (∝ λ^p from the last two increments), inside the band
        var asked = target
        if !linear.uncalibrated, history.count >= 2, core > 0 {
            for _ in 0..<correctionSteps {
                let a = history[history.count - 2], b = history[history.count - 1]
                asked = nextLoadFactor(a, b, core: core)
                let next = clampBand(asked)
                if abs(next / b.lambda - 1) <= calibrationTolerance { break }
                if cancelled() { return .cancelled }
                if let why = doStep(next, final: true) {
                    return .kept(why: why.contains("deadline") ? tooLong : failedShort, detail: why, receipt: receipt)
                }
                between()
            }
            if let b = history.last, b.fe > 1e-12 {
                // the asked factor at the field kept (one more estimate from the last two points)
                asked = history.count >= 2 ? nextLoadFactor(history[history.count - 2], b, core: core) : asked
            }
        }
        receipt.totalMS = elapsed() * 1000
        guard let out = last else { return .kept(why: failedShort, detail: "no step solved", receipt: receipt) }
        receipt.converged = receipt.steps.last?.converged ?? false
        receipt.asked = asked
        receipt.loadFactor = out.loadFactor
        guard receipt.converged else {
            let s = receipt.steps.last
            return .kept(why: notSettled,
                         detail: String(format: "the last increment moved %.1f%% after %d solves (tolerance %.0f%%)",
                                        100 * (s?.change ?? 1), s?.solves ?? 0, 100 * tolerance),
                         receipt: receipt)
        }
        let f = FlexibleFEField.stepped(out, simID: sim.id, generation: r.generation, asked: asked,
                                        uncalibrated: linear.uncalibrated, receipt: receipt)
        var g = f
        g.restsBonded = linear.restsBonded
        return .refined(g)
    }
}
