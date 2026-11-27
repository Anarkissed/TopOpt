// FlexibleSetupRowsHostedTests — B9 Flexible Setup (ledger 39, R2-Q2, N2; the reviewer's ruling 11-10 21:38Z, (C)): the B6
// face rows on the Flexible page's own list, on HIS pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5, 25 mm), the
// whole page (WorkspacePlaceholder), at 13" landscape and 11" portrait.
//   * a picked group shows one Lattice Setup face row per face and its "All 2" row, inside the panel;
//   * a tap opens a face a little: its depth becomes the NumberField (its pad is the page's one keypad slot, the handle's box
//     on the part its twin), its Expand line and "This face [Lattice │ No lattice │ Off]", each choice writing the face;
//   * the face's eye hides that face's prism and its handle on the part, and shows them again;
//   * with the rows' words ("No lattice" too, the reviewer's ruling 11-11 (1)(a)) the chip at the face keeps its width.
// The rule the stage row reads (Print plan): PrintPlanVisibilityTests. The chip's words alone: FaceChipWordTests.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class SetupRowsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleSetupRowsHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var said: [String] = []; var fits: [UUID: FlexibleFit] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static let sizes = [CGSize(width: 1376, height: 1032), CGSize(width: 834, height: 1194)]

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleSaidKey.self) { frames.said = $0 }        // only while a test records (FlexibleSaid)
            .onPreferenceChange(FlexibleFitKey.self) { frames.fits = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = SetupRowsWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func frame(_ h: Host, _ key: String, _ what: String) throws -> CGRect {
        try XCTUnwrap(h.frames.all[key], "no frame '\(key)' for \(what): \(h.frames.all.keys.filter { $0.hasPrefix("flexSetup") || $0.hasPrefix("numberField") }.sorted())")
    }

    /// His pad on the Flexible page, Group C picked.
    func page(_ size: CGSize) throws -> (ProjectModel, Host, FlexibleMainStage, UUID) {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        try FlexiblePressFixtures.enterLatticeStage(p, click: { click(h, $0) })
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        if let m = s.model { addTeardownBlock { @MainActor in await m.waitForIdle() } }
        s.faceUI.toastSeconds = 120
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        s.pickGroup(c, project: p)
        pump(1.2)
        return (p, h, s, c)
    }

    /// Where a click lands on one segment of a small SegmentedGlass (its words at 12 pt, 10 pt each side, 2 apart, 3 in).
    static func segmentCentre(_ f: CGRect, labels: [String], at i: Int) -> CGPoint {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 20 }
        let x = f.minX + 3 + w.prefix(i).reduce(0, +) + CGFloat(i) * 2 + w[i] / 2
        return CGPoint(x: x, y: f.midY)
    }

    /// ★ The face rows: Lattice Setup's, on the Flexible list; a tap opens one with its numbers and its role.
    func testAPickedFaceOpensLikeLatticeSetup() throws {
        for size in Self.sizes {
            let at = "\(Int(size.width))×\(Int(size.height))"
            let (p, h, s, c) = try page(size)
            let r3 = LatticeSelectableRef.face(group: c, face: 3), r5 = LatticeSelectableRef.face(group: c, face: 5)
            let list = try frame(h, "selectionsList", "\(at): the Selections")
            for key in ["flexSetupAll-\(c.uuidString)", "flexSetupFace-\(r3.key)", "flexSetupFace-\(r5.key)"] {
                let f = try frame(h, key, "\(at): ★ a B6 row")
                XCTAssertTrue(f.minX >= list.minX - 0.5 && f.maxX <= list.maxX + 0.5, "★ \(at): \(key) inside the panel (\(f) in \(list))")
                XCTAssertGreaterThanOrEqual(f.height, DSParts.rowHeight - 0.5, "\(at): \(key) a 48 pt row")
            }
            XCTAssertNil(h.frames.all["numberField-list-depth-\(r3.key)"], "\(at): a face not picked shows its depth as words")

            // ★ a tap on the row (its name) opens it
            let row3 = try frame(h, "flexSetupFace-\(r3.key)", "\(at): Face 3's row")
            click(h, CGPoint(x: row3.minX + 70, y: row3.midY))
            XCTAssertEqual(FlexibleFacePick.validated(s.facePick, project: p).scope, .face(group: c, ref: r3), "★ \(at): the tap picks Face 3")
            let depth = try frame(h, "numberField-list-depth-\(r3.key)", "\(at): ★ Face 3's depth NumberField")
            let expand = try frame(h, "flexSetupFaceExpand-\(r3.key)", "\(at): ★ Face 3's Expand line")
            _ = try frame(h, "numberField-list-expand-\(r3.key)", "\(at): ★ its Expand NumberField")
            let roleSeg = try frame(h, "flexSetupFaceRole-\(r3.key)", "\(at): ★ This face [Lattice │ No lattice │ Off]")
            _ = try frame(h, "flexSetupFace-\(r3.key)-line", "\(at): ★ 'Or drag its handle on the part'")
            for (k, f) in [("depth", depth), ("expand", expand), ("role", roleSeg)] {
                XCTAssertTrue(f.minX >= list.minX - 0.5 && f.maxX <= list.maxX + 0.5, "★ \(at): Face 3's \(k) inside the panel (\(f) in \(list))")
            }

            // ★ the depth's pad is the page's one keypad slot — the handle's box on the part is its twin
            click(h, CGPoint(x: depth.midX, y: depth.midY))
            XCTAssertEqual(s.faceUI.padTarget, "list-depth-\(r3.key)", "★ \(at): its pad opens in the page's one slot")
            s.faceUI.padTarget = nil
            pump(0.6)

            // ★ This face: Off, No lattice, Lattice — each written to the face
            let labels = [LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.off]
            click(h, Self.segmentCentre(roleSeg, labels: labels, at: 1))
            XCTAssertEqual(p.latticeSelectableRole(r3, in: c), .exclude, "★ \(at): No lattice")
            let roleSeg2 = try frame(h, "flexSetupFaceRole-\(r3.key)", "\(at): This face, still open")
            click(h, Self.segmentCentre(roleSeg2, labels: labels, at: 2))
            XCTAssertNil(p.latticeSelectableRole(r3, in: c), "★ \(at): Off")
            XCTAssertNil(h.frames.all["numberField-list-depth-\(r3.key)"], "\(at): an Off face has no depth to set")
            XCTAssertNil(h.frames.all["flexSetupFaceEye-\(r3.key)"], "\(at): …and no prism, so no eye")
            let roleSeg3 = try frame(h, "flexSetupFaceRole-\(r3.key)", "\(at): This face, still open")
            click(h, Self.segmentCentre(roleSeg3, labels: labels, at: 0))
            XCTAssertEqual(p.latticeSelectableRole(r3, in: c), .include, "★ \(at): Lattice again")

            // a tap on the open row closes it to its group
            let open = try frame(h, "flexSetupFace-\(r3.key)", "\(at): Face 3's row, open")
            click(h, CGPoint(x: open.minX + 70, y: open.minY + DSParts.rowHeight / 2))
            XCTAssertEqual(FlexibleFacePick.validated(s.facePick, project: p).scope, .group(c), "\(at): the open row closes to its group")
        }
    }

    /// ★ N2 / R2-Q2: the face row's eye hides that face's prism and its handle on the part — and shows them again.
    func testTheEyeHidesThatFacesPrismAndItsHandle() throws {
        let (p, h, s, c) = try page(Self.sizes[0])
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        s.pickFace(r3, group: c, project: p)
        pump(1.5)
        XCTAssertEqual(s.pickedPlaneKeys(p), [r3.key], "premise: Face 3 picked, its prism drawn")
        XCTAssertFalse(s.pickedPlanes(p).isEmpty, "premise: its handle's plane")
        let drawn = s.facePrismItems(p, picked: s.pickedPlaneKeys(p), all: true).count
        XCTAssertNotNil(h.frames.all["handleDisc-handle-depth-\(r3.key)"], "premise: its depth handle on the part")
        let eye = try frame(h, "flexSetupFaceEye-\(r3.key)", "Face 3's eye")
        XCTAssertGreaterThanOrEqual(min(eye.width, eye.height), 43.5, "the eye is a 44 pt target")

        click(h, CGPoint(x: eye.midX, y: eye.midY))
        XCTAssertEqual(s.prismEye[r3.key], false, "★ the eye shut")
        XCTAssertEqual(s.pickedPlaneKeys(p), [], "★ its prism is not drawn")
        XCTAssertTrue(s.pickedPlanes(p).isEmpty, "★ …nor its handle's plane")
        XCTAssertLessThan(s.facePrismItems(p, picked: s.pickedPlaneKeys(p), all: true).count, drawn, "★ under [Prisms] too, its prism is gone")
        XCTAssertNil(h.frames.all["handleDisc-handle-depth-\(r3.key)"], "★ its handle is gone from the part")
        XCTAssertEqual(p.latticeSelectableRole(r3, in: c), .include, "a view pick: the face is still Lattice")

        let eye2 = try frame(h, "flexSetupFaceEye-\(r3.key)", "Face 3's eye, shut")
        click(h, CGPoint(x: eye2.midX, y: eye2.midY))
        XCTAssertEqual(s.pickedPlaneKeys(p), [r3.key], "★ open again: its prism")
        XCTAssertNotNil(h.frames.all["handleDisc-handle-depth-\(r3.key)"], "★ …and its handle")
    }

    /// ★ The reviewer's ruling 11-11 02:28Z (1)(a), on his pad: the chip at the face says the rows' words ("No lattice" where
    /// it said "Solid"), each drawn whole, keeps its width and its 80 pt segments, and its No lattice writes what the row's does.
    /// The words come from FlexibleSaid (a test process builds no SwiftUI accessibility tree).
    /// (Corrected after the green run, our own new test: it read the word from the page's accessibility tree, which is empty.)
    func testTheChipAtTheFaceKeepsItsWidth() throws {
        FlexibleSaid.recording = true
        FlexibleSaid.measuring = true
        defer { FlexibleSaid.recording = false; FlexibleSaid.measuring = false }
        for size in Self.sizes {
            let at = "\(Int(size.width))×\(Int(size.height))"
            let (p, h, s, c) = try page(size)
            let r3 = LatticeSelectableRef.face(group: c, face: 3)
            let mesh = try XCTUnwrap(p.viewerMesh, "\(at): his part")
            s.tapFace(p, face: 3, point: nil, mesh: mesh)
            pump(1.5)
            XCTAssertEqual(FlexibleFacePick.validated(s.facePick, project: p).scope, .face(group: c, ref: r3), "premise \(at): Face 3 picked")
            let chip = try XCTUnwrap(h.frames.all["faceChip"], "premise \(at): chip M at Face 3")
            let seg = try XCTUnwrap(h.frames.all["chipSeg-exclude"], "\(at): the chip's middle segment")
            XCTAssertLessThanOrEqual(chip.width, FlexibleFaceChipLayout.width + 0.5, "★ \(at): the chip keeps its width (\(chip.width))")
            XCTAssertTrue(chip.insetBy(dx: -0.5, dy: -0.5).contains(seg), "★ \(at): the segment sits inside the chip (\(seg) in \(chip))")
            XCTAssertEqual(seg.width, FaceChip.segmentWidth, accuracy: 0.5, "\(at): the segment keeps its 80 pt")
            XCTAssertTrue(h.frames.said.contains(LatticeSetupCopy.noLattice), "★ \(at): the chip says No lattice")
            XCTAssertFalse(h.frames.said.contains("Solid"), "★ \(at): no Solid on the page")
            let words: Set<String> = [LatticeSetupCopy.lattice, LatticeSetupCopy.noLattice, LatticeSetupCopy.off]
            let measured = h.frames.fits.values.filter { words.contains($0.text) && $0.actual != nil && $0.ideal != nil }
            XCTAssertTrue(measured.contains { $0.text == LatticeSetupCopy.noLattice }, "\(at): No lattice measured on the page")
            for f in measured {
                XCTAssertTrue(f.whole, "★ \(at): '\(f.text)' drawn whole (drawn \(f.actual ?? 0) of \(f.ideal ?? 0))")
            }

            click(h, CGPoint(x: seg.midX, y: seg.midY))
            XCTAssertEqual(p.latticeSelectableRole(r3, in: c), .exclude, "★ \(at): the chip's No lattice is the row's")
        }
    }

    /// The list's numbers are the app's one NumberField (B2, U11), never Flexible's older box.
    func testTheListsNumbersAreTheOneNumberField() throws {
        let src = try String(contentsOf: FlexibleHisProject.repoRoot
            .appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/FlexibleSelectionsList.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("FlexNumberBox("), "★ no FlexNumberBox in the list")
        XCTAssertTrue(src.contains("NumberField(key: key"), "★ the NumberField")
    }
}
#endif
