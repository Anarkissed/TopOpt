// FlexibleHold — WHAT HOLDS THE PART in a squeeze group's squish sim (task 2026-09-29-flexible-screens, round 7 · U21 batch I,
// part I1). The ONE place the hold is decided: it feeds the bridge request (FlexibleFERequest.hold), the Squish card's line and
// the tests.
//
// ★ HIS WORDS. 2026-10-21 Img15/16: "when it runs, it doesn't actually push the bottom face at all … It should absolutely be
// able to push the bottom face as long as there is not opposing push/rest!" ~15:35, the LBR-BOTTOM answer: "#1" — Rests hold
// it; with no Rests the Topology page's fixed faces hold it FOR THE SIM ONLY, no Rests added; with neither the far side stays
// held and the card says so. NARROWED by his decision of 2026-10-22 ~02:50: a group whose project HAS Rests stays EXACTLY as
// today (batch G's rules incl. the far anvil, byte for byte — the request carries rule 0 and no anchor); only without Rests does
// the new chain run: Topology's fixed faces (sim only) → the far side.
// ★ I3 (his picks of 2026-10-21 ~15:45: "the linked walls HOLD that lattice. It squashes against them and they stay put … The
// card always says what holds it ('Held by 4 linked walls')"): the LIVE links of the lattices a group presses into hold it,
// wherever they exist — first in his order (links → Rests → Topology → the far side); with Rests the two hold together (the
// walls take the far anvil's place). With no link nothing above changes, byte for byte. Display sim only (CORE LIST item 10).
//
// ★ THE RULE ON THE WIRE (flexible_squish_fe.cpp, hold_rule 1): no Rests and an anchor → the anchors BONDED (bc "anchor"), the
// group's own pressed faces never held; no Rests and no anchor → today's far side (exit glue when the presses do not balance,
// free when they do). Rests → today's chain (rule 0 is sent). Nothing here writes a Rest or touches a job.

import Foundation
import simd
import TopOptKit

/// The hold a sim request carries (FlexibleFERequest.hold → FlexSquishRequestInfo).
public struct FlexibleFEHold: Equatable, Sendable {
    /// 0 = today's chain (batch G's, far anvil included); 1 = the app's hold (FlexibleHold).
    public var rule: Int
    /// Topology's fixed B-rep / pseudo faces (the scene's face ids) and painted regions (the scene's region ids).
    public var anchorFaceIDs: [Int]
    public var anchorRegionIDs: [Int]
    public init(rule: Int, anchorFaceIDs: [Int] = [], anchorRegionIDs: [Int] = []) {
        self.rule = rule; self.anchorFaceIDs = anchorFaceIDs; self.anchorRegionIDs = anchorRegionIDs
    }
    /// Today's chain — every request with a Rest, and the RED control (`FlexibleFERequest.controlLegacyHold`).
    public static let legacy = FlexibleFEHold(rule: 0)
    /// The Topology anchors decide the hold (nothing rests).
    public var usesAnchors: Bool { rule == 1 && !(anchorFaceIDs.isEmpty && anchorRegionIDs.isEmpty) }
}

public enum FlexibleHold {

    /// One Topology fixed group (its name on screen, its faces and regions as the scene knows them).
    public struct Anchor: Equatable, Sendable {
        public let name: String
        public let faceIDs: [Int]
        public let regionIDs: [Int]
        public init(name: String, faceIDs: [Int], regionIDs: [Int] = []) {
            self.name = name; self.faceIDs = faceIDs; self.regionIDs = regionIDs
        }
        var ids: [Int] { faceIDs + regionIDs }
    }

    /// What holds a group's part.
    public enum Kind: Equatable, Sendable {
        /// ★ I3: `walls` linked walls hold it (and `rests` Rests beside them, 0: none).
        case links(Int, rests: Int)
        /// The project's Rests (today's chain, unchanged).
        case rests(Int)
        /// Topology's fixed faces, by group name (sim only).
        case topology([String])
        /// Nothing else: the far side of the pressed stacks (their exit faces' names, when known).
        case farSide([String])
        /// Nothing set and the presses push against each other.
        case balanced
    }

    /// The request's hold: rule 0 (today's chain, byte for byte) whenever a Rest exists or no Topology anchor does; else rule 1
    /// with every Topology anchor (the bridge skips the faces a group presses).
    public static func request(resting: [Int], anchors: [Anchor]) -> FlexibleFEHold {
        let faces = anchors.flatMap(\.faceIDs), regions = anchors.flatMap(\.regionIDs)
        guard resting.isEmpty, !(faces.isEmpty && regions.isEmpty) else { return .legacy }
        return FlexibleFEHold(rule: 1, anchorFaceIDs: uniq(faces), anchorRegionIDs: uniq(regions))
    }

    /// The decided hold of one group, before its sim lands: `pressed` its pressed faces / regions, `forces` its presses' design
    /// forces (N, model frame), `farFaces` the names of its stacks' exit faces.
    /// ★ I3: `links` — the live linked walls of the lattices the group presses into (they hold first, with the Rests if any).
    public static func decide(resting: [Int], anchors: [Anchor], pressed: Set<Int>, forces: [SIMD3<Double>],
                              farFaces: [String], links: Int = 0) -> Kind {
        if links > 0 { return .links(links, rests: resting.count) }
        if !resting.isEmpty { return .rests(resting.count) }
        let holding = anchors.filter { a in a.ids.contains { !pressed.contains($0) } }
        if !holding.isEmpty { return .topology(holding.map(\.name)) }
        return balanced(forces) ? .balanced : .farSide(farFaces)
    }

    /// The hold as the sim's receipt says it ran (bc mode, the anchors that pinned), the decided one where it agrees.
    /// ★ I3: `wallsHeld` — the linked walls that pinned ≥ 1 node (a wall that held nothing is not counted).
    public static func landed(_ decided: Kind, bcMode: String, anchorsHeld: [Int], anchors: [Anchor], farFaces: [String],
                              wallsHeld: Int = 0, resting: Int = 0) -> Kind {
        if wallsHeld > 0, bcMode == "wall" || bcMode == "rest" {
            return .links(wallsHeld, rests: bcMode == "rest" ? Swift.max(1, resting) : 0)
        }
        switch bcMode {
        case "rest":
            if case .rests = decided { return decided }
            return .rests(1)
        case "anchor":
            let names = anchors.filter { a in a.ids.contains { anchorsHeld.contains($0) } }.map(\.name)
            if names.isEmpty, case .topology = decided { return decided }
            return .topology(names.isEmpty ? ["Topology"] : names)
        case "exit": return .farSide(farFaces)
        case "free": return .balanced
        default: return decided
        }
    }

    /// The bridge's own balance test, mirrored (flexible_squish_fe.cpp: |Σ f| ≤ 2 % Σ |f|) so the line is right before the sim lands.
    /// `tolerance`: RED control only (a loose mirror).
    public static func balanced(_ forces: [SIMD3<Double>], tolerance: Double = FlexibleFE.balanced) -> Bool {
        let abs = forces.reduce(0) { $0 + simd_length($1) }
        guard abs > 0 else { return false }
        return simd_length(forces.reduce(SIMD3<Double>.zero, +)) <= tolerance * abs
    }

    /// The Squish card's one line (≤ 44 characters).
    public static func line(_ k: Kind) -> String {
        switch k {
        case .links(let n, let rests): return FlexibleRowCopy.Hold.links(n, rests: rests)
        case .rests(let n): return FlexibleRowCopy.Hold.rests(n)
        case .topology(let names): return names.count == 1 ? FlexibleRowCopy.Hold.topology(group: names[0]) : FlexibleRowCopy.Hold.topologyMany
        case .farSide(let faces): return FlexibleRowCopy.Hold.farSide(face: faces.count == 1 ? faces[0] : nil)
        case .balanced: return FlexibleRowCopy.Hold.balanced
        }
    }

    /// The line read by VoiceOver: its tail says where links are set — only when no link holds the group.
    public static func spoken(_ k: Kind) -> String {
        if case .links = k { return line(k) }
        return line(k) + FlexibleRowCopy.Hold.voiceOverTail
    }

    static func uniq(_ v: [Int]) -> [Int] {
        var seen = Set<Int>(), out: [Int] = []
        for x in v where seen.insert(x).inserted { out.append(x) }
        return out
    }
}

// MARK: the model's side (read-only: Topology's groups through the project's existing API; nothing is written)

extension FlexibleStageModel {

    /// Topology's fixed groups as the Flexible scene knows them: each fixed group's faces (the run's face ids — the scene opens the
    /// same import) and its painted regions (the scene's sector ids). Read through the project's own selection / force, as
    /// `ProjectModel.loadCase()` assembles them.
    public var topologyAnchors: [FlexibleHold.Anchor] {
        project.selection.groups.compactMap { g -> FlexibleHold.Anchor? in
            guard project.force.kind(for: g.id).isAnchor else { return nil }
            let faces = g.faces.map { Int(project.runFaceID($0)) }
            let regions = g.regionIDs.map { FlexibleRegions.sectorBase + $0 }
            guard !(faces.isEmpty && regions.isEmpty) else { return nil }
            return FlexibleHold.Anchor(name: g.name, faceIDs: faces, regionIDs: regions)
        }
    }

    /// The Rests the sims are solved with (every resting face of the setup — as the build task sends them).
    var holdResting: [Int] { settings.faces.filter { $0.role == "resting" }.map(\.faceRegionID) }

    /// Group `g`'s pressed faces / regions, its presses' design forces and its stacks' far faces.
    func holdInputs(_ g: FlexibleSqueezeGroup) -> (pressed: Set<Int>, forces: [SIMD3<Double>], far: [String]) {
        var pressed = Set(g.regions)
        var forces: [SIMD3<Double>] = []
        var far: [Int] = []
        for r in g.regions {
            guard let st = stacks[FlexFaceKey(region: r, rotation: 0)] ?? stacks.first(where: { $0.key.region == r })?.value else { continue }
            forces.append(st.load * (settings.face(r)?.weightN ?? 0))
            far += st.exitFaces.filter { $0.fraction >= 0.05 }.map(\.id)
        }
        for id in g.presses {
            guard let p = press(id) else { continue }
            pressed.formUnion(p.regions)
            forces.append(simd_normalize(p.direction) * p.settings.weightN)
        }
        let names = FlexibleHold.uniq(far.filter { !pressed.contains($0) }).map { name($0) }
        return (pressed, forces, names)
    }

    /// What holds group `g`'s part: from its sim's receipt once landed, else as decided.
    public func holdKind(_ g: FlexibleSqueezeGroup) -> FlexibleHold.Kind {
        let i = holdInputs(g)
        let anchors = topologyAnchors
        let id = FlexibleSim.groupID(g.number)
        // ★ I3: the walls the shown sims solve with (a lattice shown), else the live links now
        let links = (lattice != nil ? shownWalls[id] : linkWalls()[id])?.count ?? 0
        let decided = FlexibleHold.decide(resting: holdResting, anchors: anchors, pressed: i.pressed, forces: i.forces, farFaces: i.far,
                                          links: links)
        guard let f = shownSquishField(id) else { return decided }
        return FlexibleHold.landed(decided, bcMode: f.bcMode, anchorsHeld: f.anchorsHeld, anchors: anchors, farFaces: i.far,
                                   wallsHeld: f.wallNodes.filter { $0 > 0 }.count, resting: holdResting.count)
    }

    /// The Squish card's line for group `g`.
    public func holdLine(_ g: FlexibleSqueezeGroup) -> String { FlexibleHold.line(holdKind(g)) }
}

// MARK: - ★ I3: the live links each group's sim is held by (read-only; nothing is written)

extension FlexibleStageModel {

    /// ★ RED CONTROL only (I3 test): every live link holds every group, whatever lattice its presses push into.
    nonisolated(unsafe) static var controlEveryLinkHoldsEveryGroup = false

    /// The emission the links' walls are read from — memoised on what it reads, the links themselves left out (a link never
    /// re-emits it).
    func linkRegions() -> [LatticeRegionSpec] {
        var lattice = project.lattice
        lattice.flexible?.links = nil
        let key = FlexibleIncludeMemoKey(lattice: lattice, selection: project.selection, force: project.force,
                                         faceRegions: project.faceRegions,
                                         mesh: project.viewerMesh.map { "\($0.signature.contentHash)|\($0.faceIDs.count)" } ?? "")
        if let m = linkRegionsMemo, m.key == key { return m.regions }
        let r = project.latticeJobRegions().regions
        linkRegionsMemo = (key, r)
        return r
    }

    /// Per squeeze group's sim id, the LIVE linked walls of the lattices its presses push into (a press pushes into the lattice
    /// whose key names a face it covers — its face-prism —, or its painted region). Stale and dormant links never count.
    public func linkWalls() -> [String: [FlexHeldWallInfo]] {
        let links = project.lattice.flexible?.links ?? []
        guard !links.isEmpty, let mesh = project.viewerMesh else { return [:] }
        let regions = linkRegions()
        var memo: [String: FlexibleLatticeWalls.Result?] = [:]
        func walls(_ key: String) -> FlexibleLatticeWalls.Result? {
            if let w = memo[key] { return w }
            let w = FlexibleLatticeWalls.walls(project: project, key: key, regions: regions)
            memo[key] = w
            return w
        }
        let live = links.enumerated().filter { FlexibleAttach.linkState(project, $0.element, walls: walls) == .live }
        guard !live.isEmpty else { return [:] }
        let sectors = self.regions
        var out: [String: [FlexHeldWallInfo]] = [:]
        for g in squeezeGroups {
            let pressed = holdInputs(g).pressed
            let faces = Set(pressed.flatMap { sectors.faces(of: $0, mesh: mesh) })
            var held: [FlexHeldWallInfo] = []
            for (i, l) in live {
                guard Self.controlEveryLinkHoldsEveryGroup || Self.pushesInto(l.lattice, faces: faces, regions: pressed),
                      let w = walls(l.lattice)?.wall(l.wall), !w.quads.isEmpty else { continue }
                held.append(FlexHeldWallInfo(m: w.m, quads: w.quads.flatMap { q in q.flatMap { [$0.x, $0.y, $0.z] } }, tag: i))
            }
            if !held.isEmpty { held.sort { $0.tag < $1.tag }; out[FlexibleSim.groupID(g.number)] = held }
        }
        return out
    }

    /// The lattice keyed `key` is the one a group pressing `faces` (B-rep) / `regions` (its region ids) pushes into.
    static func pushesInto(_ key: String, faces: Set<Int>, regions: Set<Int>) -> Bool {
        switch FlexibleAttach.ref(key) {
        case let .face(_, f)?: return faces.contains(Int(f))
        case let .region(_, r)?: return regions.contains(FlexibleRegions.sectorBase + Int(r))
        default: return false
        }
    }
}
