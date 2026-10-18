// FlexibleFaceChipLayout — where the face chip sits, and how a drag moves it (task 2026-09-29-flexible-screens, round 7,
// batch R7-D2; his change (a) to B1, 2026-10-14: "I want to be able to move the modals around for each face by dragging" —
// the chip is draggable and its leader line follows). PURE, so FlexibleFaceChipTests measures it at 13" and 11".
//
//   * AUTO: above the face's projected centre (56 pt gap), else below, right, left, else docked top-centre under the top
//     chrome — the first spot clear of every keep-out, 16 pt inside the screen;
//   * KEEP-OUTS: the Selections list, the capsule and the name row, the gizmo + the views row + the legend card, the corner
//     pair and its open panel, the squish player, and the picked face's own handles and numbers;
//   * DRAGGED: the chip's spot is kept FOR THAT FACE (keyed by the pick's scope) for the session — an orbit or a pan moves
//     only its leader; clamped 16 pt inside; let go over a keep-out, it slides to the nearest clear spot;
//   * the LEADER runs from the chip's nearest edge to the face's projected centre (a 6 pt dot), re-aimed every frame.

import CoreGraphics
import Combine
import Foundation
import TopOptDesign

public enum FlexibleFaceChipLayout {
    public static let width: CGFloat = 404
    public static let gap: CGFloat = 56
    public static let inset: CGFloat = 16
    public static let padding: CGFloat = 12
    public static let radius: CGFloat = 20
    /// A keep-out is inflated by this much (the chip never kisses a panel).
    public static let clearance: CGFloat = 8

    /// The chip's kinds (the plan's N / M / G / B / L) — their drawn heights, for placement before the first measure.
    public enum Kind: Equatable, Sendable { case new(join: Bool, held: Bool), member, group, blocked, locked }

    public static func size(_ k: Kind) -> CGSize {
        switch k {
        case let .new(join, held): return CGSize(width: width, height: 44 + 64 + (join ? 48 + 8 + 24 : 0) + (held ? 22 : 0) + 2 * padding + 8)
        // ★ the review of R7-D2: 132 as drawn (the grip's 12 was missing — the chip sat 12 pt lower than placed, onto the face's
        // outline and onto the (i)'s card); the layer also takes the chip's measured height when it grows (the role line, a confirm)
        case .member, .group, .blocked, .locked: return CGSize(width: width, height: 44 + 44 + 2 * padding + 8 + 12)
        }
    }

    /// The open Selections list's whole column (under the capsule, to the bottom) — kept clear while the list is open.
    public static func selectionsColumn(viewport v: CGSize) -> CGRect {
        let top = FlexibleChromeLayout.capsuleTop + FlexibleChromeLayout.capsuleHeight
        return CGRect(x: 0, y: top, width: PageChrome.edge + PageChrome.panelWidth, height: max(0, v.height - top))
    }

    /// ★ ROUND 7, R7-D3: the open list's whole REACH — it grows about its centre (PageLeftModal centres it) up to its header and
    /// 420 pt of lines, never above 2 × noteTop — from ANY measure of it (its centre does not move as a group opens). The chip's
    /// second tier (the mini in portrait): a measure taken before Group C opened under a pick is stale for a frame (the list
    /// notes its frame asynchronously) — its reach never is.
    public static func listReach(measured m: CGRect, viewport v: CGSize) -> CGRect {
        let maxH = FlexibleSelectionsList.maxDrawnHeight
        let top = min(m.minY, max(FlexibleMainViewToggles.leftPanelHighestTop, m.midY - maxH / 2))
        let bottom = max(m.maxY, min(v.height - PageChrome.edge, max(m.midY + maxH / 2, top + maxH)))
        return CGRect(x: 0, y: top, width: PageChrome.edge + PageChrome.panelWidth, height: max(0, bottom - top))
    }

    /// The top-centre dock: under the name row and the capsule.
    public static func dockTop(_ v: CGSize) -> CGFloat { FlexibleChromeLayout.capsuleTop + FlexibleChromeLayout.capsuleHeight + PageChrome.gap }

    /// The fixed keep-outs of the main page at viewport `v`, plus what is measured (the list, the legend, an open panel, the
    /// player) and the picked face's own handles.
    public static func keepOuts(viewport v: CGSize, selections: CGRect?, legend: CGRect?, panel: CGRect?, player: CGRect?,
                                setupWidth: CGFloat = FlexibleChromeLayout.setupMaxWidth, own: [CGRect] = []) -> [CGRect] {
        let pair = FlexibleChromeLayout.pair(viewport: v, setupWidth: setupWidth)
        var k: [CGRect] = [
            FlexibleChromeLayout.topLeftChrome(v).intersection(CGRect(x: 0, y: 0, width: FlexibleChromeLayout.capsuleLeft + FlexibleChromeLayout.capsuleMaxWidth + PageChrome.gap,
                                                                      height: FlexibleChromeLayout.capsuleTop + FlexibleChromeLayout.capsuleHeight)),
            FlexibleLegendPlacement.gizmoFrame(viewport: v),
            // ★ LOOKED AT (11" landscape: the chip sat on the "Lattice ready" note beside the views row): the row AND its note
            FlexibleMainViewToggles.frame(viewport: v),
            pair.setup, pair.lattice,
        ]
        for r in [selections, legend, panel, player] { if let r, r.width > 0, r.height > 0 { k.append(r) } }
        k += own
        return k
    }

    /// ★ REVIEW OF R7-D2: the picked face's own outline on screen as a keep-out for the AUTOMATIC spot (13"/11" portrait:
    /// chip M sat on Face 3's own lattice) — unless the face fills so much of the screen (≥ 45 %) that nothing would be clear.
    public static let faceKeepOutMaxShare: CGFloat = 0.45
    public static func faceKeepOut(_ bounds: CGRect?, viewport v: CGSize) -> CGRect? {
        guard let b = bounds?.intersection(CGRect(origin: .zero, size: v)), !b.isNull, b.width > 0, b.height > 0,
              b.width * b.height < faceKeepOutMaxShare * v.width * v.height else { return nil }
        return b
    }

    static func hits(_ r: CGRect, _ keepOut: [CGRect]) -> Bool {
        keepOut.contains { $0.insetBy(dx: -clearance, dy: -clearance).intersects(r) }
    }

    static func inside(_ r: CGRect, _ v: CGSize) -> Bool {
        r.minX >= inset - 0.5 && r.minY >= inset - 0.5 && r.maxX <= v.width - inset + 0.5 && r.maxY <= v.height - inset + 0.5
    }

    /// The chip kept 16 pt inside the screen.
    public static func clamped(_ r: CGRect, viewport v: CGSize) -> CGRect {
        let x = min(max(r.minX, inset), max(inset, v.width - inset - r.width))
        let y = min(max(r.minY, inset), max(inset, v.height - inset - r.height))
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// The automatic spot for a chip of `size` about `anchor` (the face's projected centre; nil off screen: docked).
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect]) -> CGRect {
        if let a = anchor {
            let cands = [CGPoint(x: a.x - s.width / 2, y: a.y - gap - s.height),   // above
                         CGPoint(x: a.x - s.width / 2, y: a.y + gap),              // below
                         CGPoint(x: a.x + gap, y: a.y - s.height / 2),             // right
                         CGPoint(x: a.x - gap - s.width, y: a.y - s.height / 2)]   // left
            for c in cands {
                // slid sideways along the screen to stay inside — never vertically (that is the next candidate's job)
                let x = min(max(c.x, inset), max(inset, v.width - inset - s.width))
                let r = CGRect(x: x, y: c.y, width: s.width, height: s.height)
                if inside(r, v), !hits(r, keepOut) { return r }
                // ★ the review of R7-D2 (img2's front camera: the open list's column blocked "above", so the chip went below,
                // onto the pad's front): slid sideways past what it hits, on the same side, before the next side
                for k in keepOut where k.insetBy(dx: -clearance, dy: -clearance).intersects(r) {
                    for sx in [k.maxX + clearance, k.minX - clearance - s.width] {
                        let r2 = CGRect(x: sx, y: c.y, width: s.width, height: s.height)
                        if inside(r2, v), !hits(r2, keepOut) { return r2 }
                    }
                }
            }
        }
        // none of the four: the nearest clear spot to "above" (the same search a let-go uses), when there is one
        if let a = anchor {
            let first = clamped(CGRect(x: a.x - s.width / 2, y: a.y - gap - s.height, width: s.width, height: s.height), viewport: v)
            let near = released(first, viewport: v, keepOut: keepOut)
            if !hits(near, keepOut) { return near }
        }
        // docked top-centre under the top chrome, then along that row
        let top = dockTop(v)
        let centre = CGRect(x: (v.width - s.width) / 2, y: top, width: s.width, height: s.height)
        if inside(centre, v), !hits(centre, keepOut) { return centre }
        var x = inset
        while x + s.width <= v.width - inset {
            let r = CGRect(x: x, y: top, width: s.width, height: s.height)
            if !hits(r, keepOut) { return r }
            x += 12
        }
        return clamped(centre, viewport: v)
    }

    /// ★ the review of R7-D2: the automatic spot with a SOFT keep-out — the face it edits: kept off it when a spot clear of
    /// everything exists; else placed as if the face were not there (the chrome's keep-outs always win — at 11" portrait no
    /// spot was clear of Face 3 AND the chrome, and the dock put the chip on the cube and the views row).
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect], soft: CGRect?) -> CGRect {
        if let soft {
            let all = keepOut + [soft]
            let r = auto(size: s, anchor: anchor, viewport: v, keepOut: all)
            if inside(r, v), !hits(r, all) { return r }
        }
        return auto(size: s, anchor: anchor, viewport: v, keepOut: keepOut)
    }

    /// ★ ROUND 7, R7-D3 (found by the integration test, the mini in portrait — 744 pt wide): the 404 pt chip never fits beside
    /// the open list's 372 pt column, so NOTHING was clear — the automatic spot fell back onto the views row and the cube, and a
    /// chip let go on the corner pair stayed on it. The whole column stays the first wish; where nothing is clear of it,
    /// `fallback` (the same keep-outs with the list AS DRAWN) decides — above or below the list, never on it.
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect], fallback: [CGRect]?, soft: CGRect? = nil) -> CGRect {
        auto(size: s, anchor: anchor, viewport: v, tiers: [keepOut] + (fallback.map { [$0] } ?? []), soft: soft)
    }
    /// ★ R7-D3: the keep-outs in TIERS, the first wish first — the first tier with a clear spot decides; none clear: the first
    /// tier's own answer (today's). The layer's tiers: the list's whole column + the face's own handles → the list's whole
    /// reach + its handles → the reach alone (on the mini in portrait the picked face's handles took the one free band below
    /// the list: the chip may cover its own handles, never the page's chrome) → the list as drawn (the mini's 229 pt new-face
    /// chip fits neither above nor below the reach).
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, tiers: [[CGRect]], soft: CGRect? = nil) -> CGRect {
        var first: CGRect?
        for k in tiers {
            let r = auto(size: s, anchor: anchor, viewport: v, keepOut: k, soft: soft)
            if inside(r, v), !hits(r, k) { return r }
            if first == nil { first = r }
        }
        return first ?? clamped(CGRect(origin: .zero, size: s), viewport: v)
    }
    /// ★ R7-D3: a let-go with the same fallback (on the mini in portrait it stayed on the pair).
    public static func released(_ r: CGRect, viewport v: CGSize, keepOut: [CGRect], fallback: [CGRect]?) -> CGRect {
        released(r, viewport: v, tiers: [keepOut] + (fallback.map { [$0] } ?? []))
    }
    /// ★ R7-D3: a let-go over the same tiers.
    public static func released(_ r: CGRect, viewport v: CGSize, tiers: [[CGRect]]) -> CGRect {
        var first: CGRect?
        for k in tiers {
            let a = released(r, viewport: v, keepOut: k)
            if !hits(a, k) { return a }
            if first == nil { first = a }
        }
        return first ?? clamped(r, viewport: v)
    }

    /// Where a chip that started at `anchor` is while a finger has moved it by `translation` (clamped 16 pt inside).
    public static func dragged(anchor: CGPoint, translation t: CGSize, size: CGSize, viewport v: CGSize) -> CGRect {
        clamped(CGRect(x: anchor.x + t.width, y: anchor.y + t.height, width: size.width, height: size.height), viewport: v)
    }

    /// A dragged chip let go at `r`: clamped inside; over a keep-out, the nearest clear spot (a spiral search outward).
    public static func released(_ r: CGRect, viewport v: CGSize, keepOut: [CGRect]) -> CGRect {
        let c = clamped(r, viewport: v)
        guard hits(c, keepOut) else { return c }
        var best: CGRect?
        var bestD = CGFloat.infinity
        let step: CGFloat = 8
        var ring: CGFloat = step
        while ring < max(v.width, v.height) {
            let n = max(8, Int(ring * 2 * .pi / step))
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                let cand = clamped(c.offsetBy(dx: cos(t) * ring, dy: sin(t) * ring), viewport: v)
                guard !hits(cand, keepOut) else { continue }
                let d = hypot(cand.midX - c.midX, cand.midY - c.midY)
                if d < bestD { bestD = d; best = cand }
            }
            if best != nil { return best! }
            ring += step
        }
        return c
    }

    /// Where the leader leaves the chip: the point of its edge nearest the face (its corner pulled in 20 pt).
    public static func leaderStart(chip r: CGRect, target t: CGPoint) -> CGPoint {
        let x = min(max(t.x, r.minX + radius), r.maxX - radius)
        let y = min(max(t.y, r.minY + radius), r.maxY - radius)
        if t.y < r.minY { return CGPoint(x: x, y: r.minY) }
        if t.y > r.maxY { return CGPoint(x: x, y: r.maxY) }
        return CGPoint(x: t.x < r.midX ? r.minX : r.maxX, y: y)
    }
}

/// ★ The face chip's live state — its OWN object, so a drag (every frame) never re-runs the workspace's body: the moved
/// spots (per face, for the session), the keypad slot, the (i), the rename, the role line, the confirms and the toast.
@MainActor
public final class FlexibleFaceChipState: ObservableObject {
    /// A chip he dragged: its top-left, per the pick's scope key, for the session.
    @Published public var spots: [String: CGPoint] = [:]
    /// The one keypad slot of the main page's boxes (the chip's, the handles' and the list's).
    @Published public var padTarget: String?
    /// The (i) open: the ref's key and the global frame of the button it opened from.
    @Published public var info: Info?
    @Published public var renaming: UUID?
    @Published public var renameDraft = ""
    /// The role line open on chip M.
    @Published public var roleOpen: UUID?
    /// "Delete Group C here and in Topology?" waiting for [Delete] / [Cancel].
    @Published public var deleteAsk: UUID?
    /// …asked from the chip's trash (else the list's) — the confirm shows where the trash was tapped, once.
    @Published public var deleteAskInChip = false
    /// "Keep clear removes this lattice" waiting for [Keep clear] / [Cancel].
    @Published public var keepClearAsk: UUID?
    /// The one message (with [Undo] after a delete).
    @Published public var toast: Toast?
    /// A handle being dragged (its key), and what the drag remembers.
    @Published public var dragging: String?
    /// What the last delete took (the message's [Undo] puts it back).
    var deleted: FlexibleFaceCommits.Deleted?
    /// ★ the review of R7-D2: a Load the chip made this session → the weight it was made with (the force's default) — it reads
    /// "weight: Squish page" until its weight changes (set on the Squish page).
    @Published public var unweighed: [UUID: Double] = [:]
    var xrayBeforeDrag: Bool?
    var held: LatticeDepthDetent.Candidate?
    var seed: Double?

    public struct Info: Equatable, Sendable {
        public let key: String
        public let group: UUID
        public let ref: LatticeSelectableRef
        public let anchor: CGRect
    }

    public struct Toast: Equatable, Sendable {
        public let text: String
        public let undo: Bool
        public let serial: Int
    }
    private var toastSerial = 0
    /// How long a message stays (tests shorten it).
    var toastSeconds: Double = 8

    public init() {}

    func say(_ text: String, undo: Bool = false) {
        toastSerial += 1
        let t = Toast(text: text, undo: undo, serial: toastSerial)
        toast = t
        let s = toastSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }

    /// A new pick (or none): the transient lines close; the moved spots stay.
    func closeTransient() {
        if info != nil { info = nil }
        if roleOpen != nil { roleOpen = nil }
        if renaming != nil { renaming = nil }
        if deleteAsk != nil { deleteAsk = nil }
        if keepClearAsk != nil { keepClearAsk = nil }
    }
}
