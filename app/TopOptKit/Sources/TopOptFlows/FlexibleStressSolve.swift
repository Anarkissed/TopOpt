// FlexibleStressSolve — the solid part's FEA the main Flexible page's Stress view shows (task
// 2026-09-29-flexible-screens, round 3 batch C verification; item T).
//
// ★ ONLY THE REGIONS THE LOAD CASE REACHES. `makeLatticeSimContext` sends EVERY face region.
// His project carries a stale one nothing uses ('Face 23 & like it', add [23], on the 6-face
// pad), and core refused the whole solve on it ("face id 23 out of range") — so Stress never
// appeared, and nothing said why. The Flexible solve sends the anchors' and loads' regions and
// their ancestors only (a sector is resolved against its parent): `FlexibleStressContext.reached`.
//
// ★ SAID, NEVER SILENT. The solve's state is ONE published value on FlexibleMainStage
// (`stressState`, from the sim's own phase): running, ready, failed (core's words behind the
// (i); "Couldn't simulate" + Retry on the Stress legend), or blocked before it starts — no
// anchor, no load — where the one line says exactly what to add and where.
//
// ★ ONE SHAPE, TWO HOOKS. The workspace hands `FlexibleStressSolver(app: model, sim: latticeSim)`
// to the view toggles (H5') and to Settings' Save & Exit (H2), so the solver is in hand on the
// very first Exit (it used to arrive only once the toggles had rendered). It never goes through
// `startStressSolveIfNeeded`'s octet gate (lattice.enabled && needsStressSolve — a fresh
// Flexible part never passes it; LatticeSimSolveTriggerTests reads its first 900 characters).

import Combine
import Foundation
import TopOptKit

public enum FlexibleStressContext {
    /// `ctx` with only the face regions its anchors and loads reach, and every ancestor of
    /// those. Everything else — the file, the material, the faces, the forces — is unchanged.
    public static func reached(_ ctx: LatticeSimModel.Context) -> LatticeSimModel.Context {
        var byID: [Int: TopOptKit.FaceRegionSpec] = [:]
        for r in ctx.faceRegions where byID[r.id] == nil { byID[r.id] = r }
        var want = Set(ctx.anchorRegionIDs + ctx.loadGroups.flatMap(\.regionIDs))
        var frontier = Array(want)
        while let id = frontier.popLast() {
            guard let r = byID[id], r.parentID >= 0, !want.contains(r.parentID) else { continue }
            want.insert(r.parentID)
            frontier.append(r.parentID)
        }
        return LatticeSimModel.Context(modelPath: ctx.modelPath, material: ctx.material,
                                       materialsPath: ctx.materialsPath, rulesPath: ctx.rulesPath,
                                       resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                                       loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                                       faceRegions: ctx.faceRegions.filter { want.contains($0.id) },
                                       anchorRegionIDs: ctx.anchorRegionIDs)
    }

    /// What stops the solve before it starts, as the Stress legend's one line — nil when it can
    /// run. A solid part with nothing holding it, or nothing pressing it, has no stress to show.
    public static func blocker(_ ctx: LatticeSimModel.Context?) -> String? {
        guard let ctx else { return noFile }
        if ctx.anchorFaceIDs.isEmpty && ctx.anchorRegionIDs.isEmpty { return noAnchor }
        if ctx.loadGroups.isEmpty { return noLoad }
        return nil
    }
    public static let noFile = "Stress needs the part's file"
    public static let noAnchor = "Stress needs an anchor on Topology"
    public static let noLoad = "Stress needs a load on Topology"
}

/// What the Stress view is doing, in one value (the legend and the button read it).
public enum FlexibleStressState: Equatable, Sendable {
    /// Nothing asked yet.
    case idle
    case running
    /// A field for the current inputs is in hand.
    case ready
    /// Core refused or could not converge — its words (behind the legend's (i)).
    case failed(String)
    /// It could not start: the one line says what to add (FlexibleStressContext.blocker).
    case blocked(String)

    public var isRunning: Bool { self == .running }
    /// The legend's one line when there is no field to draw.
    public var line: String? {
        switch self {
        case .idle: return "No stress yet"
        case .running: return "Simulating…"
        case .ready: return nil
        case .failed: return "Couldn't simulate"
        case .blocked(let l): return l
        }
    }
    /// A Retry is offered after a refusal (an edit elsewhere may have fixed it) or when nothing
    /// was asked yet; a blocker's fix is on Topology, not here.
    public var retries: Bool {
        switch self {
        case .failed, .idle: return true
        default: return false
        }
    }
}

/// The workspace's solve for the Stress view (H5', H2): the solid part, the main page's loads,
/// the regions they reach — run once, never twice, never while one runs.
@MainActor
public struct FlexibleStressSolver {
    public let sim: LatticeSimModel
    let context: () -> LatticeSimModel.Context?

    public init(app: AppModel, sim: LatticeSimModel) {
        self.sim = sim
        self.context = { [weak app] in app?.makeLatticeSimContext().map(FlexibleStressContext.reached) }
    }
    /// Tests: any context.
    init(sim: LatticeSimModel, context: @escaping () -> LatticeSimModel.Context?) {
        self.sim = sim
        self.context = context
    }

    public enum Outcome: Equatable, Sendable {
        case started, running, current
        case blocked(String)
    }

    /// Run the solve when there is no field for these inputs (or the last one failed) and none is
    /// running (FlexibleStressTrigger over the sim's own fingerprint).
    @discardableResult
    public func start() -> Outcome {
        let ctx = context()
        if let b = FlexibleStressContext.blocker(ctx) { return .blocked(b) }
        guard let ctx else { return .blocked(FlexibleStressContext.noFile) }
        if sim.phase == .running { return .running }
        let failed: Bool = { if case .failed = sim.phase { return true } else { return false } }()
        guard FlexibleStressTrigger.shouldRun(hasField: sim.field != nil && !failed,
                                              stale: sim.isStale(against: ctx.fingerprint), running: false) else { return .current }
        sim.run(ctx)
        return .started
    }
}
