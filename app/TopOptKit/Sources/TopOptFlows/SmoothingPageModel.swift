// SmoothingPageModel.swift — THE RECEIPT IS THE PRODUCT (handoff
// 2026-08-02-smoothing-page).
//
// PR 200's own conclusion was that "cranking smooth_factor alone would buy most of
// the cosmetic win with none of the honesty". So the differentiated thing on this
// page is not the melt. It is:
//
//   * BOTH SIDES MEASURED (bar AE2). The before-column is not the optimizer's
//     remembered number for this variant — it is a fresh `analyze_fixed_design`
//     certification of the UNSMOOTHED variant mesh, run through the same seam the
//     after-column uses. A remembered margin and a measured one are not
//     comparable: they can differ for reasons that have nothing to do with
//     smoothing (the run's own mesh vs its re-voxelization, H3). Comparing a
//     measured number with a remembered one would attribute that whole gap to the
//     brush.
//
//   * NON-CONVERGENCE IS A STATE, NOT A CRASH (bar AE5 / hazard H1). PR 200
//     measured variant_030 at strength 0.50 failing the production multigrid-CG,
//     deterministically. On a BRUSH workflow the user re-certifies over and over,
//     so this happens MORE, not less. When it happens the page says so, and the
//     previous certification stays on screen MARKED STALE — never presented as
//     current, never replaced by a fabricated number.
//
//   * MIN-FEATURE IS REPORTED BOTH WAYS (hazard H2). PR 200 measured min-feature
//     violations FALLING on real tendrilly variants (961 → 639) because smoothing
//     removes terracing that counted as sub-printable. Nothing here presumes
//     smoothing is a cost; the copy is derived from the sign of the change.
//
//   * THE ANALYZED OBJECT IS NAMED (hazard H3). What was certified is the
//     RE-VOXELIZATION of the smoothed mesh, and the mesh is the deliverable. Both
//     volume fractions are on the receipt so the size of that gap is visible.
//
// Pure value types for every derived surface; a small @MainActor observable holds
// only the phase. The runner is injected, so the whole state machine — including
// the H1 branch — is driven headlessly in tests.

import Foundation
import simd
import TopOptKit

// MARK: - one certification reading

/// ONE run of the certification engine over ONE geometry.
///
/// There is deliberately NO way to build this from an `OptimizeVariant`, a stored
/// outcome, or any other remembered number: the only initialiser takes an analyze
/// result. That is bar AE2 expressed in the type system — a "before" column can
/// only be filled by actually measuring.
public struct SmoothCertification: Equatable, Sendable {

    /// Which geometry this reading describes.
    public enum Subject: String, Equatable, Sendable {
        /// The variant exactly as the run produced it (the BEFORE column).
        case originalVariant
        /// The brushed mesh (the AFTER column).
        case smoothedVariant
    }

    public let subject: Subject
    public let accepted: Bool
    /// The certification solve did not converge — EVERY number below is
    /// meaningless. Never shown as a verdict.
    public let nonConvergent: Bool
    public let marginWorstCase: Double
    public let marginInPlane: Double
    public let marginInterlayer: Double
    public let marginEffective: Double
    public let marginRequired: Double
    public let maxStressMPa: Double
    public let minFeatureViolations: Int
    public let voxelMassGrams: Double
    public let meshMassGrams: Double
    public let spacingMM: Double
    /// H3 — the two volume fractions against the same grid volume: what the mesh
    /// encloses, and what the certification actually solved on.
    public let meshVolumeFraction: Double
    public let voxelVolumeFraction: Double
    /// The mesh file this reading was measured on. Two readings with the same path
    /// describe the same geometry — the page asserts they differ.
    public let meshPath: String

    public init(subject: Subject, _ r: TopOptKit.MeshCertification) {
        self.subject = subject
        accepted = r.accepted
        nonConvergent = r.nonConvergent
        marginWorstCase = r.marginWorstCase
        marginInPlane = r.marginInPlane
        marginInterlayer = r.marginInterlayer
        marginEffective = r.marginEffective
        marginRequired = r.marginRequired
        maxStressMPa = r.maxStressMPa
        minFeatureViolations = r.minFeatureViolations
        voxelMassGrams = r.voxelMassGrams
        meshMassGrams = r.meshMassGrams
        spacingMM = r.spacingMM
        meshVolumeFraction = r.meshVolumeFraction
        voxelVolumeFraction = r.voxelVolumeFraction
        meshPath = r.meshPath
    }

    /// H3, stated: the certified object is not the mesh. The gap is a number.
    public var quantizationGapPercent: Double {
        guard meshVolumeFraction > 0 else { return 0 }
        return (voxelVolumeFraction - meshVolumeFraction) / meshVolumeFraction * 100
    }
}

// MARK: - the receipt (before | after, side by side)

/// The paired reading the page shows. BOTH sides are `SmoothCertification`s, so
/// neither can be a remembered number.
public struct SmoothReceipt: Equatable, Sendable {
    public let before: SmoothCertification
    public let after: SmoothCertification
    /// The smoothing that produced `after` — the brush's own receipt.
    public let smoothing: SmoothingApplied
    /// Set when this receipt describes a smoothing that is no longer the one on
    /// screen (H1: a later re-certification failed, so the last good numbers are
    /// kept but marked). A stale receipt is NEVER offered as a current verdict.
    public let stale: Bool

    public init(before: SmoothCertification, after: SmoothCertification,
                smoothing: SmoothingApplied, stale: Bool = false) {
        self.before = before
        self.after = after
        self.smoothing = smoothing
        self.stale = stale
    }

    public func markedStale() -> SmoothReceipt {
        SmoothReceipt(before: before, after: after, smoothing: smoothing, stale: true)
    }

    // ── the derived comparison rows ──────────────────────────────────────────

    public struct Row: Equatable, Sendable {
        public let label: String
        public let beforeText: String
        public let afterText: String
        /// Whether the after-value is worse than the before-value. `nil` where
        /// "worse" is not defined (mass, stress on a part with no requirement).
        public let worse: Bool?
        /// Whether the after-value is BETTER — H2's other direction, which the UI
        /// must be able to show without contortion.
        public let better: Bool?
    }

    private static func f(_ x: Double, _ d: Int = 2) -> String {
        String(format: "%.\(d)f", x)
    }

    /// The side-by-side table. Everything the task's item 5 names: worst-case
    /// margin, in-plane, interlayer, effective, min-feature count, mass, verdict.
    public var rows: [Row] {
        func cmp(_ b: Double, _ a: Double, lowerIsWorse: Bool) -> (Bool?, Bool?) {
            if a == b { return (false, false) }
            let dropped = a < b
            return lowerIsWorse ? (dropped, !dropped) : (!dropped, dropped)
        }
        var out: [Row] = []
        func margin(_ label: String, _ b: Double, _ a: Double) {
            let (w, bt) = cmp(b, a, lowerIsWorse: true)
            out.append(Row(label: label, beforeText: Self.f(b), afterText: Self.f(a),
                           worse: w, better: bt))
        }
        margin("Worst-case margin", before.marginWorstCase, after.marginWorstCase)
        margin("In-plane", before.marginInPlane, after.marginInPlane)
        margin("Interlayer", before.marginInterlayer, after.marginInterlayer)
        margin("Effective (at the gate)", before.marginEffective, after.marginEffective)

        // H2 — min-feature both ways. FEWER violations is BETTER, and smoothing
        // genuinely produces that on tendrilly variants by removing terracing.
        let (mfWorse, mfBetter) = cmp(Double(before.minFeatureViolations),
                                      Double(after.minFeatureViolations),
                                      lowerIsWorse: false)
        out.append(Row(label: "Min-feature violations",
                       beforeText: "\(before.minFeatureViolations)",
                       afterText: "\(after.minFeatureViolations)",
                       worse: mfWorse, better: mfBetter))
        out.append(Row(label: "Mass (voxel)",
                       beforeText: Self.f(before.voxelMassGrams, 1) + " g",
                       afterText: Self.f(after.voxelMassGrams, 1) + " g",
                       worse: nil, better: nil))
        out.append(Row(label: "Mass (mesh)",
                       beforeText: Self.f(before.meshMassGrams, 1) + " g",
                       afterText: Self.f(after.meshMassGrams, 1) + " g",
                       worse: nil, better: nil))
        out.append(Row(label: "Peak stress",
                       beforeText: Self.f(before.maxStressMPa) + " MPa",
                       afterText: Self.f(after.maxStressMPa) + " MPa",
                       worse: after.maxStressMPa > before.maxStressMPa,
                       better: after.maxStressMPa < before.maxStressMPa))
        out.append(Row(label: "Verdict",
                       beforeText: before.accepted ? "ACCEPTED" : "REJECTED",
                       afterText: after.accepted ? "ACCEPTED" : "REJECTED",
                       worse: before.accepted && !after.accepted,
                       better: !before.accepted && after.accepted))
        return out
    }

    /// Did smoothing move the verdict, and which way? The S3 question, answered on
    /// the page rather than in a handoff.
    public enum VerdictChange: Equatable, Sendable {
        case heldAccepted, heldRejected, dropped, recovered
    }
    public var verdictChange: VerdictChange {
        switch (before.accepted, after.accepted) {
        case (true, true): return .heldAccepted
        case (false, false): return .heldRejected
        case (true, false): return .dropped
        case (false, true): return .recovered
        }
    }

    /// The headline. Leads with the verdict change, then the size of the move.
    public var headline: String {
        let d = after.marginWorstCase - before.marginWorstCase
        let move = String(format: "%+.2f", d)
        switch verdictChange {
        case .dropped:
            return "Smoothing dropped this below the gate — margin \(move) to "
                 + Self.f(after.marginWorstCase) + ", under the required "
                 + Self.f(after.marginRequired) + "."
        case .heldAccepted:
            return d < 0
                ? "Still holds — margin \(move) to " + Self.f(after.marginWorstCase)
                    + ", above the required " + Self.f(after.marginRequired) + "."
                : "Still holds — margin \(move) to " + Self.f(after.marginWorstCase) + "."
        case .heldRejected:
            return "Still below the gate — margin \(move) to "
                 + Self.f(after.marginWorstCase) + "."
        case .recovered:
            return "Now above the gate — margin \(move) to "
                 + Self.f(after.marginWorstCase) + "."
        }
    }

    /// H2's line, phrased from the measured direction rather than an assumption.
    public var minFeatureLine: String {
        let b = before.minFeatureViolations, a = after.minFeatureViolations
        if a == b { return "Min-feature violations unchanged at \(a)." }
        if a < b {
            return "Min-feature violations FELL \(b) → \(a): smoothing removed "
                 + "terracing that counted as sub-printable."
        }
        return "Min-feature violations ROSE \(b) → \(a): smoothing thinned "
             + "something below the printable floor."
    }

    /// H3's line: what was certified is not what will be printed, and by how much.
    public var quantizationLine: String {
        String(format:
            "Certified on the RE-VOXELIZATION of the smoothed mesh at %.2f mm: "
            + "voxel volume fraction %.4f vs the mesh's own %.4f (%+.1f%%). The "
            + "mesh is what you export; the margin describes that voxel proxy.",
            after.spacingMM, after.voxelVolumeFraction, after.meshVolumeFraction,
            after.quantizationGapPercent)
    }
}

/// The smoothing that produced an "after" reading — the brush's own receipt.
public struct SmoothingApplied: Equatable, Sendable {
    public let maxStrength: Double
    public let pairsRequested: Int
    public let pairsApplied: Int
    public let totalVertices: Int
    public let frozenVertices: Int
    public let brushedVertices: Int
    public let unbrushedVertices: Int
    public let volumeDriftFraction: Double
    public let volumeDriftBound: Double
    public let minFeatureLimited: Bool
    /// Per-region "Region A · 0.40 · 812 tris" lines, so the strength that
    /// produced this receipt is inspectable after the fact.
    public let regionLines: [String]

    public init(maxStrength: Double, pairsRequested: Int, pairsApplied: Int,
                totalVertices: Int, frozenVertices: Int, brushedVertices: Int,
                unbrushedVertices: Int, volumeDriftFraction: Double,
                volumeDriftBound: Double, minFeatureLimited: Bool,
                regionLines: [String]) {
        self.maxStrength = maxStrength
        self.pairsRequested = pairsRequested
        self.pairsApplied = pairsApplied
        self.totalVertices = totalVertices
        self.frozenVertices = frozenVertices
        self.brushedVertices = brushedVertices
        self.unbrushedVertices = unbrushedVertices
        self.volumeDriftFraction = volumeDriftFraction
        self.volumeDriftBound = volumeDriftBound
        self.minFeatureLimited = minFeatureLimited
        self.regionLines = regionLines
    }

    /// The frozen line — the hard constraint, stated as a count rather than a
    /// promise.
    public var frozenLine: String {
        "\(frozenVertices) of \(totalVertices) vertices are FROZEN (bolt bores, "
        + "mating faces, anchors, load faces, Protect groups) — held bit-identical, "
        + "not damped. \(brushedVertices) brushed, \(unbrushedVertices) left untouched."
    }

    public var driftLine: String {
        let pct = { (x: Double) in String(format: "%.2f%%", x * 100) }
        let base = "Volume drift \(pct(volumeDriftFraction)) "
                 + "(Taubin bound over the brushed range \(pct(volumeDriftBound)))"
        return volumeDriftFraction > volumeDriftBound
            ? base + " — beyond the denoising bound: real material was removed."
            : base + "."
    }

    public var cappedLine: String? {
        guard minFeatureLimited else { return nil }
        return "Stopped at \(pairsApplied) of \(pairsRequested) passes: the next "
             + "one would have thinned something below the printable floor. The "
             + "min-feature constraint is a wall, not a warning."
    }
}

// MARK: - the H1 failure, as a legible state

/// Why a re-certification produced no verdict. Distinct from an honest REJECTED,
/// which is a verdict.
public struct SmoothCertifyFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The production multigrid-CG hit its iteration cap on this re-voxelized
        /// field (H1). Deterministic and field-specific: a different strength
        /// usually resolves.
        case didNotConverge
        /// The UNSMOOTHED variant itself could not be certified. A different
        /// failure entirely: smoothing is not the cause and a lower strength
        /// cannot help, so the page must not suggest one.
        case baselineDidNotConverge
        /// The smoother or the importer refused outright.
        case refused(String)
    }
    public let kind: Kind
    /// The brush strength in play when it happened.
    public let maxStrength: Double

    public var title: String {
        switch kind {
        case .didNotConverge: return "Couldn’t certify this smoothing"
        case .baselineDidNotConverge:
            return "Couldn’t certify this variant at all"
        case .refused: return "Smoothing failed"
        }
    }

    public var detail: String {
        switch kind {
        case .didNotConverge:
            return String(format:
                "The certification solve did not reach tolerance on the "
                + "re-voxelized shape at strength %.2f. That is a solver limit on "
                + "this particular sparse field, not a verdict — there is no "
                + "trustworthy margin to show, so none is shown. Try a lower "
                + "strength, or a smaller brushed area.", maxStrength)
        case .baselineDidNotConverge:
            return "The certification solve did not reach tolerance on the "
                 + "UNSMOOTHED variant. Smoothing is not the cause, and there is "
                 + "nothing to compare a smoothed shape against — so no receipt "
                 + "can be produced for this variant at this resolution."
        case .refused(let m):
            return m
        }
    }

    /// What the page offers to do about it.
    public var suggestion: String {
        switch kind {
        case .didNotConverge: return "Lower the strength and re-certify"
        case .baselineDidNotConverge:
            return "Re-run this variant at a different resolution"
        case .refused: return "Adjust the brush and try again"
        }
    }
}

// MARK: - the page state machine

@MainActor
public final class SmoothingPageModel: ObservableObject {

    public enum Phase: Equatable {
        /// Nothing measured yet.
        case idle
        /// Measuring the UNSMOOTHED variant — the before column (AE2).
        case measuringBefore
        /// Smoothing and re-certifying.
        case certifying
        /// Both columns fresh.
        case certified(SmoothReceipt)
        /// H1 / AE5. `stale` is the last GOOD receipt, marked, or nil if there
        /// never was one.
        case couldNotCertify(SmoothCertifyFailure, stale: SmoothReceipt?)
    }

    /// What one certification call needs. A value type, so it crosses the
    /// background-executor boundary and so a test can inspect exactly what was
    /// asked for.
    public struct CertifyRequest: Equatable, Sendable {
        public let subject: SmoothCertification.Subject
        /// The mesh to certify FROM: the variant exactly as the run produced it,
        /// in both cases. The baseline certifies it directly; the smoothed pass
        /// smooths it and certifies the result, so the two readings differ by the
        /// brush and by NOTHING else.
        public let inputMeshPath: String
        /// Where the smoothed mesh is written. Empty for the baseline.
        public let outputMeshPath: String
        /// The brush weights, empty for the baseline.
        public let weights: [Double]
        public let strength: Double
        public let loadCase: SmoothRecertLoadCase
        /// The part the load case's face ids are defined on.
        public let modelPath: String

        public init(subject: SmoothCertification.Subject, inputMeshPath: String,
                    outputMeshPath: String, weights: [Double], strength: Double,
                    loadCase: SmoothRecertLoadCase, modelPath: String) {
            self.subject = subject
            self.inputMeshPath = inputMeshPath
            self.outputMeshPath = outputMeshPath
            self.weights = weights
            self.strength = strength
            self.loadCase = loadCase
            self.modelPath = modelPath
        }
    }

    /// What one certification call returns: the reading, plus (for the smoothed
    /// subject) the smoothing receipt and the geometry that was measured.
    public struct CertifyOutcome: Equatable, Sendable {
        public let certification: SmoothCertification
        public let smoothing: SmoothingApplied?
        public let meshVertices: [Float]
        public let meshIndices: [Int32]

        public init(certification: SmoothCertification,
                    smoothing: SmoothingApplied?,
                    meshVertices: [Float] = [], meshIndices: [Int32] = []) {
            self.certification = certification
            self.smoothing = smoothing
            self.meshVertices = meshVertices
            self.meshIndices = meshIndices
        }
    }

    public typealias Runner =
        @Sendable (_ request: CertifyRequest) async throws -> CertifyOutcome

    @Published public private(set) var phase: Phase = .idle
    /// The kept-or-not decision. Non-nil once the user keeps a smoothing.
    @Published public private(set) var kept: SmoothKeptResult?
    /// Which side of the before/after the viewport is showing.
    @Published public var showingSmoothed = true

    public let context: SmoothVariantContext
    /// Where the variant's own mesh was written for the certification engine to
    /// read, and where a smoothed mesh goes.
    public let variantMeshPath: String
    public let smoothedMeshPath: String
    private let runner: Runner
    /// The BEFORE reading, measured once per page session. Cached because the
    /// original variant does not change while the page is open — but it is
    /// MEASURED, never remembered from the run.
    private var beforeReading: SmoothCertification?
    /// The geometry of the most recent SUCCESSFUL smoothed certification.
    private var lastSmoothedOutcome: CertifyOutcome?
    /// How many times the certification engine has been called this session. The
    /// AE2 test reads it: a "before" that was remembered rather than measured
    /// would leave this at 1 after the first re-certify.
    public private(set) var certifyCallCount = 0

    public init(context: SmoothVariantContext, variantMeshPath: String = "",
                smoothedMeshPath: String = "", runner: @escaping Runner) {
        self.context = context
        self.variantMeshPath = variantMeshPath
        self.smoothedMeshPath = smoothedMeshPath
        self.runner = runner
    }

    // ── derived surfaces ────────────────────────────────────────────────────

    /// The receipt to render as CURRENT. Nil in every state where there is no
    /// trustworthy current verdict — there is no other numeric surface on this
    /// model, so a stale number cannot leak into the current column.
    public var receipt: SmoothReceipt? {
        if case .certified(let r) = phase, !r.stale { return r }
        return nil
    }

    /// The last good receipt when the current one could not be produced (H1). It
    /// is returned already MARKED, so a view cannot render it as current by
    /// forgetting to check a flag.
    public var staleReceipt: SmoothReceipt? {
        if case .couldNotCertify(_, let s) = phase { return s?.markedStale() }
        return nil
    }

    public var failure: SmoothCertifyFailure? {
        if case .couldNotCertify(let f, _) = phase { return f }
        return nil
    }

    public var isWorking: Bool {
        switch phase {
        case .measuringBefore, .certifying: return true
        default: return false
        }
    }

    /// The one-line status the page always shows.
    public var statusLine: String {
        switch phase {
        case .idle:
            return "Brush the areas that need smoothing, then re-certify."
        case .measuringBefore:
            return "Measuring the unsmoothed variant — the before column is a real "
                 + "certification, not the run's remembered number."
        case .certifying:
            return "Smoothing and re-certifying…"
        case .certified(let r):
            return r.headline
        case .couldNotCertify(let f, let s):
            return s == nil ? f.title
                            : f.title + " — the numbers below are the PREVIOUS "
                              + "certification and are out of date."
        }
    }

    // ── the one action (item 5: re-certify ON DEMAND, not per stroke) ────────

    /// Re-certify the current brush. Measures the BEFORE column first if it has
    /// not been measured this session, then the AFTER column. Both through the
    /// same runner — bar AE2.
    ///
    /// On an H1 failure the phase becomes `.couldNotCertify` carrying the last
    /// good receipt so the page can show it MARKED STALE. `kept` is untouched: a
    /// failed re-certification never disturbs a smoothing the user already kept.
    public func recertify(brush: SmoothBrushModel) async {
        guard let lc = context.loadCase else { return }
        let lastGood = receipt
        let strength = brush.maxStrength
        let weights = brush.normalizedWeights()

        do {
            if beforeReading == nil {
                phase = .measuringBefore
                certifyCallCount += 1
                let out = try await runner(CertifyRequest(
                    subject: .originalVariant, inputMeshPath: variantMeshPath,
                    outputMeshPath: "", weights: [], strength: 0, loadCase: lc,
                    modelPath: context.modelPath))
                if out.certification.nonConvergent {
                    phase = .couldNotCertify(
                        SmoothCertifyFailure(kind: .baselineDidNotConverge,
                                             maxStrength: 0),
                        stale: lastGood)
                    return
                }
                beforeReading = out.certification
            }
            guard let before = beforeReading else { return }

            phase = .certifying
            certifyCallCount += 1
            let out = try await runner(CertifyRequest(
                subject: .smoothedVariant, inputMeshPath: variantMeshPath,
                outputMeshPath: smoothedMeshPath, weights: weights,
                strength: strength, loadCase: lc, modelPath: context.modelPath))
            if out.certification.nonConvergent {
                phase = .couldNotCertify(
                    SmoothCertifyFailure(kind: .didNotConverge,
                                         maxStrength: strength),
                    stale: lastGood)
                return
            }
            let applied = out.smoothing ?? SmoothingApplied(
                maxStrength: strength, pairsRequested: 0, pairsApplied: 0,
                totalVertices: 0, frozenVertices: 0, brushedVertices: 0,
                unbrushedVertices: 0, volumeDriftFraction: 0, volumeDriftBound: 0,
                minFeatureLimited: false, regionLines: [])
            phase = .certified(SmoothReceipt(before: before,
                                             after: out.certification,
                                             smoothing: applied))
            lastSmoothedOutcome = out
        } catch {
            let message = (error as? TopOptError)?.message ?? "\(error)"
            phase = .couldNotCertify(
                SmoothCertifyFailure(kind: .refused(message), maxStrength: strength),
                stale: lastGood)
        }
    }

    // ── keep / discard (bar AE9) ────────────────────────────────────────────

    /// KEEP the smoothing: the smoothed geometry and the receipt that certified
    /// it travel onward together. Refused unless there is a CURRENT (non-stale)
    /// receipt — a smoothing whose verdict could not be produced is never keepable.
    @discardableResult
    public func keep(regionLines: [String]) -> Bool {
        guard let r = receipt, let out = lastSmoothedOutcome,
              !out.meshVertices.isEmpty else { return false }
        kept = SmoothKeptResult(meshVertices: out.meshVertices,
                                meshIndices: out.meshIndices,
                                meshPath: r.after.meshPath,
                                certification: r.after,
                                regionSummary: regionLines)
        return true
    }

    /// DISCARD (bar AE9): every trace of the smoothing goes, and the ORIGINAL
    /// variant is what the page and everything downstream sees. The original is
    /// never mutated in the first place — it is the immutable `context` — so this
    /// is a state reset, not an inverse operation that could drift.
    public func discard() {
        kept = nil
        lastSmoothedOutcome = nil
        phase = .idle
        showingSmoothed = false
    }

    /// The geometry the viewport draws and everything downstream consumes.
    /// Bit-identically the original whenever nothing is kept.
    public var currentGeometry: (vertices: [Float], indices: [Int32], smoothed: Bool) {
        if let k = kept, showingSmoothed {
            return (k.meshVertices, k.meshIndices, true)
        }
        if kept == nil, showingSmoothed, let out = lastSmoothedOutcome,
           !out.meshVertices.isEmpty, receipt != nil {
            return (out.meshVertices, out.meshIndices, true)
        }
        return (context.meshVertices, context.meshIndices, false)
    }
}

// MARK: - the action row

/// What the smoothing page's action row offers. Same shape as
/// `LatticePageActions` — one page's action row must not read as a different
/// product from the next one's.
public struct SmoothPageActions: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public let label: String
        public let sub: String
        public let enabled: Bool
        public let primary: Bool
    }

    public let recertify: Action
    public let keep: Action
    public let discard: Action
    /// AE8 forward: send the SMOOTHED variant to the lattice page. Enabled only
    /// once a smoothing has been kept, so the lattice is always generated on
    /// geometry that has a certification of its own.
    public let sendToLattice: Action

    public static func compute(brush: SmoothBrushModel, working: Bool,
                               hasReceipt: Bool, hasKept: Bool,
                               unavailable: SmoothUnavailable?) -> SmoothPageActions {
        if let why = unavailable {
            let off = Action(label: "Re-certify", sub: why.reason,
                             enabled: false, primary: true)
            return SmoothPageActions(
                recertify: off,
                keep: Action(label: "Keep", sub: why.reason, enabled: false, primary: false),
                discard: Action(label: "Discard", sub: "nothing to discard",
                                enabled: false, primary: false),
                sendToLattice: Action(label: "Lattice this", sub: why.reason,
                                      enabled: false, primary: false))
        }
        let re: Action
        if working {
            re = Action(label: "Re-certify", sub: "a certification is running",
                        enabled: false, primary: true)
        } else if let why = brush.unusableReason {
            re = Action(label: "Re-certify", sub: why, enabled: false, primary: true)
        } else if !brush.hasEffect {
            re = Action(label: "Re-certify",
                        sub: "brush an area and give it a strength first",
                        enabled: false, primary: true)
        } else {
            re = Action(
                label: "Re-certify",
                sub: String(format: "one certification solve on the smoothed shape "
                                    + "· strongest region %.2f", brush.maxStrength),
                enabled: true, primary: true)
        }
        return SmoothPageActions(
            recertify: re,
            keep: Action(label: "Keep smoothing",
                         sub: hasReceipt
                            ? "carries the smoothed mesh and this receipt forward"
                            : "needs a current certification",
                         enabled: hasReceipt && !working, primary: false),
            discard: Action(label: "Discard",
                            sub: "returns the original variant, unchanged",
                            enabled: (hasKept || hasReceipt) && !working,
                            primary: false),
            sendToLattice: Action(
                label: "Lattice this",
                sub: hasKept
                    ? "the lattice is generated on the SMOOTHED geometry"
                    : "keep the smoothing first — a lattice needs certified geometry",
                enabled: hasKept && !working, primary: false))
    }
}
