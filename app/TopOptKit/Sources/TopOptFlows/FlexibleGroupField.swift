// FlexibleGroupField — the density field for squeeze groups and pinches (task
// 2026-09-29-flexible-screens, round 4 batch D2).
//
// ★ ONE GROUP. Without a pinch, core assembles the group's field itself
// (`FlexibleScene.densityField`). With a pinch core refuses ("one profile per stack"), so the
// app assembles it — `assemble` is core's assemble_density_field (field.cpp) in Swift, rule for
// rule, WITHOUT that refusal and over the app's column densities (a pinched face's two-segment
// design, FlexiblePinch): every lattice voxel of core's mask goes to the NEAREST loaded face
// whose column holds it, blended with the second nearest over one cell of the larger size
// across the boundary d_A = d_B (R11). For the two ends of one stack that boundary is the
// column's middle — the two segments meet there. FlexibleGroupFieldTests holds `assemble` to
// core's own field on a set core CAN assemble (the positive control), voxel for voxel.
//
// ★ SEPARATE GROUPS are separate squeezes, and ONE lattice must carry all of them: per voxel the
// FIRMER group's density wins (`firmer`; −1 stays −1). The softer group then squishes less than
// it was designed for where they share material — `asBuilt` reads what each face squishes in
// the COMBINED field (the mean ρ along its column's designed span, through core's
// strain_under: ≈, core brief: series columns) and the page says so in one line.

import Foundation
import simd
import TopOptKit

public enum FlexibleGroupField {

    /// One pressed face as the assembler needs it.
    public struct Face {
        public let region: Int
        public let stack: FlexStackInfo
        /// A split sector's cuts (core keeps only what projects onto its side).
        public let cuts: [RegionCut]
        /// ρ per column; ≤ 0 ⇒ no lattice there (never a hit — core's rule).
        public let density: [Double]
        /// The cell (mm) per column — the handover blend's width.
        public let cellMM: [Double]
        public init(region: Int, stack: FlexStackInfo, cuts: [RegionCut], density: [Double], cellMM: [Double]) {
            self.region = region; self.stack = stack; self.cuts = cuts; self.density = density; self.cellMM = cellMM
        }
    }

    /// Core's assemble_density_field over core's lattice `mask` (0 on a lattice voxel, −1 off it)
    /// — without its one-profile-per-stack refusal. −1 off the mask, 0 in the mask under no
    /// face, else ρ; the owner is the face with the larger weight (−1: none).
    public static func assemble(mask: FlexDensityField, faces: [Face]) -> FlexDensityField {
        let n = mask.density.count
        var rho = [Float](repeating: -1, count: n)
        var owner = [Int](repeating: -1, count: n)
        struct Hit { let s: Int; let col: Int; let depth: Double }
        var hits: [Hit] = []
        hits.reserveCapacity(faces.count)
        let h = mask.spacing
        for k in 0..<mask.nz { for j in 0..<mask.ny { for i in 0..<mask.nx {
            let idx = mask.index(i, j, k)
            guard idx < n, mask.density[idx] > -0.5 else { continue }
            // core's voxel centre: origin (the grid's corner) + (i + ½)·h
            let p = mask.origin + SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * h
            hits.removeAll(keepingCapacity: true)
            for (s, f) in faces.enumerated() {
                guard let hit = FlexibleStackMembership.hit(p, f.stack, cuts: f.cuts),
                      hit.col < f.density.count, f.density[hit.col] > 0 else { continue }
                hits.append(Hit(s: s, col: hit.col, depth: hit.depth))
            }
            if hits.isEmpty { rho[idx] = 0; continue }
            hits.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.s < $1.s }
            let a = hits[0], fa = faces[a.s]
            let ra = fa.density[a.col]
            if hits.count == 1 {
                rho[idx] = Float(ra); owner[idx] = fa.region
                continue
            }
            let b = hits[1], fb = faces[b.s]
            let rb = fb.density[b.col]
            // R11: the nearest loaded face, blended over one cell of the larger size, measured
            // ACROSS the boundary d_A = d_B: (d_B − d_A) / |l_A − l_B|
            let L = max(a.col < fa.cellMM.count ? fa.cellMM[a.col] : 0, b.col < fb.cellMM.count ? fb.cellMM[b.col] : 0)
            let g = simd_length(fa.stack.load - fb.stack.load)
            let across = g > 1e-9 ? (b.depth - a.depth) / g : (b.depth > a.depth ? 1e300 : -1e300)
            let w = min(1, max(0, 0.5 + (L > 0 ? across / L : (across > 0 ? 1e300 : (across < 0 ? -1e300 : 0)))))
            rho[idx] = Float(w * ra + (1 - w) * rb)
            owner[idx] = w >= 0.5 ? fa.region : fb.region
        } } }
        return FlexDensityField(nx: mask.nx, ny: mask.ny, nz: mask.nz, spacing: mask.spacing,
                                origin: mask.origin, density: rho, owner: owner)
    }

    /// Separate squeezes combined: per voxel the FIRMER density (−1 stays −1: not lattice; 0 stays
    /// 0: under no face). `shared`: voxels where two or more groups assign a density.
    public static func firmer(_ fields: [FlexDensityField]) -> (field: FlexDensityField, shared: Int) {
        guard let first = fields.first else {
            return (FlexDensityField(nx: 0, ny: 0, nz: 0, spacing: 0, origin: .zero, density: [], owner: []), 0)
        }
        var rho = first.density, owner = first.owner
        var shared = 0
        for n in rho.indices {
            var assigned = rho[n] > 0 ? 1 : 0
            for f in fields.dropFirst() where n < f.density.count {
                let v = f.density[n]
                if v > 0 { assigned += 1 }
                if v > rho[n] {
                    rho[n] = v
                    owner[n] = n < f.owner.count ? f.owner[n] : -1
                }
            }
            if assigned >= 2 { shared += 1 }
        }
        return (FlexDensityField(nx: first.nx, ny: first.ny, nz: first.nz, spacing: first.spacing,
                                 origin: first.origin, density: rho, owner: owner), shared)
    }

    /// The density at model point `p` (the voxel holding it), nil off the grid.
    static func sample(_ f: FlexDensityField, _ p: SIMD3<Double>) -> Float? {
        guard f.spacing > 0 else { return nil }
        let q = (p - f.origin) / f.spacing
        let i = Int(q.x.rounded(.down)), j = Int(q.y.rounded(.down)), k = Int(q.z.rounded(.down))
        guard i >= 0, j >= 0, k >= 0, i < f.nx, j < f.ny, k < f.nz else { return nil }
        let n = f.index(i, j, k)
        return n < f.density.count ? f.density[n] : nil
    }

    /// ≈ What each column of a face squishes IN THE COMBINED FIELD under its own pressure: the
    /// mean ρ along its designed span (the whole column; the half nearer the face where pinched),
    /// through core's strain_under, × the height it was designed over. nil where there is no
    /// lattice or core has no number.
    public static func asBuilt(_ field: FlexDensityField, stack st: FlexStackInfo, segments: FlexiblePinch.Segments,
                               pressureMPa: [Double],
                               strainUnder: (_ pressureMPa: Double, _ density: Double) throws -> FlexStrainResult) rethrows -> [Double?] {
        let step = max(0.05, 0.5 * field.spacing)
        return try st.columns.indices.map { c -> Double? in
            guard c < segments.heightMM.count, segments.heightMM[c] > 0, segments.buildableDensity[c] > 0,
                  c < pressureMPa.count else { return nil }
            let col = st.columns[c]
            let span = (col.exitT - col.entryT) * (segments.pinched[c] ? FlexiblePinch.segmentShare : 1)
            var sum = 0.0, count = 0
            var t = col.entryT + 0.5 * step
            while t < col.entryT + span {
                if let v = sample(field, FlexibleStackMembership.point(st, column: c, t: t)), v > 0 {
                    sum += Double(v); count += 1
                }
                t += step
            }
            let rho = count > 0 ? sum / Double(count) : segments.buildableDensity[c]
            let f = try strainUnder(pressureMPa[c], rho)
            return f.ok ? f.strain * segments.heightMM[c] : nil
        }
    }
}
