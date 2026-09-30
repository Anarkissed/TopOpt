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
    }

    public let generation: Int
    /// Per scene voxel: < 0 not lattice; else ρ.
    public let rho: [Float]
    public let skinFrac: [Float]
    public let resting: [Int]
    public let law: FlexSquishLawInfo
    public let sims: [Sim]

    /// The bridge's request for `sim`.
    public func request(_ sim: Sim, control: Int = 0, deadlineMS: Double = FlexibleFE.deadlineMS) -> FlexSquishRequestInfo {
        FlexSquishRequestInfo(pressed: sim.pressed, restingIDs: resting, rho: rho, strainOp: sim.strainOp, skinFrac: skinFrac,
                              law: law, poisson: FlexibleFE.poisson, tolerance: FlexibleFE.tolerance, deadlineMS: deadlineMS,
                              control: control)
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
        do {
            let s = try scene.squishSolve(r.request(sim, control: control, deadlineMS: deadlineMS))
            guard s.ok else { return .failure(FlexibleSquishFailure(why: s.failure)) }
            let raw = FlexibleFEField(solution: s, simID: sim.id, generation: r.generation)
            return .success(raw.calibrated(to: sim.targets, band: r.law.shapeOnly ? nil : FlexibleFE.calibrationBand))
        } catch {
            return .failure(FlexibleSquishFailure(why: "\(error)"))
        }
    }
}

/// Why a squish sim failed (core's words).
public struct FlexibleSquishFailure: Error, Equatable, Sendable {
    public let why: String
}
