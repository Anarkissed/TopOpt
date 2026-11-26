// Notes29DensityDialHostedTests — ★ his iPad notes on release 20 (2026-11-25), on the Lattice page itself: "The 'Density'
// grade percentage should then be limited within that, with a notification popping up if they try to go further". The page
// is hosted as the stage opens it (IPadNotes1110HostedTests' visit), Manual; what the Grade boxes DRAW is read through
// FlexibleSaid (a test process builds no SwiftUI accessibility tree). The pure parts: Notes29DensityDialTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes29DensityDialHostedTests: XCTestCase {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    final class Box { var said: [String] = []; var ids: [String: CGRect] = [:]; var keepOut: [String: CGRect] = [:] }

    func project(_ set: (ProjectModel) -> Void) throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.aesthetic)
        set(p)
        return p
    }

    /// The Grade boxes' percents as drawn on a new Lattice page on `p`, on its last view.
    func drawn(_ p: ProjectModel) -> (from: Int?, to: Int?) {
        let box = Box()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: ["Group 1"], closeToken: 0)
            .onPreferenceChange(FlexibleSaidKey.self) { box.said = $0 }
            .onPreferenceChange(LatticeProbeKey.self) { box.ids = $0 }
            .onPreferenceChange(FlexibleKeepOutKey.self) { box.keepOut = $0 }
        let h = AppBuildHost(v, size: AppBuildHost.landscape13, test: self)
        h.pump(1.2)
        for id in ["wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)", "lattice-page-tab-area-0", "lattice-page-mode-manual"] {
            let all = box.ids.merging(box.keepOut) { a, _ in a }.merging(h.frames.all) { a, _ in a }
            if let f = all[id], f.width > 1 { h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6) }
        }
        h.pump(0.6)
        func number(_ title: String) -> Int? {
            box.said.last { $0.hasPrefix(title + " ") }.flatMap { Int($0.dropFirst(title.count + 1).dropLast(2)) }
        }
        if number("Grade from") == nil { print("NOTES29 said: \(box.said.prefix(60)) ids: \(box.ids.keys.sorted().prefix(80))") }
        return (number("Grade from"), number("Grade to"))
    }

    /// ★ Allow quilt off, Manual, BCC + Z, Grade from stored at a density of 1 (the "100 %" of before): the box draws at most
    /// the type's limit (★ notes29b: one printed line short of its quilt, just under 100 %), never 100 %, and past the open
    /// look (no longer the stop). RED CONTROL: Allow quilt on, the same stored density draws past the limit.
    func testTheGradeBoxStopsJustUnderTheQuiltWithAllowQuiltOff() throws {
        func make(_ quilt: Bool) throws -> ProjectModel {
            try project { p in
                p.lattice.topologyID = "bccz"
                p.lattice.algorithm = "stepped"
                p.lattice.allowQuilt = quilt
                p.lattice.maxRelativeDensity = 1
                p.lattice.minRelativeDensity = 0.05
                p.latticePageManual = true
            }
        }
        let off = try make(false)
        let page = LatticeDensityDial.Page(off.lattice, lineWidthMM: off.printParams.strutLineWidthMM, allowQuilt: false)
        let a = drawn(off)
        let from = try XCTUnwrap(a.from, "the Grade from box is drawn")
        XCTAssertLessThanOrEqual(Double(from), page.most, "★ Allow quilt off: at most the limit (\(page.most) %)")
        XCTAssertLessThan(from, 100)
        let open = try XCTUnwrap(LatticeDensityDial.openLookPercent(cellMM: page.cellMM, topology: "bccz",
                                                                    lineWidthMM: off.printParams.strutLineWidthMM))
        XCTAssertGreaterThan(Double(from), open, "★ notes29b: past the open look (\(open) %): it is not the stop")
        let on = try make(true)
        let b = drawn(on)
        let fromOn = try XCTUnwrap(b.from)
        XCTAssertGreaterThan(Double(fromOn), page.most, "RED CONTROL: Allow quilt on draws past the limit (\(fromOn) %)")
        XCTAssertLessThanOrEqual(fromOn, 100, "never over 100 %")
    }
}
#endif
