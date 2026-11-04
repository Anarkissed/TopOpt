// FlexibleRound7CalloutHostedTests — round 7, batch R7-D1, found by LOOKING at the evidence (round7/batch_d1/, M05): on his pad
// a blocker (a pressed face's weight taken away) turned the Lattice button orange ("Fix: the weight on Face 3") but the callout
// never popped. His pick: "Blockers pop at once above the pair." The pair hosted alone over his pad's own stage (the shared
// model, scene and designs settled), a face's weight set to 0: the callout opens at once, once.
// RED CONTROL `FlexibleCornerPair.controlCapturedStatus`: the blocker rule fed the status its onChange closure captured.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1CalloutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7CalloutHostedTests: XCTestCase {
    override func tearDown() { FlexibleCornerPair.controlCapturedStatus = false; super.tearDown() }

    func pump(_ s: Double) { let e = Date().addingTimeInterval(s); while Date() < e { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) } }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let e = Date().addingTimeInterval(t)
        while !c() { if Date() > e { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }

    func testABlockerPopsTheCalloutAtOnceOnHisPad() throws {
        var report: [String] = []
        for control in [false, true] {
            FlexibleCornerPair.controlCapturedStatus = control
            let r = try FlexiblePressFixtures.a1Project(3, self)
            let stage = FlexibleMainStage()
            stage.reduceMotion = { true }
            let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            m.openScene()
            XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && !m.readiness.designing && !m.designsInFlight }, "the scene and designs")
            let host = NSHostingView(rootView: AnyView(HStack(alignment: .bottom) { Spacer(); FlexibleCornerPair(main: stage, project: r.project, app: r.app, openSquish: {}, changeGravity: {}) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(24).environment(\.colorScheme, .dark)))
            host.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
            let w = R7D1CalloutWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1032, height: 1376), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host; w.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
            pump(1)
            let before = stage.status
            XCTAssertNotEqual(before.tone, .fix, "premise: nothing blocks at first (\(before.line))")
            XCTAssertNil(stage.chrome.open)
            // a pressed face of his own weight loses it
            let own = try XCTUnwrap(m.settings.loadedFaces.first { $0.weightFrom == nil }?.faceRegionID, "a face of his own weight")
            m.edit { st in guard var f = st.face(own) else { return }; f.weightKg = 0; st.setFace(f) }
            _ = pumpUntil(10) { stage.status.tone == .fix }
            pump(1.5)
            report.append("\(control ? "control" : "now"): status '\(stage.status.line)' · open \(String(describing: stage.chrome.open))")
            XCTAssertEqual(stage.status.tone, .fix, "premise: the weight blocks")
            if control {
                XCTAssertNil(stage.chrome.open, "★ RED CONTROL: the captured status pops nothing")
            } else {
                XCTAssertEqual(stage.chrome.open, .callout, "★ the blocker pops above the pair at once")
                stage.chrome.close(.callout)
                m.objectWillChange.send()
                pump(1)
                XCTAssertNil(stage.chrome.open, "★ dismissed, it does not pop again by itself")
            }
            w.orderOut(nil); w.contentView = nil
        }
        print("FLEX-R7D1-CALLOUT " + report.joined(separator: " | "))
    }
}
#endif
