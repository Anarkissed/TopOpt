import Foundation
import TopOptKit

/// ★ EACH REGION'S OCTET CELL (moved out of `WorkspacePlaceholder.latticeRegionCellsMM`,
/// 2026-09-28, so the probe that restores his project builds the SAME cells the app does —
/// a harness copy of a private rule drifts). The body is the view's, verbatim; the view
/// keeps its memo and calls this.
@MainActor
public enum LatticeRegionCells {
    /// One cell per region (0 for a non-include or a zero depth), `W / N*` of the region's own
    /// measured wall, divided a whole number of times across min(depth, wall).
    public static func cellsMM(project: ProjectModel, scene: LatticeSDFScene?,
                               regions: [LatticeRegionSpec], widthPercentile: Double,
                               quiltStep: Bool = false) -> [Double] {
        let bead = project.printParams.strutLineWidthMM
        guard bead > 0 else { return [] }
        return regions.enumerated().map { ri, r -> Double in
            guard r.role == .include, r.depthMM > 0 else { return 0 }
            // ★ THE REGION'S OWN MEASURED MATERIAL, not the depth the user typed —
            // the cell is W / N* for THIS region. Falls back to the declared depth
            // only when nothing is measured.
            var w = r.depthMM
            if let s = scene {
                // ★ THE WALL ALONG THIS FACE'S OWN NORMAL FIRST. Core's isotropic member
                // thickness reports the junction, not the wall, and the coarse cell that
                // buys is the quilt (see `wallWidthAlongNormalMM`). The isotropic measure
                // stays as the fallback — a bolt has no single direction to walk.
                let d = LatticeMeasuredRegionWidth.wallWidthAlongNormalMM(
                    region: r, occupancy: s.prismOccupancy, partSDF: s.partMaterialSDF,
                    percentile: widthPercentile)
                if d > 0 {
                    w = d
                } else if !s.memberThicknessMM.isEmpty {
                    let m = LatticeMeasuredRegionWidth.widthMM(
                        region: r, occupancy: s.occupancy,
                        memberThicknessMM: s.memberThicknessMM)
                    if m > 0 { w = m }
                }
            }
            // ★★★ AGAINST THE MODE'S OWN FLOOR. The cell is `width / floor`, and this
            // call used to leave the floor unstated — so it came back as core's
            // ACCURACY floor of 5 whatever the stage mode was, and his 11 mm wall
            // derived an 11.0/5 = 2.20 mm cell in a mode whose whole content is that
            // 2 cells across a member is enough. The aesthetic floor reached the
            // per-VOXEL planner and never reached this, the per-REGION cell that both
            // Fit and Stepped are built from.
            // ★ and under Structural with the beam-network certificate, the aesthetic
            // floor — see `regionCellsPerMemberFloor` (his 2026-09-20, the 2.4 mm wall).
            let floor = (project.lattice.stageMode ?? .structural)
                .regionCellsPerMemberFloor(topology: project.lattice.topologyID,
                                           boundaryFinishWritten: project.lattice.singleCellMembers,
                                           algorithm: project.lattice.resolvedAlgorithm)
            let d = TopOptKit.latticeRegionDerivation(topology: project.lattice.topologyID,
                                                      memberWidthMM: w,
                                                      minExtrudableWidthMM: bead,
                                                      cellsPerMemberFloor: floor)
            guard d.valid, d.cellMM > 0 else { return 0 }
            // ★★★ THE FIT DEPTH IS THE **MATERIAL'S**, NEVER THE DECLARATION'S
            // (his ruling, 2026-08-24 evening: "I'd rather it never overshoot —
            // that a 13mm cell never be on a 12mm wall; instead have a 12mm cell
            // on the 12mm wall"). A declared depth reaching past the wall is a
            // statement about the region, not about material that exists — the
            // walk measured the wall at `w`, and a cell obeying the depth alone
            // was 13.0 mm on his 12.03 mm wall. The whole-number fit now divides
            // min(depth, wall), so the cell equals the wall when the wall is the
            // binding constraint, and the cap-flush phase anchors to material
            // that is actually there.
            let effDepth = w > 0 ? Swift.min(r.depthMM, w) : r.depthMM
            // ★ THE WHOLE DERIVATION, SAID OUT LOUD. "On a 13 mm wall the main cell is
            // 4.3 mm — why is it so low?" is a question about four numbers, and every
            // previous answer I gave was inferred from the one at the end.
            NSLog("DIAG regionCell depth=\(r.depthMM) pct=\(widthPercentile) "
                  + "measuredW=\(w) floor=\(floor) effDepth=\(effDepth) "
                  + "coreCell=\(d.cellMM) n=\(Swift.max(1, (effDepth / d.cellMM).rounded())) "
                  + "final=\(effDepth / Swift.max(1, (effDepth / d.cellMM).rounded()))")
            // ★★★ A WHOLE NUMBER OF CELLS ACROSS THE DECLARED DEPTH (maintainer,
            // 2026-08-23: the back wall is quilted while the front is an open truss).
            //
            // ★ THE STRUTS ARE TRIMMED FLUSH AT THE REGION'S TWO CAP PLANES, and where
            // those planes fall INSIDE the cell is what you see. A cap on a cell boundary
            // leaves open cells — the truss he calls correct. A cap through the middle of
            // a cell slices every strut at its fattest, and those cross-sections nearly
            // touch: a surface of X-shaped bosses, which is the quilt. Measured on his own
            // two faces at a 6.93 mm cell:
            //
            //     region 0 (11.0 mm)   near cap phase 0.41   far cap 1.00   depth/cell 1.59
            //     region 1 (12.0 mm)   near cap phase 0.00   far cap 0.73   depth/cell 1.73
            //
            // One clean cap and one mid-cell cap EACH — one geometry showing two faces,
            // which is exactly what he photographed from the front and the back.
            //
            // ★ SO THE DEPTH IS DIVIDED A WHOLE NUMBER OF TIMES. Both caps then sit at
            // the SAME phase, and anchoring that phase to the face (see the bake's grid
            // origin) puts both on a cell boundary. Rounding never lands further than half
            // a cell from what the derivation asked for, and never below one cell across
            // the declared depth.
            var n = Swift.max(1, (effDepth / d.cellMM).rounded())
            // ★★★ AT THE QUILT, A SMALLER CELL — NEVER A THICKER STRUT (his 2026-09-28, face 2
            // at "20% · 2.26 mm strut · 12.03 mm cell": "It should not have the strut
            // thickness it has if it quilts - unless 'allow quilting' is selected. It should
            // be avoided at all costs - meaning make the cells smaller."). The octet's density
            // is capped at the non-quilt ceiling (strut 0.20 of the cell), so a wall whose
            // lattice is drawn AT that ceiling — a tenth of it in the top fifth of
            // [floor, ceiling] — takes one more whole cell across: the same density, half the
            // strut (12.03 → 6.015 mm cell, 2.26 → 1.13 mm strut). Only when the smaller cell
            // still prints open with a bead-wide strut, so the printability floor can never
            // push it back over the ceiling.
            if quiltStep, Self.stepsAtTheQuilt(project: project, scene: scene, region: ri,
                                               cellMM: effDepth / (n + 1), bead: bead) {
                n += 1
            }
            if quiltStep, let s = scene, ri < s.regionDrawnDensityP90.count, r.role == .include {
                NSLog("DIAG quiltStep r\(ri) p90 %.3f ceiling %.3f allowQuilt %@ → n %.0f cell %.3f",
                      s.regionDrawnDensityP90[ri], s.drawnCeilingRho, s.allowQuilt ? "yes" : "no", n, effDepth / n)
            }
            return effDepth / n
        }
    }

    /// The median drawn density that counts as AT the ceiling: the top fifth of [floor, ceiling].
    public nonisolated static let quiltTripFraction = 0.8

    /// ★ Does region `region` take one more cell across (see `cellsMM`)? The octet only, Allow
    /// quilt off, the region's p90 drawn density in the top fifth of [floor, ceiling], and
    /// the smaller cell `cellMM` printing open with a bead-wide strut.
    public static func stepsAtTheQuilt(project: ProjectModel, scene: LatticeSDFScene?, region: Int,
                                       cellMM: Double, bead: Double) -> Bool {
        guard let s = scene, !project.lattice.allowQuilt, !s.allowQuilt,
              region < s.regionDrawnDensityP90.count else { return false }
        guard let law = LatticeType.named(project.lattice.topologyID),   // no law: no octet rule (item a)
              law.hasAestheticCeiling, s.drawnCeilingRho < s.drawnBand.hi else { return false }
        return quiltTrips(p90: s.regionDrawnDensityP90[region], lo: s.drawnBand.lo, ceiling: s.drawnCeilingRho,
                          smallerCellFloor: law.printabilityDensityFloor(lineWidthMM: bead, cellMM: cellMM))
    }

    /// ★ THE RULE ITSELF, pure: a wall whose p90 drawn density is in the top fifth of
    /// [floor, ceiling] steps, provided the smaller cell's bead-wide strut still prints open
    /// (`finestRungMaxDensity`). His face 2: p90 0.219 at a 0.219 ceiling → steps; face 15:
    /// 0.080 → stays.
    public nonisolated static func quiltTrips(p90: Double, lo: Double, ceiling: Double, smallerCellFloor: Double) -> Bool {
        guard ceiling > lo else { return false }
        let trip = lo + quiltTripFraction * (ceiling - lo)
        return p90 >= trip && smallerCellFloor <= LatticePreviewOccupancy.finestRungMaxDensity + 1e-9
    }

    /// faceID → the user's own cell (mm), from the per-selectable store ("f:<group>:<face>").
    public static func statedCellByFace(_ lat: LatticeSettings) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for (key, mm) in lat.selectableCellMM where mm > 0 {
            if let last = key.split(separator: ":").last, let f = Int(last) { out[f] = mm }
        }
        return out
    }

    /// The stepped bake's cells as the app hands them to the renderer: the p50 derivation, a
    /// user-stated cell winning (`WorkspacePlaceholder.latticePreviewSteppedCells`).
    public static func steppedCellsMM(project: ProjectModel, scene: LatticeSDFScene?) -> [Double] {
        let regions = project.latticeJobRegions().regions
        var cells = cellsMM(project: project, scene: scene, regions: regions, widthPercentile: 0.5, quiltStep: true)
        let stated = statedCellByFace(project.lattice)
        for (i, r) in regions.enumerated() where i < cells.count {
            if let f = r.faceID, let mm = stated[f], mm > 0 { cells[i] = mm }
        }
        return cells
    }
}
