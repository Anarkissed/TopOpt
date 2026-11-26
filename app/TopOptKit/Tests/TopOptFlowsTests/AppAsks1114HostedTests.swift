// AppAsks1114HostedTests — the owner's app-only asks of 11-14, on the real page at the sweep's six windows:
//   (a) the thin-wall pop-up sits in the centre of the screen, wholly on it, its buttons working;
//   (c) in Edit faces the other half of a selected cut piece is tinted only while Union (the tool that joins the halves back)
//       is armed — not under Select, Similar, Cut, Pattern, Region or Paint;
//   (d) Edit faces' rail opens to the left on its arrow: every tool's name above its icon and its (i), each (i) its own 44 pt
//       target showing exactly its text; closed, the rail is today's to the point.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

private let sweepNames = ["13L", "13P", "11L", "11P", "MSL", "MSP"]

/// The pad, Structural, on Lattice Setup with the lattice preview armed the way he arms it (LatticeLayoutSwitchHostedTests').
@MainActor
private func latticeSetup(_ size: CGSize, _ name: String, _ test: XCTestCase, thinWalls: Bool) throws -> (AppBuildHost, ProjectModel) {
    // the first A1 pad: its walls are thinner than Structural's cells need, so the pop-up comes by itself
    let r = try FlexiblePressFixtures.a1Project(thinWalls ? 1 : 3, test, facePrism: false)
    let p = r.project
    p.lattice.flexible = nil
    p.lattice.clearLatticeType()
    p.lattice.chooseLatticeType(.structural)
    if thinWalls {
        p.lattice.wholePart = true
        p.lattice.thinWallsNoticeSeen = false
    }
    p.lattice.enabled = true
    let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: test)
    h.pump(3)
    try h.pickFromMenu("capsuleMenu", "Structural", what: "\(name): the stage menu")
    h.pump(1.5)
    if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "\(name): the lattice preview", settle: 1.5) }
    if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "\(name): the page's Save", settle: 1.5) }
    XCTAssertNil(h.frames.all["latticeSettingsPanel"], "\(name): premise: on Lattice Setup")
    return (h, p)
}

// MARK: his pick 11-15 — the new engine's stack

/// ★ "Put them at the very [bottom] in landscape and on top of the settings button in portrait": landscape, the stack's foot
/// is the screen's bottom edge; portrait, it sits just above the corner's Settings; at every window it covers neither the hint
/// nor Settings nor Lattice, and Export stays a 44 x 44 target in it. RED CONTROL: the old place, 96 pt off the bottom.
final class NewEngineStackPlacementHostedTests: XCTestCase {
    @MainActor
    func testVeryBottomInLandscapeAboveSettingsInPortrait() throws {
        let settings = AppSettings.shared
        let was = settings.newEngineTest
        addTeardownBlock { @MainActor in AppSettings.shared.newEngineTest = was; NotificationLane.controlOldPlace = false }
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            settings.newEngineTest = false
            let (h, _) = try latticeSetup(size, name, self, thinWalls: false)
            settings.newEngineTest = true
            let end = Date().addingTimeInterval(120)
            while h.frames.all["new-engine-timing"] == nil, Date() < end { h.pump(0.5) }
            h.pump(1)
            let stack = try h.onScreen("lane-new-engine", "★ \(name): the new engine's stack")
            let lines = try h.onScreen("new-engine-lines", "\(name): its lines")
            XCTAssertNil(h.frames.all["stageHint"], "\(name): ★ his 11-22: Lattice Setup has no hint")
            let set = try h.onScreen("setupChip", "\(name): premise: Settings")
            let lat = try h.onScreen("latticeSplit", "\(name): premise: Lattice")
            print("STACK \(name) \(Int(size.width))x\(Int(size.height)): stack \(stack), Settings \(set), Lattice \(lat)")
            XCTAssertTrue(stack.insetBy(dx: -0.5, dy: -0.5).contains(lines), "\(name): the lines are in the stack")
            if size.width > size.height {
                XCTAssertEqual(stack.maxY, size.height, accuracy: 1, "★ \(name): landscape, at the very bottom of the screen")
            } else {
                let corner = Swift.min(set.minY, lat.minY)
                XCTAssertLessThanOrEqual(stack.maxY, set.minY + 0.5, "★ \(name): portrait, above Settings")
                XCTAssertGreaterThanOrEqual(stack.maxY, corner - NotificationLane.stepGap - 1, "★ \(name): portrait, just above the corner")
            }
            for (f, what) in [(set, "Settings"), (lat, "Lattice")] {
                XCTAssertFalse(stack.intersects(f), "★ \(name): the stack \(stack) is clear of \(what) \(f)")
            }
            XCTAssertNil(h.frames.all["new-engine-export"], "★ \(name): his 11-20: the temporary Export bar is gone (Lattice exports)")
            if name == "13L" {   // RED CONTROL: the old place
                // the control is a static, not a state: a 1 pt nudge of the window makes the page place the stack again (it
                // used to ride on the nozzle check's redraw after every layout, which runs only when asked since 11-16)
                func replace() {
                    h.view.setFrameSize(NSSize(width: size.width, height: size.height - 1)); h.pump(0.5)
                    h.view.setFrameSize(NSSize(width: size.width, height: size.height)); h.pump(1)
                }
                NotificationLane.controlOldPlace = true
                replace()
                let old = try h.onScreen("lane-new-engine", "\(name): the stack, old place")
                XCTAssertLessThan(old.maxY, size.height - 50, "RED CONTROL: the old place sits 96 pt off the bottom")
                NotificationLane.controlOldPlace = false
                replace()
            }
            settings.newEngineTest = false
            h.pump(1)
        }
    }
}

// MARK: (a)

final class AppAsksThinWallPopUpHostedTests: XCTestCase {

    // ★ notes30 (builder R1): the page this test leaves (its Switch to Aesthetic lays again) raises the new engine's centred
    // pop-up ("Some of the lattice stays solid"); left up, its backdrop sat over the next test's page (AppSettingsHostedTests'
    // rows, release 21's suite).
    override func tearDown() async throws {
        await MainActor.run { AppPopups.shared.current = nil }
        try await super.tearDown()
    }

    /// ★ (a) The pop-up's own frame is centred on the window (within 1 pt), wholly on it, at the six windows; Continue and
    /// Switch still work.
    @MainActor
    func testThePopUpSitsInTheCentreOfTheScreen() throws {
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            let (h, p) = try latticeSetup(size, name, self, thinWalls: true)
            let end = Date().addingTimeInterval(240)
            while h.frames.all["lattice-thin-walls-panel"] == nil, Date() < end { h.pump(2) }
            let card = try h.onScreen("lattice-thin-walls-panel", "★ \(name): the thin-wall pop-up, by itself")
            print("THIN-WALL POP-UP \(name) \(Int(size.width))×\(Int(size.height)): \(card)")
            XCTAssertEqual(card.midX, size.width / 2, accuracy: 1, "★ \(name): centred across the screen")
            XCTAssertEqual(card.midY, size.height / 2, accuracy: 1, "★ \(name): centred up and down the screen")
            try h.probe("lattice-thin-walls-switch", "\(name): Switch to Aesthetic")
            try h.probe("lattice-thin-walls-continue", "\(name): Continue with Structural")
            try h.tap("lattice-thin-walls-continue", "\(name): Continue with Structural", settle: 1)
            XCTAssertNil(h.frames.all["lattice-thin-walls-panel"], "★ \(name): Continue closes it")
            XCTAssertTrue(p.lattice.thinWallsNoticeSeen, "★ \(name): … and saves the answer")
            try h.tap("lattice-thin-walls-note", "\(name): the note", settle: 1)
            _ = try h.onScreen("lattice-thin-walls-panel", "★ \(name): the note re-opens it")
            try h.tap("lattice-thin-walls-switch", "\(name): Switch to Aesthetic", settle: 1.5)
            XCTAssertEqual(p.lattice.stageMode, .aesthetic, "★ \(name): Switch changes the mode")
            XCTAssertNil(h.frames.all["lattice-thin-walls-panel"], "★ \(name): … and closes it")
        }
    }
}

// MARK: (c)

final class AppAsksCutSiblingTintHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset() }
        try await super.tearDown()
    }

    /// The page's 3D view's renderer (the largest MTKView's).
    @MainActor
    private func renderer(_ h: AppBuildHost) throws -> MeshRenderer {
        var found: [MTKView] = []
        func walk(_ v: NSView) { if let m = v as? MTKView { found.append(m) }; v.subviews.forEach(walk) }
        walk(h.view)
        let mtk = try XCTUnwrap(found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }, "the 3D view")
        return try XCTUnwrap(mtk.delegate as? MeshRenderer, "the 3D view's renderer")
    }

    /// The other half's tint is drawn: the shader is testing a plane or picked pieces, and paints the rest in the sibling blue.
    private func siblingDrawn(_ u: CutUniformsSwift) -> Bool {
        (u.enabled > 0.5 || u.pickGroups > 0) && u.colSibling == SurfaceTint.sibling
    }

    /// ★ (c) With a piece of a cut face selected: the half highlight is off under Select, Similar, Cut, Pattern, Region and
    /// Paint, and on under Union.
    @MainActor
    func testTheOtherHalfIsTintedOnlyUnderUnion() throws {
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            let (h, p) = try ParityCutShots.cut(size, test: self)
            let m = try XCTUnwrap(p.viewerMesh, "the pad's mesh")
            let flat = try XCTUnwrap(FaceTopology.faceIDs(in: m).first {
                CutAim.make(face: $0, piece: p.surfaceCutTarget(face: $0), regions: p.faceRegions, mesh: m)?.way == .line
            }, "\(name): a flat face")
            let aim = try XCTUnwrap(CutAim.make(face: flat, piece: p.surfaceCutTarget(face: flat), regions: p.faceRegions, mesh: m))
            let cut = try XCTUnwrap(aim.surfaceCut(), "\(name): the face's cut")
            XCTAssertFalse(p.commitSurfaceCut(cut).isEmpty, "\(name): premise: the face is cut in two")
            h.pump(0.8)

            func either(_ k: String) -> String { h.frames.all[k + "-on"] != nil ? k + "-on" : k }
            /// Select, tap the face (its deepest piece), then arm `tool` on it.
            func armed(_ tool: String) throws -> CutUniformsSwift {
                try h.tap(either("cutTool-Select"), "\(name): Select")
                let pick = try XCTUnwrap(CutLive.pick, "the page's face tap")
                pick(flat)
                h.pump(0.8)
                if tool != "Select" { try h.tap(either("cutTool-\(tool)"), "\(name): \(tool)") }
                h.pump(0.8)
                return try renderer(h).cutUniforms
            }

            let select = try armed("Select")
            XCTAssertTrue(select.enabled > 0.5, "\(name): premise: a piece of the cut face is selected (its plane is tested)")
            XCTAssertEqual(select.colSelected, SurfaceTint.selected, "\(name): premise: the selected piece is lit")
            XCTAssertFalse(siblingDrawn(select), "★ \(name): Select — no half highlight")
            for tool in ["Similar", "Cut", "Pattern", "Region", "Paint"] {
                XCTAssertFalse(siblingDrawn(try armed(tool)), "★ \(name): \(tool) — no half highlight")
            }
            let union = try armed("Union")
            XCTAssertGreaterThan(union.pickGroups, 0, "\(name): premise: Union picked the piece")
            XCTAssertTrue(siblingDrawn(union), "★ \(name): Union — the other half is lit (Union joins the halves back)")
        }
    }
}
// MARK: (d)

final class AppAsksToolRailHostedTests: XCTestCase {

    private let names = SurfaceTool.allCases.map(\.title) + ["Paint", "Pencil only"]
    private func targetKey(_ n: String) -> String { n == "Pencil only" ? "cutToolTarget-PencilOnly" : "cutToolTarget-\(n)" }

    /// Today's closed rail (printed on the base, 0379e639, at all six windows): the capsule 80 pt in from the right edge at
    /// y 299.5, 56 × 417; its targets 74 pt in, 50 pt apart from y 305.5, Paint at 605.5, Pencil only at 666.5.
    private func todays(_ size: CGSize) -> [String: CGRect] {
        var t: [String: CGRect] = ["cutRail": CGRect(x: size.width - 80, y: 299.5, width: 56, height: 417)]
        for (i, tool) in SurfaceTool.allCases.enumerated() {
            t["cutToolTarget-\(tool.title)"] = CGRect(x: size.width - 74, y: 305.5 + 50 * CGFloat(i), width: 44, height: 44)
        }
        t["cutToolTarget-Paint"] = CGRect(x: size.width - 74, y: 605.5, width: 44, height: 44)
        t["cutToolTarget-PencilOnly"] = CGRect(x: size.width - 74, y: 666.5, width: 44, height: 44)
        return t
    }

    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// The owner's words for each (i), exactly (the brief of 11-14). A hosted popover's words cannot be read back (no
    /// accessibility tree; its root view holds no Text when mirrored), so the page's (i)s are held to `CutRailInfo` here and
    /// each (i) is tapped to show that it opens its popover.
    private let owners: [String: String] = [
        "Select": "Picks one face. Tap a face to select it.",
        "Similar": "Picks every face that looks like the one you tap, such as all the bolt holes at once. Tap one of them.",
        "Cut": "Splits a face into two pieces along a line. Tap the face where the cut goes, turn or tilt the line on its bar, then tap ✓.",
        "Union": "Joins faces into one, or joins a cut face's pieces back together. Tap the faces to join, then ✓.",
        "Pattern": "Splits a face into a grid of pieces. Tap the face, set the grid, then ✓.",
        "Region": "Adds faces to a region or takes them out. Tap the region, then the faces to add or drop.",
        "Paint": "On an STL part, paints a face of your own where the file has none. Brush over the part; the eraser takes paint off.",
        "Pencil only": "On: only the Apple Pencil picks and cuts; your finger turns and zooms the part.",
    ]

    @MainActor
    func testTheArrowOpensTheRailWithNamesAndInfo() throws {
        for (name, size) in zip(sweepNames, AppBuildHost.sweep) {
            let (h, _) = try ParityCutShots.cut(size, test: self)
            func either(_ k: String) -> String { h.frames.all[k + "-on"] != nil ? k + "-on" : k }

            // closed: today's rail, to the point
            for (k, want) in todays(size) {
                let got = try h.onScreen(k, "\(name): \(k)")
                XCTAssertTrue(same(got, want), "★ \(name): closed, \(k) is today's \(want): got \(got)")
            }
            XCTAssertTrue(h.frames.all.keys.filter { $0.hasPrefix("info-cutRail") || $0.hasPrefix("cutRailName-") }.isEmpty,
                          "\(name): closed, no names and no (i)")
            try h.tap(either("cutTool-Union"), "\(name): closed, a tap on Union's icon")
            XCTAssertNotNil(h.frames.all["cutTool-Union-on"], "★ \(name): closed, a tap on the icon picks the tool")

            // the arrow opens it to the left
            let arrow = try h.probe("cutRailArrow", "★ \(name): the rail's arrow, a 44 pt target")
            let closedRail = try XCTUnwrap(h.frames.all["cutRail"])
            XCTAssertLessThanOrEqual(arrow.maxX, closedRail.minX + 0.5, "\(name): the arrow is beside the rail, on its left")
            try h.tap("cutRailArrow", "\(name): the arrow", settle: 1)
            let rail = try h.onScreen("cutRail", "★ \(name): the open rail, wholly on the screen")
            print("OPEN RAIL \(name) \(Int(size.width))×\(Int(size.height)): \(rail) (closed \(closedRail))")
            XCTAssertEqual(rail.maxX, closedRail.maxX, accuracy: 0.5, "★ \(name): it opens to the LEFT (its right edge stays)")
            XCTAssertLessThan(rail.minX, closedRail.minX - 40, "★ \(name): … and is wider")
            _ = try h.probe("cutRailArrow-on", "\(name): the arrow, open")

            var infos: [CGRect] = []
            for n in names {
                let label = try h.onScreen("cutRailName-\(n)", "★ \(name): \(n)'s name")
                let target = try h.probe(targetKey(n), "\(name): \(n)'s target")
                XCTAssertTrue(target.insetBy(dx: -0.5, dy: -0.5).contains(label), "★ \(name): \(n)'s name is in its target (a tap on it picks it)")
                let icon = try h.onScreen(either(n == "Pencil only" ? "cutTool-PencilOnly" : "cutTool-\(n)"), "\(name): \(n)'s icon")
                XCTAssertLessThanOrEqual(label.maxY, icon.minY + 0.5, "★ \(name): \(n)'s name is above its icon")
                let info = try h.probe("info-cutRail-\(n)", "★ \(name): \(n)'s (i), its own 44 pt target")
                XCTAssertFalse(info.intersects(target.insetBy(dx: 0.5, dy: 0.5)), "\(name): \(n)'s (i) is its own target")
                XCTAssertTrue(rail.insetBy(dx: -0.5, dy: -0.5).contains(info), "\(name): \(n)'s (i) is in the rail")
                infos.append(info)
            }
            for i in infos.indices { for j in infos.indices where j > i {
                XCTAssertFalse(infos[i].insetBy(dx: 0.5, dy: 0.5).intersects(infos[j]), "★ \(name): no two (i)s overlap")
            } }
            // it covers no other control
            let own = ["cutRail", "cutTool", "info-cutRail", "cutRailName-", "cutRailHint", "cutPaintWhy"]
            for (k, f) in h.frames.all where !own.contains(where: { k.hasPrefix($0) }) {
                if f.insetBy(dx: -0.5, dy: -0.5).contains(rail) { continue }   // the page round it
                XCTAssertFalse(rail.insetBy(dx: 0.5, dy: 0.5).intersects(f), "★ \(name): the open rail covers \(k) \(f)")
            }
            // each (i) holds exactly its text, and opens its popover
            // ★ RE-PINNED (notes29, his 11-25: every (i) opens the front-and-centre notification): each (i) raises the centred
            // notification with exactly its words (a popover's words could not be read back; the notification's can)
            for n in names {
                XCTAssertEqual(CutRailInfo.text(n), owners[n], "★ \(n)'s (i) says exactly the owner's words")
                AppPopups.shared.current = nil
                try h.tap("info-cutRail-\(n)", "\(name): \(n)'s (i)", settle: 0.6)
                XCTAssertEqual(AppPopups.shared.current?.info, true, "★ \(name): \(n)'s (i) opens the centred notification")
                XCTAssertEqual(AppPopups.shared.current?.text, owners[n], "★ \(name): \(n)'s words")
                AppPopups.shared.current = nil
                h.pump(0.4)
            }
            // a tap on a name picks the tool, open
            try h.tap("cutRailName-Region", "\(name): open, Region's name", settle: 0.8)
            XCTAssertNotNil(h.frames.all["cutTool-Region-on"], "★ \(name): open, a tap on the name picks the tool")
            try h.tap(either("cutTool-Similar"), "\(name): open, Similar's icon", settle: 0.8)
            XCTAssertNotNil(h.frames.all["cutTool-Similar-on"], "★ \(name): open, a tap on the icon picks the tool")
            try h.tap("cutRailName-Pencil only", "\(name): open, Pencil only's name", settle: 0.8)
            XCTAssertNotNil(h.frames.all["cutTool-PencilOnly-on"], "★ \(name): open, a tap on Pencil only's name turns it on")
            try h.tap("cutRailName-Pencil only", "\(name): … and off", settle: 0.8)
            XCTAssertNil(h.frames.all["cutTool-PencilOnly-on"], "\(name): Pencil only is off again")

            // the arrow closes it: today's rail again
            try h.tap("cutRailArrow-on", "\(name): the arrow again", settle: 1)
            for (k, want) in todays(size) {
                let got = try h.onScreen(k, "\(name): \(k)")
                XCTAssertTrue(same(got, want), "★ \(name): closed again, \(k) is today's \(want): got \(got)")
            }
        }
    }
}
#endif
