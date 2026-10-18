// FlexibleRound7SelectionsHostedTests — round 7, batch R7-D2 (Selections, his mockup pick 2), the hosted half: the WHOLE app
// page (WorkspacePlaceholder) offscreen on HIS pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm) at 13" and
// 11" portrait. Written BEFORE the code (red run: round7/batch_d2/d2_red_run.txt).
//   S1  the list replaces #354's card on the Flexible stage (H25); a tap on Face 3 (H22's call) opens chip M; a tap on Face 4
//       then opens chip N with the FILLED "Add to Group C as lattice", and a click on it joins Face 4 to Group C as lattice at
//       25 mm — the chip stays; the chip never sits on a keep-out (the list, the capsule, the corner pair, the legend)
//   S2  the trash asks first; [Delete] removes Group C (here and for Topology); the message's [Undo] brings it back
//   S3  the handle's number box: it reads the list's number; a click opens the keypad slot
//   S4  the (i) on the list's face line opens his four numbers
//   S5  the chip is dragged: it stays where he let it go (for that face), the leader follows
//   S6  the layer is hit-transparent: a click on an empty point of it reaches what is underneath
// (The part is drawn by Metal; a model tap is H22's call — the page's onPickPoint hands it to `flexibleMain.tapFace` — made
// directly, as the earlier hosted tests do. Frames come from FlexibleKeepOutKey.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class D2HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7SelectionsHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

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
        let w = D2HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func event(_ h: Host, _ t: NSEvent.EventType, _ p: CGPoint) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }
    func click(_ h: Host, _ p: CGPoint) {
        event(h, .leftMouseDown, p); pump(0.06)
        event(h, .leftMouseUp, p); pump(0.8)
    }
    func press(_ h: Host, _ key: String, _ what: String) throws {
        let f = try XCTUnwrap(h.frames.all[key], "no frame '\(key)' for \(what)")
        click(h, CGPoint(x: f.midX, y: f.midY))
    }
    func drag(_ h: Host, from a: CGPoint, to b: CGPoint) {
        event(h, .leftMouseDown, a); pump(0.05)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            event(h, .leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); pump(0.03)
        }
        event(h, .leftMouseUp, b); pump(0.8)
    }

    /// His pad on the Flexible stage: the page hosted, Topology's top-right button to the lattice stage.
    func flexibleStage(_ size: CGSize) throws -> (FlexibleHisProject.Restored, Host, FlexibleMainStage, UUID) {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(4)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        addTeardownBlock { @MainActor in await s.model?.waitForIdle() }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        return (r, h, s, c)
    }

    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11p", CGSize(width: 834, height: 1194))]

    // MARK: S1

    func testTheListTheChipAndTheFilledJoinButton() throws {
        for (tag, size) in Self.sizes {
            let (r, h, s, c) = try flexibleStage(size)
            let p = r.project
            let mesh = try XCTUnwrap(p.viewerMesh)
            XCTAssertNotNil(h.frames.all["selectionsList"], "★ \(tag) H25: the B1 list in #354's panel slot")
            XCTAssertNotNil(h.frames.all["selGroup-\(c.uuidString)"], "\(tag): Group C's quiet line")
            XCTAssertNotNil(h.frames.all["selTrash-\(c.uuidString)"], "★ \(tag): a trash on the group line")
            s.tapFace(p, face: 3, point: nil, mesh: mesh)
            pump(1.2)
            let chipM = try XCTUnwrap(h.frames.all["faceChip"], "★ \(tag): chip M at Face 3")
            XCTAssertNotNil(h.frames.all["info-c-" + LatticeSelectableRef.face(group: c, face: 3).key], "★ \(tag): the chip's (i)")
            s.tapFace(p, face: 4, point: nil, mesh: mesh)
            pump(1.2)
            let chipN = try XCTUnwrap(h.frames.all["faceChip"], "★ \(tag): chip N at Face 4")
            let join = try XCTUnwrap(h.frames.all["chipJoin"], "★ \(tag): the join button (Group C was picked earlier)")
            XCTAssertGreaterThanOrEqual(join.height, 44, "★ \(tag): ≥ 44 pt tall")
            XCTAssertGreaterThan(join.width, chipN.width * 0.8, "★ \(tag): full width — a button, not a title")
            for k in FlexibleNewFaceKind.allCases { XCTAssertNotNil(h.frames.all["chipNew-\(k.rawValue)"], "\(tag): [\(k)]") }
            // the chip clear of its keep-outs at the auto placement
            for (name, key) in [("the list", "selectionsList"), ("the capsule", "capsule"), ("the Setup chip", "setupChip"),
                                ("the Lattice button", "latticeSplit"), ("the legend", "legendCard")] {
                if let k = h.frames.all[key] { XCTAssertFalse(k.intersects(chipN), "★ \(tag): the chip is not on \(name) (\(k) vs \(chipN))") }
            }
            _ = chipM
            try press(h, "chipJoin", "Add to Group C as lattice")
            let r4 = LatticeSelectableRef.face(group: c, face: 4)
            XCTAssertEqual(p.selection.groups.first { $0.id == c }?.faces.contains(4), true, "★ \(tag): Face 4 joined Group C")
            XCTAssertEqual(p.latticeSelectableRole(r4, in: c), .include, "★ \(tag): as lattice")
            XCTAssertEqual(p.latticeSlabDepthMM(r4, in: c), 25, accuracy: 1e-9, "★ \(tag): at 25 mm")
            XCTAssertEqual(s.facePick.scope, .face(group: c, ref: r4), "★ \(tag): the chip stays, on Face 4 of Group C")
            print("FLEX-R7D2-S1 \(tag) chip M \(chipM) · chip N \(chipN) · join \(join)")
        }
    }

    // MARK: S2

    func testTheTrashAsksFirstAndUndoBringsTheGroupBack() throws {
        let (r, h, s, c) = try flexibleStage(Self.sizes[0].1)
        let p = r.project
        try press(h, "selTrash-\(c.uuidString)", "Group C's trash")
        XCTAssertEqual(s.faceUI.deleteAsk, c, "★ the trash asks first")
        XCTAssertNotNil(p.selection.groups.first { $0.id == c }, "nothing deleted yet")
        try press(h, "deleteConfirm", "[Delete]")
        XCTAssertNil(p.selection.groups.first { $0.id == c }, "★ [Delete]: Group C gone (here and for Topology)")
        _ = pumpUntil(3) { h.frames.all["toastUndo"] != nil }
        try press(h, "toastUndo", "the message's [Undo]")
        XCTAssertNotNil(p.selection.groups.first { $0.id == c }, "★ [Undo]: Group C is back")
        XCTAssertEqual(p.latticeSlabDepthMM(.face(group: c, face: 3), in: c), 25, accuracy: 1e-9, "with its depth")
    }

    // MARK: S3 + S4

    func testTheHandlesNumberIsTheListsAndTheInfoOpensHisFour() throws {
        let (r, h, s, c) = try flexibleStage(Self.sizes[0].1)
        let p = r.project
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        s.tapFace(p, face: 3, point: nil, mesh: try XCTUnwrap(p.viewerMesh))
        pump(1.5)
        let handleBox = try XCTUnwrap(h.frames.all["numberBox-handle-depth-\(r3.key)"], "★ the depth handle's number box")
        let listBox = try XCTUnwrap(h.frames.all["numberBox-list-depth-\(r3.key)"], "★ the list's box for Face 3")
        XCTAssertGreaterThan(handleBox.height, 0); XCTAssertGreaterThan(listBox.height, 0)
        click(h, CGPoint(x: handleBox.midX, y: handleBox.midY))
        XCTAssertEqual(s.faceUI.padTarget, "handle-depth-\(r3.key)", "★ a click on the handle's number opens the keypad")
        s.faceUI.padTarget = nil
        pump(0.5)
        try press(h, "info-l-\(r3.key)", "Face 3's (i) in the list")
        XCTAssertEqual(s.faceUI.info?.ref, r3, "★ the (i) opened for Face 3")
        pump(0.5)
        XCTAssertNotNil(h.frames.all["statsCard"], "★ his four numbers' card")
    }

    // MARK: S5

    func testADraggedChipStaysWhereHeLetsGo() throws {
        let (r, h, s, _) = try flexibleStage(Self.sizes[0].1)
        let p = r.project
        s.tapFace(p, face: 4, point: nil, mesh: try XCTUnwrap(p.viewerMesh))
        pump(1.2)
        let before = try XCTUnwrap(h.frames.all["faceChip"])
        let grip = CGPoint(x: before.midX, y: before.minY + 8)
        drag(h, from: grip, to: CGPoint(x: grip.x - 120, y: grip.y + 160))
        let after = try XCTUnwrap(h.frames.all["faceChip"])
        XCTAssertGreaterThan(hypot(after.minX - before.minX, after.minY - before.minY), 60, "★ the chip moved with the drag")
        XCTAssertNotNil(s.faceUI.spots[s.facePick.scope.chipKey ?? ""], "★ its spot is kept for that face")
    }

    // MARK: S6

    func testTheLayerIsHitTransparent() throws {
        let p = ProjectModel(id: UUID(), name: "Pad", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice.flexible = FlexibleStageSettings()
        let s = FlexibleMainStage()
        var hits = 0
        let v = ZStack {
            Button { hits += 1 } label: { Color.gray.frame(width: 1032, height: 1376) }.buttonStyle(.plain)
            FlexibleOnModelLayer(main: s, project: p, projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)),
                                 bottomClearance: 88, cards: [:], groupCards: [:], cardsChanged: {})
        }
        let h = host(v, size: CGSize(width: 1032, height: 1376))
        pump(0.5)
        click(h, CGPoint(x: 500, y: 700))
        XCTAssertEqual(hits, 1, "★ a click on an empty point of the layer reaches what is under it (orbit and pinch survive)")
    }
}
#endif
