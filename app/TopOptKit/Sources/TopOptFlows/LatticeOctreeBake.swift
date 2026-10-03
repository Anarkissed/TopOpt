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
// outline and its centre far enough in for the band; otherwise split that slot
// alone and try the next rung; a finest slot the outline still cuts is painted where
// it lies inside and attaches to the solid outline — a band of one width the shader
// draws over everything, the lattice's separate frame. Texels are laid at the
// finest rung of all ladders, one cell size per texel, each texel belonging to the
// cell its MIDDLE is in; the stepped march draws that.
//
// The stepped bake this replaces decided one size per COARSEST cell, so any texel
// the outline touched turned a whole 10 mm strip into 2 mm cells, and a 12 mm cell
// drawn through 10.3 mm texels was cut where a neighbour texel changed size.
extension LatticePreviewOccupancy {

    public struct OctreeBakeStats {
        public var slotsKept: [Double: Int] = [:]   // cell size → whole cells kept
        public var slotsCut = 0                    // finest slots the outline cuts (attached to the band)
        public var texelsPainted = 0
        public var pitchMM: Double = 0
        public var seconds: Double = 0
        public var why: [String: Int] = [:]      // level-0 slot outcomes, per region
        public var paintedByRegion: [Int: Int] = [:]
        public var secondaryRegions: [Int] = []
        /// Face regions tilted further than `ladderAxisCos` from every axis — they get no cells.
        public var noLadderRegions: [Int] = []
        /// The in-plane anchor chosen for the base slots (mm, subtracted from the
        /// occupancy origin), so the most base-cell volume fits whole.
        public var anchorShiftMM = SIMD3<Double>(repeating: 0)
        public var anchorSeconds: Double = 0
        public var rasterSeconds: Double = 0
        public var cellsPlaced = 0
    }

    /// The densest a bead-wide strut may make the finest rung (core's measured law):
    /// above it the smallest cell reads as a quilt before any grading — octet, 0.45 mm
    /// bead: 2 mm is 26.5 %, 2.58 mm 17 %, 3 mm 13 %.
    public static let finestRungMaxDensity = 0.20

    /// A face region gets a ladder when its normal is within 30° of an axis (cos 30°).
    public static let ladderAxisCos = 0.866
    /// A tilted face's slots cover the prism's real extent along the axis; false = the
    /// centre-plane anchoring (a test's control only).
    nonisolated(unsafe) static var tiltedSpanEnabled = true

    /// How far toward the quilt a cell ABOVE the finest rung thickens at the outline
    /// when it lies in the band (the finest rung goes all the way).
    public static let coarseCellBandRaise = 0.35

    /// The band from which the solid bleeds inward from the outline beam (mm).
    public static let bleedStartsAtBandMM = 25.0

    /// One cell size per texel at the finest rung's pitch, chosen by the octree.
    /// ★★★ STEPPED'S MENU IS ANY STEP (his 2026-09-17: "To me that's what stepped
    /// means: taking ANY step. If they all add up to the same outline number, who
    /// cares" — and "Go - exclude 10 and 11, no solid strips"). Every k·(base/n) for
    /// n up to 6: halves, thirds, quarters, sixths and their multiples — on a 12 mm
    /// base at a 3 mm floor that is 12, 9, 8, 6, 4, 3. A 1/n tile has to be at or
    /// above the floor AND print open (the same bead-density bound as the dyadic
    /// finest rung), which is what drops 10 and 11 from a 12: they would need a 2 mm
    /// tile behind them, and 2 mm at a 0.45 bead is a quilt. DEPTH-CLEAN BY
    /// CONSTRUCTION: a k/n cell at the face leaves (n−k)/n of the wall behind it,
    /// which the 1/n tiles fill exactly — no solid strip ever. Descending; the base
    /// first, the finest last.
    /// ★ `printsOpenBound` is the AESTHETIC quilt rule. Under a structural intent core's
    /// ruling (2026-09-18) is the printability floor ALONE: "the 20 % rule has no
    /// structural content … what actually binds is whether a strut can be printed; the
    /// frame solve answers the rest." So structural passes false and the menu reaches
    /// down to the floor (sixths of a 12 at 2.0 mm, and with them 10 mm).
    public static func steppedSizeMenu(base: Double, floorMM: Double,
                                       lineWidthMM: Double, latticeID: String,
                                       printsOpenBound: Bool = true) -> [Double] {
        let law = latticeID.isEmpty ? nil : LatticeType.named(latticeID)
        func printsOpen(_ r: Double) -> Bool {
            guard printsOpenBound, let law, lineWidthMM > 0 else { return true }
            return law.printabilityDensityFloor(lineWidthMM: lineWidthMM, cellMM: r) <= finestRungMaxDensity + 1e-9
        }
        var menu: [Double] = [base]
        for n in 2...steppedMenuMaxDivisor {
            let t = base / Double(n)
            guard t >= floorMM - 1e-9, printsOpen(t) else { continue }
            for k in 1..<n {
                let s = t * Double(k)
                if !menu.contains(where: { abs($0 - s) < 1e-6 * base }) { menu.append(s) }
            }
        }
        return menu.sorted(by: >)
    }
    /// The largest divisor of the base a Stepped tile may be: sixths. The start grid
    /// inside a base slot is base/12, which every family up to sixths lands on.
    public static let steppedMenuMaxDivisor = 6

    public static func octreeCellField(occupancy occ: LatticeVoxelGrid,
                                       demand: LatticeVoxelGrid?,
                                       regions: [LatticeRegionSpec],
                                       cellMM: [Double],
                                       lineWidthMM: Double,
                                       realFloorMM: Double,
                                       shapeFitBandMM: Double,
                                       shapeFit: Bool,
                                       /// ★ THE SOLID OUTLINE'S WIDTH: no cell corner
                                       /// closer than this to the face outline. 0 ⇒ a bead.
                                       solidBandMM: Double = 0,
                                       densityLo: Double,
                                       densityHi: Double,
                                       densityGamma: Double,
                                       latticeID: String,
                                       /// ★ DEFAULT GRADE (core's "doubled"): the rungs
                                       /// are halves only — a third is never taken, so
                                       /// every cell's nodes land on its parent's.
                                       dyadicSteps: Bool = false,
                                       /// False under a structural intent: Stepped's
                                       /// menu is bounded by the printability floor
                                       /// alone (core's ruling, 2026-09-18).
                                       finestPrintsOpen: Bool = true,
                                       /// The grade's amount multiplier (1 = today's) —
                                       /// `LatticeSettings.gradeAmount(strength:)`.
                                       bandAmount: Double = 1,
                                       /// ★ The densest the grade band may raise a cell (1 = to
                                       /// the quilt, today's). With Allow quilt off the octet's
                                       /// non-quilt ceiling (his 2026-09-28: the quilt "should
                                       /// be avoided at all costs … unless 'allow quilting' is
                                       /// selected"); the band then grades by smaller cells only.
                                       bandQuiltCeiling: Double = 1,
                                       stats: inout OctreeBakeStats) -> LatticeCellField? {
        let t0 = Date()
        let voxel = Double(Swift.max(occ.spacing.x, Swift.max(occ.spacing.y, occ.spacing.z)))
        let floorMM = Swift.max(realFloorMM > 0 ? realFloorMM : voxel, voxel, 0.5)

        // Each region's ladder: its cell halved while the half is still printable.
        /// `span`: where the prism lies along `axis`, in mm from the face plane going into the
        /// part — (0, depth) for an axis-aligned face; a tilted face's prism starts IN FRONT of
        /// its centre plane on one side (his foot facet's lower half, 2026-09-28 review)
        struct Ladder { let region: Int; let sizes: [Double]; let axis: Int; var span: (lo: Double, hi: Double) = (0, 0) }
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
            // ★★ A TILTED FACE GETS ITS LADDER TOO (his 2026-09-28: "The bottom back corner is
            // completely gone"). Face 23 is a curved wall cut into three facets; its foot facet
            // is tilted 18° (normal 0.95, 0, −0.31) and its top 13°, and a 0.99 gate (8°) gave
            // them NO ladder — no cells at all, while the shell was cut there: a hole through
            // the part. The cells stay axis-aligned (the lattice is in world axes); the slab test
            // trims the ones a tilted face cuts, and the smaller rungs fill in. 30° is the band's
            // own "across a prism" tilt; a face tilted further from every axis keeps none, and
            // the DIAG names it.
            guard a[axis] > Self.ladderAxisCos else { stats.noLadderRegions.append(r); continue }
            var span = (lo: 0.0, hi: region.depthMM)
            if a[axis] < 0.99, Self.tiltedSpanEnabled {
                // ★ the prism's real extent along the axis: the outline's corners at the face and
                // at full depth (grown by the in-plane offset), measured into the part
                let (bu, bv) = LatticeRegionMask.basis(n)
                let sgn = n[axis] > 0 ? 1.0 : -1.0
                var pts = region.outlineLoops.flatMap { $0 }
                if pts.isEmpty { pts = [SIMD2(-region.halfUMM, -region.halfWMM), SIMD2(region.halfUMM, -region.halfWMM),
                                        SIMD2(region.halfUMM, region.halfWMM), SIMD2(-region.halfUMM, region.halfWMM)] }
                let grow = abs(region.inPlaneOffsetMM) * (bu[axis] * bu[axis] + bv[axis] * bv[axis]).squareRoot()
                var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
                for q in pts { for d in [0.0, region.depthMM] {
                    let t = sgn * (bu[axis] * q.x + bv[axis] * q.y + n[axis] * d)
                    lo = Swift.min(lo, t); hi = Swift.max(hi, t)
                } }
                span = (Swift.min(0, lo - grow), Swift.max(region.depthMM, hi + grow))
            }
            ladders.append(Ladder(region: r, sizes: [], axis: axis, span: span))
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
        // ★ THE FINEST RUNG IS ALSO BOUNDED BY HOW DENSE A BEAD-WIDE STRUT MAKES IT
        // (2026-09-15 night: "I am seeing quilting all along the 2mm cells … 0 should
        // mean ZERO quilting"). By core's measured law a 0.45 mm bead in a 2 mm octet
        // cell is 26.5 % dense with half-millimetre windows — it reads as a quilt
        // before any grade; 2.58 mm is 17 %, 3 mm 13 %. A rung whose bead-wide strut
        // exceeds `finestRungMaxDensity` is not a rung, so his ladders are 12 → 6 → 3
        // and 10.31 → 5.16 → 2.58 ("if there isn't space, the 2.58 one is ok"), and
        // the grade's quilt band starts from an open cell.
        let law = latticeID.isEmpty ? nil : LatticeType.named(latticeID)
        func printsOpen(_ r: Double) -> Bool {
            guard let law, lineWidthMM > 0 else { return true }
            return law.printabilityDensityFloor(lineWidthMM: lineWidthMM, cellMM: r) <= finestRungMaxDensity + 1e-9
        }
        func ladderSizes(base: Double) -> [Double] {
            // The finest rung: the smallest base/(2^a·3^b) still at or above the floor
            // whose bead-wide strut prints open. Under Default Grade b is 0: the ladder
            // is core's doubled one, halves only (his 2026-09-17: Default Grade must
            // draw the same per-region cells, band and outline as Stepped).
            var finest = base
            for a in 0...8 { for b in 0...(dyadicSteps ? 0 : 5) {
                let r = base / (pow(2.0, Double(a)) * pow(3.0, Double(b)))
                if r >= floorMM - 1e-9, r < finest, printsOpen(r) { finest = r }
            }}
            // The chain down to it: halve while the half is still a multiple of the
            // finest rung, otherwise take a third.
            var sizes = [base]
            while sizes.last! > finest + 1e-9 {
                let last = sizes.last!
                func multiple(_ v: Double) -> Bool { let q = v / finest; return abs(q - q.rounded()) < 1e-6 }
                if multiple(last / 2) { sizes.append(last / 2) }
                else if !dyadicSteps, multiple(last / 3) { sizes.append(last / 3) }
                else { break }
            }
            return sizes
        }
        ladders = ladders.map {
            let base = cellMM[$0.region]
            let sizes = dyadicSteps
                ? ladderSizes(base: base)
                : steppedSizeMenu(base: base, floorMM: floorMM, lineWidthMM: lineWidthMM, latticeID: latticeID,
                                  printsOpenBound: finestPrintsOpen)
            return Ladder(region: $0.region, sizes: sizes, axis: $0.axis, span: $0.span)
        }
        let pitch = ladders.map { $0.sizes.last! }.min()!
        stats.pitchMM = pitch

        let bead = Swift.max(lineWidthMM, 0.1)
        // ★ A UNIFORM SOLID BAND (2026-09-15: "It should not just be in the middle of
        // the steps but on top of them too"). Cells keep clear of the outline by the
        // band's width, so the solid's inner face is a stepped-by-cells line and its
        // outer face the outline itself; nothing pokes through the band.
        // ★ THE SOLID BLEEDS IN ONLY FROM A 25 mm BAND UP (his 2026-09-16 19:30 rule:
        // "25mm and up is when solid gets thicker"; at 25 he saw 5 mm of bleed and
        // called it perfect, so the amount stays half of the band over 15 — 5 mm at
        // 25, 7.5 at 30 — and there is none at all below 25). The outline BEAM stays
        // one thin width; the bleed is drawn by the march as solid over the band's
        // texels (`solidDepthMM`) — "the growing solid inwards is SDF — the outline
        // stays the way it is, clean and thin". Cells keep clear of both.
        let beam = Swift.max(solidBandMM, bead)
        let bleed = shapeFit && shapeFitBandMM >= bleedStartsAtBandMM ? (shapeFitBandMM - 15) * 0.5 : 0
        let band = beam + bleed
        func occupied(_ p: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, i < occ.nx, j >= 0, j < occ.ny, k >= 0, k < occ.nz else { return false }
            return occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5
        }
        // ★ THE OCCUPANCY IS VOXELS (1.67 mm on this part) and eroded by up to one at
        // every surface, so a cell that spans the wall exactly — his single-cell 12 mm
        // in a 12 mm wall — has corners the voxel grid calls empty. The outline test
        // is exact; the part test pulls the corner in by a voxel so the voxelisation
        // cannot veto a cell the CAD holds.
        let pull = Swift.max(0.6 * voxel, 0.2)

        // ★★★ THE ANCHOR IS CHOSEN, NOT INHERITED (2026-09-15: "Look how far the 12mm
        // cells could have gone"). Base slots sit on a grid; anchored at the voxel
        // grid's corner, the last row that fit along his base's bottom edge left an
        // 8–11 mm strip of 6 and 2 mm cells where a 12 mm row would have fit a few
        // millimetres lower. The in-plane anchor is searched within one base cell
        // (eighths, along every in-plane axis of the ladders) for the offset that
        // fits the most base-cell VOLUME whole; the texel grid is then laid from
        // there, so the march tiles from the same origin.
        var inPlaneAxes = Set<Int>()
        for l in ladders { for ax in 0..<3 where ax != l.axis { inPlaneAxes.insert(ax) } }
        let baseMax = ladders.map { $0.sizes[0] }.max()!
        // The outline distance, rasterised once per region for the SEARCH and the cut
        // texels' corner tests (the fit test and the texel's own distance keep the
        // exact polygon): 64 anchors × every base slot × 8 corners against a 75-vertex
        // polygon cost 38 s on his stand; a raster with bilinear reads makes the
        // search a quarter of a second.
        struct OutlineRaster {
            let origin: SIMD2<Double>; let h: Double; let nu: Int; let nv: Int; let values: [Double]
            func at(_ uv: SIMD2<Double>) -> Double {
                let g = (uv - origin) / h
                let i = Int(g.x.rounded(.down)), j = Int(g.y.rounded(.down))
                guard i >= 0, j >= 0, i + 1 < nu, j + 1 < nv else { return -1e3 }
                let fx = g.x - Double(i), fy = g.y - Double(j)
                let a = values[j * nu + i] * (1 - fx) + values[j * nu + i + 1] * fx
                let b = values[(j + 1) * nu + i] * (1 - fx) + values[(j + 1) * nu + i + 1] * fx
                return a * (1 - fy) + b * fy
            }
        }
        var rasters: [Int: OutlineRaster] = [:]
        let tRaster = Date()
        for ladder in ladders {
            let region = regions[ladder.region]
            guard !region.outlineLoops.isEmpty else { continue }
            var lo = SIMD2<Double>(1e9, 1e9), hi = SIMD2<Double>(-1e9, -1e9)
            for loop in region.outlineLoops { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
            let pad = baseMax + 2
            lo -= SIMD2(pad, pad); hi += SIMD2(pad, pad)
            // 1 mm: bilinear on a distance field is within ~0.1 mm of the polygon at
            // that step, and the 0.5 mm raster cost 10 s of a 30 s bake on his stand.
            let h = 1.0
            let nu = Int(((hi.x - lo.x) / h).rounded(.up)) + 2, nv = Int(((hi.y - lo.y) / h).rounded(.up)) + 2
            var vals = [Double](repeating: -1e3, count: nu * nv)
            for j in 0..<nv { for i in 0..<nu {
                let uv = lo + SIMD2(Double(i), Double(j)) * h
                vals[j * nu + i] = -(LatticeFaceOutline.signedDistanceAcrossSeams(uv, loops: region.outlineLoops, seams: region.outlineSeams, tilts: region.outlineSeamTilt, caps: region.outlineSeamDepthMM) - region.inPlaneOffsetMM)
            }}
            rasters[ladder.region] = OutlineRaster(origin: lo, h: h, nu: nu, nv: nv, values: vals)
        }
        stats.rasterSeconds = Date().timeIntervalSince(tRaster)
        func keptVolume(shift: SIMD3<Double>, children: Bool) -> Double {
            let go = SIMD3<Double>(occ.origin) - shift
            let ext = SIMD3<Double>(Double(occ.nx - 1) * Double(occ.spacing.x),
                                    Double(occ.ny - 1) * Double(occ.spacing.y),
                                    Double(occ.nz - 1) * Double(occ.spacing.z)) + shift
            var volume = 0.0
            for ladder in ladders {
                let region = regions[ladder.region]
                let n = LatticeRegionMask.unit(region.normal)
                let (bu, bv) = LatticeRegionMask.basis(n)
                let axis = ladder.axis, S = ladder.sizes[0], plane = region.origin[axis]
                let raster = rasters[ladder.region]
                func dOut(_ p: SIMD3<Double>) -> Double {
                    guard let raster else {
                        return LatticeRegionMask.contains(p, region: region) ? 1e3 : -1e3
                    }
                    let rel = p - region.origin
                    return raster.at(SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv)))
                }
                var count = SIMD3<Int>(repeating: 1)
                for ax in 0..<3 where ax != axis { count[ax] = Int((ext[ax] / S).rounded(.up)) + 1 }
                let axisI0 = Int((ladder.span.lo / S).rounded(.down))
                count[axis] = Swift.max(1, Int((ladder.span.hi / S).rounded(.up)) - axisI0)
                func fitsBox(_ lo: SIMD3<Double>, _ S: Double) -> Bool {
                    if dOut(lo + SIMD3<Double>(repeating: 0.5 * S)) < -0.87 * S { return false }
                    if !LatticePreviewOccupancy.boxInsideSlab(lo, S, region: region, axis: axis) { return false }
                    let eps = Swift.min(0.05 * S, 0.2)
                    for cz in 0...1 { for cy in 0...1 { for cx in 0...1 {
                        let corner = lo + SIMD3<Double>(Double(cx), Double(cy), Double(cz)) * S
                        let sgn = SIMD3<Double>(cx == 0 ? 1 : -1, cy == 0 ? 1 : -1, cz == 0 ? 1 : -1)
                        if dOut(corner + sgn * eps) < band
                            || !occupied(corner + sgn * Swift.min(pull, 0.45 * S)) { return false }
                    }}}
                    return true
                }
                for k in 0..<count.z { for j in 0..<count.y { for i in 0..<count.x {
                    var idx = SIMD3<Int>(i, j, k)
                    idx[axis] += axisI0
                    var lo = SIMD3<Double>(repeating: 0)
                    for ax in 0..<3 {
                        lo[ax] = ax == axis
                            ? (n[axis] > 0 ? plane + Double(idx[ax]) * S : plane - Double(idx[ax] + 1) * S)
                            : go[ax] + Double(idx[ax]) * S
                    }
                    if fitsBox(lo, S) { volume += S * S * S; continue }
                    // A slot that fails: its next-rung children count too, so among
                    // anchors that fit the same base cells the one leaving room for
                    // the next rung (rather than two solid slivers) wins. Scored only
                    // for the anchors that tie on base cells (second pass).
                    guard children, ladder.sizes.count > 1 else { continue }
                    let S1 = ladder.sizes[1]
                    let kk = Int((S / S1).rounded())
                    for cz in 0..<kk { for cy in 0..<kk { for cx in 0..<kk {
                        let lo1 = lo + SIMD3<Double>(Double(cx), Double(cy), Double(cz)) * S1
                        if fitsBox(lo1, S1) { volume += S1 * S1 * S1 }
                    }}}
                }}}
            }
            return volume
        }
        var bestShift = SIMD3<Double>(repeating: 0)
        var bestVolume = -1.0
        let steps = 8
        let axesList = inPlaneAxes.sorted()
        var combos = [SIMD3<Double>(repeating: 0)]
        for ax in axesList {
            var next: [SIMD3<Double>] = []
            for c in combos { for k in 0..<steps {
                var v = c; v[ax] = Double(k) * baseMax / Double(steps); next.append(v)
            }}
            combos = next
        }
        let tSearch = Date()
        let baseVolumes = combos.map { keptVolume(shift: $0, children: false) }
        let bestBase = baseVolumes.max() ?? 0
        for (shift, v0) in zip(combos, baseVolumes) where v0 >= bestBase - baseMax * baseMax * baseMax - 1e-9 {
            let v = keptVolume(shift: shift, children: true)
            if v > bestVolume + 1e-9 { bestVolume = v; bestShift = shift }
        }
        stats.anchorShiftMM = bestShift
        stats.anchorSeconds = Date().timeIntervalSince(tSearch)

        // The texel grid at that pitch, from the chosen anchor, with the demand
        // averaged into it.
        let grid = cellField(occupancy: occ, demand: demand, cellMM: pitch,
                             originShiftMM: SIMD3<Float>(bestShift))
        let gnx = grid.nx, gny = grid.ny, gnz = grid.nz
        let gorigin = SIMD3<Double>(grid.origin)
        var size = [Float](repeating: 0, count: grid.count)
        var phase = [Float](repeating: 0, count: grid.count)
        // ★ EACH CELL'S OWN ORIGIN, per texel, in texel units modulo the cell's size in
        // texel units — what the shader subtracts before it floors. Stepped cells sit
        // anywhere on their family's grid, so the origin can no longer be derived from
        // the size; the dyadic path writes it too (in-plane 0, the face-plane shift
        // along the normal), so one shader path serves both.
        var origin = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0), count: grid.count)
        var bandT = [Float](repeating: 1, count: grid.count)
        var outlineMM = [Float](repeating: 1e3, count: grid.count)
        // ★ The first region to claim each texel. Int32, like `cellOf`: an Int8 trapped on the
        // 128th include region (102117B9 as Default Grade has 177; the proof, 2026-10-02).
        var owner = [Int32](repeating: -1, count: grid.count)
        var isFinest = [Bool](repeating: false, count: grid.count)
        var cells: [LatticeSteppedCell] = []
        var cellOf = [Int32](repeating: -1, count: grid.count)   // texel → cell index

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
                return -(LatticeFaceOutline.signedDistanceAcrossSeams(
                    SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv)),
                    loops: region.outlineLoops, seams: region.outlineSeams,
                    tilts: region.outlineSeamTilt, caps: region.outlineSeamDepthMM) - region.inPlaneOffsetMM)
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
            var lastFail = ""
            var outlineFailed = false
            var slabFailed = false
            func fits(_ lo: SIMD3<Double>, _ S: Double, fast: Bool = false) -> (fits: Bool, nearest: Double, farthest: Double) {
                var nearest = 1e3, farthest = -1e3
                var ok = true
                lastFail = ""
                outlineFailed = false
                slabFailed = false
                let eps = Swift.min(0.05 * S, 0.2)
                // ★ THE SLAB IN DEPTH (his 2026-09-22 01:07: "the lattice is jutting out of
                // the rim … something is making the lattice move rather than thin"): a
                // cell is laid only where its whole depth lies inside the drawn band, so
                // a thinner band takes the next rung down instead of a whole cell
                // poking out of it.
                if !LatticePreviewOccupancy.boxInsideSlab(lo, S, region: region, axis: axis) {
                    lastFail = "slab"
                    slabFailed = true
                    return (false, nearest, farthest)
                }
                for cz in 0...1 { for cy in 0...1 { for cx in 0...1 {
                    let corner = lo + SIMD3<Double>(Double(cx), Double(cy), Double(cz)) * S
                    let sgn = SIMD3<Double>(cx == 0 ? 1 : -1, cy == 0 ? 1 : -1, cz == 0 ? 1 : -1)
                    let d = fast ? dOutFast(corner + sgn * eps) : dOut(corner + sgn * eps)
                    nearest = Swift.min(nearest, d)
                    farthest = Swift.max(farthest, d)
                    if d < band { ok = false; outlineFailed = true; if lastFail.isEmpty { lastFail = "outline" } }
                    else if !occupied(corner + sgn * Swift.min(pull, 0.45 * S)) { ok = false; if lastFail.isEmpty { lastFail = "occupancy" } }
                }}}
                return (ok, nearest, farthest)
            }
            // ★ THE BAND DOES NOT CAP THE CELL (2026-09-15). It used to: a 12 mm cell
            // had to sit 5 mm from the outline to be kept, so a 5 mm band on his arm
            // was two rows of 6 mm cells where 12 mm cells fit whole. His reading: "the
            // grade is meant to be a grade from largest to smallest, so this is still
            // allowed … they connect the two sizes of cells together via the walls."
            // The largest cell that fits stands anywhere; the sizes step down only
            // where the geometry forces them, and the band drives the thickening
            // toward the solid (`bandT`) and the solid's bleed.
            // The outline distance off the region's 0.5 mm raster (built for the
            // anchor search) — for the cut texels' corner test and inward direction,
            // where a tenth of a millimetre does not matter and the exact polygon
            // (75 vertices on his stand) cost 15 s per bake. The texel's own distance
            // (`outlineMM`) stays exact.
            let raster = rasters[ladder.region]
            func dOutFast(_ p: SIMD3<Double>) -> Double {
                guard let raster else { return dOut(p) }
                let rel = p - region.origin
                return raster.at(SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv)))
            }
            // In-plane inward direction of the outline distance at `p` (unit, in the
            // face's own basis), by central differences.
            func inward(_ p: SIMD3<Double>) -> SIMD3<Double> {
                let h = 0.25
                let gu = (dOutFast(p + bu * h) - dOutFast(p - bu * h)) / (2 * h)
                let gv = (dOutFast(p + bv * h) - dOutFast(p - bv * h)) / (2 * h)
                let g = bu * gu + bv * gv
                let l = simd_length(g)
                return l > 1e-6 ? g / l : SIMD3<Double>(repeating: 0)
            }
            // ★ `edge`: a finest cell the outline cuts. It is NOT painted solid any more
            // (2026-09-15 evening: "I want a singular flat outline around the entire
            // lattice that curves and has no pixels (cells) … a completely separate
            // thing from the lattice"). The outline is the shader's band of one width
            // (`solidBandMM`); the finest cells run up to it and their struts end
            // inside it, so every texel with any of its extent inside the outline is
            // painted as a plain cell and the band is drawn over it.
            func paint(_ lo: SIMD3<Double>, _ S: Double, finest: Bool, edge: Bool, nearest: Double) {
                let ph = tilingPhase(region: region, cellMM: S, origin: grid.origin) ?? 0
                // The cell's origin in texel units, modulo its size in texel units.
                let m = S / pitch
                var orig = SIMD3<Float>(repeating: 0)
                for ax in 0..<3 {
                    let q = (lo[ax] - gorigin[ax]) / pitch
                    var r = q - (q / m).rounded(.down) * m
                    if r < 1e-6 * m || r > m - 1e-6 * m { r = 0 }
                    orig[ax] = Float(r)
                }
                let t: Float = (shapeFit && shapeFitBandMM > 0)
                    ? Float(Swift.max(0, Swift.min(1, nearest / shapeFitBandMM))) : 1
                // ★ A TEXEL BELONGS TO THE CELL ITS MIDDLE IS IN. Texel i spans
                // [i, i+1)·pitch from the grid origin; its middle is (i + 0.5)·pitch.
                // Painting by the texel's START (the first cut) handed the last 1.4 mm
                // of every 6 mm cell on his back wall to the 2 mm layer below it —
                // that wall's face plane sits 0.59 mm off the texel grid — which is
                // the cell "cut off" he photographed (2026-09-14).
                // ★ ALONG THE NORMAL THE FACE-PLANE TEXEL COUNTS TOO. The slot against
                // the face starts exactly at the plane, and the texel that contains the
                // plane has its middle OUTSIDE the part whenever the plane sits past
                // the texel's half — with a 2.58 mm pitch that left the outer 1.3 mm of
                // his back wall with no texel at all: no band, no cells (caught by the
                // curved-outline probe, 2026-09-15 night). That texel belongs to the
                // slot against the face; its outside half is clipped by the part anyway.
                // Its material test is taken just inside the plane.
                let hiS = lo + SIMD3<Double>(repeating: S)
                let g0 = (lo - gorigin) / pitch - 0.5
                let g1 = (hiS - gorigin) / pitch - 0.5
                var lo0 = SIMD3<Int>(Int(g0.x.rounded(.up)), Int(g0.y.rounded(.up)), Int(g0.z.rounded(.up)))
                var hi0 = SIMD3<Int>(Int((g1.x - 1e-9).rounded(.down)), Int((g1.y - 1e-9).rounded(.down)), Int((g1.z - 1e-9).rounded(.down)))
                let faceSide = n[axis] > 0 ? lo[axis] : hiS[axis]
                let atFace = abs(faceSide - plane) < 1e-6
                if atFace {
                    if n[axis] > 0 { lo0[axis] = Int(((lo[axis] - gorigin[axis]) / pitch).rounded(.down)) }
                    else { hi0[axis] = Int(((hiS[axis] - gorigin[axis] - 1e-9) / pitch).rounded(.down)) }
                }
                let i0 = Swift.max(0, lo0.x), i1 = Swift.min(gnx - 1, hi0.x)
                let j0 = Swift.max(0, lo0.y), j1 = Swift.min(gny - 1, hi0.y)
                let k0 = Swift.max(0, lo0.z), k1 = Swift.min(gnz - 1, hi0.z)
                func inSlot(_ v: Double, _ ax: Int) -> Bool {
                    if v >= lo[ax], v < hiS[ax] { return true }
                    // the face-plane texel: its middle is on the outside of the plane
                    return atFace && ax == axis && (n[axis] > 0 ? v < lo[ax] && v > lo[ax] - pitch
                                                                 : v >= hiS[ax] && v < hiS[ax] + pitch)
                }
                var painted = 0
                if i0 <= i1, j0 <= j1, k0 <= k1 {
                for k in k0...k1 {
                    let cz = gorigin.z + (Double(k) + 0.5) * pitch
                    guard inSlot(cz, 2) else { continue }
                    for j in j0...j1 {
                        let cy = gorigin.y + (Double(j) + 0.5) * pitch
                        guard inSlot(cy, 1) else { continue }
                        for i in i0...i1 {
                            let cx = gorigin.x + (Double(i) + 0.5) * pitch
                            guard inSlot(cx, 0) else { continue }
                            let idx = (k * gny + j) * gnx + i
                            guard owner[idx] < 0 else { continue }          // first region wins
                            var c = SIMD3<Double>(cx, cy, cz)                // the texel's middle
                            // the face-plane texel's test point, just inside the plane
                            c[axis] = Swift.min(Swift.max(c[axis], lo[axis] + 0.25 * pitch), hiS[axis] - 0.25 * pitch)
                            let d = dOut(c)
                            if edge {
                                // ★ PAINTED WHEREVER ANY OF THE TEXEL IS INSIDE THE OUTLINE,
                                // so the band has a texel to be drawn in. Testing the
                                // middle alone left every texel whose middle was a bead
                                // outside unpainted — up to 1.5 mm of polygon interior
                                // per texel, the 2 mm stair steps along his outline. Its
                                // in-plane corners, at the middle's depth; and the
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
                                        if dOutFast(q) > 0 { anyInside = true }
                                    }}
                                }
                                guard anyInside else { continue }
                                let shift = Swift.max(0, 1.5 * voxel - d)
                                let probe = shift > 0 ? c + inward(c) * shift : c
                                guard occupiedNear(probe) else { continue }
                            } else {
                                guard occupied(c) || occupiedNear(c) else { continue }
                            }
                            owner[idx] = Int32(ladder.region)
                            cellOf[idx] = Int32(cells.count)
                            isFinest[idx] = finest
                            size[idx] = halfRepresentable(Float(S))
                            phase[idx] = ph
                            origin[idx] = orig
                            bandT[idx] = t
                            outlineMM[idx] = Float(Swift.max(0, Swift.min(1e3, d)))
                            painted += 1
                        }
                    }
                }
                }
                stats.texelsPainted += painted
                stats.paintedByRegion[ladder.region, default: 0] += painted
                if edge { stats.slotsCut += 1 } else { stats.slotsKept[S, default: 0] += 1 }
                // The plan: every cell that owns at least one texel, cut or whole.
                if painted > 0 { cells.append(LatticeSteppedCell(region: ladder.region, originMM: lo, sizeMM: S)) }
            }
            func place(_ idx: SIMD3<Int>, level: Int) {
                let S = ladder.sizes[level]
                let lo = slotLo(idx, S)
                // Skip slots wholly outside the outline or the part quickly.
                let centre = lo + SIMD3<Double>(repeating: 0.5 * S)
                let dc = dOut(centre)
                if dc < -0.87 * S { return }                       // no corner can be inside
                let (ok, nearest, farthest) = fits(lo, S)
                // ★ HIS CENTRE RULE, SCALED BY SIZE (2026-09-15: "if a larger cell has
                // 1/2 its body in the graded area it is ok, anything more than 1/2 it
                // needs to be split up"). Taken literally that is one test for every
                // size and lets a 12 mm cell nearer the outline than a 2 mm one; scaled,
                // the base cell keeps its centre a full band in, the finest rung is
                // never held back, and the rungs between get a proportional share —
                // smallest at the outline, base cell at the band's inner edge. Band 5
                // on a 12 mm cell changes no size (half of 12 is 6), as he accepted.
                let finestLevel = level == ladder.sizes.count - 1
                let centreOK = finestLevel || !(shapeFit && shapeFitBandMM > 0 && sBase > f + 1e-9)
                    || dc >= shapeFitBandMM * (S - f) / (sBase - f) - 1e-9
                if level == 0 {
                    let key = "r\(ladder.region)/" + (ok ? (centreOK ? "kept" : "band") : lastFail)
                    stats.why[key, default: 0] += 1
                }
                if ok && centreOK {
                    paint(lo, S, finest: finestLevel, edge: false, nearest: nearest)
                    return
                }
                // ★★★ STEPPED: ANY STEP. A base slot that fails is PACKED, not halved:
                // every menu size in turn, largest first, at any position on its
                // family's grid inside the slot; then the finest fills whatever is left.
                if !dyadicSteps, level == 0, ladder.sizes.count > 1 {
                    packSlot(lo, sBase)
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
                // The finest rung and still cut by the OUTLINE: painted wherever any of
                // the cell lies inside the outline, and attached to the band. A cell
                // that failed only on the part's depth (the plate thinner than the
                // prism) is a plain cell, painted where there is material and clipped
                // by the part like any other.
                // ★ NEVER A CELL OUTSIDE THE SLAB (2026-09-23): a finest cell that failed
                // the depth slab is air, not a plain cell — his "lattice jutting out of
                // the rim" was this fall-through painting it.
                if slabFailed { return }
                if outlineFailed {
                    if farthest > 0 { paint(lo, S, finest: true, edge: true, nearest: nearest) }
                } else {
                    paint(lo, S, finest: true, edge: false, nearest: nearest)
                }
            }
            /// ★★★ THE STEPPED PACKER (his 2026-09-17 rule). The slot is a base-cell
            /// cube; its start grid is base/12, which halves, thirds, quarters and
            /// sixths all land on. Sizes are tried largest first; a size k·(base/n)
            /// may start at any multiple of its own tile base/n, so a 9 mm cell sits
            /// at 0 or 3 in a 12 mm slot — whichever the outline allows first — and
            /// the 3 mm tiles behind and beside it land on the same grid. Depth is
            /// scanned from the FACE inward so the face layer fills first. Cells never
            /// overlap (the `taken` mask) and never straddle the slot. Neighbouring
            /// cells of different families share no nodes — that is Stepped, and core
            /// counts those ends; Default Grade never comes here.
            ///
            /// ★ NOTHING IS LEFT UNOWNED: after the packing a fill pass walks the finest
            /// tile's nested grid and paints only the texels no cell claimed (paint
            /// skips owned texels), cut by the outline where it is, so a sliver the
            /// outline leaves between two families is drawn rather than left as a
            /// hole — the same edge treatment the finest rung always had.
            func packSlot(_ lo0: SIMD3<Double>, _ S0: Double) {
                let menu = Array(ladder.sizes.dropFirst())
                let nG = 2 * steppedMenuMaxDivisor
                let g = S0 / Double(nG)
                var taken = [Bool](repeating: false, count: nG * nG * nG)
                func cellIndex(_ i: SIMD3<Int>) -> Int { (i.z * nG + i.y) * nG + i.x }
                func isFree(_ i0: SIMD3<Int>, _ span: Int) -> Bool {
                    for z in i0.z..<(i0.z + span) { for y in i0.y..<(i0.y + span) { for x in i0.x..<(i0.x + span) {
                        if taken[cellIndex(SIMD3<Int>(x, y, z))] { return false }
                    }}}
                    return true
                }
                func take(_ i0: SIMD3<Int>, _ span: Int) {
                    for z in i0.z..<(i0.z + span) { for y in i0.y..<(i0.y + span) { for x in i0.x..<(i0.x + span) {
                        taken[cellIndex(SIMD3<Int>(x, y, z))] = true
                    }}}
                }
                let ax1 = (axis + 1) % 3, ax2 = (axis + 2) % 3
                /// Candidate starts for a cell of `span` grid steps whose family tile is
                /// `step` grid steps: multiples of `step`, depth from the face first.
                func candidates(span: Int, step: Int) -> [SIMD3<Int>] {
                    var out: [SIMD3<Int>] = []
                    let maxI = nG - span
                    var a = 0
                    while a <= maxI {
                        var b = 0
                        while b <= maxI {
                            var c = 0
                            while c <= maxI {
                                var i = SIMD3<Int>(repeating: 0)
                                i[axis] = n[axis] > 0 ? a : maxI - a
                                i[ax1] = b; i[ax2] = c
                                out.append(i)
                                c += step
                            }
                            b += step
                        }
                        a += step
                    }
                    return out
                }
                func familyStep(_ S: Double) -> Int {
                    // the tile this size is a multiple of: base/n for the smallest n
                    // whose tile divides S
                    for nn in 2...steppedMenuMaxDivisor {
                        let t = S0 / Double(nn)
                        let k = S / t
                        if abs(k - k.rounded()) < 1e-6 { return Swift.max(1, Int((t / g).rounded())) }
                    }
                    return 1
                }
                for S in menu {
                    let span = Int((S / g).rounded())
                    guard span >= 1, span <= nG else { continue }
                    let isF = abs(S - f) < 1e-9
                    for i in candidates(span: span, step: familyStep(S)) {
                        guard isFree(i, span) else { continue }
                        let lo = lo0 + SIMD3<Double>(Double(i.x), Double(i.y), Double(i.z)) * g
                        let dc = dOutFast(lo + SIMD3<Double>(repeating: 0.5 * S))
                        if dc < -0.87 * S { continue }
                        let (ok, nearest, _) = fits(lo, S, fast: true)
                        let centreOK = isF || !(shapeFit && shapeFitBandMM > 0 && sBase > f + 1e-9)
                            || dc >= shapeFitBandMM * (S - f) / (sBase - f) - 1e-9
                        guard ok && centreOK else { continue }
                        paint(lo, S, finest: isF, edge: false, nearest: nearest)
                        take(i, span)
                    }
                }
                // The fill pass: the finest tile on its nested grid, into unowned texels.
                let span = Int((f / g).rounded())
                for i in candidates(span: span, step: span) {
                    if isFree(i, span) == false {
                        // wholly taken? then nothing to fill here
                        var anyFree = false
                        for z in i.z..<(i.z + span) where !anyFree { for y in i.y..<(i.y + span) where !anyFree { for x in i.x..<(i.x + span) {
                            if !taken[cellIndex(SIMD3<Int>(x, y, z))] { anyFree = true; break }
                        }}}
                        if !anyFree { continue }
                    }
                    let lo = lo0 + SIMD3<Double>(Double(i.x), Double(i.y), Double(i.z)) * g
                    let dc = dOutFast(lo + SIMD3<Double>(repeating: 0.5 * f))
                    if dc < -0.87 * f { continue }
                    let (ok, nearest, farthest) = fits(lo, f)
                    if slabFailed { continue }                 // ★ outside the slab is air
                    if ok || !outlineFailed {
                        paint(lo, f, finest: true, edge: false, nearest: nearest)
                    } else if farthest > 0 {
                        paint(lo, f, finest: true, edge: true, nearest: nearest)
                    }
                }
            }
            // Level-0 slots covering the region's box.
            let ext = SIMD3<Double>(Double(gnx - 1), Double(gny - 1), Double(gnz - 1)) * pitch
            var i0 = SIMD3<Int>(repeating: 0), i1 = SIMD3<Int>(repeating: 0)
            for ax in 0..<3 {
                if ax == axis {
                    i0[ax] = Int((ladder.span.lo / sBase).rounded(.down))
                    i1[ax] = Swift.max(i0[ax], Int((ladder.span.hi / sBase).rounded(.up)) - 1)
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
                    let q = Swift.min(Swift.min(drawnHi, lat.quiltRowDensity(cellMM: s)), bandQuiltCeiling)
                    // ★ ONLY THE FINEST CELLS QUILT (2026-09-15: "Quilting should only
                    // be allowed in the smallest printable cells — never for larger
                    // cells"). A coarser cell in the band keeps its own density; the
                    // solid's bleed below still applies to every texel in the band.
                    // ★ AND THE COARSER CELLS IN THE BAND THICKEN A LITTLE (2026-09-16:
                    // "add density around the edges — not enough to quilt them, but to
                    // extend the grade a little bit before the movement of the next
                    // phase"): a third of the way to the quilt at the outline, fading
                    // to nothing at the band's inner edge. Only the finest rung quilts.
                    let share = isFinest[i] ? 1.0 : coarseCellBandRaise
                    // ★ the amount, scaled by the strength (2026-09-18): more than the
                    // quilt is clamped to the drawn top below; less is simply less
                    // ★ never past q (2026-09-28 review: a grade strength above 0 doubled the raise
                    // and overshot the ceiling with Allow quilt off; past the quilt row it drew the
                    // same saturated strut anyway)
                    r = Swift.max(r, Swift.min(q, r + (q - r) * (1 - Double(bandT[i])) * share * (bandAmount > 0 ? bandAmount : 1)))
                    // the bleed: solid wherever the voxel is within beam + bleed of
                    // the outline — the march tests the in-plane distance per voxel
                    if bleed > 0 { solidDepth[i] = Float(band) }
                }
                if lineWidthMM > 0 {
                    r = Swift.max(r, lat.printabilityDensityFloor(lineWidthMM: lineWidthMM, cellMM: s))
                }
            }
            activation[i] = act(Swift.min(r, drawnHi))
            // ruling C: the cell carries its densest texel's ρ
            let ci = Int(cellOf[i])
            if ci >= 0, ci < cells.count { cells[ci].rho = Swift.max(cells[ci].rho, Swift.min(r, drawnHi)) }
        }
        for i in 0..<grid.count where size[i] <= 0 { activation[i] = -1 }

        var out = grid
        out.values = activation
        stats.seconds = Date().timeIntervalSince(t0)
        stats.cellsPlaced = cells.count
        var field = LatticeCellField(field: out, level: outlineMM,
                                steppedCellMM: size, steppedPhase: phase,
                                steppedOrigin: origin,
                                baseCellMM: pitch,
                                maxLevel: {
                                    let maxMM = Double(size.max() ?? 0)
                                    guard maxMM > 0, pitch > 0 else { return 0 }
                                    let ratio = maxMM / pitch
                                    return ratio > 1 ? Int(log2(ratio).rounded(.up)) : 0
                                }(),
                                fromCorePlan: false,
                                drawnDensityHi: drawnHi > densityHi + 1e-9 ? drawnHi : 0,
                                solidDepthMM: solidDepth,
                                solidBandMM: beam)
        field.steppedCells = cells
        return field
    }
}
