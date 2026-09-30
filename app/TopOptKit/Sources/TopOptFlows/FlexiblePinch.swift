// FlexiblePinch — a column pressed from BOTH ends at once, designed as TWO SEGMENTS (task
// 2026-09-29-flexible-screens, round 4 batch D2; his img 3: "when squeezing something with your
// hands, you would absolutely squeeze the two sides together. One side wouldn't rest.").
//
// ★ WHAT CORE CANNOT DO (core brief: PINCH, SERIES COLUMNS). Core designs a face alone
// (design_face): every column carries ONE density over its whole lattice height, and
// assemble_density_field refuses two faces on one stack ("push the same material along the
// same axis (one profile per stack)", M13). So his faces 3 and 5 — the two ends of every
// 100 mm column of his pad — could never be squeezed together.
//
// ★ THE APP'S TWO SEGMENTS. Two faces of ONE squeeze group on one stack are a pinch. A column of
// face A whose MIDPOINT lies in its partner's stack is PINCHED: it is split in the middle, and
// the half nearer A is designed for A's OWN target at A's OWN pressure — core's design_face,
// column by column, with that column's height halved (target strain = A's drawn depth over
// half the lattice), through core's own density_for / strain_under / cell_size_mm (the
// bridge). The partner's half is designed the same way for ITS target. The field then gives
// each voxel to the NEARER face — core's own R11 handover rule, blended over one cell
// (FlexibleGroupField) — which for two opposite faces is exactly the column's middle.
//   * With nothing pinched this IS core's design, bit for bit: FlexiblePinchTests holds it to
//     core's buildable densities and depths on his project (the positive control).
//   * A half is the approximation: two faces of different shape meet at their stacks' middle
//     (d_A = d_B), not where a force balance would put it (core brief: pinch force balance).
//
// ★ MEMBERSHIP IS CORE'S in_stack (field.cpp), in Swift: the frame's (u, v) from the stack's own
// centroid, axes and u/v minimums, the column at ⌊u/pitch⌋, ⌊v/pitch⌋, entry ≤ t ≤ exit, and a
// sector's cuts tested on the point projected back onto its face.

import Foundation
import simd
import TopOptKit

public enum FlexibleStackMembership {

    /// Core's `in_stack`: the column of `st` holding model point `p` and its depth below the
    /// face, or nil. `cuts`: a split sector's (core keeps only what projects onto its side).
    public static func hit(_ p: SIMD3<Double>, _ st: FlexStackInfo, cuts: [RegionCut] = []) -> (col: Int, depth: Double)? {
        guard st.pitchMM > 0 else { return nil }
        let d = p - st.centroid
        let u = simd_dot(d, st.xAxis) - st.uMin, v = simd_dot(d, st.yAxis) - st.vMin
        let fu = (u / st.pitchMM).rounded(.down), fv = (v / st.pitchMM).rounded(.down)
        guard fu.isFinite, fv.isFinite, abs(fu) < 1e9, abs(fv) < 1e9 else { return nil }
        let c = st.column(Int(fu), Int(fv))
        guard c >= 0, c < st.columns.count else { return nil }
        let col = st.columns[c]
        let t = simd_dot(d, st.load)
        if t < col.entryT - 1e-9 || t > col.exitT + 1e-9 { return nil }
        let depth = t - col.entryT
        if !cuts.isEmpty {
            let q = p - st.load * depth
            for cut in cuts {
                let s = simd_dot(q - cut.point, cut.normal)
                if cut.strict ? !(s > 0) : !(s >= 0) { return nil }
            }
        }
        return (c, depth)
    }

    /// Column `c`'s centre line at `t` along the load (core's from_uv + t·load).
    public static func point(_ st: FlexStackInfo, column c: Int, t: Double) -> SIMD3<Double> {
        let col = st.columns[c]
        return st.centroid + st.xAxis * (col.uMM + st.uMin) + st.yAxis * (col.vMM + st.vMin) + st.load * t
    }
}

public enum FlexiblePinch {

    /// The share of a pinched column each face designs for (the half nearer it).
    public static let segmentShare = 0.5

    /// Which columns of face `st` are PINCHED by `partners`: the column's midpoint (halfway
    /// between its entry and exit) lies in a partner's stack.
    public static func pinchedColumns(_ st: FlexStackInfo, partners: [(stack: FlexStackInfo, cuts: [RegionCut])]) -> [Bool] {
        guard !partners.isEmpty else { return [Bool](repeating: false, count: st.columns.count) }
        return st.columns.indices.map { c in
            let col = st.columns[c]
            let p = FlexibleStackMembership.point(st, column: c, t: 0.5 * (col.entryT + col.exitT))
            return partners.contains { FlexibleStackMembership.hit(p, $0.stack, cuts: $0.cuts) != nil }
        }
    }

    /// Core's table, read through the bridge — as closures, so the rule is testable.
    public struct Law {
        public var densityFor: (_ strain: Double, _ pressureMPa: Double) throws -> FlexInverseResult
        public var strainUnder: (_ pressureMPa: Double, _ density: Double) throws -> FlexStrainResult
        public var cellMM: (_ density: Double) throws -> Double
        public var strainLimit: Double
        public var densityMin: Double
        public var densityMax: Double

        public init(densityFor: @escaping (Double, Double) throws -> FlexInverseResult,
                    strainUnder: @escaping (Double, Double) throws -> FlexStrainResult,
                    cellMM: @escaping (Double) throws -> Double,
                    strainLimit: Double, densityMin: Double, densityMax: Double) {
            self.densityFor = densityFor; self.strainUnder = strainUnder; self.cellMM = cellMM
            self.strainLimit = strainLimit; self.densityMin = densityMin; self.densityMax = densityMax
        }

        /// Core's own curve set for the filament, temperature and lattice family (the design's).
        public static func core(materialsPath path: String, materialID: String, tempC: Double,
                                build: FlexBuildParams) throws -> Law {
            let set = try FlexibleCore.curveSet(path: path, materialID: materialID, tempC: tempC, topology: build.topology)
            return Law(
                densityFor: { e, p in
                    try FlexibleCore.densityFor(path: path, materialID: materialID, tempC: tempC,
                                                topology: build.topology, targetStrain: e, pressureMPa: p)
                },
                strainUnder: { p, rho in
                    try FlexibleCore.strainUnder(path: path, materialID: materialID, tempC: tempC,
                                                 topology: build.topology, pressureMPa: p, density: rho)
                },
                cellMM: { rho in
                    try FlexibleCore.cellSizeMM(topology: build.topology, density: rho,
                                                beadsPerWall: build.beadsPerWall, beadWidthMM: build.beadWidthMM)
                },
                strainLimit: set.strainLimit, densityMin: set.densityMin, densityMax: set.densityMax)
        }
    }

    /// One face's design with its pinched columns split: per column, core's arrays.
    public struct Segments: Equatable, Sendable {
        public let pinched: [Bool]
        /// The lattice height each column is designed over (half the lattice where pinched).
        public let heightMM: [Double]
        public let status: [String]
        public let clampedDensity: [Double]
        /// The density built (0 where there is no lattice).
        public let buildableDensity: [Double]
        /// The squish built under this face's own pressure (mm), nil where core could not reach one.
        public let buildableDepthMM: [Double?]
        public let cellMM: [Double]
        public var pinchedCount: Int { pinched.filter { $0 }.count }
    }

    public enum DesignError: Error, Equatable { case columnsDoNotMatch }

    /// Core's design_face (field.cpp: F6, F7) column by column over core's own design `d` of the
    /// face — its drawing S, target depth and pressure — with a PINCHED column's height halved
    /// (`segmentShare`). Unpinched columns keep their whole height: with nothing pinched this is
    /// core's design itself.
    public static func design(_ d: FlexFaceDesignInfo, stack st: FlexStackInfo, pinched: [Bool], law: Law) throws -> Segments {
        let n = st.columns.count
        guard d.columns.count == n else { throw DesignError.columnsDoNotMatch }
        var h = [Double](repeating: 0, count: n), status = [String](repeating: "no_lattice", count: n)
        var clamped = [Double](repeating: 0, count: n)
        var lattice = [Bool](repeating: false, count: n)
        for k in 0..<n {
            let c = d.columns[k]
            guard c.status != "no_lattice", c.heightMM > 0 else { continue }
            lattice[k] = true
            let hk = c.heightMM * (k < pinched.count && pinched[k] ? segmentShare : 1)
            h[k] = hk
            let inv = try law.densityFor(c.targetDepthMM / hk, c.pressureMPa)
            status[k] = inv.status
            if inv.ok {
                clamped[k] = inv.coreDensity
            } else if inv.status == "too_firm" || inv.status == "too_soft" {
                clamped[k] = inv.nearestDensity
            } else {
                // beyond_data: pull the target back to the strain limit, then re-invert
                let atLim = try law.densityFor(law.strainLimit, c.pressureMPa)
                clamped[k] = atLim.ok ? atLim.coreDensity : (atLim.status == "too_firm" ? law.densityMin : law.densityMax)
            }
        }
        // F7: a Gaussian of σ = half the local cell, gathered over the face's latticed columns
        let p = st.pitchMM
        var buildable = [Double](repeating: 0, count: n)
        for k in 0..<n where lattice[k] {
            let sigma = 0.5 * (try law.cellMM(clamped[k]))
            let r = Int((3 * sigma / p).rounded(.up))
            let sc = st.columns[k]
            var wsum = 0.0, rsum = 0.0
            if r >= 0 {
                for dj in -r...r {
                    for di in -r...r {
                        let j = st.column(sc.iu + di, sc.iv + dj)
                        guard j >= 0, j < n, lattice[j] else { continue }
                        let d2 = p * p * (Double(di) * Double(di) + Double(dj) * Double(dj))
                        let w = exp(-d2 / (2 * sigma * sigma))
                        wsum += w
                        rsum += w * clamped[j]
                    }
                }
            }
            buildable[k] = wsum > 0 ? rsum / wsum : clamped[k]
        }
        var cell = [Double](repeating: 0, count: n)
        var depth = [Double?](repeating: nil, count: n)
        for k in 0..<n where lattice[k] {
            cell[k] = try law.cellMM(buildable[k])
            let f = try law.strainUnder(d.columns[k].pressureMPa, buildable[k])
            if f.ok { depth[k] = f.strain * h[k] }
        }
        return Segments(pinched: (0..<n).map { $0 < pinched.count && pinched[$0] && lattice[$0] }, heightMM: h,
                        status: status, clampedDensity: clamped, buildableDensity: buildable,
                        buildableDepthMM: depth, cellMM: cell)
    }

    /// Core's own design as Segments (nothing pinched, nothing recomputed): its buildable
    /// densities, depths and cells — what a face that is not pinched hands the field.
    public static func core(_ d: FlexFaceDesignInfo, stack st: FlexStackInfo) -> Segments {
        let n = st.columns.count
        func col(_ k: Int) -> FlexColumnDesign? { k < d.columns.count ? d.columns[k] : nil }
        return Segments(
            pinched: [Bool](repeating: false, count: n),
            heightMM: (0..<n).map { col($0)?.heightMM ?? 0 },
            status: (0..<n).map { col($0)?.status ?? "no_lattice" },
            clampedDensity: (0..<n).map { col($0)?.clampedDensity ?? 0 },
            buildableDensity: (0..<n).map { k in col(k).map { $0.status == "no_lattice" ? 0 : $0.buildableDensity } ?? 0 },
            buildableDepthMM: FlexibleSquishFace.buildableDepths(stack: st, design: d),
            cellMM: (0..<n).map { col($0)?.cellMM ?? 0 })
    }
}
