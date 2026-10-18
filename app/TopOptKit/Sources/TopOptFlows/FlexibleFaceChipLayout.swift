// FlexibleFaceChipLayout — STUB (round 7, batch R7-D2: tests first). The chip's live state is real (plain state).
import CoreGraphics
import Combine
import Foundation
import TopOptDesign

public enum FlexibleFaceChipLayout {
    public enum Kind: Equatable, Sendable { case new(join: Bool, held: Bool), member, group, blocked, locked }
    public static func size(_ k: Kind) -> CGSize { .zero }
    public static func keepOuts(viewport v: CGSize, selections: CGRect?, legend: CGRect?, panel: CGRect?, player: CGRect?,
                                setupWidth: CGFloat = 0, own: [CGRect] = []) -> [CGRect] { [] }
    public static func clamped(_ r: CGRect, viewport v: CGSize) -> CGRect { r }
    public static func auto(size s: CGSize, anchor: CGPoint?, viewport v: CGSize, keepOut: [CGRect]) -> CGRect { .zero }
    public static func released(_ r: CGRect, viewport v: CGSize, keepOut: [CGRect]) -> CGRect { r }
    public static func leaderStart(chip r: CGRect, target t: CGPoint) -> CGPoint { t }
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
    /// "Keep clear removes this lattice" waiting for [Keep clear] / [Cancel].
    @Published public var keepClearAsk: UUID?
    /// The one message (with [Undo] after a delete).
    @Published public var toast: Toast?
    /// A handle being dragged (its key), and what the drag remembers.
    @Published public var dragging: String?
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
