// FlexibleChromeStateTests — round 7, batch R7-D1: ONE CARD AT A TIME on the main Flexible page (the redesign's step 0,
// shared with D2). His rules: one legend card per page; blockers pop at once; and the mockup he picked, whose Setup tray,
// Lattice card and blocker callout never stack. A model tap, a stage change, the Squish page opening and gravity setup fold
// them all. The panels are OVERLAYS of the corner pair: they never change the bottom bar's measured height (#354's
// BottomBarHeightKey — the defect BottomBarMeasurementTests guards). RED CONTROL: a panel placed in layout changes it.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows

@MainActor
final class FlexibleChromeStateTests: XCTestCase {

    func testOpeningAnyCardClosesTheOthers() {
        let c = FlexibleChromeState()
        let all: [FlexibleChromeState.Card] = [.setup, .latticeCard, .callout, .faceChip, .keypad]
        for a in all {
            for b in all where b != a {
                c.show(b); c.show(a)
                XCTAssertEqual(c.open, a, "\(a) closes \(b)")
            }
        }
        c.show(.setup); c.toggle(.setup)
        XCTAssertNil(c.open, "toggle closes the open card")
        c.show(.latticeCard); c.close(.setup)
        XCTAssertEqual(c.open, .latticeCard, "close(x) leaves another card open")
        c.foldAll()
        XCTAssertNil(c.open)
    }

    func testTheFaceChipWaitsWhileTheTrayOrTheCardIsOpen() {
        let c = FlexibleChromeState()
        XCTAssertTrue(c.allowsFaceChip)
        c.show(.setup); XCTAssertFalse(c.allowsFaceChip, "the tray is open")
        c.show(.latticeCard); XCTAssertFalse(c.allowsFaceChip, "the card is open")
        c.show(.callout); XCTAssertFalse(c.allowsFaceChip, "the callout is open")
        c.show(.faceChip); XCTAssertTrue(c.allowsFaceChip)
        c.show(.keypad); XCTAssertTrue(c.allowsFaceChip, "the keypad a chip's number opened")
    }

    /// A model tap folds every card (D1: every face tap on the main page reaches `read`, H7's existing line); leaving the
    /// stage and the Squish page opening (a full-screen page) fold them too.
    func testAModelTapAStageChangeAndTheSquishPageFoldTheCards() throws {
        let main = FlexibleMainStage()
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        main.apply(p, owned: true, pageUp: false)
        XCTAssertTrue(main.visible)
        main.chrome.show(.latticeCard)
        _ = main.read(p, mode: .groups, face: FaceID(1), point: nil)
        XCTAssertNil(main.chrome.open, "★ a tap on the part folds the card")
        main.chrome.show(.setup)
        main.apply(p, owned: true, pageUp: true)
        XCTAssertNil(main.chrome.open, "★ the Squish page (a full-screen page) folds the tray")
        main.apply(p, owned: true, pageUp: false)
        main.chrome.show(.callout)
        main.apply(p, owned: false, pageUp: false)
        XCTAssertNil(main.chrome.open, "★ leaving the stage folds the callout")
        let code = try FlexibleSource.code("FlexibleMainStage+Views.swift")
        XCTAssertTrue(code.contains("if visible, !frozen, model?.project === project { chrome.foldAll(); noteMainTap(face: Int(face), point: point) }"))
    }

    // MARK: the bar's measured height (hosted)

    final class Box { var height: CGFloat = 0 }

    /// #354's bar, as it measures itself: an HStack whose background publishes BottomBarHeightKey, inside the expanded frame.
    func measure(open: FlexibleChromeState.Card?, control: Bool) -> CGFloat {
        let main = FlexibleMainStage()
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        let app = AppModel(materialsPath: nil)
        if let open { main.chrome.show(open) }
        FlexibleCornerPair.controlPanelInLayout = control
        defer { FlexibleCornerPair.controlPanelInLayout = false }
        let box = Box()
        let bar = HStack(alignment: .bottom) {
            Spacer()
            FlexibleCornerPair(main: main, project: p, app: app, openSquish: {}, changeGravity: {})
        }
        .background(GeometryReader { g in Color.clear.preference(key: BottomBarHeightKey.self, value: g.size.height) })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 24).padding(.bottom, 24)
        .onPreferenceChange(BottomBarHeightKey.self) { box.height = $0 }
        let hv = NSHostingView(rootView: bar.environment(\.colorScheme, .dark))
        hv.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let w = NSWindow(contentRect: hv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        hv.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(1.0)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        hv.layoutSubtreeIfNeeded()
        w.contentView = nil
        return box.height
    }

    func testThePanelsNeverChangeTheBarsMeasuredHeight() {
        let closed = measure(open: nil, control: false)
        XCTAssertEqual(closed, 64, accuracy: 0.5, "the bar is the pair's height (the 64 pt Lattice button)")
        for c in [FlexibleChromeState.Card.setup, .latticeCard, .callout] {
            XCTAssertEqual(measure(open: c, control: false), closed, accuracy: 0.5, "★ \(c) open: the bar measures the same")
        }
        let control = measure(open: .latticeCard, control: true)
        print("FLEX-R7D1-CHROME bar closed \(closed) · card open \(measure(open: .latticeCard, control: false)) · control (in layout) \(control)")
        XCTAssertGreaterThan(control, closed + 50, "★ RED CONTROL: a panel placed in layout grows the measured bar")
    }
}
#endif
