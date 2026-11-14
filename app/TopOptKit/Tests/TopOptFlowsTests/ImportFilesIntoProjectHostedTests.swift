// ImportFilesIntoProjectHostedTests — B1, ledger note 9 (approved design 2026-11-02).
//
// His words: "Adding a part and setting it to be a project … automatically added it to the 'unfiled' project … A part should
// be added to a project whenever it is set (or when the default is ok)." The cause: the chosen project
// (`LibraryModel.importTargetProject`) was used once and CLEARED on the first Library refresh — and a refresh can come before
// the new part's folder exists, so nothing was filed and the part fell to Unfiled. Now the choice is kept until the part
// exists and is filed in it, and the part is filed the moment it is created (`continueToWorkspace`), before the workspace.
//
// His iPad's early refresh is not reproduced exactly; the test forces one between "Add part" and Continue (the mechanism).
// The file pick and Continue go through the import model's own calls (the system file picker can't be driven offscreen);
// "Add part" and Back are real clicks.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ImportFilesIntoProjectHostedTests: XCTestCase {

    func testAPartAddedInAProjectIsFiledInThatProjectEvenAfterAnEarlyRefresh() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        app.backHome()   // the Library, on his project's folder (note 8)
        let project = try XCTUnwrap(app.library.index.projects.first { $0.name == "Squish Mechanism" })

        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.tap("libraryAddPart", "his project's Add part", settle: 1)
        XCTAssertTrue(app.importSheetPresented, "Add part opens New part")
        XCTAssertEqual(app.library.importTargetProject, project.id, "the project is chosen")

        app.library.refresh()   // ★ an early refresh, before the new part exists (it cleared the choice)

        // the part: a lookalike cube (never his inputs), PLA, Continue
        let cube = FlexibleHisProject.repoRoot.appendingPathComponent("core/tests/fixtures/stl/cube_10mm.stl").path
        XCTAssertTrue(app.importFile(atPath: cube, displayName: "Top motor mount.stl"), "the cube imports")
        app.selectMaterial("PLA")
        app.continueToWorkspace()
        let newID = try XCTUnwrap(app.project?.id)
        h.pump(1)

        // ★ filed the moment it exists, before he goes back
        let part = try XCTUnwrap(app.library.index.part(containing: newID), "the new part is in the Library")
        XCTAssertEqual(app.library.projectOf(part: part.id)?.id, project.id, "★ the new part is in his project, not Unfiled")
        XCTAssertNil(app.library.importTargetProject, "the choice is used up once filed")

        // ★ and Back shows it in his project's folder
        try h.tap("backButton", "the workspace's Back", settle: 2)
        _ = try h.onScreen("libraryFolder-Squish Mechanism", "his project's folder")
        _ = try h.onScreen("libraryPart-\(part.name)", "★ the new part's card, in his project")
    }

    func testCancellingAddPartFilesNothingLater() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let app = r.app
        app.library.refresh()
        try app.library.group(projectName: "Squish Mechanism", partIDs: nil)
        app.backHome()
        let h = AppBuildHost(AppBuildRoot(model: app), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.tap("libraryAddPart", "his project's Add part", settle: 1)
        app.cancelImport()
        XCTAssertNil(app.library.importTargetProject, "a cancelled Add part leaves no project chosen")
    }
}
#endif
