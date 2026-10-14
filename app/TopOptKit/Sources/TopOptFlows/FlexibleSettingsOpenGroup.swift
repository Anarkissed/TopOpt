// FlexibleSettingsOpenGroup — the Settings page's OPEN GROUP is the master (task 2026-09-29-flexible-screens, round 7
// batch S; his img4 words of 2026-10-14: "After creating the first group, and in particular adding a corner
// modification, automatically brings me back to Group 1. It does this after every change I make, please make it stay on
// the same group and never shift." and "What is this 3mm? I don't see anything listed in the group with that number? I
// should only be able to view numbers associated to what I'm working on.").
//
// RED STUBS (tests first): today's rules, so FlexibleR7SettingsTests fail for their stated reasons.

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// ★ The panel's onAppear rule (both panels): the face selected when the page shows with nothing selected.
    @MainActor
    static func appearSelection(_ m: FlexibleStageModel) -> Int? {
        m.settings.loadedFaces.first?.faceRegionID
    }
}

extension FlexibleStageOverlays {

    /// ★ The face whose numbers the page draws (the depth chip, the curve editors, the stamp handle, the Prisms tags).
    @MainActor
    static func workingRegion(model m: FlexibleStageModel) -> Int? {
        m.selectedRegion
    }
}

extension FlexibleStagePage {

    /// ★ The face the fix pop-up selects as it opens on `issue` (nil: it names and pulses the face, selecting nothing).
    @MainActor
    static func presentSelection(_ issue: FlexibleIssue, model m: FlexibleStageModel) -> Int? {
        issue.region
    }
}

extension FlexibleStageModel {
    /// ★ RED CONTROL (FlexibleR7SettingsTests): today's rule — the tab follows the SELECTED FACE after every edit.
    @MainActor static var controlRailFollowsSelection = false
    /// ★ RED CONTROL: today's Reset all — the main page's loads read in again, the strips left cut.
    @MainActor static var controlResetAdopts = false

    /// ★ 4h: [+ New] with nothing pressed — a tap on a face starts Group 1 (`kg`: the keypad's answer). false: not started.
    @discardableResult
    public func startFirstGroup(_ region: Int, kg: Double?) -> Bool { false }
}

extension FlexibleStageOverlays {
    /// ★ RED CONTROL: today's gate — the selected face's numbers whatever tab is open (his img4).
    @MainActor static var controlGateOnSelectionOnly = false
}

extension FlexibleStageOverlays {

    /// ★ The face the overlays draw on (its curves, its depth chip, its stamp handle): the working region, on the Face
    /// tab, out of pick mode, a pressed face with its map. nil: nothing is drawn on a face.
    struct WorkingFace { let region: Int; let geometry: FlexFaceGeometry; let face: FlexibleFaceSettings }

    @MainActor
    static func workingFace(model m: FlexibleStageModel) -> WorkingFace? {
        guard m.edgePick == nil, m.tab == .face, let r = workingRegion(model: m), let k = m.key(r),
              let g = m.geometry[k], let f = m.settings.face(r), f.isLoaded else { return nil }
        return WorkingFace(region: r, geometry: g, face: f)
    }

    /// The curve editors drawn (the face and its axes); nil: none (no working face, or a Stamp face).
    @MainActor
    static func curveEditors(model m: FlexibleStageModel) -> (region: Int, axes: [String])? {
        guard let w = workingFace(model: m) else { return nil }
        let axes = curveAxes(w.face)
        return axes.isEmpty ? nil : (w.region, axes)
    }
}

extension FlexibleReadiness {
    /// ★ RED CONTROL (4f f): issue ids by REGION (today's) — a strip re-cut re-ids the rest and its issue looks new.
    nonisolated(unsafe) static var controlIssueIdByRegion = false
}
