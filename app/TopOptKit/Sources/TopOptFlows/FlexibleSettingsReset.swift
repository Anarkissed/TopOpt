// FlexibleSettingsReset — "Reset all" and "Exit" vs "Save & Exit" on the Flexible Settings page
// (task 2026-09-29-flexible-screens, round 5 batch S5 and S9; his img 2 / img 3).
//
// ★ S5 — "Create a "reset all" button to reset all inputs and start anew." One button on the
// modal, a one-line confirm, one UNDOABLE edit. Afterwards the settings are EXACTLY a brand-new
// Flexible setup of this part (`freshSettings`): the default filament (the one with squish data —
// D-R5-S5's ruling; the app's own entry, WorkspacePlaceholder's `FlexibleStageSettings()`, has none
// on this branch, batch F's preselect is not here), feel and finish; the main page's Load and Anchor groups read again as
// pressed / resting faces at their weights, every face at its defaults; one squeeze group; nothing
// deleted. The weight UNIT is kept — it is how he reads weights, not an input of the part.
// ★ S9 — "If there are *any* modifications, it should say "Save & Exit". This will run the lattice
// bake (if the view is already selected). Otherwise, it should say "Exit" and no changes should
// occur on the main screen." The page keeps the settings as they were when it opened (a VALUE,
// so undoing back to them reads "Exit" again). Exit with nothing changed saves nothing and tells
// the main page so (`exitUnchanged`): no rebuild, no re-solve, no restart of the squish. Save &
// Exit saves and hands over to the main page, which bakes the lattice only while its Lattice view
// is on (FlexibleMainStage.didExitSettings) — with it off the settings are only stored, and the
// bake runs when the view is turned on.

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// The filament a brand-new setup starts with: the first with squish data, else the first.
    public var defaultMaterialID: String? {
        catalogue.first { $0.noPrediction == nil }?.id ?? catalogue.first?.id
    }

    /// ★ S5: a brand-new Flexible setup of THIS part, the main page's loads read in (the unit kept).
    public func freshSettings() -> FlexibleStageSettings {
        var s = FlexibleStageSettings(materialID: defaultMaterialID)
        s.weightUnit = settings.weightUnit
        if let loads = deriveMainPageLoads() { _ = Self.adopt(loads, into: &s) }
        return FlexibleSettingsMigration.migrated(s)
    }

    /// ★ S5: every input back to a brand-new setup — one undoable step; the page's per-face copies
    /// of core's answers go with the old faces.
    public func resetAll() {
        let fresh = freshSettings()
        let before = settings
        guard fresh != before else { return }
        actionSerial += 1
        let regions = Set(before.faces.map(\.faceRegionID))
        project.sealUndoStep()   // the edits before it are their own step (their save may still be pending)
        edit { $0 = fresh }
        for r in regions { purgeFaceCaches(r) }
        refreshMainPageLoads()
        relinkedWeights = [:]
        curvePoint = nil
        frozenExaggeration = nil
        selectedRegion = settings.loadedFaces.first?.faceRegionID ?? settings.faces.first?.faceRegionID
        save()   // one undo step (the project's snapshot history)
    }

    /// ★ S9 (S VERIFICATION): the page's "nothing changed" snapshot once a part that was still
    /// opening as the page appeared is open — the settings as the page appeared, with the open's
    /// own read of the main page's loads applied (the same loads, the same rule as
    /// `adoptMainPageLoads`). The open's adopt is not his edit; an edit he made while it opened
    /// (the [Model] tab is live) is not in it, so it still reads "Save & Exit". (Re-taking the
    /// snapshot at .ready had counted that edit as "nothing changed".)
    public func openedSnapshot(appeared: FlexibleStageSettings) -> FlexibleStageSettings {
        var s = appeared
        if project.viewerMesh != nil { _ = Self.adopt(mainPageLoads, into: &s) }
        return FlexibleSettingsMigration.migrated(s)
    }

    /// ★ S9: the page's Exit with nothing changed (read once by the main page).
    func takeExitUnchanged() -> Bool {
        defer { exitUnchanged = false }
        return exitUnchanged
    }
}

/// ★ S9: what the page's exit button says and does, from the readiness and whether anything changed.
public enum FlexibleSettingsExit {

    public static let exit = "Exit"
    public static let saveAndExit = "Save & Exit"

    /// "Exit" (nothing changed — even with a blocker standing: leaving changes nothing), "Save & Exit"
    /// (something changed, nothing blocks), "Fix 1 thing" (something changed and it blocks).
    public static func title(_ r: FlexibleReadiness, modified: Bool) -> String {
        guard modified else { return exit }
        return r.blocking.isEmpty ? saveAndExit : FlexibleExitDecision.title(r)
    }

    /// Nothing changed: leave (the main page does nothing). Changed: the readiness decides.
    public static func decide(_ r: FlexibleReadiness, modified: Bool) -> FlexibleExitDecision {
        modified ? FlexibleExitDecision.decide(r) : .exit
    }

    /// Did anything change since the page opened (`opened` nil: the part is still opening — nothing yet)?
    public static func modified(_ now: FlexibleStageSettings, since opened: FlexibleStageSettings?) -> Bool {
        opened.map { $0 != now } ?? false
    }

    /// ★ S9: the page's top line when it is ready — it names the button he will press (round 4's
    /// "Ready: Exit builds the lattice" was said while nothing had changed, and Exit then built nothing).
    public static func readyLine(_ line: String, modified: Bool) -> String {
        guard line == FlexibleReadiness.ready || line == FlexibleReadiness.readyShapeOnly else { return line }
        guard modified else { return unchangedLine }
        return line == FlexibleReadiness.ready ? "Ready: Save & Exit builds the lattice" : "Ready: Save & Exit builds a shape-only lattice"
    }
    public static let unchangedLine = "Ready · nothing changed yet"

    /// The one-line confirm of Reset all.
    public static let resetAsk = "Reset every setting here?"
    public static let resetButton = "Reset all"
    public static let resetConfirm = "Reset"
    public static let resetCancel = "Cancel"
}

extension FlexibleMainStage {
    /// ★ S9: the Lattice view turned on — the bake a Save & Exit left for it (the view was off) runs now.
    func bakeDeferred() {
        guard let m = model, m.latticeBuildDeferred else { return }
        m.latticeBuildDeferred = false
        buildIfReady()
    }
}
