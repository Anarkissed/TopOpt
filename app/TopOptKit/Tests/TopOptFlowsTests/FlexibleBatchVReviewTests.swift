// FlexibleBatchVReviewTests — round 6, batch V's review (2026-10-10): the verifier's confirmed findings, each as a test with
// its red control, on HIS pad (A1_0003, restored as he saved it). Part of FlexibleBatchVHostedTests (its hosting and helpers).
//   VR1 (★ RE-PINNED by R7-V: the toggle is gone — his 2026-10-14 words) the main page's model shows no Selections colour
//       at HIS camera (img1), in the Model view and his Lattice view, by the shipping renderer (the ticked case, fixed).
//   VR2 "Prism after a pick": an Undo or a Redo re-writes the selection (ProjectModel.applyEditSnapshot, an equal write as
//       often as not) — it was counted as his pick. RED CONTROL: `controlUndoIsAPick`. Positive control: re-tapping the
//       active row still counts.
//   VR3 m19: a reading's TAG (not only its point) stays out of the chrome — tapped just left of the legend, its squircle
//       covered the legend. RED CONTROL: `FlexibleReadingCallout.controlPointOnly`.
//   VR4 m19: the depth chip, the tags, the discs, the stamp's handle and the curve's points keep out of the WHOLE chrome (the
//       fix pop-up, the top line, the Exit row, the gizmo), not only the panel, the legend, the view buttons and the player.
//       RED CONTROL: the old keep-out (`stageKeepOut`) shows a chip under the pop-up.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

extension FlexibleBatchVHostedTests {

    // MARK: - VR1: "Role colours off", unticked, shows #354's colours where he looks

    /// One frame of the main page's model by the shipping renderer (the page's mesh, tints, dents, body alpha) at his img1
    /// camera — BGRA8, 900 × 900.
    func mainFrame(_ s: FlexibleMainStage, _ p: ProjectModel, roles: [FaceID: SIMD4<Float>], device: MTLDevice,
                   name: String) throws -> [UInt8] {
        s.refresh()
        let probe = FlexibleRound6EvidenceProbe()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let img1 = FlexibleRound6Tests.Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
        let mr = try probe.renderer(mesh: mesh, tints: s.tints(p, on: .lattice, roles: roles, stress: nil),
                                    dents: s.dents(p, on: .lattice), scale: Float(s.channels?.exaggeration ?? 1),
                                    bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: img1, device: device, items: [])
        if let dir = Self.dir {
            setenv("FLEX_R6_EVIDENCE_DIR", dir.path, 1)
            try probe.write(mr, name)
            unsetenv("FLEX_R6_EVIDENCE_DIR")
        }
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: FlexibleRound6EvidenceProbe.size,
                                                clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    /// Pixels (BGRA8) whose HUE is the role colour's: the chroma (rgb minus its mean) pointing the role's way (cos ≥ 0.97) and
    /// strong enough to read as colour (≥ 0.06), whatever the lighting does to its brightness.
    static func hued(_ px: [UInt8], like c: SIMD4<Float>) -> Int {
        let rc = SIMD3<Float>(c.x, c.y, c.z), rm = (rc.x + rc.y + rc.z) / 3, rd = rc - SIMD3(repeating: rm)
        let rn = simd_length(rd)
        guard rn > 1e-3 else { return 0 }
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let p = SIMD3<Float>(Float(px[i + 2]), Float(px[i + 1]), Float(px[i])) / 255
            let m = (p.x + p.y + p.z) / 3, d = p - SIMD3(repeating: m), dn = simd_length(d)
            if dn >= 0.06, simd_dot(d, rd) / (dn * rn) >= 0.97 { n += 1 }
        }
        return n
    }

    /// Pixels (BGRA8) whose largest channel differs by more than `t` (of 255).
    static func frameDiffering(_ a: [UInt8], _ b: [UInt8], threshold t: Int = 12) -> Int {
        guard a.count == b.count else { return -1 }
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            if d > t { n += 1 }
        }
        return n
    }

    /// ★ RE-PINNED (R7-V — his 2026-10-14 words: "All view buttons should be icons - never full words. Remove the two full
    /// worded view icons. I've decided against them.", and his answer: NO Selections role colours on the main page's model):
    /// batch V review's VR1 measured "Role colours off" UNTICKED (#354's colours where he looks); the toggle is gone, so only
    /// its TICKED case is kept — fixed. At his img1 camera, by the shipping renderer: no Top blue, no Anchor green, in the
    /// Model view and his Lattice view (heat off), whatever roles H4 hands over. (The roles' red control is
    /// FlexibleRound7ViewsTests.testTheMainPageModelWearsNoRoleColourWhateverRolesAreHandedOver.)
    func testTheMainPageModelShowsNoSelectionsColourAtHisCamera() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let s = mainStage()
        let (r, m) = try his(s)
        let p = r.project
        s.apply(p, owned: true, pageUp: false)
        m.selectedRegion = nil
        s.stress = false
        let roles = Self.roleTints(p)
        let topInk = try XCTUnwrap(roles[1], "premise: the Top (face 1) wears the Top's colour")
        let bottomInk = try XCTUnwrap(roles[0], "premise: the Bottom (face 0) wears the Anchor's colour")
        var lines: [String] = []
        for (name, lattice, xray) in [("model_heatOff", false, false), ("lattice_heatOff", true, true)] {
            s.latticeOn = lattice; s.xrayOn = xray; s.heat = false
            let frame = try mainFrame(s, p, roles: roles, device: device, name: "BVR_roles_\(name)_fixed.png")
            let t = (Self.hued(frame, like: topInk), Self.hued(frame, like: bottomInk))
            XCTAssertEqual(t.0, 0, "★ \(name): no Top colour on the model")
            XCTAssertEqual(t.1, 0, "★ \(name): no Anchor / Group C green")
            lines.append("\(name): Top blue / Anchor green px \(t.0) / \(t.1)")
        }
        print("FLEX-BVR-1 (fixed, R7-V) " + lines.joined(separator: " · "))
    }

    // MARK: - VR2: an Undo / Redo is never his pick

    func testAnUndoOrRedoIsNeverAPick() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.selection.setActive(top.id)   // the Top active as the project opens (V1b's setup)
        let s = mainStage()
        _ = settledModel(p, stage: s)
        s.apply(p, owned: true, pageUp: false)
        func prisms() -> [Int] { s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID) }
        // (★ R7-V: "Prism after a pick" is no longer a setting — fixed ON by his 2026-10-14 answer; this test is otherwise
        // carried over unchanged)
        XCTAssertFalse(s.sessionPicked)
        XCTAssertEqual(prisms(), [], "on open: nothing")
        // an edit that is not a pick (the Top's weight, on the main page), sealed as one undo step
        let kg = p.force.kind(for: top.id).weightKg ?? 10
        p.force.setWeight(top.id, kg: kg + 2)
        p.sealUndoStep()
        XCTAssertTrue(p.undo.canUndo, "premise: an undo step")
        XCTAssertFalse(s.sessionPicked, "an edit is not a pick")
        p.performUndo()
        XCTAssertEqual(p.force.kind(for: top.id).weightKg, kg, "premise: the undo restored the weight")
        XCTAssertFalse(s.sessionPicked, "★ an Undo re-writes the selection — never his pick")
        XCTAssertEqual(prisms(), [], "★ …so no prism shows")
        p.performRedo()
        XCTAssertFalse(s.sessionPicked, "★ nor a Redo")
        XCTAssertEqual(prisms(), [])
        pump(0.6)   // (past the stage's project debounce)
        XCTAssertFalse(s.sessionPicked)
        // ★ RED CONTROL: batch V as built — the Undo's equal write counted as a pick, the Top's prism shown
        s.controlUndoIsAPick = true
        p.performUndo()
        let controlPicked = s.sessionPicked, controlPrisms = prisms()
        XCTAssertTrue(controlPicked, "★ RED CONTROL: batch V counted the Undo as his pick")
        XCTAssertEqual(controlPrisms, [1], "★ RED CONTROL: …and showed the Top's prism")
        s.controlUndoIsAPick = false
        s.sessionPicked = false
        // ★ POSITIVE CONTROL: right after an Undo, his tap on the active row (#354's equal write) is still a pick
        p.performRedo()
        XCTAssertFalse(s.sessionPicked)
        p.selection.setActive(top.id)
        XCTAssertTrue(s.sessionPicked, "his re-tap on the Top's row is a pick")
        XCTAssertEqual(prisms(), [1], "…and the Top's prism shows")
        // the classifier itself: a commit is never an Undo or a Redo, even one that clears a single undone step
        var h = UndoHistory(depth: 50)
        let a = p.editSnapshot
        var b = a; b.force.setWeight(top.id, kg: kg + 5)
        h.reset(to: a)
        let h0 = h
        XCTAssertNotEqual(b, a, "premise")
        h.commit(b)
        XCTAssertFalse(FlexibleMainStage.isUndoOrRedo(from: h0, to: h), "a commit")
        let h1 = h
        _ = h.undo()
        XCTAssertTrue(FlexibleMainStage.isUndoOrRedo(from: h1, to: h), "an Undo")
        let h2 = h
        _ = h.redo()
        XCTAssertTrue(FlexibleMainStage.isUndoOrRedo(from: h2, to: h), "a Redo")
        _ = h.undo()
        let h3 = h
        var c2 = a; c2.force.setWeight(top.id, kg: kg + 7)
        h.commit(c2)
        XCTAssertEqual(h.future.count + 1, h3.future.count, "premise: a commit that clears one undone step (by the counts, a Redo)")
        XCTAssertFalse(FlexibleMainStage.isUndoOrRedo(from: h3, to: h), "…is a commit: the baseline is not the undone state")
        print("FLEX-BVR-2 undo/redo: picked false, prisms [] · control (batch V): picked \(controlPicked), prisms \(controlPrisms) · re-tap: picked true")
    }

    // MARK: - VR3: a reading's tag never reaches into the chrome

    func testAReadingsTagNeverReachesIntoTheChrome() throws {
        addTeardownBlock { @MainActor in FlexibleReadingCallout.controlPointOnly = false }
        let size = CGSize(width: 600, height: 600)
        let box = FlexibleProjectionBox()
        box.projection = CameraProjection(viewProjection: matrix_identity_float4x4, viewportSize: size)
        let reading = FlexibleReading(kind: .dent, value: "12.4", unit: "mm", fraction: 0.6, anchor: SIMD3<Float>(0, 0, 0))
        let s = try XCTUnwrap(box.projection?.project(reading.anchor))
        XCTAssertEqual(s.x, 300, accuracy: 0.5); XCTAssertEqual(s.y, 300, accuracy: 0.5)
        // the legend 40 pt right of the point (he tapped just left of it), a far one, and none
        let near = CGRect(x: s.x + 40, y: s.y - 90, width: 220, height: 180)
        let far = CGRect(x: s.x + 200, y: s.y - 90, width: 80, height: 180)
        final class Box: ObservableObject { @Published var reading: FlexibleReading? }
        struct Page: View {
            @ObservedObject var model: Box
            let proj: FlexibleProjectionBox
            let clip: [CGRect]
            var body: some View {
                ZStack(alignment: .topLeading) {
                    Color.black
                    FlexibleReadingCallout(proj: proj, reading: model.reading, clip: clip)
                }
                .frame(width: 600, height: 600)
            }
        }
        func pixels(_ clip: [CGRect], control: Bool) throws -> (inside: Int, anywhere: Int) {
            FlexibleReadingCallout.controlPointOnly = control
            let model = Box()
            let h = host(Page(model: model, proj: box, clip: clip), size: size)
            pump(0.3)
            let none = try shot(h)
            model.reading = reading
            pump(0.5)
            let with = try shot(h)
            let inside = clip.first.map { Self.differing(with, none, in: $0) } ?? 0
            return (inside, Self.differing(with, none, in: CGRect(origin: .zero, size: size)))
        }
        let free = try pixels([], control: false)
        XCTAssertGreaterThan(free.anywhere, 200, "positive control: with no chrome the tag draws")
        let clear = try pixels([far], control: false)
        XCTAssertGreaterThan(clear.anywhere, 200, "a legend clear of the tag: the tag draws")
        XCTAssertEqual(clear.inside, 0)
        let fixed = try pixels([near], control: false)
        XCTAssertEqual(fixed.inside, 0, "★ the tag would reach into the legend: nothing of it shows there")
        let control = try pixels([near], control: true)
        XCTAssertGreaterThan(control.inside, 200, "★ RED CONTROL (batch V: the point alone tested): the tag covers the legend")
        // the rule itself: the whole frame, not the point
        let tag = CGSize(width: 90, height: 2 * FlexibleReadingTag.halfHeight)
        XCTAssertFalse(FlexibleReadingCallout.clear(anchor: s, size: tag, clip: [near]))
        XCTAssertTrue(FlexibleReadingCallout.clear(anchor: s, size: tag, clip: [far]))
        XCTAssertFalse(FlexibleReadingCallout.clear(anchor: s, size: nil, clip: [far]), "unmeasured: never over any chrome")
        print("FLEX-BVR-3 reading 40 pt left of the legend: inside the legend \(fixed.inside) px (control, point only: \(control.inside)) · "
              + "no chrome \(free.anywhere) px drawn · far legend \(clear.anywhere) px drawn, \(clear.inside) inside")
    }

    // MARK: - VR4: the chip, tags, discs and handles keep out of the WHOLE chrome

    func testTheOverlayViewsKeepOutOfTheWholeChrome() throws {
        let v = CGSize(width: 1194, height: 834 - 44)
        let page = CGRect(x: 0, y: 24, width: v.width, height: v.height)
        let stage = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let popup = CGRect(x: 300, y: 120, width: 420, height: 110)
        let frames: [String: CGRect] = ["page": page, "stage": stage,
                                        "panel": CGRect(x: 24, y: 300, width: 400, height: 500),
                                        "legend": CGRect(x: 900, y: 500, width: 260, height: 120),
                                        "popup": popup, "exitRow": CGRect(x: 24, y: 40, width: 226, height: 44)]
        let underPopup = CGPoint(x: popup.midX, y: popup.midY)
        let clip = FlexibleStagePage.chromeClip(frames, viewport: v)
        XCTAssertFalse(FlexibleDepthChipLayout.shows(underPopup, dragging: false, keepOut: clip, viewport: stage.size),
                       "★ a chip under the fix pop-up is hidden (the whole chrome)")
        XCTAssertTrue(FlexibleDepthChipLayout.shows(underPopup, dragging: false, keepOut: FlexibleStagePage.stageKeepOut(frames), viewport: stage.size),
                      "★ RED CONTROL (batch V: the keep-outs only): it showed over the pop-up")
        XCTAssertTrue(FlexibleDepthChipLayout.shows(CGPoint(x: 700, y: 400), dragging: false, keepOut: clip, viewport: stage.size),
                      "positive control: a chip clear of the chrome shows")
        // the page hands the whole chrome to every view drawn on the part (the chip, the tags and discs, the stamp's handle,
        // the curves' points and their ×) — the red control (`controlOverlaysOverChrome`) hands the keep-outs, as before
        let src = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(src.contains("exaggeration: FlexibleStageVolumes.prismK(dentExaggeration), keepOut: clip ?? keepOut,"),
                      "the overlays' keep-out is the chrome clip")
    }
}
#endif
