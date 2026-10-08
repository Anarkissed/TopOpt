// FlexibleRound6HostedTests — round 6, items 1 and 3, on HIS project (A1_0003, restored as he saved it) and
// hosted in a window (offscreen, never the app) (task 2026-09-29-flexible-screens, round 6; FINAL spec §6).
// Written BEFORE the code; each with its red control.
//   R6-1a  the main page wears NO group colour — no frame, no digit, no tinted body — in any view or any
//          Play-all turn (his img1), from a positive control that reproduces his screenshot first;
//   R6-1b  the Settings page walls the OPEN group only (his answer to item 1), Rests in cyan, every group
//          in the Groups view; its composed tints carry no frame, gap or group colour;
//   R6-1e  past eight groups the number rides the glass (a disc), only in the Groups view;
//   R6-3a  selecting a pressed face shows its prism (faint) and its number at once (his img3's red line);
//   R6-3b  the Prisms view: every pressed face's prism with its mm, a tag tap selects;
//   R6-3c  the view buttons sit under the gizmo, clear of everything, at 11" and 13", both ways;
//   R6-3d  ONE legend card carries the view rows, one line each;
//   R6-3f  the main page's prisms (hook H15's list): the active group's, or every one in the Prisms view;
//   R6-3g / R6-3h  the main page's [Prisms] button — wait on the S1 base (skipped, printed).
// FLEX_R6_EVIDENCE_DIR=<dir> also writes the hosted pages.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R6HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound6HostedTests: XCTestCase {

    // MARK: - hosting (FlexibleGroupPaletteHostedTests' own)

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R6_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let sizes: [(String, CGSize)] = FlexibleGroupPaletteHostedTests.sizes

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
        let w = R6HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name))
            print("FLEX-R6 wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    /// A model over `project` (the main stage's own), its scene, stacks and designs settled.
    func settledModel(_ project: ProjectModel, stage given: FlexibleMainStage? = nil) -> FlexibleStageModel {
        let stage = given ?? FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return m
    }

    /// HIS pad: A1_0003 as he saved it (img1–img4): Group 1 = the top (face 1), Group 2 = faces 4 and 2
    /// (pink), Group 3 = faces 3 and 5 (teal, his pick), face 0 rests.
    func his(_ stage: FlexibleMainStage? = nil) throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = settledModel(r.project, stage: stage)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "his three groups")
        return (r, m)
    }

    static func rgba(_ t: [Float], _ v: Int) -> SIMD4<Float> { SIMD4(t[v * 8], t[v * 8 + 1], t[v * 8 + 2], t[v * 8 + 3]) }

    /// Every colour a group puts on a body: its token opaque (the frame, a digit) and at the pressed face's
    /// alpha (round 4's body tint), and the frame's gap. (Group 1's green at the pressed alpha IS the
    /// uncoloured pressed face — `loadedFace` — so it is not a group's sign and is left out.)
    @MainActor
    static func groupInk(_ m: FlexibleStageModel) -> Set<SIMD4<Float>> {
        var out: Set<SIMD4<Float>> = [FlexibleGroupFrames.gapColour]
        for g in m.squeezeGroups {
            let c = m.groupColour(g)
            out.insert(FlexibleColours.token(c, 1))
            out.insert(FlexibleColours.token(c, FlexibleColours.loadedFace.w))
        }
        out.remove(FlexibleColours.loadedFace)
        return out
    }

    static func inked(_ t: [Float], _ ink: Set<SIMD4<Float>>) -> Int {
        (0..<(t.count / 8)).filter { ink.contains(rgba(t, $0)) }.count
    }

    // MARK: - R6-1a

    /// His pad through Save & Exit, until every group's sim has landed (FlexibleMergeR5SMTests' route).
    func mainStage() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 600 {
            if m.lattice != nil, !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(m.lattice, "the lattice built")
        XCTAssertFalse(m.squish.isEmpty, "the sims ran")
        return (r, stage, m)
    }

    /// ★ HIS IMG1: "I am seeing these edges all along the object — even when the heat map is turned off."
    func testTheMainPageWearsNoGroupColourInAnyViewOrTurn() async throws {
        let (r, s, m) = try await mainStage()
        let o = try XCTUnwrap(s.overlay)
        let ink = Self.groupInk(m)
        var lines: [String] = []
        // ── POSITIVE CONTROL (his img1): the Lattice view on, the heat off — round 5's frames, every one
        s.latticeOn = true
        s.heat = false
        s.controlRound5Frames = true
        s.refresh()
        let framed = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
        let pc = FlexibleMergeR5SMTests.frameCheck(framed, o, m)
        lines.append("positive control (Lattice on, heat off, round 5's frames): \(pc.checked) frame vertices checked, \(pc.wrong) wrong · \(Self.inked(framed, ink)) inked")
        XCTAssertGreaterThan(pc.checked, 0, "positive control: his img1's frames")
        XCTAssertEqual(pc.wrong, 0, "positive control: every frame vertex in its group's colour")
        s.controlRound5Frames = false
        // ── every view, every Play-all turn: no group's ink on the model
        let seq = s.fe.sequence
        XCTAssertGreaterThan(seq.count, 1, "Play all plays every group (\(s.fe.requested))")
        for (name, heat, stress) in [("heat off", false, false), ("heat on", true, false), ("Stress", false, true)] {
            s.heat = heat
            s.stress = stress
            s.refresh()
            var turns: [String] = []
            for i in seq {
                s.loop.shownIndex = i
                let t = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: [:], stress: nil))
                let n = Self.inked(t, ink)
                turns.append("\(s.fe.fields[i].simID) \(n)")
                XCTAssertEqual(n, 0, "\(name), \(s.fe.fields[i].simID)'s turn: no group colour on the model")
            }
            let composed = Self.inked(try XCTUnwrap(s.composed), ink)
            XCTAssertEqual(composed, 0, "\(name): the composed tints")
            lines.append("\(name): inked vertices per turn — " + turns.joined(separator: " · ") + " · composed \(composed)")
        }
        s.stress = false; s.heat = true
        // ── a pressed face with no map yet: the plain pressed colour, in the refresh AND in a Play-all turn
        XCTAssertNil(m.stacks[FlexFaceKey(region: 0, rotation: 0)], "premise: face 0 (resting) has no stack")
        m.selectedRegion = nil   // (a selected face would tint face 0 as its linked other end)
        m.edit { st in
            guard var f = st.face(0) else { return }
            f.role = "loaded"; f.squeezeGroup = 2
            st.setFace(f)
        }
        let tris = o.keptFace.indices.filter { o.keptFace[$0] == 0 }
        XCTAssertFalse(tris.isEmpty, "face 0's part triangles are in the overlay")
        func face0(_ t: [Float]) -> Set<SIMD4<Float>> { Set(tris.flatMap { tri in (0..<3).map { Self.rgba(t, 3 * tri + $0) } }) }
        let turns = s.playAllBaseTints(m, scaleMM: 1)   // (fe is still the landed sims': no refresh since the edit)
        XCTAssertFalse(turns.isEmpty, "the Play-all turns' tints")
        for (id, t) in turns { XCTAssertEqual(face0(t), [FlexibleColours.loadedFace], "\(id)'s turn: face 0 pressed, no map — the plain pressed colour") }
        s.refresh()
        XCTAssertNil(m.stacks[FlexFaceKey(region: 0, rotation: 0)], "still no map for face 0")
        XCTAssertEqual(face0(try XCTUnwrap(s.channels?.tints)), [FlexibleColours.loadedFace], "the refresh: the plain pressed colour")
        // ★ RED CONTROL: the channels with the group colours (round 4–5) — face 0 wears Group 2's pink
        let red = FlexiblePageChannels.channels(model: m, overlay: o, xray: false, drawnLattice: nil, groupColours: true)
        let pink = FlexibleColours.token(m.groupColour(number: 2), FlexibleColours.loadedFace.w)
        XCTAssertEqual(face0(try XCTUnwrap(red.tints)), [pink], "control: groupColours true tints the map-less face pink")
        lines.append("no map: face 0 \(face0(try XCTUnwrap(s.channels?.tints)) == [FlexibleColours.loadedFace] ? "plain" : "TINTED") (control: pink)")
        print("FLEX-R6-1a\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - R6-1b

    /// ★ HIS ANSWER TO ITEM 1: "Settings page only, BUT only when the group is selected or the all groups has
    /// been set. Also, make it a slightly visible wall with a TINT of the group colour."
    func testTheSettingsPageWallsTheOpenGroupOnly() throws {
        let (r, m) = try his()
        let part = try XCTUnwrap(r.project.viewerMesh)
        func walls(_ views: FlexibleStageViews = []) -> [Int: ClearanceRenderItem] {
            Dictionary(FlexibleGroupWalls.items(model: m, views: views, mesh: part).map { ($0.volume.faceID, $0) }) { a, _ in a }
        }
        func rgb(_ c: RGBA) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
        let pink = rgb(FlexibleGroupColour.pink.rgba), teal = rgb(FlexibleGroupColour.teal.rgba), cyan = rgb(DS.Color.accentCyan)
        var lines: [String] = []
        m.rail = .group(2)
        var w = walls()
        XCTAssertEqual(Set(w.keys), [4, 2], ".group(2): its members")
        for it in w.values {
            XCTAssertEqual(it.tint, pink); XCTAssertEqual(it.faceAlpha, FlexibleGroupWalls.faceAlpha); XCTAssertEqual(it.edgeAlpha, FlexibleGroupWalls.edgeAlpha)
            XCTAssertTrue(it.surfaceOnly, "a glass: its base only")
        }
        // (the alphas themselves are R6-1d's measured values on his pad: FlexibleRound6Tests)
        XCTAssertLessThan(FlexibleGroupWalls.faceAlpha, FlexibleGroupWalls.openFaceAlpha, "the open group brighter in the Groups view")
        lines.append(".group(2) → \(w.keys.sorted())")
        m.rail = .group(3)
        w = walls()
        XCTAssertEqual(Set(w.keys), [3, 5], ".group(3)")
        XCTAssertTrue(w.values.allSatisfy { $0.tint == teal }, "teal (his pick)")
        lines.append(".group(3) → \(w.keys.sorted())")
        m.rail = .rests
        w = walls()
        XCTAssertEqual(Set(w.keys), [0], ".rests")
        XCTAssertEqual(w[0]?.tint, cyan, "Rests in cyan")
        lines.append(".rests → \(w.keys.sorted())")
        // [Model] with face 2 selected (img3's state): Group 2's glass
        m.selectedRegion = 2
        m.rail = .model
        XCTAssertEqual(m.rail, .model); XCTAssertEqual(m.selectedRegion, 2)
        XCTAssertEqual(Set(walls().keys), [4, 2], "[Model] + face 2: its group")
        m.selectedRegion = nil
        XCTAssertTrue(walls().isEmpty, "[Model], nothing selected: no glass")
        m.rail = .newGroup
        XCTAssertTrue(walls().isEmpty, "[+ New]: no glass")
        // the Groups view: every group and Rests, the open one brighter
        m.rail = .group(2)
        w = walls([.groups])
        XCTAssertEqual(Set(w.keys), [1, 4, 2, 3, 5, 0], "the Groups view: every group and Rests")
        for (f, it) in w {
            let open = [4, 2].contains(f)
            XCTAssertEqual(it.faceAlpha, open ? FlexibleGroupWalls.openFaceAlpha : FlexibleGroupWalls.faceAlpha, "face \(f)")
            XCTAssertEqual(it.edgeAlpha, open ? FlexibleGroupWalls.openEdgeAlpha : FlexibleGroupWalls.edgeAlpha, "face \(f)")
        }
        lines.append("the Groups view → \(w.keys.sorted()), open {4, 2} at \(FlexibleGroupWalls.openFaceAlpha)/\(FlexibleGroupWalls.openEdgeAlpha)")
        // the page's composed tints: no frame, no gap, no group colour — with a map and without one
        let ink = Self.groupInk(m)
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let withMap = Self.inked(try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: o).tints), ink)
        let mapless = Self.inked(try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: nil).tints), ink)
        lines.append("composeTints: inked \(withMap) (map) · \(mapless) (no overlay)")
        XCTAssertEqual(withMap, 0, "the Settings body wears no group colour")
        XCTAssertEqual(mapless, 0, "…nor the map-less body")
        // ★ RED CONTROLS: round 5's frames; every group walled
        FlexibleStagePage.controlRound5Frames = true
        let frames = Self.inked(try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: o).tints), ink)
        FlexibleStagePage.controlRound5Frames = false
        XCTAssertGreaterThan(frames, 0, "control: round 5's frames")
        FlexibleGroupWalls.controlEveryGroup = true
        let every = Set(walls().keys)
        FlexibleGroupWalls.controlEveryGroup = false
        XCTAssertTrue(every.contains(1), "control: group 1's glass on .group(2)")
        lines.append("controls: frames → \(frames) inked · every group → \(every.sorted())")
        print("FLEX-R6-1b\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - R6-1e

    /// ★ PAST EIGHT GROUPS THE NUMBER RIDES THE GLASS (C5's digits leave the heat): nine groups on the
    /// octagonal prism — groups 1 and 9 share green.
    func testPastEightGroupsTheNumberRidesTheWallInTheGroupsView() throws {
        let (pm, dir) = try FlexibleGroupPaletteHostedTests.prismProject()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (s, _, pressed) = try FlexibleGroupPaletteHostedTests.nineGroups(pm)
        pm.lattice.flexible = s
        let m = settledModel(pm)
        let mesh = try XCTUnwrap(pm.viewerMesh)
        XCTAssertEqual(m.squeezeGroups.count, 9)
        m.rail = .group(9)
        let discs = FlexibleGroupWalls.discs(model: m, views: [.groups], mesh: mesh)
        XCTAssertEqual(Set(discs.map(\.number)), [1, 9], "the shared colour's groups only")
        XCTAssertEqual(discs.count, 2, "one per member (each group has one face)")
        for d in discs {
            let sh = try XCTUnwrap(FlexibleGroupWalls.shell(region: d.region, regions: m.regions, mesh: mesh))
            let a = sh.base[Int(sh.indices[0])], b = sh.base[Int(sh.indices[1])], c = sh.base[Int(sh.indices[2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            XCTAssertLessThan(abs(simd_dot(d.anchor - a, n)), 1e-3, "Group \(d.number)'s disc on its glass")
            let lo = sh.base.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = sh.base.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let inside = (0..<3).allSatisfy { d.anchor[$0] >= lo[$0] - 1e-3 && d.anchor[$0] <= hi[$0] + 1e-3 }
            XCTAssertTrue(inside, "inside its glass")
            XCTAssertEqual(d.region, pressed[d.number - 1])
        }
        XCTAssertTrue(FlexibleGroupWalls.discs(model: m, views: [], mesh: mesh).isEmpty, "one group shown: its tab names it")
        // the digits are gone from the heat: the page's composition lights no plate cell in a group's colour
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        func litInGroupColour(_ t: [Float]) throws -> Int {
            let (up, fallback) = FlexibleGroupNumbers.upAndFallback(m)
            var n = 0
            for g in m.squeezeGroups where [1, 9].contains(g.number) {
                let k = try XCTUnwrap(m.key(g.regions[0])), st = try XCTUnwrap(m.stacks[k]), start = try XCTUnwrap(o.flatStart[k])
                let ax = FlexibleGroupNumbers.axes(st, up: up, fallback: fallback)
                let cells = FlexibleGroupNumbers.plate(g.number, st, right: ax.right, up: ax.up, squish: m.liveS[k]) ?? [:]
                let want = FlexibleColours.token(m.groupColour(g), 1)
                n += cells.filter { $0.value }.keys.filter { Self.rgba(t, start + $0 * 6) == want }.count
            }
            return n
        }
        let lit = try litInGroupColour(try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: o).tints))
        XCTAssertEqual(lit, 0, "no digit painted on the heat")
        // ★ RED CONTROLS: round 5's paint; the count rule
        FlexibleStagePage.controlRound5Frames = true
        let red = try litInGroupColour(try XCTUnwrap(FlexibleStagePage.composeTints(model: m, overlay: o).tints))
        FlexibleStagePage.controlRound5Frames = false
        XCTAssertGreaterThan(red, 0, "control: round 5 painted the digits")
        FlexibleGroupWalls.controlNumberByCount = true
        let byCount = Set(FlexibleGroupWalls.discs(model: m, views: [.groups], mesh: mesh).map(\.number))
        FlexibleGroupWalls.controlNumberByCount = false
        XCTAssertEqual(byCount, Set(1...9), "control: the count rule numbers every group")
        print("FLEX-R6-1e discs \(discs.map { "\($0.number)@face \($0.region)" }) · digits lit \(lit) (control \(red)) · count rule \(byCount.sorted())")
    }

    // MARK: - R6-3a

    /// ★ HIS IMG3 (the red line from the "19.0 mm" chip to its face): selecting a pressed face shows its
    /// prism at once — faint — joining the chip at its floor to the face.
    func testSelectingAPressedFaceShowsItsPrismAndNumberAtOnce() throws {
        let (_, m) = try his()
        let k = 3.0
        m.select(2)
        let items = FlexibleDepthPrism.renderItems(model: m, k: k)
        XCTAssertEqual(items.count, 1, "at rest: face 2's prism")
        let it = try XCTUnwrap(items.first)
        XCTAssertEqual(it.volume.faceID, 2)
        XCTAssertEqual(it.tint, FlexibleStageStyle.facePrismTint)
        XCTAssertEqual(it.faceAlpha, FlexibleDepthPrism.restFaceAlpha, "faint")
        XCTAssertEqual(it.edgeAlpha, FlexibleDepthPrism.restEdgeAlpha)
        guard case .shell(let sh) = it.volume.shape else { return XCTFail("a shell") }
        let f = try XCTUnwrap(m.settings.face(2))
        XCTAssertEqual(sh.reachedDepthMM, k * f.deepestMM, accuracy: 1e-3, "k × his deepest (19 mm)")
        let key = try XCTUnwrap(m.key(2))
        let want = try XCTUnwrap(FlexibleDepthPrism.volume(region: 2, stack: try XCTUnwrap(m.stacks[key]), centres: try XCTUnwrap(m.geometry[key]).centres,
                                                           depthMM: f.deepestMM, k: k, footprint: m.prismFootprint(2)))
        XCTAssertNotNil(m.prismFootprint(2), "a Stamp face")
        XCTAssertEqual(it.volume, want, "on face 2's stamp footprint")
        // the chip sits on the prism's floor
        let h = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k))
        XCTAssertEqual(h.anchor, try XCTUnwrap(FlexibleDepthPrism.handle(want)).anchor, "the chip at the drawn prism's floor")
        // dragging: the contact look
        m.frozenExaggeration = k
        XCTAssertNil(FlexibleDepthPrism.renderItems(model: m, k: k).first?.faceAlpha, "dragging: nil alphas")
        m.frozenExaggeration = nil
        // a resting face: no prism
        m.select(0)
        XCTAssertTrue(FlexibleDepthPrism.renderItems(model: m, k: k).isEmpty, "face 0 rests: no prism")
        // ★ RED CONTROL: round 3's rule — only while dragged
        m.select(2)
        FlexibleDepthPrism.controlOnlyWhileDragging = true
        let red = FlexibleDepthPrism.renderItems(model: m, k: k)
        FlexibleDepthPrism.controlOnlyWhileDragging = false
        XCTAssertTrue(red.isEmpty, "control: round 3 drew nothing at rest")
        print(String(format: "FLEX-R6-3a face 2: prism %.1f mm (k %.0f × %.1f) · alphas %.2f / %.2f · chip on its floor",
                     sh.reachedDepthMM, k, f.deepestMM, it.faceAlpha ?? -1, it.edgeAlpha ?? -1))
    }

    // MARK: - R6-3b

    /// A projection of `mesh` at his img2's camera (the renderer's own clip-from-model).
    func projection(_ project: ProjectModel, size: CGFloat = 900) throws -> CameraProjection {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(project.viewerMesh))
        mr.beginSettle(to: project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: .pi / 4, elevation: .pi / 6)
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
    }

    /// ★ "THERE SHOULD ALSO BE A VIEW THAT TURNS ON/OFF ALL SQUISH PRISMS."
    func testThePrismsViewDrawsEveryPressedFacesPrismWithItsNumber() throws {
        let (r, m) = try his()
        let k = 3.0
        m.select(2)
        let items = FlexibleDepthPrism.renderItems(model: m, k: k, views: [.prisms])
        XCTAssertEqual(Set(items.map(\.volume.faceID)), [1, 4, 2, 3, 5], "every pressed face")
        XCTAssertEqual(items.count, 5)
        for it in items {
            let r = it.volume.faceID
            let key = try XCTUnwrap(m.key(r)), f = try XCTUnwrap(m.settings.face(r))
            let want = FlexibleDepthPrism.volume(region: r, stack: try XCTUnwrap(m.stacks[key]), centres: try XCTUnwrap(m.geometry[key]).centres,
                                                 depthMM: f.deepestMM, k: k, footprint: m.prismFootprint(r))
            XCTAssertEqual(it.volume, want, "face \(r): on its stamp footprint")
            XCTAssertEqual(it.faceAlpha, r == 2 ? FlexibleDepthPrism.viewSelectedFaceAlpha : FlexibleDepthPrism.restFaceAlpha, "face \(r)")
        }
        XCTAssertGreaterThan(FlexibleDepthPrism.viewSelectedFaceAlpha, FlexibleDepthPrism.restFaceAlpha, "the selected one brighter")
        // the tags: one per uncovered prism, the selected face's is its chip
        m.views = [.prisms]
        let proj = try projection(r.project)
        let tags = FlexibleStageViewTags.tags(model: m, k: k, projection: proj, keepOut: [])
        XCTAssertFalse(tags.contains { $0.region == 2 }, "the selected face shows its chip, not a tag")
        XCTAssertGreaterThanOrEqual(tags.count, 2, "the other faces' tags (overlaps dropped)")
        for t in tags {
            let f = try XCTUnwrap(m.settings.face(t.region))
            XCTAssertEqual(t.text, String(format: "%.1f mm", f.deepestMM), "face \(t.region): his deepest, read-only")
        }
        for (i, a) in tags.enumerated() { for b in tags[(i + 1)...] {
            XCTAssertFalse(FlexibleStageViewTags.frame(a).intersects(FlexibleStageViewTags.frame(b)), "tags \(a.region) and \(b.region) never overlap")
        } }
        // a keep-out hides a tag under it
        if let t = tags.first {
            let hidden = FlexibleStageViewTags.tags(model: m, k: k, projection: proj, keepOut: [FlexibleStageViewTags.frame(t)])
            XCTAssertFalse(hidden.contains { $0.region == t.region }, "a tag under a keep-out hides")
            // a tag's tap selects that face (its chip replaces the tag)
            FlexibleStageViewTags.tap(t, model: m)
            XCTAssertEqual(m.selectedRegion, t.region, "a tag tap selects its face")
        }
        // ★ RED CONTROL: no view — the selected face's prism alone
        XCTAssertEqual(FlexibleDepthPrism.renderItems(model: m, k: k, views: []).count, 1, "control: without the view, one prism")
        print("FLEX-R6-3b prisms \(items.map(\.volume.faceID)) · tags " + tags.map { "face \($0.region) \($0.text)" }.joined(separator: ", "))
    }

    // MARK: - R6-3c (hosted)

    /// ★ THE VIEW BUTTONS SIT UNDER THE GIZMO, CLEAR OF EVERYTHING — the page hosted at 11" and 13", both ways.
    func testTheSettingsTogglesSitUnderTheGizmoClearOfEverything() throws {
        let (r, m) = try his()
        m.select(2)
        m.views = [.prisms, .groups]
        var lines: [String] = []
        for (tag, size) in Self.sizes {
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            let buttons = try XCTUnwrap(local(h, "viewButtons"), "\(tag): the view buttons are on the page")
            let want = FlexibleStageViews.frame(viewport: size)
            XCTAssertLessThan(max(abs(buttons.minX - want.minX), abs(buttons.minY - want.minY), abs(buttons.width - want.width),
                                  abs(buttons.height - want.height)), 1, "\(tag): drawn where the keep-outs think (\(buttons) vs \(want))")
            let gizmo = FlexibleLegendPlacement.gizmoFrame(viewport: size)
            XCTAssertGreaterThanOrEqual(buttons.minY, gizmo.maxY, "\(tag): under the gizmo's touch square")
            XCTAssertLessThanOrEqual(buttons.maxX, size.width - PageChrome.edge + 0.5, "\(tag): on the trailing edge")
            for other in ["notice", "legend", "panel", "player", "playerCapsule", "playerTopRow", "popup", "exitRow"] {
                guard let f = local(h, other) else { continue }
                XCTAssertFalse(f.intersects(buttons), "\(tag): the buttons clear the \(other) (\(f) vs \(buttons))")
            }
            // the chips / tags / curves keep out of the buttons (`stageKeepOut`)
            let centre = CGPoint(x: buttons.midX, y: buttons.midY)
            XCTAssertFalse(FlexibleDepthChipLayout.visible(centre, keepOut: FlexibleStagePage.stageKeepOut(h.frames.all), viewport: size),
                           "\(tag): nothing on the part is drawn under the buttons")
            // ★ RED CONTROL: the keep-out omitted — a chip under the buttons shows (an overlap)
            var without = h.frames.all
            without["viewButtons"] = nil
            let overlaps = FlexibleDepthChipLayout.visible(centre, keepOut: FlexibleStagePage.stageKeepOut(without), viewport: size)
            XCTAssertTrue(overlaps, "\(tag): control — without the keep-out a chip lies under the buttons")
            lines.append("\(tag) buttons \(buttons) · gizmo \(gizmo) · legend \(local(h, "legend").map { "\($0)" } ?? "—") · control: overlap with the chips \(overlaps)")
            snapshot(h, "R6_\(tag)_settings_views.png")
        }
        print("FLEX-R6-3c\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - R6-3d

    /// ★ ONE LEGEND CARD PER PAGE: a view on brings the card (with no dent too); its rows are one line each.
    func testOneLegendCardCarriesTheViewRows() throws {
        XCTAssertTrue(FlexibleLegend.shows(hasDent: false, views: [.prisms]), "a view on with no dent: the card")
        XCTAssertTrue(FlexibleLegend.shows(hasDent: false, views: [.groups]))
        XCTAssertTrue(FlexibleLegend.shows(hasDent: true, views: []))
        XCTAssertFalse(FlexibleLegend.shows(hasDent: false, views: []))
        for line in [FlexibleRowCopy.legendPrismsRow(7), FlexibleRowCopy.legendPrismsRow(120), FlexibleRowCopy.legendGroupsRow] {
            XCTAssertFalse(line.isEmpty)
            XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars, line)
            XCTAssertEqual(FlexibleRowCopy.fit(line), line, "fitted")
        }
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertEqual(page.components(separatedBy: "FlexibleLegend(model:").count - 1, 1, "exactly one card on the page")
        XCTAssertTrue(page.contains("FlexibleLegend.shows(hasDent: dents != nil, views: model.views)"), "the page reads the rule")
        // hosted: both rows on, each one line
        let (r, m) = try his()
        m.select(2)
        m.views = [.prisms, .groups]
        var lines: [String] = []
        for (tag, size) in [Self.sizes[0], Self.sizes[2]] {
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            let legend = try XCTUnwrap(local(h, "legend"), "\(tag): the card")
            for row in ["legendPrismsRow", "legendGroupsRow"] {
                let f = try XCTUnwrap(local(h, row), "\(tag): \(row)")
                XCTAssertLessThanOrEqual(f.height, 22, "\(tag): \(row) is one line")
                XCTAssertTrue(legend.insetBy(dx: -1, dy: -1).contains(f), "\(tag): \(row) in the one card")
                lines.append("\(tag) \(row) \(f)")
            }
            snapshot(h, "R6_\(tag)_legend_views.png")
        }
        print("FLEX-R6-3d " + lines.joined(separator: " · "))
    }

    // MARK: - R6-3f

    /// ★ THE MAIN PAGE'S PRISMS (the list hook H15 hands the viewer): the active Selections group's pressed
    /// faces, every pressed face in the Prisms view; nothing off the Flexible stage or while a legend reads.
    func testTheMainPageDrawsTheActiveGroupsPrismsAndThePrismsView() throws {
        let stage = FlexibleMainStage()
        let (r, m) = try his(stage)
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        r.project.selection.setActive(top.id)
        stage.refresh()
        let active = stage.volumes(r.project, on: .lattice, drilledIn: false)
        XCTAssertEqual(active.map(\.volume.faceID), [1], "the active group Top: face 1's prism")
        XCTAssertNotNil(active.first?.faceAlpha, "faint")
        m.views = [.prisms]
        let all = stage.volumes(r.project, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(all.map(\.volume.faceID)), [1, 4, 2, 3, 5], "the Prisms view: every pressed face")
        XCTAssertTrue(stage.volumes(r.project, on: .topology, drilledIn: false).isEmpty, "off the Flexible stage")
        XCTAssertTrue(stage.volumes(r.project, on: .lattice, drilledIn: true).isEmpty, "while a legend reads")
        m.views = []
        print("FLEX-R6-3f active Top → \(active.map(\.volume.faceID)) · Prisms view → \(all.map(\.volume.faceID).sorted())")
    }

    // MARK: - R6-3g / R6-3h (the main page's [Prisms] button: step 6, on the S1 base)

    func s1Base() throws {
        guard try FlexibleSource.code("WorkspacePlaceholder.swift").contains("legendDrilledIn") else {
            print("FLEX-R6 SKIP \(name): the base is not S1 — the main page's [Prisms] button waits (step 6)")
            throw XCTSkip("waits on the S1 base")
        }
    }

    func testTheFourMainButtonsClearTheNoteLegendAndPlayer() throws {
        try s1Base()
        XCTAssertEqual(FlexibleMainViewToggles.buttons, 4, "Dent heat, Stress, Lattice, Prisms")
        for (tag, size) in Self.sizes {
            let row = FlexibleMainViewToggles.rowFrame(viewport: size)
            XCTAssertEqual(row.width, 4 * 40 + 3 * DS.Space.s, tag)
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 120, chipColumnWidth: 180)
            XCTAssertTrue(keep.contains { $0.contains(row) }, "\(tag): the legends keep out of the four buttons")
            XCTAssertTrue(FlexibleMainPlayerSlot.keepOut(viewport: size).contains { $0.contains(row) }, "\(tag): the player too")
        }
    }

    func testPrismsTurnsTheLatticeViewOnItself() throws {
        try s1Base()
        let stage = FlexibleMainStage()
        let (_, m) = try his(stage)
        stage.latticeOn = false
        stage.togglePrisms()
        XCTAssertTrue(m.views.contains(.prisms))
        XCTAssertTrue(stage.latticeOn, "[Prisms] turns the Lattice view (the X-ray) on itself")
    }
}
#endif
