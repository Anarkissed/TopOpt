// FlexibleKit+SquishSteps — the squish solved in STEPS (task 2026-09-29-flexible-screens, round 5
// batch N; maintainer, asked about batch G's fold cut: "Is there no way to fold realistically
// instead?").
//
// ★ THE SAME PROBLEM, SOLVED AGAIN AND AGAIN. `FlexibleScene.squishSteps` builds the group's
// problem ONCE — the grid, the loads by column pressure, the rests, the pins and the inertia relief
// of `squishSolve` — and each `step(loadFactor:)` solves it at that multiple of the design force
// with every voxel's modulus the SECANT of core's tested curve at the voxel's OWN principal
// compressive strain (damped fixed-point iterations, each a core MG-CG solve warm-started from the
// last). Skin and solid voxels keep their moduli. One session, used from ONE thread at a time (the
// sims' serial queue); it ends when this object goes.
//
// Plain values in, plain values out; a solve that fails is a VALUE (`ok == false`, core's words).

import Foundation
import TopOptBridge

/// Past the curves' last tested strain (FlexibleBridge.hpp, FlexSquishStepOptions).
public enum FlexSquishPastData: Int32, Sendable {
    /// The curve held at its last tested secant — no stiffening (the red control: what the tested
    /// data alone says).
    case heldAtLastTest = 0
    /// Densification (Gibson & Ashby): σ → ∞ at ε_D = 1 − 1.4 ρ, joined to the curve at its end.
    case densifies = 1
}

/// One group's stepped solve. NOT thread-safe: one thread at a time.
public final class FlexSquishSteps: @unchecked Sendable {
    /// The setup's receipt (the loads, the rests, the grid) — `ok` false: no session (see failure).
    public let setup: FlexSquishSolutionInfo
    let session: Int64
    public private(set) var ended = false

    init(setup: FlexSquishSolutionInfo) {
        self.setup = setup
        session = setup.session
    }

    deinit { end() }

    /// One step: the problem at `loadFactor` × the design force, up to `iterations` secant solves
    /// until max|Δu| ≤ `tolerance` · max|u|. The field is RAW (mm at that load), extended like the
    /// linear solve's.
    public func step(loadFactor: Double, iterations: Int, tolerance: Double) throws -> FlexSquishSolutionInfo {
        guard session > 0, !ended else { throw TopOptError(message: "the squish steps' session has ended") }
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_squish_step(session, loadFactor, Int32(iterations), tolerance, &err)
        try FlexConv.check(err)
        return FlexSquishConv.info(s)
    }

    /// Frees the session (idempotent).
    public func end() {
        guard !ended else { return }
        ended = true
        if session > 0 { topoptbridge.flexible_squish_step_end(session) }
    }

    /// TESTS: sessions alive in the bridge (a cancelled refine must leave none).
    public static var liveSessions: Int { Int(topoptbridge.flexible_squish_live_sessions()) }
}

extension FlexibleScene {
    /// Build `r`'s problem once for the stepped solve (seconds at most — OFF the main thread).
    public func squishSteps(_ r: FlexSquishRequestInfo, pastData: FlexSquishPastData = .densifies,
                            densification: Double = 1.4) throws -> FlexSquishSteps {
        let q = squishRequest(r)
        var o = topoptbridge.FlexSquishStepOptions()
        o.law_past_data = pastData.rawValue
        o.densification_coeff = densification
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_scene_squish_step_begin(handle, q, o, &err)
        try FlexConv.check(err)
        return FlexSquishSteps(setup: FlexSquishConv.info(s))
    }
}

extension FlexibleCore {
    /// One voxel's modulus by the STEPPED law (MPa) at its own strain: core's curve up to its last
    /// tested strain, then `pastData`.
    public static func squishStepModulus(law: FlexSquishLawInfo, rho: Double, strain: Double, skinFrac: Double = 0,
                                         pastData: FlexSquishPastData = .densifies, densification: Double = 1.4) throws -> Double {
        var o = topoptbridge.FlexSquishStepOptions()
        o.law_past_data = pastData.rawValue
        o.densification_coeff = densification
        var err = topoptbridge.BridgeError()
        let e = topoptbridge.flexible_squish_step_modulus(FlexSquishConv.law(law), rho, strain, skinFrac, o, &err)
        try FlexConv.check(err)
        return e
    }
}
