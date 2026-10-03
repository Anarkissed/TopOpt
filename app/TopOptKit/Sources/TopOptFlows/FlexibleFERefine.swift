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
// ★ BATCH N VERIFICATION. (1) Only an UNDAMPED solve may stop an increment (the bridge): his Group 1
// had stopped on a ¼-damped 1.6 % change, 7 % (1.5 mm) short of its fixed point. (2) ONE solve per
// bridge call, so a cancel, a waiting solve and the budget are heard between SOLVES, not only
// between increments (his Group 1's last increment ran 6.5 s with nobody listening). (3) The line
// counts the increment being SOLVED, from the moment the refine claims core, and names the group:
// "Refining Group 2… 3/8" (it had blanked 1.5 s, stalled on 7/8 through the slowest increment, then
// restarted at 1/8 for the next group unnamed).

import Foundation
import TopOptKit

/// ★ BATCH N: a group's refine on the model (FlexibleStageModel.refine).
public enum FlexibleRefineState: Equatable, Sendable {
    /// ★ BATCH N VERIFICATION: `step` — the increment being SOLVED (1-based; set when the refine claims core).
    case running(step: Int, total: Int)
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
    /// ★ BATCH N VERIFICATION: 6 → 10 — only an undamped solve may stop now, and his Group 1's last
    /// increment needs 8 (6 damped, then 2 undamped).
    public static let finalIterations = 10
    /// An increment has converged when its last solve was UNDAMPED and moved the field by ≤ this × its
    /// largest motion (the bridge's rule).
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

    /// The player's note while a group of the sequence refines: the group and the increment being
    /// SOLVED — "Refining Group 2… 3/8". ★ BATCH N VERIFICATION: named (Play all's next group had
    /// restarted at 1/8 unnamed beside the picker's "All · Group 1") and short enough to sit WHOLE beside
    /// the live Play-all picker at 11" portrait (FlexibleBatchNVerifyTests pins the drawn width).
    public static func refining(_ group: String, _ step: Int, of total: Int) -> String { "Refining \(group)… \(step)/\(total)" }
    /// The player's note when the refine did not land and the quick linear squish stays. ★ BATCH N
    /// VERIFICATION: the reason alone, short — "Quick squish · the refine did not settle" was cut to
    /// "Quick squish · the refine did…" beside the live picker at 11" portrait; the (i) keeps the
    /// sentence ("its motion cut to 23 % … (the refine did not settle)").
    public static func kept(_ why: String) -> String {
        switch why {
        case notSettled: return "Refine didn't settle"
        case tooLong: return "Refine took too long"
        default: return "Refine failed"
        }
    }
    /// The short reasons (they stand in the (i)'s cut sentence).
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
        /// ★ BATCH N VERIFICATION: the last solve's damping (1 = undamped: only that may stop), the part's
        /// elements, those whose volume grows > 30 % (a turn drawn as a stretch — the (i) says so) and the
        /// largest volume ratio.
        public var omega: Double = 1
        public var solid: Int = 0
        public var inflated: Int = 0
        public var volumeRatioMax: Double = 0
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
        /// ★ BATCH N VERIFICATION: the field's elements whose volume grows > 30 % under the press — a turn
        /// the small-strain sim draws as a stretch (his Group 1's lifted edge); the (i) says so when any.
        public var inflated: Int { steps.last?.inflated ?? 0 }
        /// The field's elements squeezed past the curves' last tested strain (there the shape is the
        /// textbook densification's), and the part's elements.
        public var beyondData: Int { steps.last?.beyondData ?? 0 }
        public var solid: Int { steps.last?.solid ?? 0 }
    }

    public enum Outcome: Sendable {
        case refined(FlexibleFEField)
        /// Not converged / failed / over budget: the linear field stays (`why`: one short line;
        /// `detail`: core's words or the numbers, behind the (i)).
        case kept(why: String, detail: String, receipt: Receipt)
        /// ★ BATCH N VERIFICATION: with the receipt so far (the tests count the solves after the cancel).
        case cancelled(Receipt)
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
    /// landed linear field (its k and its rests). `between` runs between SOLVES (the yield to a waiting
    /// solve); `progress` reports (the increment being solved, total) at each increment's START;
    /// `cancelled` and the budget are polled between solves.
    /// Test controls: `iterations` (per increment, last), `tolerance`; `pollPerIncrement` — RED control
    /// of the verification: batch N's first loop (one bridge call per increment, nobody listening inside);
    /// `inspect` — the probes' look at a converged session before it ends (its distance to the fixed point);
    /// `band` — the calibration band (the probes' "at his weights" picture: [0.5, 1]).
    public static func run(_ sim: FlexibleFERequest.Sim, of r: FlexibleFERequest, on scene: FlexibleScene,
                           linear: FlexibleFEField, control: Int = 0, pastData: FlexSquishPastData = pastData,
                           increments n: Int = increments, budgetS: Double = budgetS, unsettled: Bool = false,
                           iterations: (each: Int, last: Int)? = nil, tolerance tol: Double = tolerance,
                           pollPerIncrement: Bool = false, inspect: ((FlexSquishSteps, FlexSquishSolutionInfo) -> Void)? = nil,
                           band bandOverride: ClosedRange<Double>? = nil,
                           cancelled: () -> Bool = { false }, between: () -> Void = {},
                           progress: (Int, Int) -> Void = { _, _ in }) -> Outcome {
        let t0 = Date()
        var receipt = Receipt()
        receipt.linearAsked = linear.coreRatio
        receipt.linearK = linear.scale / (linear.foldShare ?? 1)
        receipt.pastData = pastData.rawValue
        let band = r.law.shapeOnly ? nil : Optional(bandOverride ?? FlexibleFE.calibrationBand)
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
        var at = (increment: 0, of: lambdas.count)
        enum End { case failed(String), cancelled, overBudget }
        func overBudget() -> Outcome {
            .kept(why: tooLong, detail: String(format: "%.0f s past the %.0f s budget at increment %d of %d", elapsed(), budgetS,
                                               at.increment, at.of), receipt: receipt)
        }
        /// One increment (or correction) at `lambda`: up to its cap of secant solves, ONE per bridge call
        /// (the session carries the damping across calls at the same λ), a cancel / a waiting solve / the
        /// budget heard between them. nil: it solved (converged or at its cap).
        func doStep(_ lambda: Double, final: Bool) -> End? {
            // (the red control `unsettled`: one solve per increment and a tolerance no field meets)
            let cap = unsettled ? 1 : (final ? (iterations?.last ?? finalIterations) : (iterations?.each ?? iterationsPerIncrement))
            let tolNow = unsettled ? 1e-12 : tol
            var step = Step(loadFactor: lambda, solves: 0, change: 1, converged: false, cgIterations: 0, ms: 0,
                            strainP99: 0, strainMax: 0, beyondData: 0, mgSkipped: false)
            var out: FlexSquishSolutionInfo?
            defer { receipt.steps.append(step) }
            let calls = pollPerIncrement ? 1 : cap
            for k in 0..<calls {
                if k > 0 {
                    // ★ between SOLVES: a new lattice stops the refine here, a waiting solve gets core here
                    if cancelled() { return .cancelled }
                    between()
                    if elapsed() > budgetS { return .overBudget }
                }
                let o: FlexSquishSolutionInfo
                do {
                    o = try steps.step(loadFactor: lambda, iterations: pollPerIncrement ? cap : 1, tolerance: tolNow)
                } catch { return .failed("\(error)") }
                step.solves += o.fixedPointIterations
                step.cgIterations += o.cgIterationsTotal
                step.ms += o.stepMS
                step.change = o.fixedPointChange
                step.converged = o.fixedPointConverged
                step.omega = o.fixedPointOmega
                step.mgSkipped = o.mgSkipped
                step.stressUpdates = o.stressUpdates
                guard o.ok else { return .failed(o.failure) }
                step.strainP99 = o.strainP99
                step.strainMax = o.strainMax
                step.beyondData = o.beyondDataElements
                step.solid = o.solidElements
                step.inflated = o.inflatedElements
                step.volumeRatioMax = o.volumeRatioMax
                out = o
                if o.fixedPointConverged { break }
            }
            guard let out else { return .failed("no solve") }
            last = out
            let f = FlexibleFEField(solution: out, simID: sim.id, generation: r.generation)
            if let z = zoneSums(f, sim.targets) { core = z.core; history.append((lambda, z.fe)) }
            return nil
        }
        func ended(_ e: End) -> Outcome {
            switch e {
            case .failed(let why): return .kept(why: why.contains("deadline") ? tooLong : failedShort, detail: why, receipt: receipt)
            case .cancelled: return .cancelled(receipt)
            case .overBudget: return overBudget()
            }
        }
        for (i, lambda) in lambdas.enumerated() {
            if cancelled() { return .cancelled(receipt) }
            at.increment = i + 1
            // ★ at the START: the line counts the increment being solved (8/8 while the last one runs)
            progress(i + 1, lambdas.count)
            if let e = doStep(lambda, final: i == lambdas.count - 1) { return ended(e) }
            if elapsed() > budgetS { return overBudget() }
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
                if cancelled() { return .cancelled(receipt) }
                if let e = doStep(next, final: true) { return ended(e) }
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
                                        100 * (s?.change ?? 1), s?.solves ?? 0, 100 * tol),
                         receipt: receipt)
        }
        inspect?(steps, out)
        let f = FlexibleFEField.stepped(out, simID: sim.id, generation: r.generation, asked: asked,
                                        uncalibrated: linear.uncalibrated, receipt: receipt)
        var g = f
        g.restsBonded = linear.restsBonded
        return .refined(g)
    }
}
