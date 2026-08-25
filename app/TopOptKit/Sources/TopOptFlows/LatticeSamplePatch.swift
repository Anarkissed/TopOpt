// LatticeSamplePatch.swift — the "this is what the cells look like" reference: a
// SMALL block (a few cells) of the lattice at TRUE geometry, so the density colours
// on the part are anchored to something real. This is the deliberate second half of
// the proxy (handoff 2026-07-28-lattice-viewer-proxy): the surface shading says
// where/how-dense, this says what the unit cell physically is. It is a handful of
// cells — never the part — so it stays a few thousand triangles, orders below the
// full lattice the device cannot hold.
//
// The primitives mirror the worker's swept-solid generator (PR-201 /
// 2026-07-27-strut-lattice-family): each strut is a capped regular 8-gon prism
// (16 side + 2×8 cap = 32 triangles), each junction a 20-triangle icosahedron blob.
// The strut RADIUS comes from the SAME grading law the proxy shades by —
// r(ρ) = L·√(ρ/K) — so the patch's thickness is the density it is labelled with.
//
// Pure geometry on Float arrays → a `ViewerMesh`, testable headlessly (no GPU). The
// block is built by tiling the lattice's canonical struts over an N³ grid of cells
// and keeping the ones fully inside the block, deduped by endpoint — the same
// canonical-ownership idea the worker uses, at sample scale.

import Foundation
import simd
import TopOptKit

public enum LatticeSamplePatch {

    /// Build an `cells`³-cell block of `lattice` at cell size `cellMM`, with struts
    /// sized to relative density `relativeDensity` via r = L·√(ρ/K). Returns a
    /// render-ready `ViewerMesh` (smooth-shaded — the struts are round) centred on
    /// the origin. `sides` is the prism cross-section (8 → the worker's 32-tri strut).
    /// ★ `boundary` — WHAT DRESSES THE BLOCK'S OUTER SURFACE, and until now this
    /// builder had no such parameter (task 2026-08-15 §10).
    ///
    /// ★ THE DEFECT, EXACTLY: the wizard's None / Rim / Skin chips wrote
    /// `model.boundary` and **this function never read it**, so all three produced
    /// byte-identical geometry. The maintainer's report — *"The finish still
    /// doesn't work. There is no skin or rim visible."* — was not a rendering
    /// problem or a camera problem. There was nothing to render.
    ///
    ///   NONE  bare struts — what every finish drew before.
    ///   RIM   the boundary dressing on the block's EDGES: a frame of beams along
    ///         the twelve edges of the patch, which is what a rim IS (core's rim
    ///         rides the pairs of boundary faces that meet at an edge).
    ///   SKIN  the anchored DIAGRID surface: crossing diagonals lying in each of
    ///         the six outer faces, tied to the strut nodes on that face.
    public static func mesh(lattice: LatticeType, cellMM: Double, cells: Int,
                            relativeDensity: Double,
                            boundary: LatticeBoundaryTreatment = .none,
                            sides: Int = 8) -> ViewerMesh {
        let n = max(1, cells)
        let S = lattice.denominator
        let unit = Float(cellMM) / Float(S)                 // world mm per integer step
        let radius = Float(lattice.strutRadiusMM(relativeDensity: relativeDensity, cellMM: cellMM))
        let extent = n * S                                   // block spans [0, extent] in L/S units

        // Collect the block's struts: tile canonical struts over the cell grid (plus a
        // one-cell ghost margin to close the high faces), keep those fully inside the
        // block box, dedup by ordered endpoint key.
        var segSet = Set<[Int]>()
        var segments: [(LatticeType.Node, LatticeType.Node)] = []
        var nodeSet = Set<[Int]>()
        var nodePts: [LatticeType.Node] = []

        func consider(_ a0: LatticeType.Node, _ b0: LatticeType.Node) {
            // inside the closed block box
            func inside(_ p: LatticeType.Node) -> Bool {
                p.x >= 0 && p.x <= extent && p.y >= 0 && p.y <= extent && p.z >= 0 && p.z <= extent
            }
            guard inside(a0), inside(b0) else { return }
            let a = a0, b = b0
            let key = order(a, b)
            if segSet.insert(key).inserted { segments.append((a, b)) }
            for p in [a, b] {
                let nk = [p.x, p.y, p.z]
                if nodeSet.insert(nk).inserted { nodePts.append(p) }
            }
        }

        for cz in -1...n { for cy in -1...n { for cx in -1...n {
            let ox = cx * S, oy = cy * S, oz = cz * S
            for s in lattice.struts {
                let a = LatticeType.Node(s.a.x + ox, s.a.y + oy, s.a.z + oz)
                let b = LatticeType.Node(s.b.x + ox, s.b.y + oy, s.b.z + oz)
                consider(a, b)
            }
        } } }

        var pos: [Float] = []
        var idx: [Int32] = []

        func world(_ p: LatticeType.Node) -> SIMD3<Float> {
            SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)) * unit
                - SIMD3<Float>(repeating: Float(extent) * unit * 0.5)   // centre the block
        }

        for (a, b) in segments { emitStrut(world(a), world(b), radius: radius, sides: sides, pos: &pos, idx: &idx) }
        for p in nodePts { emitNode(world(p), radius: radius, pos: &pos, idx: &idx) }

        // ── ★ THE BOUNDARY FINISH, ON THE SAMPLE (task 2026-08-15 §10) ──────────
        switch boundary {
        case .none:
            break
        // ★★ THE COVER IS DRAWN, AND IT IS A WALL (maintainer, 2026-08-19: "The
        // preview needs to update when selecting 'Covered'", then "I'd rather
        // this be a solid wall on 4 sides and the lattice seen from the top and
        // bottom").
        //
        // ★ THE FIRST CUT DREW NOTHING — a setting that renders nothing cannot be
        // judged, which is the complaint Finish has now drawn twice. The second
        // drew the walls as a dense run of the strut emitter's CAPSULES, which
        // reads as stacked ridges, not as a wall. This one emits flat QUADS: four
        // solid side panels, top and bottom left open so the lattice inside stays
        // legible. That is the sample's job — the real cover closes every face,
        // and the caption says so.
        case .covered:
            let e = Float(extent)
            let half = e * unit * 0.5
            // ★★ THE WALL SITS OUTSIDE THE STRUTS, NOT THROUGH THEM (maintainer,
            // 2026-08-19: "the 'walls' you added to the 'covered' finish are
            // *inside* the lattice. Had you taken the time to check, you could
            // have found that out yourself").
            //
            // ★ THE BOX IS NOT THE SILHOUETTE. `inside()` clips strut ENDPOINTS
            // to [0, extent], but `emitStrut` sweeps a capsule of `radius` about
            // that segment and `emitNode` puts a blob of the same radius on each
            // junction — so the drawn lattice reaches `radius` PAST the box on
            // every face. Panels placed at the box therefore cut through the
            // outermost struts. `pad` is that radius, with a hair of clearance so
            // the wall reads as a surface over the lattice rather than as a plane
            // coincident with it.
            let pad = radius * 1.05
            func w(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
                let p = SIMD3<Float>(x, y, z) * unit - SIMD3<Float>(repeating: half)
                // ★ X AND Z ONLY. The pad exists so a wall clears the strut
                // capsules it covers — which is a question about the wall's own
                // normal and about the CORNERS it has to close, both in plan.
                // Padding Y as well made the block taller than its lattice, so
                // the open top and bottom stopped being flush with it and the
                // "seen from the top and bottom" rule quietly broke. Y is left
                // exactly at the box: the lattice's own bulge then stands proud
                // of the open ends, which is the point.
                return SIMD3<Float>(p.x + (x <= 0 ? -pad : (x >= e ? pad : 0)),
                                    p.y,
                                    p.z + (z <= 0 ? -pad : (z >= e ? pad : 0)))
            }
            // The four VERTICAL faces (y is up): the pairs at x = 0/e and z = 0/e.
            let panels: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
                (w(0, 0, 0), w(0, 0, e), w(0, e, e), w(0, e, 0)),   // x = 0
                (w(e, 0, 0), w(e, e, 0), w(e, e, e), w(e, 0, e)),   // x = e
                (w(0, 0, 0), w(0, e, 0), w(e, e, 0), w(e, 0, 0)),   // z = 0
                (w(0, 0, e), w(e, 0, e), w(e, e, e), w(0, e, e)),   // z = e
            ]
            for (a, b, c, d) in panels {
                emitPanel(a, b, c, d, pos: &pos, idx: &idx)
            }
        case .rim:
            // A frame along the twelve edges of the block. Slightly heavier than a
            // strut so it reads as a DRESSING rather than as more lattice — the
            // whole point is that you can see which finish you picked.
            let e = Float(extent)
            let rimR = radius * 1.6
            let c: [SIMD3<Float>] = [
                SIMD3(0, 0, 0), SIMD3(e, 0, 0), SIMD3(e, e, 0), SIMD3(0, e, 0),
                SIMD3(0, 0, e), SIMD3(e, 0, e), SIMD3(e, e, e), SIMD3(0, e, e),
            ].map { $0 * unit - SIMD3<Float>(repeating: e * unit * 0.5) }
            let edges = [(0, 1), (1, 2), (2, 3), (3, 0),
                         (4, 5), (5, 6), (6, 7), (7, 4),
                         (0, 4), (1, 5), (2, 6), (3, 7)]
            for (i, j) in edges {
                emitStrut(c[i], c[j], radius: rimR, sides: sides, pos: &pos, idx: &idx)
            }
        case .fullSkin:
            // ★ THE ANCHORED DIAGRID. One diagonal lattice lying IN each of the six
            // outer faces, spanning cell to cell — so it is tied to the strut nodes
            // it lands on rather than floating over them. Diagrid is the only skin
            // core builds, which is why the wizard states it as a fact.
            // Heavy enough to read as a SURFACE rather than as more lattice —
            // the same weight the rim uses, because both are dressings.
            let skinR = radius * 1.6
            let step = Float(S)
            let half = Float(extent) * unit * 0.5
            func w(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
                SIMD3<Float>(x, y, z) * unit - SIMD3<Float>(repeating: half)
            }
            // For each of the 3 axes, the 2 faces at its low and high extreme.
            for axis in 0..<3 {
                for face in 0..<2 {
                    let fixed = face == 0 ? Float(0) : Float(extent)
                    for a in 0..<n {
                        for b in 0..<n {
                            let u0 = Float(a) * step, u1 = u0 + step
                            let v0 = Float(b) * step, v1 = v0 + step
                            // both diagonals of this face cell -> a diagrid
                            func p(_ u: Float, _ v: Float) -> SIMD3<Float> {
                                switch axis {
                                case 0:  return w(fixed, u, v)
                                case 1:  return w(u, fixed, v)
                                default: return w(u, v, fixed)
                                }
                            }
                            emitStrut(p(u0, v0), p(u1, v1), radius: skinR,
                                      sides: sides, pos: &pos, idx: &idx)
                            emitStrut(p(u1, v0), p(u0, v1), radius: skinR,
                                      sides: sides, pos: &pos, idx: &idx)
                        }
                    }
                }
            }
        }

        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// ★★★ THE SAMPLE SHOWS WHICH GRADE IS SELECTED (maintainer, 2026-08-22: "the
    /// sample part doesn't change when the grade is set to Stepped or Organic. Please
    /// make it a visible change").
    ///
    /// ★ THE ALGORITHM DID NOT REACH THIS FUNCTION AT ALL — the same defect §10 fixed
    /// for the FINISH one task earlier, in the same builder: a control that renders
    /// nothing cannot be judged. All three grades produced one uniform block.
    ///
    /// What each shows, and why it is the honest picture of that algorithm:
    ///
    ///   DEFAULT GRADE  one block. The dyadic ladder's whole point is that coarse and
    ///                  fine cells meet at SHARED nodes, so a uniform patch is a fair
    ///                  sample of it — nothing is being hidden.
    ///   STEPPED        two blocks at cells in a NON-dyadic ratio, abutting. The nodes
    ///                  do not line up across the seam, and that is not a rendering
    ///                  compromise: it is the algorithm. Core counts the cost as
    ///                  `LatticeSteppedStats::floating_ends`.
    ///   ORGANIC        core's own traced spans, run on this very block — not a cell
    ///                  lattice at all. Traced, then put through the four passes the
    ///                  exporter runs (node merge, free-end tie, support prune,
    ///                  stranded drop), so the sample shows the spans a file would
    ///                  contain rather than the raw curves.
    /// - Parameter steppedCoarsePerHalf: how many cells the COARSE half of the
    ///   stepped sample shows across itself — the single-cell/member floor (his
    ///   spec, 2026-08-24 evening: "There should be a single cell filling half
    ///   the cube, with a grade around"). 1 ⇒ one derived cell fills its half;
    ///   2 ⇒ two across. nil keeps the legacy proportions, where the toggle only
    ///   rescaled the block and read as no change at all.
    public static func mesh(lattice: LatticeType, cellMM: Double, cells: Int,
                            relativeDensity: Double,
                            boundary: LatticeBoundaryTreatment,
                            transition: LatticeCellTransition,
                            sides: Int = 8,
                            steppedCoarsePerHalf: Int? = nil,
                            /// ★ Dyadic stepping ⇒ the run grades in TWOS (his
                            /// 2026-08-25 spec: "the dyadic one should be the same
                            /// but in twos").
                            dyadicSteps: Bool = false) -> ViewerMesh {
        switch transition {
        case .defaultGrade:
            return mesh(lattice: lattice, cellMM: cellMM, cells: cells,
                        relativeDensity: relativeDensity, boundary: boundary, sides: sides)

        case .stepped:
            // ★★★ ONE BLOCK. ONE OUTER BOX. THE CELL STEPS ACROSS IT (maintainer,
            // 2026-08-23: "Remove one of them and add a stepped gradient onto a SINGLE
            // FUCKING SAMPLE BLOCK").
            //
            // ★ TWICE NOW I BUILT TWO BLOCKS AND CALLED IT ONE. First two cubes of
            // different SIZES with a gap; then two cubes of the same size abutting —
            // which is still two cubes, because each one carries its own six faces and
            // the seam is a plane you can see straight through. "One sample" means one
            // envelope, and the only thing that changes across it is the cell.
            //
            // ★ SO BOTH DIVISIONS ARE BUILT OVER THE **SAME** BOX and each contributes
            // only its own half. `mesh(...)` already tiles a block of a stated extent at
            // a stated cell — including the finish dressing on that block's faces — so
            // taking the left half of one and the right half of the other yields a
            // single block whose left is at one cell and right at the other, with one
            // continuous rim around the whole thing.
            // ★★★ RE-MADE FROM SCRATCH (his verdict, 2026-08-24 late: "still
            // looks awful. Please re-make from scratch"), to his own sentence:
            // "a single cell filling half the cube, with a grade AROUND". One
            // envelope: a centre of exactly the floor's worth of derived cells —
            // ONE cell at single-cell, 2×2×2 at floor two — wrapped on all sides
            // by a shell one grade step finer. The block size is pinned to the
            // MEMBER, so the toggle changes the structure, never the scale.
            if let k = steppedCoarsePerHalf.map({ Swift.max(1, $0) }) {
                // ★★★ HIS SPEC (2026-08-25): the first cube is ONE cell spanning
                // the whole depth — you see straight through it — and the run
                // grades finer along its width to show the fit-to-shape step.
                // Stepped grades 1·3·4·5; dyadic "the same but in twos".
                //
                // The floor multiplies every divisor, so with single-cell OFF the
                // run starts at 2 across and steps from there — the toggle changes
                // the STRUCTURE at a constant cube size, as it always had to.
                let steps = dyadicSteps ? [1, 2, 4, 8] : [1, 3, 4, 5]
                return gradedRun(lattice: lattice, cellMM: cellMM * Double(k),
                                 divisors: steps.map { $0 * k },
                                 relativeDensity: relativeDensity, sides: sides)
            }
            let n = Swift.max(2, cells)
            let extentMM = cellMM * Double(n)
            // ★ THE OTHER DIVISION MUST NOT BE DYADIC. A power-of-two pair shares nodes
            // at the seam, which is what DOUBLED does — drawing that here would make the
            // two grades identical and the control meaningless.
            func dyadic(_ a: Int, _ b: Int) -> Bool {
                let r = Double(Swift.max(a, b)) / Double(Swift.min(a, b))
                return abs(pow(2.0, log2(r).rounded()) - r) < 1e-9
            }
            var m = Swift.max(1, Int((Double(n) / 1.5).rounded()))
            while m == n || dyadic(n, m) { m += 1 }

            let fine = mesh(lattice: lattice, cellMM: extentMM / Double(n), cells: n,
                            relativeDensity: relativeDensity, boundary: boundary, sides: sides)
            let coarse = mesh(lattice: lattice, cellMM: extentMM / Double(m), cells: m,
                              relativeDensity: relativeDensity, boundary: boundary, sides: sides)
            return halves(fine, keepingXBelow: 0, and: coarse)

                case .organicGrade:
            return organicMesh(cellMM: cellMM, cells: cells,
                               relativeDensity: relativeDensity, sides: sides)
                ?? mesh(lattice: lattice, cellMM: cellMM, cells: cells,
                        relativeDensity: relativeDensity, boundary: boundary, sides: sides)
        }
    }


    /// ★★★ THE STEPPED SAMPLE, TO HIS SPEC (2026-08-25): "a single cell that fits
    /// the entire depth and goes all the way through, and the sample should be
    /// WIDER than the others to show that it then is graded to 3 then 4 then 5 to
    /// fit the shape" — and dyadic "the same but in twos".
    ///
    /// So the block is a RUN of `divisors.count` cubes, each one derived-cell wide,
    /// tall and deep. The first is ONE cell — it spans the whole depth and you can
    /// see straight through it. Each cube after it is the same cube divided more
    /// finely, which is precisely what grade-to-fit-shape does as it approaches the
    /// face's outline.
    ///
    /// ★ AND EVERY DIVISOR IS WHOLE, so the columns MESH: the coarse cell's corners
    /// are nodes of the fine grid beside it. That is the same law the part's bake
    /// now obeys (`steppedCellField`) after his close-up showed struts cut to
    /// pieces where 12.00 mm sat beside 13.00 mm — so the sample teaches the rule
    /// the part follows, instead of a picture nothing else obeys.
    static func gradedRun(lattice: LatticeType, cellMM m: Double,
                          divisors: [Int], relativeDensity: Double,
                          sides: Int) -> ViewerMesh {
        var pos: [Float] = []
        var idx: [Int32] = []
        let S = lattice.denominator
        let cols = Swift.max(1, divisors.count)
        let centre = SIMD3<Float>(Float(m) * Float(cols) / 2,
                                  Float(m) / 2, Float(m) / 2)
        for (k, nRaw) in divisors.enumerated() {
            let n = Swift.max(1, nRaw)
            let c = Float(m) / Float(n)              // this column's cell
            let unit = c / Float(S)
            let radius = Float(lattice.strutRadiusMM(relativeDensity: relativeDensity,
                                                     cellMM: Double(c)))
            let x0 = Float(k) * Float(m)
            let extent = n * S
            var segSet = Set<[Int]>()
            var nodeSet = Set<[Int]>()
            var segs: [(LatticeType.Node, LatticeType.Node)] = []
            var nodes: [LatticeType.Node] = []
            func inside(_ p: LatticeType.Node) -> Bool {
                p.x >= 0 && p.x <= extent && p.y >= 0 && p.y <= extent
                    && p.z >= 0 && p.z <= extent
            }
            for cz in -1...n { for cy in -1...n { for cx in -1...n {
                let ox = cx * S, oy = cy * S, oz = cz * S
                for st in lattice.struts {
                    let a = LatticeType.Node(st.a.x + ox, st.a.y + oy, st.a.z + oz)
                    let b = LatticeType.Node(st.b.x + ox, st.b.y + oy, st.b.z + oz)
                    guard inside(a), inside(b) else { continue }
                    let key = order(a, b)
                    if segSet.insert(key).inserted { segs.append((a, b)) }
                    for p in [a, b] {
                        let nk = [p.x, p.y, p.z]
                        if nodeSet.insert(nk).inserted { nodes.append(p) }
                    }
                }
            } } }
            func world(_ p: LatticeType.Node) -> SIMD3<Float> {
                SIMD3<Float>(Float(p.x) * unit + x0,
                             Float(p.y) * unit,
                             Float(p.z) * unit) - centre
            }
            for (a, b) in segs {
                emitStrut(world(a), world(b), radius: radius, sides: sides,
                          pos: &pos, idx: &idx)
            }
            for p in nodes {
                emitNode(world(p), radius: radius, pos: &pos, idx: &idx)
            }
        }
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// ★★★ THE STEPPED SAMPLE: a centre of the floor's worth of derived cells,
    /// wrapped by a one-step-finer shell — his sentence ("a single cell filling
    /// half the cube, with a grade AROUND"), built literally. The centre spans
    /// the middle `memberMM` cube of a `2·memberMM` block; the shell is the same
    /// block one dyadic grade finer with its middle removed. One envelope, two
    /// structures, and the single-cell toggle flips the CENTRE between one cell
    /// and 2×2×2 at constant block size.
    ///
    /// ★★ RE-BUILT CELL-GRANULAR (his verdict, 2026-08-25: "It looks terrible").
    /// The previous cut built TWO complete meshes and clipped their TRIANGLES by
    /// centroid against the core box — so every strut crossing the interface was
    /// chopped mid-prism, half-prisms of the coarse cell burst through the fine
    /// shell, and the seam read as fused wreckage. Nothing is clipped now: the
    /// shell tiles whole cells of `m/2k` over the block and simply SKIPS the
    /// core's cells; the centre tiles its own cells (2× the shell's, an integer
    /// scale of the same canonical node lattice) exactly into the hole. The core
    /// spans a whole number of shell cells by construction, so every interface
    /// node is SHARED — the coarse cell's corners land on shell nodes, dyadic
    /// conformity, no overlap, no shard. Each grade keeps its own strut radius
    /// (the same law everything else uses), so the grade reads as thick-to-thin
    /// rather than as noise.
    static func centreAndShell(lattice: LatticeType, memberMM m: Double,
                               coarseAcross k: Int, relativeDensity: Double,
                               sides: Int) -> ViewerMesh {
        let S = lattice.denominator
        let shellCellMM = m / Double(2 * k)          // one dyadic grade finer
        let centreCellMM = m / Double(k)
        let unit = Float(shellCellMM) / Float(S)     // world mm per integer step
        let across = 4 * k                           // shell cells across the block
        let extent = across * S                      // block span in shell units
        let coreLo = k * S, coreHi = 3 * k * S       // the middle m, in shell units
        let rShell = Float(lattice.strutRadiusMM(relativeDensity: relativeDensity,
                                                 cellMM: shellCellMM))
        let rCentre = Float(lattice.strutRadiusMM(relativeDensity: relativeDensity,
                                                  cellMM: centreCellMM))

        var segSet = Set<[Int]>()
        var segments: [(LatticeType.Node, LatticeType.Node, Float)] = []
        var nodeRadius: [[Int]: Float] = [:]
        var nodeOrder: [[Int]] = []

        func consider(_ a: LatticeType.Node, _ b: LatticeType.Node,
                      radius: Float, lo: Int, hi: Int) {
            func inside(_ p: LatticeType.Node) -> Bool {
                p.x >= lo && p.x <= hi && p.y >= lo && p.y <= hi
                    && p.z >= lo && p.z <= hi
            }
            guard inside(a), inside(b) else { return }
            let key = order(a, b)
            if segSet.insert(key).inserted { segments.append((a, b, radius)) }
            for p in [a, b] {
                let nk = [p.x, p.y, p.z]
                if nodeRadius[nk] == nil { nodeOrder.append(nk) }
                // A node where two grades meet wears the FATTER radius, so the
                // joint closes rather than showing the thin blob inside the fat
                // strut's end.
                nodeRadius[nk] = Swift.max(nodeRadius[nk] ?? 0, radius)
            }
        }

        // The grade around: whole shell cells, the core's skipped — the hole is
        // exactly (2k)³ shell cells, so its boundary lies on shell-cell planes.
        //
        // ★ AND A QUARTER IS CUT AWAY. A shell that goes all the way around hides
        // the one thing the sample exists to show — the coarse centre sat fully
        // enclosed and the block read as a uniform fine lattice (the old build
        // only "showed" the centre through its clipping wreckage). One vertical
        // quarter of shell cells is omitted, cell-granular like everything else,
        // so the section reads: shell outside, the floor's big cell(s) within —
        // his sentence, visible.
        let mid = 2 * k
        for cz in -1...across { for cy in -1...across { for cx in -1...across {
            let coreCell = cx * S >= coreLo && (cx + 1) * S <= coreHi
                && cy * S >= coreLo && (cy + 1) * S <= coreHi
                && cz * S >= coreLo && (cz + 1) * S <= coreHi
            if coreCell { continue }
            if cx >= mid && cy >= mid { continue }      // the cutaway quarter
            let ox = cx * S, oy = cy * S, oz = cz * S
            for s in lattice.struts {
                let a = LatticeType.Node(s.a.x + ox, s.a.y + oy, s.a.z + oz)
                let b = LatticeType.Node(s.b.x + ox, s.b.y + oy, s.b.z + oz)
                // A shell strut may not reach INTO the core interior — cells
                // outside it own only the interface, never the hole.
                consider(a, b, radius: rShell, lo: 0, hi: extent)
            }
        } } }

        // The cell(s) within: the same canonical struts at 2× the integer scale,
        // tiled into the hole. Every corner lands on a shell node.
        for cz in 0..<k { for cy in 0..<k { for cx in 0..<k {
            let ox = coreLo + cx * 2 * S
            let oy = coreLo + cy * 2 * S
            let oz = coreLo + cz * 2 * S
            for s in lattice.struts {
                let a = LatticeType.Node(2 * s.a.x + ox, 2 * s.a.y + oy, 2 * s.a.z + oz)
                let b = LatticeType.Node(2 * s.b.x + ox, 2 * s.b.y + oy, 2 * s.b.z + oz)
                consider(a, b, radius: rCentre, lo: coreLo, hi: coreHi)
            }
        } } }

        var pos: [Float] = []
        var idx: [Int32] = []
        func world(_ p: LatticeType.Node) -> SIMD3<Float> {
            SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)) * unit
                - SIMD3<Float>(repeating: Float(extent) * unit * 0.5)
        }
        for (a, b, r) in segments {
            emitStrut(world(a), world(b), radius: r, sides: sides, pos: &pos, idx: &idx)
        }
        for nk in nodeOrder {
            let p = LatticeType.Node(nk[0], nk[1], nk[2])
            emitNode(world(p), radius: nodeRadius[nk] ?? rShell, pos: &pos, idx: &idx)
        }
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// ★ ONE BLOCK OUT OF TWO DIVISIONS OF THE SAME BOX: every triangle of `a` whose
    /// centroid is on the low-x side, every triangle of `b` on the high-x side. Both were
    /// built over the SAME extent, so the result has ONE outer envelope and one rim — the
    /// cell is the only thing that changes across the seam, which is what stepped IS.
    ///
    /// Filtering by CENTROID and not by vertex: a strut is a closed prism, so its
    /// triangles either belong to it or they do not, and the centroid decides that once.
    /// A vertex test would split individual prisms and leave open shells behind.
    private static func halves(_ a: ViewerMesh, keepingXBelow split: Float,
                               and b: ViewerMesh) -> ViewerMesh {
        var pos: [Float] = []
        var idx: [Int32] = []
        func append(_ m: ViewerMesh, keepLow: Bool) {
            var remap = [Int32: Int32]()
            var t = 0
            // ★ A strut may poke past the seam by up to its own radius — enough
            // slack that a prism whose CENTROID is on this side keeps its whole
            // body, but a shard reaching deep into the other half is dropped
            // (his fix 4, 2026-08-24 night: "jagged edges that stick out in
            // between the two cell sizes"). Centroid picks the owner; the reach
            // test kills the spikes.
            let reach: Float = 1.5
            while t + 2 < m.indices.count {
                let i0 = Int(m.indices[t]), i1 = Int(m.indices[t + 1]), i2 = Int(m.indices[t + 2])
                let x0 = m.positions[i0 * 3], x1 = m.positions[i1 * 3], x2 = m.positions[i2 * 3]
                let cx = (x0 + x1 + x2) / 3
                t += 3
                guard keepLow ? (cx < split) : (cx >= split) else { continue }
                let far = keepLow ? max(x0, max(x1, x2)) : min(x0, min(x1, x2))
                guard keepLow ? (far < split + reach) : (far > split - reach)
                else { continue }
                var tri = [Int32]()
                for i in [i0, i1, i2] {
                    let key = Int32(i)
                    if let r = remap[key] { tri.append(r); continue }
                    let r = Int32(pos.count / 3)
                    pos.append(m.positions[i * 3])
                    pos.append(m.positions[i * 3 + 1])
                    pos.append(m.positions[i * 3 + 2])
                    remap[key] = r
                    tri.append(r)
                }
                idx += tri
            }
        }
        append(a, keepLow: true)
        append(b, keepLow: false)
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// Two patches side by side in one mesh. Indices are rebased, so the seam is two
    /// bodies touching — which is exactly what an unshared node looks like.
    private static func merged(_ a: ViewerMesh, shiftedBy da: SIMD3<Float>,
                               with b: ViewerMesh,
                               shiftedBy db: SIMD3<Float>) -> ViewerMesh {
        var pos = [Float](); pos.reserveCapacity(a.positions.count + b.positions.count)
        var idx = [Int32](); idx.reserveCapacity(a.indices.count + b.indices.count)
        func append(_ m: ViewerMesh, _ d: SIMD3<Float>) {
            let base = Int32(pos.count / 3)
            var i = 0
            while i + 2 < m.positions.count {
                pos.append(m.positions[i] + d.x)
                pos.append(m.positions[i + 1] + d.y)
                pos.append(m.positions[i + 2] + d.z)
                i += 3
            }
            for v in m.indices { idx.append(Int32(v) + base) }
        }
        append(a, da); append(b, db)
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// ★ CORE'S OWN TRACER, ON THE SAMPLE BLOCK. Uniaxial tension so the principal
    /// frame is determined — on a degenerate field the eigenvector order swaps between
    /// neighbouring voxels and the curves comb. Returns nil when core declines (no
    /// bead, no candidates), and the caller then draws the cell sample rather than
    /// inventing curves.
    private static func organicMesh(cellMM: Double, cells: Int,
                                    relativeDensity: Double, sides: Int) -> ViewerMesh? {
        let n = 28
        let extentMM = cellMM * Double(Swift.max(1, cells))
        let h = extentMM / Double(n)
        guard h > 0 else { return nil }
        let count = n * n * n
        var tensor = [Double](repeating: 0, count: 6 * count)
        var cand = [Bool](repeating: false, count: count)
        var sep = [Double](repeating: 0, count: count)
        // ★★★ A BENDING FIELD, NOT A UNIFORM ONE (maintainer, 2026-08-22: "this is not
        // what organic lattices looks like at all. Why does it look just like an
        // outline of boxes?").
        //
        // ★ HE WAS LOOKING AT MY OWN FIXTURE. I chose a UNIFORM uniaxial tensor "so the
        // principal frame is determined" — and a constant tensor has CONSTANT principal
        // directions, which are the coordinate axes. The tracer then walks straight
        // lines along x, y and z and the result is a rectangular wireframe: a box grid,
        // exactly as drawn. The choice that made the frame unambiguous also made the
        // answer trivial.
        //
        // ★ ORGANIC LOOKS ORGANIC BECAUSE THE FIELD BENDS. This is the textbook
        // cantilever: axial stress growing toward the root and with height off the
        // neutral axis, plus the parabolic shear that vanishes at the free surfaces.
        // Its principal directions are the classic arching isostatic lines — the
        // compression arch and the tension tie — which is what a traced lattice is FOR
        // and what his printed coupon shows.
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let e = (k * n + j) * n + i
            // A one-voxel rind is not a candidate, so tracing has a boundary to stop at.
            let inside = i > 0 && j > 0 && k > 0 && i < n - 1 && j < n - 1 && k < n - 1
            cand[e] = inside
            sep[e] = inside ? cellMM : 0
            guard inside else { continue }
            // Normalised: x along the beam 0…1, y and z across it -1…1.
            let x = Double(i) / Double(n - 1)
            let y = 2 * Double(j) / Double(n - 1) - 1
            let z = 2 * Double(k) / Double(n - 1) - 1
            let moment = (1 - x)                    // grows toward the root
            tensor[6 * e]     = 12 * moment * y     // sigma_xx: bending
            tensor[6 * e + 1] = 0.6 * moment        // a little transverse
            tensor[6 * e + 2] = 0.3 * moment
            tensor[6 * e + 3] = 4 * (1 - y * y)     // tau_xy: parabolic, zero at the faces
            tensor[6 * e + 4] = 0.8 * z * moment    // tau_yz: breaks the planar symmetry
            tensor[6 * e + 5] = 2 * (1 - z * z)     // tau_zx
        } } }
        guard let t = TopOptKit.organicTrace(
            nx: n, ny: n, nz: n, spacingMM: h,
            origin: SIMD3<Double>(repeating: -extentMM * 0.5),
            candidate: cand, stressTensor: tensor, separationMM: sep,
            minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
            // A 2×2×2 field is enough: only the SPANS are wanted here, and the field
            // is what makes the call expensive.
            fieldDims: (2, 2, 2),
            fieldOrigin: SIMD3<Double>(repeating: -extentMM * 0.5),
            fieldSpacingMM: extentMM, bandMM: 1,
            rhoMin: Swift.max(0.01, relativeDensity * 0.5),
            rhoMax: Swift.min(0.95, Swift.max(0.05, relativeDensity)))
        else { return nil }
        guard !t.spans.isEmpty else { return nil }
        var pos: [Float] = []
        var idx: [Int32] = []
        for s in t.spans {
            emitStrut(SIMD3<Float>(s.a), SIMD3<Float>(s.b), radius: Float(s.r),
                      sides: sides, pos: &pos, idx: &idx)
        }
        guard !idx.isEmpty else { return nil }
        return ViewerMesh(vertices: pos, indices: idx, faceIDs: [], smoothShaded: true)
    }

    /// The triangle count of a patch WITHOUT allocating its full mesh — for the cost
    /// table (V1) and to size the inset. tris = struts·(sides·4) + nodes·20.
    public static func triangleCount(lattice: LatticeType, cells: Int, sides: Int = 8) -> Int {
        let m = counts(lattice: lattice, cells: cells)
        return m.struts * sides * 4 + m.nodes * 20
    }

    /// Strut and node counts of the block (the same tiling/dedup as `mesh`, integers
    /// only — cheap).
    public static func counts(lattice: LatticeType, cells: Int) -> (struts: Int, nodes: Int) {
        let n = max(1, cells)
        let S = lattice.denominator
        let extent = n * S
        var segSet = Set<[Int]>()
        var nodeSet = Set<[Int]>()
        func inside(_ p: LatticeType.Node) -> Bool {
            p.x >= 0 && p.x <= extent && p.y >= 0 && p.y <= extent && p.z >= 0 && p.z <= extent
        }
        for cz in -1...n { for cy in -1...n { for cx in -1...n {
            let ox = cx * S, oy = cy * S, oz = cz * S
            for s in lattice.struts {
                let a = LatticeType.Node(s.a.x + ox, s.a.y + oy, s.a.z + oz)
                let b = LatticeType.Node(s.b.x + ox, s.b.y + oy, s.b.z + oz)
                guard inside(a), inside(b) else { continue }
                if segSet.insert(order(a, b)).inserted {
                    nodeSet.insert([a.x, a.y, a.z]); nodeSet.insert([b.x, b.y, b.z])
                }
            }
        } } }
        return (segSet.count, nodeSet.count)
    }

    // MARK: primitives (mirror the worker's swept solid)

    private static func order(_ a: LatticeType.Node, _ b: LatticeType.Node) -> [Int] {
        let ka = [a.x, a.y, a.z], kb = [b.x, b.y, b.z]
        return (kb.lexicographicallyPrecedes(ka)) ? kb + ka : ka + kb
    }

    /// A capped regular `sides`-gon prism from `p0` to `p1`, radius `r`: `sides` side
    /// quads (2 tris each) + two `sides`-triangle end-cap fans = `sides·4` triangles.
    private static func emitStrut(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, radius r: Float,
                                  sides: Int, pos: inout [Float], idx: inout [Int32]) {
        let axis = p1 - p0
        let len = simd_length(axis)
        guard len > 1e-6, r > 1e-6 else { return }
        let w = axis / len
        let (u, v) = orthonormalBasis(w)
        let base = Int32(pos.count / 3)

        func push(_ p: SIMD3<Float>) { pos.append(p.x); pos.append(p.y); pos.append(p.z) }

        // ring 0 (at p0) then ring 1 (at p1)
        for ring in 0..<2 {
            let c = ring == 0 ? p0 : p1
            for s in 0..<sides {
                let a = 2 * Float.pi * Float(s) / Float(sides)
                push(c + (u * cos(a) + v * sin(a)) * r)
            }
        }
        let cap0 = Int32(pos.count / 3); push(p0)
        let cap1 = Int32(pos.count / 3); push(p1)

        func ringIndex(_ ring: Int, _ s: Int) -> Int32 { base + Int32(ring * sides + (s % sides)) }
        for s in 0..<sides {
            let a0 = ringIndex(0, s), a1 = ringIndex(0, s + 1)
            let b0 = ringIndex(1, s), b1 = ringIndex(1, s + 1)
            idx += [a0, b0, b1,  a0, b1, a1]                  // side quad
            idx += [cap0, a1, a0]                              // p0 cap fan
            idx += [cap1, b0, b1]                              // p1 cap fan
        }
    }

    /// ★ A FLAT, DOUBLE-SIDED QUAD — the solid wall panel `covered` is built from.
    /// Both windings are emitted so the wall is opaque from inside the block as
    /// well as outside; the sample is orbited freely and a one-sided panel would
    /// vanish from half the angles.
    private static func emitPanel(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                  _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                                  pos: inout [Float], idx: inout [Int32]) {
        let base = Int32(pos.count / 3)
        for p in [a, b, c, d] { pos.append(p.x); pos.append(p.y); pos.append(p.z) }
        idx += [base, base + 1, base + 2,  base, base + 2, base + 3]
        idx += [base, base + 2, base + 1,  base, base + 3, base + 2]
    }

    /// A 20-triangle icosahedron of radius `r` at `c` (the junction blob).
    private static func emitNode(_ c: SIMD3<Float>, radius r: Float, pos: inout [Float], idx: inout [Int32]) {
        guard r > 1e-6 else { return }
        let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
        var verts: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        for i in verts.indices { verts[i] = simd_normalize(verts[i]) * r + c }
        let base = Int32(pos.count / 3)
        for p in verts { pos.append(p.x); pos.append(p.y); pos.append(p.z) }
        for f in faces { idx += [base + Int32(f.0), base + Int32(f.1), base + Int32(f.2)] }
    }

    /// Two unit vectors perpendicular to unit `w` (a stable orthonormal frame).
    private static func orthonormalBasis(_ w: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ref: SIMD3<Float> = abs(w.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(ref, w))
        let v = simd_cross(w, u)
        return (u, v)
    }
}
