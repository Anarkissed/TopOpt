// CornerAboveFixLineTests — B2, U12 (approved design 2026-11-02, design-system §4.18 / §4.19 and §6 U12; his round 2 note N4:
// "When the Settings tab opens up, it should not be behind the 'No lattice settings yet' notification. It should be just above
// it").
//
// The corner pair (CornerPair, every stage's) with a fix line and its Settings panel open, at the iPad sizes: the panel's foot
// sits 8 pt above the fix line and never over it; with no fix line the panel sits where it always did. RED control: the panel
// ignores the fix line (it opens behind it). Today's app draws no fix line in the corner yet (the refusals ride on the run
// button until B3 / B6 move them there, U6); this proves the rule those lines will sit under.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

private struct CornerPage: View {
    let withFixLine: Bool
    @StateObject private var geometry = ChromeGeometry()
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DS.Color.background.color
            CornerPair(geometry: geometry, open: "setup",
                       fixLine: withFixLine ? AnyView(
                        Text("No lattice settings yet · Open Lattice").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, DS.Space.m).frame(height: 44)
                            .background(Capsule().fill(DS.Surface.bar.color))) : nil) {
                Text("Settings").frame(width: 120, height: 52).background(CornerPairStyle.publish("setupChip"))
            } split: {
                Text("Optimize").frame(width: 200, height: PageChrome.actionButton).background(CornerPairStyle.publish("split"))
            } panel: {
                CornerPairStyle.panel(width: 420, maxHeight: 400) {
                    ForEach(0..<5) { i in Text("Setting \(i)").frame(height: 44) }
                }
            }
            .padding(.trailing, PageChrome.edge).padding(.bottom, PageChrome.edge)
        }
    }
}

@MainActor
final class CornerAboveFixLineTests: XCTestCase {
    func frames(_ size: CGSize, fixLine: Bool) throws -> (panel: CGRect, line: CGRect?, split: CGRect) {
        let h = AppBuildHost(CornerPage(withFixLine: fixLine), size: size, test: self)
        h.pump(1)
        return (try h.onScreen("cornerPanel", "\(size): the Settings panel"), h.frames.all["cornerFixLine"],
                try h.onScreen("split", "\(size): the run button"))
    }

    func testThePanelOpensJustAboveTheFixLine() throws {
        addTeardownBlock { @MainActor in CornerPairStyle.controlPanelBehindFixLine = false }
        // ★ RED CONTROL: the panel ignores the fix line — it opens behind it
        CornerPairStyle.controlPanelBehindFixLine = true
        let c = try frames(AppBuildHost.landscape13, fixLine: true)
        XCTAssertTrue(c.panel.intersects(try XCTUnwrap(c.line).insetBy(dx: 0.5, dy: 0.5)), "the control: behind the fix line")
        CornerPairStyle.controlPanelBehindFixLine = false

        for size in AppBuildHost.sweep {   // ★ B10: the six windows
            let f = try frames(size, fixLine: true)
            let line = try XCTUnwrap(f.line, "\(size): the fix line")
            XCTAssertLessThanOrEqual(line.maxY, f.split.minY, "\(size): the fix line sits above the pair")
            XCTAssertEqual(f.panel.maxY, line.minY - CornerPairStyle.fixLineGap, accuracy: 1,
                           "\(size): ★ U12 — the panel's foot 8 pt above the fix line")
            XCTAssertFalse(f.panel.intersects(line.insetBy(dx: 0.5, dy: 0.5)), "\(size): ★ never behind it")
            let bare = try frames(size, fixLine: false)
            XCTAssertEqual(bare.panel.maxY, bare.split.minY - CornerPairStyle.panelGap, accuracy: 1,
                           "\(size): with no fix line, where it always was")
        }
    }
}
#endif
