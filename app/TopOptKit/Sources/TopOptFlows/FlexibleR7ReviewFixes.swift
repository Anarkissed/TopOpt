// FlexibleR7ReviewFixes — round 7, "the review of M2 and F" (task 2026-09-29-flexible-screens; the owed two-angle review of
// batches M2 and F, merged with X1 at a870cad4, and his three answers of 2026-10-15). Tests: FlexibleR7RTests and
// FlexibleR7RHostedTests (each with its RED control). App only; no #354, main or core file.
//   (1) His answer 7, clarified: "the weight is an EQUAL SHARE PER LATTICE PART (two parts = 5 lb each of 10 lb, whatever
//       their size), only on the latticed parts." M2 split only the Top (linked to the main page). A face with its OWN
//       weight was COPIED onto each of its lattice parts, so each face pressed twice as hard (Group 2: 10 lb per face
//       became 20). Now a face's own weight is shared equally between its parts, and the parts of one face are ONE hand of
//       its squeeze group (the group's force row says the face's weight, not a part's).
//   (2) F's Bend pose: its cache key sampled every 522nd dent on his pad — always a vertex's x, zero for a press along y
//       or z — so every group's bend had the SAME key, and the page kept the first pose of the session.
//   (3) His answer of 2026-10-15 (1): "With Bend on, the depth chip and depth labels MOVE with the bend (everything goes to
//       the full-bend pose)." A prism's floor, its depth chip and the Prisms view's floor tags follow the bend of their face.
//   (4) His answer of 2026-10-15 (3): after Reset all the MAIN page's line says "Nothing to squish yet" too (neutral, no
//       Fix); with nothing to heat the heat icon is not lit, on either page.
//   (5) The review's smaller findings: a stale "Delete Group N?" never outlives its group; a tap on a face's solid middle
//       picks its lattice parts' group; the violet legend row only while something is violet; the rail counts faces; the
//       pinch line names the face; the face card's named chips fit (under the words when not beside them); F's new
//       controls are 44 pt targets.

import Foundation
import simd
import SwiftUI
import TopOptKit

// MARK: - (1) an equal share per lattice part

/// ★ (1) A face's own weight over its lattice parts: an equal share each; the parts of one face are one hand.
enum FlexibleSectionShares {
    /// ★ RED CONTROL: M2's carry — a face's own weight COPIED onto each of its lattice parts, each part its own hand.
    nonisolated(unsafe) static var controlCopyWeight = false
}

extension FlexibleStageModel {
    /// The root a lattice part grows from (a face, or his own Surface sector); any other region is its own root.
    public func rootRegion(of r: Int) -> Int {
        guard FlexibleSectors.isFlexible(r), let p = regions.flexible?.piece(r), p.kind != .strip else { return r }
        return p.rootRegion
    }
    /// The hands of squeeze group `g` (a main-page Load group's faces; a face of his own — all its lattice parts).
    public func groupHands(_ g: FlexibleSqueezeGroup) -> [FlexibleSqueezeGroups.Hand] {
        FlexibleSqueezeGroups.hands(g, settings: settings, loads: mainPageLoads, liveKg: liveMainKg)
    }
}

// MARK: - (2) the Bend pose's key

extension FlexibleBendPose {
    /// ★ RED CONTROL: F's key — a strided sample of the dents (every count/256-th value).
    @MainActor static var controlSampledKey = false
    /// ★ RED CONTROL: F's rule (before his 2026-10-15 answer) — a prism's floor, its depth chip and the floor tags stay at rest.
    @MainActor static var controlInsideStays = false
}

extension FlexibleDepthChips {
    /// The working face's prism handle at the full bend (`pose` nil: at rest).
    @MainActor static func handle(model: FlexibleStageModel, k: Double, pose: FlexibleBendPose?) -> ClearanceHandle? {
        handle(model: model, k: k)
    }
}

extension FlexibleStageViewTags {
    /// The floors at the full bend (`pose` nil: at rest).
    @MainActor static func floors(model: FlexibleStageModel, k: Double, pose: FlexibleBendPose?) -> [Floor] {
        floors(model: model, k: k)
    }
}

// MARK: - (4) the empty setup on the main page

extension FlexibleMainStage {
    /// ★ RED CONTROL: today's main page after Reset all — the readiness's "press the face that carries weight" Fix.
    @MainActor static var controlEmptyMainFix = false
    /// Something to heat: a face-prism and a squeeze group.
    public var heatAvailable: Bool { viewsAvailable }
    /// The heat icon lit: his Heat on and something to heat.
    public var heatIconLit: Bool { heat && viewsAvailable }
    /// The "every group" mark on the heat icon (his 3 s hold), only while there is something to heat.
    public var heatAllBadgeShown: Bool { heat && heatAll }
}

// MARK: - (5) the smaller findings

extension FlexibleStageModel {
    /// ★ RED CONTROL: F's question kept its group id after the group left (a new group reusing the id was asked about).
    @MainActor static var controlAskOutlivesGroup = false
}

extension FlexibleMainStage {
    /// ★ RED CONTROL: F's main-page tap — a tap on a face's solid middle (its root, in no group) keeps the last group.
    @MainActor static var controlTapRootIgnored = false
}

extension FlexibleLegend {
    /// ★ RED CONTROL: M2's legend row — "Violet = lattice · tap to pick" whenever a face is cut into parts.
    @MainActor static var controlVioletRowAlways = false
}

extension FlexibleSettingsRailView {
    /// ★ RED CONTROL: M2's rail — every lattice part counted as a face.
    @MainActor static var controlRailCountsParts = false
}

extension FlexibleFacePanel {
    /// ★ RED CONTROL: the pinch line names the partner's lattice PART (cut to "Face 2 · lattic…").
    @MainActor static var controlPinchPartName = false
    /// The pinch line of a pressed face (nil: no pinch partner).
    @MainActor static func pinchLine(model: FlexibleStageModel, region r: Int) -> String? {
        guard let other = model.pinchPartners(r).first else { return nil }
        let oneProfile = model.key(r).map { model.segmentErrors[$0] != nil } ?? false
        let name = model.faceName(other)
        return oneProfile ? FlexibleRowCopy.pinchedOneProfile(with: name) : FlexibleRowCopy.pinched(with: name)
    }
}

extension FlexibleFaceGroupRow {
    /// ★ RED CONTROL: F's row — the chips only BESIDE the words, else one menu chip.
    @MainActor static var controlMenuFallback = false
}

/// ★ (5) His rule: 44 pt targets.
enum FlexibleTargets {
    /// ★ RED CONTROL: F's sizes (the take-out 32 × 32; Delete, Keep, Reset 32 tall; Reset all 30 tall).
    @MainActor static var controlSmall = false
}
