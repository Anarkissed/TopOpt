// IPadNotes1110HostedTests — his iPad notes 11-10 (relayed by #362 07:42Z) on the Lattice page itself, app only:
//   img08: "Auto/Manual on the Lattice page falls back to Auto every visit. It must keep his choice until Reset." Each new
//          page is a visit (as the stage opens it); Manual's rows are the proof of the mode.
//   img04/05: "Band's caption goes under Band, and each caption is one short line with an (i) for the rest." Measured on the
//          page at 13L and 11P: each line between its own slider and the next row, one line high, at full size.
// The pure parts: IPadNotes1110Tests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class IPadNotes1110HostedTests: XCTestCase {

    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }

    /// The page's control ids (LatticeProbeKey) and the shared parts' frames (FlexibleKeepOutKey: Reset all's ask, as on
    /// the Squish page).
    final class Probe { var all: [String: CGRect] = [:]; var keepOut: [String: CGRect] = [:] }

    @MainActor struct Page {
        let h: AppBuildHost
        let probe: Probe
        var ids: [String: CGRect] {
            probe.all.merging(probe.keepOut) { a, _ in a }.merging(h.frames.all) { a, _ in a }
        }
        @discardableResult func click(_ id: String) -> Bool {
            guard let f = ids[id], f.width > 1 else { return false }
            h.click(CGPoint(x: f.midX, y: f.midY), settle: 0.6)
            return true
        }
    }

    /// His A1 part 3 with a structural lattice (`set` adjusts it).
    func project(_ set: (ProjectModel) -> Void = { _ in }) throws -> ProjectModel {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        set(p)
        return p
    }

    /// One visit: a new Lattice page on `p`, as the stage opens it, on its last view with the area's tab open.
    func visit(_ p: ProjectModel, size: CGSize = AppBuildHost.landscape13) -> Page {
        let pr = Probe()
        let v = LatticeSetupWizard(project: p, onExit: {}).cellsPage(regions: ["Group 1"], closeToken: 0)
            .onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 }
            .onPreferenceChange(FlexibleKeepOutKey.self) { pr.keepOut = $0 }
        let h = AppBuildHost(v, size: size, test: self)
        h.pump(1.2)
        let page = Page(h: h, probe: pr)
        page.click("wizard-stage-\(LatticeWizardStage.allCases.last!.rawValue)")
        page.click("lattice-page-tab-area-0")
        return page
    }

    /// Manual's rows (Density is one: an area's tab shows it in Manual only).
    static let manualRow = "wizard-seg-uniform"

    /// ★ img08: he picks Manual; every later visit opens in Manual — after Save, after Cancel — until Reset all, which puts
    /// Auto back for good.
    func testManualStaysOnEveryVisitUntilResetAll() throws {
        let p = try project()
        var page = visit(p)
        XCTAssertNil(page.ids[Self.manualRow], "premise: a part that never picked opens in Auto")
        XCTAssertTrue(page.click("lattice-page-mode-manual"))
        XCTAssertNotNil(page.ids[Self.manualRow], "premise: Manual shows its rows")

        XCTAssertTrue(page.click("lattice-cells-save"))
        page = visit(p)
        XCTAssertNotNil(page.ids[Self.manualRow], "★ the next visit opens in Manual")
        XCTAssertTrue(page.click("lattice-page-cancel"))
        page = visit(p)
        XCTAssertNotNil(page.ids[Self.manualRow], "★ after Cancel too: his pick is the part's, not a setting of this visit")

        XCTAssertTrue(page.click("lattice-page-reset-all"))
        XCTAssertTrue(page.click("latticeResetConfirm"), "Reset all asks once, in place")
        XCTAssertNil(page.ids[Self.manualRow], "★ Reset all puts Auto back")
        XCTAssertFalse(p.latticePageManual)
        page = visit(p)
        XCTAssertNil(page.ids[Self.manualRow], "★ and the next visit stays in Auto")
    }

    /// ★ img04/05: Band's line under Band and above Strength, Strength's under Strength; each one line, at full size
    /// (a shrunk line's frame is narrower than the line's own width). The octet's band and Organic's, at 13L and 11P.
    func testEachBandCaptionSitsUnderItsOwnSlider() throws {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        func natural(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let cases: [(prefix: String, band: String, set: (ProjectModel) -> Void)] = [
            ("wizard-shape-band", LatticeSetupWizard.shapeBand.brief, { $0.lattice.gradingMode = .full }),
            ("wizard-organic-band", LatticeSetupWizard.organicBand.brief, { $0.lattice.cellTransition = .organicGrade }),
        ]
        for c in cases {
            for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
                let page = visit(try project(c.set), size: size)
                page.click("lattice-page-mode-manual")
                let at = "\(c.prefix) at \(Int(size.width))×\(Int(size.height))"
                let ids = page.ids
                guard let bandSlider = ids["\(c.prefix)-band-slider"], let strengthSlider = ids["\(c.prefix)-strength-slider"] else {
                    XCTFail("premise: \(at): the band's sliders are on the page: \(ids.keys.filter { $0.contains("band") }.sorted())")
                    continue
                }
                let bandLine = try XCTUnwrap(ids["\(c.prefix)-band-note"], "★ \(at): Band has its own line")
                let strengthLine = try XCTUnwrap(ids["\(c.prefix)-strength-note"], "\(at): Strength's line")
                XCTAssertGreaterThanOrEqual(bandLine.minY, bandSlider.maxY - 0.5, "★ \(at): Band's line is under Band")
                XCTAssertLessThanOrEqual(bandLine.maxY, strengthSlider.minY + 0.5, "★ \(at): …and above Strength")
                XCTAssertGreaterThanOrEqual(strengthLine.minY, strengthSlider.maxY - 0.5, "★ \(at): Strength's line is under Strength")
                for (f, text) in [(bandLine, c.band), (strengthLine, LatticeSetupWizard.strengthBrief)] {
                    XCTAssertLessThan(f.height, 20, "★ \(at): one line: \(text)")
                    XCTAssertGreaterThanOrEqual(f.width, natural(text) - 1, "★ \(at): at full size, not shrunk: \(text) (\(f.width) pt)")
                }
            }
        }
    }
}
#endif
