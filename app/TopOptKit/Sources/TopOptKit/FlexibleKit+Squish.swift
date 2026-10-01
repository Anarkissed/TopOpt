// FlexibleKit+Squish — the squish as ONE 3D displacement field per squeeze group (task
// 2026-09-29-flexible-screens, round 5 batch G; maintainer: "is there a way to ensure that the
// squish sim also squeezes out the sides of the object? I'd like it to actually bend and move
// and squish like it would in real life").
//
// ★ CORE'S SOLVER, THE APP'S SETUP. `FlexibleScene.squishSolve` runs core's existing
// heterogeneous matrix-free MG-CG (fea_solve_mgcg_matfree) on the scene's own voxel grid
// (coarsened by `FlexibleCore.squishCoarsen`), each voxel's modulus the secant of core's tested
// squish curve at its own density (`FlexibleCore.squishModulus`). The loads, the rests and the
// 3-2-1 anchoring of a squeeze nothing rests against are the app's (flexible_squish_fe.cpp).
// Linear small-strain physics — a DISPLAY field, scaled by the app to core's squish.
//
// Plain values in, plain values out. Malformed input throws (core's words); a solve that fails
// (the deadline, a non-convergence) is a VALUE: `ok == false` with the reason.

import Foundation
import TopOptBridge

/// One pressed face of the squeeze group: its region, frame rotation and core's pressure per
/// column (parallel to the stack's columns: a stamp where it presses, else weight ÷ footprint).
public struct FlexSquishPressInfo: Equatable, Sendable {
    public var face: Int
    public var rotation: Int
    public var columnPressureMPa: [Double]
    public init(face: Int, rotation: Int, columnPressureMPa: [Double]) {
        self.face = face; self.rotation = rotation; self.columnPressureMPa = columnPressureMPa
    }
}

/// The per-voxel stiffness law's inputs: the filament's curve set, or the shape-only law.
public struct FlexSquishLawInfo: Equatable, Sendable {
    public var materialsPath: String
    public var materialID: String
    public var topology: String
    public var tempC: Double
    public var shapeOnly: Bool
    public init(materialsPath: String, materialID: String, topology: String, tempC: Double, shapeOnly: Bool) {
        self.materialsPath = materialsPath; self.materialID = materialID; self.topology = topology
        self.tempC = tempC; self.shapeOnly = shapeOnly
    }
}

/// One squeeze group's sim, as the bridge takes it. The per-voxel arrays are on the SCENE's
/// grid (x fastest).
public struct FlexSquishRequestInfo: Sendable {
    public var pressed: [FlexSquishPressInfo]
    public var restingIDs: [Int]
    /// < 0: not lattice (solid); else the printed core ρ.
    public var rho: [Float]
    /// The strain of the voxel's column under THIS group (0 = no stack of this group).
    public var strainOp: [Float]
    /// The share of the voxel inside the skin, 0…1.
    public var skinFrac: [Float]
    public var law: FlexSquishLawInfo
    public var poisson: Double
    public var tolerance: Double
    public var deadlineMS: Double
    /// 0 = the rule (`FlexibleCore.squishCoarsen`).
    public var coarsen: Int
    /// TESTS ONLY — the red controls (FlexibleBridge.hpp lists the bits). The app sends 0.
    public var control: Int
    public init(pressed: [FlexSquishPressInfo], restingIDs: [Int], rho: [Float], strainOp: [Float], skinFrac: [Float],
                law: FlexSquishLawInfo, poisson: Double = 0.3, tolerance: Double = 1e-4, deadlineMS: Double = 20_000,
                coarsen: Int = 0, control: Int = 0) {
        self.pressed = pressed; self.restingIDs = restingIDs; self.rho = rho; self.strainOp = strainOp
        self.skinFrac = skinFrac; self.law = law; self.poisson = poisson; self.tolerance = tolerance
        self.deadlineMS = deadlineMS; self.coarsen = coarsen; self.control = control
    }
}

/// The raw field (mm, uncalibrated) on the FE grid's NODES, and the solve's receipt.
public struct FlexSquishSolutionInfo: Sendable {
    public let ok: Bool
    public let failure: String
    /// "rest" | "exit" | "free" | "patch" (a test control).
    public let bcMode: String
    /// The rigid modes the rests left free (6: nothing rests) — each relieved and pinned by one DOF.
    public let freeModes: Int
    public let coarsen: Int
    /// Node counts.
    public let nx: Int, ny: Int, nz: Int
    public let spacing: Double
    /// Node (0, 0, 0) — the grid's corner.
    public let origin: SIMD3<Double>
    /// 3 per node, mm, RAW (before the app's calibration), extended to every node.
    public let u: [Float]
    /// Per node: a solid element owns it.
    public let solved: [Bool]
    public let elements: Int, iterations: Int, mgLevels: Int
    /// The solve's iteration cap: a work budget, elements × iterations (never under 600).
    public let maxIterations: Int
    public let usedMultigrid: Bool
    public let residual: Double, setupMS: Double, solveMS: Double
    /// Waiting for another sim to leave the solver (the deadline starts after it).
    public let waitMS: Double
    public let eMinMPa: Double, eMaxMPa: Double
    public let appliedForceN: SIMD3<Double>
    public let appliedForceAbsN: Double
    public let heldReactionN: SIMD3<Double>
    public let anchorReactionN: Double
    public let threadsBefore: Int, threadsDuring: Int, threadsAfter: Int
    /// Core's GenEO deflation before / during / after the solve (a topology run leaves it armed;
    /// the posture pins it off for the sim), and Krylov recycling during it.
    public let geneoBefore: Bool, geneoDuring: Bool, geneoAfter: Bool, recyclingDuring: Bool
    /// Per press: its nodal loads (node, N) — the tests' receipt — the force it was normalised
    /// to (Σ p · column area) and the raw Σ p · projected area before normalising.
    public let pressLoads: [[(node: Int, force: SIMD3<Double>)]]
    public let pressForceN: [Double]
    public let pressRawForceN: [Double]
    public let heldNodes: [Int]
    /// 3 · node + component of every Dirichlet DOF.
    public let pinnedDOFs: [Int]
    public let restingMissing: [Int]
    /// Far ends of pressed stacks held along their normal beside the rests (their anvils).
    public var farAnvils: Int = 0
    /// ★ BATCH M: per FE element ((nx−1)(ny−1)(nz−1), x fastest), the modulus it was solved with
    /// (MPa; relative units under shape only), 0 where no solid — the stress view's C.
    public var elementE: [Float] = []
    /// ★ BATCH N: the STEPPED solve's receipt (a linear solve: one solve at load factor 1).
    public var session: Int64 = 0
    public var loadFactor = 1.0
    public var fixedPointIterations = 0
    public var fixedPointConverged = false
    public var fixedPointChange = 0.0
    public var cgIterationsTotal = 0
    public var mgSkipped = false
    public var stepMS = 0.0
    /// The solid elements' principal compressive strain (the curves' axis) at this field.
    public var strainP50 = 0.0, strainP99 = 0.0, strainMax = 0.0
    /// Elements past the curves' last tested strain.
    public var beyondDataElements = 0
    /// Elements the last iterate updated by their STRESS (where the curve stiffens).
    public var stressUpdates = 0

    /// Node (a, b, c)'s index (x fastest).
    public func node(_ a: Int, _ b: Int, _ c: Int) -> Int { (c * ny + b) * nx + a }
    public func position(_ n: Int) -> SIMD3<Double> {
        let a = n % nx, b = (n / nx) % ny, c = n / (nx * ny)
        return origin + SIMD3(Double(a), Double(b), Double(c)) * spacing
    }
    public func displacement(_ n: Int) -> SIMD3<Double> {
        SIMD3(Double(u[3 * n]), Double(u[3 * n + 1]), Double(u[3 * n + 2]))
    }
}

extension FlexibleScene {
    /// One squeeze group's squish field (core's solver; seconds on a large part — call it OFF the
    /// main thread and off any actor that serialises design calls).
    public func squishSolve(_ r: FlexSquishRequestInfo) throws -> FlexSquishSolutionInfo {
        let q = squishRequest(r)
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.flexible_scene_squish_solve(handle, q, &err)
        try FlexConv.check(err)
        return FlexSquishConv.info(s)
    }

    /// The bridge's request for `r` (★ BATCH N: shared by the linear solve and the stepped one).
    func squishRequest(_ r: FlexSquishRequestInfo) -> topoptbridge.FlexSquishRequest {
        var q = topoptbridge.FlexSquishRequest()
        var presses = topoptbridge.FlexSquishPresses()
        for p in r.pressed {
            var x = topoptbridge.FlexSquishPress()
            x.face_region_id = Int32(p.face)
            x.rotation_deg = Int32(p.rotation)
            x.column_pressure_mpa = FlexConv.d(p.columnPressureMPa)
            presses.push_back(x)
        }
        q.pressed = presses
        q.resting_region_ids = FlexConv.i(r.restingIDs)
        q.rho = FlexSquishConv.f(r.rho)
        q.strain_op = FlexSquishConv.f(r.strainOp)
        q.skin_frac = FlexSquishConv.f(r.skinFrac)
        q.law = FlexSquishConv.law(r.law)
        q.poisson = r.poisson
        q.tolerance = r.tolerance
        q.deadline_ms = r.deadlineMS
        q.coarsen = Int32(r.coarsen)
        q.control = Int32(r.control)
        return q
    }
}

extension FlexSquishConv {
    /// The bridge's solution as plain values.
    static func info(_ s: topoptbridge.FlexSquishSolution) -> FlexSquishSolutionInfo {
        // ★ hoist every vector ONCE (a C++ member read in a Swift loop copies the whole vector)
        let u = Array(s.u), solved = Array(s.solved).map { $0 != 0 }
        let offs = Array(s.press_load_offsets).map { Int($0) }
        let nodes = Array(s.press_load_nodes).map { Int($0) }
        let xyz = Array(s.press_load_xyz)
        var loads: [[(node: Int, force: SIMD3<Double>)]] = []
        if offs.count >= 2 {
            for k in 0..<(offs.count - 1) {
                loads.append((offs[k]..<offs[k + 1]).map { i in
                    (nodes[i], SIMD3(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]))
                })
            }
        }
        var info = FlexSquishSolutionInfo(
            ok: s.ok, failure: String(s.failure), bcMode: String(s.bc_mode), freeModes: Int(s.free_modes), coarsen: Int(s.coarsen),
            nx: Int(s.nx), ny: Int(s.ny), nz: Int(s.nz), spacing: s.spacing, origin: FlexConv.v3(s.origin),
            u: u, solved: solved, elements: Int(s.elements), iterations: Int(s.iterations), mgLevels: Int(s.mg_levels), maxIterations: Int(s.max_iterations),
            usedMultigrid: s.used_multigrid, residual: s.residual, setupMS: s.setup_ms, solveMS: s.solve_ms, waitMS: s.wait_ms,
            eMinMPa: s.e_min_mpa, eMaxMPa: s.e_max_mpa, appliedForceN: FlexConv.v3(s.applied_force_n),
            appliedForceAbsN: s.applied_force_abs_n, heldReactionN: FlexConv.v3(s.held_reaction_n),
            anchorReactionN: s.anchor_reaction_n, threadsBefore: Int(s.threads_before),
            threadsDuring: Int(s.threads_during), threadsAfter: Int(s.threads_after),
            geneoBefore: s.geneo_before, geneoDuring: s.geneo_during, geneoAfter: s.geneo_after,
            recyclingDuring: s.recycling_during,
            pressLoads: loads, pressForceN: Array(s.press_force_n), pressRawForceN: Array(s.press_raw_force_n),
            heldNodes: Array(s.held_nodes).map { Int($0) }, pinnedDOFs: Array(s.pinned_dofs).map { Int($0) },
            restingMissing: Array(s.resting_missing).map { Int($0) }, farAnvils: Int(s.far_anvils))
        info.elementE = Array(s.element_e)
        info.session = s.session
        info.loadFactor = s.load_factor
        info.fixedPointIterations = Int(s.fixed_point_iterations)
        info.fixedPointConverged = s.fixed_point_converged
        info.fixedPointChange = s.fixed_point_change
        info.cgIterationsTotal = Int(s.cg_iterations_total)
        info.mgSkipped = s.mg_skipped
        info.stepMS = s.step_ms
        info.strainP50 = s.strain_p50
        info.strainP99 = s.strain_p99
        info.strainMax = s.strain_max
        info.beyondDataElements = Int(s.beyond_data_elements)
        info.stressUpdates = Int(s.stress_updates)
        return info
    }
}

extension FlexibleCore {
    /// One voxel's modulus by the squish sim's law (MPa; relative units under shape only):
    /// the SECANT of core's curve at clamp(strain, 0.02, the strain limit) — 0.05 (the initial
    /// modulus) when `strain` is 0 —, mixed with the solid modulus by the skin share; ρ < 0 = solid.
    public static func squishModulus(law: FlexSquishLawInfo, rho: Double, strain: Double, skinFrac: Double,
                                     control: Int = 0) throws -> Double {
        var err = topoptbridge.BridgeError()
        let e = topoptbridge.flexible_squish_modulus(FlexSquishConv.law(law), rho, strain, skinFrac, Int32(control), &err)
        try FlexConv.check(err)
        return e
    }

    /// The FE grid's coarsening factor for an nx × ny × nz scene grid (core-side rule).
    public static func squishCoarsen(nx: Int, ny: Int, nz: Int) -> Int {
        Int(topoptbridge.flexible_squish_coarsen(Int32(nx), Int32(ny), Int32(nz)))
    }

    /// TESTS: arm core's GenEO deflation process-wide, as a topology run leaves it. Returns the
    /// previous setting.
    @discardableResult
    public static func squishSetGeneoForTests(_ enable: Bool) -> Bool {
        topoptbridge.flexible_squish_set_geneo_for_tests(enable)
    }
}

enum FlexSquishConv {
    static func f(_ v: [Float]) -> topoptbridge.FlexFloats {
        var o = topoptbridge.FlexFloats()
        o.reserve(v.count)
        for x in v { o.push_back(x) }
        return o
    }
    static func law(_ l: FlexSquishLawInfo) -> topoptbridge.FlexSquishLaw {
        var o = topoptbridge.FlexSquishLaw()
        o.materials_path = std.string(l.materialsPath)
        o.material_id = std.string(l.materialID)
        o.topology = std.string(l.topology)
        o.temp_c = l.tempC
        o.shape_only = l.shapeOnly
        return o
    }
}
