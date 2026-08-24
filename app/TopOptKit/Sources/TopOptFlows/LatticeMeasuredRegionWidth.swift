// LatticeMeasuredRegionWidth — the member width Auto and Fit size their cell from,
// MEASURED by core rather than read off the user's declaration.
//
// ★★ THE DEFECT (maintainer, 2026-08-20: "I made sure the walls here are *exactly*
// 20mm wide. That's 4mm cells 5x wide. Yet I am seeing holes, and much smaller sized
// cells than what should be expected when I put 'auto' on everything").
//
// He is right, and the arithmetic is not subtle. Both Auto's swept window and Fit's
// per-region cell were handed `region.depthMM` — HOW FAR THE LATTICE REACHES IN FROM
// THE DECLARED FACE — and used it as if it were the thickness of the member:
//
//     LatticeAutoPosture.applied(… regionWidthsMM: includes.map { $0.depthMM } …)
//
// Those are different quantities. The cells-per-member ceiling is W / N*, where W is
// the MATERIAL's thickness — the same `local_member_thickness_mm` core's own floor
// reads. A declared depth is a statement about the lattice, not about the wall.
// Measured, at his bead of 0.42 mm with N* = 5:
//
//     declared depth   5 mm  ->  Auto's window  1.09 mm     (his "tiny cells")
//     declared depth  10 mm  ->                 2.00 mm
//     declared depth  11 mm  ->                 2.20 mm
//     declared depth  20 mm  ->                 4.00 mm     (what a 20 mm wall holds)
//
// So declaring a lattice HALF WAY into a 20 mm wall halved the cell, on a wall whose
// material never changed. The error only ever runs one way — a declared depth cannot
// exceed the material it is declared into — so the cell was always too FINE, which is
// more struts, more plastic and longer bakes, the exact opposite of what he asked
// "minimize plastic" for.
//
// ★ AND IT EXPLAINS THE HOLES TOO. A finer cell needs a denser strut to clear one
// bead: at 4.00 mm on a 20 mm slab core plans 864 cells with ZERO rejections down to
// rho = 0.08, but the same slab at rho = 0.05 has every one of those 864 cells
// rejected `unprintable`. Driving the cell below what the wall can hold pushes the
// thin end of a graded band under the nozzle, and those cells fall back to solid —
// holes, in the middle of material thick enough to lattice.
//
// ★ THE MEASUREMENT IS CORE'S, NOT A SECOND ONE. The scene already carries
// `memberThicknessMM` — `topopt::local_member_thickness_mm` per occupancy voxel, the
// SAME field the cells-per-member floor tests against. Reading the window off that
// field is what makes the ceiling agree with the floor: the cell Auto reaches for is,
// by construction, one the floor will accept.

import Foundation
import simd

public enum LatticeMeasuredRegionWidth {

    /// The coarsest cell the latticed material can hold, expressed as ONE width in mm.
    /// Empty when core measured nothing.
    ///
    /// ★★★ IT RETURNS ONE WIDTH, AND THAT IS THE WHOLE POINT — A REGRESSION I SHIPPED
    /// AND HE CAUGHT IN ONE LOOK ("It's worse now....").
    ///
    /// The first version of this returned the THINNEST and THICKEST measured widths, on
    /// the reasoning that `autoWindowMM` wants a ceiling and a floor. That widened Auto's
    /// window from one rung to several — and core's swept planner then walks DOWN that
    /// ladder, not up. `plan_cell_sizes` takes the level printability DEMANDS:
    ///
    ///     if (all_candidates && need_max == L && cap_min >= L)   // need = finest that prints
    ///
    /// so every extra rung below the ceiling is a rung it will descend to. Handing it a
    /// wider ladder produced FINER cells over most of the part, and finer cells push the
    /// thin end of a graded band under the nozzle — which culls them to solid. Sparse
    /// clumps of struts in a mostly empty wall: strictly worse than the too-fine-but-
    /// uniform picture it replaced.
    ///
    /// ★ SO THE CEILING IS THE ONLY NUMBER TO GIVE IT. One width in means `loFit == hi`
    /// inside `autoWindowMM`, which means one rung, which means the planner has nowhere
    /// to descend to: every cell it plans is the coarsest the material holds. That is
    /// what "minimize plastic" asks for, and it is also what the code did BEFORE this
    /// file existed — the defect was never the single rung, it was that the rung was
    /// derived from the declared depth instead of the measured wall.
    ///
    /// ★ WHAT THIS DELIBERATELY DOES NOT DO. On a part whose regions differ in
    /// thickness, one rung at the thickest means the thinner ones are culled by the
    /// cells-per-member floor rather than given their own finer cell. That is a real
    /// limit and it is NOT repaired here: the mode that sizes each region separately is
    /// FIT, which picks `W / N*` per region by construction and culls nothing. Widening
    /// the swept window to imitate it does not work, for the reason above.
    ///
    /// - Note: `occupancy` is ALREADY masked to the declared regions, so every voxel
    ///   considered is material the lattice will actually be built into. A `+infinity`
    ///   width is core's "thicker than the EDT cap measured" sentinel; it cannot bound a
    ///   ceiling, so it is excluded rather than treated as a length.
    public static func boundsMM(occupancy: LatticeVoxelGrid,
                                memberThicknessMM: [Double]) -> [Double] {
        guard memberThicknessMM.count == occupancy.values.count else { return [] }
        var hi = 0.0
        for i in 0..<occupancy.values.count where occupancy.values[i] > 0.5 {
            let w = memberThicknessMM[i]
            guard w.isFinite, w > 0 else { continue }
            if w > hi { hi = w }
        }
        return hi > 0 ? [hi] : []
    }

    /// ★★★ THE CELL EACH VOXEL'S OWN MEMBER CAN HOLD — `width / N*`, per voxel.
    ///
    /// This is what `plan_cell_sizes_fit` calls `desired_cell_mm`, and handing it this
    /// array is the whole of "per local member". Core does the rest: per base cell it
    /// takes the CONSERVATIVE end (`want_min`, the thinnest member under that cell) and
    /// then "the coarsest ladder rung at or below its own derived cell. Never above."
    ///
    /// 0 marks a voxel with no derivation — outside the candidate set, or a width core
    /// did not measure. Core reads 0 as "not fitted" and skips it, which is why this
    /// returns 0 rather than guessing a cell there.
    ///
    /// `+infinity` is core's "thicker than the EDT cap" sentinel. It means the member is
    /// at least as wide as the cap, not that it is unbounded, so it is clamped to the
    /// cap's own width rather than producing an infinite cell. `capMM` is that cap in
    /// millimetres (`capRadiusVoxels * spacing`); pass 0 to skip those voxels entirely.
    /// ★★ AND A WALL TOO THIN FOR A PRINTABLE CELL ASKS FOR NOTHING — which is how it
    /// ends up SOLID rather than a hole (his rule, 2026-08-20: "Go solid").
    ///
    /// `baseCellMM` is the ladder's finest rung. Core's fit planner computes each base
    /// cell's level by climbing UP from 0 and then asserts what it emitted:
    ///
    ///     if (!(S <= want_min[c] * (1.0 + 1e-9)))
    ///         throw "plan_cell_sizes_fit: emitted a cell coarser than the derivation
    ///                asked for"
    ///
    /// so a voxel wanting a cell FINER than the base rung has no level to be given and
    /// core throws — which the bridge catches and returns as "no plan at all", taking
    /// the whole part's lattice with it. Measured on his `M2_verticalStand_THICK`: the
    /// thinnest member wants 0.738 mm against a finest-printable rung of 1.17 mm, and
    /// every fit call for the entire part failed on that one voxel class.
    ///
    /// Zero is core's own "no derivation ⇒ not fitted" marker (`if
    /// (!(desired_cell_mm[e] > 0.0)) continue;`), so those voxels are simply not
    /// latticed — left SOLID, which is what the run builds there anyway. Pass 0 to skip
    /// the clamp (every voxel asks, and the caller guarantees the ladder reaches).
    public static func desiredCellMM(occupancy: LatticeVoxelGrid,
                                     memberThicknessMM: [Double],
                                     minCellsPerMember nStar: Double,
                                     baseCellMM: Double = 0,
                                     capMM: Double = 0,
                                     // ★★ THE AESTHETIC FLOOR IS PER VOXEL, because the
                                     // rule it comes from is: core derives it from the
                                     // measured error curve and THIS voxel's own
                                     // utilisation, so a member carrying nothing may
                                     // hold a coarser cell than one carrying its
                                     // allowable. Empty ⇒ every voxel uses `nStar`,
                                     // which is the structural path unchanged.
                                     perVoxelFloor: [Double] = []) -> [Double] {
        guard memberThicknessMM.count == occupancy.values.count, nStar > 0 else { return [] }
        let usePerVoxel = perVoxelFloor.count == occupancy.values.count
        var out = [Double](repeating: 0, count: occupancy.values.count)
        for i in 0..<occupancy.values.count where occupancy.values[i] > 0.5 {
            let w = memberThicknessMM[i]
            // A non-positive per-voxel floor is not a licence to lattice anything: it
            // means core had no answer for that voxel, so the scene-wide floor stands.
            let n = usePerVoxel && perVoxelFloor[i] > 0 ? perVoxelFloor[i] : nStar
            var want = 0.0
            if w.isFinite, w > 0 {
                want = w / n
            } else if !w.isFinite, capMM > 0 {
                // At least the cap — the most this measurement can honestly claim.
                want = capMM / n
            }
            // Below the finest rung there is no cell to give, so ask for none.
            if baseCellMM > 0, want < baseCellMM * (1 - 1e-9) { want = 0 }
            out[i] = want
        }
        return out
    }

    /// ★★★ THE RUNG A MEMBER OF THIS WIDTH GETS — core's own rule, in one place.
    ///
    /// `plan_cell_sizes_fit` computes it as "the coarsest ladder rung at or below its own
    /// derived cell. Never above", by climbing from the base:
    ///
    ///     while (L + 1 <= Lmax && cell_mm_at_level(L + 1) <= want_min[c]) ++L;
    ///
    /// This is that loop. It exists as a function because the READOUT needs the same
    /// answer the BAKE gets: the tapped-strut callout was quoting a strut diameter
    /// computed at `params.cellMM` — the stored uniform 8.00 mm — while the march was
    /// drawing 2.25/4.50/9.00 mm cells. The number on screen did not describe the
    /// geometry on screen, and it read as a 0.83 mm CELL to the one person looking at it.
    ///
    /// - Note: core decides per BASE CELL from the thinnest member under it, so a point
    ///   near a thickness change can sit in a block that took one rung finer than this
    ///   returns. It is the same law on a slightly different domain, not a second law.
    public static func rungForWidthMM(_ widthMM: Double, minCellsPerMember nStar: Double,
                                      baseCellMM: Double, maxCellMM: Double) -> Double {
        guard nStar > 0, baseCellMM > 0, maxCellMM >= baseCellMM else { return 0 }
        let want = widthMM.isFinite ? widthMM / nStar : maxCellMM
        guard want >= baseCellMM * (1 - 1e-9) else { return 0 }   // too thin ⇒ solid
        var cell = baseCellMM
        while cell * 2 <= Swift.min(want, maxCellMM) * (1 + 1e-9) { cell *= 2 }
        return cell
    }

    /// ★★★ WHERE THE LADDER IS ANCHORED — and it is the difference between a lattice and
    /// a haze of tiny struts.
    ///
    /// Core's ladder is DYADIC: every rung is a doubling, because that is what lets a
    /// coarse cell meet a fine one at shared nodes. So there is no rung between 2.77 and
    /// 5.54 mm, and a wall that can hold 4.43 mm falls all the way to 2.77 — about 2.5x
    /// more struts than it needs. WHERE the rungs land is therefore not a detail; it
    /// decides how much plastic the part uses.
    ///
    /// Anchoring on the part's DOMINANT member puts a rung exactly on the cell that the
    /// thickness the part is mostly made of can hold. Measured on his
    /// `M2_verticalStand_THICK` — walls at 22–24 mm (34% of it) and 44–46 mm (29%),
    /// against core's N* = 5 and his 0.45 mm bead:
    ///
    ///     anchor                       planned   culled   cells produced
    ///     his typed swept 3–8 mm ....     92%     3,302    all 3.00 mm
    ///     finest printable ..........    100%         0    1.17 mm mostly
    ///     the coarsest wall .........    100%         0    1.38 / 2.77 mm
    ///     THE DOMINANT WALL .........    100%         0    2.30 / 4.60 / 9.20 mm
    ///
    /// The last row is the one he asked for: 4.60 mm over the walls he built to 20 mm
    /// (the 0.6 is the +10% the 1.84 mm occupancy grid over-reads them by), 9.20 mm
    /// through the thick zones, 2.30 mm at the thin edges, and nothing refused.
    ///
    /// - Parameters:
    ///   - finestPrintableMM: the finest cell that prints at all. The ladder never goes
    ///     below it — a rung nothing can be printed at is not a rung.
    ///   - bucketMM: histogram bucket for finding the mode. Coarse enough that one wall
    ///     lands in one bucket despite the grid's own quantisation.
    /// - Returns: the base cell S0. 0 when nothing was measured.
    public static func ladderBaseCellMM(occupancy: LatticeVoxelGrid,
                                        memberThicknessMM: [Double],
                                        minCellsPerMember nStar: Double,
                                        finestPrintableMM: Double,
                                        bucketMM: Double = 2) -> Double {
        guard memberThicknessMM.count == occupancy.values.count, nStar > 0,
              finestPrintableMM > 0, bucketMM > 0 else { return 0 }
        var hist: [Int: Int] = [:]
        for i in 0..<occupancy.values.count where occupancy.values[i] > 0.5 {
            let w = memberThicknessMM[i]
            guard w.isFinite, w > 0 else { continue }
            hist[Int(w / bucketMM), default: 0] += 1
        }
        // The most common bucket, ties broken toward the THICKER one — a coarser anchor
        // uses less plastic, and the finer walls are still served by the rungs below it.
        var mode = -1, best = 0
        for (b, n) in hist where n > best || (n == best && b > mode) { best = n; mode = b }
        guard mode >= 0 else { return 0 }
        let dominantWidth = (Double(mode) + 0.5) * bucketMM
        let dominantCell = dominantWidth / nStar
        guard dominantCell > 0 else { return 0 }
        // Halve from that cell while the rung still prints; the last one that does is S0.
        var s0 = dominantCell
        while s0 / 2 >= finestPrintableMM { s0 /= 2 }
        // A dominant wall too thin to print even one cell leaves nothing to anchor to;
        // the printable floor is then the only honest base.
        return Swift.max(s0, finestPrintableMM)
    }

    /// The measured member width under ONE declared region, in mm — Fit's and Stepped's
    /// own question, asked of the material instead of the declaration.
    ///
    /// Fit and Stepped size each region independently at `W / N*`, so they need a single
    /// number per region rather than a ladder. That number is the width the region can
    /// hold EVERYWHERE — the 5th percentile of the measured thickness under it.
    ///
    /// ★★★ A LOW PERCENTILE, NOT THE MIDDLE ONE (maintainer, 2026-08-23: "the back-wall
    /// … has a big hole in the center", "Make it *CONSISTENT* with the first wall").
    ///
    /// ★ THE CELL HAS TO BE HOLDABLE BY THE WHOLE REGION, NOT BY HALF OF IT. The floor is
    /// `width/cell >= N*` PER VOXEL, so a cell derived from the median is refused
    /// everywhere the region is thinner than the median — and a face prism reaches past
    /// the wall it was declared on into whatever junction is behind it, which drags the
    /// median up. Measured on his own two declared faces at his 10 mm depth, N* = 2:
    ///
    ///     statistic   region 0 cell / culled     region 1 cell / culled
    ///     median          6.93 mm /  0%             13.86 mm / 28%
    ///     p10             6.93 mm /  0%             10.39 mm /  8%
    ///     p05             6.93 mm /  0%              6.93 mm /  1%
    ///     min             3.46 mm /  0%              3.46 mm /  0%
    ///
    /// His region 1 runs 6.93 mm to 48.51 mm of material. At the median a QUARTER of that
    /// wall cannot hold its own cell and is culled to solid — the hole in the middle of
    /// the back wall, and why it does not match the front. p05 gives BOTH walls the same
    /// 6.93 mm cell and culls 1%.
    ///
    /// ★ AND NOT THE MINIMUM. The minimum culls nothing by construction, but it sizes the
    /// whole region for its single thinnest voxel — 3.46 mm here, halving a cell that
    /// 99% of the region could have held. p05 is the coarsest cell that still leaves the
    /// region essentially uncut, which is the trade this number exists to make.
    ///
    /// ★ A PERCENTILE OF MEASURED VALUES, so an exactly-20 mm wall still reports 20.00 —
    /// the reason this is not a bucketed mode ("I made sure the walls here are *exactly*
    /// 20mm wide. That's 4mm cells 5x wide.").
    ///
    /// ★★★ IT USED TO BE THE MAXIMUM, AND THAT IS WHY STEPPED DREW NOTHING ON HIS PART
    /// (maintainer, 2026-08-22, four rounds of "I attempted a Stepped lattice preview and
    /// it didn't work").
    ///
    /// ★ THE THICKEST VOXEL UNDER A REGION IS NOT THE REGION'S MEMBER. `memberThicknessMM`
    /// is core's local member thickness of the WHOLE PART, and a face region is a prism
    /// that necessarily reaches past the wall it was declared on — on his part an 11 mm
    /// slab on a 9 mm wall contains voxels where the wall meets the base and the part
    /// measures 45.95 mm thick. Taking the max sized that region at 45.95 / 2 = 22.98 mm.
    ///
    /// ★ AND THE ARGUMENT THAT DEFENDED THE MAX IS THE ONE THAT FAILS. It was "core's
    /// per-voxel floor still culls the cells that land on thinner material" — true, and
    /// on his part the culling removes EVERY cell: a 22.98 mm cell needs 45.95 mm of
    /// member and nothing in his declared slab is that thick, so `steppedCellField`
    /// returned nil and the preview silently drew the DOUBLED LADDER instead. Measured on
    /// his part at Balanced 96, aesthetic, N* = 2:
    ///
    ///     width statistic          width      cell     stepped bake
    ///     max (what this was)      45.95 mm   22.98 mm  NOTHING
    ///     p90                      41.36 mm   20.68 mm  NOTHING
    ///     p05 (this)                6.93 mm    3.46 mm  latticed, both walls alike
    ///
    /// 4.60 mm is also inside the 4-8 mm window his page states, which the 22.98 mm the
    /// maximum produced was not.
    ///
    /// ★ `+infinity` IS CORE'S "THICKER THAN THE EDT CAP" SENTINEL, not a measurement,
    /// and it is excluded — a handful of capped voxels would otherwise drag the median
    /// to infinity and take the whole region with it.
    ///
    /// Returns 0 when core measured nothing under the region, and the caller must then
    /// fall back rather than invent a width.
    public static func widthMM(region: LatticeRegionSpec,
                               occupancy: LatticeVoxelGrid,
                               memberThicknessMM: [Double]) -> Double {
        guard memberThicknessMM.count == occupancy.values.count else { return 0 }
        var seen: [Double] = []
        for k in 0..<occupancy.nz {
            for j in 0..<occupancy.ny {
                for i in 0..<occupancy.nx {
                    let n = (k * occupancy.ny + j) * occupancy.nx + i
                    guard occupancy.values[n] > 0.5 else { continue }
                    let w = memberThicknessMM[n]
                    guard w.isFinite, w > 0 else { continue }
                    let p = SIMD3<Double>(
                        Double(occupancy.origin.x) + Double(i) * Double(occupancy.spacing.x),
                        Double(occupancy.origin.y) + Double(j) * Double(occupancy.spacing.y),
                        Double(occupancy.origin.z) + Double(k) * Double(occupancy.spacing.z))
                    if LatticeRegionMask.contains(p, region: region) { seen.append(w) }
                }
            }
        }
        guard !seen.isEmpty else { return 0 }
        seen.sort()
        return seen[Swift.min(seen.count - 1, Int(0.05 * Double(seen.count - 1)))]
    }

    /// ★★★ THE WALL, ALONG THE FACE'S OWN NORMAL — not the largest sphere that fits
    /// (maintainer, 2026-08-23: the back wall is "still quilted on part of it", and the
    /// quilt is the UPPER part, where the two walls meet).
    ///
    /// ★ `memberThicknessMM` IS ISOTROPIC, AND A JUNCTION IS NOT A THICK WALL. Core's
    /// local member thickness is the largest inscribed sphere; where two walls meet, that
    /// sphere spans BOTH of them and reports material several times thicker than either.
    /// The cell is `width / N*`, so a corner buys a coarse cell — and a coarse cell in a
    /// thin wall is the quilt. It appears at the junction and nowhere else, which is
    /// exactly where he sees it.
    ///
    /// ★ A FACE REGION HAS A DIRECTION, SO ITS WIDTH SHOULD TOO. The user declared a
    /// depth ALONG a face normal; the material that has to hold the cell is the wall
    /// measured in that same direction. Walked here through the occupancy, both ways from
    /// each voxel, which is the wall's own thickness and nothing else's.
    ///
    /// Measured on his two declared faces (Fast 64):
    ///
    ///                     isotropic EDT                along the normal
    ///     region 0    p05 13.86  med 13.86  p95 48.51   10.39  10.39  10.39
    ///     region 1    p05 13.86  med 27.72  p95 48.51   10.39  13.86  13.86
    ///
    /// The walls are 10.4-13.9 mm. The isotropic number reaches 48.51 — up to 4.7x the
    /// wall — and it is that inflation, not the wall, that the cell was being derived
    /// from. Along the normal the thickness is nearly constant inside a region, which is
    /// what a wall actually is.
    ///
    /// Returns 0 for a region with no normal (a bolt has no single direction), and the
    /// caller falls back to the isotropic measure rather than inventing one.
    /// ★★★ THE WALK MUST BE THROUGH THE **PART**, NOT THROUGH THE REGION.
    ///
    /// ★ THIS MEASURED THE DECLARATION AND CALLED IT THE MATERIAL. `occ` is
    /// `scene.occupancy`, which is `LatticeRegionMask.clipped(solid, to: regions)` — it
    /// is ALREADY cut to the region. So the walk along the normal stopped at the
    /// region's own cap planes and returned the DEPTH THE USER TYPED, every time. Every
    /// cell the preview has ever shown was therefore `depth / floor`: 12 mm -> 6.00,
    /// 11 mm -> 5.50, 13 mm -> 4.33. The measurement that exists to read his part has
    /// been reading his input back to him.
    ///
    /// `partSDF` (negative inside the part, on the same grid) is the material itself, so
    /// the walk now leaves the region and stops at the real wall. The ENUMERATION still
    /// uses `occ` — only voxels in the region get a vote, which is what makes it "this
    /// region's wall" rather than the whole part's.
    ///
    /// nil `partSDF` keeps the old region-bounded behaviour, so a caller that has no
    /// part field is unchanged rather than silently measuring something else.
    public static func wallWidthAlongNormalMM(region: LatticeRegionSpec,
                                              occupancy occ: LatticeVoxelGrid,
                                              partSDF: LatticeVoxelGrid? = nil) -> Double {
        guard region.kind == .face else { return 0 }
        let n = simd_normalize(region.normal)
        guard simd_length(n) > 0.5 else { return 0 }
        let h = Double(Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z)))
        guard h > 0 else { return 0 }
        func solid(_ p: SIMD3<Double>) -> Bool {
            if let sdf = partSDF {
                let g = (SIMD3<Float>(p) - sdf.origin) / sdf.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, a < sdf.nx, b >= 0, b < sdf.ny, c >= 0, c < sdf.nz
                else { return false }
                return sdf.values[(c * sdf.ny + b) * sdf.nx + a] < 0
            }
            let g = (SIMD3<Float>(p) - occ.origin) / occ.spacing
            let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
            guard a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz else { return false }
            return occ.values[(c * occ.ny + b) * occ.nx + a] > 0.5
        }
        // A bound on the walk so a mis-oriented normal cannot run the length of the part.
        let cap = 4.0 * Double(Swift.max(occ.spacing.x * Float(occ.nx),
                                         Swift.max(occ.spacing.y * Float(occ.ny),
                                                   occ.spacing.z * Float(occ.nz))))
        var seen: [Double] = []
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let idx = (k * occ.ny + j) * occ.nx + i
                    guard occ.values[idx] > 0.5 else { continue }
                    let p = SIMD3<Double>(
                        Double(occ.origin.x) + Double(i) * Double(occ.spacing.x),
                        Double(occ.origin.y) + Double(j) * Double(occ.spacing.y),
                        Double(occ.origin.z) + Double(k) * Double(occ.spacing.z))
                    guard LatticeRegionMask.contains(p, region: region) else { continue }
                    var fwd = 0.0, back = 0.0
                    var q = p
                    while fwd < cap, solid(q + n * h) { q += n * h; fwd += h }
                    q = p
                    while back < cap, solid(q - n * h) { q -= n * h; back += h }
                    seen.append(fwd + back + h)
                }
            }
        }
        guard !seen.isEmpty else { return 0 }
        seen.sort()
        // The same conservative end the isotropic measure takes, for the same reason:
        // the cell has to be holdable by the whole wall, not by half of it.
        return seen[Swift.min(seen.count - 1, Int(0.05 * Double(seen.count - 1)))]
    }
}
