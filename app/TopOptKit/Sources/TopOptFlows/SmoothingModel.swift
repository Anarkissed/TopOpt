// SmoothingModel — the state + HONESTY LOGIC behind the "Smooth" control on the
// results screen (handoff 2026-07-28-constrained-smooth-ui).
//
// The one rule this model exists to enforce: PRE-SMOOTHING NUMBERS NEVER APPEAR
// BESIDE SMOOTHED GEOMETRY. Smoothing routes through re-certification, and the only
// numbers this model ever exposes are the re-analysed ones (from `.certified`).
// While smoothing/working, or if the re-cert can't converge (S7), or on a hard
// failure, it exposes NO margin/mass — only a status. The view binds to `phase` and
// the derived copy; there is no back door to a cached optimizer number.
//
// It also carries the SELL: the differentiated value is the RECEIPT and the HARD
// CONSTRAINTS (frozen mating faces / bolt circles, min-feature as a wall), not the
// cosmetic look — so the copy leads with those, and with the honest quantization gap.
import Foundation
import simd
import TopOptKit

@MainActor
public final class SmoothingModel: ObservableObject {

    /// The re-analysed receipt shown beside the smoothed geometry. A thin projection
    /// of `TopOptKit.SmoothRecertifyResult` — every field describes the SMOOTHED part.
    public struct Receipt: Equatable, Sendable {
        public let accepted: Bool
        public let marginWorstCase: Double
        public let marginRequired: Double
        public let maxStressMPa: Double
        public let voxelMassGrams: Double
        public let meshMassGrams: Double
        public let minFeatureViolations: Int
        public let spacingMM: Double
        public let strength: Double
        public let pairsRequested: Int
        public let pairsApplied: Int
        public let frozenVertices: Int
        public let totalVertices: Int
        public let volumeDriftFraction: Double
        public let volumeDriftBound: Double
        public let minFeatureLimited: Bool
        public let smoothedMeshPath: String

        init(_ r: TopOptKit.SmoothRecertifyResult) {
            accepted = r.accepted
            marginWorstCase = r.marginWorstCase
            marginRequired = r.marginRequired
            maxStressMPa = r.maxStressMPa
            voxelMassGrams = r.voxelMassGrams
            meshMassGrams = r.meshMassGrams
            minFeatureViolations = r.minFeatureViolations
            spacingMM = r.spacingMM
            strength = r.strength
            pairsRequested = r.pairsRequested
            pairsApplied = r.pairsApplied
            frozenVertices = r.frozenVertices
            totalVertices = r.totalVertices
            volumeDriftFraction = r.volumeDriftFraction
            volumeDriftBound = r.volumeDriftBound
            minFeatureLimited = r.minFeatureLimited
            smoothedMeshPath = r.smoothedMeshPath
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case certified(Receipt)
        /// S7 — the certification solve could not resolve the smoothed field. NOT a
        /// genuine "too weak" verdict; there simply is no trustworthy number, so the
        /// UI offers a lower strength instead of showing a fabricated margin.
        case couldNotCertify(strength: Double)
        case failed(String)
    }

    /// The strength knob ∈ [0, 1]. 0 = identity (no smoothing). The view binds a
    /// slider to this; applying at 0 is a no-op the view disables.
    @Published public var strength: Double = 0.35
    @Published public private(set) var phase: Phase = .idle

    /// Injected so the model is headlessly testable. In the app this wraps
    /// `TopOptKit.smoothAndRecertifyLoadCase` on a background executor.
    public typealias Runner =
        @Sendable (_ strength: Double) async throws -> TopOptKit.SmoothRecertifyResult
    private let runner: Runner

    public init(strength: Double = 0.35, runner: @escaping Runner) {
        self.strength = strength
        self.runner = runner
    }

    /// Smooth at the current `strength` and re-certify. Sets `phase` to `.working`,
    /// then to `.certified` / `.couldNotCertify` / `.failed`. The honesty rule is
    /// structural: on any non-certified outcome the receipt is cleared, so a stale
    /// (stronger) number can never be shown next to a smoothed shape.
    public func apply() async {
        let s = strength
        phase = .working
        do {
            let r = try await runner(s)
            phase = r.nonConvergent ? .couldNotCertify(strength: s) : .certified(Receipt(r))
        } catch {
            phase = .failed((error as? TopOptError)?.message ?? "\(error)")
        }
    }

    /// Reset to the pre-smoothing view (the "See original" affordance).
    public func reset() { phase = .idle }

    // ── The honesty gate: numbers exist ONLY when certified ──────────────────────

    /// The re-analysed receipt, or nil. The view MUST read margin/mass/verdict only
    /// from here — there is no other numeric surface on this model.
    public var receipt: Receipt? {
        if case .certified(let r) = phase { return r }
        return nil
    }

    public var isWorking: Bool { if case .working = phase { return true }; return false }
    public var canApply: Bool { strength > 0 && !isWorking }

    /// The path Export exports (the smoothed mesh) — only when a receipt exists.
    public var exportMeshPath: String? { receipt?.smoothedMeshPath }

    // ── Display copy (the SELL is the receipt + the constraints, not the look) ───

    public static let pillText = "Smoothed · re-analyzed"

    /// The info-popover disclosure (task item 4): the analyzed-vs-printed quantization
    /// gap is stated, not hidden.
    public var quantizationInfo: String {
        let mm = receipt.map { String(format: "%.2g mm", $0.spacingMM) } ?? "the print grid"
        return """
        Re-analysis runs on the voxelization of the SMOOTHED mesh at the print grid \
        resolution (\(mm)), so the analyzed and printed geometry can differ by up to \
        about half a voxel. The margin and voxel mass describe that voxel proxy; the \
        mesh mass is the surface-enclosed volume of the exported mesh.
        """
    }

    /// The one-line value proposition shown under the control.
    public static let sell = """
    Smoothing rounds the print terracing, then RE-CERTIFIES: mating faces and bolt \
    circles are held bit-identical, min feature width is a hard wall, and the margin \
    below is re-computed on the smoothed shape — never carried over.
    """

    /// The headline verdict line, or nil when there is nothing certified to show.
    public var verdictText: String? {
        switch phase {
        case .idle: return nil
        case .working: return "Re-certifying the smoothed shape…"
        case .couldNotCertify(let s):
            return String(format: "Couldn't re-certify at strength %.2f — try a lower strength.", s)
        case .failed(let m): return "Smoothing failed: \(m)"
        case .certified(let r):
            return r.accepted
                ? "Holds — re-certified margin is above the required minimum."
                : "Weakened below the required margin — reduce strength or keep the original."
        }
    }

    /// A short, honest volume-drift line for the receipt: measured vs Taubin's bound,
    /// flagging when aggressive smoothing moved more than the small-perturbation bound.
    public func driftLine(_ r: Receipt) -> String {
        let pct = { (x: Double) in String(format: "%.2f%%", x * 100) }
        let base = "Volume drift \(pct(r.volumeDriftFraction)) (Taubin bound \(pct(r.volumeDriftBound)))"
        return r.volumeDriftFraction > r.volumeDriftBound
            ? base + " — beyond the denoising bound: real material was removed."
            : base + "."
    }
}

// MARK: - Live wiring

extension SmoothingModel {
    /// Everything the live re-cert runner needs from the run: the part, the selected
    /// variant's exported mesh, where to write the smoothed mesh, the material/rules
    /// files, and the DECLARED load case (anchors + tractions) the run used — so the
    /// re-certification loads the part the same way the optimizer did. All value
    /// types, so it crosses the background-executor boundary safely.
    public struct Context: Sendable {
        public var modelPath: String
        public var inputMeshPath: String
        public var smoothedOutPath: String
        public var material: String
        public var materialsPath: String
        public var rulesPath: String
        public var resolution: Int
        public var anchorFaceIDs: [Int]
        public var loadGroups: [TopOptKit.LoadGroupSpec]
        public var buildDirection: SIMD3<Double>
        public var infillPercent: Int
        public var freeze: [TopOptKit.FreezeRegionSpec]

        public init(modelPath: String, inputMeshPath: String, smoothedOutPath: String,
                    material: String, materialsPath: String, rulesPath: String,
                    resolution: Int, anchorFaceIDs: [Int],
                    loadGroups: [TopOptKit.LoadGroupSpec],
                    buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
                    infillPercent: Int = -1,
                    freeze: [TopOptKit.FreezeRegionSpec] = []) {
            self.modelPath = modelPath
            self.inputMeshPath = inputMeshPath
            self.smoothedOutPath = smoothedOutPath
            self.material = material
            self.materialsPath = materialsPath
            self.rulesPath = rulesPath
            self.resolution = resolution
            self.anchorFaceIDs = anchorFaceIDs
            self.loadGroups = loadGroups
            self.buildDirection = buildDirection
            self.infillPercent = infillPercent
            self.freeze = freeze
        }
    }

    /// A model whose runner calls the real bridge seam on a background executor, so
    /// the (blocking) re-cert never stalls the main actor while the UI shows
    /// `.working`. The honesty rule and the S7 branch are unchanged — they live in
    /// `apply()`, above.
    public static func live(context: Context, strength: Double = 0.35) -> SmoothingModel {
        SmoothingModel(strength: strength, runner: { s in
            try await Task.detached(priority: .userInitiated) {
                try TopOptKit.smoothAndRecertifyLoadCase(
                    modelPath: context.modelPath, inputMeshPath: context.inputMeshPath,
                    smoothedOutPath: context.smoothedOutPath, material: context.material,
                    materialsPath: context.materialsPath, rulesPath: context.rulesPath,
                    resolution: context.resolution, strength: s, enforceMinFeature: true,
                    anchorFaceIDs: context.anchorFaceIDs, loadGroups: context.loadGroups,
                    buildDirection: context.buildDirection,
                    infillPercent: context.infillPercent, freeze: context.freeze)
            }.value
        })
    }
}
