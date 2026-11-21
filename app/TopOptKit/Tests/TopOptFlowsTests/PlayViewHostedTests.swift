// PlayViewHostedTests — B9 (#362), the Print plan's Play view (his Phase 3 note P3; ledger P3; the mockup's #flex-plan-play).
// On the Print plan page the view row's ▶ is the Play view: the timeline at the bottom centre ("Apart ⟷ Together"), its
// caption saying what plays. The pieces come apart along the engine's split of the body (E5 item 53), which waits — so
// today the caption says so and ▶ is dim, as it is when the part prints as one piece. A second ▶ closes it. On the Setup
// page ▶ is still the squish's Play.
#if canImport(AppKit)
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PlayViewHostedTests: XCTestCase {
    struct Page: View {
        @ObservedObject var main: FlexibleMainStage
        @ObservedObject var project: ProjectModel
        let app: AppModel
        var body: some View {
            ZStack {
                PrintPlanHostedTests.PlanPage(main: main, project: project, app: app)
                FlexibleMainViewToggles(main: main)
                    .padding(PageChrome.edge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    func host() throws -> (SquishHost, FlexibleMainStage, FlexibleStageModel) {
        let stage = FlexibleMainStage()
        let (r, m) = try SquishHost.pad(self, edges: false, stage: stage)
        stage.page = .plan
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("play-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel(materialsPath: "/no/such/materials.json", store: ProjectStore(rootDir: dir))
        let h = SquishHost(Page(main: stage, project: r.project, app: app), size: PrintPlanHostedTests.size, test: self)
        SquishHost.pump(1.5)
        return (h, stage, m)
    }

    func testThePlayViewOpensTheTimelineAndSaysWhyNothingMovesYet() throws {
        let (h, stage, m) = try host()
        XCTAssertNil(h.frame("timeline"), "no timeline until ▶")
        try h.tap("mainView-play", "the view row's ▶")
        XCTAssertTrue(stage.planPlay, "★ ▶ on the Print plan page opens the Play view")
        XCTAssertFalse(stage.playOn, "…not the squish's Play")
        let line = try XCTUnwrap(h.frame("timeline"), "★ the timeline is drawn")
        XCTAssertEqual(line.midX, PrintPlanHostedTests.size.width / 2, accuracy: 2, "★ bottom centre")
        if let corner = h.frame("planBuild") ?? h.frame("cornerPair") {
            XCTAssertLessThanOrEqual(line.maxY, corner.minY + 0.5, "★ above the corner, never over it")
        }
        XCTAssertEqual(FlexiblePlanPlay.caption(stage.printPlans).caption, FlexiblePlanPlay.onePiece,
                       "one material: it prints as one piece")
        XCTAssertFalse(FlexiblePlanPlay.caption(stage.printPlans).enabled, "…and ▶ is dim")
        // two materials: two pieces, the add-ons their joint calls for — and the engine's split still to come
        try h.tap("planSecondMaterial", "+ Second material")
        stage.editPlans { $0.plan.joints["lattice-body"] = "T-slot" }
        SquishHost.pump(0.5)
        let say = FlexiblePlanPlay.caption(m.settings.printPlans)
        XCTAssertTrue(say.caption.hasPrefix("2 pieces + 2 add-ons"), "★ what plays: \(say.caption)")
        XCTAssertTrue(say.caption.hasSuffix("apart once the engine splits them"), "★ says why nothing moves yet")
        XCTAssertFalse(say.enabled, "★ ▶ dim until the engine splits the body")
        try h.tap("mainView-play", "▶ again")
        XCTAssertFalse(stage.planPlay, "★ a second ▶ closes it")
        XCTAssertNil(h.frame("timeline"))
    }

    /// CONTROL: on the Setup page ▶ is still the squish's Play — no Play view, no timeline.
    func testOnSetupPlayIsStillTheSquish() throws {
        let (h, stage, _) = try host()
        stage.page = .setup
        SquishHost.pump(0.5)
        if h.frame("mainView-play") != nil, stage.viewsAvailable {
            try h.tap("mainView-play", "▶ on Setup")
            XCTAssertFalse(stage.planPlay, "control: Setup's ▶ never opens the Play view")
        }
        XCTAssertNil(h.frame("timeline"))
    }
}
#endif
