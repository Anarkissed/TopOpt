// FlexibleSquishFollowUps — round 7 batch F, the Squish page's follow-ups from his 2026-10-14 answers (task
// 2026-09-29-flexible-screens). STUBS (today's behaviour) for the tests-first red run.

import Foundation
import simd
import TopOptKit

/// (1) The two trash glyphs.
enum FlexibleTrashGlyphs {
    static let group = "trash"
    static let groupSize: CGFloat = 14
    static let face = "trash"
    static let faceSize: CGFloat = 14
}

extension FlexibleRowCopy {
    static func deleteGroupAsk(_ name: String) -> String { "" }
    static let deleteGroupConfirm = ""
    static let deleteGroupKeep = ""
}

extension FlexibleStageModel {
    /// ★ RED CONTROL: today's trash — the group goes at once.
    @MainActor static var controlTrashDeletesAtOnce = false

    public func askDeleteGroup(_ groupID: Int) { removeGroup(groupID) }
    public func confirmDeleteGroup() {}
    public func keepGroup() {}

    /// (2) Nothing set to squish.
    public var isEmptySetup: Bool { false }
    /// ★ RED CONTROL: R7-V's opening look.
    @MainActor static var controlHeatOnByDefault = false
}

extension FlexibleSettingsExit {
    @MainActor static var controlEmptyBlocks = false
    public static let emptyLine = ""
    public static func title(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> String { title(r, modified: modified) }
    public static func decide(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> FlexibleExitDecision { decide(r, modified: modified) }
    public static func topLine(_ r: FlexibleReadiness, modified: Bool, empty: Bool) -> String { readyLine(r.oneLine, modified: modified) }
}

extension FlexibleFaceGroupRow {
    @MainActor static var controlChipsByNumber = false
}

extension FlexibleStageViews {
    nonisolated(unsafe) static var controlBendWithPlay = false
    /// (4) A view button's toggle.
    public mutating func toggle(_ v: FlexibleStageViews) {
        if contains(v) { remove(v) } else { insert(v) }
    }
}

extension FlexibleStagePage {
    @MainActor static var controlBendRestPose = false
    static func posesOverlays(views: FlexibleStageViews) -> Bool { false }
    @MainActor static func bendPose(views: FlexibleStageViews, overlay: FlexibleOverlayMesh?, dents: [Float]?, k: Double) -> FlexibleBendPose? { nil }
}

/// (4) The full-bend pose.
struct FlexibleBendPose {
    init?(positions: [Float], dents: [Float], k: Double) { return nil }
    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> { p }
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { p }
    func pose(_ item: ClearanceRenderItem) -> ClearanceRenderItem { item }
}

extension FlexibleMainStage {
    @MainActor static var controlPlayAllDefault = false
    /// (6) The sim the main page shows for its heat.
    static func heatSim(sims: [FlexibleSim], tappedGroup: Int?, all: Bool) -> String? { nil }
    func heatHeld() {}
    func noteMainTap(face: Int, point: SIMD3<Float>?) {}
    var tappedGroupNumber: Int? { nil }
}

extension FlexibleMainPlayerSlot {
    static func pickerSims(_ sims: [FlexibleSim]) -> [FlexibleSim] { sims }
}
