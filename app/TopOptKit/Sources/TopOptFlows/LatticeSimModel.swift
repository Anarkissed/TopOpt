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
    /// ★★★ THE FULL CAUCHY TENSOR, 6 per voxel in core's Voigt order — the input the
    /// ORGANIC tracer eigen-decomposes. The stage's own solve has always returned it;
    /// this field simply never carried it, which is the whole reason organic was called
    /// unpreviewable. Empty when the solve did not produce one (a remote run does not
    /// send it over the wire).
    public let stressTensor: [Double]
    public let nx: Int, ny: Int, nz: Int
    public let origin: SIMD3<Double>
    public let spacingMM: Double
    public let provenance: LatticeFieldProvenance

    public init(vonMises: [Float], stressTensor: [Double] = [],
                nx: Int, ny: Int, nz: Int,
                origin: SIMD3<Double>, spacingMM: Double,
                provenance: LatticeFieldProvenance) {
        self.vonMises = vonMises
        self.stressTensor = stressTensor
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
    /// ★ the region layer, so a region edit re-solves (2026-09-05)
    public var anchorRegionIDs: [Int] = []
    public var regionSignature: String = ""

    public init(modelPath: String, material: String, resolution: Int,
                anchorFaceIDs: [Int], loadGroups: [TopOptKit.LoadGroupSpec],
                anchorRegionIDs: [Int] = [], regionSignature: String = "") {
        self.modelPath = modelPath
        self.material = material
        self.resolution = resolution
        self.anchorFaceIDs = anchorFaceIDs
        self.loadGroups = loadGroups
        self.anchorRegionIDs = anchorRegionIDs
        self.regionSignature = regionSignature
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
        /// ★ THE REGION LAYER (2026-09-05) — the same regions the run request sends,
        /// so a load painted as a region reaches the stage's solve too.
        public let faceRegions: [TopOptKit.FaceRegionSpec]
        public let anchorRegionIDs: [Int]
        /// ★ 11-21: the load scenario this solve is (its name, said if it cannot be solved); nil: the part has one.
        public var scenarioName: String? = nil

        public init(modelPath: String, material: String, materialsPath: String,
                    rulesPath: String, resolution: Int, anchorFaceIDs: [Int],
                    loadGroups: [TopOptKit.LoadGroupSpec],
                    buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
                    faceRegions: [TopOptKit.FaceRegionSpec] = [],
                    anchorRegionIDs: [Int] = []) {
            self.modelPath = modelPath
            self.material = material
            self.materialsPath = materialsPath
            self.rulesPath = rulesPath
            self.resolution = resolution
            self.anchorFaceIDs = anchorFaceIDs
            self.loadGroups = loadGroups
            self.buildDirection = buildDirection
            self.faceRegions = faceRegions
            self.anchorRegionIDs = anchorRegionIDs
        }

        public var fingerprint: LatticeSimFingerprint {
            LatticeSimFingerprint(modelPath: modelPath, material: material,
                                  resolution: resolution,
                                  anchorFaceIDs: anchorFaceIDs, loadGroups: loadGroups,
                                  anchorRegionIDs: anchorRegionIDs,
                                  regionSignature: faceRegions.map { "\($0.id):\($0.parentID):\($0.addFaces.count):\($0.removeFaces.count):\($0.cuts.count)" }.joined(separator: "|"))
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
    /// ★ 11-21 (his 2040 stand: one scenario could not be solved and sank them all): the scenarios the last check could not
    /// solve, by name. The field is the worst of the others.
    public private(set) var unsolved: [String] = []
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

    public init(runner: Runner? = nil) {
        self.runner = runner ?? Self.testRunner ?? { ctx in
            try TopOptKit.analyzeSolidLoadCase(
                modelPath: ctx.modelPath, material: ctx.material,
                materialsPath: ctx.materialsPath, rulesPath: ctx.rulesPath,
                resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                faceRegions: ctx.faceRegions, anchorRegionIDs: ctx.anchorRegionIDs)
        }
    }

    /// Test seam (hosted tests): the solver a page's own model is made with while set — nil (always, in the app) is core's.
    public static var testRunner: Runner?

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
                Result { try FlexibleCoreGate.whileInCore { try runner(ctx) } }   // Flexible (PR #362, batch G): core's matrix-free pool held while this solve is IN it (a cancelled one too) — no squish sim enters beside it
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
                        vonMises: r.vonMisesField, stressTensor: r.stressTensorField,
                        nx: r.gridNX, ny: r.gridNY,
                        nz: r.gridNZ, origin: r.gridOrigin, spacingMM: r.spacingMM,
                        provenance: .solidSim(date: now, resolution: ctx.resolution))
                    self.fingerprint = ctx.fingerprint
                    self.phase = .complete(summary)
                }
            }
        }
    }

    /// ★ INSTALL 2, MANUAL CONTROL 6: one solve per load scenario switched on for the lattice, and the field the worst of them
    /// at each place (the highest von Mises, with that solve's own stress there; unweighted — LatticeReview's design). One
    /// context: exactly `run(_:)`. The headline numbers are the worst of the solves'.
    public func run(_ ctxs: [Context], now: Date = Date()) {
        guard let first = ctxs.first else { return }
        guard ctxs.count > 1 else { run(first, now: now); return }
        guard phase != .running else { return }
        phase = .running
        generation += 1
        let gen = generation
        let runner = self.runner
        let fp = Self.fingerprint(of: ctxs)
        Task.detached(priority: .userInitiated) { [weak self] in
            // ★ 11-21: each scenario on its own — one that cannot be solved no longer sinks the others
            let each: [Result<TopOptKit.SimAnalysisResult, Error>] = ctxs.map { c in
                Result { try FlexibleCoreGate.whileInCore { try runner(c) } }
            }
            let (solved, unsolved) = Self.split(each, names: ctxs.map { $0.scenarioName ?? "a load scenario" })
            let outcome: Result<[TopOptKit.SimAnalysisResult], Error> = solved.isEmpty
                ? .failure(each.compactMap { if case .failure(let e) = $0 { return e } else { return nil } }.first
                           ?? TopOptError(message: "The sim could not converge at this resolution — no field was produced."))
                : .success(solved)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }  // cancelled/superseded
                self.unsolved = solved.isEmpty ? [] : unsolved
                switch outcome {
                case .failure(let e):
                    self.phase = .failed(String(describing: e))
                case .success(let rs):
                    let r = Self.worstOf(rs)
                    let summary = Summary(maxDisplacementMM: r.maxDisplacementMM,
                                          maxStressMPa: r.maxStressMPa,
                                          safety: r.marginWorstCase,
                                          date: now, resolution: first.resolution)
                    self.field = LatticeDemandField(
                        vonMises: r.vonMisesField, stressTensor: r.stressTensorField,
                        nx: r.gridNX, ny: r.gridNY,
                        nz: r.gridNZ, origin: r.gridOrigin, spacingMM: r.spacingMM,
                        provenance: .solidSim(date: now, resolution: first.resolution))
                    self.fingerprint = fp
                    self.phase = .complete(summary)
                }
            }
        }
    }

    /// The solves that gave a field (converged), and the names of those that did not.
    nonisolated static func split(_ each: [Result<TopOptKit.SimAnalysisResult, Error>], names: [String])
        -> (solved: [TopOptKit.SimAnalysisResult], unsolved: [String]) {
        var solved: [TopOptKit.SimAnalysisResult] = [], unsolved: [String] = []
        for (i, r) in each.enumerated() {
            if case .success(let s) = r, !s.nonConvergent { solved.append(s) } else { unsolved.append(names[i]) }
        }
        return (solved, unsolved)
    }

    /// The worst of several solves on one grid: at each voxel the highest von Mises and that solve's own six stresses; the
    /// largest displacement and stress, the smallest margin. Solves on different grids (never at one resolution of one
    /// part): the one with the highest stress, whole.
    nonisolated static func worstOf(_ rs: [TopOptKit.SimAnalysisResult]) -> TopOptKit.SimAnalysisResult {
        guard let a = rs.first else { preconditionFailure("no solve") }
        let n = a.vonMisesField.count
        guard rs.count > 1, rs.allSatisfy({ $0.vonMisesField.count == n && $0.gridNX == a.gridNX && $0.gridNY == a.gridNY
                                            && $0.gridNZ == a.gridNZ }) else {
            return rs.max { $0.maxStressMPa < $1.maxStressMPa } ?? a
        }
        var vm = a.vonMisesField
        var who = [Int](repeating: 0, count: n)
        for (k, r) in rs.enumerated().dropFirst() {
            for i in 0..<n where r.vonMisesField[i] > vm[i] { vm[i] = r.vonMisesField[i]; who[i] = k }
        }
        let tensors = rs.allSatisfy { $0.stressTensorField.count == 6 * n }
        var t = tensors ? a.stressTensorField : []
        if tensors {
            for i in 0..<n where who[i] != 0 {
                for j in 0..<6 { t[6 * i + j] = rs[who[i]].stressTensorField[6 * i + j] }
            }
        }
        return TopOptKit.SimAnalysisResult(
            accepted: rs.allSatisfy(\.accepted), nonConvergent: false,
            maxStressMPa: rs.map(\.maxStressMPa).max() ?? a.maxStressMPa,
            marginWorstCase: rs.map(\.marginWorstCase).min() ?? a.marginWorstCase,
            marginRequired: a.marginRequired,
            maxDisplacementMM: rs.map(\.maxDisplacementMM).max() ?? a.maxDisplacementMM,
            vonMisesField: vm, stressTensorField: t,
            gridNX: a.gridNX, gridNY: a.gridNY, gridNZ: a.gridNZ, gridOrigin: a.gridOrigin, spacingMM: a.spacingMM)
    }

    /// The fingerprint of several solves: one context's own; several, every one's inputs in order.
    public static func fingerprint(of ctxs: [Context]) -> LatticeSimFingerprint? {
        guard let first = ctxs.first else { return nil }
        guard ctxs.count > 1 else { return first.fingerprint }
        let fps = ctxs.map(\.fingerprint)
        return LatticeSimFingerprint(
            modelPath: first.modelPath, material: first.material, resolution: first.resolution,
            anchorFaceIDs: fps.flatMap { $0.anchorFaceIDs + [-1] }, loadGroups: fps.flatMap(\.loadGroups),
            anchorRegionIDs: fps.flatMap { $0.anchorRegionIDs + [-1] },
            regionSignature: fps.map { "\($0.regionSignature)#\($0.anchorFaceIDs.count)/\($0.loadGroups.count)" }.joined(separator: "||"))
    }

    /// Whether a completed field is stale against these solves' inputs.
    public func isStale(against ctxs: [Context]) -> Bool {
        guard let fp = Self.fingerprint(of: ctxs) else { return false }
        return isStale(against: fp)
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
