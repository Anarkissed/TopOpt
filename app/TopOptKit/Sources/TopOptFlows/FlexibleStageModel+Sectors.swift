// FlexibleStageModel+Sectors — the stage model's side of round 7 batch M2 (the reviewer's ruling 3 on the 2026-10-14
// outbox: "FLEXIBLE-ONLY sectors carried in the job, NOT Surface-stage sectors … If I2 already writes Surface sectors, move
// them to Flexible-only and say what moved"; his img3 words: "when I tapped the top, it selected the model's top face,
// rather than one of the lattice's top faces" and "the pressed curves continue right through the entire model rather than
// the lattice section").
//
// ★ ONE VALUE, MEMOISED. `regions` (every reader's FlexibleRegions) = his Surface regions (I2's cuts given back) + the
// Flexible sectors FlexibleSectors.resolve derives from the face-prisms and the strips, numbered by the session's
// FlexibleSectorNumbers (seeded from the store). Recomputed only when what it is made from changes.
// ★ EVERY EDIT REGISTERS its numbers in the store (`registerSectors`), so a number names the same role in every session.
// ★ THE CARRY (c4): at open, a face pressed WHOLE that is now only partly latticed — or a Flexible piece that is gone — has
// its setting carried onto the root's lattice pieces (re-expressed through core's frames: a stamp stays where he drew it
// on the part), inside the open's adopt edit, so the whole face is never left beside its sections (core: shared_footprint).

import Foundation
import simd
import TopOptKit

/// ★ ROUND 7 (M2): the toast's one fix.
public enum FlexibleToastFix: String, Equatable, Sendable {
    /// "Solid here · only face-prisms get latticed" → [Go to Lattice]: the page's Exit (never Save & Exit's bake).
    case goToLattice
}

/// What the Flexible sectors are made from (the memo's key).
struct FlexibleSectorMemoKey: Equatable {
    var faceRegions: FaceRegionModel
    var includes: [LatticeRegionSpec]
    var strips: [UUID: FlexibleStrip]
    var stripOrder: [UUID]
    /// ★ R7-E1: each press's flat prism (its direction and depth).
    var cuts: [UUID: FlexibleFlatPrism.Cut]
    var newPicks: Set<UUID>
    var meshKey: String
    var controls: [Bool]
}

/// What the include specs are emitted from (their memo's key).
struct FlexibleIncludeMemoKey: Equatable {
    var lattice: LatticeSettings
    var selection: SelectionModel
    var force: ForceModel
    var faceRegions: FaceRegionModel
    var mesh: String
}

/// The carry at open (c4): the faces list and the deleted list as they become, from the settings they were planned on.
struct FlexibleSectionCarry {
    var from: FlexibleStageSettings
    var faces: [FlexibleFaceSettings]
    var removed: [Int]?
    var toast: String?
}

extension FlexibleStageModel {

    // MARK: - the regions over his Surface regions and the Flexible sectors

    /// The Flexible-only sectors of the part as it is now.
    public var sectorSet: FlexibleSectorSet { sectorState().set }

    /// The regions the Flexible stage reads his Surface sectors from: the project's — with I2's cuts given back while a
    /// project saved by I2 has not been moved yet (FlexibleSectorMigration reads it through).
    public var restoredFaceRegions: FaceRegionModel {
        sectorMigration(rawSettings)?.restored ?? project.faceRegions
    }

    /// The settings as the project holds them (the round-3 read-through only).
    var rawSettings: FlexibleStageSettings {
        FlexibleSettingsMigration.migrated(project.lattice.flexible ?? FlexibleStageSettings())
    }

    /// Selections' include specs — the face-prisms (memoised on what the emission reads: one emission per change, not one
    /// per read — `regions` is read by every row and overlay).
    var includeSpecs: [LatticeRegionSpec] {
        let key = FlexibleIncludeMemoKey(lattice: project.lattice, selection: project.selection, force: project.force,
                                         faceRegions: project.faceRegions,
                                         mesh: project.viewerMesh.map { "\($0.signature.contentHash)|\($0.faceIDs.count)" } ?? "")
        if let m = includeMemo, m.key == key { return m.specs }
        let specs = project.latticeJobRegions().regions.filter { $0.role == .include }
        includeMemo = (key, specs)
        return specs
    }

    /// The resolved sectors and the regions over them, for `s` (the current settings by default), memoised.
    func sectorState(for s: FlexibleStageSettings? = nil, newPicks: Set<UUID> = []) -> (set: FlexibleSectorSet, regions: FlexibleRegions) {
        let s = s ?? settings
        let base = restoredFaceRegions
        guard let mesh = project.viewerMesh else {
            return (.empty, FlexibleRegions(model: base, mesh: nil))
        }
        if !sectorNumbersSeeded { sectorNumbersSeeded = true; sectorNumbers.seed(project.lattice.flexible?.sectors?.ids ?? [:]) }
        if let ids = s.sectors?.ids { sectorNumbers.seed(ids) }
        // I2's form read as it is (only under the red controls: the read-through moves it otherwise) — its strips are the
        // Surface stage's sectors, never Flexible ones
        let strips = FlexibleSectorMigration.isLegacy(s) ? [] : (s.presses ?? []).compactMap { p in p.strip.map { (p.id, $0) } }
        // ★ R7-E1: each press's flat prism — its plane cuts its pieces (nil: a strip still saved with M2's width)
        var cuts: [UUID: FlexibleFlatPrism.Cut] = [:]
        if !FlexibleSectorMigration.isLegacy(s) { for p in s.presses ?? [] { if let c = FlexibleFlatPrism.planCut(of: p) { cuts[p.id] = c } } }
        let key = FlexibleSectorMemoKey(
            faceRegions: base, includes: includeSpecs, strips: Dictionary(strips, uniquingKeysWith: { a, _ in a }),
            stripOrder: strips.map(\.0), cuts: cuts, newPicks: newPicks,
            meshKey: "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)|\(mesh.faceIDs.count)",
            controls: [FlexibleLatticeSections.controlWholeFace, FlexibleLatticeSections.controlAlwaysCut,
                       FlexibleLatticeSections.controlFingerprintIDs, FlexibleSectors.controlRecycle])
        if let m = sectorMemo, m.key == key { return (m.set, m.regions) }
        let set = FlexibleSectors.resolve(mesh: mesh, faceRegions: base, includes: key.includes,
                                          strips: strips.map { (id: $0.0, strip: $0.1) }, cuts: cuts, newPicks: newPicks, numbers: sectorNumbers)
        let regions = FlexibleRegions(model: base, mesh: mesh, flexible: set)
        if newPicks.isEmpty { sectorMemo = (key, set, regions) }
        return (set, regions)
    }

    // MARK: - the numbers in the store

    /// ★ Every Flexible id `s` refers to (faces, check stamps, presses, deleted faces) and every sector of its set, by key →
    /// number, into `s.sectors`. Nothing Flexible ⇒ the store stays as it was (nil on every project without one).
    func registerSectors(_ s: inout FlexibleStageSettings) {
        let set = sectorState(for: s).set
        var ids = s.sectors?.ids ?? [:]
        for p in set.pieces { ids[p.key] = p.number }
        var refs = s.faces.map(\.faceRegionID) + s.checkStamps.map(\.faceRegionID) + (s.removedRegions ?? [])
        refs += (s.presses ?? []).flatMap(\.regions)
        for r in refs where FlexibleSectors.isFlexible(r) {
            let n = r - FlexibleSectors.base
            if let k = sectorNumbers.key(of: n) { ids[k] = n }
        }
        guard !ids.isEmpty || s.sectors != nil else { return }
        let store = FlexibleSectorStore(version: FlexibleSectorStore.currentVersion, ids: ids)
        if s.sectors != store { s.sectors = store }
    }

    // MARK: - the move of I2's strips (FlexibleSectorMigration)

    /// The read-through of I2's form (memoised), or nil when `raw` is not I2's.
    func sectorMigration(_ raw: FlexibleStageSettings) -> FlexibleSectorMigration.Moved? {
        guard FlexibleSectorMigration.isLegacy(raw), !FlexibleSectorMigration.controlNoMigration,
              !FlexibleSectors.controlSurfaceRoute, let mesh = project.viewerMesh else { return nil }
        let key = FlexibleSectorMigration.MemoKey(raw: raw, faceRegions: project.faceRegions,
                                                  groups: project.selection.groups.map(\.regionIDs),
                                                  includes: includeSpecs, meshCount: mesh.faceIDs.count)
        if let m = migrationMemo, m.key == key { return m.moved }
        if !sectorNumbersSeeded { sectorNumbersSeeded = true }
        let moved = FlexibleSectorMigration.move(raw, faceRegions: project.faceRegions, mesh: mesh,
                                                 used: Set(project.selection.groups.flatMap(\.regionIDs).map { Int($0) }),
                                                 includes: key.includes, numbers: sectorNumbers)
        migrationMemo = (key, moved)
        return moved
    }

    /// ★ (i) THE MOVE AT OPEN: a project saved by I2, with nothing undoable — the Surface stage's regions get I2's cuts back
    /// and the file the Flexible form, as the LOADED state (the undo baseline is seeded: the move cannot be undone, and
    /// nothing he made is lost). With something undoable, his next Flexible edit makes the move (`edit`) as part of it.
    public func migrateSectorsAtOpen() {
        let raw = rawSettings
        guard let moved = sectorMigration(raw) else { return }
        migrationReport = moved.report
        guard !project.canUndoNow else { return }
        FlexibleSectorMigration.assignRegions(project, moved.restored)
        var s = moved.settings
        registerSectors(&s)
        project.lattice.flexible = s
        project.seedUndoBaseline()
        save()
        toast = FlexibleRowCopy.stripsMoved
    }

    // MARK: - the carry at open (c4)

    /// ★ THE CARRY: every LOADED face entry on a root now cut into lattice pieces (a whole face or Surface sector partly
    /// inside a face-prism, or one a strip cut), and every entry on a Flexible piece that is gone, is replaced by a copy on
    /// each of the root's pieces (each takes the root's first entry: a whole root holds every piece; a gone piece has no
    /// geometry), at the old entry's place. Re-expressed through core's frames where the old region is still declared (a
    /// face, a Surface sector): the stamp keeps its point on the part; a piece that does not hold the stamp's centre is
    /// Curves (the stamp stays stored). Rests stay whole (D2). nil: nothing to carry.
    func planCarry() async -> FlexibleSectionCarry? {
        guard !controlNoCarry, let mesh = project.viewerMesh else { return nil }
        let s = settings
        let regs = regions
        guard let set = regs.flexible, !set.pieces.isEmpty || s.faces.contains(where: { FlexibleSectors.isFlexible($0.faceRegionID) }) else { return nil }
        let base = restoredFaceRegions
        func targets(_ root: Int) -> [Int] {
            let pcs = set.pieces.filter { $0.rootRegion == root && $0.kind != .strip }.map(\.wireID)
            return pcs.isEmpty ? [root] : pcs
        }
        func rootOf(_ r: Int, loaded: Bool) -> Int? {
            if FlexibleSectors.isFlexible(r) {
                guard set.piece(r) == nil, let key = sectorNumbers.key(of: r - FlexibleSectors.base),
                      let token = FlexibleSectors.rootToken(ofKey: key) else { return nil }
                return FlexibleSectors.rootRegion(token: token, faceRegions: base, mesh: mesh)
            }
            guard loaded, set.pieces.contains(where: { $0.rootRegion == r && $0.kind != .strip }) else { return nil }
            return r
        }
        var faces = s.faces
        var toast: String?
        var groups: [(root: Int, olds: [FlexibleFaceSettings])] = []
        for f in s.faces {
            guard let root = rootOf(f.faceRegionID, loaded: f.isLoaded) else { continue }
            if let i = groups.firstIndex(where: { $0.root == root }) { groups[i].olds.append(f) } else { groups.append((root, [f])) }
        }
        for g in groups {
            let at = faces.firstIndex { e in g.olds.contains { $0.faceRegionID == e.faceRegionID } } ?? faces.count
            faces.removeAll { e in g.olds.contains { $0.faceRegionID == e.faceRegionID } }
            let existing = Set(faces.map(\.faceRegionID))
            let src = g.olds[0]
            // ★ ROUND 7 REVIEW (R, his answer 7 clarified: "an EQUAL SHARE PER LATTICE PART (two parts = 5 lb each of 10 lb,
            // whatever their size)"): the face's weight — the old entries' together — shared equally by its parts. M2 COPIED
            // it onto each (a face of his own then pressed twice its weight; a linked face is re-shared by the adopt anyway)
            let tg = targets(g.root)
            let share = FlexibleSectionShares.share(g.olds.map(\.weightKg).reduce(0, +), parts: tg.count)
            var news: [FlexibleFaceSettings] = []
            for t in tg where !existing.contains(t) {
                var f = src
                let declared = !FlexibleSectors.isFlexible(src.faceRegionID) || set.piece(src.faceRegionID) != nil
                if declared, src.faceRegionID != t {
                    if let r = try? await frameWorker.withScene({ try FlexiblePressReframe.reframe(src, from: .face(src.faceRegionID), to: .face(t),
                                                                                                 frames: FlexibleSceneFrames($0)) }) {
                        f = r.settings
                    }
                }
                f.faceRegionID = t
                f.weightKg = FlexibleSectionShares.controlCopyWeight ? src.weightKg : share
                // a stamp whose centre is not on the piece's lattice: Curves (the stamp stays stored, for a switch back)
                if f.isStampShape, let st = f.designStamp {
                    let holds = (try? await frameWorker.withScene { scene -> Bool in
                        let stack = try scene.stack(face: t, rotation: 0)
                        let iu = Int((st.centreU / stack.pitchMM).rounded(.down)), iv = Int((st.centreV / stack.pitchMM).rounded(.down))
                        return stack.column(iu, iv) >= 0
                    }) ?? false
                    // "curves", never nil: a stamp with no shape reads as round 3's Stamp (FlexibleSettingsMigration)
                    if !holds { f.shape = "curves"; toast = FlexibleRowCopy.stampStays(displayName(t)) }
                }
                news.append(f)
            }
            if toast == nil, !FlexibleSectors.isFlexible(src.faceRegionID) { toast = FlexibleRowCopy.nowPressesLattice(displayName(src.faceRegionID)) }
            faces.insert(contentsOf: news, at: Swift.min(at, faces.count))
        }
        var removed = s.removedRegions
        for r in s.removedRegions ?? [] {
            guard let root = rootOf(r, loaded: true) else { continue }
            for t in targets(root) where !(removed ?? []).contains(t) { removed = (removed ?? []) + [t] }
        }
        guard faces != s.faces || removed != s.removedRegions else { return nil }
        return FlexibleSectionCarry(from: s, faces: faces, removed: removed, toast: toast)
    }
}
