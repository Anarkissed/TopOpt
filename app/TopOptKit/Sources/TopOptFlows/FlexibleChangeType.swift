// FlexibleChangeType — "Change lattice type…" on the Flexible stage (the redesign plan's P4, point 2: one lattice type per
// project; the reviewer's rulings R8 / R12 and the overnight release ruling of 2026-10-26 07:42 UTC, hook H62).
//
// The ● Flexible menu's row (after ● Flexible ✓) asks with #354's own ChangeLatticeTypeCard (B4, LatticeStage.swift), three
// ways: "Create a duplicate and choose a type" → AppModel.duplicateAndChooseLatticeType(id:) (the copy keeps everything but
// Topology's results — his R12 answer — and opens its type selector; H54 clears the copy's Flexible claim); "Continue and
// lose all work" → today's delete (WorkspacePlaceholder.deleteLatticeForMode: ProjectModel.clearLatticeWork, ONE undo step,
// its Undo over the selector it brings up); Cancel → nothing. #354's own mount needs a Structural / Aesthetic type
// (`stageMode`), which a Flexible project never has, so the card is mounted for Flexible here (H62). On the Squish page the
// row runs the page's Save & Exit check first (the draft is saved, so a duplicate carries it).

import SwiftUI
import TopOptDesign

public enum FlexibleChangeType {
    public static let title = LatticeStageMenu.changeTypeTitle
    /// ≤ 22 characters (R9).
    public static let detail = "asks first \u{00B7} work goes"

    /// The card shows: asked, on a Flexible project. (#354's mount reads `stageMode`, nil on every Flexible project.)
    @MainActor static func shows(asking: Bool, project: ProjectModel) -> Bool { asking && project.lattice.flexible != nil }

    /// A choice: the card closes, then the one thing it says.
    @MainActor static func choose(_ c: ChangeLatticeTypeChoice, main: FlexibleMainStage, duplicate: () -> Void, loseAll: () -> Void) {
        main.changeTypeAsking = false
        switch c {
        case .duplicate: duplicate()
        case .loseAll: loseAll()
        case .cancel: break
        }
    }

    /// The duplicate, as #354's lattice stage makes it: saved first, then copied and opened with its type selector.
    @MainActor static func duplicate(app: AppModel, project: ProjectModel) {
        app.persistCurrentProject()
        if app.duplicateAndChooseLatticeType(id: project.id) == nil { app.toast = RerunCard.copyFailedToast }
    }
}

extension FlexibleMainStage {
    /// The ● Flexible menu's "Change lattice type…": every card folds, the card asks.
    public func askChangeType() {
        chrome.foldAll()
        changeTypeAsking = true
    }
}

/// H62: #354's card over the Flexible pages (zIndex 49, over the Squish page's 48), while asked.
public struct FlexibleChangeTypeMount: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let app: AppModel
    let loseAll: () -> Void

    public init(main: FlexibleMainStage, project: ProjectModel, app: AppModel, loseAll: @escaping () -> Void) {
        self.main = main; self.project = project; self.app = app; self.loseAll = loseAll
    }

    public var body: some View {
        if FlexibleChangeType.shows(asking: main.changeTypeAsking, project: project) {
            ChangeLatticeTypeCard(type: FlexibleStageStyle.title, regions: FlexibleChangeType.regions(project)) { c in
                FlexibleChangeType.choose(c, main: main, duplicate: { FlexibleChangeType.duplicate(app: app, project: project) },
                                          loseAll: loseAll)
            }
            .transition(.opacity)
        }
    }
}

extension FlexibleChangeType {
    /// The card's count: the groups that lattice something (an include in them), as #354's card counts.
    @MainActor static func regions(_ p: ProjectModel) -> Int {
        p.selection.groups.filter { g in
            p.latticeSelectableRefs(g).contains { p.latticeSelectableRole($0, in: g.id) == .include }
        }.count
    }
}
