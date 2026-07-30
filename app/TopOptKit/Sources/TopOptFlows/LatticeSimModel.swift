// LatticeSimModel.swift — the lattice page's RUN SIM state machine (handoff
// 2026-07-30-lattice-page, bars B5/B6/B9).
//
// RUN SIM is ONE coarse linear FEA of the SOLID part under page one's declared
// anchors + loads, through the bridge's analyze_loadcase seam (the same
// build_production_loadcase the optimizer and the CLI use). Its product is the
// per-voxel von Mises field the auto-density preview grades from, plus the
// headline numbers the sim banner shows.
//
// DEVIATION FROM THE PROTOTYPE, reported in the handoff: the sim runs ON-DEVICE,
// not on the worker — the LAN worker routes only `run` (minimize_plastic) jobs
// and the job schema's only mode is "minimize_plastic", so a worker-dispatched
// analyze does not exist yet. The bridge path solves the identical load case.
//
// Staleness (B6/B9): the field is stamped with a fingerprint of everything that
// ACTUALLY determines it — the model, the material, the resolution and the
// declared load case. When any of those change after a completed sim, the field
// is STALE and the page shows the amber "Sim is out of date / Re-run" banner.
// (The prototype staled on a cell-size change; the solid-part field does not
// depend on the lattice's cell size, so that trigger is corrected — deviation
// justified in the handoff.)

import Foundation
import simd
import TopOptKit

/// Where a demand field came from — shown as provenance next to Auto density
/// ("auto must never silently mean uniform" needs the user to see WHAT guides it).
public enum LatticeFieldProvenance: Equatable, Sendable {
    /// A solid-part sim run from this page, at `date`, resolution `resolution`.
    case solidSim(date: Date, resolution: Int)
    /// A finished run's own per-variant field (the variants entry point).
    case variant(runName: String, variantIndex: Int, date: Date?)

    /// The one-line provenance label ("Solid-part sim · Fast (64³) · 2 min ago").
    public func label(now: Date = Date()) -> String {
        switch self {
        case .solidSim(let date, let res):
            return "Solid-part sim · \(res)³ · \(Self.age(from: date, to: now))"
        case .variant(let name, let idx, let date):
            let age = date.map { " · \(Self.age(from: $0, to: now))" } ?? ""
            return "Run \(name) · variant \(idx + 1)\(age)"
        }
    }

    static func age(from: Date, to: Date) -> String {
        let s = max(0, to.timeIntervalSince(from))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}

/// A demand field + its grid — the exact metadata the SDF preview's demand
/// grading consumes, decoupled from where it came from.
public struct LatticeDemandField: Equatable, Sendable {
    public let vonMises: [Float]
    public let nx: Int, ny: Int, nz: Int
    public let origin: SIMD3<Double>
    public let spacingMM: Double
    public let provenance: LatticeFieldProvenance

    public init(vonMises: [Float], nx: Int, ny: Int, nz: Int,
                origin: SIMD3<Double>, spacingMM: Double,
                provenance: LatticeFieldProvenance) {
        self.vonMises = vonMises
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.origin = origin
        self.spacingMM = spacingMM
        self.provenance = provenance
    }
}

/// The everything-that-determines-the-field fingerprint. Pure + Equatable so the
/// staleness rule is headlessly testable: same inputs ⇒ fresh, any change ⇒ stale.
public struct LatticeSimFingerprint: Equatable, Sendable {
    public let modelPath: String
    public let material: String
    public let resolution: Int
    public let anchorFaceIDs: [Int]
    public let loadGroups: [TopOptKit.LoadGroupSpec]

    public init(modelPath: String, material: String, resolution: Int,
                anchorFaceIDs: [Int], loadGroups: [TopOptKit.LoadGroupSpec]) {
        self.modelPath = modelPath
        self.material = material
        self.resolution = resolution
        self.anchorFaceIDs = anchorFaceIDs
        self.loadGroups = loadGroups
    }
}

/// The RUN SIM state machine. `@MainActor` ObservableObject the page observes;
/// the solve itself runs detached (the SmoothingModel.live pattern). The bridge
/// call has no cancellation flag, so Cancel ABANDONS the result (the state
/// returns to idle and a late result is discarded) — the solve finishes in the
/// background; this is stated in the handoff, not hidden.
@MainActor
public final class LatticeSimModel: ObservableObject {

    /// The sim inputs, resolved by the caller (the page) from the project.
    public struct Context: Sendable {
        public let modelPath: String
        public let material: String
        public let materialsPath: String
        public let rulesPath: String
        /// The COARSE sim resolution — deliberately the fast tier, not the run's.
        public let resolution: Int
        public let anchorFaceIDs: [Int]
        public let loadGroups: [TopOptKit.LoadGroupSpec]
        public let buildDirection: SIMD3<Double>

        public init(modelPath: String, material: String, materialsPath: String,
                    rulesPath: String, resolution: Int, anchorFaceIDs: [Int],
                    loadGroups: [TopOptKit.LoadGroupSpec],
                    buildDirection: SIMD3<Double> = SIMD3(0, 0, 1)) {
            self.modelPath = modelPath
            self.material = material
            self.materialsPath = materialsPath
            self.rulesPath = rulesPath
            self.resolution = resolution
            self.anchorFaceIDs = anchorFaceIDs
            self.loadGroups = loadGroups
            self.buildDirection = buildDirection
        }

        public var fingerprint: LatticeSimFingerprint {
            LatticeSimFingerprint(modelPath: modelPath, material: material,
                                  resolution: resolution,
                                  anchorFaceIDs: anchorFaceIDs, loadGroups: loadGroups)
        }
    }

    /// The headline numbers the sim-complete banner shows.
    public struct Summary: Equatable, Sendable {
        public let maxDisplacementMM: Double
        public let maxStressMPa: Double
        /// Worst-case strength margin (the certified safety number).
        public let safety: Double
        public let date: Date
        public let resolution: Int
    }

    public enum Phase: Equatable {
        case idle
        case running
        case complete(Summary)
        /// The solve never finished or hard-failed — no field, no numbers.
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// The completed sim's field (nil unless `phase == .complete`).
    @Published public private(set) var field: LatticeDemandField?
    /// The fingerprint the field was computed under.
    @Published public private(set) var fingerprint: LatticeSimFingerprint?

    /// The injectable solver seam — the REAL one calls
    /// `TopOptKit.analyzeSolidLoadCase`; tests inject a stub so every phase is
    /// drivable headlessly (bar B9). Runs OFF the main actor.
    public typealias Runner = @Sendable (Context) throws -> TopOptKit.SimAnalysisResult
    private let runner: Runner
    private var generation = 0

    public init(runner: @escaping Runner = { ctx in
        try TopOptKit.analyzeSolidLoadCase(
            modelPath: ctx.modelPath, material: ctx.material,
            materialsPath: ctx.materialsPath, rulesPath: ctx.rulesPath,
            resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
            loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection)
    }) {
        self.runner = runner
    }

    /// Whether a completed field is STALE against the current inputs — any change
    /// to model / material / resolution / load case invalidates it.
    public func isStale(against current: LatticeSimFingerprint) -> Bool {
        guard case .complete = phase, let fp = fingerprint else { return false }
        return fp != current
    }

    /// Kick off ONE sim. No-op while one is already running (B5's "one sim").
    public func run(_ ctx: Context, now: Date = Date()) {
        guard phase != .running else { return }
        phase = .running
        generation += 1
        let gen = generation
        let runner = self.runner
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<TopOptKit.SimAnalysisResult, Error> =
                Result { try runner(ctx) }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }  // cancelled/superseded
                switch outcome {
                case .failure(let e):
                    self.phase = .failed(String(describing: e))
                case .success(let r) where r.nonConvergent:
                    // The honesty boundary: a non-convergent solve has NO numbers.
                    self.phase = .failed("The sim could not converge at this resolution — no field was produced.")
                case .success(let r):
                    let summary = Summary(maxDisplacementMM: r.maxDisplacementMM,
                                          maxStressMPa: r.maxStressMPa,
                                          safety: r.marginWorstCase,
                                          date: now, resolution: ctx.resolution)
                    self.field = LatticeDemandField(
                        vonMises: r.vonMisesField, nx: r.gridNX, ny: r.gridNY,
                        nz: r.gridNZ, origin: r.gridOrigin, spacingMM: r.spacingMM,
                        provenance: .solidSim(date: now, resolution: ctx.resolution))
                    self.fingerprint = ctx.fingerprint
                    self.phase = .complete(summary)
                }
            }
        }
    }

    /// Cancel: abandon the in-flight result (the bridge solve has no cancel flag —
    /// it finishes in the background and is discarded on arrival).
    public func cancel() {
        guard phase == .running else { return }
        generation += 1
        phase = .idle
    }

    /// Drop a completed/failed sim (e.g. when the part itself is replaced).
    public func reset() {
        generation += 1
        phase = .idle
        field = nil
        fingerprint = nil
    }
}
