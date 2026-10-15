// FlexibleNoFacePrismFlow — round 7 batch M1, the VERIFY's fixes (task 2026-09-29-flexible-screens, 2026-10-14). The verify
// looked at batch M1 on his pad (A1_0003) with the whole main page hosted and found, among others:
//   * with no face-prism, core's whole-part designs were still asked for and drove the Squish page's dent scale ("What you
//     drew · 0 mm … 28.7 mm" over faces that show no dent), and its top line said "Ready · No lattice under Face 1";
//   * the main page's pill said "Set a face to Lattice in Selections first" but its tap opened the Squish page's
//     [Lattice under all 4] (three new groups, the whole pad latticed again — his img1 complaint);
//   * while the lattice rebuilt after a depth edit, the main page's legend read "What you drew · 0 mm … 24.5 mm" — Face 3's
//     SQUISH depth from the Squish page, beside the list's 17.3 / 25.0 (his img1: "they should *always* be equal"; his
//     answer: "the squish number: only on the Squish page");
//   * [Prisms] drew nothing a pick did not (before a pick: nothing at all, yet its legend row and X-ray);
//   * the Heat / Play icons stayed lit on the plain model;
//   * the Export line named the SQUISH group by his Squish-page name beside Selections' "Group C" (his answer: "Group
//     names in squish are JUST squish groups. NOT lattice groups.").
// The rules live with the code they change (FlexibleStageModel.scheduleDesigns, FlexibleShownValues, FlexibleReadiness,
// FlexibleMainStage, FlexibleMainStatusPill, FlexibleCoreHold); this file holds the shared helpers and the RED CONTROLS (each
// the M1 build's behaviour it reverses). All app-side; nothing in a #354 / main file.

import Foundation
import SwiftUI
import TopOptKit

extension FlexibleMainStage {
    /// Test controls only (the M1 build, before its verify): the drawn curve's dent and heat on the main page while no
    /// lattice is drawn (its legend "What you drew · … 24.5 mm"); [Prisms] = only the picked group's face-prisms (with its
    /// legend row and X-ray even when nothing is drawn); the no-face-prism pill opening the Squish page's fix; the lattice
    /// views lit and live with no face-prism.
    @MainActor static var controlDrawnCurveOnMain = false
    @MainActor static var controlPrismsPickedOnly = false
    @MainActor static var controlNoPrismOpensSquishFix = false
    @MainActor static var controlViewsAlwaysAvailable = false

    /// ★ M1 VERIFY (his img1 rule: "ONLY the face-prism creates the lattice structure"): the lattice's views (Heat, Stress,
    /// Lattice, [Prisms], Play) have something to show — false on the opened scene with no face-prism (the plain model:
    /// they are drawn unavailable, never lit). X-ray stays (it sees into the solid).
    public var viewsAvailable: Bool {
        true   // STUB (tests first)
    }
}

extension FlexibleMainStatusPill {
    /// ★ M1 VERIFY (ruling 4: "Export disabled with a stated reason when no face-prism is set"): with no face-prism, on the
    /// main page itself, the big Lattice button is DISABLED — its line is the reason ("Set a face to Lattice in Selections
    /// first"), and Selections is on the same screen. On another stage its tap takes him to the Lattice stage (where
    /// Selections is). RED CONTROL `FlexibleMainStage.controlNoPrismOpensSquishFix`: enabled, its tap opened the Squish page.
    @MainActor static func disabled(_ s: FlexibleMainStatus, visible: Bool) -> Bool {
        false   // STUB (tests first)
    }
}

extension FlexibleStagePage {
    /// ★ M1 VERIFY: the Squish page's top-line [Fix] — the first blocker, else the advisory (competing groups, a face with
    /// no lattice under it); with NO face-prism none: the line says what to do on the main page ("Set a face to Lattice in
    /// Selections first"), and the per-face [Lattice under it] stays on each face's card.
    @MainActor static func noticeFix(_ r: FlexibleReadiness, model m: FlexibleStageModel) -> FlexibleIssue? {
        r.blocking.first ?? r.advisory   // STUB (tests first)
    }
}

extension FlexibleStageModel {
    /// Test control only (the M1 build): with no face-prism, core's designs still asked for (on its own whole-part stack)
    /// and the drawn curve still shown — the Squish page's "What you drew · 0 mm … 28.7 mm" over faces with no lattice,
    /// "Ready · No lattice under Face 1", and the pop-up at once.
    @MainActor static var controlDesignsWithoutPrism = false

    /// ★ M1 VERIFY: nothing can be designed or squished — the opened scene sets no face-prism (the scene still opening
    /// counts as "not known yet": false).
    var noFacePrismKnown: Bool {
        !Self.controlDesignsWithoutPrism && sceneState == .ready && !facePrismsSet
    }
}

extension FlexibleCoreHold {
    /// Test control only (the M1 build): the Export line names the squeeze group by his Squish-page name ("This export makes
    /// Thumbs only.") — his answer: squish group names stay on the Squish page.
    @MainActor static var controlSquishNameInExport = false
}
