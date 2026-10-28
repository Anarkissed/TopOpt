// FlexibleAttach — the Attach tool's steps, its hit test, its links' states and its words (task 2026-09-29-flexible-screens,
// round 7 · U21 batch I, part I2). His answer of 2026-10-21 ~15:35: "Use the link icon (two chain pieces together). Make it so
// when you select the lattice in the selections, it is an option/tool in the dragable modal, once clicked, it shows the
// lattice on its own, you select a wall, then it shows the model with the lattice as a ghost and you select the face it is
// meant to connect to. And you should be able to do this multiple times per lattice object." His picks ~15:45: targets are
// only the solid a wall touches (lit; the rest greyed); one-tap suggestion "Attach to the 4 walls around it" (nothing set
// until he taps); the link listed under the lattice ("Side 2 → wall") with a trash that asks first.
//
// ★ PURE: the step machine (`FlexibleAttach.step`) decides; the stage (FlexibleMainStage+Attach) applies its effect (one sealed
//   undo step per link — FlexibleFaceCommits). A stray tap never ends the steps: only Cancel / Done / ✕ (or an outside end).
// ★ LINKS ARE NEVER PRUNED: a link whose wall or solid is gone is STALE (greyed, its reason, its trash the fix); a link whose
//   group was deleted is DORMANT (listed nowhere; an Undo of the delete brings it back with no write).

import CoreGraphics
import Foundation
import simd

/// Where the Attach tool is.
public enum FlexibleAttachStep: Equatable, Sendable {
    case off
    /// Step 1 · the lattice alone: tap a wall.
    case pickWall
    /// Step 2 · the model, the lattice a ghost: tap the solid `wall` connects to.
    case pickTarget(wall: String)
}

/// The Attach tool's state on the main page (one value; the stage publishes it).
public struct FlexibleAttachState: Equatable, Sendable {
    public var step: FlexibleAttachStep = .off
    /// The lattice's selectable key ("f:<group>:<face>") and its group.
    public var lattice = ""
    public var group: UUID?
    /// "Face 6" (the card's title).
    public var faceName = ""
    /// Links made since this Attach opened ([Done] replaces [Cancel]).
    public var linkedHere = 0
    /// The one say line (a greyed tap's reason, "Linked Side 2 → wall", a stray tap's hint).
    public var say: String?
    /// A wall a Selections row flashed.
    public var flash: String?

    public init() {}
    public var active: Bool { step != .off }
    public var wall: String? { if case let .pickTarget(w) = step { return w }; return nil }
    public static let off = FlexibleAttachState()
}

/// What a tap during Attach is.
public enum FlexibleAttachTap: Equatable, Sendable {
    /// A wall chip or tag (or a canvas tap that hit a wall — step 1).
    case wall(String)
    /// A target chip or tag (or a canvas tap on the lit target — step 2).
    case target(String)
    /// A canvas tap on model face N with no wall / target under it.
    case face(Int)
    /// Empty canvas (or nothing hit).
    case miss
    case back
    case cancel
}

/// What the stage must do after a tap.
public enum FlexibleAttachEffect: Equatable, Sendable { case none, link(wall: String, target: String), end }

public enum FlexibleAttach {

    /// ★ RED CONTROL (I2 test 7): names by SCREEN order (left to right) — two camera frames disagree.
    nonisolated(unsafe) static var controlNamesByScreenOrder = false
    /// ★ RED CONTROL (hosted e): today's routing — a stray tap (tapFace / missTap) runs first and Attach ends.
    nonisolated(unsafe) static var controlStrayTapCancels = false
    /// ★ RED CONTROL (hosted a): the Attach row on every face card (a Solid face, a drilled-in legend).
    nonisolated(unsafe) static var controlAttachEverywhere = false
    /// ★ RED CONTROL (hosted b): the step changes nothing in the view (body, prisms, the other lattices as they were).
    nonisolated(unsafe) static var controlAttachKeepsTheView = false
    /// ★ RED CONTROL (hosted c): no ghost and no dimmed faces in step 2.
    nonisolated(unsafe) static var controlNoGhostInStepTwo = false
    /// ★ RED CONTROL (hosted g): the tags placed once at the step's start, never re-projected.
    nonisolated(unsafe) static var controlTagsPlacedOnce = false
    /// ★ RED CONTROL (hosted h): Kind `.attach` measured as `.member` (the step card's buttons clipped / on the chrome).
    nonisolated(unsafe) static var controlAttachUsesMemberSize = false
    /// ★ RED CONTROL (I2 test 16): I2's first rule — step 2's overlay ghost only with no (or a stale) lattice.
    nonisolated(unsafe) static var controlOverlayGhostOnlyWhenStale = false
    /// Step 2 draws the lattice's walls at the ghost alpha on top of the model. His words: "it shows the model with the
    /// lattice as a ghost". The pass's own ghost (0.12, depth .always) was not visible over the opaque body (I2_03), so the
    /// overlay draws it whether or not a lattice is built.
    static func overlayDrawsGhost(fresh: Bool) -> Bool { controlOverlayGhostOnlyWhenStale ? !fresh : true }
    /// ★ RED CONTROL (I2 test 13): stale links pruned when listed.
    nonisolated(unsafe) static var controlPruneStale = false

    public static func start(lattice: String, group: UUID, faceName: String) -> FlexibleAttachState {
        var s = FlexibleAttachState()
        s.step = .pickWall
        s.lattice = lattice
        s.group = group
        s.faceName = faceName
        return s
    }

    /// The step line: "1 of 2 · Tap a wall of the lattice" / "2 of 2 · Tap what Side 2 connects to".
    public static func stepLine(_ s: FlexibleAttachState, walls: FlexibleLatticeWalls.Result?) -> String {
        switch s.step {
        case .off: return ""
        case .pickWall: return FlexibleSelectionsCopy.attachStep1
        case let .pickTarget(w): return FlexibleSelectionsCopy.attachStep2(walls?.wall(w)?.name ?? "the wall")
        }
    }

    /// Why a wall cannot be tapped (one line, ≤ 44).
    public static func reason(_ w: FlexibleLatticeWalls.Wall) -> String {
        switch w.status {
        case .target: return ""
        case .open: return FlexibleSelectionsCopy.attachOpen(w.name)
        case .seam: return FlexibleSelectionsCopy.attachSeam(w.name)
        case .thin: return FlexibleSelectionsCopy.attachThin(w.name)
        case .gone: return FlexibleSelectionsCopy.attachGone(w.name)
        }
    }

    /// ★ THE STEP MACHINE. `linked`: this lattice's live links as "wall|target"; `outsideFaces`: the model faces lying on the
    /// picked wall's plane facing out ("Face 2 is the part's outside"). A stray tap never ends the steps.
    public static func step(_ s0: FlexibleAttachState, _ tap: FlexibleAttachTap, walls: FlexibleLatticeWalls.Result?,
                            linked: Set<String>, outsideFaces: Set<Int> = []) -> (FlexibleAttachState, FlexibleAttachEffect) {
        var s = s0
        s.flash = nil
        switch (s.step, tap) {
        case (.off, _):
            return (s, .none)
        case (_, .cancel):
            return (.off, .end)
        case (.pickTarget, .back):
            s.step = .pickWall
            s.say = nil
            return (s, .none)
        case (.pickWall, .back):
            return (s, .none)
        case let (.pickWall, .wall(k)):
            guard let w = walls?.wall(k) else { s.say = stepLine(s, walls: walls); return (s, .none) }
            guard w.tappable, w.target != nil else { s.say = reason(w); return (s, .none) }
            s.step = .pickTarget(wall: k)
            s.say = nil
            return (s, .none)
        case let (.pickTarget(k), .target(t)):
            guard let w = walls?.wall(k), w.tappable, let tw = w.target else {
                s.step = .pickWall
                s.say = FlexibleSelectionsCopy.attachChanged(walls?.wall(k)?.name ?? "The wall")
                return (s, .none)
            }
            guard t == tw else { s.say = stepLine(s, walls: walls); return (s, .none) }
            if linked.contains("\(k)|\(t)") { s.say = FlexibleSelectionsCopy.attachAlready(w.name, FlexibleLatticeWalls.targetName(t)); return (s, .none) }
            s.step = .pickWall
            s.linkedHere += 1
            s.say = FlexibleSelectionsCopy.attachLinked(w.name, FlexibleLatticeWalls.targetName(t))
            return (s, .link(wall: k, target: t))
        case let (.pickTarget(k), .face(f)):
            guard let w = walls?.wall(k) else { s.say = stepLine(s, walls: walls); return (s, .none) }
            if w.target == "skin:f\(f)" { return step(s, .target("skin:f\(f)"), walls: walls, linked: linked, outsideFaces: outsideFaces) }
            s.say = outsideFaces.contains(f) ? FlexibleSelectionsCopy.attachOutside(f) : FlexibleSelectionsCopy.attachNotTouching(f, w.name)
            return (s, .none)
        default:
            // a miss, a face tap in step 1, a wall tap in step 2: the step line again — nothing thrown away
            s.say = stepLine(s, walls: walls)
            return (s, .none)
        }
    }

    /// The picked wall changed under him (a box edit): back to step 1, said once.
    public static func revalidated(_ s0: FlexibleAttachState, walls: FlexibleLatticeWalls.Result?) -> FlexibleAttachState {
        guard case let .pickTarget(k) = s0.step else { return s0 }
        if let w = walls?.wall(k), w.tappable { return s0 }
        var s = s0
        s.step = .pickWall
        s.say = FlexibleSelectionsCopy.attachChanged(walls?.wall(k)?.name ?? "The wall")
        return s
    }

    /// The wall under a screen point: inside one of its projected quads; the nearest to the camera wins (`depth`: smaller is
    /// nearer). Only walls that draw a lattice side are hit.
    public static func wallUnder(_ p: CGPoint, walls: [FlexibleLatticeWalls.Wall], project: (SIMD3<Double>) -> CGPoint?,
                                 depth: (SIMD3<Double>) -> Double?) -> String? {
        var best: (String, Double)?
        for w in walls {
            for q in w.quads {
                let pts = q.compactMap(project)
                guard pts.count == q.count, inside(p, pts) else { continue }
                let c = q.reduce(SIMD3<Double>.zero, +) / Double(q.count)
                let d = depth(c) ?? .infinity
                if best == nil || d < best!.1 { best = (w.key, d) }
            }
        }
        return best?.0
    }

    /// Point in a screen polygon (even–odd).
    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var c = false
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
        }
        return c
    }

    /// The walls' names as drawn: their own ("Side N" from the outline — never the camera). RED CONTROL: numbered by screen x.
    public static func names(_ r: FlexibleLatticeWalls.Result, screen: (SIMD3<Double>) -> CGPoint?) -> [String: String] {
        var out: [String: String] = [:]
        guard controlNamesByScreenOrder else { for w in r.walls { out[w.key] = w.name }; return out }
        let sides = r.walls.filter { $0.kind == .side }
            .map { w -> (String, CGFloat) in (w.key, w.centre.flatMap(screen)?.x ?? .infinity) }
            .sorted { $0.1 < $1.1 }
        for (i, s) in sides.enumerated() { out[s.0] = "Side \(i + 1)" }
        for w in r.walls where w.kind != .side { out[w.key] = w.name }
        return out
    }

    // MARK: - a link's state

    /// A link as Selections lists it.
    public enum LinkState: Equatable, Sendable {
        case live
        /// Greyed, with its reason (" · no solid there now" …); never removed by itself.
        case stale(String)
        /// Its group was deleted: listed nowhere, ignored; an Undo of the delete brings it back.
        case dormant
    }

    /// The selectable ref a lattice key names ("f:<group>:<face>", "r:<group>:<region>").
    public static func ref(_ key: String) -> LatticeSelectableRef? {
        let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let g = UUID(uuidString: parts[1]), let n = Int(parts[2]) else { return nil }
        switch parts[0] {
        case "f": return .face(group: g, face: FaceID(n))
        case "r": return .region(group: g, region: RegionID(n))
        default: return nil
        }
    }

    public static func group(of ref: LatticeSelectableRef) -> UUID? {
        switch ref {
        case let .face(g, _), let .region(g, _): return g
        case .primitive: return nil
        }
    }

    /// A link's state: `groupExists` (its key's group is still there), `latticeOn` (its face still Lattice), `walls` (now).
    public static func state(_ l: FlexibleLatticeLink, groupExists: Bool, latticeOn: Bool,
                             walls: FlexibleLatticeWalls.Result?) -> LinkState {
        guard groupExists else { return .dormant }
        guard latticeOn else { return .stale(FlexibleSelectionsCopy.staleOff) }
        if l.wall == "floor" {
            guard let f = walls?.floor, f.status == .target, f.target == l.target else { return .stale(FlexibleSelectionsCopy.staleThrough) }
            return .live
        }
        guard let w = walls?.wall(l.wall), w.status != .gone else { return .stale(FlexibleSelectionsCopy.staleGone) }
        guard w.status == .target, w.target == l.target else { return .stale(FlexibleSelectionsCopy.staleNoSolid) }
        return .live
    }

    /// A link's state in `p` (`walls`: the lattice's walls now, by key) — the one rule Selections and the sim (I3) both read:
    /// dormant when its key's group is gone or the face left it, stale with its reason, else live.
    @MainActor
    public static func linkState(_ p: ProjectModel, _ l: FlexibleLatticeLink,
                                 walls: (String) -> FlexibleLatticeWalls.Result?) -> LinkState {
        guard let ref = ref(l.lattice), let g = group(of: ref),
              let grp = p.selection.groups.first(where: { $0.id == g }), p.latticeSelectableRefs(grp).contains(ref) else { return .dormant }
        let on = p.latticeSelectableRole(ref, in: g) == .include
        return state(l, groupExists: true, latticeOn: on, walls: on ? walls(l.lattice) : nil)
    }

    /// A link's row: "Side 2 → wall", with its stale reason after it.
    public static func rowText(_ l: FlexibleLatticeLink, wallName: String, state: LinkState) -> String {
        let base = FlexibleSelectionsCopy.linkRow(wallName, FlexibleLatticeWalls.targetName(l.target))
        if case let .stale(why) = state { return base + why }
        return base
    }
}

// MARK: - the words (his rule: one line per setting, ≤ 44 characters, plain words — no "anvil", "BC", "node")

extension FlexibleSelectionsCopy {
    public static let attach = "Attach"
    public static let attachVoice = "Attach this lattice to a solid wall"
    public static let notAttached = "Not attached"
    public static func linkedCount(_ n: Int) -> String { "\(n) linked" }
    public static let nothingTouches = "Nothing solid touches it"
    public static let curvedAttach = "Curved lattice · Attach not yet"
    /// "Attach to the 4 walls around it" / "Attach to the 2 other walls around it" / "… the other wall around it".
    public static func suggest(_ n: Int, other: Bool) -> String {
        if n == 1 { return other ? "Attach to the other wall around it" : "Attach to the wall around it" }
        return other ? "Attach to the \(n) other walls around it" : "Attach to the \(n) walls around it"
    }
    public static func linkedWalls(_ n: Int) -> String { n == 1 ? "Linked 1 wall" : "Linked \(n) walls" }
    public static func attachTitle(_ face: String) -> String { "Attach · \(face)" }
    public static let attachStep1 = "1 of 2 · Tap a wall of the lattice"
    public static func attachStep2(_ wall: String) -> String { "2 of 2 · Tap what \(wall) connects to" }
    public static func attachLinked(_ wall: String, _ target: String) -> String { "Linked \(wall) → \(target)" }
    public static func attachOpen(_ wall: String) -> String { "\(wall) is open to the outside" }
    public static func attachSeam(_ wall: String) -> String { "\(wall) runs into another lattice" }
    public static func attachThin(_ wall: String) -> String { "\(wall)'s solid is thinner than a bead" }
    public static func attachGone(_ wall: String) -> String { "\(wall) is gone at this expand" }
    public static func attachNotTouching(_ face: Int, _ wall: String) -> String { "Face \(face) doesn't touch \(wall)" }
    public static func attachOutside(_ face: Int) -> String { "Face \(face) is the part's outside" }
    public static func attachAlready(_ wall: String, _ target: String) -> String { "\(wall) → \(target) is linked already" }
    public static func attachChanged(_ wall: String) -> String { "\(wall) changed · tap a wall again" }
    public static let done = "Done"
    public static let back = "Back"
    public static func linkRow(_ wall: String, _ target: String) -> String { "\(wall) → \(target)" }
    public static let staleNoSolid = " · no solid there now"
    public static let staleThrough = " · runs through now"
    public static let staleGone = " · side gone"
    public static let staleOff = " · lattice off"
    public static let removeLinkAsk = "Remove this link?"
    public static let removeLink = "Remove"
    public static func removeLinkVoice(_ wall: String, _ target: String) -> String { "Remove link \(wall) to \(target)" }

    /// Every Attach string with its worst case filled in (Side 12, Face 123, a 16-character name) — `testCopyFits`.
    public static var attachWorstCases: [String] {
        let w = "Side 12", f = 123, name = "Face 123"
        return [attach, notAttached, linkedCount(12), nothingTouches, curvedAttach, suggest(12, other: false), suggest(12, other: true),
                suggest(1, other: true), linkedWalls(12), attachTitle(name), attachStep1, attachStep2(w), attachLinked(w, "solid under it"),
                attachOpen(w), attachSeam(w), attachThin(w), attachGone(w), attachNotTouching(f, w), attachOutside(f),
                attachAlready(w, "wall"), attachChanged(w), done, back, cancel,
                linkRow(w, "Face 123 skin"), linkRow("Floor", "solid under it") + staleThrough, linkRow(w, "wall") + staleNoSolid,
                linkRow(w, "wall") + staleGone, linkRow(w, "wall") + staleOff, removeLinkAsk, removeLink, attachVoice]
    }

    /// What is drawn, counted as drawn: `→` and `·` one character each (Swift's Character count).
    public static func fits(_ s: String) -> Bool { s.count <= 44 }
}
