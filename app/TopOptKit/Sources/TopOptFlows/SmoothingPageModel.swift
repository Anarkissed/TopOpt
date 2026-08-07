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

    /// Decimal places the two mass rows print at. Three, because the quantity
    /// they report is one Taubin holds nearly fixed on purpose: on the probe's
    /// own corner patch the mesh mass moved 0.140 g on 245 g (+0.057 %), and at
    /// one decimal — what shipped — that printed as no change at all. Named
    /// rather than inlined so the V2 test pins the resolution itself.
    public static let massDecimals = 3

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
        // BOTH MASSES AT `massDecimals` (task 2026-08-04, bar V2). They used to
        // print at one decimal, and on the maintainer's run that made "Mass
        // (mesh) 182.6 g → 182.6 g" the only row that did not move — which read
        // as "the certification solved the ORIGINAL shape". It had not.
        //
        // `smooth_viewer_identity_probe` settled it: mesh mass is computed by
        // bridge.cpp's `analyze_loadcase` from whatever mesh it ANALYSED, which on
        // the after column is the smoothed file, and the measured column moves
        // (245.650462 → 245.790474 g on a corner patch at strength 1.00). What
        // makes it move so LITTLE is Taubin itself: the λ|μ pair is
        // volume-preserving by construction — that is the whole reason core uses
        // it instead of a plain Laplacian, which would collapse the part. A
        // genuine sub-0.05 g change then rounded to the same string at one
        // decimal, and an unchanged string is not something a reader can
        // distinguish from an unchanged shape.
        //
        // So the fix is precision, not a different quantity. The size of the move
        // relative to the smoother's own bound is already stated by
        // `SmoothingApplied.driftLine`.
        out.append(Row(label: "Mass (voxel)",
                       beforeText: Self.f(before.voxelMassGrams, Self.massDecimals) + " g",
                       afterText: Self.f(after.voxelMassGrams, Self.massDecimals) + " g",
                       worse: nil, better: nil))
        out.append(Row(label: "Mass (mesh)",
                       beforeText: Self.f(before.meshMassGrams, Self.massDecimals) + " g",
                       afterText: Self.f(after.meshMassGrams, Self.massDecimals) + " g",
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

    /// ★ WHAT THE CERTIFICATE CANNOT SEE (task 2026-08-08, S3e).
    ///
    /// PR 303 measured the shipped smoother moving this part's surface **0.23 mm**
    /// and returning an IDENTICAL margin, peak stress, verdict and voxel mass — to
    /// every digit. That is not the certificate confirming the part is still fine;
    /// it is the certificate being structurally unable to see the change, because
    /// it re-voxelizes onto the same grid and a sub-voxel move does not alter a
    /// single voxel.
    ///
    /// So this line exists to stop the most likely misreading of the row above it:
    /// that a margin which did not move is a safety check on the smoothing. It is
    /// not. It is stated UNCONDITIONALLY rather than only when the margin holds
    /// still, because the limitation is a property of the instrument and not of
    /// any particular reading — a footnote that appeared only sometimes would
    /// imply the certificate CAN see the change the rest of the time.
    public var certificateBlindnessLine: String {
        String(format:
            "The certification re-voxelizes at %.2f mm, so it cannot see surface "
            + "motion smaller than one voxel: a margin that did not move is NOT "
            + "evidence that the smoothing was safe. What bounds the risk is the "
            + "displacement limit on the brush, not this number.", after.spacingMM)
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

    /// THE LIVE BRUSH PREVIEW (task 2026-08-04-variant-volume-fraction-mismatch,
    /// failure C). Injected like `Runner` so the whole behaviour is headlessly
    /// testable; nil ⇒ the host gave the page no preview engine and the toggle
    /// says exactly that instead of pretending.
    ///
    /// ★ IT TAKES THE GEOMETRY, NOT A PATH (task 2026-08-08, S1b). This used to
    /// be `(meshPath, strength, weights)`, and the bridge behind it re-imported
    /// the variant's STL on EVERY settled stroke — 14.4 MB and 164,228 triangles
    /// on the maintainer's own part, to produce vertices this model is already
    /// holding in `context.meshVertices`. The signature is the fix: there is no
    /// longer a parameter through which a file could be named, so the re-read
    /// cannot come back by someone re-wiring a caller.
    public typealias Previewer =
        @Sendable (_ vertices: [Float], _ indices: [Int32], _ strength: Double,
                   _ weights: [Double]) async throws -> BrushPreviewResult

    /// What one preview produced: the deformed geometry and how far it moved.
    public struct BrushPreviewResult: Equatable, Sendable {
        public let meshVertices: [Float]
        public let meshIndices: [Int32]
        public let movedVertices: Int
        public let maxDisplacementMM: Double
        public let seconds: Double
        /// Where `seconds` went (task 2026-08-08, S1b/S1c). `secondsImport` is
        /// the STL re-read the page no longer does — it is 0 on the shipped
        /// route, and a non-zero value here means something re-wired the preview
        /// back onto a file.
        public var secondsImport: Double = 0
        public var secondsSmooth: Double = 0

        public init(meshVertices: [Float], meshIndices: [Int32],
                    movedVertices: Int, maxDisplacementMM: Double,
                    seconds: Double,
                    secondsImport: Double = 0, secondsSmooth: Double = 0) {
            self.secondsImport = secondsImport
            self.secondsSmooth = secondsSmooth
            self.meshVertices = meshVertices
            self.meshIndices = meshIndices
            self.movedVertices = movedVertices
            self.maxDisplacementMM = maxDisplacementMM
            self.seconds = seconds
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// The kept-or-not decision. Non-nil once a re-certification succeeds (U3 —
    /// there is no longer a second button to press).
    @Published public private(set) var kept: SmoothKeptResult?
    /// Which side of the before/after the viewport is showing.
    @Published public var showingSmoothed = true

    // ── U4/U5/U6: what the page shows, and for how long ─────────────────────

    /// THE RECEIPT IS A DRAWER (bar U4), not a permanent panel. It used to be a
    /// card inside the left panel, which meant every number on it was standing
    /// text the user had to scroll past to reach the brush.
    @Published public var receiptOpen = false

    /// THE NOTE QUEUE (bar U5, extended by bar D5c). One visible, the rest
    /// waiting, each for at most `PageTransientNote.lifetime`, each dismissible,
    /// and a queued one whose topic has gone stale is dropped rather than shown
    /// late. `PageNoteQueue` lives in `PageChrome.swift` so a fourth page
    /// inherits the rule instead of inventing a third one.
    @Published public private(set) var noteBox = PageNoteQueue()
    public var note: PageTransientNote? { noteBox.note }
    /// How many notes are waiting behind the visible one — read by the tests.
    public var queuedNoteCount: Int { noteBox.depth }

    /// The topics a note can be ABOUT. A topic is re-resolved when its note comes
    /// up for display; `nil` means the state it described is gone.
    public enum NoteTopic {
        /// What the Smoothed side is showing right now.
        public static let smoothedSide = "smoothedSide"
        /// "Pencil only is on, so a finger orbits."
        public static let pencilOnly = "pencilOnly"
    }

    /// The CURRENT text for a topic, or nil if it no longer says anything.
    public func noteText(forTopic topic: String) -> String? {
        switch topic {
        case NoteTopic.smoothedSide: return smoothedSideNote
        case NoteTopic.pencilOnly: return Self.pencilOnlyNote
        default: return nil
        }
    }

    public func post(note text: String, topic: String = "", now: Date = Date()) {
        noteBox.post(text, topic: topic, now: now)
    }
    /// THE ✕ (bar D5c). A failure banner is not in the queue — it is derived
    /// from the phase — so dismissing it has to be its own fact, or the button
    /// would be a control that does nothing. A NEW failure re-arms it: what has
    /// been waved away is that failure, not the idea of being told.
    @Published public private(set) var failureDismissed = false
    public func dismissNote(now: Date = Date()) {
        if failure != nil, !failureDismissed {
            failureDismissed = true
            return
        }
        noteBox.dismiss(now: now, resolve: { [weak self] in self?.noteText(forTopic: $0) })
    }
    public func tick(now: Date = Date()) {
        noteBox.tick(now: now, resolve: { [weak self] in self?.noteText(forTopic: $0) })
    }

    /// BAR D1b — SAY WHY THE BRUSH IGNORED THE FINGER, ONCE.
    ///
    /// The maintainer checked "Pencil only", drew with an Apple Pencil, and
    /// nothing happened; the page's only comment on that was four disabled
    /// buttons further down the screen. The gate defect is fixed, so a pencil
    /// paints — but a FINGER drag with this on is still refused (that is the
    /// point of the toggle), and the page now says so the first time it happens
    /// rather than leaving the user to work it out.
    ///
    /// Once per page session: a finger orbit is the intended behaviour here, and
    /// a note on every orbit would be noise.
    @Published public private(set) var pencilOnlyNoteShown = false
    public static let pencilOnlyNote =
        "“Pencil only” is on — a finger drag turns the part around. "
        + "Draw with the pencil, or switch Pencil only off to paint with a finger."
    public func notePencilOnlyRefusedFinger(now: Date = Date()) {
        guard !pencilOnlyNoteShown else { return }
        pencilOnlyNoteShown = true
        post(note: Self.pencilOnlyNote, topic: NoteTopic.pencilOnly, now: now)
    }

    /// BAR D5c — THE SMOOTHED-SIDE SENTENCE IS A NOTE, NOT STANDING PROSE.
    ///
    /// It used to be a permanent paragraph under the stage tabs, which is a note
    /// in the wrong place: on his screenshots it lay across the top-centre note
    /// and ran on under the panel. It goes through the queue now, and only when
    /// it becomes NEWS — the value at entry is seeded, so the page still starts
    /// with nothing standing on it (bar U6).
    private var lastSideNote: String?
    public func syncSideNote(now: Date = Date()) {
        let current = smoothedSideNote
        guard current != lastSideNote else { return }
        lastSideNote = current
        if let c = current {
            post(note: c, topic: NoteTopic.smoothedSide, now: now)
        }
    }

    /// THE ONE STANDING NOTICE (bar U6): shown on entry, dismissed with OK, and
    /// then gone for this page session. Everything the page used to explain in
    /// permanent prose is either this sentence or is behind the receipt drawer.
    @Published public private(set) var entryNoticeDismissed = false
    public func dismissEntryNotice() { entryNoticeDismissed = true }
    public static let entryNotice = "You cannot smooth protected areas."
    /// Whether that notice is currently up.
    public var showsEntryNotice: Bool {
        !entryNoticeDismissed && context.unavailable == nil
    }

    public let context: SmoothVariantContext
    /// Where the variant's own mesh was written for the certification engine to
    /// read, and where a smoothed mesh goes.
    public let variantMeshPath: String
    public let smoothedMeshPath: String
    private let runner: Runner
    private let previewer: Previewer?
    /// The live preview of the CURRENT brush — the geometry the Smoothed tab
    /// draws before any certification has run (failure C). Cleared whenever the
    /// brush changes, so the tab never shows a stroke the user has moved on from.
    @Published public private(set) var preview: BrushPreviewResult?
    /// True while a preview is in flight.
    @Published public private(set) var previewing = false
    /// How many previews have been produced this session — the test reads it to
    /// prove the toggle is fed by a real deformation and not by the certification.
    public private(set) var previewCallCount = 0
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
                smoothedMeshPath: String = "", runner: @escaping Runner,
                previewer: Previewer? = nil) {
        self.context = context
        self.variantMeshPath = variantMeshPath
        self.smoothedMeshPath = smoothedMeshPath
        self.runner = runner
        self.previewer = previewer
        // SEED the side-note tracker at entry: the sentence that is true when the
        // page opens is not news, and posting it would put a note on a page that
        // bar U6 says starts with nothing standing on it.
        self.lastSideNote = nil
        self.lastSideNote = smoothedSideNote
    }

    // ── the live brush preview (failure C) ──────────────────────────────────

    /// Whether this page can show a Smoothed side at all before re-certifying.
    /// The toggle's copy reads this: a page with no preview engine must SAY the
    /// comparison is unavailable, never offer it and draw the same mesh twice.
    public var canPreviewBrush: Bool { previewer != nil }

    /// Apply the CURRENT brush to the preview mesh. Called when a stroke settles,
    /// so the Smoothed tab shows the smoothed shape immediately — the whole of
    /// bar C1 / L4.
    ///
    /// A brush with nothing painted clears the preview rather than running the
    /// smoother on an all-zero weight vector: that would return the input mesh
    /// and make "Smoothed" claim a difference it does not have.
    public func refreshPreview(brush: SmoothBrushModel) async {
        guard let p = previewer else { return }
        let weights = brush.normalizedWeights()
        let strength = brush.maxStrength
        guard strength > 0, weights.contains(where: { $0 > 0 }) else {
            preview = nil
            return
        }
        previewing = true
        defer { previewing = false }
        do {
            previewCallCount += 1
            // THE GEOMETRY THE PAGE ALREADY OWNS. `context` is the variant as the
            // run made it — the same buffer the stage draws and the same one the
            // brush's weights are indexed against — so this cannot preview a
            // different mesh from the one on screen (task 2026-08-08, S1b).
            let r = try await p(context.meshVertices, context.meshIndices,
                                strength, weights)
            // A deformation that moved NOTHING is not a smoothed side. Reported
            // as absent so the toggle keeps saying "nothing smoothed yet" rather
            // than offering two identical meshes as a before/after.
            preview = r.movedVertices > 0 ? r : nil
        } catch {
            preview = nil
        }
        syncSideNote()
    }

    /// Drop the preview — the brush changed, or the page is starting over.
    public func clearPreview() { preview = nil }

    /// ★ IS THERE A SMOOTHED SHAPE TO LOOK AT? (task 2026-08-08, S3d.)
    ///
    /// THE DEFECT. The view's own copy of this read `receipt != nil || kept != nil`
    /// and ignored `preview` — so the Smoothed tab was DEAD until a certification
    /// had run, even though `refreshPreview` produces a displaced mesh on every
    /// settled stroke and `currentGeometry` was already willing to hand it to the
    /// stage. The maintainer's words for it: certification was being used as the
    /// rendering path. PR 303 reproduced it, named this exact fix, and deferred it
    /// behind PR 299's NO-GO on the operator.
    ///
    /// IT IS TAKEN NOW REGARDLESS OF THE OPERATOR QUESTION. Whether the smoother
    /// is worth improving (it is not — see this task's S2) is a different question
    /// from whether the user can see what it did. A preview he cannot reach is a
    /// broken control, not a small change.
    ///
    /// IT LIVES ON THE MODEL, NOT IN THE VIEW, on purpose. As a `private var` in
    /// `SmoothingPage` the only way to test it was to retype the expression in the
    /// test — which is a mirror, and a mirror agrees with the view right up until
    /// someone edits one of them. Here the test and the view read the same
    /// property.
    public var hasSmoothedToShow: Bool {
        receipt != nil || kept != nil || preview != nil
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

    /// EXACTLY ONE THING AT THE TOP OF THE SCREEN (bar U5).
    ///
    /// The page used to draw a status banner, a failure banner and an in-panel
    /// warning card, all at once and all overlapping — the three notices the
    /// maintainer counted. This is the single decision that replaces them: a
    /// precedence, evaluated in one place, returning at most one thing. A view
    /// cannot show two because there is only one value to render.
    ///
    /// At REST it is nil. Nothing stands on this page when nothing is happening —
    /// that is bar U6 expressed as a state rather than as a promise about layout.
    public enum TopNote: Equatable, Sendable {
        /// A re-certification produced no verdict (H1/AE5). Outranks everything:
        /// it is the only one that changes what the numbers below mean.
        case failure(SmoothCertifyFailure)
        /// The transient note — an outcome, or something the page wants to say
        /// once. Auto-dismisses.
        case transient(PageTransientNote)
        /// Work in flight. Only while it actually is.
        case working(String)
    }

    public var topNote: TopNote? {
        if let f = failure, !failureDismissed { return .failure(f) }
        if let n = note { return .transient(n) }
        if isWorking { return .working(statusLine) }
        return nil
    }

    /// The one-line status, shown only while working or inside the receipt drawer.
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
                failureDismissed = false
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
            // A SUCCESSFUL RE-CERTIFICATION IS THE KEEP (bar U3). The page used
            // to carry a separate "Keep smoothing" button, and the maintainer's
            // note on it was: "that's stupid. They just keep smoothing if they
            // want to keep smoothing." He is right — the button asked the user to
            // ratify a decision they had already made by pressing Re-certify, and
            // its only real job was to gate "Lattice this" on there being a
            // current verdict. That gate is the receipt, so it can read the
            // receipt.
            //
            // Nothing about WHEN a smoothing is keepable has moved: `keep`
            // refuses unless there is a current, non-stale receipt, so a
            // non-convergent or failed re-certification still keeps nothing. This
            // only removes the second press.
            keep(regionLines: brush.summaries().filter { !$0.inert }
                    .map { String(format: "%@ %.2f (%d tri)", $0.name,
                                  $0.strength, $0.triangles) })
            // The outcome is a TRANSIENT note, not a standing banner (U5/U6): it
            // is news, and news stops being news. The numbers behind it stay
            // available in the receipt drawer for as long as the user wants them.
            if let r = receipt { post(note: r.headline) }
            syncSideNote()
        } catch {
            let message = (error as? TopOptError)?.message ?? "\(error)"
            failureDismissed = false
            phase = .couldNotCertify(
                SmoothCertifyFailure(kind: .refused(message), maxStrength: strength),
                stale: lastGood)
        }
    }

    // ── keep / discard (bar AE9) ────────────────────────────────────────────

    /// KEEP the smoothing: the smoothed geometry and the receipt that certified
    /// it travel onward together. Refused unless there is a CURRENT (non-stale)
    /// receipt — a smoothing whose verdict could not be produced is never keepable.
    ///
    /// `designFingerprint` is core's hash over the rung's density field, when the
    /// caller holds the retained container. It makes the recorded identity a DESIGN
    /// rather than a position (task 2026-08-03-variant-postprocessing-concurrency,
    /// requirement 3) — absent, the rung index and its volume fraction are the whole
    /// identity, which is honest rather than pretending to a hash we do not have.
    @discardableResult
    public func keep(regionLines: [String],
                     designFingerprint: UInt64? = nil) -> Bool {
        guard let r = receipt, let out = lastSmoothedOutcome,
              !out.meshVertices.isEmpty else { return false }
        kept = SmoothKeptResult(meshVertices: out.meshVertices,
                                meshIndices: out.meshIndices,
                                meshPath: r.after.meshPath,
                                certification: r.after,
                                regionSummary: regionLines,
                                rung: rungFingerprint(designFingerprint))
        return true
    }

    /// The rung this page is working on, as an identity. Read from the page's own
    /// immutable `context` — never from whatever the workspace has selected now,
    /// which is exactly the confusion this fingerprint exists to prevent.
    public func rungFingerprint(_ designFingerprint: UInt64? = nil)
        -> SmoothingRungFingerprint {
        SmoothingRungFingerprint(
            variantIndex: context.variantIndex,
            requestedVolumeFraction: context.requestedVolumeFraction,
            designFingerprint: designFingerprint)
    }

    /// The banner to show when the kept smoothing belongs to a different rung than
    /// the one on screen. nil ⇒ nothing to say.
    public func stalenessBanner(currentRung: SmoothingRungFingerprint?)
        -> LatticePageBanner? {
        SmoothingStaleness.banner(kept: kept?.rung, current: currentRung)
    }

    /// DISCARD (bar AE9): every trace of the smoothing goes, and the ORIGINAL
    /// variant is what the page and everything downstream sees. The original is
    /// never mutated in the first place — it is the immutable `context` — so this
    /// is a state reset, not an inverse operation that could drift.
    public func discard() {
        kept = nil
        lastSmoothedOutcome = nil
        // AE9 covers the live preview too (task
        // 2026-08-04-variant-volume-fraction-mismatch): "every trace of the
        // smoothing goes" has to include the deformed geometry the Smoothed tab
        // was drawing, or Discard would leave a smoothed shape on screen.
        preview = nil
        phase = .idle
        showingSmoothed = false
        // The drawer described a receipt that no longer exists, and the note
        // announced its outcome. Both go with it (U4/U5) — a drawer left open
        // over nothing is the "stale number on screen" failure in another shape.
        // The QUEUE goes too: every note behind the visible one was about a state
        // this reset has just left, and showing them afterwards is precisely the
        // "note that describes a state the user has already left" D5c forbids.
        receiptOpen = false
        failureDismissed = false
        noteBox.clear()
        lastSideNote = smoothedSideNote
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
        // THE LIVE PREVIEW (failure C / bar L4). Before any certification has
        // run, Smoothed draws the brush's own deformation — which is what makes
        // the toggle a comparison instead of two identical meshes. It ranks BELOW
        // a certified or kept result, so once a real one exists the preview never
        // shadows it.
        if kept == nil, showingSmoothed, let p = preview,
           !p.meshVertices.isEmpty {
            return (p.meshVertices, p.meshIndices, true)
        }
        return (context.meshVertices, context.meshIndices, false)
    }

    /// What the toggle should SAY about the Smoothed side right now (bar C1/C2).
    /// nil ⇒ the two sides genuinely differ and nothing needs explaining.
    ///
    /// This replaced an unconditional *"Nothing smoothed yet — both show the
    /// variant as the run made it"*, which was printed even while a 71,752-triangle
    /// brush region sat at strength 0.49. The page was describing its own inability
    /// to preview as a fact about the user's brush.
    public var smoothedSideNote: String? {
        if kept != nil || receipt != nil { return nil }
        if previewing { return "Applying the brush…" }
        if let p = preview {
            return "Smoothed shows the brush applied — "
                 + String(format: "%.2f mm", p.maxDisplacementMM)
                 + " at the deepest. Re-certify APPLIES it under the min-feature "
                 + "constraint and measures the result, so the certified shape may "
                 + "move less."
        }
        if !canPreviewBrush {
            return "This page can’t preview the brush, so Smoothed shows the "
                 + "variant as the run made it. Re-certify to see the smoothed "
                 + "shape."
        }
        return "Nothing painted yet — both show the variant as the run made it."
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

    /// The four things the page can be asked to do. Named so the column's ORDER
    /// is a value the tests can read rather than a shape in the view body.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case receipt, discard, lattice, recertify
    }

    /// THE ACTION COLUMN, TOP TO BOTTOM (bar D5b, task 2026-08-05).
    ///
    /// One column, narrowest first, `recertify` pinned last in every state. The
    /// widths were MEASURED at the maintainer's own landscape size rather than
    /// guessed — see `SmoothingRound4Tests.testTheActionColumnIsOrderedByWidth`,
    /// which renders the page in four different states and checks this constant
    /// still runs narrow → wide with Apply & certify at the foot.
    ///
    /// A CONSTANT, NOT A SORT. Every button is as wide as its own caption and the
    /// captions change between states ("re-certify to get one" → "before and
    /// after, both measured"), so sorting at render time would shuffle the column
    /// under the user's thumb the moment a certification landed. His rule was
    /// explicit: the order must not reflow as captions change.
    public static let columnOrder: [Kind] = [.receipt, .discard, .lattice, .recertify]

    public let recertify: Action
    public let discard: Action
    /// AE8 forward: send the SMOOTHED variant to the lattice page. Enabled only
    /// once a smoothing has been kept, so the lattice is always generated on
    /// geometry that has a certification of its own.
    public let sendToLattice: Action

    public static func compute(brush: SmoothBrushModel, working: Bool,
                               hasReceipt: Bool, hasKept: Bool,
                               unavailable: SmoothUnavailable?) -> SmoothPageActions {
        if let why = unavailable {
            let off = Action(label: "Apply & certify", sub: why.reason,
                             enabled: false, primary: true)
            return SmoothPageActions(
                recertify: off,
                discard: Action(label: "Discard", sub: "nothing to discard",
                                enabled: false, primary: false),
                sendToLattice: Action(label: "Lattice this", sub: why.reason,
                                      enabled: false, primary: false))
        }
        // BAR C2 — THE BUTTON NAMES WHAT IT DOES. "Re-certify" read as a CHECK on
        // a smoothing that had already happened, which is why the maintainer
        // painted, toggled, saw no change and concluded the brush was broken.
        // Nothing is smoothed until this runs: it applies the brush under the
        // min-feature constraint and certifies the result. The label says that;
        // the sub-line says the two halves in order.
        let re: Action
        if working {
            re = Action(label: "Apply & certify", sub: "a certification is running",
                        enabled: false, primary: true)
        } else if let why = brush.unusableReason {
            re = Action(label: "Apply & certify", sub: why, enabled: false, primary: true)
        } else if !brush.hasEffect {
            // "…and give it a strength first" was left over from round 2's
            // per-region slider. There is no strength to give any more: one
            // stroke IS a strength (bar U1's ladder), so the sentence told the
            // user to look for a control that had been deleted.
            re = Action(label: "Apply & certify",
                        sub: "brush an area first",
                        enabled: false, primary: true)
        } else {
            re = Action(
                label: "Apply & certify",
                sub: String(format: "applies the brush to the variant, then one "
                                    + "certification solve on the result "
                                    + "· strongest region %.2f", brush.maxStrength),
                enabled: true, primary: true)
        }
        return SmoothPageActions(
            recertify: re,
            // DISCARD IS ENABLED WHENEVER THE PAGE IS NOT BUSY (task 2026-08-05,
            // the disabled-control audit). It used to require a receipt or a
            // kept result, which put a greyed-out button in front of a user who
            // had painted half the part and wanted to start over — the strokes,
            // the tint and the live preview are all things to discard, and none
            // of them is a certification. And with nothing painted at all the
            // press is a harmless no-op that lands exactly where its own caption
            // says it does: the original variant, unchanged.
            discard: Action(label: "Discard",
                            sub: "returns the original variant, unchanged",
                            enabled: !working,
                            primary: false),
            // AE8's guarantee is unchanged: a lattice is only ever generated on
            // geometry that has a certification of its own. What changed is which
            // fact says so. It used to be `hasKept` — the user having pressed a
            // second button — and it is now the receipt itself, because a
            // successful re-certification keeps (bar U3). The two are the same
            // condition now, and the receipt is the one that is actually ABOUT
            // the geometry.
            sendToLattice: Action(
                label: "Lattice this",
                sub: hasReceipt
                    ? "the lattice is generated on the SMOOTHED geometry"
                    : "re-certify first — a lattice needs certified geometry",
                enabled: hasReceipt && !working, primary: false))
    }
}
