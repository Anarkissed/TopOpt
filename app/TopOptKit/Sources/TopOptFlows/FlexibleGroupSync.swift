// FlexibleGroupSync — ONE SET OF GROUPS (task 2026-09-29-flexible-screens, round 6 item 4; his img4: "All set groups
// should be visible on the main Flexibles screen. Also, any groups already created should already be set in the
// flexible settings when the user starts up. These two boxes should be synced"; his answer: "Yes, one set of groups").
// TESTS FIRST: the API only — the implementation follows in the next commit.

import Foundation
import simd
import TopOptKit

/// A main-page group with no role yet ("Pending…" on the main page), listed on Settings' Pending tab.
public struct FlexiblePendingGroup: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// The Flexible regions it holds.
    public let regions: [Int]
    public init(id: UUID, name: String, regions: [Int]) { self.id = id; self.name = name; self.regions = regions }
}

/// [Press it] on a face a main-page Anchor holds: asked once — "Face 0 rests (main page: Bottom)".
public struct FlexibleRestsAsk: Equatable, Sendable {
    public let region: Int
    public let anchorName: String
    public let faceName: String
    public let kg: Double?
    public let into: Int?
    public var line: String { FlexibleRowCopy.restsAsk(face: faceName, anchor: anchorName) }
}

/// The links' red controls (tests only).
enum FlexibleGroupLinks {
    /// RED CONTROL: a new main-page Load group joins squeeze group 1 (round 3's adopt).
    nonisolated(unsafe) static var controlOneSqueezeTag = false
    /// RED CONTROL: `designInputs` keeps `weightFrom` (a link alone re-keys the lattice).
    nonisolated(unsafe) static var controlKeepWeightFrom = false
    /// RED CONTROL: the trash leaves the face in its main-page group (round 5 S6's rule).
    nonisolated(unsafe) static var controlKeepMainGroup = false
}

extension FlexibleRowCopy {
    /// "Face 0 rests (main page: Bottom)".
    public static func restsAsk(face: String, anchor: String) -> String { "\(face) rests (main page: \(fit(anchor, 16)))" }
}

extension FlexibleStageModel {
    /// The main page's Pending groups.
    public var pendingGroups: [FlexiblePendingGroup] { [] }
    /// [Squeeze it] on a Pending group.
    public func squeezePending(_ id: UUID, kg: Double) {}
    /// [It rests] on a Pending group.
    public func restPending(_ id: UUID) {}
    /// [Squeeze it] on the anchored face's ask.
    @discardableResult
    public func squeezeAnchored() -> Bool { false }
    /// [Keep it resting].
    public func keepResting() { restsAsk = nil }
    /// A squeeze group's tab title.
    public func railTitle(_ g: FlexibleSqueezeGroup) -> String { FlexibleRowCopy.groupName(g.number) }
    /// The anchor group a resting face rests with (its row names it).
    public func restsGroupName(_ region: Int) -> String? { nil }
}
