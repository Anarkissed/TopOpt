// FlexibleR7D2ReviewHostedTests — round 7, the review of R7-D2, the hosted half: the WHOLE page (WorkspacePlaceholder) on HIS
// pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm), the lattice built, at img1's camera, at 13" and 11"
// in both orientations. Written BEFORE the fixes (the red run: round7/batch_d2_review/d2r_red_run.txt).
//   R1  the (i) opened from chip M never covers the chip
//   R3  the (i)'s numbers lie inside the lattice legend's span (the Flexible lattice drawn at Face 3)
//   R9  chip M's automatic spot keeps off Face 3's own outline
//   R6  a renamed group's delete question never widens the 348 pt list; every trash stays inside it
//   R2  with Play on, the Load's message and the delete's [Undo] never sit on the player
//   R8  a number box takes a click 5 pt outside its 32 pt look (a 44 pt target)
//   S6' with Face 3 picked (chip, leader, handles, edge light all drawn), a click on an empty point reaches what is under the
//       layer; a click on the chip does not (the positive control)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class D2RHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7D2ReviewHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = D2RHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func click(_ h: Host, _ p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }
    func press(_ h: Host, _ key: String, _ what: String) throws {
        let f = try XCTUnwrap(h.frames.all[key], "no frame '\(key)' for \(what)")
        click(h, CGPoint(x: f.midX, y: f.midY))
    }
    func pageView(_ v: NSView) -> MTKView? {
        var all: [MTKView] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView, m.delegate is MeshRenderer, !m.isHidden { all.append(m) }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        guard let maxA = all.map({ $0.bounds.width * $0.bounds.height }).max() else { return nil }
        return all.first { $0.bounds.width * $0.bounds.height >= maxA - 1 }
    }
    /// img1's camera on the page's own orbit model (as the evidence probes do).
    @discardableResult
    func setCam(_ h: Host, _ cam: Cam) -> Bool {
        guard let v = pageView(h.view) else { return false }
        for g in v.gestureRecognizers {
            guard let t = g.target else { continue }
            var mirror: Mirror? = Mirror(reflecting: t)
            while let mm = mirror {
                if let c = mm.children.first(where: { $0.label == "cameraModel" })?.value as? OrbitCameraModel {
                    var cc = c.camera
                    cc.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
                    c.adopt(cc)
                    pump(1.5)
                    return true
                }
                mirror = mm.superclassMirror
            }
        }
        return false
    }

    /// His pad on the Flexible stage, hosted, the lattice built.
    func flexibleStage(_ size: CGSize, lattice: Bool) throws -> (ProjectModel, Host, FlexibleMainStage, FlexibleStageModel, UUID) {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        let m = try XCTUnwrap(s.model, "the stage's model")
        s.faceUI.toastSeconds = 120
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        if lattice {
            XCTAssertTrue(pumpUntil(420) { m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight && m.lattice != nil },
                          "premise: his lattice is built")
            pump(2)
            XCTAssertTrue(setCam(h, Self.img1), "premise: img1's camera")
        }
        return (p, h, s, m, c)
    }

    // MARK: R1 · R3 · R9 · R6 · R2 at one size

    func run(_ tag: String, _ size: CGSize) throws {
        let (p, h, s, m, c) = try flexibleStage(size, lattice: true)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)

        // R9 — chip M's automatic spot keeps off Face 3's own outline
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.5)
        let chip = try XCTUnwrap(h.frames.all["faceChip"], "\(tag): chip M")
        let outline = try XCTUnwrap(h.frames.all["faceOutline"], "\(tag): Face 3's outline on screen")
        // the chrome always wins; the face is kept clear wherever a spot clear of both exists (the oracle: the let-go's own
        // search over the whole screen, from where the chip is)
        let chrome = ["capsule", "setupChip", "latticeSplit", "legendCard", "selectionsList"].compactMap { h.frames.all[$0] }
            + [FlexibleLegendPlacement.gizmoFrame(viewport: size), FlexibleMainViewToggles.frame(viewport: size)]
            + [s.legendCard(viewport: size, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame].compactMap { $0 }
        // the picked face's own handles (each disc and its box) are the chip's keep-outs too — in the oracle as well
        let handles = h.frames.all.filter { $0.key.hasPrefix("numberBox-handle-") }.map { CGRect(x: $0.value.minX - 52, y: $0.value.midY - 22, width: $0.value.width + 52, height: 44) }
        for k in chrome { XCTAssertFalse(chip.intersects(k), "★ R9 \(tag): the chip is not on the chrome (\(chip) vs \(k))") }
        let visible = outline.intersection(CGRect(origin: .zero, size: size))
        let column = FlexibleFaceChipLayout.selectionsColumn(viewport: size)
        let clear = FlexibleFaceChipLayout.released(chip, viewport: size, keepOut: chrome + handles + [column, outline])
        if !visible.isNull, visible.width * visible.height < 0.45 * size.width * size.height,
           !FlexibleFaceChipLayout.hits(clear, chrome + handles + [column, outline]) {
            XCTAssertFalse(chip.intersects(outline), "★ R9 \(tag): a spot off the face exists (\(clear)) — the chip keeps off the face it edits (\(chip) vs \(outline))")
        }

        // R1 — the chip's (i): its card below the chip, never on it
        try press(h, "info-c-" + r3.key, "Face 3's (i) on the chip")
        pump(1)
        let card = try XCTUnwrap(h.frames.all["statsCard"], "\(tag): the (i)'s card")
        let chipNow = try XCTUnwrap(h.frames.all["faceChip"])
        XCTAssertFalse(card.intersects(chipNow), "★ R1 \(tag): the (i)'s card is not on the chip (\(card) vs \(chipNow))")
        XCTAssertTrue(card.minX >= -0.5 && card.maxX <= size.width + 0.5 && card.minY >= -0.5 && card.maxY <= size.height + 0.5, "\(tag): on screen")

        // R3 — the (i)'s numbers: the Flexible lattice drawn at Face 3, inside the legend's span
        let ends = try XCTUnwrap(s.latticeEnds(), "\(tag): the lattice legend")
        if let rows = s.faceStats(r3, group: c, project: p), let rho = rows.rho, let cell = rows.cellMM {
            XCTAssertTrue(rho >= ends.span.lowerBound - 1e-6 && rho <= ends.span.upperBound + 1e-6,
                          "★ R3 \(tag): the (i)'s density \(rho) lies inside the legend's \(ends.span) (\(ends.lo) … \(ends.hi))")
            let g = try XCTUnwrap(m.lattice)
            let cells = [FlexibleProbe.drawnCell(rho: ends.span.lowerBound, g.inputs).mm, FlexibleProbe.drawnCell(rho: ends.span.upperBound, g.inputs).mm]
            XCTAssertTrue(cell >= cells.min()! - 0.05 && cell <= cells.max()! + 0.05, "★ R3 \(tag): the (i)'s cell \(cell) lies inside the legend's \(cells)")
            XCTAssertNotNil(h.frames.all["statsCard"], "the card shows them")
            print("FLEX-R7D2R-R3 \(tag) (i) \(rows.rows.map { "\($0.label) \($0.value)" }) · legend \(ends.lo) … \(ends.hi)")
        } else {
            XCTFail("★ R3 \(tag): no numbers for Face 3 from his drawn lattice")
        }
        s.faceUI.info = nil
        pump(0.5)
        // the list's (i): beside the list, off it and off the chip
        s.pickGroup(c, project: p)
        pump(1)
        try press(h, "info-l-" + r3.key, "Face 3's (i) in the list")
        pump(1)
        if let listCard = h.frames.all["statsCard"], let list = h.frames.all["selectionsList"] {
            XCTAssertFalse(listCard.intersects(list), "★ R1 \(tag): the list's (i) card is off the list (\(listCard) vs \(list))")
            if let g = h.frames.all["faceChip"] { XCTAssertFalse(listCard.intersects(g), "★ R1 \(tag): and off the chip (\(listCard) vs \(g))") }
        } else { XCTFail("\(tag): the list's (i) card") }
        s.faceUI.info = nil
        pump(0.5)

        // R6 — a renamed group's delete question never widens the list
        FlexibleFaceCommits.rename(c, to: "Left side squeeze pad", project: p)
        s.pickGroup(c, project: p)
        pump(1)
        s.askDelete(c)
        pump(1)
        let list = try XCTUnwrap(h.frames.all["selectionsList"], "\(tag): the list")
        XCTAssertNotNil(h.frames.all["deleteConfirm"], "premise: the question is up")
        XCTAssertLessThanOrEqual(list.width, PageChrome.panelWidth + 0.5, "★ R6 \(tag): the list stays 348 pt wide (\(list.width))")
        for (k, f) in h.frames.all where k.hasPrefix("selTrash-") {
            XCTAssertLessThanOrEqual(f.maxX, list.maxX + 0.5, "★ R6 \(tag): \(k) inside the list")
        }
        s.faceUI.deleteAsk = nil
        s.askDelete(c, inChip: true)
        pump(1)
        let chipAsk = try XCTUnwrap(h.frames.all["faceChip"])
        XCTAssertLessThanOrEqual(chipAsk.width, FlexibleFaceChipLayout.width + 0.5, "★ R6 \(tag): the chip keeps its width with the question")
        s.faceUI.deleteAsk = nil
        FlexibleFaceCommits.rename(c, to: "Group C", project: p)
        pump(0.5)

        // R2 — Play on: the messages never sit on the player
        s.togglePlay()
        XCTAssertTrue(pumpUntil(90) { h.frames.all["playerCapsule"] != nil }, "premise \(tag): the player shows with Play on")
        s.tapFace(p, face: 2, point: nil, mesh: mesh)
        pump(1.2)
        s.commitNew(.load, project: p) {}
        XCTAssertTrue(pumpUntil(3) { h.frames.all["toast"] != nil }, "\(tag): the Load's message")
        pump(0.6)
        func clearOfPlayer(_ what: String) throws {
            let t = try XCTUnwrap(h.frames.all["toast"], "\(tag): \(what)")
            for k in ["playerCapsule", "playerTopRow", "playerNote"] {
                if let f = h.frames.all[k] { XCTAssertFalse(t.intersects(f), "★ R2 \(tag): \(what) is not on the player's \(k) (\(t) vs \(f))") }
            }
            if let u = h.frames.all["toastUndo"], let f = h.frames.all["playerCapsule"] {
                XCTAssertFalse(u.intersects(f), "★ R2 \(tag): [Undo] is not on the player's track")
            }
            XCTAssertTrue(t.minY >= 0 && t.maxY <= size.height, "\(tag): on screen")
        }
        try clearOfPlayer("the Load's message")
        s.faceUI.toast = nil
        pump(0.4)
        s.askDelete(c)
        s.confirmDelete(project: p) {}
        XCTAssertTrue(pumpUntil(3) { h.frames.all["toastUndo"] != nil }, "\(tag): the delete's [Undo]")
        pump(0.6)
        try clearOfPlayer("the delete's message")
        s.undoDelete(project: p) {}
        pump(0.6)
        print("FLEX-R7D2R \(tag) chip \(chip) · outline \(outline) · card \(card) · list \(list)")
    }

    func testTheReviewFindingsOnHisPad13Portrait() throws { try run("13p", CGSize(width: 1032, height: 1376)) }
    func testTheReviewFindingsOnHisPad13Landscape() throws { try run("13l", CGSize(width: 1376, height: 1032)) }
    func testTheReviewFindingsOnHisPad11Portrait() throws { try run("11p", CGSize(width: 834, height: 1194)) }
    func testTheReviewFindingsOnHisPad11Landscape() throws { try run("11l", CGSize(width: 1194, height: 834)) }

    // MARK: R8 — a 44 pt target around the 32 pt box

    func testANumberBoxTakesATapAcross44Points() throws {
        let (p, h, s, _, c) = try flexibleStage(CGSize(width: 1032, height: 1376), lattice: false)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        s.pickGroup(c, project: p)
        pump(1.2)
        let box = try XCTUnwrap(h.frames.all["numberBox-list-depth-\(r3.key)"], "Face 3's depth box in the list")
        XCTAssertEqual(box.height, FlexNumberBox.height, accuracy: 0.5, "the box still looks 32 pt tall")
        click(h, CGPoint(x: box.midX, y: box.minY - 5))
        XCTAssertEqual(s.faceUI.padTarget, "list-depth-\(r3.key)", "★ R8: a click 5 pt above the box opens its keypad (a 44 pt target)")
        s.faceUI.padTarget = nil
        pump(0.5)
        click(h, CGPoint(x: box.midX, y: box.maxY + 5))
        XCTAssertEqual(s.faceUI.padTarget, "list-depth-\(r3.key)", "★ R8: and 5 pt below it")
        s.faceUI.padTarget = nil
    }

    // MARK: S6' — hit-transparent with a face picked

    func testTheLayerPassesTapsThroughWithAFacePicked() throws {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let size = CGSize(width: 1032, height: 1376)
        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        cam.setOrientation(azimuth: Self.img1.azimuth, elevation: Self.img1.elevation)
        let projection = CameraProjection(camera: cam, viewportSize: size)
        let s = FlexibleMainStage()
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: .face(group: c, face: 3)), "premise: Face 3 picked")
        final class Hits { var n = 0 }
        let hits = Hits()
        let v = ZStack {
            Button { hits.n += 1 } label: { Color.gray.frame(width: size.width, height: size.height) }.buttonStyle(.plain)
            FlexibleOnModelLayer(main: s, project: p, projection: projection, settle: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)),
                                 bottomClearance: FlexibleChromeLayout.barClearance, cards: [:], groupCards: [:], cardsChanged: {})
        }
        let h = host(v, size: size)
        pump(1.2)
        let chip = try XCTUnwrap(h.frames.all["faceChip"], "★ chip M is drawn")
        let depthBox = try XCTUnwrap(h.frames.all["numberBox-handle-depth-\(LatticeSelectableRef.face(group: c, face: 3).key)"], "★ the depth handle is drawn")
        let outline = try XCTUnwrap(h.frames.all["faceOutline"], "★ the edge light is drawn")
        // an empty point: off the chip, the handles and the leader's dot
        let empty = [CGPoint(x: 40, y: size.height - 40), CGPoint(x: size.width - 40, y: 40), CGPoint(x: 40, y: 40)]
            .first { !chip.insetBy(dx: -30, dy: -30).contains($0) && !depthBox.insetBy(dx: -60, dy: -30).contains($0) }!
        click(h, empty)
        XCTAssertEqual(hits.n, 1, "★ S6': a click on an empty point of the layer reaches what is under it, with Face 3 picked (\(empty))")
        // a click across the edge light (drawn, hit-transparent) reaches it too
        click(h, CGPoint(x: outline.midX, y: outline.minY + 1))
        if !chip.contains(CGPoint(x: outline.midX, y: outline.minY + 1)) && !depthBox.insetBy(dx: -30, dy: -30).contains(CGPoint(x: outline.midX, y: outline.minY + 1)) {
            XCTAssertEqual(hits.n, 2, "★ S6': the edge light takes no touch")
        }
        let before = hits.n
        // positive control: the chip itself takes its touches
        click(h, CGPoint(x: chip.midX, y: chip.minY + 6))
        XCTAssertEqual(hits.n, before, "positive control: a click on the chip stays on the chip")
    }
}
#endif
