// FaceRegion.swift — THE SECOND LAYER OF IDENTITY, app side
// (task 2026-08-14-face-regions §1).
//
// ★ HIS OBSERVATION: "faces tend to be random and not really representative of
// the structure itself — regardless of what file we import." His own
// `loadcase.json` proves it: ONE load group carrying 23 face ids, and face
// protections ranging from 16 voxels (faces 41-47, seven of them) to 10,554
// (face 16). A 660x range on one bracket. STEP faces record how the CAD was
// modelled, not what a user thinks of as a wall.
//
// ── THE TWO LAYERS ─────────────────────────────────────────────────────────
//
//   LAYER 1  voxel -> ORIGINAL CAD FACE ID. Used for PROJECTION, the CAD/cut
//            classifier, and every analytic-surface lookup. ★ NEVER CHANGES.
//            Nothing in this file writes it, and the emission never renumbers
//            it.
//   LAYER 2  voxel -> REGION. Roles, depth, split, union. THIS is what the UI
//            manipulates.
//
// ★ WHY LAYER 1 IS NON-NEGOTIABLE: a UNION HAS NO ANALYTIC SURFACE. Two planes
// do not merge into one plane. PR 307's projection and PR 326's CAD-derived
// frozen region (0.3232 mm against SIMP's 0.4293 — the best dimensional result
// this project has) both stand on the face partition being exactly what the
// B-rep said. So a region is a DERIVED selection and never a re-partition:
//
//     region  =  (member FACE IDS)  ∩  (an intersection of HALF-SPACES)
//
// ── DAY ONE IS BYTE-IDENTICAL (bar R1) ─────────────────────────────────────
//
// Conceptually there is one region per CAD face on import. Materially, this
// model stores NOTHING until the user unions, filters or splits: an IDENTITY
// region — one member face, no cuts — resolves to exactly what its face
// resolves to (core asserts this voxel-for-voxel in test_face_region.cpp), so
// it is emitted as the bare face id it has always been emitted as. A project
// with no region edits produces the job it produced yesterday, to the byte.
//
// ── PERSISTENCE (§3c, §4e) ─────────────────────────────────────────────────
//
// ★ A UNION IS NOT STORED AS A LIST OF FACE IDS. A re-import after a CAD edit
// renumbers B-rep faces and a stored id list would silently point at whatever
// inherited the number. What is stored is the defining FILTER plus an explicit
// add/remove list, re-evaluated on every import, with `filterMatchedAtAuthor`
// recorded so a change is REPORTED (`FaceRegionModel.drift`) rather than
// absorbed. A split is stored as GEOMETRY — a point and a normal in model space
// — never as "region 24, half A".

import Foundation
import simd
import TopOptKit

/// A region id. Distinct from `FaceID` on purpose: the two are different things
/// and the type system should say so.
public typealias RegionID = Int

/// ONE HALF-SPACE. A voxel centre `p` is inside iff `dot(p - point, normal)` is
/// `>= 0` (`strict == false`) or `> 0` (`strict == true`).
///
/// Both senses exist so a grid split PARTITIONS: each cell takes its lower
/// boundary non-strictly and its upper boundary strictly, so a voxel centre
/// exactly on a cut plane lands in one cell — never two, never none.
public struct RegionCut: Equatable, Sendable, Codable {
    public var point: SIMD3<Double>
    public var normal: SIMD3<Double>
    public var strict: Bool

    public init(point: SIMD3<Double>, normal: SIMD3<Double>, strict: Bool = false) {
        self.point = point
        self.normal = normal
        self.strict = strict
    }
}

/// The selection filter (§2).
///
/// ★ "ALL FILLETS AND CHAMFERS" IS NOT A `kind` FILTER. A CHAMFER is a flat
/// bevel (a plane). A FILLET is rounded (a cylinder, or a torus that lands in
/// "other"). Filtering on "other" would MISS most chamfers and CATCH unrelated
/// splines and cones. What identifies a blend is that it is SMALL and ADJACENT
/// TO TWO LARGER FACES — the shape of his seven 16-voxel faces.
///
/// Every set predicate is ANDed. An all-unset filter matches NOTHING.
///
/// SIZE IS IN mm², NOT VOXELS: a voxel count depends on the run resolution, so a
/// voxel-expressed filter would match a different set at 64 than at 128 and a
/// persisted union would drift for a reason unrelated to the CAD. The UI shows
/// the equivalent voxel count at the current resolution (`voxelsPerMM2`).
public struct RegionFilter: Equatable, Sendable, Codable {
    public var maxAreaMM2: Double = 0
    public var minAreaMM2: Double = 0
    public var minLargerNeighbours: Int = 0
    public var largerRatio: Double = 2
    /// "" (unset) | "plane" | "cylinder" | "other"
    public var kind: String = ""
    public var cylinderRadiusMM: Double = 0
    public var cylinderRadiusTolMM: Double = 0.05

    public init() {}

    public var any: Bool {
        maxAreaMM2 > 0 || minAreaMM2 > 0 || minLargerNeighbours > 0
            || !kind.isEmpty || cylinderRadiusMM > 0
    }

    /// The BLEND preset — the one §2(a) asks for, as a filter the user can then
    /// adjust, never a magic button. `maxAreaMM2` is seeded from the part so the
    /// preset means "small FOR THIS PART" rather than a fixed millimetre guess.
    public static func blend(maxAreaMM2: Double) -> RegionFilter {
        var f = RegionFilter()
        f.maxAreaMM2 = maxAreaMM2
        f.minLargerNeighbours = 2
        f.largerRatio = 2
        return f
    }

    /// The ANALYTIC SIGNATURE preset — "all six bolt bores in one tap".
    public static func bores(radiusMM: Double, tolMM: Double = 0.05) -> RegionFilter {
        var f = RegionFilter()
        f.cylinderRadiusMM = radiusMM
        f.cylinderRadiusTolMM = tolMM
        return f
    }
}

/// One materialized region. `id` is stable within a project and is what the job
/// refers to; `parentID` is provenance only (a split is resolved from its cuts,
/// never from its parent).
public struct FaceRegion: Identifiable, Equatable, Sendable, Codable {
    public let id: RegionID
    public var name: String
    public var filter: RegionFilter
    /// What `filter` matched when this region was authored; -1 = not recorded.
    public var filterMatchedAtAuthor: Int
    public var add: [FaceID]
    public var remove: [FaceID]
    public var cuts: [RegionCut]
    public var parentID: RegionID
    /// UI only: a grid split's parent starts COLLAPSED, because fifty rows from
    /// one tap is worse than the problem he started with (§5b).
    public var collapsed: Bool

    public init(id: RegionID, name: String, filter: RegionFilter = RegionFilter(),
                filterMatchedAtAuthor: Int = -1, add: [FaceID] = [],
                remove: [FaceID] = [], cuts: [RegionCut] = [],
                parentID: RegionID = -1, collapsed: Bool = true) {
        self.id = id
        self.name = name
        self.filter = filter
        self.filterMatchedAtAuthor = filterMatchedAtAuthor
        self.add = add
        self.remove = remove
        self.cuts = cuts
        self.parentID = parentID
        self.collapsed = collapsed
    }

    /// True when this region is exactly ONE face with no filter and no cut — an
    /// IDENTITY region, which is its face and is emitted as its face.
    public var isIdentity: Bool {
        !filter.any && cuts.isEmpty && remove.isEmpty && add.count == 1
    }

    /// True when this region was manufactured by a split (it is bounded by
    /// half-spaces). Only these are priced against the sliver floor.
    public var isCut: Bool { !cuts.isEmpty }
}

/// The verdict of the sliver guard, mirroring core's `SliverVerdict` so the
/// sheet refuses with the same number the run would.
public struct SliverVerdict: Equatable, Sendable {
    public let ok: Bool
    public let minCellVoxels: Int
    public let emptyCells: Int
    public let memberVoxels: Int
    public let maxCellsBudget: Int
    public let floorVoxels: Int
    /// Empty iff `ok`. Kept SHORT — bar R7.
    public let reason: String
}

/// ★ THE SLIVER FLOOR, AND WHY THIS NUMBER (§5a).
///
/// A 10x5 split is fifty sub-regions from one operation. On his face 16 (10,554
/// voxels) that is ~211 each and fine; on a 500-voxel face it is ten each and
/// useless. The floor is not a taste: it is the size of the SMALLEST FACE HIS
/// OWN CAD HANDED HIM — faces 41-47 of M2_verticalStand.step tag sixteen voxels
/// each at resolution 128, and he selects them today. The guard refuses to
/// MANUFACTURE anything smaller than the smallest thing the CAD produced.
public let kRegionSliverFloorVoxels = 16

/// The region layer over one imported part.
public struct FaceRegionModel: Equatable, Sendable, Codable {
    public private(set) var regions: [FaceRegion] = []
    private var nextID: RegionID = 100

    public init() {}

    public var isEmpty: Bool { regions.isEmpty }

    public func region(_ id: RegionID) -> FaceRegion? {
        regions.first { $0.id == id }
    }

    public func children(of id: RegionID) -> [FaceRegion] {
        regions.filter { $0.parentID == id }
    }

    /// Root rows — everything whose parent is not itself a live region. A grid
    /// split's children hang off their parent and are hidden until it is
    /// expanded, so one operation adds ONE row, not fifty (§5b).
    public var roots: [FaceRegion] {
        let live = Set(regions.map(\.id))
        return regions.filter { $0.parentID < 0 || !live.contains($0.parentID) }
    }

    // MARK: - union (§3)

    /// ★ UNION N faces into ONE region: one id, the union of their voxel sets,
    /// one role, one depth, one row. No analytic surface is synthesised and the
    /// face partition is untouched — the members keep their own ids and their
    /// own surfaces.
    ///
    /// `filter` and `filterMatchedAtAuthor` make the union RE-EVALUABLE after a
    /// CAD edit; pass an unset filter for a hand-picked union, whose members are
    /// then the explicit `add` list and nothing else.
    @discardableResult
    public mutating func union(faces: [FaceID], named name: String,
                               filter: RegionFilter = RegionFilter(),
                               matchedAtAuthor: Int = -1) -> RegionID {
        let id = nextID
        nextID += 1
        regions.append(FaceRegion(id: id, name: name, filter: filter,
                                  filterMatchedAtAuthor: matchedAtAuthor,
                                  add: faces.sorted(), collapsed: false))
        return id
    }

    /// ★ A UNION MUST BE DISSOLVABLE back to its members (§3d). Returns the face
    /// ids that come back, so the caller can hand them to the selection.
    /// Dissolving a region also dissolves everything split out of it — those
    /// children are cells of a shape that no longer exists.
    @discardableResult
    public mutating func dissolve(_ id: RegionID, resolvedMembers: [FaceID] = [])
        -> [FaceID] {
        guard let r = region(id) else { return [] }
        let members = resolvedMembers.isEmpty ? r.add : resolvedMembers
        var drop: Set<RegionID> = [id]
        var changed = true
        while changed {
            changed = false
            for c in regions where drop.contains(c.parentID) && !drop.contains(c.id) {
                drop.insert(c.id)
                changed = true
            }
        }
        regions.removeAll { drop.contains($0.id) }
        return members
    }

    // MARK: - splits (§4)

    /// A MANUAL split: one plane, two children. Stored as geometry.
    @discardableResult
    public mutating func splitManual(_ id: RegionID, point: SIMD3<Double>,
                                     normal: SIMD3<Double>) -> [RegionID] {
        guard let parent = region(id), simd_length(normal) > 1e-12 else { return [] }
        let n = simd_normalize(normal)
        var out: [RegionID] = []
        for (k, cut) in [RegionCut(point: point, normal: n),
                         RegionCut(point: point, normal: -n, strict: true)].enumerated() {
            let cid = nextID
            nextID += 1
            regions.append(FaceRegion(id: cid, name: "\(parent.name) \(k == 0 ? "A" : "B")",
                                      filter: parent.filter,
                                      filterMatchedAtAuthor: parent.filterMatchedAtAuthor,
                                      add: parent.add, remove: parent.remove,
                                      cuts: parent.cuts + [cut], parentID: id,
                                      collapsed: true))
            out.append(cid)
        }
        setCollapsed(id, false)
        return out
    }

    /// A GRID split: `cells` come from `FaceRegionGeometry.gridSplitCells`, so
    /// the app and the core place the same planes. The parent stays as the
    /// COLLAPSIBLE row; the cells are its children.
    @discardableResult
    public mutating func splitGrid(_ id: RegionID,
                                   cells: [FaceRegionGeometry.GridCell]) -> [RegionID] {
        guard let parent = region(id), !cells.isEmpty else { return [] }
        var out: [RegionID] = []
        for c in cells {
            let cid = nextID
            nextID += 1
            regions.append(FaceRegion(id: cid, name: "\(parent.name) \(c.i + 1)·\(c.j + 1)",
                                      filter: parent.filter,
                                      filterMatchedAtAuthor: parent.filterMatchedAtAuthor,
                                      add: parent.add, remove: parent.remove,
                                      cuts: parent.cuts + c.cuts, parentID: id,
                                      collapsed: true))
            out.append(cid)
        }
        setCollapsed(id, true)  // collapsed by default: one row, not fifty
        return out
    }

    /// Undo the LAST split of a region: drop its immediate children (and theirs).
    /// Splits are a revertable stack (§4d).
    public mutating func revertSplit(_ id: RegionID) {
        let kids = children(of: id).map(\.id)
        for k in kids { _ = dissolve(k) }
    }

    // MARK: - edits

    public mutating func rename(_ id: RegionID, to name: String) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].name = name
    }

    public mutating func setCollapsed(_ id: RegionID, _ collapsed: Bool) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].collapsed = collapsed
    }

    /// ★ A HEURISTIC THAT CANNOT BE CORRECTED BY HAND IS WORSE THAN NO HEURISTIC
    /// (§2c). Tap-add and tap-remove on a filter-defined region write the
    /// explicit lists the persistence re-applies after every import.
    public mutating func addFace(_ face: FaceID, to id: RegionID) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].remove.removeAll { $0 == face }
        if !regions[i].add.contains(face) {
            regions[i].add.append(face)
            regions[i].add.sort()
        }
    }

    public mutating func removeFace(_ face: FaceID, from id: RegionID) {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].add.removeAll { $0 == face }
        if !regions[i].remove.contains(face) {
            regions[i].remove.append(face)
            regions[i].remove.sort()
        }
    }

    /// Record what each region's filter matches NOW, so the next import can
    /// report drift against it. Called once when the user commits a selection.
    public mutating func recordAuthorMatches(_ matched: [RegionID: Int]) {
        for (id, n) in matched {
            guard let i = regions.firstIndex(where: { $0.id == id }) else { continue }
            regions[i].filterMatchedAtAuthor = n
        }
    }

    // MARK: - drift (§3c)

    /// One region whose filter matches a different number of faces than it did
    /// when it was authored — a CAD edit the user has to see.
    public struct Drift: Equatable, Sendable {
        public let id: RegionID
        public let name: String
        public let then: Int
        public let now: Int
    }

    /// Compare each region's recorded author-time match count against what its
    /// filter matches on THIS import. ★ Reported, never absorbed.
    public func drift(matchedNow: [RegionID: Int]) -> [Drift] {
        regions.compactMap { r in
            guard r.filter.any, r.filterMatchedAtAuthor >= 0,
                  let now = matchedNow[r.id], now != r.filterMatchedAtAuthor
            else { return nil }
            return Drift(id: r.id, name: r.name, then: r.filterMatchedAtAuthor, now: now)
        }
    }

    // MARK: - the sliver guard (§5a, bar R5)

    /// ★ REFUSE BEFORE DOING ANYTHING. Prices the ACTUAL per-cell voxel counts —
    /// a budget alone is an upper bound and an uneven region fails below it.
    public static func checkSliver(cellVoxels: [Int], memberVoxels: Int,
                                   floor: Int = kRegionSliverFloorVoxels) -> SliverVerdict {
        guard !cellVoxels.isEmpty else {
            return SliverVerdict(ok: false, minCellVoxels: 0, emptyCells: 0,
                                 memberVoxels: memberVoxels, maxCellsBudget: 0,
                                 floorVoxels: floor, reason: "No cells.")
        }
        let worst = cellVoxels.min() ?? 0
        let empty = cellVoxels.filter { $0 == 0 }.count
        let budget = floor > 0 ? memberVoxels / floor : 0
        if worst >= floor {
            return SliverVerdict(ok: true, minCellVoxels: worst, emptyCells: empty,
                                 memberVoxels: memberVoxels, maxCellsBudget: budget,
                                 floorVoxels: floor, reason: "")
        }
        return SliverVerdict(
            ok: false, minCellVoxels: worst, emptyCells: empty,
            memberVoxels: memberVoxels, maxCellsBudget: budget, floorVoxels: floor,
            reason: "Smallest piece: \(worst) voxels, floor \(floor). "
                + "\(memberVoxels) voxels fits \(budget) pieces.")
    }

    // MARK: - Codable (forward-compatible)

    private enum CodingKeys: String, CodingKey { case regions, nextID }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        regions = try c.decodeIfPresent([FaceRegion].self, forKey: .regions) ?? []
        nextID = try c.decodeIfPresent(RegionID.self, forKey: .nextID)
            ?? ((regions.map(\.id).max() ?? 99) + 1)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(regions, forKey: .regions)
        try c.encode(nextID, forKey: .nextID)
    }
}

// ---------------------------------------------------------------------------
// THE ONE CONVERSION to the bridge transport (task 2026-08-14-face-regions).
//
// TopOptKit sits BELOW this file, so it cannot see `FaceRegion`. This adapter is
// the ONLY place the two representations meet — the alternative, a second model
// filled by hand at each call site, is the shape that dropped the outer wall
// line width for 71 minutes and a whole release.
// ---------------------------------------------------------------------------

extension TopOptKit.FaceRegionSpec {
    public init(region r: FaceRegion) {
        self.init(
            id: r.id,
            parentID: r.parentID,
            addFaces: r.add.map(Int.init),
            removeFaces: r.remove.map(Int.init),
            cuts: r.cuts.map { (point: $0.point, normal: $0.normal, strict: $0.strict) },
            maxAreaMM2: r.filter.maxAreaMM2,
            minAreaMM2: r.filter.minAreaMM2,
            minLargerNeighbours: r.filter.minLargerNeighbours,
            largerRatio: r.filter.largerRatio,
            kindCode: r.filter.kind == "plane" ? 0
                : r.filter.kind == "cylinder" ? 1
                : r.filter.kind == "other" ? 2 : -1,
            cylinderRadiusMM: r.filter.cylinderRadiusMM,
            cylinderRadiusTolMM: r.filter.cylinderRadiusTolMM,
            filterMatchedAtAuthor: r.filterMatchedAtAuthor)
    }
}
