import Foundation
import TopOptKit

/// ★ EACH REGION'S OCTET CELL (moved out of `WorkspacePlaceholder.latticeRegionCellsMM`,
/// 2026-09-28, so the probe that restores his project builds the SAME cells the app does —
/// a harness copy of a private rule drifts). The body is the view's, verbatim; the view
/// keeps its memo and calls this.
@MainActor
public enum LatticeRegionCells {
    /// One region's measured wall and the cell the bake lays there — the pair the drawer and
    /// the bake share (item 5, 2026-10-05: one number, one source).
    public struct RegionCell: Equatable, Sendable {
        public let measuredWidthMM: Double
        public let cellMM: Double
        /// ★ The cell BEFORE Default Grade's base rule (b) — the whole-number fit n₀. Equal to `cellMM` wherever (b)
        /// did not move it. The bake's "do no harm" guard (the reviewer, 2026-10-11 04:31) keeps this one when (b)'s
        /// candidate would leave more of the region uncovered.
        public let cellBeforeBaseRuleMM: Double
        public init(measuredWidthMM: Double, cellMM: Double, cellBeforeBaseRuleMM: Double? = nil) {
            self.measuredWidthMM = measuredWidthMM; self.cellMM = cellMM
            self.cellBeforeBaseRuleMM = cellBeforeBaseRuleMM ?? cellMM
        }
        public static let none = RegionCell(measuredWidthMM: 0, cellMM: 0)
    }

    /// One cell per region (0 for a non-include or a zero depth), `W / N*` of the region's own
    /// measured wall, divided a whole number of times across min(depth, wall).
    public static func cellsMM(project: ProjectModel, scene: LatticeSDFScene?,
                               regions: [LatticeRegionSpec], widthPercentile: Double,
                               quiltStep: Bool = false) -> [Double] {
        guard project.printParams.strutLineWidthMM > 0 else { return [] }
        return regionCells(project: project, scene: scene, regions: regions,
                           widthPercentile: widthPercentile, quiltStep: quiltStep).map(\.cellMM)
    }

    /// `cellsMM` with the wall each cell was derived from — the body is the bake's, once.
    public static func regionCells(project: ProjectModel, scene: LatticeSDFScene?,
                                   regions: [LatticeRegionSpec], widthPercentile: Double,
                                   quiltStep: Bool = false) -> [RegionCell] {
        let bead = project.printParams.strutLineWidthMM
        guard bead > 0 else { return [] }
        return regions.enumerated().map { ri, r -> RegionCell in
            guard r.role == .include, r.depthMM > 0 else { return .none }
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
            // ★ at the job's cap (#358 E1/D1): the region's cell is never under the run's floor
            let d = TopOptKit.latticeRegionDerivation(topology: project.lattice.topologyID,
                                                      memberWidthMM: w,
                                                      minExtrudableWidthMM: bead,
                                                      cellsPerMemberFloor: floor,
                                                      maxRelativeDensity: LatticeSettings.jobDensityCap(
                                                        topologyID: project.lattice.topologyID,
                                                        allowQuilt: project.lattice.allowQuilt,
                                                        algorithm: project.lattice.algorithm))
            guard d.valid, d.cellMM > 0 else { return RegionCell(measuredWidthMM: w, cellMM: 0) }
            // the job's tile floor: core's E1 at the cap the job writes (2.25 mm at a 0.45 mm bead)
            let tileFloor = LatticeSettings.tileFloorMM(topologyID: project.lattice.topologyID, beadMM: bead,
                                                        allowQuilt: project.lattice.allowQuilt) ?? 0
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
            var extra = 0
            if quiltStep, Self.stepsAtTheQuilt(project: project, scene: scene, region: ri,
                                               cellMM: effDepth / (n + 1), bead: bead) {
                n += 1
                extra = 1
            }
            if quiltStep, let s = scene, ri < s.regionDrawnDensityP90.count, r.role == .include {
                NSLog("DIAG quiltStep r\(ri) p90 %.3f ceiling %.3f allowQuilt %@ → n %.0f cell %.3f",
                      s.regionDrawnDensityP90[ri], s.drawnCeilingRho, s.allowQuilt ? "yes" : "no", n, effDepth / n)
            }
            var cell = Self.wholeCellsAcross(depthMM: effDepth, derivedCellMM: d.cellMM, tileFloorMM: tileFloor, extraCells: extra)
            let beforeBaseRule = cell
            // ★★ DEFAULT GRADE: A BASE WHOSE HALVES END AT THE FLOOR (the reviewer's ruling (b), 2026-10-11 00:35,
            // approved by the maintainer). His 68BF7B74 face 23 middle facet: a one-voxel move of its measured
            // wall took the cell 10.31 → 9.45, whose half 2.36 is over the floor but does not print open, so
            // the ladder ended at 4.73 — 342 cells and a see-through slit where 1,524 had been. Under Default
            // Grade the per-region bake's cell (quiltStep) takes the first whole-number fit whose halving
            // ladder ends at the floor, not at prints-open. Stepped's any-step menu has no such stop.
            if quiltStep, project.lattice.gradeStepsAreHalves, cell > 0 {
                let voxel = scene.map { Double(Swift.max($0.prismOccupancy.spacing.x,
                                                         Swift.max($0.prismOccupancy.spacing.y, $0.prismOccupancy.spacing.z))) } ?? 0
                let topology = project.lattice.topologyID
                let moved = Self.cellWhoseHalvesEndAtTheFloor(
                    depthMM: effDepth, cellMM: cell, tileFloorMM: tileFloor,
                    bakeFloorMM: LatticePreviewOccupancy.bakeFloorMM(realFloorMM: tileFloor, voxelMM: voxel), beadMM: bead,
                    printsOpen: { LatticePreviewOccupancy.printsOpen(cellMM: $0, lineWidthMM: bead, latticeID: topology) })
                if moved != cell {
                    NSLog("DIAG regionCell r\(ri) Default Grade: %.4f mm's halves end at prints-open → %.4f mm (%.0f → %.0f across %.3f mm)",
                          cell, moved, (effDepth / cell).rounded(), (effDepth / moved).rounded(), effDepth)
                }
                cell = moved
            }
            return RegionCell(measuredWidthMM: w, cellMM: cell, cellBeforeBaseRuleMM: beforeBaseRule)
        }
    }

    /// ★★ DEFAULT GRADE'S BASE RULE (the reviewer's ruling (b), 2026-10-11): the candidates are the wall's
    /// whole-number fits `depthMM / n` for n = n₀ + 1, n₀ + 2, … while the fit stays at or above the tile
    /// floor (n₀ = `cellMM`'s own count), each of which must itself print open. A base REACHES when its
    /// halving ladder ends because the next half is under the bake's floor (or no wider than the bead),
    /// and NOT because that half is at or above the floor but fails `printsOpen` (core's
    /// `lattice_prints_open`; open from 2.370917 mm at a 0.45 mm bead). `cellMM` stands when it reaches;
    /// otherwise the first candidate that reaches wins — the smallest n, so the coarsest; none ⇒ `cellMM`.
    /// At a 2.25 mm floor and a 0.45 mm bead a ladder fails to reach exactly when its finest rung is in
    /// [4.50, 4.74) mm. Over every wall, the finest rung's largest jump on a small change of the wall is
    /// 1.5× at n₀ = 2 and 3, 1.6× at 4, 1.67× at 5 (today's is 2× at every n₀); a one-cell wall of
    /// 4.50–4.74 mm keeps today's 2× (its only smaller fit does not print open). It does not make the
    /// finest rung uniform — ruling (a), its own round.
    nonisolated public static func cellWhoseHalvesEndAtTheFloor(depthMM: Double, cellMM: Double, tileFloorMM: Double,
                                                                bakeFloorMM: Double, beadMM: Double,
                                                                printsOpen: (Double) -> Bool) -> Double {
        guard depthMM > 0, cellMM > 0 else { return cellMM }
        func reaches(_ base: Double) -> Bool {
            var rung = base
            for _ in 0..<8 {   // core's kSteppedMaxHalvings
                let half = rung / 2
                if half < bakeFloorMM - 1e-9 || half <= beadMM { return true }   // ends at the floor
                if !printsOpen(half) { return false }                            // ends at prints-open
                rung = half
            }
            return true
        }
        if reaches(cellMM) { return cellMM }
        let n0 = Swift.max(1, (depthMM / cellMM).rounded())
        var n = n0 + 1
        while n <= n0 + 64, depthMM / n >= tileFloorMM - 1e-9 {
            let base = depthMM / n
            if printsOpen(base), reaches(base) { return base }   // never a quilt base for a quilt rung
            n += 1
        }
        return cellMM
    }

    /// The whole-number fit of a region's cell across its wall: the nearest whole number of the cell core
    /// derived, plus `extraCells` (the quilt step) — then FEWER while a cell would be under the job's tile
    /// floor (`tileFloorMM`, core's E1 at the job's cap; 0 = none stated).
    /// ★★ NEVER UNDER THE FLOOR (proof arm 3, 2026-10-10: on 102117B9 the nearest n put 20,986 of 22,210
    /// plan cells at 2.06 / 2.00 / 1.72 mm under the 2.25 mm floor — 4.12 mm / 2 = 2.06 — where core's
    /// derivation had asked for ≥ 2.25). A wall thinner than one printable cell gets none (0): no cell,
    /// never a quilt cell core refuses (D5).
    nonisolated public static func wholeCellsAcross(depthMM: Double, derivedCellMM: Double, tileFloorMM: Double,
                                                    extraCells: Int = 0) -> Double {
        guard depthMM > 0, derivedCellMM > 0 else { return 0 }
        var n = Swift.max(1, (depthMM / derivedCellMM).rounded()) + Double(extraCells)
        guard tileFloorMM > 0 else { return depthMM / n }
        while n > 1, depthMM / n < tileFloorMM - 1e-9 { n -= 1 }
        return depthMM / n >= tileFloorMM - 1e-9 ? depthMM / n : 0
    }

    /// ★★ THE DRAWER'S CELL IS THE BAKE'S (maintainer, 2026-10-03, item 5: "the drawer's 'Cell
    /// 2.40 mm' and the bake use the same member width (the measured one)"). Per selectable key
    /// (`LatticeRegionSpec.selectableKey`, the drawer's own key), the wall the bake measured and
    /// the cell it lays, for the algorithms whose preview is the per-region bake (Stepped and
    /// Default Grade: p50, the quilt step, a stated cell winning — `steppedCellsMM`'s exact
    /// inputs). A key spanning several regions (a curved face's facets) reports the governing
    /// one — the finest cell — and the span. Empty with no bake yet, or under any other
    /// algorithm, so those drawers stay on the declared depth and core's own derivation.
    public struct SelectableCell: Equatable, Sendable {
        public let measuredWidthMM: Double
        public let cellMM: Double
        public let cellRangeMM: ClosedRange<Double>
    }
    public static func selectableCells(project: ProjectModel, scene: LatticeSDFScene?) -> [String: SelectableCell] {
        guard scene != nil, ["stepped", "doubled"].contains(project.lattice.algorithm) else { return [:] }
        let regions = project.latticeJobRegions().regions
        let derived = regionCells(project: project, scene: scene, regions: regions,
                                  widthPercentile: 0.5, quiltStep: true)
        // the stated cell wins, exactly as `steppedCellsMM` (the bake's cells) does it
        let stated = statedCellByFace(project.lattice)
        // ★ where Default Grade's base rule (b) moved a region, the bake's "do no harm" guard may have kept n₀ — the
        // drawer says the bake's own base (its last plan), so drawer and bake still say one number
        var bakedBase: [Int: Double] = [:]
        for c in project.latticePreviewSteppedCells { if let b = c.planBaseCellMM, bakedBase[c.regionID] == nil { bakedBase[c.regionID] = b } }
        let cells = regions.indices.map { i -> Double in
            guard i < derived.count else { return 0 }
            if let f = regions[i].faceID, let mm = stated[f], mm > 0 { return mm }
            let d = derived[i]
            if abs(d.cellMM - d.cellBeforeBaseRuleMM) > 1e-9, regions[i].role == .include {
                let includeID = regions[..<i].filter { $0.role == .include }.count + 1
                if let b = bakedBase[includeID], abs(b - d.cellBeforeBaseRuleMM) < 1e-9 { return b }
            }
            return d.cellMM
        }
        var out: [String: SelectableCell] = [:]
        for (i, r) in regions.enumerated() where r.role == .include && i < derived.count && i < cells.count {
            guard let key = r.selectableKey, cells[i] > 0 else { continue }
            let mine = SelectableCell(measuredWidthMM: derived[i].measuredWidthMM, cellMM: cells[i],
                                      cellRangeMM: cells[i]...cells[i])
            guard let had = out[key] else { out[key] = mine; continue }
            let span = Swift.min(had.cellRangeMM.lowerBound, cells[i])...Swift.max(had.cellRangeMM.upperBound, cells[i])
            let gov = cells[i] < had.cellMM ? mine : had
            out[key] = SelectableCell(measuredWidthMM: gov.measuredWidthMM, cellMM: gov.cellMM, cellRangeMM: span)
        }
        return out
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
                          smallerCellPrintsOpen: LatticePreviewOccupancy.printsOpen(
                            cellMM: cellMM, lineWidthMM: bead, latticeID: project.lattice.topologyID))   // ★ core's one rule
    }

    /// ★ THE RULE ITSELF, pure: a wall whose p90 drawn density is in the top fifth of
    /// [floor, ceiling] steps, provided the smaller cell's bead-wide strut still prints open
    /// (core's `lattice_prints_open`, `LatticePreviewOccupancy.printsOpen`). His face 2: p90 0.219 at a
    /// 0.219 ceiling → steps; face 15: 0.080 → stays.
    public nonisolated static func quiltTrips(p90: Double, lo: Double, ceiling: Double, smallerCellPrintsOpen: Bool) -> Bool {
        guard ceiling > lo else { return false }
        let trip = lo + quiltTripFraction * (ceiling - lo)
        return p90 >= trip && smallerCellPrintsOpen
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
        steppedCellChoices(project: project, scene: scene).cells
    }

    /// The bake's cells and, per region, the cell BEFORE Default Grade's base rule (b) — what the bake's "do no harm"
    /// guard falls back to (`LatticePreviewOccupancy.octreeCellField(cellMMBeforeBaseRule:)`). A stated cell wins in both.
    public static func steppedCellChoices(project: ProjectModel, scene: LatticeSDFScene?)
        -> (cells: [Double], beforeBaseRule: [Double]) {
        guard project.printParams.strutLineWidthMM > 0 else { return ([], []) }
        let regions = project.latticeJobRegions().regions
        let derived = regionCells(project: project, scene: scene, regions: regions, widthPercentile: 0.5, quiltStep: true)
        var cells = derived.map(\.cellMM), before = derived.map(\.cellBeforeBaseRuleMM)
        let stated = statedCellByFace(project.lattice)
        for (i, r) in regions.enumerated() where i < cells.count {
            if let f = r.faceID, let mm = stated[f], mm > 0 { cells[i] = mm; before[i] = mm }
        }
        return (cells, before)
    }
}
