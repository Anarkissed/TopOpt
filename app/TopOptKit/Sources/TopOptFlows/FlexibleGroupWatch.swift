// FlexibleGroupWatch — the MAIN page's own group edits followed into the Flexible groups LIVE, on every stage (task
// 2026-09-29-flexible-screens, round 6 item 4 verification). One set of groups both ways: FlexibleGroupSync writes
// Settings' actions onto the main page; this follows the main page's (Topology, Optimize, the Flexible stage alike)
// into Settings, in the SAME undo step (it writes on the next turn of the main queue, inside #354's 0.4 s settle):
//   * HIS FORCE ANSWER — a squeeze group's force is one number: a weight set on ONE of its hands (a pinch side's row —
//     the scrub or the pad) is written to every hand of that group (the verifier's P3: 6 kg on "Group 2 · Face 4" left
//     face 2 at 4.5 kg, a net 14 N on the part in Topology);
//   * HIS DELETE ANSWER, MIRRORED — a face linked to a main-page group that no longer holds it with a role (the group
//     deleted, its role cleared, the face moved into a group with no role) leaves Settings, parked with its squish
//     detail; a parked face a group presses or rests again comes back with it (FlexibleStageModel.parkOrphans /
//     unpark — the adopt does the same, with core's directions, on every Flexible open);
//   * ONE UNIT — the main page's kg / lbs toggle switches Settings' weights too (Settings' own toggle writes the main
//     page's — FlexibleWeightUnit.setWeightUnit); N and kN stay Settings' own.
// Nothing here reads a direction (core's stacks are the adopt's), so this and the adopt never undo each other.
// Installed by FlexibleMainStage (H3's call reaches it on every stage) for a project with a Flexible stage.

import Combine
import Foundation

@MainActor
final class FlexibleGroupWatch {
    let projectID: UUID
    private weak var project: ProjectModel?
    /// The roles and weights as last seen (what moved since is "changed"), and the groups.
    private var lastForce: ForceModel
    private var lastSelection: SelectionModel
    /// The expansion (areas, normals, sectors) of the part as it is — rebuilt only when the regions or the mesh change.
    private var expander: (key: String, x: FlexibleMainPageLoads.Expander)?
    private var subscriptions: [AnyCancellable] = []
    private var scheduled = false
    /// How many times it wrote (tests).
    private(set) var writes = 0

    init(project: ProjectModel) {
        projectID = project.id
        self.project = project
        lastForce = project.force
        lastSelection = project.selection
        subscriptions = [
            project.$force.dropFirst().sink { [weak self] _ in self?.schedule() },
            project.$selection.dropFirst().sink { [weak self] _ in self?.schedule() },
        ]
    }

    /// (@Published emits before the value is set: the look runs on the next turn, after it landed.)
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.follow()
        }
    }

    /// Follow the main page once (also called directly by tests).
    func follow() {
        guard let p = project else { return }
        let seenForce = lastForce, seenSelection = lastSelection
        defer { lastForce = p.force; lastSelection = p.selection }
        guard let stored = p.lattice.flexible, let mesh = p.viewerMesh else { return }
        let s = FlexibleSettingsMigration.migrated(stored)
        let regions = FlexibleRegions(model: p.faceRegions, mesh: mesh)
        let key = "\(regions.key)|\(p.faceRegions.regions.count)|\(mesh.triangleCount)|\(mesh.positions.count)"
        let x: FlexibleMainPageLoads.Expander
        if let e = expander, e.key == key { x = e.x } else {
            x = FlexibleMainPageLoads.Expander(faceRegions: p.faceRegions, mesh: mesh, regions: regions)
            expander = (key, x)
        }
        var w = FlexibleGroupWorld(selection: p.selection, force: p.force, flexible: s, x: x,
                                   latticeRoles: Set(p.lattice.groupRoles.keys))
        // (1) one force per squeeze group
        var changed = Set<UUID>()
        for g in p.selection.groups {
            guard let now = p.force.kind(for: g.id).weightKg, let was = seenForce.kind(for: g.id).weightKg,
                  seenForce.kind(for: g.id).isLoad, abs(now - was) > 1e-9 else { continue }
            changed.insert(g.id)
        }
        w.equaliseHands(changed: changed)
        // (2) a face its group let go of: parked; back with its detail when a group holds it with a role again (only
        // "held or not": a face whose group pulls is the adopt's, which knows core's direction). Only when the groups or
        // a role moved — a weight alone (the scrub) never holds or lets go of a face
        var flex = w.flexible
        if p.selection != seenSelection || Self.roles(p.force, p.selection) != Self.roles(seenForce, p.selection) {
            let l = w.loads()
            let skip = Set(flex.removedRegions ?? []).union(flex.pressRegions)
            let membership = FlexibleMainPageLoads(entries: l.entries.filter { $0.value.role != .ask })
            let asks = Set(l.entries.filter { $0.value.role == .ask }.map(\.key))
            FlexibleStageModel.parkOrphans(&flex, loads: membership, skip: skip.union(asks))
            FlexibleStageModel.unpark(&flex, loads: membership, skip: skip)
        }
        // (3) one unit: the main page's kg / lbs, where Settings shows kg or lb
        if p.force.unit != seenForce.unit {
            let mine = FlexibleWeightUnit(stored: flex.weightUnit)
            if mine == .kg || mine == .lb { flex.weightUnit = p.force.unit == .kg ? nil : FlexibleWeightUnit.lb.rawValue }
        }
        if w.force != p.force { p.force = w.force; writes += 1 }
        if flex != s { p.lattice.flexible = flex; writes += 1 }
    }

    /// Each group's role, its weight left out (anchor / load and its direction / pending / keep clear).
    static func roles(_ f: ForceModel, _ s: SelectionModel) -> [String] {
        s.groups.map { g in
            switch f.kind(for: g.id) {
            case .anchor: return "a"
            case let .load(d, _): return "l\(d.rawValue)"
            case .pending: return "p"
            case .clearance: return "c"
            }
        }
    }
}

extension FlexibleMainStage {
    /// The watch for `project` (made once per project, on any stage — H3's call), or nil without a Flexible stage.
    func watch(_ project: ProjectModel) {
        guard project.lattice.flexible != nil else { return }
        if let g = groupWatch, g.projectID == project.id { return }
        groupWatch = FlexibleGroupWatch(project: project)
    }
}
