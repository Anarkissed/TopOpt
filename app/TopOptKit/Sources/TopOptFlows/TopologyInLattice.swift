// TopologyInLattice — his iPad notes 2026-11-22 (img 6, 11, 12).
//
// His words: "When I tap on the "Topology" selections, it should automatically show all the topology assets - I should be able
// to edit the groups/faces/anchors/loads/design box from Topology. It should immediately hide all things for the lattice
// selections." — "I only want 6 handles at a time, for each primitive I select." — and on the Forces view: "I'd rather have
// something that hides all the keep clears" (his decision: keep Forces, add "Hide keep clears" beside it).
//
// His decisions: (a) the Topology shown on Lattice Setup is THE SAME setup as the Topology stage (an edit there is Topology's,
// and the stress check that reads Topology's loads is out of date after it); (b) "modify" = a group's role and numbers, its
// faces, and moving / resizing the keep-clear shapes and the design box — never a new group, load, scenario or shape.
//
// The page (WorkspacePlaceholder) keeps no new @State and grows by no byte (WorkspaceBodySizeTests): the view's session state
// lives here, held by the AppModel (`AppModel.topologyView`), whose observers redraw when it changes.
import SwiftUI
import Combine
import simd

/// The Topology view's own state for the session (the Topology stage, and Lattice Setup with its Topology panel open).
@MainActor
public final class TopologyViewState: ObservableObject {
    /// ★ "Hide keep clears": on hides every keep-clear shape and its handles. A VIEW: they still keep clear in the run.
    @Published public var keepClearsHidden = false
    /// ★ The Design box row (its id) whose handles show; nil: none ("6 handles at a time, for each primitive I select").
    @Published public var pickedDesignRow: Int?
    /// Its changes, passed on to the model that holds it (the page observes that model).
    var relay: AnyCancellable?

    public init() {}

    /// Back to how a session starts (the hosted tests share the one instance).
    public func reset() { keepClearsHidden = false; pickedDesignRow = nil }
}

/// The words and the icon of the Topology view's additions.
public enum TopologyViewCopy {
    /// The view button beside Forces (on = keep clears hidden).
    public static let hideKeepClears = "Hide keep clears"
    public static let hideKeepClearsIcon = "eye.slash"
    /// ★ The Topology panel's (i) on Lattice Setup: the two notes that sat inside the panel when a group was switched off
    /// (his "NOTHING cuts into the modal"), word for word.
    public static var panelInfo: String {
        LatticeSetupCopy.resultKeepsGroups + "\n\n" + LatticeSetupCopy.protectStillApplies
    }
}

/// ★ "I only want 6 handles at a time, for each primitive I select": which Design box rows show their handles, and which row a
/// tap on the part picks. Pure, so the rule is tested without a screen.
public enum DesignRowHandles {
    /// RED CONTROL: every shown row's handles at once (as before his 11-22 note).
    @MainActor public static var controlEveryRow = false

    /// A Negative row ("No mass here") is a keep clear: "Hide keep clears" hides it with the rest.
    public static func isKeepClear(_ p: DesignPrimitive) -> Bool { p.sign == .negative }

    /// Whether a row is drawn at all (its eye on, and not a hidden keep clear).
    public static func drawn(_ p: DesignPrimitive, keepClearsHidden: Bool) -> Bool {
        p.isShown && !(keepClearsHidden && isKeepClear(p))
    }

    /// The rows (by id) whose handles draw: the picked row alone, if it is drawn; none when nothing is picked.
    @MainActor
    public static func shown(_ d: DesignBoxModel, picked: Int?, keepClearsHidden: Bool) -> Set<Int> {
        let drawn = d.primitives.filter { drawn($0, keepClearsHidden: keepClearsHidden) }.map(\.id)
        if controlEveryRow { return Set(drawn) }
        guard let picked, drawn.contains(picked) else { return [] }
        return [picked]
    }

    /// The row a tap's ray (model frame, `dir` unit) picks: the nearest drawn row it enters, except where the part under the
    /// finger lies inside that row (the tap is the part's then — the design box holds the whole part). `surface` is the
    /// distance to the part along the ray, nil when the ray misses the part. nil: no row.
    public static func pick(_ d: DesignBoxModel, origin: SIMD3<Float>, dir: SIMD3<Float>, surface: Float?,
                            keepClearsHidden: Bool) -> Int? {
        let hit = surface.map { origin + dir * $0 }
        var best: (id: Int, t: Float)?
        for p in d.primitives where drawn(p, keepClearsHidden: keepClearsHidden) {
            guard let t = entry(p.bounds, origin: origin, dir: dir) else { continue }
            if let s = surface, let h = hit {
                if t > s + 0.5 { continue }                                    // behind the part: not what he tapped
                if p.bounds.contains(h) { continue }                           // the part under the finger is inside it
            }
            if best.map({ t < $0.t }) ?? true { best = (p.id, t) }
        }
        return best?.id
    }

    /// Where a ray enters a box (the slab method); 0 from inside; nil when it misses or the box is behind.
    static func entry(_ b: DesignBoxBounds, origin o: SIMD3<Float>, dir d: SIMD3<Float>) -> Float? {
        var tMin: Float = 0, tMax = Float.greatestFiniteMagnitude
        for a in 0..<3 {
            if abs(d[a]) < 1e-9 {
                if o[a] < b.min[a] || o[a] > b.max[a] { return nil }
                continue
            }
            let t1 = (b.min[a] - o[a]) / d[a], t2 = (b.max[a] - o[a]) / d[a]
            tMin = Swift.max(tMin, Swift.min(t1, t2))
            tMax = Swift.min(tMax, Swift.max(t1, t2))
            if tMin > tMax { return nil }
        }
        return tMin
    }
}

/// Test hooks: what the page drew last (a hosted test cannot read the Metal view's volumes).
public enum TopologyViewLive {
    @MainActor public static var recordLive = false
    /// The keep-clear volumes the Topology view drew last.
    @MainActor public static var keepClearVolumes = 0
    /// How many times an edit in Topology's view on Lattice Setup found the stress check out of date and said so.
    @MainActor public static var stressMarkedStale = 0
    /// RED CONTROL: an edit made there leaves the stress check as it was (as before his 11-22 decision (a)).
    @MainActor public static var controlNoStressMark = false
}

extension WorkspaceStageVisibility {
    /// ★ his 11-22 (img 6): Lattice Setup with its Topology panel open — Topology's in-scene editors (the design box, the keep-clear
    /// shapes and their handles, the load arrows), none of the lattice selections' (no depth planes, no prisms, no zone boxes);
    /// the lattice's own preview, its views and its watchers stay mounted.
    public static let topologyInLattice = WorkspaceStageVisibility(designBox: true, groupPrimitives: true, keepOuts: true,
                                                                   latticeDepthPlanes: false, latticeControls: true,
                                                                   wireframe: true, topologyRows: true)

    /// The table with both modes applied: editing faces wins; then Topology's panel open on Lattice Setup.
    public static func of(_ stage: WorkspaceStage, editingFaces: Bool, topologyInLattice: Bool) -> WorkspaceStageVisibility {
        if editingFaces { return .editingFaces }
        return topologyInLattice && stage == .lattice ? .topologyInLattice : .of(stage)
    }
}

extension DesignRowHandles {
    /// The row (its id) a handle belongs to: the design box is the run's row, `.keepOut(k)` the k-th other row.
    public static func row(of h: DesignBoxDragSession.HandleID, in d: DesignBoxModel) -> Int? {
        switch h.target {
        case .designBox: return d.primaryIndex.map { d.primitives[$0].id }
        case .keepOut(let k):
            let idx = d.otherIndices
            return idx.indices.contains(k) ? d.primitives[idx[k]].id : nil
        }
    }

    /// The frame a drawn handle publishes: "designHandle-<row id>-move", "designHandle-<row id>-x+" (the hosted tests count them).
    public static func frameKey(_ h: DesignBoxDragSession.HandleID, in d: DesignBoxModel) -> String {
        let kind: String
        switch h.kind {
        case .move: kind = "move"
        case .face(let axis, let isMax): kind = ["x", "y", "z"][axis] + (isMax ? "+" : "-")
        }
        return "designHandle-\(row(of: h, in: d) ?? -1)-\(kind)"
    }
}
