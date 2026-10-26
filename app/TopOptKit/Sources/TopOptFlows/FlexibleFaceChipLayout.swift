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

/// ★ P2 (the redesign, point 5): the numbers and the rules are the shared FaceChipLayout's (#354's B2 lift of this file, the
/// same values and code); Flexible keeps its name, its signatures and its main page's own fixed keep-outs (`keepOuts`).
public enum FlexibleFaceChipLayout {
    public static let width: CGFloat = FaceChipLayout.width
    public static let gap: CGFloat = FaceChipLayout.gap
    public static let inset: CGFloat = FaceChipLayout.inset
    public static let padding: CGFloat = FaceChipLayout.padding
    public static let radius: CGFloat = FaceChipLayout.radius
    /// A keep-out is inflated by this much (the chip never kisses a panel).
    public static let clearance: CGFloat = FaceChipLayout.clearance

    /// The chip's kinds (the plan's N / M / G / B / L, ★ U21 batch I (I2): chip M with its Attach rows, the Attach step card)
    /// — their drawn heights, for placement before the first measure.
    public typealias Kind = FaceChipLayout.Kind
    /// ★ I2: one Attach row (44 pt + the stack's spacing).
    public static let attachRow: CGFloat = FaceChipLayout.attachRow

    public static func size(_ k: Kind) -> CGSize { FaceChipLayout.size(k) }

    /// The open Selections list's whole column (under the capsule, to the bottom) — kept clear while the list is open.
    public static func selectionsColumn(viewport v: CGSize) -> CGRect { FaceChipLayout.selectionsColumn(viewport: v) }

    /// ★ ROUND 7, R7-D3: the open list's whole REACH — it grows about its centre (PageLeftModal centres it) up to its header and
    /// 420 pt of lines, never above 2 × noteTop — from ANY measure of it (its centre does not move as a group opens).
    public static func listReach(measured m: CGRect, viewport v: CGSize) -> CGRect { FaceChipLayout.listReach(measured: m, viewport: v) }

    /// The top-centre dock: under the name row and the capsule.
    public static func dockTop(_ v: CGSize) -> CGFloat { FaceChipLayout.dockTop(v) }

    /// The fixed keep-outs of the main page at viewport `v`, plus what is measured (the list, the legend, an open panel, the
    /// player) and the picked face's own handles.
    public static func keepOuts(viewport v: CGSize, selections: CGRect?, legend: CGRect?, panel: CGRect?, player: CGRect?,
                                setupWidth: CGFloat = FlexibleChromeLayout.setupMaxWidth, own: [CGRect] = []) -> [CGRect] {
        let pair = FlexibleChromeLayout.pair(viewport: v, setupWidth: setupWidth)
        let chrome: [CGRect] = [
            FlexibleChromeLayout.topLeftChrome(v).intersection(CGRect(x: 0, y: 0, width: FlexibleChromeLayout.capsuleLeft + FlexibleChromeLayout.capsuleMaxWidth + PageChrome.gap,
                                                                      height: FlexibleChromeLayout.capsuleTop + FlexibleChromeLayout.capsuleHeight)),
            FlexibleLegendPlacement.gizmoFrame(viewport: v),
            // ★ LOOKED AT (11" landscape: the chip sat on the "Lattice ready" note beside the views row): the row AND its note
            FlexibleMainViewToggles.frame(viewport: v),
            pair.setup, pair.lattice,
        ]
        return FaceChipLayout.keepOuts(chrome: chrome, selections: selections, legend: legend, panel: panel, player: player, own: own)
    }

    /// ★ REVIEW OF R7-D2: the picked face's own outline on screen as a keep-out for the AUTOMATIC spot — unless the face fills
    /// so much of the screen (≥ 45 %) that nothing would be clear.
    public static let faceKeepOutMaxShare: CGFloat = FaceChipLayout.faceKeepOutMaxShare
    public static func faceKeepOut(_ bounds: CGRect?, viewport v: CGSize) -> CGRect? { FaceChipLayout.faceKeepOut(bounds, viewport: v) }

    static func hits(_ r: CGRect, _ keepOut: [CGRect]) -> Bool { FaceChipLayout.hits(r, keepOut) }

    static func inside(_ r: CGRect, _ v: CGSize) -> Bool { FaceChipLayout.inside(r, v) }

    /// The chip kept 16 pt inside the screen.
    public static func clamped(_ r: CGRect, viewport v: CGSize) -> CGRect { FaceChipLayout.clamped(r, viewport: v) }

    /// The automatic spot for a chip of `size` about `anchor` (the face's projected centre; nil off screen: docked): above,
    /// below, right, left, the nearest clear spot to "above", else docked top-centre.
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect]) -> CGRect {
        FaceChipLayout.auto(size: s, anchor: anchor, viewport: v, keepOut: keepOut)
    }

    /// ★ the review of R7-D2: the automatic spot with a SOFT keep-out — the face it edits.
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect], soft: CGRect?) -> CGRect {
        FaceChipLayout.auto(size: s, anchor: anchor, viewport: v, keepOut: keepOut, soft: soft)
    }

    /// ★ ROUND 7, R7-D3: the whole column first; where nothing is clear of it, `fallback` (the list AS DRAWN) decides.
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect], fallback: [CGRect]?, soft: CGRect? = nil) -> CGRect {
        FaceChipLayout.auto(size: s, anchor: anchor, viewport: v, keepOut: keepOut, fallback: fallback, soft: soft)
    }
    /// ★ R7-D3: the keep-outs in TIERS, the first wish first.
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, tiers: [[CGRect]], soft: CGRect? = nil) -> CGRect {
        FaceChipLayout.auto(size: s, anchor: anchor, viewport: v, tiers: tiers, soft: soft)
    }
    /// ★ R7-D3: a let-go with the same fallback (on the mini in portrait it stayed on the pair).
    public static func released(_ r: CGRect, viewport v: CGSize, keepOut: [CGRect], fallback: [CGRect]?) -> CGRect {
        FaceChipLayout.released(r, viewport: v, keepOut: keepOut, fallback: fallback)
    }
    /// ★ R7-D3: a let-go over the same tiers.
    public static func released(_ r: CGRect, viewport v: CGSize, tiers: [[CGRect]]) -> CGRect {
        FaceChipLayout.released(r, viewport: v, tiers: tiers)
    }

    /// Where a chip that started at `anchor` is while a finger has moved it by `translation` (clamped 16 pt inside).
    public static func dragged(anchor: CGPoint, translation t: CGSize, size: CGSize, viewport v: CGSize) -> CGRect {
        FaceChipLayout.dragged(anchor: anchor, translation: t, size: size, viewport: v)
    }

    /// A dragged chip let go at `r`: clamped inside; over a keep-out, the nearest clear spot (a spiral search outward).
    public static func released(_ r: CGRect, viewport v: CGSize, keepOut: [CGRect]) -> CGRect {
        FaceChipLayout.released(r, viewport: v, keepOut: keepOut)
    }

    /// Where the leader leaves the chip: the point of its edge nearest the face (its corner pulled in 20 pt).
    public static func leaderStart(chip r: CGRect, target t: CGPoint) -> CGPoint { FaceChipLayout.leaderStart(chip: r, target: t) }
}

/// ★ The face chip's live state — its OWN object, so a drag (every frame) never re-runs the workspace's body: the moved
/// spots (per face, for the session), the keypad slot, the (i), the rename, the role line, the confirms and the toast.
/// (★ P2: still Flexible's own — the shared FaceChipState is final and has no `deleted`, the Flexible trash's undo.)
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
    @Published public var roleOpen: UUID? { didSet { if roleOpen != oldValue { protectLockSaid = nil } } }
    /// ★ R7-E1 (his answer 2026-10-18 ~15:50): [Protect] tapped on a Lattice group — the role line says why it stays on.
    @Published public var protectLockSaid: UUID?
    /// "Delete ‘Group C’ from every stage?" waiting for [Delete] / [Cancel].
    @Published public var deleteAsk: UUID?
    /// …asked from the chip's trash (else the list's) — the confirm shows where the trash was tapped, once.
    @Published public var deleteAskInChip = false
    /// "Keep clear removes this lattice" waiting for [Keep clear] / [Cancel].
    @Published public var keepClearAsk: UUID?
    /// ★ U21 batch I (I2): "Remove this link?" waiting for [Remove] / [Keep] (the link's id).
    @Published public var linkRemoveAsk: UUID?
    /// ★ I2: where the chip was last placed (Attach pins it there, so the step card does not jump) — never published.
    var lastChipOrigin: CGPoint?
    /// ★ I2: each wall tag's chosen spot (its candidate index), kept while it stays clear (no jitter in an orbit).
    var attachTagPick: [String: Int] = [:]
    /// ★ I2 (the red control `controlTagsPlacedOnce` only): each tag's first spot, never re-projected.
    var attachTagFrozen: [String: CGPoint] = [:]
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

    func say(_ text: String, undo: Bool = false, seconds: Double? = nil) {
        toastSerial += 1
        let t = Toast(text: text, undo: undo, serial: toastSerial)
        toast = t
        let s = seconds ?? toastSeconds
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
        if linkRemoveAsk != nil { linkRemoveAsk = nil }
    }
}
