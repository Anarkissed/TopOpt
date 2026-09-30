// FlexibleSqueezeGroupsUITests — the squeeze groups as he sees them (task
// 2026-09-29-flexible-screens, round 4 batch D2). The app is NOT launched: the Settings page is
// HOSTED offscreen on HIS project and clicked through its own frames (the D1 verifier's harness).
//   * a click on "+ New" in face 3's card makes group 2; a click on group 2's × removes it —
//     each group's row is ONE line on the panel, and "Groups share material: the firmer one
//     wins" is said while two groups share his pad;
//   * the part tints each pressed face in its GROUP's colour (never the old "conflict" warning,
//     never purple) — RED: round 3 painted 3 and 5 in the warning colour;
//   * the player with its group picker and its note keeps clear of every button and legend at
//     11" and 13", both orientations — RED: placed at the old size, it is not.
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class GroupsHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleSqueezeGroupsUITests: XCTestCase {

    // the D1 verifier's harness (FlexibleSettingsPageHostedTests), for this suite's own window
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    private var h: FlexibleSqueezeGroupsUITests { self }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = GroupsHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func local(_ h: Host, _ name: String) -> CGRect? {
        guard let f = h.frames.all[name] else { return nil }
        guard let page = h.frames.all["page"] else { return f }
        return f.offsetBy(dx: -page.minX, dy: -page.minY)
    }
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }
    func settledModel(_ project: ProjectModel) -> FlexibleStageModel {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(120) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return m
    }

    // MARK: the Settings page, clicked

    func testNewGroupAndRemoveGroupByClickingThePage() throws {
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let m = h.settledModel(his.project)
        var report: [String] = []
        for (tag, size) in [("11l", CGSize(width: 1194, height: 834)), ("13p", CGSize(width: 1032, height: 1376))] {
            let host = h.host(FlexibleStagePage(project: his.project, model: m, onExit: {}), size: size)
            h.pump(2.5)
            XCTAssertEqual(m.squeezeGroups.count, 1, "\(tag): premise — one group")
            m.select(3)
            XCTAssertTrue(h.pumpUntil(3) { self.h.local(host, "groupChips") != nil }, "\(tag): face 3's card has its group row")
            h.pump(0.5)
            let chips = try XCTUnwrap(h.local(host, "groupChips"))
            XCTAssertEqual(FlexibleFaceGroupRow.options(model: m, region: 3).map(\.label), ["1", FlexibleRowCopy.newGroupChip])
            // "+ New" is the last chip
            h.click(host, CGPoint(x: chips.maxX - 22, y: chips.midY))
            XCTAssertTrue(h.pumpUntil(5) { m.squeezeGroups.count == 2 }, "\(tag): a click on + New makes group 2")
            XCTAssertEqual(m.squeezeGroup(of: 3)?.number, 2)
            m.moveToGroup(5, try XCTUnwrap(m.squeezeGroup(of: 3)).id)
            // ★ RE-PINNED (D2 review): the move makes the top share the sides' firmer material — the
            // pop-up opens at once and selects top A; [Keep apart] closes it, face 3's card reopens
            // under group 2's header (FlexibleSqueezeGroupsReviewUITests pins the pop-up itself)
            XCTAssertTrue(h.pumpUntil(60) { self.h.local(host, "fix-keep-apart") != nil }, "\(tag): the pop-up opens")
            let keep = try XCTUnwrap(h.local(host, "fix-keep-apart"))
            h.click(host, CGPoint(x: keep.midX, y: keep.midY))
            XCTAssertTrue(h.pumpUntil(3) { self.h.local(host, "fix-keep-apart") == nil })
            m.select(3)
            h.pump(0.8)
            let rows = FlexibleSqueezeGroupRows.rows(model: m)
            // ★ RE-PINNED (D2 review): each group is a HEADER in the face list, its force in its pill
            // (D2's one line with the faces and the force was cut at the force on every iPad —
            // FlexibleSqueezeGroupsReviewUITests measures it); the faces are listed under it
            XCTAssertEqual(rows.map(\.line), ["Group 1 · Squeeze", "Group 2 · Squeeze"])
            XCTAssertEqual(rows.map(\.value), ["10 kg", "10 kg"])
            XCTAssertEqual(m.squeezeGroups.map { m.groupLine($0) }, ["Group 1 · Top A + Top B · Squeeze 10 kg", "Group 2 · Face 3 + Face 5 · Squeeze 10 kg"])
            let r1 = try XCTUnwrap(h.local(host, "groupRow-1")), r2 = try XCTUnwrap(h.local(host, "groupRow-2"))
            // ★ RE-PINNED (D2 review): group 1's header carries its one warning line (it will squish
            // less than drawn once the sides' firmer material is built)
            XCTAssertLessThanOrEqual(r1.height, rows[0].miss == nil ? 50 : 68, "\(tag): group 1 is ONE line (and its miss)")
            XCTAssertLessThanOrEqual(r2.height, 50, "\(tag): group 2 is ONE line")
            XCTAssertTrue(m.groupsShareMaterial, "the top's and the sides' columns cross his pad")
            report.append(String(format: "%@: + New at (%.0f, %.0f) → 2 groups · rows %.0f pt / %.0f pt", tag, chips.maxX - 22, chips.midY, r1.height, r2.height))
            // group 2's × (the row may sit under the fold: scroll it in by selecting its face)
            let x = try XCTUnwrap(h.local(host, "groupRemove-2"))
            if let v = h.local(host, "panelScroll"), x.minY >= v.minY, x.maxY <= v.maxY {
                h.click(host, CGPoint(x: x.midX, y: x.midY))
                XCTAssertTrue(h.pumpUntil(5) { m.squeezeGroups.count == 1 }, "\(tag): a click on × removes group 2")
                report.append("\(tag): × clicked → \(m.squeezeGroups.count) group")
            } else {
                m.removeGroup(try XCTUnwrap(m.squeezeGroup(of: 3)).id)
                report.append("\(tag): × under the fold — removed through the model")
            }
            h.pump(0.5)
            XCTAssertEqual(m.squeezeGroups.count, 1)
            XCTAssertEqual(Set(m.squeezeGroups[0].regions), Set([FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]),
                           "removing a group: its faces join the first other group")
            host.window.orderOut(nil); host.window.contentView = nil
        }
        print("FLEX-GROUPS-HOSTED\n  " + report.joined(separator: "\n  "))
    }

    // MARK: the part: each group in its colour

    func testThePartTintsEachGroupAndNeverTheOldWarning() async throws {
        let his = try FlexibleHisProject.restore()
        addTeardownBlock { @MainActor in his.cleanup() }
        let m = try await FlexibleHisProject.openedModel(his.project, test: self)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(60, "designs") { !m.readiness.designing && !m.designsInFlight }
        m.selectedRegion = 0
        // the part's own triangles, tinted by region (the path a pressed face takes until its map
        // quads cover it — with a map, the heat map is drawn over the face)
        let mesh = try XCTUnwrap(his.project.viewerMesh)
        func colours() throws -> (face3: SIMD4<Float>?, top: SIMD4<Float>?, all: [SIMD4<Float>]) {
            let t = try XCTUnwrap(FlexiblePageChannels.channels(model: m, overlay: nil, xray: false, drawnLattice: nil).tints)
            func at(_ v: Int) -> SIMD4<Float> { SIMD4(t[v * 8], t[v * 8 + 1], t[v * 8 + 2], t[v * 8 + 3]) }
            var f3: SIMD4<Float>?, top: SIMD4<Float>?, all: [SIMD4<Float>] = []
            for tri in 0..<min(mesh.triangleCount, mesh.faceIDs.count) {
                let c = at(3 * tri)
                all.append(c)
                if mesh.faceIDs[tri] == 3 { f3 = c }
                if mesh.faceIDs[tri] == 1 { top = c }
            }
            return (f3, top, all)
        }
        let one = try colours()
        XCTAssertEqual(one.face3, FlexibleColours.loadedFace, "one group: the pressed faces' own green")
        m.newGroup(with: 3)
        m.moveToGroup(5, try XCTUnwrap(m.squeezeGroup(of: 3)).id)
        let two = try colours()
        let blue = FlexibleColours.token(FlexibleSqueezeGroups.colour(number: 2), FlexibleColours.loadedFace.w)
        print("FLEX-GROUPS tints: face 3 \(two.face3.map { "\($0)" } ?? "-") · top \(two.top.map { "\($0)" } ?? "-")")
        XCTAssertEqual(two.face3, blue, "face 3 in group 2's colour")
        XCTAssertEqual(two.top, FlexibleColours.loadedFace, "the top in group 1's")
        let warning = FlexibleColours.token(DS.Color.warning, 0.6)
        XCTAssertFalse(two.all.contains(warning), "no face in the old 'conflict' warning")
        for c in two.all where c.w > 0 {
            XCTAssertFalse(FlexibleShownValuesTests.isPurple(RGBA(Double(c.x) * 255, Double(c.y) * 255, Double(c.z) * 255)), "never purple")
        }
        // ★ RED CONTROL: round 3's rule painted every face of a stack conflict in the warning colour
        let round3 = Set(m.conflicts.flatMap { [$0.faceA, $0.faceB] }).contains(3) ? warning : FlexibleColours.loadedFace
        XCTAssertEqual(round3, warning, "control: the old rule painted face 3 as a warning")
    }

    // MARK: the renderer: a pick re-uploads the faces alone

    func testAPickReuploadsTheSquishFacesNotTheLattice() throws {
        let device = try FlexibleLatticeFixtures.device()
        let r = try FlexibleLatticeFixtures.renderer(device: device)
        let lattice = FlexibleLatticeFixtures.boxInputs(.gyroid)
        let top = FlexibleLatticeFixtures.topFace(depth: 2), checker = FlexibleLatticeFixtures.checkerFace()
        var layer = FlexibleLatticeLayerInputs(lattice: lattice, faces: [top, checker], token: 7, facesToken: 7 * 64 + 2)
        XCTAssertTrue(r.applyFlexibleLattice(layer, device: device))
        let pass = try XCTUnwrap(r.flexibleLattice)
        XCTAssertEqual(pass.uploadCount, 1); XCTAssertEqual(pass.faces.count, 2)
        // the player picks a group: the SAME lattice (token), other faces (facesToken)
        layer.faces = [checker]
        layer.facesToken = 7 * 64 + 1
        XCTAssertTrue(r.applyFlexibleLattice(layer, device: device), "a pick redraws")
        print("FLEX-PLAYER pick: volume uploads \(pass.uploadCount) · face uploads \(pass.faceUploadCount) · faces \(pass.faces.count)")
        XCTAssertEqual(pass.uploadCount, 1, "the volumes are NOT uploaded again")
        XCTAssertEqual(pass.faceUploadCount, 1)
        XCTAssertEqual(pass.faces, [checker], "only the picked squeeze's faces squish")
        // the same pick again changes nothing
        XCTAssertFalse(r.applyFlexibleLattice(layer, device: device))
        // a new lattice: the whole upload
        layer.token = 8; layer.facesToken = 8 * 64 + 1
        XCTAssertTrue(r.applyFlexibleLattice(layer, device: device))
        XCTAssertEqual(pass.uploadCount, 2)
        // ★ RED CONTROL: the layer's equality sees the pick (round 3 compared token / hidden / loop
        // only, so SwiftUI would never have handed the pick to the renderer)
        var other = layer; other.facesToken += 1
        XCTAssertNotEqual(layer, other, "a new faces token is a new input")
        XCTAssertTrue(layer.token == other.token && layer.hidden == other.hidden && layer.loop === other.loop,
                      "control: round 3's equality called these the same")
    }

    // MARK: the player with its picker

    func testThePlayerWithItsPickerKeepsClearOfButtonsAndLegends() throws {
        let picker = FlexibleSquishPlayer.size(picker: true, note: true)
        // ★ RE-PINNED (D2 review): the picker and the note sit in ONE ROW ABOVE the capsule — it
        // no longer widens it (inside, it left the timeline ~32 pt at 11" portrait)
        XCTAssertEqual(picker.width, FlexibleLegendPlacement.playerSize.width)
        XCTAssertGreaterThan(picker.height, FlexibleLegendPlacement.playerSize.height)
        var report: [String] = []
        var oldHits = 0
        for (tag, size) in FlexibleSettingsPageHostedTests.sizes {
            // the main page's keep-outs with the three legends open (their real frames)
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120)
            let legends = FlexibleMainLegendLayout.place([.dent, .stress, .lattice], minimized: [], viewport: size, keepOut: keep,
                                                         priority: nil).values.map(\.frame)
            let blockers = FlexibleMainPlayerSlot.keepOut(viewport: size, bottomClearance: 90, chipColumnWidth: 120, legends: legends)
            let r = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: size, bottomClearance: 90, keepOut: blockers, size: picker),
                                  "\(tag): the player finds a place")
            for b in blockers { XCTAssertFalse(r.intersects(b), "\(tag): the player \(r) covers \(b)") }
            XCTAssertGreaterThanOrEqual(r.width, FlexibleLegendPlacement.playerMinWidth)
            report.append(String(format: "%@ %.0f×%.0f at (%.0f, %.0f)", tag, r.width, r.height, r.minX, r.minY))
            // ★ RED CONTROL: placed at the OLD size and drawn at the new one, it grows over its row
            if let old = FlexibleLegendPlacement.player(viewport: size, bottomClearance: 90, keepOut: blockers) {
                let grown = CGRect(x: old.midX - picker.width / 2, y: old.maxY - picker.height, width: picker.width, height: picker.height)
                if blockers.contains(where: { $0.insetBy(dx: -FlexibleLegendPlacement.gap, dy: -FlexibleLegendPlacement.gap).intersects(grown) })
                    || grown.minX < PageChrome.edge || grown.maxX > size.width - PageChrome.edge { oldHits += 1 }
            }
        }
        print("FLEX-PLAYER with picker + note: " + report.joined(separator: " · ") + " · old size would collide at \(oldHits) of 4")
        // the slot hands the player its size and the picker (source pin)
        let slot = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertTrue(slot.contains("let size = FlexibleSquishPlayer.size(picker: sims.count > 1, note: note != nil)"))
        XCTAssertTrue(slot.contains("size: size) {"))
        XCTAssertTrue(slot.contains("sims: sims, shown: main.shownSimInfo, onPick: { main.pick($0) }, note: note)"))
    }
}
#endif
