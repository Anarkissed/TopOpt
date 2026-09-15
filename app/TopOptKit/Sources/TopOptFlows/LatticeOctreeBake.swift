import Foundation
import simd

// ★★★ THE OCTREE BAKE — his rules of 2026-09-14, verbatim:
//
//   "Always aim for the largest possible cell size because we want to use as FEW
//    CELLS AS POSSIBLE. That is always the goal for any space throughout the
//    entirety of the model. The grading area is specifically made to create room
//    for a smooth gradient between those largest possible cells and the solid
//    outline. The smallest cells go in the areas none of the larger cells can go -
//    like those holes on the edges. THAT'S where the 2mm cells should fill in - and
//    as little as possible."
//
// Each region's ladder is its own cell halved (or thirded) down to the bead's real
// printable floor, every rung anchored on ONE grid per region (in-plane at the
// lattice origin, along the normal at the face plane), so a coarse cell's corners
// are fine-cell corners and no cell is ever cut mid-way by a neighbour of another
// size. Top-down per slot: keep the region's cell wherever it fits whole inside the
// outline and the grade allows it; otherwise split that slot alone and try the next
// rung; a slot still cut at the floor is the solid outline's. Texels are laid at the
// finest rung of all ladders, one cell size per texel, each texel belonging to the
// cell its MIDDLE is in; the stepped march draws that.
//
// The stepped bake this replaces decided one size per COARSEST cell, so any texel
// the outline touched turned a whole 10 mm strip into 2 mm cells, and a 12 mm cell
// drawn through 10.3 mm texels was cut where a neighbour texel changed size.
extension LatticePreviewOccupancy {

    public struct OctreeBakeStats {
        public var slotsKept: [Double: Int] = [:]   // cell size → whole cells kept
        public var slotsCut = 0                    // finest slots the outline cuts (solid)
        public var texelsPainted = 0
        public var pitchMM: Double = 0
        public var seconds: Double = 0
        public var why: [String: Int] = [:]      // level-0 slot outcomes, per region
        public var paintedByRegion: [Int: Int] = [:]
        public var secondaryRegions: [Int] = []
    }

    /// One cell size per texel at the finest rung's pitch, chosen by the octree.
    public static func octreeCellField(occupancy occ: LatticeVoxelGrid,
                                       demand: LatticeVoxelGrid?,
                                       regions: [LatticeRegionSpec],
                                       cellMM: [Double],
                                       lineWidthMM: Double,
                                       realFloorMM: Double,
                                       shapeFitBandMM: Double,
                                       shapeFit: Bool,
                                       densityLo: Double,
                                       densityHi: Double,
                                       densityGamma: Double,
                                       latticeID: String,
                                       stats: inout OctreeBakeStats) -> LatticeCellField? {
        let t0 = Date()
        let voxel = Double(Swift.max(occ.spacing.x, Swift.max(occ.spacing.y, occ.spacing.z)))
        let floorMM = Swift.max(realFloorMM > 0 ? realFloorMM : voxel, voxel, 0.5)

        // Each region's ladder: its cell halved while the half is still printable.
        struct Ladder { let region: Int; let sizes: [Double]; let axis: Int }
        var ladders: [Ladder] = []
        // ★ ONE LADDER PER PLATE. His stand's plate carries two regions — face 2 from
        // the front, face 15 from the back — and each prism overruns the plate where
        // it is thinner than the declared depth. Two ladders on one plate gave the
        // back face's cut cells as a solid sheet on the inner face (his "weird skin",
        // 2026-09-14) and two incompatible finest rungs for one texel grid. The
        // stepped bake merged such pairs (`primary`); so does this.
        var secondary = [Bool](repeating: false, count: regions.count)
        for (r, region) in regions.enumerated() where region.role == .include && region.kind == .face {
            let nr = LatticeRegionMask.unit(region.normal)
            guard simd_length(nr) > 0.5 else { continue }
            for q in 0..<r where regions[q].role == .include && regions[q].kind == .face && !secondary[q] {
                let nq = LatticeRegionMask.unit(regions[q].normal)
                guard simd_dot(nr, nq) < -0.99 else { continue }
                let sOnQ = simd_dot(region.origin - regions[q].origin, nq)
                if sOnQ > -1e-6, sOnQ - region.depthMM < regions[q].depthMM + 1e-6 {
                    secondary[r] = true
                    break
                }
            }
        }
        stats.secondaryRegions = secondary.enumerated().filter { $0.element }.map { $0.offset }
        for (r, region) in regions.enumerated()
        where region.role == .include && region.kind == .face && r < cellMM.count && cellMM[r] > 0 && !secondary[r] {
            let n = LatticeRegionMask.unit(region.normal)
            guard simd_length(n) > 0.5 else { continue }
            let a = abs(n)
            let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
            guard a[axis] > 0.99 else { continue }
            ladders.append(Ladder(region: r, sizes: [], axis: axis))
        }
        guard !ladders.isEmpty else { return nil }
        // ★ ONE LADDER PER REGION, from that region's own cell. His back wall is
        // 10.00 mm thick (ray-cast on his mesh) and its region cell 10.31; a ladder
        // shared from the front wall's 12 mm put a 6 mm layer and two 2 mm layers
        // through it instead of one cell ("why does the back wall's internal face
        // have 2mm cells throughout", 2026-09-14). The texel grid takes the finest
        // rung of ALL ladders; where a region's cells are not multiples of that
        // pitch a texel can straddle two cells — so texels are painted by their
        // MIDDLE, and the march re-reads the neighbouring texel when its point lies
        // past the texel's own cell (`lsdf_cell_frame_at`).
        //
        // ★ THE RUNGS NEST — each divides the one above — so cells never cut each
        // other: halve while the half stays printable; when a half would drop under
        // the floor but a third would not, take the third (12 → 6 → 2 at a 1.8 mm
        // floor, instead of stopping at 3). His question: "why is it ALWAYS 1/2?"
        func ladderSizes(base: Double) -> [Double] {
            // The finest rung: the smallest base/(2^a·3^b) still at or above the floor.
            var finest = base
            for a in 0...8 { for b in 0...5 {
                let r = base / (pow(2.0, Double(a)) * pow(3.0, Double(b)))
                if r >= floorMM - 1e-9, r < finest { finest = r }
            }}
            // The chain down to it: halve while the half is still a multiple of the
            // finest rung, otherwise take a third.
            var sizes = [base]
            while sizes.last! > finest + 1e-9 {
                let last = sizes.last!
                func multiple(_ v: Double) -> Bool { let q = v / finest; return abs(q - q.rounded()) < 1e-6 }
                if multiple(last / 2) { sizes.append(last / 2) }
                else if multiple(last / 3) { sizes.append(last / 3) }
                else { break }
            }
            return sizes
        }
        ladders = ladders.map { Ladder(region: $0.region, sizes: ladderSizes(base: cellMM[$0.region]), axis: $0.axis) }
        let pitch = ladders.map { $0.sizes.last! }.min()!
        stats.pitchMM = pitch

        // The texel grid at that pitch, with the demand averaged into it.
        let grid = cellField(occupancy: occ, demand: demand, cellMM: pitch)
        let gnx = grid.nx, gny = grid.ny, gnz = grid.nz
        let gorigin = SIMD3<Double>(grid.origin)
        var size = [Float](repeating: 0, count: grid.count)
        var phase = [Float](repeating: 0, count: grid.count)
        var cutFlag = [Bool](repeating: false, count: grid.count)
        var bandT = [Float](repeating: 1, count: grid.count)
        var outlineMM = [Float](repeating: 1e3, count: grid.count)
        var owner = [Int8](repeating: -1, count: grid.count)

        func occupied(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, i < occ.nx, j >= 0, j < occ.ny, k >= 0, k < occ.nz else { return false }
            return occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5
        }

        let bead = Swift.max(lineWidthMM, 0.1)
        // Within a voxel of material: the voxel occupancy is eroded at every surface,
        // and a cut cell's texels sit exactly there.
        let pullV = Swift.max(0.6 * voxel, 0.2)
        func occupiedNear(_ p: SIMD3<Double>) -> Bool {
            if occupied(p) { return true }
            for ax in 0..<3 {
                var q = p; q[ax] += pullV; if occupied(q) { return true }
                q[ax] -= 2 * pullV; if occupied(q) { return true }
            }
            return false
        }
        for ladder in ladders {
            let region = regions[ladder.region]
            let n = LatticeRegionMask.unit(region.normal)
            let (bu, bv) = LatticeRegionMask.basis(n)
            let axis = ladder.axis
            let sBase = ladder.sizes[0]
            let plane = region.origin[axis]
            let f = ladder.sizes.last!
            // In from the outline (mm; < 0 outside) — the exact polygon.
            func dOut(_ p: SIMD3<Double>) -> Double {
                guard !region.outlineLoops.isEmpty else {
                    return LatticeRegionMask.contains(p, region: region) ? 1e3 : -1e3
                }
                let rel = p - region.origin
                return -(LatticeFaceOutline.signedDistance(
                    SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv)),
                    loops: region.outlineLoops) - region.inPlaneOffsetMM)
            }
            // The slot's box [lo, lo + S) per axis, for slot index (i, j, k) at size S.
            // In-plane slots are anchored at the lattice origin; along the normal at
            // the face plane, going into the part.
            func slotLo(_ idx: SIMD3<Int>, _ S: Double) -> SIMD3<Double> {
                var lo = SIMD3<Double>(repeating: 0)
                for ax in 0..<3 {
                    if ax == axis {
                        lo[ax] = n[axis] > 0 ? plane + Double(idx[ax]) * S
                                              : plane - Double(idx[ax] + 1) * S
                    } else {
                        lo[ax] = gorigin[ax] + Double(idx[ax]) * S
                    }
                }
                return lo
            }
            // Whole-cell test: every corner (pulled in by a hair) sits inside the
            // outline by at least a bead and inside the part.
            // ★ THE OCCUPANCY IS VOXELS (1.67 mm on this part) and eroded by up to
            // one at every surface, so a cell that spans the wall exactly — his
            // single-cell 12 mm in a 12 mm wall — has corners the voxel grid calls
            // empty. The outline test is exact; the part test pulls the corner in by
            // a voxel so the voxelisation cannot veto a cell the CAD holds.
            let pull = Swift.max(0.6 * voxel, 0.2)
            var lastFail = ""
            var outlineFailed = false
            func fits(_ lo: SIMD3<Double>, _ S: Double) -> (fits: Bool, nearest: Double, farthest: Double) {
                var nearest = 1e3, farthest = -1e3
                var ok = true
                lastFail = ""
                outlineFailed = false
                let eps = Swift.min(0.05 * S, 0.2)
                for cz in 0...1 { for cy in 0...1 { for cx in 0...1 {
                    let corner = lo + SIMD3<Double>(Double(cx), Double(cy), Double(cz)) * S
                    let sgn = SIMD3<Double>(cx == 0 ? 1 : -1, cy == 0 ? 1 : -1, cz == 0 ? 1 : -1)
                    let d = dOut(corner + sgn * eps)
                    nearest = Swift.min(nearest, d)
                    farthest = Swift.max(farthest, d)
                    if d < bead { ok = false; outlineFailed = true; if lastFail.isEmpty { lastFail = "outline" } }
                    else if !occupied(corner + sgn * Swift.min(pull, 0.45 * S)) { ok = false; if lastFail.isEmpty { lastFail = "occupancy" } }
                }}}
                return (ok, nearest, farthest)
            }
            func capAt(_ x: Double) -> Double {
                guard shapeFit, shapeFitBandMM > 0 else { return sBase }
                let t = Swift.max(0, Swift.min(1, x / shapeFitBandMM))
                return f * pow(sBase / f, t)
            }
            // In-plane inward direction of the outline distance at `p` (unit, in the
            // face's own basis), by central differences on the exact polygon.
            func inward(_ p: SIMD3<Double>) -> SIMD3<Double> {
                let h = 0.1
                let gu = (dOut(p + bu * h) - dOut(p - bu * h)) / (2 * h)
                let gv = (dOut(p + bv * h) - dOut(p - bv * h)) / (2 * h)
                let g = bu * gu + bv * gv
                let l = simd_length(g)
                return l > 1e-6 ? g / l : SIMD3<Double>(repeating: 0)
            }
            func paint(_ lo: SIMD3<Double>, _ S: Double, level: Int, cut: Bool, nearest: Double) {
                let ph = tilingPhase(region: region, cellMM: S, origin: grid.origin) ?? 0
                let t: Float = (shapeFit && shapeFitBandMM > 0)
                    ? Float(Swift.max(0, Swift.min(1, nearest / shapeFitBandMM))) : 1
                // ★ A TEXEL BELONGS TO THE CELL ITS MIDDLE IS IN. Texel i spans
                // [i, i+1)·pitch from the grid origin; its middle is (i + 0.5)·pitch.
                // Painting by the texel's START (the first cut) handed the last 1.4 mm
                // of every 6 mm cell on his back wall to the 2 mm layer below it —
                // that wall's face plane sits 0.59 mm off the texel grid — which is
                // the cell "cut off" he photographed (2026-09-14).
                let g0 = (lo - gorigin) / pitch - 0.5
                let g1 = (lo + SIMD3<Double>(repeating: S) - gorigin) / pitch - 0.5
                let i0 = Swift.max(0, Int(g0.x.rounded(.up))), i1 = Swift.min(gnx - 1, Int((g1.x - 1e-9).rounded(.down)))
                let j0 = Swift.max(0, Int(g0.y.rounded(.up))), j1 = Swift.min(gny - 1, Int((g1.y - 1e-9).rounded(.down)))
                let k0 = Swift.max(0, Int(g0.z.rounded(.up))), k1 = Swift.min(gnz - 1, Int((g1.z - 1e-9).rounded(.down)))
                var painted = 0
                if i0 <= i1, j0 <= j1, k0 <= k1 {
                for k in k0...k1 {
                    let cz = gorigin.z + (Double(k) + 0.5) * pitch
                    guard cz >= lo.z, cz < lo.z + S else { continue }
                    for j in j0...j1 {
                        let cy = gorigin.y + (Double(j) + 0.5) * pitch
                        guard cy >= lo.y, cy < lo.y + S else { continue }
                        for i in i0...i1 {
                            let cx = gorigin.x + (Double(i) + 0.5) * pitch
                            guard cx >= lo.x, cx < lo.x + S else { continue }
                            let idx = (k * gny + j) * gnx + i
                            guard owner[idx] < 0 else { continue }          // first region wins
                            let c = SIMD3<Double>(cx, cy, cz)                // the texel's middle
                            let d = dOut(c)
                            if cut {
                                // ★ SOLID WHEREVER ANY OF THE TEXEL IS INSIDE THE OUTLINE.
                                // Testing the middle alone left every texel whose middle
                                // was a bead outside unpainted — up to 1.5 mm of polygon
                                // interior per texel, the 2 mm stair steps along his
                                // outline ("a vectored outline with a pixel internal").
                                // Its in-plane corners, at the middle's depth; and the
                                // material test is taken a voxel and a half INSIDE the
                                // outline, because the voxel occupancy is eroded ~0.6 mm
                                // at the wall (measured) and would refuse the very
                                // texels the outline needs. Along the depth that shifted
                                // point still leaves the wall where the wall ends, so a
                                // prism deeper than the plate paints no skin.
                                var anyInside = d > 0
                                if !anyInside {
                                    let a1 = (axis + 1) % 3, a2 = (axis + 2) % 3
                                    for cx2 in [-0.5, 0.5] { for cy2 in [-0.5, 0.5] {
                                        var q = c; q[a1] += cx2 * pitch; q[a2] += cy2 * pitch
                                        if dOut(q) > 0 { anyInside = true }
                                    }}
                                }
                                guard anyInside else { continue }
                                let shift = Swift.max(0, 1.5 * voxel - d)
                                let probe = shift > 0 ? c + inward(c) * shift : c
                                guard occupiedNear(probe) else { continue }
                            } else {
                                guard occupied(c) || occupiedNear(c) else { continue }
                            }
                            owner[idx] = Int8(ladder.region)
                            size[idx] = halfRepresentable(Float(S))
                            phase[idx] = ph
                            cutFlag[idx] = cut
                            bandT[idx] = t
                            outlineMM[idx] = Float(Swift.max(0, Swift.min(1e3, d)))
                            painted += 1
                        }
                    }
                }
                }
                stats.texelsPainted += painted
                stats.paintedByRegion[ladder.region, default: 0] += painted
                if cut { stats.slotsCut += 1 } else { stats.slotsKept[S, default: 0] += 1 }
            }
            func place(_ idx: SIMD3<Int>, level: Int) {
                let S = ladder.sizes[level]
                let lo = slotLo(idx, S)
                // Skip slots wholly outside the outline or the part quickly.
                let centre = lo + SIMD3<Double>(repeating: 0.5 * S)
                let dc = dOut(centre)
                if dc < -0.87 * S { return }                       // no corner can be inside
                let (ok, nearest, farthest) = fits(lo, S)
                if level == 0 {
                    let key = "r\(ladder.region)/" + (ok ? (S <= capAt(nearest) + 1e-9 ? "kept" : "cap") : lastFail)
                    stats.why[key, default: 0] += 1
                }
                if ok && S <= capAt(nearest) + 1e-9 {
                    paint(lo, S, level: level, cut: false, nearest: nearest)
                    return
                }
                if level + 1 < ladder.sizes.count {
                    // The next rung is a half OR a third of this one: k children per axis.
                    let k = Int((S / ladder.sizes[level + 1]).rounded())
                    for cz in 0..<k { for cy in 0..<k { for cx in 0..<k {
                        place(idx &* k &+ SIMD3<Int>(cx, cy, cz), level: level + 1)
                    }}}
                    return
                }
                // The finest rung and still cut by the OUTLINE: solid, wherever any of
                // the cell lies inside the outline. A cell that failed only on the
                // part's depth (the plate thinner than the prism) is a plain cell,
                // painted where there is material and clipped by the part like any
                // other — never solid.
                if outlineFailed {
                    if farthest > 0 { paint(lo, S, level: level, cut: true, nearest: nearest) }
                } else if !ok {
                    paint(lo, S, level: level, cut: false, nearest: nearest)
                }
            }
            // Level-0 slots covering the region's box.
            let ext = SIMD3<Double>(Double(gnx - 1), Double(gny - 1), Double(gnz - 1)) * pitch
            var i0 = SIMD3<Int>(repeating: 0), i1 = SIMD3<Int>(repeating: 0)
            for ax in 0..<3 {
                if ax == axis {
                    i0[ax] = 0
                    i1[ax] = Swift.max(0, Int((region.depthMM / sBase).rounded(.up)) - 1)
                } else {
                    i0[ax] = 0
                    i1[ax] = Int((ext[ax] / sBase).rounded(.up))
                }
            }
            for k in i0.z...i1.z { for j in i0.y...i1.y { for i in i0.x...i1.x {
                place(SIMD3<Int>(i, j, k), level: 0)
            }}}
        }

        // Density: the demand's activation over the drawn span (widened to the quilt),
        // the quilt in the grade, the bead's floor on small cells.
        var activation = grid.values
        let lat = latticeID.isEmpty ? nil : LatticeType.named(latticeID)
        let quiltTop = (shapeFit && lat != nil && densityHi > 0)
            ? Swift.min(1, lat!.quiltRowDensity(cellMM: pitch)) : 0
        let drawnHi = Swift.max(densityHi, quiltTop)
        let g = densityGamma > 0 ? densityGamma : 1
        func rho(_ a: Float) -> Double {
            let av = Double(Swift.max(0, Swift.min(1, a)))
            return densityHi > densityLo ? densityLo + (densityHi - densityLo) * pow(av, g) : densityLo
        }
        func act(_ r: Double) -> Float {
            guard drawnHi > densityLo else { return 0 }
            let u = Swift.max(0, Swift.min(1, (r - densityLo) / (drawnHi - densityLo)))
            return Float(pow(u, 1 / g))
        }
        var solidDepth = [Float](repeating: 0, count: grid.count)
        for i in 0..<grid.count where size[i] > 0 {
            let s = Double(size[i])
            var r = rho(activation[i] < 0 ? 0 : activation[i])
            if let lat {
                if shapeFit, shapeFitBandMM > 0, bandT[i] < 1 {
                    let q = Swift.min(drawnHi, lat.quiltRowDensity(cellMM: s))
                    r = Swift.max(r, r + (q - r) * (1 - Double(bandT[i])))
                    // the solid bleeds in where the law asks for more than the quilt
                    let base = rho(activation[i] < 0 ? 0 : activation[i])
                    let bleed = shapeFitBandMM * Swift.max(0, 1 - q) / Swift.max(1e-3, 1 - Swift.min(base, q))
                    solidDepth[i] = Float(Swift.max(0, bleed))
                }
                if lineWidthMM > 0 {
                    r = Swift.max(r, lat.printabilityDensityFloor(lineWidthMM: lineWidthMM, cellMM: s))
                }
            }
            activation[i] = act(Swift.min(r, drawnHi))
            if cutFlag[i] { solidDepth[i] = 1e3 }           // the whole cut cell is solid
        }
        for i in 0..<grid.count where size[i] <= 0 { activation[i] = -1 }

        var out = grid
        out.values = activation
        stats.seconds = Date().timeIntervalSince(t0)
        return LatticeCellField(field: out, level: outlineMM,
                                steppedCellMM: size, steppedPhase: phase,
                                baseCellMM: pitch,
                                maxLevel: {
                                    let maxMM = Double(size.max() ?? 0)
                                    guard maxMM > 0, pitch > 0 else { return 0 }
                                    let ratio = maxMM / pitch
                                    return ratio > 1 ? Int(log2(ratio).rounded(.up)) : 0
                                }(),
                                fromCorePlan: false,
                                drawnDensityHi: drawnHi > densityHi + 1e-9 ? drawnHi : 0,
                                solidDepthMM: solidDepth)
    }
}
