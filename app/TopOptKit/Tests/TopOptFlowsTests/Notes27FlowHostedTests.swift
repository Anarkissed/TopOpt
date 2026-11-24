// Notes27FlowHostedTests — ★ his iPad notes 2026-11-23 ~23:45 EST on release 17 (notes27, builder G "flow27"), hosted at his two
// iPad sizes (13″ landscape, and portrait 820 × 1180):
//   G1 (note 5): the print file's card for a CELL lattice shows the hexagons, Organic's the vines — the same size, in the card.
//   G2 (note 7): after "Show me", a tap on the orange marker raises the same failure pop-up again; the "x" beside it (44 pt,
//      clear of the ring, riding the part with it as the view turns) takes the marker away.
//   G3 (his 11-24 ~00:20): the top-left pill is "‹ Squish Mechanism | Part" — one pill, divided; Part opens the part's versions,
//      Back still goes to the project.
// Model tests, pins and the offscreen render: Notes27FlowTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes27FlowHostedTests: XCTestCase {
    override func tearDownWithError() throws {
        LatticeMacMake.shared.reset()
        LatticePrintFlow.shared.reset()
        AppPopups.shared.current = nil
        LatticeFileSpot.shared.clear()
    }

    static let sizes: [(String, CGSize)] = [("13″ landscape", AppBuildHost.landscape13), ("portrait", CGSize(width: 820, height: 1180))]

    @discardableResult
    private func waitFor(_ h: AppBuildHost, _ key: String, seconds: Double = 10) -> CGRect? {
        var waited = 0.0
        while h.frames.all[key] == nil, waited < seconds { h.pump(0.25); waited += 0.25 }
        return h.frames.all[key]
    }
    private func waitGone(_ h: AppBuildHost, _ key: String, seconds: Double = 10) {
        var waited = 0.0
        while h.frames.all[key] != nil, waited < seconds { h.pump(0.25); waited += 0.25 }
    }

    // MARK: G1 · the card's animation by the lattice kind

    /// ★ "The animation for regular lattices should *show* a regular lattice, and not an organic one": at both of his sizes the
    /// card of a cell lattice's press draws the hexagons (never the vines), Organic's press the vines (never the hexagons) —
    /// each the same 220 × 150, inside the card; and it moves (two looks a moment apart differ: never frozen).
    func testTheCellLatticesCardShowsHexagonsAndOrganicsTheVines() throws {
        for (name, size) in Self.sizes {
            let h = AppBuildHost(DS.Color.background.color.ignoresSafeArea().overlay { LatticeMacMakeModal() }, size: size, test: self)
            h.pump(0.5)
            let mac = LatticeMacMake.shared
            mac.begin(project: UUID(), path: nil, fileOnly: true, kind: .cells, onMac: false, cancel: {})
            let cells = try XCTUnwrap(waitFor(h, "macMakeCells", seconds: 3), "\(name): ★ a cell lattice's card: the hexagons")
            h.pump(0.3)
            XCTAssertNil(h.frames.all["macMakeVines"], "\(name): ★ never the vines")
            let card = try h.onScreen("macMakeModal", "\(name): the card")
            XCTAssertTrue(card.contains(cells), "\(name): inside the card")
            XCTAssertEqual(cells.size, LatticeMacMakeAnimation.size, "\(name): the vines' size")
            let a = try look(h, cells), b: [UInt8]
            h.pump(0.6)
            b = try look(h, cells)
            let drawn = a.contains(where: { $0 > 40 }) || b.contains(where: { $0 > 40 })
            print("NOTES27-G1 hosted \(name): the card's hexagons read offscreen: \(drawn)")
            if drawn { XCTAssertNotEqual(a, b, "\(name): ★ it moves (never frozen)") }
            picture(h, "G1_card_cells_\(Int(size.width))x\(Int(size.height)).png")
            mac.ended()
            h.pump(0.5)
            XCTAssertNil(h.frames.all["macMakeCells"], "\(name): the card gone with its run")

            mac.begin(project: UUID(), path: nil, cancel: {})
            let vines = try XCTUnwrap(waitFor(h, "macMakeVines", seconds: 3), "\(name): ★ Organic's card keeps the vines")
            h.pump(0.3)
            XCTAssertNil(h.frames.all["macMakeCells"], "\(name): ★ never the hexagons")
            XCTAssertEqual(vines.size, cells.size, "\(name): the same size on the card")
            XCTAssertTrue(try h.onScreen("macMakeModal", "\(name): the card").contains(vines), "\(name): inside the card")
            mac.ended()
            h.pump(0.3)
        }
    }

    /// The hosted window as drawn offscreen, to look at (EvidenceOut's "notes27-flow"; the path is printed).
    private func picture(_ h: AppBuildHost, _ file: String) {
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let url = EvidenceOut.dir("notes27-flow").appendingPathComponent(file)
        if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
            print("NOTES27 wrote \(url.path)")
        }
    }

    /// The hosted window's pixels inside `r` (grey levels), or empty where the host draws nothing offscreen.
    private func look(_ h: AppBuildHost, _ r: CGRect) throws -> [UInt8] {
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return [] }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / h.size.width, sy = CGFloat(rep.pixelsHigh) / h.size.height
        var out: [UInt8] = []
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX {
                let c = rep.colorAt(x: Int(x * sx), y: Int(y * sy))
                out.append(UInt8(max(0, min(255, (c?.brightnessComponent ?? 0) * 255))))
                x += 4
            }
            y += 4
        }
        return out
    }

    // MARK: G2 · the marker: its tap reopens the pop-up; its x takes it away

    /// His A1 pad, Structural with cells, on the Lattice stage, the card and the pop-ups mounted as RootView mounts them
    /// (Notes25FlowHostedTests' stage).
    private func cellStage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        if let c = p.selection.groups.first(where: { $0.name == "Group C" }) { p.force.makeAnchor(c.id) }
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p).overlay { LatticeMacMakeModal() }.overlay { AppPopupLayer() },
                             size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        return (h, p)
    }

    private func fileRun(_ p: ProjectModel, failing: Error) {
        p.run.runner = { _, progress, _ in
            var n = 0
            while progress(0, 1, 0), n < 20 { usleep(50_000); n += 1 }
            throw failing
        }
        p.run.start(RunRequest(modelPath: p.importedFile?.path ?? "", material: "PLA", materialsPath: "", rulesPath: "",
                               resolution: 64, projectName: p.name, projectID: p.id).withJobMode(LatticeFileButton.jobMode),
                    remote: true, workerName: "Mac")
    }

    // the page's own camera (its Metal view's orbit gesture target), as FlexibleR7E1ReviewHostedTests reaches it
    private func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    private func cameraModel(_ h: AppBuildHost) -> OrbitCameraModel? {
        let views = mtkViews(h.view).filter { $0.delegate is MeshRenderer }
        guard let mtk = views.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }

    /// ★ "tapping the orange marker should open up the notification again as well as an "x" next to it so that it can be
    /// closed": the cell lattice's print file refused (his bridge), "Show me" pressed — the ring and its x on screen, each a
    /// 44 pt target, the x beside the ring and clear of it. A real tap on the ring raises the SAME pop-up (its title, its reason,
    /// Show me · Change settings · OK); the marker stays. The view turned (orbit and a shift): the ring moves with the part and
    /// the x rides with it, still beside it, still clear. A real tap on the x: the marker gone, no pop-up. RED CONTROL: a
    /// spot marked without its pop-up (release 17's mark) — the ring's tap raises nothing.
    func testTheMarkersTapReopensThePopUpAndItsXClosesIt() throws {
        for (name, size) in Self.sizes {
            AppPopups.shared.current = nil
            let (h, p) = try cellStage(size)
            XCTAssertFalse(LatticeLayoutPreview.organic(p.lattice), "premise: a cell lattice")
            let mac = LatticeMacMake.shared
            LatticePrintFlow.shared.begin(project: p.id, key: nil)
            let run = p.run
            mac.begin(project: p.id, path: p.importedFile?.path, run: run, fileOnly: true, kind: .cells, cancel: { run.cancel() })
            let box = try XCTUnwrap(LatticeLayoutPreview.box(p.importedMesh?.vertices ?? []))
            let top: [Double] = [Double(box.lo.x + box.hi.x) / 2, Double(box.lo.y + box.hi.y) / 2, Double(box.hi.z)]
            let refusal = try XCTUnwrap(LatticeFileRefusal.parse(Notes25FlowTests.refusedReport(at: [top])))
            fileRun(p, failing: LatticeFileRun.Failure(refusal.plain, refusal: refusal))
            var waited = 0.0
            while run.phase == .running, waited < 15 { h.pump(0.25); waited += 0.25 }
            h.pump(1)
            let first = try XCTUnwrap(AppPopups.shared.current, "\(name): premise: the refusal's pop-up")
            XCTAssertEqual(first.title, LatticeMacMakeCopy.failedTitle)
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeFileRefusal.showMe)

            // "Show me" (the pop-up's button: it closes, then runs)
            let showMe = AppPopups.shared.action?.run
            AppPopups.shared.current = nil
            showMe?()
            XCTAssertNotNil(waitFor(h, "latticeFileSpot", seconds: 3), "\(name): Show me: the spot marked")
            XCTAssertNotNil(waitFor(h, "latticeFileSpotClose", seconds: 3), "\(name): ★ the x beside it")
            h.pump(1)
            let ring = try h.probe("latticeFileSpot", "\(name): ★ the ring: a 44 pt target")
            let x = try h.probe("latticeFileSpotClose", "\(name): ★ the x: a 44 pt target")
            XCTAssertFalse(ring.insetBy(dx: 0.5, dy: 0.5).intersects(x), "\(name): ★ the x clear of the ring: \(ring) \(x)")
            XCTAssertLessThanOrEqual(hypot(x.midX - ring.midX, x.midY - ring.midY), 60, "\(name): ★ beside it")
            XCTAssertNil(AppPopups.shared.current, "premise: no pop-up up")
            picture(h, "G2_marker_\(Int(size.width))x\(Int(size.height)).png")

            // ★ the ring tapped (a real tap): the same pop-up again
            try h.tap("latticeFileSpot", "\(name): the marker", settle: 0.8)
            let again = try XCTUnwrap(AppPopups.shared.current, "\(name): ★ the marker's tap raises the pop-up again")
            XCTAssertEqual(again.title, first.title, "\(name): ★ the same title")
            XCTAssertEqual(again.text, refusal.plain, "\(name): ★ the same reason")
            XCTAssertEqual(AppPopups.shared.action?.title, LatticeFileRefusal.showMe, "\(name): ★ the same buttons")
            XCTAssertEqual(AppPopups.shared.second?.title, LatticeFileRefusal.changeSettings)
            XCTAssertEqual(AppPopups.shared.dismissTitle, LatticeFileRefusal.ok)
            XCTAssertNotNil(h.frames.all["appPopup"], "\(name): on screen")
            XCTAssertNotNil(LatticeFileSpot.shared.spot, "\(name): the marker stays")
            // its OK (the pop-up's own dismiss) — closed, the marker still there
            AppPopups.shared.current = nil
            waitGone(h, "appPopup", seconds: 3)
            XCTAssertNotNil(h.frames.all["latticeFileSpot"], "\(name): ★ the marker stays after the pop-up")

            // ★ the view turned: the ring rides the part, the x with it
            let cm = try XCTUnwrap(cameraModel(h), "\(name): the page's camera")
            var c = cm.camera
            c.setOrientation(azimuth: c.azimuth + 0.5, elevation: c.elevation)
            c.target += SIMD3<Float>(Float(box.hi.x - box.lo.x) * 0.15, 0, 0)
            cm.adopt(c)
            h.pump(1.5)
            let ring2 = try h.probe("latticeFileSpot", "\(name): the ring, turned")
            let x2 = try h.probe("latticeFileSpotClose", "\(name): the x, turned")
            XCTAssertGreaterThan(hypot(ring2.midX - ring.midX, ring2.midY - ring.midY), 4, "\(name): ★ the ring moved with the part")
            let o = LatticeFileSpotMarker.closeOffset(at: CGPoint(x: ring2.midX, y: ring2.midY), in: size)
            XCTAssertEqual(x2.midX - ring2.midX, o.dx, accuracy: 1, "\(name): ★ the x rides with it")
            XCTAssertEqual(x2.midY - ring2.midY, o.dy, accuracy: 1, "\(name): ★ the x rides with it")
            XCTAssertFalse(ring2.insetBy(dx: 0.5, dy: 0.5).intersects(x2), "\(name): ★ still clear of the ring")

            // ★ the x tapped (a real tap): the marker gone, no pop-up
            try h.tap("latticeFileSpotClose", "\(name): the x", settle: 0.8)
            waitGone(h, "latticeFileSpot", seconds: 3)
            XCTAssertNil(LatticeFileSpot.shared.spot, "\(name): ★ the x: the marker gone")
            XCTAssertNil(h.frames.all["latticeFileSpot"], "\(name): ★ off the screen")
            XCTAssertNil(h.frames.all["latticeFileSpotClose"], "\(name): ★ its x too")
            XCTAssertNil(AppPopups.shared.current, "\(name): ★ the x raises no pop-up")

            // RED CONTROL: a spot marked with no pop-up kept (release 17's mark) — its tap raises nothing
            LatticeFileSpot.shared.mark(SIMD3<Float>(Float(top[0]), Float(top[1]), Float(top[2])), version: p.id)
            XCTAssertNotNil(waitFor(h, "latticeFileSpot", seconds: 3))
            h.pump(0.5)
            try h.tap("latticeFileSpot", "\(name): RED CONTROL ring", settle: 0.8)
            XCTAssertNil(AppPopups.shared.current, "\(name): RED CONTROL: nothing to raise without the pop-up kept")
            LatticeFileSpot.shared.clear()
            LatticePrintFlow.shared.reset()
            mac.reset()
        }
    }

    // MARK: G3 · ‹ the project | Part

    /// The pill's checks on one page: ‹ Squish Mechanism and Part in ONE pill (drawn 42, as the back pill always was), Part to
    /// the right with one divider between (the stage capsule's: 2 pt, a 1 pt rule, 2 pt), each a 44 pt target, the back where
    /// it always was, the name pill and undo · redo after it, nothing under the view corner.
    private func checkPill(_ h: AppBuildHost, _ what: String) throws {
        let back = try h.probe("backButton", "\(what): ‹ Squish Mechanism, a 44 pt target")
        let part = try h.probe("topLeftPart", "\(what): ★ Part, a 44 pt target")
        let pill = try h.onScreen("topLeftBackPill", "\(what): ★ the one pill")
        XCTAssertEqual(pill.height, TopLeftBlock.height, accuracy: 0.5, "\(what): drawn 42, as before")
        let drawn = pill.insetBy(dx: -0.5, dy: -1.5)
        XCTAssertTrue(drawn.contains(back) && drawn.contains(part), "\(what): ★ both in the one pill: \(back) \(part) in \(pill)")
        XCTAssertEqual(part.minX - back.maxX, 5, accuracy: 0.5, "\(what): ★ Part right of it, one | between (the capsule's divider)")
        XCTAssertEqual(part.midY, back.midY, accuracy: 0.5, "\(what): one line")
        XCTAssertEqual(back.minX, TopLeftBlock.leading, accuracy: 0.5, "\(what): the back where it always was")
        let name = try h.onScreen("topLeftName", "\(what): the name pill")
        let undo = try h.probe("topLeftUndo", "\(what): Undo"), redo = try h.onScreen("topLeftRedo", "\(what): Redo")
        XCTAssertLessThan(pill.maxX, name.minX, "\(what): ★ then the name pill (nothing clipped)")
        XCTAssertLessThan(name.maxX, undo.minX + 1, "\(what): then undo · redo, beside it as before")
        if let pair = h.frames.all["viewPair"] {
            XCTAssertLessThanOrEqual(redo.maxX, pair.minX - 11, "\(what): ★ the row never runs under the view corner")
        }
    }

    /// ★ "add another button to the right of that called "Part" that leads to the list of the versions of the part rather than
    /// all the way back to the project ... making it part of the same pill, but separated with a "|"": his A1 pad grouped into
    /// "Squish Mechanism" (BackTargetHostedTests' Library), the whole app hosted at his two sizes. The pill holds both, divided,
    /// on Topology Setup, Results and the Lattice stage; Part (a real tap) opens the part's own page — its versions, "Open v…"
    /// — never the project's folder; opened again, Back still goes to the project. RED CONTROL: before he groups there is no
    /// part's page, and no Part (the back pill as it was).
    func testThePillIsBackAndPartAndPartOpensThePartsVersions() throws {
        for (name, size) in Self.sizes {
            let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
            let app = r.app, p = r.project
            p.lattice.flexible = nil
            p.lattice.chooseLatticeType(.structural)
            p.run.restoreOutcome(AppBuildFixtures.outcome())
            app.library.refresh()
            try app.library.group(projectName: "Squish Mechanism", partIDs: nil)   // his part, filed in his project
            let part = try XCTUnwrap(app.library.index.part(containing: p.id))
            let project = try XCTUnwrap(app.library.projectOf(part: part.id))
            let h = AppBuildHost(AppBuildRoot(model: app), size: size, test: self)
            h.pump(3)
            XCTAssertEqual(TopLeftBlock.backTitle(app.library, folder: p.id), "Squish Mechanism", "premise: Back says the project")

            try checkPill(h, "\(name) Topology Setup")
            picture(h, "G3_pill_\(Int(size.width))x\(Int(size.height)).png")
            try h.tap("capsuleResults", "\(name): Results", settle: 1.5)
            XCTAssertNotNil(waitFor(h, "resultsExport", seconds: 3), "\(name): premise: Results")
            try checkPill(h, "\(name) Results")
            try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
            h.pump(1.5)
            XCTAssertNotNil(h.frames.all["capsuleLattice"], "\(name): premise: the Lattice stage")
            try checkPill(h, "\(name) Lattice stage")

            // ★ Part: the part's own page, its versions
            try h.tap("topLeftPart", "\(name): Part", settle: 2)
            XCTAssertEqual(app.screen, .home, "\(name): Part left the version")
            XCTAssertEqual(app.library.route, .part(part.id), "\(name): ★ the part's own page")
            XCTAssertNotNil(waitFor(h, "library-open", seconds: 3), "\(name): ★ its versions (\"Open v…\") on screen")
            XCTAssertNotNil(h.frames.all["library-sort"], "\(name): ★ the versions list")
            XCTAssertNil(h.frames.all["libraryFolder-Squish Mechanism"], "\(name): ★ never all the way back to the project")

            // opened again: Back still goes to the project
            try h.tap("library-open", "\(name): Open", settle: 2.5)
            XCTAssertEqual(app.screen, .workspace, "\(name): the version open again")
            XCTAssertNotNil(waitFor(h, "topLeftPart", seconds: 3), "\(name): its Part again")
            try h.tap("backButton", "\(name): ‹ Squish Mechanism", settle: 2)
            XCTAssertEqual(app.screen, .home)
            XCTAssertEqual(app.library.route, .project(project.id), "\(name): ★ Back: the project, as before")
            XCTAssertNotNil(waitFor(h, "libraryFolder-Squish Mechanism", seconds: 3), "\(name): ★ his project's folder")
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // RED CONTROL: not grouped — no part's page, no Part; the back pill is the back alone
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        r.project.lattice.flexible = nil
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: r.project), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        XCTAssertNil(r.app.library.partPage(of: r.project.id), "RED CONTROL: before he groups, no part's page")
        let back = try h.probe("backButton", "RED CONTROL: Back")
        XCTAssertNil(h.frames.all["topLeftPart"], "RED CONTROL: ★ no Part before he groups")
        let pill = try h.onScreen("topLeftBackPill", "RED CONTROL: the pill")
        XCTAssertEqual(pill.width, back.width, accuracy: 0.5, "RED CONTROL: the back pill is the back alone, as it was")
    }
}
#endif
