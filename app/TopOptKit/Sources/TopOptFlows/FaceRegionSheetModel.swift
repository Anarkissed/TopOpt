// FaceRegionSheetModel.swift — every decision the Regions sheet makes, as a pure
// value type (task 2026-08-14-face-regions §2, §4, §5).
//
// The view renders this; it computes nothing of its own. That is the /app/
// verification standard here: the match count, the per-cell voxel counts, the
// sliver refusal and the button enablement are all unit-tested headlessly, and
// the SwiftUI file is left with layout.

import Foundation
import simd

public struct FaceRegionSheetModel: Equatable, Sendable {

    /// Which selection tool the sheet is offering. ★ Never a magic button: each
    /// is a FILTER the user can then adjust and correct by tap (§2c).
    public enum Preset: String, CaseIterable, Sendable {
        /// Small AND touching two larger faces — the honest blend signal.
        case blends
        /// Every cylinder of one radius: "all six bolt bores in one tap".
        case bores
        /// Everything under an area threshold, adjacency ignored.
        case small

        public var title: String {
            switch self {
            case .blends: return "Fillets & chamfers"
            case .bores: return "Bores of one size"
            case .small: return "Small faces"
            }
        }
    }

    /// One row of the region list. A grid split's parent shows the child count
    /// and the aggregate voxels; its children stay hidden until it is expanded,
    /// so one operation adds ONE row, not fifty (§5b).
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: RegionID
        public let name: String
        public let depth: Int          // 0 = root, 1 = a split cell
        public let memberFaces: Int
        public let voxels: Int
        public let childCount: Int
        public let collapsed: Bool
        /// True when this row is below the sliver floor — dimmed, not hidden.
        public let underFloor: Bool
    }

    /// The result of asking for an N x M grid split, priced BEFORE it happens.
    public struct GridPreview: Equatable, Sendable {
        public let cells: Int
        public let cellVoxels: [Int]
        public let verdict: SliverVerdict
        /// ★ TRUE when the frame is PCA rather than the members' shared axis. The
        /// UI must say so: "equal" is then equal in the PCA parameter, which is
        /// not equal in any intrinsic sense on a curved surface (§4b).
        public let pcaFallback: Bool
    }

    // MARK: - inputs

    public var preset: Preset = .blends
    /// The blend/small size threshold, as a FRACTION of the part's median face
    /// area. Expressed relatively so the control means "small for THIS part"
    /// rather than a millimetre guess that is wrong on the next import.
    public var sizeFraction: Double = 0.25
    public var boreRadiusMM: Double = 0
    public var gridN: Int = 1
    public var gridM: Int = 1

    // MARK: - derived, from the mesh

    /// The part's median face area (mm²) — the scale the size threshold is a
    /// fraction of. Median rather than mean: one 10,554-voxel wall beside seven
    /// 16-voxel blends drags a mean far off what "typical" means here.
    public private(set) var medianAreaMM2: Double = 0
    /// The run's voxel edge at the current resolution, for the voxel counts.
    public private(set) var spacingMM: Double = 0
    public private(set) var matched: [FaceID] = []
    public private(set) var rows: [Row] = []
    public private(set) var drift: [FaceRegionModel.Drift] = []

    public init() {}

    /// The area threshold the current preset implies (mm²).
    public var thresholdMM2: Double { medianAreaMM2 * sizeFraction }

    /// The filter the current preset + inputs describe.
    public var filter: RegionFilter {
        switch preset {
        case .blends: return .blend(maxAreaMM2: thresholdMM2)
        case .bores: return .bores(radiusMM: boreRadiusMM)
        case .small:
            var f = RegionFilter()
            f.maxAreaMM2 = thresholdMM2
            return f
        }
    }

    /// ★ SHOW THE MATCH COUNT BEFORE COMMITTING (§2c).
    public var matchLabel: String {
        matched.isEmpty ? "No matches" : "\(matched.count) faces"
    }

    // MARK: - recompute

    /// Refresh everything the sheet shows against a mesh and a resolution.
    /// `resolution` is the run's voxel count along the longest axis, so the
    /// voxel numbers on screen are the numbers the run will price.
    public mutating func refresh(mesh: ViewerMesh?, resolution: Int,
                                 model: FaceRegionModel,
                                 selectedRegion: RegionID?) {
        guard let mesh else {
            matched = []
            rows = []
            drift = []
            return
        }
        let areas = FaceRegionGeometry.faceAreas(in: mesh)
        let sorted = areas.values.sorted()
        medianAreaMM2 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let extent = mesh.bounds.max - mesh.bounds.min
        let span = Double(Swift.max(extent.x, Swift.max(extent.y, extent.z)))
        spacingMM = resolution > 0 ? span / Double(resolution) : 0
        if boreRadiusMM <= 0 {
            // Seed the bore radius from the part's most common cylinder, so the
            // preset lands on a real hole rather than 0 mm.
            var radii: [Double] = []
            for f in areas.keys {
                if let g = mesh.faceGeometry(f), g.kind == .cylinder, g.cylinderRadiusMM > 0 {
                    radii.append(g.cylinderRadiusMM)
                }
            }
            boreRadiusMM = radii.sorted().first ?? 0
        }
        matched = FaceRegionGeometry.match(filter, in: mesh)

        var now: [RegionID: Int] = [:]
        for r in model.regions where r.filter.any {
            now[r.id] = FaceRegionGeometry.match(r.filter, in: mesh).count
        }
        drift = model.drift(matchedNow: now)
        rows = Self.buildRows(model: model, mesh: mesh, spacingMM: spacingMM)
        _ = selectedRegion
    }

    static func buildRows(model: FaceRegionModel, mesh: ViewerMesh,
                          spacingMM: Double) -> [Row] {
        var out: [Row] = []
        func row(_ r: FaceRegion, depth: Int) -> Row {
            let members = FaceRegionGeometry.members(of: r, in: mesh)
            let kids = model.children(of: r.id)
            // A parent's voxel figure is its members' — its children partition
            // exactly that, so the aggregate is the parent, not a sum that could
            // double-count a boundary voxel.
            var voxels = FaceRegionGeometry.memberVoxelEstimate(
                members: members, in: mesh, spacingMM: spacingMM)
            if r.isCut {
                // A split cell's own share of its members, priced through the
                // same sampler the grid preview uses.
                let cell = FaceRegionGeometry.GridCell(i: 0, j: 0, cuts: r.cuts)
                voxels = FaceRegionGeometry.cellVoxelCounts(
                    members: members, in: mesh, cells: [cell],
                    spacingMM: spacingMM).first ?? 0
            }
            return Row(id: r.id, name: r.name, depth: depth,
                       memberFaces: members.count, voxels: voxels,
                       childCount: kids.count, collapsed: r.collapsed,
                       // ★ §5(c) — a row below the floor is DIMMED, not hidden.
                       // Seven 16-voxel rows are noise he has to read past on
                       // every part; hiding them outright would lose a selection
                       // he does in fact use.
                       underFloor: voxels < kRegionSliverFloorVoxels)
        }
        func walk(_ r: FaceRegion, depth: Int) {
            out.append(row(r, depth: depth))
            guard !r.collapsed else { return }
            for c in model.children(of: r.id) { walk(c, depth: depth + 1) }
        }
        for r in model.roots { walk(r, depth: 0) }
        return out
    }

    // MARK: - §4(b) the grid, priced before it happens

    /// Price an N x M split of `region` WITHOUT performing it. ★ R5: a split that
    /// would produce sub-regions below the floor refuses, with the number, before
    /// anything is done.
    public func gridPreview(of region: FaceRegion, in mesh: ViewerMesh) -> GridPreview? {
        let members = FaceRegionGeometry.members(of: region, in: mesh)
        let frame = FaceRegionGeometry.frame(members: members, in: mesh)
        guard frame.valid else { return nil }
        let cells = FaceRegionGeometry.gridSplitCells(frame, n: gridN, m: gridM)
        let counts = FaceRegionGeometry.cellVoxelCounts(members: members, in: mesh,
                                                        cells: cells, spacingMM: spacingMM)
        let total = FaceRegionGeometry.memberVoxelEstimate(members: members, in: mesh,
                                                           spacingMM: spacingMM)
        return GridPreview(cells: cells.count, cellVoxels: counts,
                           verdict: FaceRegionModel.checkSliver(cellVoxels: counts,
                                                                memberVoxels: total),
                           pcaFallback: !frame.cylindrical)
    }

    /// The cells to hand `FaceRegionModel.splitGrid` once the preview clears.
    public func gridCells(of region: FaceRegion, in mesh: ViewerMesh)
        -> [FaceRegionGeometry.GridCell] {
        let members = FaceRegionGeometry.members(of: region, in: mesh)
        let frame = FaceRegionGeometry.frame(members: members, in: mesh)
        guard frame.valid else { return [] }
        return FaceRegionGeometry.gridSplitCells(frame, n: gridN, m: gridM)
    }

    // MARK: - §4(a) the manual split's rotate button

    /// The snap normal for `step` presses of the ROTATE button on `region`.
    /// Index 0 — the default — cuts ACROSS the region's long axis.
    public func manualSplitNormal(of region: FaceRegion, in mesh: ViewerMesh,
                                  step: Int) -> SIMD3<Double>? {
        let members = FaceRegionGeometry.members(of: region, in: mesh)
        let snaps = FaceRegionGeometry.snapNormals(
            FaceRegionGeometry.frame(members: members, in: mesh))
        guard !snaps.isEmpty else { return nil }
        return snaps[((step % snaps.count) + snaps.count) % snaps.count]
    }
}
