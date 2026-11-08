// FacePrismDragHostedTests — B6 N2 (his go 11-05, "Yes, start B6"; plan.md B6: "The face's prism shows with an end handle;
// the row's eye shows or hides that face's prism … FacePrismDragHostedTests (drag the end → the number changes, and the
// reverse)"; design-system §4.24; ledger N2 and row 28; mockup #lat-face-prism, #lat-face-depth-type, #lat-prisms-eye).
// His words (N2): "there should always be a way to drag out the face-prisms manually. This should change the depth value …
// where it says '31mm'. Selecting that face should open it up … It should also *show/hide* the face-prism associated to the
// face."
//
// On the fixture pad (ParityTopologyShots' pad) on Structural, Group 1 holding three faces as Lattice. A picked face row's
// prism shows, lit, with the one 44 pt handle at its end and its number beside it; dragging the handle out deepens the face
// and the row's number follows; typing a depth moves the handle. Each face row has an eye that shows or hides that face's
// prism (no longer the face). A synthesised drag never reaches a gesture in an offscreen window (FlexibleR7U21CHandlesHosted-
// Tests' finding), so the drag drives the very closure the handle's gesture calls, as the page last built it.
//
// RED before (saved: scratchpad b2red/LatticeHandles_build.txt): no LatticeSetupHandles; the picked face had no handle, only
// today's 22 pt knob on every latticed face, and its row no eye.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class FacePrismDragHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { LatticeSetupHandles.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.litThrough = []
            LatticeSetupHandles.livePick = nil
            LatticeSetupHandles.latticeTinted = []
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    /// The fixture pad on Structural; Group 1 (the Lattice stage's own) holds three faces — the first from his Top — as
    /// Lattice, saved (the prisms are a saved lattice's), open.
    func stage(_ size: CGSize = AppBuildHost.landscape13) throws -> (AppBuildHost, ProjectModel, SelectionGroup) {
        LatticeSetupHandles.live = [:]
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        let others = Set(mesh.faceIDs).subtracting(top.faces).sorted()
        for f in top.faces.prefix(1) + others.prefix(2) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        // ★ NO lattice saved (his iPad, 11-06: the prisms and zones must show before Save — the first cut set this true and
        // so never saw a Box zone draw nothing)
        XCTAssertFalse(p.lattice.enabled, "premise: no lattice saved yet")
        let g = try XCTUnwrap(p.latticeGroups.first, "Group 1")
        p.latticeList.setActive(g.id)
        h.pump(1)
        return (h, p, g)
    }

    private func faceRefs(_ p: ProjectModel, _ g: SelectionGroup) -> [LatticeSelectableRef] {
        p.latticeSelectableRefs(g).filter { if case .face = $0 { return true }; return false }
    }

    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// Drive the handle `key`'s own drag closure out by `along` points in `steps` moves, the page redrawing between them,
    /// then release — as a finger would.
    private func drag(_ h: AppBuildHost, _ key: String, along: CGFloat, steps: Int = 12) throws {
        for i in 1...steps {
            let live = try XCTUnwrap(LatticeSetupHandles.live[key], "★ the page built the handle '\(key)'")
            live.drag(along * CGFloat(i) / CGFloat(steps), false)
            h.pump(0.05)
        }
        try XCTUnwrap(LatticeSetupHandles.live[key]).drag(along, true)
        h.pump(0.8)
    }

    /// ★ N2 + §4.24, re-pinned to his iPad notes of 11-07 (1a: "only the ± EXPAND knobs show … NO depth handle at a prism's
    /// end"; 3a: prisms "must all be VISIBLE by default"): with the group open and nothing picked, every face's prism shows
    /// with its end handle beside its expand knob, no number; a picked face row lights its prism, its handle wears its number
    /// and a line says so — and dragging the handle out deepens the face, under the finger.
    func testAPickedFaceShowsItsPrismAndDraggingItsEndSetsTheDepth() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            let refs = faceRefs(p, g)
            let ref = try XCTUnwrap(refs.first, "a face")
            let key = LatticeSetupHandles.prismKey(ref)
            for r in refs {
                XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(r.key), "\(size): ★ 3a — nothing picked, \(r.key)'s prism shows")
                _ = try h.onScreen("handle-\(LatticeSetupHandles.prismKey(r))", "\(size): ★ 1a — \(r.key)'s end handle, with the group open")
                _ = try h.onScreen("latticeExpandKnob-\(r.key)", "\(size): beside its expand knob")
            }
            XCTAssertTrue(h.frames.all.keys.filter { $0.hasPrefix("handleValue-prism-") }.isEmpty, "\(size): nothing picked: no number on the part")
            try h.tap("latticeFace-\(ref.key)", "\(size): the face's row", settle: 1)
            XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(ref.key), "\(size): ★ picked: its prism shows (no lattice saved)")
            XCTAssertEqual(LatticeSetupHandles.litThrough, [ref.key], "\(size): ★ lit through the part, it alone")
            let handle = try h.probe("handle-\(key)", "\(size): ★ N2 — the prism's end handle, a 44 pt target",
                                     covers: ["selectionsList"])
            let pill = try h.onScreen("handleValue-\(key)", "\(size): its number beside it")
            XCTAssertEqual(pill.midY, handle.midY, accuracy: 1, "\(size): the number rides beside the handle")
            _ = try h.onScreen("latticeFace-\(ref.key)-line", "\(size): ★ the row's line: \(LatticeSetupCopy.dragItsHandle)")
            XCTAssertEqual(h.frames.all.keys.filter { $0.hasPrefix("handleValue-prism-") && $0 != "handleValue-\(key)" }.count, 0,
                           "\(size): ★ one number on the part: the picked face's")
            // ★ the picked face's expand knob (his 11-06 shots: at 11" portrait it sat on the Role row's lock, over the panel):
            // clear of the page's panel and of the prism's handle and its number
            let knob = try h.onScreen("latticeExpandKnob-\(ref.key)", "\(size): the picked face's expand knob")
            let list = try XCTUnwrap(h.frames.all["selectionsList"], "the Selections panel")
            XCTAssertFalse(list.intersects(knob.insetBy(dx: 0.5, dy: 0.5)), "\(size): ★ the expand knob is not on the panel: \(knob) vs \(list)")
            XCTAssertFalse(handle.union(pill).intersects(knob.insetBy(dx: 0.5, dy: 0.5)),
                           "\(size): ★ the expand knob is clear of the prism's handle and its number: \(knob)")

            let axis = try XCTUnwrap(LatticeSetupHandles.live[key]).axis
            let d0 = p.latticeSlabDepthMM(ref, in: g.id)
            try drag(h, key, along: 60)
            let d1 = p.latticeSlabDepthMM(ref, in: g.id)
            XCTAssertGreaterThan(d1, d0 + 0.5, "\(size): ★ dragged out, the face lattices deeper (\(d0) → \(d1) mm)")
            let moved = try h.onScreen("handle-\(key)", "\(size): the handle after the drag")
            let travel = (moved.midX - handle.midX) * axis.dx + (moved.midY - handle.midY) * axis.dy
            XCTAssertGreaterThan(travel, 30, "\(size): ★ the end stays under the finger (it moved \(travel) pt of 60)")
            XCTAssertNil(h.padFrame("numberPad"), "\(size): a drag opens no pad")
        }
    }

    /// ★ 1a: an unpicked face's handle drags its depth too (no number beside it while it rests).
    func testAnUnpickedFacesHandleSetsItsDepth() throws {
        let (h, p, g) = try stage()
        let ref = try XCTUnwrap(faceRefs(p, g).last, "a face")
        let key = LatticeSetupHandles.prismKey(ref)
        _ = try h.probe("handle-\(key)", "★ its end handle, a 44 pt target", covers: ["selectionsList"])
        XCTAssertNil(h.frames.all["handleValue-\(key)"], "at rest: no number on the part")
        let d0 = p.latticeSlabDepthMM(ref, in: g.id)
        try drag(h, key, along: 60)
        XCTAssertGreaterThan(p.latticeSlabDepthMM(ref, in: g.id), d0 + 0.5, "★ dragged out, that face lattices deeper")
    }

    /// ★ The reverse (plan.md B6): the row's number and the handle are one value — typing a depth moves the handle back
    /// along its axis, and the number beside it says it.
    func testTypingTheDepthMovesTheHandle() throws {
        let (h, p, g) = try stage()
        let ref = try XCTUnwrap(faceRefs(p, g).first)
        let key = LatticeSetupHandles.prismKey(ref)
        p.writeLatticeDepthMM(ref, mm: 12)
        h.pump(0.5)
        try h.tap("latticeFace-\(ref.key)", "the face's row", settle: 1)
        let before = try h.onScreen("handle-\(key)", "the handle at 12 mm")
        let axis = try XCTUnwrap(LatticeSetupHandles.live[key]).axis
        try h.tap("numberField-latticeFaceDepth-\(ref.key)", "★ its depth, the number field")
        _ = try XCTUnwrap(h.padFrame("numberPad"), "★ a tap opens the app's pad")
        try h.padTap("numberPad-key-4", "4")
        try h.padTap("numberPad-done", "Done")
        h.pump(0.8)
        XCTAssertEqual(p.latticeSlabDepthMM(ref, in: g.id), 4, accuracy: 1e-6, "★ typed: 4 mm")
        let after = try h.onScreen("handle-\(key)", "the handle at 4 mm")
        let travel = (after.midX - before.midX) * axis.dx + (after.midY - before.midY) * axis.dy
        XCTAssertLessThan(travel, -2, "★ the handle comes back toward the face (\(travel) pt along its axis)")
    }

    /// ★ N2, re-pinned to 3a: each face row's eye shows or hides THAT face's prism — never the face or its group; shown by
    /// default, its eye hides it with its handle; picked, a hidden prism stays hidden until its eye shows it again.
    func testTheEyeShowsOrHidesTheFacesPrism() throws {
        let (h, p, g) = try stage()
        let refs = faceRefs(p, g)
        XCTAssertGreaterThanOrEqual(refs.count, 2, "premise: two faces")
        let a = refs[1], hk = "handle-\(LatticeSetupHandles.prismKey(a))"
        _ = try h.probe("latticeFaceEye-\(a.key)", "★ the face row's eye, a 44 pt target")
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(a.key), "★ 3a: shown by default")
        _ = try h.onScreen(hk, "★ 1a: with its handle")
        try h.tap("latticeFaceEye-\(a.key)", "its eye")
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(a.key), "★ the eye hides its prism")
        XCTAssertFalse(p.groupView.isHidden(g.id), "★ it hides no group")
        XCTAssertNil(h.frames.all[hk], "★ and its handle with it")
        try h.tap("latticeFace-\(a.key)", "its row", settle: 1)
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(a.key), "★ the eye wins: picked, its hidden prism stays hidden")
        XCTAssertNil(h.frames.all[hk], "and no handle on a hidden prism")
        _ = try h.onScreen("numberField-latticeFaceDepth-\(a.key)", "the row still opens with its depth")
        try h.tap("latticeFaceEye-\(a.key)", "the picked face's eye")
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(a.key), "★ its eye shows it")
        _ = try h.onScreen(hk, "★ with its handle (picked)")
        try h.tap("latticeFaceEye-\(a.key)", "the picked face's eye again")
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(a.key), "★ a picked face's eye hides its prism")
        XCTAssertNil(h.frames.all[hk], "★ and its handle with it")
        XCTAssertTrue(p.latticeGroups.first { $0.id == g.id }?.faces.isEmpty == false, "the face stays in its group")
    }

    /// ★ His iPad 11-07 (3a): "On the first tap, all of the group's face prisms come up hidden. They must all be VISIBLE by
    /// default … even in Pending, I should still SEE what was selected." His rule: "Lattice = Prism. No Lattice = Prism.
    /// Protect Skin = Colour. That's it". A tap on a free face starts a group (Pending…): its face wears the group's colour
    /// at once. Lattice: its prism with its handle, no colour. No lattice: its prism, no colour. Protect skin: its colour, no
    /// prism and no handle; its row's eye hides and shows the colour.
    func testTheFirstTapsPrismIsVisible() throws {
        let (h, p, g) = try stage()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let topo = Set(p.selection.groups.flatMap(\.faces))
        let pick = try XCTUnwrap(LatticeSetupHandles.livePick, "★ the page's face tap")
        var used: Set<FaceID> = Set(p.latticeGroups.flatMap(\.faces))
        /// A free face (one no Topology group holds when there is one, so Topology's colour can't be what shows), tapped
        /// into a new group, Pending; then `role` chosen in the face's chip.
        func tapNew(_ what: String, role key: String) throws -> (FaceID, SelectionGroup, LatticeSelectableRef) {
            let free = mesh.faceIDs.filter { !used.contains($0) }
            let f = try XCTUnwrap(free.first { !topo.contains($0) } ?? free.first, "\(what): a free face")
            used.insert(f)
            p.latticeList.clearActive()
            h.pump(0.5)
            pick(f)
            h.pump(1)
            let gr = try XCTUnwrap(p.latticeGroups.first { $0.id != g.id && $0.faces.contains(f) }, "★ \(what): the tap started a group")
            XCTAssertNil(p.lattice.groupRoles[gr.id], "premise: Pending (no role yet)")
            XCTAssertTrue(LatticeSetupHandles.latticeTinted.contains(f), "★ \(what): Pending — the tapped face shows, in its group's colour")
            let ref = try XCTUnwrap(p.latticeSelectableRefs(gr).first, "\(what): its face")
            try h.tap("latticeRole-\(key)", "\(what): the face chip's choice", settle: 1)
            return (f, gr, ref)
        }

        // Lattice = prism
        let (f1, g1, r1) = try tapNew("Lattice", role: "lattice")
        XCTAssertEqual(p.lattice.groupRoles[g1.id], .include)
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(r1.key), "★ Lattice: its prism, nothing else tapped")
        _ = try h.onScreen("handle-\(LatticeSetupHandles.prismKey(r1))", "★ Lattice: with its end handle")
        XCTAssertFalse(LatticeSetupHandles.latticeTinted.contains(f1), "★ Lattice: the prism, not the colour")

        // No lattice = prism
        let (f2, g2, r2) = try tapNew("No lattice", role: "noLattice")
        XCTAssertEqual(p.lattice.groupRoles[g2.id], .exclude)
        XCTAssertFalse(p.lattice.skinGroups.contains(g2.id))
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(r2.key), "★ No lattice: its prism")
        XCTAssertFalse(LatticeSetupHandles.latticeTinted.contains(f2), "★ No lattice: the prism, not the colour")

        // Protect skin = colour
        let (f3, g3, r3) = try tapNew("Protect skin", role: "skin")
        XCTAssertTrue(p.lattice.skinGroups.contains(g3.id), "Protect skin")
        XCTAssertTrue(LatticeSetupHandles.latticeTinted.contains(f3), "★ Protect skin: its colour")
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(r3.key), "★ Protect skin: no prism")
        XCTAssertNil(h.frames.all["handle-\(LatticeSetupHandles.prismKey(r3))"], "★ … and no handle")
        XCTAssertNil(h.frames.all["latticeExpandKnob-\(r3.key)"], "★ … and no expand knob")
        p.latticeList.setActive(g3.id)
        h.pump(1)
        if h.frames.all["latticeFaceEye-\(r3.key)"] != nil {
            try h.tap("latticeFaceEye-\(r3.key)", "Protect skin: its row's eye")
            XCTAssertFalse(LatticeSetupHandles.latticeTinted.contains(f3), "★ its eye hides the colour")
            try h.tap("latticeFaceEye-\(r3.key)", "its eye again")
            XCTAssertTrue(LatticeSetupHandles.latticeTinted.contains(f3), "★ and shows it again")
        } else {
            XCTFail("Protect skin: its face row (with its eye) is not on the screen")
        }
        // the others are as they were
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(r1.key) && LatticeSetupHandles.drawnPrisms.contains(r2.key),
                      "Lattice's and No lattice's prisms stay")
    }

    /// ★ His iPad 11-07 (1b): "Tapping a face prism on the part does NOT deselect it. Wanted: tap a prism → an '×' pops up
    /// on it → tapping the × removes that face from the group." A tap on a face the open group holds puts the × on it (a
    /// 44 pt target, clear of the panel); a second tap takes the × away; the × takes the face out of the group (one Undo).
    func testATapOnAPrismOffersAnXThatTakesTheFaceOut() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let (h, p, g) = try stage(size)
            let ref = try XCTUnwrap(faceRefs(p, g).last, "a face")
            guard case let .face(_, f) = ref else { return XCTFail("a face ref") }
            let pick = try XCTUnwrap(LatticeSetupHandles.livePick, "\(size): ★ the page's face tap")
            XCTAssertNil(h.frames.all["latticeFaceRemove-\(ref.key)"], "\(size): no × before the tap")
            pick(f)
            h.pump(0.8)
            _ = try h.probe("latticeFaceRemove-\(ref.key)", "\(size): ★ the × on the tapped face, a 44 pt target",
                            covers: ["selectionsList"])
            XCTAssertEqual(p.latticeList.activeGroupID, g.id, "\(size): the group stays open")
            pick(f)
            h.pump(0.8)
            XCTAssertNil(h.frames.all["latticeFaceRemove-\(ref.key)"], "\(size): ★ a second tap takes the × away")
            pick(f)
            h.pump(0.8)
            try h.tap("latticeFaceRemove-\(ref.key)", "\(size): the ×")
            XCTAssertFalse(p.latticeGroups.first { $0.id == g.id }?.faces.contains(f) ?? true, "\(size): ★ the × took the face out")
            XCTAssertNil(h.frames.all["latticeFaceRemove-\(ref.key)"], "\(size): and the × is gone")
            XCTAssertTrue(p.latticeGroups.contains { $0.id == g.id }, "\(size): the group stays")
        }
    }

    /// The rules, without a page: shown by default (3a), the eye wins either way; a handle's axis is its projected direction
    /// (up when it points at the camera); a drag moves the finger along the axis only.
    func testTheRules() {
        XCTAssertTrue(LatticeSetupHandles.prismShown("a", eye: [:], picked: "a"), "picked: shown")
        XCTAssertTrue(LatticeSetupHandles.prismShown("a", eye: [:], picked: "b"), "★ 3a: not picked: shown by default")
        XCTAssertTrue(LatticeSetupHandles.prismShown("a", eye: [:], picked: nil), "★ 3a: nothing picked: shown")
        XCTAssertFalse(LatticeSetupHandles.prismShown("a", eye: ["a": false], picked: "a"), "★ the eye hides a picked one")
        XCTAssertFalse(LatticeSetupHandles.prismShown("a", eye: ["a": false], picked: nil), "★ and any other")
        XCTAssertTrue(LatticeSetupHandles.prismShown("a", eye: ["a": true], picked: nil), "★ the eye shows another")
        let ax = LatticeSetupHandles.screenAxis(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 50))
        XCTAssertEqual(ax.dx, 0.6, accuracy: 1e-9); XCTAssertEqual(ax.dy, 0.8, accuracy: 1e-9)
        let edgeOn = LatticeSetupHandles.screenAxis(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.2, y: 10))
        XCTAssertEqual(edgeOn.dy, -1, "pointing at the camera: up")
        let f = LatticeSetupHandles.finger(start: CGPoint(x: 100, y: 100), axis: ax, along: 50)
        XCTAssertEqual(f.x, 130, accuracy: 1e-9); XCTAssertEqual(f.y, 140, accuracy: 1e-9)
        XCTAssertEqual(LatticeSetupCopy.dragItsHandle, "Or drag its handle on the part")
        // never under the page's own UI: slid along its own line to the nearest clear place
        let panel = CGRect(x: 0, y: 0, width: 300, height: 600)
        XCTAssertEqual(LatticeSetupHandles.placed(CGPoint(x: 500, y: 100), axis: CGVector(dx: 1, dy: 0), keepOut: [panel]),
                       CGPoint(x: 500, y: 100), "clear: on its point")
        let q = LatticeSetupHandles.placed(CGPoint(x: 280, y: 100), axis: CGVector(dx: -1, dy: 0), keepOut: [panel])
        XCTAssertEqual(q.y, 100, "★ along its own line")
        XCTAssertGreaterThanOrEqual(q.x - 22, 300, "★ out from under the panel, the nearer way (\(q.x))")
        XCTAssertLessThanOrEqual(q.x - 22, 300 + LatticeSetupHandles.slideStep, "the nearest clear place")
    }
}
#endif
