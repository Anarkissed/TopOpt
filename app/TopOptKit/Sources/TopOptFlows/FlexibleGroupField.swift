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

    /// ★ R7-E2 FIX (the verify: core's press column runs to the far side of the part — a 10.6 mm flat prism on Edge 16 re-densified
    /// a 140 mm diagonal, Face 5's slab included): a press's voxels (owner = its synthetic key) PAST its flat prism's plane
    /// (height > h along the arrow) are under no face (0) — the press grades only the volume he set; another group's firmer wins
    /// there as before.
    public static func clipToPresses(_ f: FlexDensityField, cuts: [Int: FlexibleFlatPrism.Cut]) -> FlexDensityField {
        guard !cuts.isEmpty, !controlPressFieldWhole else { return f }
        var rho = f.density, owner = f.owner
        for k in 0..<f.nz { for j in 0..<f.ny { for i in 0..<f.nx {
            let n = f.index(i, j, k)
            guard n < rho.count, n < owner.count, rho[n] > 0, let c = cuts[owner[n]] else { continue }
            let p = f.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * f.spacing
            if c.height(p) > c.depthMM { rho[n] = 0; owner[n] = -1 }
        } } }
        return FlexDensityField(nx: f.nx, ny: f.ny, nz: f.nz, spacing: f.spacing, origin: f.origin, density: rho, owner: owner)
    }
    /// ★ RED CONTROL only: E2 as built — core's whole press column in the preview.
    nonisolated(unsafe) static var controlPressFieldWhole = false

    /// ★ R7-U21 H, EDGE-LOOK (his Img3 of 2026-10-21: "Edges/corners don't look great"). `clipToPresses` cuts a press's
    /// column at its flat prism's plane BY VOXEL CENTRE, so the combined ρ jumps from the press's design (up to 0.32 on his
    /// pad) to the face lattice's 0.14 across ONE voxel, on a staircase: the gyroid ladder ran through up to 4.66 rungs inside
    /// that voxel and shredded a 1–1.5 mm band along the plane (FlexibleR7U21EdgeLookTests). The seam's SUB-VOXEL clip, for
    /// the field to draw two lattices meeting AT the plane (FlexibleLatticeField.seamWall):
    ///  * `across` — per voxel within `seamBandVoxels` of a press's plane, the OTHER side's ρ carried across it: a press
    ///    voxel takes the value just past the plane along the arrow (the face lattice's), a voxel past the plane takes the
    ///    press's value just inside it (core's press column is one ρ along the arrow). Everywhere else `across` = ρ, which
    ///    is how the field knows a cell holds no seam (and draws it exactly as before).
    ///  * `side` — the press side's share by the plane's TRUE position: 1 well inside, 0 well past, a ramp over ±
    ///    `seamRampVoxels` voxels around the plane (its trilinear ½ crossing is the plane, not the voxel staircase).
    /// nil when no voxel has a seam. `rho` is the builder's filled ρ, `owner` the combined field's carried through the same
    /// fills, on the same grid (x fastest, `origin` its corner). ρ itself is never changed: the colours stay core's design.
    public static func pressSeam(rho: [Float], owner: [Int], nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, spacing h: Double,
                                 cuts: [Int: FlexibleFlatPrism.Cut]) -> (across: [Float], side: [Float])? {
        let n = nx * ny * nz
        guard !cuts.isEmpty, h > 0, rho.count == n, owner.count == n else { return nil }
        let band = (controlSeamBandVoxels ?? seamBandVoxels) * h
        let ramp = seamRampVoxels * h
        typealias Plane = (key: Int, cut: FlexibleFlatPrism.Cut, dir: SIMD3<Double>, len: Double)
        // sorted keys: a voxel past two planes takes the same one every run (no hash order)
        let planes: [Plane] = cuts.keys.sorted().map { key in
            let c = cuts[key]!, l = simd_length(c.direction)
            return (key, c, l > 1e-12 ? c.direction / l : c.direction, Swift.max(l, 1e-12))
        }
        var byKey: [Int: Plane] = [:]
        for p in planes { byKey[p.key] = p }
        func centre(_ v: Int) -> SIMD3<Double> {
            origin + SIMD3(Double(v % nx) + 0.5, Double((v / nx) % ny) + 0.5, Double(v / (nx * ny)) + 0.5) * h
        }
        func past(_ c: Plane, _ p: SIMD3<Double>) -> Double { (c.cut.height(p) - c.cut.depthMM) / c.len }
        func voxel(_ p: SIMD3<Double>) -> Int? {
            let q = (p - origin) / h
            let i = Int(q.x.rounded(.down)), j = Int(q.y.rounded(.down)), k = Int(q.z.rounded(.down))
            guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return nil }
            return (k * ny + j) * nx + i
        }
        func share(_ d: Double) -> Float { Float(Swift.min(1, Swift.max(0, 0.5 - 0.5 * d / ramp))) }
        var across = rho, side = [Float](repeating: 0, count: n)
        var any = false
        for v in 0..<n {
            let p = centre(v)
            if let c = byKey[owner[v]], past(c, p) <= 0 {
                // a press voxel (its centre on the press's side of the plane; a fill past the plane is not one)
                let d = past(c, p)
                side[v] = share(d)
                guard d >= -band else { continue }
                var s = -d + 0.25 * h
                while s <= -d + 1.5 * h {
                    if let w = voxel(p + c.dir * s), past(c, centre(w)) > 0 {
                        if rho[w] != rho[v] { across[v] = rho[w]; any = true }
                        break
                    }
                    s += 0.25 * h
                }
                continue
            }
            for c in planes {
                let d = past(c, p)
                guard d > 0, d <= band else { continue }
                // past this press's plane: the press's own value just inside it, where its column is
                var s = d + 0.25 * h, found: Int?
                while s <= d + 1.5 * h {
                    if let w = voxel(p - c.dir * s), past(c, centre(w)) <= 0 {
                        if owner[w] == c.key { found = w }
                        break
                    }
                    s += 0.25 * h
                }
                guard let w = found else { continue }
                side[v] = share(d)
                if rho[w] != rho[v] { across[v] = rho[w]; any = true }
                break
            }
        }
        return any ? (across, side) : nil
    }
    /// The band (voxels either side of a press's plane) that carries the other side's ρ, and the half-width of the side
    /// share's ramp. The ramp saturates inside the band, so a cell at the band's edge is plain ladder on both sides.
    public static let seamBandVoxels: Double = 2.5
    public static let seamRampVoxels: Double = 1
    /// ★ RED CONTROL only (FlexibleR7U21EdgeLookTests.testSmoothDensityIsUntouched): a band this many voxels wide.
    nonisolated(unsafe) static var controlSeamBandVoxels: Double?

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
