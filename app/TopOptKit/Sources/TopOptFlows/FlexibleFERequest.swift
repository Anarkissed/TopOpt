// FlexibleFERequest — what the squish sims need, built ONCE per lattice inside its build task
// (task 2026-09-29-flexible-screens, round 5 batch G, §3.2).
//
// ★ BUILT WHERE THE COMBINED FIELD STILL EXISTS. The lattice's combined density field is not
// kept after a build (D-R4-19: ~24 MB at 128³), so the per-voxel arrays the sims read are made
// in the build task beside it: ρ per scene voxel (the combined field's, or where it is 0 —
// unassigned — the builder's flood-filled ρ the walls are drawn with), the skin share (the
// lattice inputs' own skin distance and thickness: every Finish), and per sim (squeeze group) the
// strain each voxel's column takes under THAT group (the nearest of its faces — each pinched half
// its own face —, core's depth over the designed, half where pinched, height). The pressures are
// core's own per column (a stamp where it presses, else weight ÷ footprint); a shape-only lattice
// presses its weight ÷ footprint and is calibrated to the DRAWN depths.
// It is released once its last sim has solved (FlexibleSquishSolver).

import Foundation
import simd
import TopOptKit

public struct FlexibleFERequest: Sendable {
    /// One pressed face as the sims need it.
    public struct Face: Sendable {
        public let key: FlexFaceKey
        public let stack: FlexStackInfo
        public let cuts: [RegionCut]
        /// Core's depth per column, as the heat map shows it (the calibration's target).
        public let depthsMM: [Double?]
        /// The designed height per column (half where a pinch halves it).
        public let heightsMM: [Double]
        public let pinched: [Bool]
        /// Core's pressure per column (MPa).
        public let pressureMPa: [Double]
        public init(key: FlexFaceKey, stack: FlexStackInfo, cuts: [RegionCut], depthsMM: [Double?], heightsMM: [Double],
                    pinched: [Bool], pressureMPa: [Double]) {
            self.key = key; self.stack = stack; self.cuts = cuts; self.depthsMM = depthsMM; self.heightsMM = heightsMM
            self.pinched = pinched; self.pressureMPa = pressureMPa
        }
    }

    /// One squeeze group's sim.
    public struct Sim: Sendable {
        public let id: String
        public let pressed: [FlexSquishPressInfo]
        /// Per scene voxel: its column's strain under this group (0: no stack of the group).
        public let strainOp: [Float]
        public let targets: [FlexibleFEField.Target]
        /// ★ X20b: an edges group core designed for — one target per press (`targets[i]` ↔ `pressed[i]`); solved per press and
        /// shown at core's full design depth (FlexibleFEField.designDepth).
        public var perPress = false
    }

    /// ★ X20b, RED CONTROL only: C1's one scalar for an edges group (k in the band, then the ½ fold cut) — his Edge 12 2.68 mm.
    nonisolated(unsafe) public static var controlOneScalar = false

    public let generation: Int
    /// Per scene voxel: < 0 not lattice; else ρ.
    public let rho: [Float]
    public let skinFrac: [Float]
    public let resting: [Int]
    public let law: FlexSquishLawInfo
    public let sims: [Sim]
    /// ★ U21 · I1 (his answer of 2026-10-21 ~15:35, narrowed 2026-10-22 ~02:50): what holds the part — today's chain whenever a
    /// Rest exists, else Topology's fixed faces (sim only) → the far side (FlexibleHold.request). Every sim of the request shares
    /// it, as it shares `resting`.
    public var hold: FlexibleFEHold = .legacy

    /// ★ U21 · I3 (his answer of 2026-10-21 ~15:35: "I expect the 4 walls around the lattice to hold the lattice up"; his picks
    /// ~15:45: "the linked walls HOLD that lattice"): per sim id, the live linked walls of the lattices that group presses into
    /// (FlexibleStageModel.linkWalls). Display sim only — never in `designInputs`, never in a job (CORE LIST item 10). A link
    /// added / removed re-solves the sims with new walls (FlexibleStageModel.relinkSims), never the lattice.
    public var walls: [String: [FlexHeldWallInfo]] = [:]
    /// ★ U21 · I3: the model's hold epoch these walls belong to (every field solved from this request carries it).
    public var holdEpoch = 0

    /// ★ U21 · I1, RED CONTROL only: every request sends today's chain (rule 0, no anchor) — his l-bracket's Face 2 glued.
    nonisolated(unsafe) public static var controlLegacyHold = false
    /// ★ U21 · I3, RED CONTROL only: the linked walls are not sent (the hold falls to Rests / Topology / the far side).
    nonisolated(unsafe) public static var controlIgnoreLinks = false
    /// ★ U21 · I1, RED CONTROL only (R3): a field whose hold leaves the exits free calibrates on ITSELF (no reference solve).
    nonisolated(unsafe) public static var controlSingleSolveCalibration = false

    /// ★ R7-E3: this request with `sims` in place of its own (the per-voxel arrays shared).
    public func with(sims: [Sim]) -> FlexibleFERequest {
        var r = FlexibleFERequest(generation: generation, rho: rho, skinFrac: skinFrac, resting: resting, law: law, sims: sims)
        r.hold = hold
        r.walls = walls; r.holdEpoch = holdEpoch   // ★ U21 · I3
        return r
    }

    /// ★ U21 · I3: this request with `walls` (per sim id) under hold epoch `epoch`.
    public func with(walls w: [String: [FlexHeldWallInfo]], epoch: Int) -> FlexibleFERequest {
        var r = self
        r.walls = w
        r.holdEpoch = epoch
        return r
    }

    /// ★ U21 · I1 (R3) + I3: the REFERENCE a field whose hold leaves the exits free is calibrated on — today's chain, no linked wall.
    var reference: FlexibleFERequest {
        var r = with(hold: .legacy)
        r.walls = [:]
        return r
    }

    /// ★ U21 · I1: this request with `hold` in place of its own (the reference solve: `.legacy`).
    public func with(hold h: FlexibleFEHold) -> FlexibleFERequest {
        var r = self
        r.hold = h
        return r
    }

    /// ★ MANUAL (M1, his orders of 2026-10-22 ~02:30: "The views become what the app assumes based on your values"): every sim
    /// solved at HIS lattice's own stiffness — no column strain and no core depth to calibrate to (`targets` empty: the solve's own
    /// size, cut only so it never folds, as the interim edge sim). The per-voxel ρ is already his (FlexibleManualField).
    public var manualEstimate: FlexibleFERequest {
        var r = with(sims: sims.map { s in
            Sim(id: s.id, pressed: s.pressed, strainOp: [Float](repeating: 0, count: s.strainOp.count), targets: [])
        })
        r.hold = hold
        return r
    }

    /// ★ R7-E3: the per-voxel arrays alone (no sim) — what an edges group's interim sim is solved on.
    public var base: FlexibleFERequest { with(sims: []) }

    /// ★ R7-E3 (the reviewer's AP ruling (a), the interim sim; his 2026-10-19 notes: "It should absolutely have a simulation going"):
    /// an edges group's sim — each press pushes ALONG its arrow over its whole footprint with its force (core's solver, the current
    /// lattice's stiffness at its own density; no column strain: 0; no core prediction to calibrate to — `targets` empty, so the field
    /// keeps the solve's own size, cut only so it never folds). It never writes a job.
    /// ★ C1: `targets` — core's depths on each press stack once the lattice carries core's design for the group (calibrated to them,
    /// as a face group's sim); empty: the interim sim.
    /// ★ X20b (his answer of 2026-10-20 ~19:10: "Edge Play shows CORE'S FULL DESIGN DEPTH"): with one target per press, `perPress`.
    public static func pressSim(id: String, presses: [PressPush], voxels: Int, targets: [FlexibleFEField.Target] = []) -> Sim {
        var sim = Sim(id: id,
            pressed: presses.map { q in
                var x = FlexSquishPressInfo(press: q.regions, direction: [q.direction.x, q.direction.y, q.direction.z], weightN: q.weightN)
                x.pushXYZ = q.pushXYZ; x.pushWeight = q.pushWeight   // ★ R7-E5: where it presses follows his drawing
                return x
            },
            strainOp: [Float](repeating: 0, count: voxels), targets: targets)
        sim.perPress = !targets.isEmpty && targets.count == presses.count && !controlOneScalar
        return sim
    }

    /// ★ R7-E3 + R7-E5: one press of an edges group's interim sim — its footprint, its arrow, its force, and (R7-E5) its drawn shape
    /// as weighted samples on the footprint (FlexiblePressPush; empty: an even push).
    public struct PressPush: Equatable, Sendable {
        public let regions: [Int]
        public let direction: SIMD3<Double>
        public let weightN: Double
        public var pushXYZ: [Double] = []
        public var pushWeight: [Double] = []
    }

    /// The bridge's request for `sim`.
    public func request(_ sim: Sim, control: Int = 0, deadlineMS: Double = FlexibleFE.deadlineMS) -> FlexSquishRequestInfo {
        var q = FlexSquishRequestInfo(pressed: sim.pressed, restingIDs: resting, rho: rho, strainOp: sim.strainOp, skinFrac: skinFrac,
                                      law: law, poisson: FlexibleFE.poisson, tolerance: FlexibleFE.tolerance, deadlineMS: deadlineMS,
                                      control: control)
        let h = Self.controlLegacyHold ? FlexibleFEHold.legacy : hold   // ★ U21 · I1
        q.holdRule = h.rule
        q.anchorFaceIDs = h.anchorFaceIDs
        q.anchorRegionIDs = h.anchorRegionIDs
        if !Self.controlIgnoreLinks { q.heldWalls = walls[sim.id] ?? [] }   // ★ U21 · I3
        return q
    }

    /// ★ U21 · I1 (R3): a field solved under a hold that leaves the exits free (the Topology anchors) is calibrated on a REFERENCE
    /// — the same sim under today's chain (the exits held) — whose k is applied to it. Today's chain is its own reference.
    /// ★ U21 · I3: so is a field held by linked walls whose exits are free (no Rest: the walls alone hold it; with Rests the far
    /// anvil stays — "links and Rests both hold" — so its exits are held and it is its own reference).
    static func needsReference(_ f: FlexibleFEField, _ r: FlexibleFERequest) -> Bool {
        guard !controlSingleSolveCalibration, !f.exitsHeld else { return false }
        if f.wallNodes.contains(where: { $0 > 0 }) { return true }
        return r.hold.rule == 1 && f.holdRule == 1 && f.bcMode == "anchor"
    }

    /// Build every group sim's request from the lattice just built.
    /// `field`: the combined density field (the scene's grid); `inputs`: the lattice's inputs
    /// (ρ and the skin); `sims`: the lattice's sims (only GROUPS are solved — "Play all" plays them
    /// in turn); `faces`: every built face.
    public static func build(field: FlexDensityField, inputs: FlexibleLatticeInputs, sims: [FlexibleSim],
                             faces: [FlexFaceKey: Face], resting: [Int], law: FlexSquishLawInfo,
                             generation: Int) -> FlexibleFERequest {
        let n = field.nx * field.ny * field.nz
        let h = field.spacing
        func centre(_ v: Int) -> SIMD3<Double> {
            let i = v % field.nx, j = (v / field.nx) % field.ny, k = v / (field.nx * field.ny)
            return field.origin + (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * h
        }
        var rho = [Float](repeating: -1, count: n), skin = [Float](repeating: 0, count: n)
        var lattice: [Int] = []
        let hf = Float(h)
        for v in 0..<Swift.min(n, field.density.count) {
            let d = field.density[v]
            guard d >= 0 else { continue }
            lattice.append(v)
            let p = SIMD3<Float>(centre(v))
            rho[v] = d > 0 ? d : Swift.max(0, inputs.rho.sample(p))
            let sd = inputs.skinDist.sample(p)
            skin[v] = Swift.min(1, Swift.max(0, (inputs.skinMM - (sd - hf / 2)) / hf))
        }
        var out: [Sim] = []
        for sim in sims {
            guard case .group = sim.kind else { continue }
            let fs = sim.keys.compactMap { faces[$0] }
            guard !fs.isEmpty else { continue }
            var strain = [Float](repeating: 0, count: n)
            for v in lattice {
                let p = centre(v)
                var best: (depth: Double, strain: Double)?
                for f in fs {
                    guard let hit = FlexibleStackMembership.hit(p, f.stack, cuts: f.cuts) else { continue }
                    if let b = best, b.depth <= hit.depth { continue }
                    let d = hit.col < f.depthsMM.count ? (f.depthsMM[hit.col] ?? 0) : 0
                    let hh = hit.col < f.heightsMM.count ? f.heightsMM[hit.col] : 0
                    best = (hit.depth, d > 0 && hh > 0 ? d / hh : 0)
                }
                if let b = best { strain[v] = Float(b.strain) }
            }
            out.append(Sim(id: sim.id,
                           pressed: fs.map { FlexSquishPressInfo(face: $0.key.region, rotation: $0.key.rotation, columnPressureMPa: $0.pressureMPa) },
                           strainOp: strain,
                           targets: fs.map { FlexibleFEField.Target(stack: $0.stack, depthsMM: $0.depthsMM, pinched: $0.pinched) }))
        }
        return FlexibleFERequest(generation: generation, rho: rho, skinFrac: skin, resting: resting, law: law, sims: out)
    }

    /// Solve one sim (seconds — OFF the main thread and off the design actor) and calibrate it.
    /// A failed solve is `.failure` with core's words.
    public static func solve(_ sim: Sim, of r: FlexibleFERequest, on scene: FlexibleScene,
                             control: Int = 0, deadlineMS: Double = FlexibleFE.deadlineMS) -> Result<FlexibleFEField, FlexibleSquishFailure> {
        // ★ U21 · I3: every field carries the hold epoch it was solved under (a late answer of another epoch is discarded)
        solveCalibrated(sim, of: r, on: scene, control: control, deadlineMS: deadlineMS).map { f in
            var f = f
            f.holdEpoch = r.holdEpoch
            return f
        }
    }

    static func solveCalibrated(_ sim: Sim, of r: FlexibleFERequest, on scene: FlexibleScene,
                                control: Int, deadlineMS: Double) -> Result<FlexibleFEField, FlexibleSquishFailure> {
        // ★ X20b: an edges group core designed for — one solve per press, each scaled to core's design depth (linear: summed)
        if sim.perPress, sim.pressed.count == sim.targets.count, !controlOneScalar {
            var parts: [FlexibleFEField] = []
            var refs: [FlexibleFEField?] = []
            for p in sim.pressed {
                let one = Sim(id: sim.id, pressed: [p], strainOp: sim.strainOp, targets: [])
                switch solveRaw(one, of: r, on: scene, control: control, deadlineMS: deadlineMS) {
                case .success(let f):
                    parts.append(f)
                    // ★ U21 · I1 (R3): one reference per press, only when its exits are not held
                    if needsReference(f, r) {
                        switch solveRaw(one, of: r.reference, on: scene, control: control, deadlineMS: deadlineMS, reference: true) {
                        case .success(let g): refs.append(g)
                        case .failure(let e): return .failure(e)
                        }
                    } else { refs.append(nil) }
                case .failure(let e): return .failure(e)
                }
            }
            guard let f = FlexibleFEField.designDepth(parts: parts, targets: sim.targets, references: refs) else {
                return .failure(FlexibleSquishFailure(why: "The presses' sims did not share one grid."))
            }
            return .success(f)
        }
        let band = r.law.shapeOnly ? nil : Optional(FlexibleFE.calibrationBand)
        switch solveRaw(sim, of: r, on: scene, control: control, deadlineMS: deadlineMS) {
        case .failure(let e): return .failure(e)
        case .success(let f):
            // ★ U21 · I1 (R3): k from a reference solve with the exits held, applied to the real-hold field
            guard needsReference(f, r), !sim.targets.isEmpty else { return .success(f.calibrated(to: sim.targets, band: band)) }
            switch solveRaw(sim, of: r.reference, on: scene, control: control, deadlineMS: deadlineMS, reference: true) {
            case .failure(let e): return .failure(e)
            case .success(let ref): return .success(f.calibrated(to: sim.targets, band: band, reference: ref))
            }
        }
    }

    /// One solve, its raw field (k = 1).
    static func solveRaw(_ sim: Sim, of r: FlexibleFERequest, on scene: FlexibleScene,
                         control: Int, deadlineMS: Double, reference: Bool = false) -> Result<FlexibleFEField, FlexibleSquishFailure> {
        do {
            var s = try scene.squishSolve(r.request(sim, control: control, deadlineMS: deadlineMS))
            // ★ A squeeze whose rests SLIDE leaves near-rigid modes held by one pin each; on a
            // high-contrast part multigrid can stall there (his pad with the bottom pressed too:
            // multigrid stagnates and Jacobi-CG runs out of its work budget; bonded: 221). Retry ONCE with every rest bonded
            // (the design's rule) — a stiffer picture, still one continuous field.
            var retried = false
            if !s.ok, s.freeModes > 0, s.bcMode == "rest", control & FlexibleFE.bondedRests == 0 {
                let bonded = try scene.squishSolve(r.request(sim, control: control | FlexibleFE.bondedRests, deadlineMS: deadlineMS))
                if bonded.ok { s = bonded; retried = true }
            }
            guard s.ok else { return .failure(FlexibleSquishFailure(why: s.failure)) }
            var raw = FlexibleFEField(solution: s, simID: sim.id, generation: r.generation, bounds: !reference)
            raw.holdEpoch = r.holdEpoch   // ★ U21 · I3
            raw.restsBonded = retried
            return .success(raw)
        } catch {
            return .failure(FlexibleSquishFailure(why: "\(error)"))
        }
    }
}

/// Why a squish sim failed (core's words).
public struct FlexibleSquishFailure: Error, Equatable, Sendable {
    public let why: String
}
