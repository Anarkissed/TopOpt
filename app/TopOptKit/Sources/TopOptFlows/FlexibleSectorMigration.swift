// FlexibleSectorMigration — I2's edge strips move from the Surface stage to Flexible-only sectors (task
// 2026-09-29-flexible-screens, round 7 batch M2; the reviewer's ruling 3: "If I2 already writes Surface sectors, move them
// to Flexible-only and say what moved.").
//
// ★ WHAT I2 DID (round 6 item 2). [Done] cut each strip with the Surface tool's own cut INTO `project.faceRegions` — an
// identity region for the face, then splitManual / splitDetached — and keyed the presses and the faces' rests on those
// Surface sectors (wire id 1 000 000 + FaceRegion id). So the Surface stage listed them, Selections' Regions popover
// listed them, and Topology's, the lattice stage's and the Stress solve's requests declared them (RemoteRunner emits
// face_regions whenever the list is non-empty).
// ★ THE MOVE. A project in I2's form (no Flexible store, a strip member with a Surface root) is read THROUGH at once
// (`move`, the house rule of FlexibleSettingsMigration — undo-safe): each strip chain whose pieces he does not use on
// another stage (no Selections group holds one) is reverted on the Surface stage's regions — I2's own plan with no pick
// left, so the regions are exactly as before the cut (nextID stays advanced; ids are never reused) — and the same strips
// are derived as Flexible-only sectors (FlexibleSectors: the same calls, so the same cuts, bit for bit); every id the
// settings held on those chains is re-keyed to its Flexible piece. A chain he uses elsewhere STAYS on the Surface stage
// (said, with the reason); its strips are still the Flexible store's own pieces, so no two entries share surface.
// ★ THE WRITE. Once: at open when nothing is undoable (the loaded state — FlexibleStageModel.migrateSectorsAtOpen), else as
// part of his next Flexible edit (one undo step; undo returns I2's bytes, which read through again). This file holds the
// ONE place Flexible code writes `project.faceRegions` (`assignRegions`), and it only gives I2's cuts back.

import Foundation
import TopOptKit

public enum FlexibleSectorMigration {

    /// What the move did, said in plain words (the handoff prints it for his project).
    public struct Report: Equatable, Sendable {
        /// Surface regions removed (id, name).
        public var removed: [(id: Int, name: String)] = []
        /// Flexible pieces made (key, wire id, name).
        public var made: [(key: String, id: Int, name: String)] = []
        /// Re-keys: old id → new id, and what it belongs to ("Face 1", "press <id>").
        public var rekeyed: [(old: Int, new: Int, owner: String)] = []
        /// Chains kept on the Surface stage, with the reason.
        public var kept: [(root: Int, line: String)] = []
        public init() {}
        public var isEmpty: Bool { removed.isEmpty && made.isEmpty && rekeyed.isEmpty && kept.isEmpty }
        public static func == (a: Report, b: Report) -> Bool {
            a.removed.map(\.id) == b.removed.map(\.id) && a.removed.map(\.name) == b.removed.map(\.name)
                && a.made.map(\.key) == b.made.map(\.key) && a.made.map(\.id) == b.made.map(\.id)
                && a.rekeyed.map(\.old) == b.rekeyed.map(\.old) && a.rekeyed.map(\.new) == b.rekeyed.map(\.new)
                && a.kept.map(\.root) == b.kept.map(\.root) && a.kept.map(\.line) == b.kept.map(\.line)
        }
    }

    /// ★ RED CONTROL: no migration — I2's strips stay on the Surface stage (Topology keeps carrying them).
    nonisolated(unsafe) static var controlNoMigration = false

    /// What the move makes: the settings in the Flexible form, the Surface stage's regions with I2's cuts given back, and
    /// what moved.
    public struct Moved {
        public let settings: FlexibleStageSettings
        public let restored: FaceRegionModel
        public let report: Report
    }

    /// What the read-through is made from (the stage model memoises it).
    struct MemoKey: Equatable {
        var raw: FlexibleStageSettings
        var faceRegions: FaceRegionModel
        var groups: [[RegionID]]
        var includes: [LatticeRegionSpec]
        var meshCount: Int
    }

    /// ★ THE READ-THROUGH (pure): I2's settings and Surface regions → the Flexible form, the regions given back, the Report.
    /// `used`: the FaceRegion ids his Selections groups hold (a chain with one of them stays on the Surface stage).
    static func move(_ raw: FlexibleStageSettings, faceRegions: FaceRegionModel, mesh: ViewerMesh, used: Set<Int>,
                     includes: [LatticeRegionSpec], numbers: FlexibleSectorNumbers) -> Moved {
        var report = Report()
        let presses = raw.presses ?? []
        let roots = Set(presses.compactMap(\.strip).flatMap { $0.members.map(\.root) }.filter { $0 >= 0 })
        func below(_ id: Int) -> Set<Int> {
            var out = Set<Int>(), todo = [id]
            while let x = todo.popLast() {
                for c in faceRegions.children(of: x) where out.insert(c.id).inserted { todo.append(c.id) }
            }
            return out
        }
        var revertible = Set<Int>()
        for r in roots.sorted() {
            if below(r).isDisjoint(with: used) { revertible.insert(r); continue }
            let name = faceRegions.region(r).map { $0.name.isEmpty ? "Region \($0.id)" : $0.name } ?? "Region \(r)"
            report.kept.append((root: r, line: FlexibleRowCopy.cutStaysOnSurface(name)))
        }
        // the Surface stage's regions with the revertible chains given back (I2's own plan, no pick left)
        var restored = FlexibleEdgeStrips.plan([], replay: revertible, faceRegions: faceRegions, mesh: mesh, keep: used).faceRegions
        for r in revertible.sorted() {
            if let reg = restored.region(r), reg.isCut, restored.children(of: r).isEmpty { restored.setCollapsed(r, true) }
        }
        for reg in faceRegions.regions where restored.region(reg.id) == nil {
            report.removed.append((id: reg.id, name: reg.name))
        }
        // the Flexible form: every strip member's root derived (−1), the same strips resolved on the given-back regions
        var flex = raw
        var strips: [(id: UUID, strip: FlexibleStrip)] = []
        if var list = flex.presses {
            for i in list.indices {
                guard var st = list[i].strip else { continue }
                for k in st.members.indices { st.members[k].root = -1 }
                list[i].strip = st
                strips.append((list[i].id, st))
            }
            flex.presses = list
        }
        let set = FlexibleSectors.resolve(mesh: mesh, faceRegions: restored, includes: includes, strips: strips, numbers: numbers)
        // re-key: a strip piece → its press's Flexible piece; anything else on a given-back chain → the Flexible piece on its
        // face holding most of it (the same cuts: a copy)
        var map: [Int: Int] = [:]
        var owner: [Int: String] = [:]
        for p in presses {
            guard let new = set.stripRegions[p.id] else { continue }
            for (k, old) in p.regions.enumerated() where k < new.count { map[old] = new[k]; owner[old] = "press \(p.id.uuidString.prefix(8))" }
        }
        var under: [Int: FaceRegion] = [:]
        for r in revertible { for id in below(r).union([r]) { if let reg = faceRegions.region(id) { under[FlexibleRegions.wireID(reg)] = reg } } }
        let ids = raw.faces.map(\.faceRegionID) + raw.checkStamps.map(\.faceRegionID) + (raw.removedRegions ?? [])
        for old in ids where map[old] == nil {
            guard let reg = under[old] else { continue }
            let faces = FaceRegionGeometry.members(of: reg, in: mesh).map { Int($0) }
            guard let face = faces.first else { continue }
            let tris = FlexibleEdgeStrips.triangles(face: face, mesh: mesh)
            let best = set.pieces.filter { $0.kind != .strip && FaceRegionGeometry.members(of: $0.region, in: mesh).map { Int($0) } == faces }
                .map { ($0.wireID, FlexibleEdgeStrips.area(tris, reg.cuts + $0.region.cuts)) }
                .max { $0.1 < $1.1 }
            if let b = best, b.1 > 1e-6 { map[old] = b.0 } else if reg.isIdentity || !reg.isCut { map[old] = face }
            owner[old] = "Face \(face)"
        }
        func re(_ id: Int) -> Int { map[id] ?? id }
        for i in flex.faces.indices { flex.faces[i].faceRegionID = re(flex.faces[i].faceRegionID) }
        for i in flex.checkStamps.indices { flex.checkStamps[i].faceRegionID = re(flex.checkStamps[i].faceRegionID) }
        if let rr = flex.removedRegions { flex.removedRegions = rr.map(re) }
        if var list = flex.presses {
            for i in list.indices {
                guard list[i].strip != nil, let new = set.stripRegions[list[i].id], new.count == list[i].regions.count else { continue }
                // the same pieces under their Flexible ids: never `setMembers` (the footprint and the aim did not move)
                list[i].regions = new
                list[i].settings.faceRegionID = new[0]
            }
            flex.presses = list
        }
        var store: [String: Int] = [:]
        for pc in set.pieces { store[pc.key] = pc.number }
        flex.sectors = FlexibleSectorStore(version: FlexibleSectorStore.currentVersion, ids: store)
        report.made = set.pieces.map { (key: $0.key, id: $0.wireID, name: $0.region.name) }
        report.rekeyed = map.sorted { $0.key < $1.key }.map { (old: $0.key, new: $0.value, owner: owner[$0.key] ?? "") }
        return Moved(settings: flex, restored: restored, report: report)
    }

    /// The Report in plain lines (the handoff prints it for his project).
    public static func lines(_ r: Report) -> [String] {
        var out: [String] = []
        for x in r.removed { out.append("Surface region \(x.id) \"\(x.name)\" removed (an I2 cut, given back)") }
        for x in r.made { out.append("Flexible sector \(x.id) \"\(x.name)\" made (\(x.key))") }
        for x in r.rekeyed { out.append("\(x.owner): \(x.old) → \(x.new)") }
        for x in r.kept { out.append("kept on Surface: region \(x.root) — \(x.line)") }
        return out
    }

    /// I2's form: no Flexible store, and a strip member carries a Surface root (a project FaceRegion id).
    public static func isLegacy(_ s: FlexibleStageSettings) -> Bool {
        s.sectors == nil && (s.presses ?? []).contains { $0.strip?.members.contains { $0.root >= 0 } ?? false }
    }

    /// ★ THE ONE PLACE Flexible code writes the Surface stage's regions — only to give back what I2 cut there.
    @MainActor
    static func assignRegions(_ project: ProjectModel, _ m: FaceRegionModel) {
        project.faceRegions = m
    }
}
