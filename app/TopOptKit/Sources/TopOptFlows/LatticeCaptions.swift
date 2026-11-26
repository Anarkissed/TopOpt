// LatticeCaptions — ★ his iPad notes on release 20 (2026-11-25): "What is with ALL THAT TEXT below the 'Skin'? You should aim
// for about 5 words below ANY setting, with an (i)."
//
// Every line drawn under a setting on the Lattice settings panel (Part, groups, zones; Structural, Aesthetic, Organic) is at
// most five words; the sentence it replaced is its (i), opened in the centred notification (AppInfo.swift). The panel's own
// lines are named here, beside the counter the tests use; while a test records (FlexibleSaid.recording), every line the panel
// draws is recorded so a walk of the page in each state can hold every one to five words (LatticeCaptionsNotes29Tests).
import Foundation

public enum LatticeCaptions {
    /// His number.
    public static let maxWords = 5

    /// The words a reader counts: whitespace-separated tokens that hold a letter or a digit ("·", "—", "+", "→" are not words).
    public static func words(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).filter { t in t.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Every line drawn under a setting while a test records.
    nonisolated(unsafe) public static var recorded: [String] = []
    public static func record(_ line: String) {
        if FlexibleSaid.recording { recorded.append(line) }
    }

    /// The (i)'s title for a wizard (i) by its id (the setting it explains).
    public static func infoTitle(_ id: String) -> String {
        if let t = titles[id] { return t }
        if id.hasPrefix("type-") { return "Lattice type" }
        var words = id.replacingOccurrences(of: "manual-", with: "").replacingOccurrences(of: "-", with: " ")
        if let f = words.first { words = f.uppercased() + words.dropFirst() }
        return words
    }
    static let titles: [String: String] = [
        "grade-toggle": "Grade the lattice", "grade-type": "Grade", "sim": "Simulate Stresses",
        "grade-style": "Grade style", "grade-style-blocked": "Grade style", "band": "Grade to shape band",
        "organic-band": "Grade to shape band", "wizard-shape-band-strength": "Strength", "traced-grown": "Organic lattice",
        "organic": "Organic lattice", "cell-size": "Cell size", "density": "Density", "density-sim": "Density",
        "fit-to-shape": "Fit to shape", "spacing-scale": "Spacing scale", "transfer-ties": "Transfer ties",
        "solid-rim": "Solid rim at edges", "look": "Look", "synthetic": "Unloaded walls", "synthetic-map": "Unloaded walls",
        "check-failed": "Check sizes", "none-checked": "Check sizes", "rec-collapsed": "Recommended size",
        "rec-auto": "Recommended size", "rec-fit": "Recommended size", "band-no-room": "Grade to shape band",
        "band-steps": "Grade to shape band", "cut-cells": "Let walls cut cells", "small-cells": "Small cells in thin walls",
        "single-cell": "Allow single-cell members", "subfloor": "Thin parts", "auto-cell": "Cell size",
        "per-region": "Density", "quilt": "Allow quilt", "finish-locked": "Finish", "rim": "Rim", "open-faces": "Finish",
        "covered": "Covered", "skin": "Skin pattern", "skin-cert": "Skin", "type-change": "Lattice type",
        "type": "Lattice type", "type-reason": "Lattice type", "thickness-derived": "Thickness",
        "thickness-no-band": "Thickness", "thickness-floor": "Thickness", "swept": "Cell size", "swept-narrow": "Cell size",
        "strength": "Strength", "tabs": "Groups", "per-area": "Groups", "area-own": "This group",
        "area-preview": "The preview", "organic-part": "Organic settings", "zone-rim-skin": "Finish",
        "zone-covered-under-skin": "Finish", "zone-rim-skin-engine": "Finish", "zone-skin-sheet": "Finish",
        "zone-finish-preview": "Finish", "shape-grade-run": "Grade to shape band", "look-walls": "Look",
        "fit-nothing-set": "Lattice walls", "sizes-recheck": "Check sizes", "check-refused": "Check sizes",
        "auto-recheck": "Check sizes", "recheck-tap": "Check sizes", "face-walls-left-out": "Face walls",
        "skin-thickness-refused": "Skin thickness", "manual-cells-across-warning": "Cells across a wall",
        "manual-strut-floor": "Strut width", "manual-strut-auto": "Strut width", "manual-target-line": "Target stress",
    ]

    /// A refused number's line under its setting (the centred pop-up says why too).
    public static let numberNotApplied = "That number was not applied."
    // Organic (LatticeOrganicControls)
    public static let organicShapeOnlyBrief = "Small cells where shape tightens."
    public static let organicMeasuringBrief = "Measuring this part for Auto."
    public static let organicUnmeasuredBrief = "Couldn't measure: type a range."
    public static let organicCrossingNeedsSeedsBrief = "Crossing vines need wall seeds."
    public static let organicFociBrief = "Foci are set in Selections."
}

/// The Lattice settings panel's lines (★ notes29: five words each; the sentences they replaced are their (i)s).
extension LatticeSetupWizard {
    static let gradeOnLine = "Cells vary across the part."
    static let gradeOffLine = "One cell, one density, everywhere."
    static let gradeFullLine = "Graded by stress and shape."
    static let gradeShapeLine = "Cells fit the outline only."
    static let gradeStressLine = "Density follows stress only."
    static let simOnLine = "Simulation sets Sim settings."
    static let simOffLine = "Every setting is yours."
    static let steppedBlockedLine = "Stepped blocked: use Default Grade."
    static let gradeStyleMissingLine = "Not in this engine."
    static let steppedLine = "Steps of any printable size."
    static let defaultGradeLine = "Each step halves the cell."
    static let markWallFirstLine = "Mark a lattice wall first."
    static let sizesRecheckLine = "Sizes need a re-check."
    static let cantCheckSizesLine = "Can't check sizes yet."
    static let noSizesCheckedLine = "No sizes checked yet."
    static let faceWallsLeftOutLine = "Some face walls left out."
    static let recheckTapBrief = "Tap to re-check sizes."
    static let shapeGradeRunBrief = "Band and Strength: preview only."
    static let bandNoRoomLine = "No room for smaller cells."
    static let subfloorLine = "Thin parts keep their lattice."
    static let typeReasonLine = "Can't use this type here."
    static let typeCantRunLine = "This type can't run here."
    static let thicknessDerivedLine = "Set by the stress simulation."
    static let autoCellLine = "The solve picks every cell."
    static let densityByStressLine = "Graded by each region's stress."
    static let perRegionLine = "Saved; not used yet."
    static let quiltOnLine = "Struts may fuse into quilt."
    static let quiltOffLine = "Struts never fuse into quilt."
    static let finishLockedLine = "Single-cell members need Skin."
    static let coveredLine = "Solid outer wall over lattice."
    static let rimGreyedBrief = "Rim not available yet."
    static let rimStoredBrief = "Rim refused: pick another finish."
    static let openFacesPreviewBrief = "Printed open; preview shows skin."
    static let skinNotCertifiedBrief = "Skin isn't strength-certified yet."
    static let organicWholePartBrief = "Settings cover the whole part."
    static let organicPartBrief = "Each group's tab sets these."
    static let latticePerAreaBrief = "Each group: own grade, finish."
    static let organicAreaBrief = "This group sets its finish."
    static let organicGroupBrief = "This group's own Organic settings."
    static let latticeAreaOwnBrief = "Grade and finish set here."
    static let latticeAreaPreviewBrief = "Preview shows the part's grade."
    static func zoneRimSkinBrief(_ part: String) -> String { "Part's \(part) covers every zone." }
    static let zoneCoveredUnderSkinBrief = "Part's Skin rules out Covered."
    static let zoneRimSkinNeedEngineBrief = "Zones take None or Covered."
    static let zoneSkinOnSheetBrief = "Sheet types can't take Skin."
    static let zoneFinishPreviewBrief = "Preview shows the part's finish."
    static let tabsBrief = "Settings apply to every region."
    static let strengthRunBrief = "Checked when the lattice runs."
    static let strengthExportBrief = "Checked on Mac at Export."
    static let strengthNotYetBrief = "Not checked yet."
    static let sweptLine = "Cells sized block by block."
    static let sweptNarrowLine = "Window too narrow to sweep."
    static let cellsAcrossWarnBrief = "Too few cells across."
}
