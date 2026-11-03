// SheetLayeringTests — B2, U17 (approved design 2026-11-02, design-system §4.11 and §6 U17; his Phase 3 note P4: "a
// notification that pops up *Behind* the modal … The notification for it not having a built Print Plan is also *BEHIND* the
// modal").
//
// The print parameters sheet as RootView presents it (over its scrim, with the app's toast and the pad's note), with real
// clicks: a number's pad opens above the sheet; what it kept is said above the sheet and never over it; and "Save" asks for
// the preset's name in a row inside the sheet, never an alert. RED before B2: the pad's note reached nothing in a sheet
// (no toast), and Save raised a system alert over the sheet (no row in it).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

/// The sheet the way RootView layers it.
private struct SheetRoot: View {
    @ObservedObject var model: AppModel
    let project: ProjectModel
    var body: some View {
        ZStack { DS.Color.background.color; PrintParamsOverlay(model: model, project: project) }
            .laneToast($model.toast)
            .numberPadNote { model.toast = $0 }
    }
}

@MainActor
final class SheetLayeringTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run { HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    func testWhatASheetOpensOrSaysIsAboveItOrInIt() throws {
        HardwareKeyboard.override = false
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let app = r.app, p = r.project
            p.paramsLocked = false
            let h = AppBuildHost(SheetRoot(model: app, project: p), size: size, test: self)
            h.pump(2)
            let sheet = try h.onScreen("sheet", "\(size): the print parameters sheet")

            // a number's pad: its own presentation, above the sheet
            try h.tap("printParam-infill", "\(size): Infill density")
            XCTAssertNotNil(h.padWindow, "\(size): ★ the pad opens above the sheet")
            for c in "150" { try h.padTap("numberPad-key-\(c)", "\(size): \(c)") }
            try h.padTap("numberPad-done", "\(size): Done")
            XCTAssertEqual(p.printParams.infillPercent, 100, "\(size): out of range keeps the nearest (100 %)")
            XCTAssertEqual(app.toast, "Kept 100 % (0 to 100 %)", "\(size): ★ and says so")
            h.pump(0.5)
            let toast = try h.onScreen("lane-toast", "\(size): ★ the note, drawn above the sheet's scrim")
            XCTAssertFalse(toast.intersects(sheet.insetBy(dx: 0.5, dy: 0.5)), "\(size): ★ never over the sheet: \(toast) vs \(sheet)")

            // what the sheet asks is a row in it
            try h.tap("presetSave", "\(size): Save")
            let row = try h.onScreen("presetNameRow", "\(size): ★ the preset's name, asked in the sheet")
            XCTAssertTrue(sheet.insetBy(dx: -0.5, dy: -0.5).contains(row), "\(size): inside the sheet")
            XCTAssertFalse(NSApp.windows.contains { $0 !== h.window && $0.isVisible && $0.className.contains("Alert") },
                           "\(size): ★ no alert")
        }
    }
}
#endif
