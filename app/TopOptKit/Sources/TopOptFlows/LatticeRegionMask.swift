// LatticeRegionMask.swift — ★ THE PREVIEW SHOWS THE LATTICE WHERE IT WILL BE
// (maintainer, 2026-08-17: "Can you confirm that the preview will only show what
// is *actually* set to lattice (i.e. the primitives)").
//
// ★ THE ANSWER WAS NO, AND IT WAS A REAL GAP. `LatticeSDFScene` bakes its
// occupancy grid from `mesh.positions / indices / bounds` — the WHOLE PART — and
// there is no region or primitive input anywhere in the preview path. So the
// raymarched struts filled the entire part interior no matter which selectables
// were set to Lattice. Picture ≠ run, which on this project is a defect and not
// a cosmetic one: the whole page exists so the picture predicts the run.
//
// ★ THIS IS THE SAME PREDICATE CORE USES, IN THE SAME SHAPE. A lattice region is
// pure geometry (`LatticeRegionSpec`): a FACE slab is `origin + s·normal`,
// s ∈ [0, depth], clipped to 2·halfU × 2·halfW; a BOLT is a cylinder about
// `axisPoint + t·axisDir`, t ∈ [−halfLength, +halfLength]. Core evaluates them
// pointwise as `ClearanceGeometry` predicates; so does this. Nothing is
// approximated and nothing new is authored — if the two ever disagree it is
// because the SPEC changed, not because the picture drifted.
//
// ★ EMPTY MEANS "NO CLIPPING", DELIBERATELY. The lattice SETTINGS page previews a
// sample block with no regions declared at all ("A sample part. Your settings,
// not your result."), and clipping that to nothing would blank a preview whose
// job is to show the cell. So an empty region list leaves the occupancy exactly
// as it was — which is also what makes this change inert for every surface that
// does not declare regions.
//
// Pure Float math over the grid, headlessly testable, no GPU.

import Foundation
import simd

public enum LatticeRegionMask {

    /// Is `p` (world mm) inside this region's geometry?
    ///
    /// ★ THE FACE SLAB'S AXES. `normal` already points INTO the part (the
    /// emission flips it), so `s` runs 0…depth going inward. The two in-plane
    /// axes are any orthonormal pair perpendicular to it — the extents are
    /// symmetric in both, so which pair does not matter, only that they are
    /// perpendicular and unit.
    public static func contains(_ p: SIMD3<Double>, region: LatticeRegionSpec) -> Bool {
        contains(p, region: region, inPlaneReachMM: 0)
    }

    /// `contains` over the WHOLE declared prism, ignoring any slab — what the slab's own
    /// builder scans, and the reference the sim rule normalises against.
    public static func containsWholePrism(_ p: SIMD3<Double>, region: LatticeRegionSpec) -> Bool {
        var whole = region
        whole.thicknessMap = nil
        return contains(p, region: whole, inPlaneReachMM: 0)
    }

    /// ★★★ `contains`, WITH THE IN-PLANE TEST RELAXED BY `inPlaneReachMM` — for
    /// deciding which base cells a face OWNS, as distinct from where its material is
    /// (2026-08-27).
    ///
    /// ★ WHY OWNERSHIP IS A WIDER QUESTION THAN CONTAINMENT. The cell field is one
    /// value per base cell, and a cell is emitted only if its centre passes this test.
    /// A base cell straddling the face's outline — centre just outside, most of its
    /// volume inside — was therefore not owned by anybody, emitted nothing, and left a
    /// band up to half a cell wide with no struts in it. That is the "empty areas just
    /// at the ends" (maintainer, 2026-08-27), and his rule for it is:
    ///
    ///     "this is where the grade to fit should go in if it's applied — if it's not
    ///      applied, the cell should just be cut off where it ends."
    ///
    /// Both halves fall out of simply OWNING the cell. With grade to shape on, the fit
    /// distance at such a centre is 0, so the ladder runs to its cap and the cell goes
    /// SOLID — "graded until it becomes a solid". With it off the cell keeps its full
    /// size and the march's `dClip` (which unions the region's own SDF) cuts its struts
    /// flush at the outline — "cut off where it ends".
    ///
    /// ★ AND WIDENING THE PAINT CANNOT LEAK MATERIAL. `dClip` is `max(partClip, bbox,
    /// dRegion)` and `dRegion` is sampled from the SAME field the shell's hole is cut
    /// from — untouched by this. A wider owner can therefore only ADD material inside
    /// the declared face where there was none; it can never place a strut outside it.
    ///
    /// ★ THE DEPTH SLAB IS NOT RELAXED. His ruling: *"the face-prism only makes what's
    /// solid into lattice, it cannot make walls thicker."* The cap planes stay flush by
    /// construction, so the reach is in-plane ONLY.
    public static func contains(_ p: SIMD3<Double>, region: LatticeRegionSpec,
                                inPlaneReachMM: Double) -> Bool {
        let reach = Swift.max(0, inPlaneReachMM)
        switch region.kind {
        case .face:
            let n = unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { return false }
            let d = p - region.origin
            let s = simd_dot(d, n)
            let (u, v) = basis(n)
            let uv = SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            let (s0, s1) = region.slabRange(uv: uv)     // the slab, or the whole prism
            guard s >= s0, s <= s1 else { return false }
            // ★★ THE OUTLINE WINS WHEN THERE IS ONE. The rectangle was the face's
            // BOUNDING BOX — 41.2% and 29.8% of the emitted region was actually
            // the face on his two lattice walls, and the rest was solid material
            // the struts were drawn into. See `LatticeFaceOutline`.
            if !region.outlineLoops.isEmpty {
                if !region.outlineSeamTilt.isEmpty,
                   LatticeFaceOutline.insideWithFlare(uv, loops: region.outlineLoops, seams: region.outlineSeams,
                                                      tilts: region.outlineSeamTilt, caps: region.outlineSeamDepthMM, depth: s) {
                    // ★ a NEGATIVE expand still shrinks the outline (2026-09-23): the flare
                    // answered "inside" for every point of the polygon, so a shrunk region
                    // with seams never shrank. The shrink is measured to the non-seam edges.
                    let shrink = region.inPlaneOffsetMM + reach
                    if shrink < 0 {
                        let sd = LatticeFaceOutline.signedDistance(uv, loops: region.outlineLoops, seams: region.outlineSeams)
                        return sd <= shrink || abs(sd) >= -shrink
                    }
                    return true
                }
                return LatticeFaceOutline.signedDistance(uv, loops: region.outlineLoops, seams: region.outlineSeams)
                    <= region.inPlaneOffsetMM + reach
            }
            // ★★★ THE RECTANGLE IS A MANUAL PRIMITIVE'S OWN SHAPE, AND NOTHING ELSE'S.
            // A primitive the user placed and dragged IS a box — measuring it as one is
            // exact. A B-REP FACE is not: its rectangle is a bounding box that was 41.2%
            // and 29.8% face on his two lattice walls, so falling back to it declares
            // material he never marked. A face-derived region reaches this line only if
            // its outline could not be built, and `LatticeRegionEmission` now refuses to
            // emit that region at all — so it is counted as skipped and SAID, rather
            // than silently replaced with a shape 2.4x too big. See `faceID`.
            guard region.faceID == nil else { return false }
            return abs(uv.x) <= region.halfUMM + reach
                && abs(uv.y) <= region.halfWMM + reach
        case .bolt:
            let a = unit(region.axisDir)
            guard simd_length(a) > 0.5, region.radiusMM > 0 else { return false }
            let d = p - region.axisPoint
            let t = simd_dot(d, a)
            // A bolt's "in-plane" is radial; its length is the depth axis.
            guard abs(t) <= region.halfLengthMM else { return false }
            return simd_length(d - a * t) <= region.radiusMM + reach
        }
    }

    /// ★ SIGNED DISTANCE (mm, negative inside) to ONE region — the same set
    /// `contains` describes, as a distance so it can be baked into a field and
    /// sphere-traced. Extrusion of the in-plane shape along the depth axis:
    /// `length(max(q,0)) + min(max(q),0)` with q = (in-plane, along-depth).
    /// ★ HOW FAR IN FROM A FACE'S OUTLINE a point sits (mm, negative outside), for
    /// the nearest include face region whose slab holds the point; 1e3 where no such
    /// region exists. The stepped preview's SOLID OUTLINE is drawn from this per voxel
    /// (his 2026-09-14 rule: "a solid outline that wraps the lattice in the shape of
    /// the face-prism's outline"), against the raw part surface — never through the
    /// strut clip's surface hold, which is what swallowed every "solid" cell before.
    /// `slabMarginMM` extends the slab test past the caps: the value is baked per
    /// VOXEL and sampled trilinearly, so a "far" voxel just outside the face plane
    /// blends into the first voxel under it and the solid skin vanished exactly in
    /// the layer seen face-on (his "the solid is barely visible", 2026-09-15).
    public static func outlineDistance(_ p: SIMD3<Double>,
                                       regions: [LatticeRegionSpec],
                                       slabMarginMM: Double = 0) -> Double {
        // ★ 1e9 is the "no region answered" sentinel; the far value handed back is the
        // old 1e3 (the full suite of 2026-09-22 caught `best` starting at 1e3 against a
        // 1e9 sentinel test — the union's max then never left 1e3 and the organic band
        // graded 0 voxels).
        // ★ THE NEAREST OUTLINE AMONG THE REGIONS THAT CONTAIN THE POINT (his 2026-09-23,
        // image 3: the band "just stops half way up the curve" — exactly where face 23's
        // prism overlaps face 2's: the union's MAX took face 23's large distance and the
        // band vanished). Inside the union the band is the distance to the nearest true
        // outline of any region the point is in; outside, the nearest region's edge.
        var best = 1e9
        var bestInside = 1e9
        for region in regions where region.role == .include && region.kind == .face
            && !region.outlineLoops.isEmpty {
            let n = unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let d = p - region.origin
            let s = simd_dot(d, n)
            let along = abs(s - 0.5 * region.depthMM) - 0.5 * region.depthMM
            guard along <= slabMarginMM else { continue }
            let (u, v) = basis(n)
            let uv = SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            let inside = -(LatticeFaceOutline.signedDistance(uv, loops: region.outlineLoops, seams: region.outlineSeams)
                           - region.inPlaneOffsetMM)
            // ★ THE UNION (2026-09-22): the regions overlap at every seam (facets, corners),
            // and `min` made a point deep inside one prism read as OUTSIDE its neighbour's
            // outline — the band, the bleed and the strut clip then walled every seam. A
            // union's inside distance is the MAX over its members.
            if inside > 0 { bestInside = Swift.min(bestInside, inside) }
            best = best == 1e9 ? inside : Swift.max(best, inside)
        }
        if bestInside < 1e9 { return bestInside }
        return best == 1e9 ? 1e3 : best
    }

    /// ★★★ THE OUTLINE ONLY WHERE THE PART'S SOLID BACKS IT (his rules, 2026-09-23: green
    /// only where there is skin or rim, never facing air; the rim outlines the whole
    /// lattice except at seams). For each region containing `p`, the nearest point on its
    /// grown outline is found and a probe placed one `stepMM` beyond it, at the same
    /// depth; the outline counts when `solidAt` says the part is there and the probe is
    /// not inside any prism (a seam). Returns the in-plane distance to the nearest backed
    /// outline, or 1e3 when none is.
    public static func solidBackedOutlineDistance(_ p: SIMD3<Double>,
                                                  regions: [LatticeRegionSpec],
                                                  slabMarginMM: Double,
                                                  stepMM: Double,
                                                  solidAt: (SIMD3<Double>) -> Bool) -> Double {
        var best = 1e3
        for region in regions where region.role == .include && region.kind == .face
            && !region.outlineLoops.isEmpty {
            let n = unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { continue }
            let d = p - region.origin
            let s = simd_dot(d, n)
            let along = abs(s - 0.5 * region.depthMM) - 0.5 * region.depthMM
            guard along <= slabMarginMM else { continue }
            let (u, v) = basis(n)
            let uv = SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            guard let near = LatticeFaceOutline.nearestPoint(uv, loops: region.outlineLoops,
                                                              seams: region.outlineSeams) else { continue }
            // distance to the GROWN outline: inside the raw polygon it is raw + offset,
            // in the expand ring it is offset − raw; beyond the grown outline, outside
            // (negative beyond the grown outline, so the sampled field is continuous across it)
            let grown = near.inside ? near.dist + region.inPlaneOffsetMM : region.inPlaneOffsetMM - near.dist
            let edgeUV = near.point + near.outward * region.inPlaneOffsetMM
            let probeUV = edgeUV + near.outward * stepMM
            let probe = region.origin + u * probeUV.x + v * probeUV.y + n * s
            guard solidAt(probe), signedDistanceWholePrism(probe, regions: regions) > 0 else { continue }
            best = Swift.min(best, grown)
        }
        return best
    }

    public static func signedDistance(_ p: SIMD3<Double>,
                                      region: LatticeRegionSpec) -> Double {
        let big = 1e9
        switch region.kind {
        case .face:
            let n = unit(region.normal)
            guard simd_length(n) > 0.5, region.depthMM > 0 else { return big }
            let d = p - region.origin
            let s = simd_dot(d, n)
            let (u, v) = basis(n)
            let uv = SIMD2<Double>(simd_dot(d, u), simd_dot(d, v))
            // ★ THE SLAB (2026-09-21): the whole prism unless a thickness map says
            // otherwise — then [start, end(uv)] along the normal, so every reader of
            // this distance (the shell clip, the march, the candidates, the octree)
            // sees the one slab. See `LatticeWallThickness`.
            let (s0, s1) = region.slabRange(uv: uv)
            let half = 0.5 * Swift.max(0, s1 - s0)
            let along = abs(s - (s0 + half)) - half
            // ★ THE OUTLINE DISTANCE IS THE EXPENSIVE TERM — O(outline vertices)
            // per voxel, and the field is baked over the whole part bbox. Measured
            // on his face 15 (63 vertices) it took the scene bake from 3.70 s to
            // 17.45 s, a 4.7x regression on something that rebakes whenever a
            // setting moves.
            //
            // ★ OUTSIDE THE DEPTH SLAB IT IS NOT NEEDED. The extrusion is
            // `length(max(q,0)) + min(max(q),0)` with q = (inPlane, along), so
            // whenever `along > 0` the true distance is at least `along`.
            // Returning `along` there is an UNDER-estimate of a distance, which is
            // the safe direction for both readers: a sphere trace takes a shorter
            // step (never overshoots), and the `<= 0` inside-test is unaffected
            // because `along > 0` already means outside. Most of the bbox is far
            // from an 11 mm slab, so this skips the polygon for the large majority
            // of voxels.
            if along > 0 { return along }
            let inPlane: Double
            if !region.outlineLoops.isEmpty {
                var sd = LatticeFaceOutline.signedDistance(uv, loops: region.outlineLoops, seams: region.outlineSeams)
                // ★ the flared seams (2026-09-22): the sign follows the bisector planes
                if !region.outlineSeamTilt.isEmpty {
                    let inside = LatticeFaceOutline.insideWithFlare(uv, loops: region.outlineLoops, seams: region.outlineSeams,
                                                                    tilts: region.outlineSeamTilt, caps: region.outlineSeamDepthMM, depth: Swift.max(0, s))
                    sd = inside ? -abs(sd) : abs(sd)
                }
                inPlane = sd - region.inPlaneOffsetMM
            } else if region.faceID == nil {
                // A manual primitive's own box — see `contains` for why a FACE never
                // gets this fallback.
                let q = SIMD2<Double>(abs(uv.x) - region.halfUMM, abs(uv.y) - region.halfWMM)
                inPlane = simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, q.y), 0)
            } else {
                return big
            }
            let q = SIMD2<Double>(inPlane, along)
            return simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, q.y), 0)
        case .bolt:
            let a = unit(region.axisDir)
            guard simd_length(a) > 0.5, region.radiusMM > 0 else { return big }
            let d = p - region.axisPoint
            let t = simd_dot(d, a)
            let q = SIMD2<Double>(simd_length(d - a * t) - region.radiusMM,
                                  abs(t) - region.halfLengthMM)
            return simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, q.y), 0)
        }
    }

    /// The UNION of the include regions, as a distance. `+big` when nothing is
    /// declared — the caller decides what "no regions" means (see
    /// `EmptyRegionPolicy`), this function only reports the geometry.
    public static func signedDistance(_ p: SIMD3<Double>,
                                      regions: [LatticeRegionSpec]) -> Double {
        var best = 1e9
        for r in regions where r.role == .include {
            best = Swift.min(best, signedDistance(p, region: r))
        }
        return best
    }
    /// ★★★ THE POCKET (his 2026-09-21 23:17, images 5–8: "Walls should never take the
    /// place of the empty or too little lattice! Ever!"). A declared region is the whole
    /// prism of material REMOVED; the slab only says where inside it the lattice goes.
    /// The shell opens and the body is carved over the WHOLE prism; where the slab is
    /// thin or absent there is air, never the part's own wall. Readers that PLACE
    /// lattice (candidates, cells, the slab mesh) keep the slab-aware distance above.
    public static func signedDistanceWholePrism(_ p: SIMD3<Double>,
                                                regions: [LatticeRegionSpec]) -> Double {
        var best = 1e9
        for r in regions where r.role == .include {
            var whole = r
            whole.thicknessMap = nil
            best = Swift.min(best, signedDistance(p, region: whole))
        }
        return best
    }

    /// True when `p` is inside ANY of the regions that will actually be latticed.
    ///
    /// ★ ONLY `include` REGIONS COUNT. An `exclude` region is frozen SOLID — it
    /// carries no lattice at all — so showing struts there would be the same lie
    /// in the other direction.
    public static func contains(_ p: SIMD3<Double>, regions: [LatticeRegionSpec]) -> Bool {
        for r in regions where r.role == .include {
            if contains(p, region: r) { return true }
        }
        return false
    }

    /// ★ CLIP AN OCCUPANCY GRID TO THE DECLARED REGIONS.
    ///
    /// Returns the grid unchanged when no INCLUDE region is declared — see the
    /// file note: the settings page's sample block has none, and blanking it
    /// would break a preview whose job is to show the cell.
    /// ★★ WHAT AN EMPTY REGION LIST MEANS — AND IT IS NOT ONE ANSWER
    /// (maintainer, 2026-08-18: "Why does the lattice preview show the *entire*
    /// model as lattice? It should only show the regions that have been set as
    /// 'Lattice'. Everything else should stay solid").
    ///
    /// ★ THE DEFECT WAS AN IMPLICIT DEFAULT. `clipped` returned the grid
    /// UNCHANGED when no include region existed — correct for the settings
    /// page's sample block, where there are no regions by construction and the
    /// whole sample should lattice, and catastrophically wrong on the STAGE,
    /// where "no include region" means the user has declared nothing and the
    /// honest picture is a solid part. One function, two callers, opposite
    /// needs, and no way to tell them apart — so the caller says which.
    public enum EmptyRegionPolicy: Equatable, Sendable {
        /// No regions ⇒ the whole grid latticed. The settings-page SAMPLE, whose
        /// entire subject is the lattice itself.
        case latticeEverything
        /// No regions ⇒ nothing latticed. The STAGE: the user has declared no
        /// lattice, so none is drawn.
        case latticeNothing
    }

    /// ★ THE SAME CLIP OVER THE WHOLE PRISM (review 2026-09-22 #21): the slab-clipped
    /// grid is where LATTICE goes; the measurers — the wall width along the normal, the
    /// rim's attachment seed, the in-plane boundary distance, the octree's "is there
    /// material here" — must read the whole declared prism, or every slab edge reads
    /// as a boundary and grows a rim, a cap, or a solid wall across the pocket.
    public static func clippedWholePrism(_ grid: LatticeVoxelGrid,
                                         to regions: [LatticeRegionSpec],
                                         whenEmpty: EmptyRegionPolicy = .latticeEverything)
        -> LatticeVoxelGrid {
        var whole = regions
        for i in whole.indices { whole[i].thicknessMap = nil }
        return clipped(grid, to: whole, whenEmpty: whenEmpty)
    }

    public static func clipped(_ grid: LatticeVoxelGrid,
                               to regions: [LatticeRegionSpec],
                               whenEmpty: EmptyRegionPolicy = .latticeEverything)
        -> LatticeVoxelGrid {
        guard regions.contains(where: { $0.role == .include }) else {
            switch whenEmpty {
            case .latticeEverything: return grid
            case .latticeNothing:
                var out = grid
                for i in 0..<out.values.count { out.values[i] = 0 }
                return out
            }
        }
        var out = grid
        var i = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for x in 0..<grid.nx {
                    if out.values[i] != 0 {
                        let p = SIMD3<Double>(
                            Double(grid.origin.x) + Double(x) * Double(grid.spacing.x),
                            Double(grid.origin.y) + Double(j) * Double(grid.spacing.y),
                            Double(grid.origin.z) + Double(k) * Double(grid.spacing.z))
                        if !contains(p, regions: regions) { out.values[i] = 0 }
                    }
                    i += 1
                }
            }
        }
        return out
    }

    /// ★ A DEMAND FIELD THAT ENCODES EACH REGION'S OWN DENSITY (maintainer,
    /// 2026-08-17: "Density is controllable in each region - but it is not
    /// updating the lattice preview of it").
    ///
    /// ★ WHY A DEMAND FIELD AND NOT A SECOND UNIFORM. The raymarcher grades a
    /// strut's radius from ONE number per cell — `uniformRho` when there is no
    /// demand grid, and otherwise
    ///
    ///     rho = rhoMin + (rhoMax - rhoMin) * pow(demand, gamma)
    ///
    /// So a preview that shows two regions at two densities needs a PER-CELL
    /// input, which is exactly what the demand grid is. Inverting that mapping
    /// gives the demand value each region must carry to come out at its own rho:
    ///
    ///     demand = ((rho - rhoMin) / (rhoMax - rhoMin)) ^ (1 / gamma)
    ///
    /// — so nothing about the shader changes, and the number on the card is the
    /// number the struts are drawn at.
    ///
    /// Returns nil when NO region states a density: there is then nothing to
    /// grade by and the caller should keep whatever field it already had (the
    /// run's stress field, or none at all).
    public static func densityDemand(like grid: LatticeVoxelGrid,
                                     regions: [LatticeRegionSpec],
                                     rhoMin: Double, rhoMax: Double,
                                     gamma: Double) -> LatticeVoxelGrid? {
        let stated = regions.filter {
            $0.role == .include && ($0.relativeDensity ?? 0) > 0
        }
        guard !stated.isEmpty, rhoMax > rhoMin, gamma > 0 else { return nil }

        /// The demand value that comes back out of the shader as `rho`.
        func demand(for rho: Double) -> Float {
            let t = (rho - rhoMin) / (rhoMax - rhoMin)
            return Float(pow(Swift.min(Swift.max(t, 0), 1), 1.0 / gamma))
        }
        var out = grid
        var i = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for x in 0..<grid.nx {
                    let p = SIMD3<Double>(
                        Double(grid.origin.x) + Double(x) * Double(grid.spacing.x),
                        Double(grid.origin.y) + Double(j) * Double(grid.spacing.y),
                        Double(grid.origin.z) + Double(k) * Double(grid.spacing.z))
                    // The FIRST stating region that contains this voxel wins —
                    // the same first-match rule the emission's own region order
                    // gives the run, so the picture and the job agree about an
                    // overlap instead of averaging it into a third answer.
                    var d: Float = 0
                    for r in stated where contains(p, region: r) {
                        d = demand(for: r.relativeDensity ?? 0)
                        break
                    }
                    out.values[i] = d
                    i += 1
                }
            }
        }
        return out
    }

    // MARK: helpers

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : .zero
    }

    /// Any orthonormal pair perpendicular to `n`.
    /// ★★ CORE'S CONVENTION, EXACTLY — `u = cross(ref, n)`, not `cross(n, ref)`.
    ///
    /// ★ WHY THE ORDER IS LOAD-BEARING NOW. It never was: every quantity measured
    /// on this basis used to be a SYMMETRIC half-extent, and `±u` gives the same
    /// answer for `|u| <= halfU`. A face OUTLINE is not symmetric. Core resolves
    /// its own in-plane basis in `plane_basis` (core/src/voxel/clearance.cpp:24)
    /// as `u = normalize(cross(ref, normal))`, `w = cross(normal, u)`, and this
    /// was the mirror of it — so a polygon expressed here and tested there would
    /// arrive rotated 180° about the origin, latticing the wrong half of the
    /// face while every rectangle-based test stayed green.
    ///
    /// ★ SO THE APP MOVED TO CORE'S ORDER rather than negating at the wire. One
    /// convention, asserted against core's own formula in
    /// `LatticeOutlineWireTests` — a conversion at the boundary would have been a
    /// second place for the sign to be wrong.
    /// The same basis, reachable from tests. `basis` is the ONE pair containment is
    /// measured in, so a probe that builds its own would be measuring a different plane.
    static func basisForTests(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        basis(n)
    }

    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let a = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = unit(simd_cross(a, n))
        return (u, unit(simd_cross(n, u)))
    }
}
