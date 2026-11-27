// BackTargetHostedTests — B1, ledger note 8 (approved design 2026-11-02).
//
// His words: "Pressing the < button … goes straight to the Library view. If the part is within a Project, the back should go
// to the Project folder." The cause: the Library's route was its view's own @State, rebuilt on every return, so Back
// (`AppModel.backHome`) always landed on the Library's home. The route now lives on LibraryModel, and Back from a part filed
// in a project shows that project's folder.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class BackTargetHostedTests: XCTestCase {

    func testBackFromAPartInAProjectShowsThatProjectsFolder() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)   // his part, filed in his project
        let part = try XCTUnwrap(app.library.index.part(containing: r.project.id))

        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.tap("backButton", "the workspace's Back", settle: 2)

        XCTAssertEqual(app.screen, .home, "Back left the part")
        _ = try h.onScreen("libraryFolder-Squish Mechanism", "★ his project's folder, after Back")
        _ = try h.onScreen("libraryPart-\(part.name)", "his part's card in it")
    }

    func testBackFromAnUnfiledPartShowsTheLibrarysHome() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app
        app.library.refresh()
        try app.library.group(projectName: nil, partIDs: nil)   // grouped, but in no project
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        try h.tap("backButton", "the workspace's Back", settle: 2)
        XCTAssertEqual(app.screen, .home)
        XCTAssertEqual(app.library.route, .home, "an unfiled part comes back to the Library's home")
        XCTAssertNil(h.frames.all.keys.first { $0.hasPrefix("libraryFolder-") }, "no folder is open")
    }
}
#endif
