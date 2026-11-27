// LatticePageNotes1123Tests — ★ his iPad notes 2026-11-23 (img 3, the Lattice page's 40 mm cube sample):
//   "The background of the sample should expand to the rest of the screen behind everything - rather than just stopping and
//    having a black bar on top and on the left side."
//   "The named Group names on the left side has too small an area. Please allow the left column to expand automatically a
//    little bit so that it doesn't feel crowded"
// In the real page at his two sizes, with his group names ("Front face", "Back Wall").
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class LatticePageNotes1123Tests: XCTestCase {
    override nonisolated func setUp() { super.setUp(); FlexibleSaid.recording = true }
    override nonisolated func tearDown() { FlexibleSaid.recording = false; super.tearDown() }
    final class Probe { var all: [String: CGRect] = [:] }

    override func tearDownWithError() throws {
        LatticePageColumns.controlFixedColumn = false
        LatticeSampleView.controlWholeView = false
    }

    /// His A1 pad on Aesthetic, two lattice groups named as his ("Front face", "Back Wall"), the Lattice page open on Cells.
    private func page(_ size: CGSize) throws -> (AppBuildHost, Probe, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.aesthetic)
        let pr = Probe()
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).onPreferenceChange(LatticeProbeKey.self) { pr.all = $0 },
                             size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Aesthetic", what: "\(size): the stage menu")
        let faces = p.selection.groups.compactMap(\.faces.first)
        for (f, name) in zip(faces.prefix(2), ["Front face", "Back Wall"]) {
            var l = p.latticeList; l.clearActive(); p.latticeList = l
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID {
                p.lattice.groupRoles[g] = .include
                var l2 = p.latticeList; l2.rename(g, to: name); p.latticeList = l2
            }
        }
        p.lattice.enabled = true
        h.pump(1)
        try h.tap("capsuleSetup", "\(size): Setup, the settings", settle: 1.5)
        if let c = pr.all["wizard-stage-\(LatticeWizardStage.cell.rawValue)"] ?? h.frames.all["wizard-stage-\(LatticeWizardStage.cell.rawValue)"] {
            h.click(CGPoint(x: c.midX, y: c.midY), settle: 1)
        }
        h.pump(1)
        return (h, pr, p)
    }

    private func seen(_ h: AppBuildHost, _ pr: Probe, _ id: String) -> CGRect? {
        (pr.all[id] ?? h.frames.all[id]).flatMap { $0.width > 1 ? $0 : nil }
    }

    /// ★ The sample's view fills the whole page — under the panel and the top rows, edge to edge (no black bar on top or on
    /// the left) — and its picture is drawn in the part the panel leaves free. RED CONTROL: the picture framed in the whole view.
    func testTheSampleFillsTheWholePageBehindEverything() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, pr, _) = try page(size)
            let sample = try XCTUnwrap(seen(h, pr, "lattice-sample-cells") ?? seen(h, pr, "lattice-sample-part"), "\(size): the sample")
            XCTAssertEqual(sample.minX, 0, accuracy: 0.5, "\(size): ★ no bar on the left")
            XCTAssertEqual(sample.minY, 0, accuracy: 0.5, "\(size): ★ no bar on top")
            XCTAssertEqual(sample.width, size.width, accuracy: 0.5, "\(size): ★ edge to edge")
            XCTAssertEqual(sample.height, size.height, accuracy: 0.5, "\(size): ★ top to bottom")
            let panel = try XCTUnwrap(h.frames.all["latticeSettingsPanel"], "\(size): the panel over it")
            let r = try XCTUnwrap(LatticeSampleView.recordedRegion, "\(size): ★ the picture drawn in the free part")
            let portrait = size.width < size.height
            if portrait {
                XCTAssertEqual(CGFloat(r.y) * size.height, panel.maxY, accuracy: 24, "\(size): ★ under the panel")
                XCTAssertEqual(r.x, 0, accuracy: 0.01)
            } else {
                XCTAssertEqual(CGFloat(r.x) * size.width, panel.maxX, accuracy: 2, "\(size): ★ right of the panel")
                XCTAssertEqual(CGFloat(r.y) * size.height, PageChrome.panelTop, accuracy: 1, "\(size): ★ under the top rows")
            }
            XCTAssertEqual(r.z, 1, accuracy: 0.001); XCTAssertEqual(r.w, 1, accuracy: 0.001)
            let caption = try XCTUnwrap(seen(h, pr, "lattice-sample-caption"), "\(size): the sample's line")
            if !portrait { XCTAssertGreaterThan(caption.minX, panel.maxX, "\(size): ★ its line in the free part, never under the panel") }
        }
        // the region is the camera's: a view of that size, placed there (the floor runs on to the edges)
        var cam = OrbitCamera(target: .zero)
        cam.frameRegion = SIMD4(0.4, 0.1, 1, 1)
        let p = cam.projectionMatrix(aspect: 1.5) * cam.viewMatrix() * SIMD4<Float>(cam.target, 1)
        XCTAssertEqual(p.x / p.w, 0.4 + 1 - 1, accuracy: 1e-4, "★ the model's centre at the free part's middle (x)")
        XCTAssertEqual(p.y / p.w, 1 - (0.1 + 1), accuracy: 1e-4, "★ (y)")
        LatticeSampleView.controlWholeView = true
        let (h, pr, _) = try page(AppBuildHost.landscape13)
        _ = try XCTUnwrap(seen(h, pr, "lattice-sample-cells") ?? seen(h, pr, "lattice-sample-part"))
        XCTAssertNil(LatticeSampleView.recordedRegion, "RED CONTROL: framed in the whole view (under the panel)")
    }

    /// ★ The left column widens by itself to its names ("Front face" on one line), up to its most; the panel widens with it so
    /// the settings keep their room. RED CONTROL: the 62 pt column, "Front face" on two lines.
    func testTheLeftColumnWidensToItsNames() throws {
        XCTAssertEqual(LatticePageColumns.tabsWidth(["Part"]), DSParts.tabsWidth, "short names: as before")
        XCTAssertEqual(LatticePageColumns.tabsWidth([String(repeating: "Wide name ", count: 8)]), LatticePageColumns.tabsMost,
                       "★ a sensible most (a longer name wraps)")
        let key = LatticeSetupWizard.latticeTabsKey
        for control in [true, false] {
            LatticePageColumns.controlFixedColumn = control
            for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
                let (h, _, p) = try page(size)
                let column = try h.onScreen("\(key)-column", "\(size): the left column")
                let panel = try h.onScreen("latticeSettingsPanel", "\(size): the panel")
                let front = try XCTUnwrap(p.latticeAreaGroups.firstIndex { $0.name == "Front face" }, "his Front face")
                let title = try h.onScreen("\(key)-area-\(front)-title", "\(size): \"Front face\"")
                let oneLine = LatticePageColumns.textWidth("Front face", size: LatticePageColumns.titleSize)
                if control {
                    XCTAssertEqual(column.width, DSParts.tabsWidth, accuracy: 0.5, "\(size): RED CONTROL: 62 pt")
                    XCTAssertGreaterThan(title.height, 20, "\(size): RED CONTROL: crowded onto two lines")
                } else {
                    XCTAssertGreaterThan(column.width, DSParts.tabsWidth + 1, "\(size): ★ wider for his names")
                    XCTAssertLessThanOrEqual(column.width, LatticePageColumns.tabsMost + 0.5)
                    XCTAssertLessThan(title.height, 20, "\(size): ★ \"Front face\" on one line")
                    XCTAssertGreaterThanOrEqual(column.width - 2 * 6 - 2 * 4, oneLine, "\(size): with room to spare")
                    XCTAssertEqual(panel.width, PageChrome.widePanelWidth + column.width - DSParts.tabsWidth, accuracy: 1,
                                   "\(size): ★ the panel widens with it (the settings keep their room)")
                    XCTAssertLessThan(panel.maxX, size.width - 100, "\(size): the panel still leaves the sample room")
                }
            }
        }
    }
}
#endif
