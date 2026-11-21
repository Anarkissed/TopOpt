// FlexibleEditFaces — Edit faces (B5's mode) opened from a Flexible page (the redesign plan's P5, point 1; the reviewer's
// rulings R9 and the overnight release ruling of 2026-10-26 07:42 UTC, hooks H60 / H61).
//
// The ● Flexible menu's "Edit faces…" row and the ✂ after [Lattice | Squish] open B5's mode through #354's own entry point,
// `WorkspacePlaceholder.enterEditFaces(from: .host(<page>), onReturn:)`. While it is up Flexible's own layers and taps are
// off (`FlexibleMainStage.faceEditing`; H61 gates the page's positive owns() sites); owns() itself stays, so #354's
// handles, Settings button, Regions panel and Export step stay hidden on the Flexible stage. Done (or Discard) hands the
// origin back: the Squish page re-opens, the main page is already under the mode.

import Foundation

public enum FlexibleEditFaces {
    /// The return targets #354's `.host` origin carries.
    public static let mainPage = "flexible.main"
    public static let squishPage = "flexible.squish"

    /// ★ RED CONTROL: Done lands on Topology (the origin a Topology page would give).
    @MainActor static var controlLandsOnTopology = false

    /// Where Edit faces opens from (and Done goes back to).
    @MainActor public static func origin(_ page: FlexibleStageCapsule.Page) -> EditFacesOrigin {
        if controlLandsOnTopology { return .topology(.setup) }
        return .host(page == .squish ? squishPage : mainPage)
    }

    /// The Flexible page an origin names (nil: not a Flexible page's).
    public static func page(_ origin: EditFacesOrigin) -> FlexibleStageCapsule.Page? {
        guard case let .host(name) = origin else { return nil }
        switch name {
        case mainPage: return .lattice
        case squishPage: return .squish
        default: return nil
        }
    }
}

extension FlexibleMainStage {
    /// Edit faces opens from a Flexible page: every card folds, the pick and the chip close, Flexible's layers go off.
    public func editFacesOpens() {
        endAttach()
        chrome.foldAll()
        faceUI.closeTransient()
        if !facePick.scope.isNone { var s = facePick; s.scope = .none; facePick = s }
        faceEditing = true
    }

    /// Done (or Discard): Flexible's layers come back; true when the Squish page is the one to re-open.
    @discardableResult
    public func editFacesReturns(_ origin: EditFacesOrigin) -> Bool {
        faceEditing = false
        return FlexibleEditFaces.page(origin) == .squish
    }
}
