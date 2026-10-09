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
//   R6-3g  the main page's [Prisms] button — ★ S1b: un-gated (the S1 base is on this branch); R6-3h (togglePrisms).
// ★ S1b (2026-10-08, the main-page half of item 3): R6-3j the fourth button IS [Prisms] (clicked, hosted); R6-3k the main
//   page's ONE legend card carries the Prisms row while it is on (hosted, one line, inside the card); R6-3l selecting a
//   group on the main page shows its squish AT ONCE — its faint prism and its read-only mm tag, on the hosted page too.
// ★ R6 REVIEW (the verifier's findings, 2026-10-08): R6R-0 the page's one list carries the glass AND the prisms; R6R-4
//   with no dent the chip stands on the drawn prism's floor (one k); R6R-2 the tags, discs and dashed outlines are on the
//   hosted page; R6R-6 a member that faces away is drawn dashed ([Rests] from above).
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

    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
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
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }   // ★ R6 REVIEW: what the views' layer drew
            .environment(\.colorScheme, .dark))
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
        // ★ R6 REVIEW: a glass's alphas are its colour's over its own heat (FlexibleGroupWalls.alphas — no heat given here:
        // the page's backdrop); measured on his pad by FlexibleRound6Tests (R6R-1)
        let tab = FlexibleGroupWalls.alphas(tint: pink, heat: [], open: false), openTab = FlexibleGroupWalls.alphas(tint: pink, heat: [], open: true)
        for it in w.values {
            XCTAssertEqual(it.tint, pink); XCTAssertEqual(it.faceAlpha, tab.face); XCTAssertEqual(it.edgeAlpha, tab.edge)
            XCTAssertTrue(it.surfaceOnly, "a glass: its base only")
        }
        XCTAssertLessThan(tab.face, openTab.face, "the open group brighter in the Groups view")
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
            let want = FlexibleGroupWalls.alphas(tint: try XCTUnwrap(it.tint), heat: [], open: open)
            XCTAssertEqual(it.faceAlpha, want.face, "face \(f)")
            XCTAssertEqual(it.edgeAlpha, want.edge, "face \(f)")
        }
        lines.append("the Groups view → \(w.keys.sorted()), open {4, 2} at \(openTab.face)/\(openTab.edge)")
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
    func projection(_ project: ProjectModel, size: CGFloat = 900, elevation: Float = .pi / 6, azimuth: Float = .pi / 4) throws -> CameraProjection {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(project.viewerMesh))
        mr.beginSettle(to: project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: azimuth, elevation: elevation)
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
    // ★ S1b (2026-10-08): UN-GATED — the S1 base is on this branch (e2652a41); R6-3g runs, red until the fourth button.

    func testTheFourMainButtonsClearTheNoteLegendAndPlayer() throws {
        XCTAssertTrue(try FlexibleSource.code("WorkspacePlaceholder.swift").contains("legendDrilledIn"), "premise: the S1 base")
        XCTAssertEqual(FlexibleMainViewToggles.buttons, 4, "Dent heat, Stress, Lattice, Prisms")
        for (tag, size) in Self.sizes {
            let row = FlexibleMainViewToggles.rowFrame(viewport: size)
            XCTAssertEqual(row.width, 4 * 40 + 3 * DS.Space.s, tag)
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 120, chipColumnWidth: 180)
            XCTAssertTrue(keep.contains { $0.contains(row) }, "\(tag): the legends keep out of the four buttons")
            XCTAssertTrue(FlexibleMainPlayerSlot.keepOut(viewport: size).contains { $0.contains(row) }, "\(tag): the player too")
        }
        // ★ S1b: THE NARROW PAD (iPad mini, 744 × 1133 portrait — FlexibleMainPageRound4VerifyTests' "mini"). Four in a row
        // leave the "Lattice ready · Show" note 148 pt beside them, under its 180 (that test went red on the fourth button):
        // there the four wrap two over two, and the note keeps its room on the row's line, clear of the left panel.
        let mini = CGSize(width: 744, height: 1133)
        let row = FlexibleMainViewToggles.rowFrame(viewport: mini), note = FlexibleMainViewToggles.noteFrame(viewport: mini)
        XCTAssertEqual(FlexibleMainViewToggles.columns(viewport: mini), 2, "mini: two over two")
        XCTAssertEqual(row.width, 2 * 40 + DS.Space.s, "mini: two 40 pt buttons across")
        XCTAssertEqual(row.height, 2 * 40 + DS.Space.s, "mini: two lines")
        XCTAssertGreaterThanOrEqual(note.width, FlexibleMainNote.minWidth, "mini: the note keeps its room")
        XCTAssertFalse(note.intersects(FlexibleMainLegendLayout.leftStrip(viewport: mini)), "mini: clear of the left panel")
        for (tag, size) in Self.sizes { XCTAssertEqual(FlexibleMainViewToggles.columns(viewport: size), 4, "\(tag): one line of four") }
        print("FLEX-R6-3g mini row \(row.integral) · note \(note.integral)")
    }

    /// ★ R6 REVIEW: un-gated — `togglePrisms` is on this base (only its button waits for S1), so it is tested now.
    func testPrismsTurnsTheLatticeViewOnItself() throws {
        let stage = FlexibleMainStage()
        let (_, m) = try his(stage)
        stage.latticeOn = false
        stage.togglePrisms()
        XCTAssertTrue(m.views.contains(.prisms))
        XCTAssertTrue(stage.latticeOn, "[Prisms] turns the Lattice view (the X-ray) on itself")
        // off again: the Prisms view goes, the Lattice view stays as he left it
        stage.togglePrisms()
        XCTAssertFalse(m.views.contains(.prisms))
        XCTAssertTrue(stage.latticeOn)
    }

    // MARK: - S1b: the main-page half of item 3 (R6-3j, R6-3k, R6-3l)

    /// A click at `p` (the page's points, y down) through the window (FlexibleMainPageRound4HostedTests' own).
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    /// ★ R6-3j: THE FOURTH BUTTON IS [Prisms] — clicked on the hosted row: the Prisms view on (every pressed face's
    /// prism in H15's list) and the Lattice view with it; clicked again: off, the Lattice view as he left it. The
    /// third is still Lattice. RED before the button: the trailing button is Lattice (the click toggles the lattice
    /// and no prism view comes on).
    func testThePrismsButtonIsTheFourthAndShowsEveryPrism() throws {
        let code = try FlexibleSource.code("FlexibleMainStatusPill.swift")
        XCTAssertTrue(code.contains("\"flexible-main-view-prisms\""), "the button's accessibility id")
        XCTAssertTrue(code.contains("main.togglePrisms()"), "it asks the stage (the Lattice view comes with it)")
        let stage = FlexibleMainStage()
        let (r, m) = try his(stage)
        var opened = 0
        var lines: [String] = []
        for (tag, size) in [Self.sizes[0], Self.sizes[1]] {
            let h = host(FlexibleMainViewToggles(main: stage, openSettings: { opened += 1 }), size: size)
            pump(0.3)
            let row = FlexibleMainViewToggles.rowFrame(viewport: size)
            let prisms = CGPoint(x: row.maxX - 20, y: row.midY)                               // the fourth (trailing)
            let lattice = CGPoint(x: row.minX + 2 * (40 + DS.Space.s) + 20, y: row.midY)      // the third
            m.views = []
            stage.latticeOn = false
            click(h, prisms)
            XCTAssertTrue(m.views.contains(.prisms), "\(tag): [Prisms] on")
            XCTAssertTrue(stage.latticeOn, "\(tag): …and the Lattice view (the X-ray) with it")
            XCTAssertEqual(Set(stage.volumes(r.project, on: .lattice, drilledIn: false).map(\.volume.faceID)), [1, 4, 2, 3, 5],
                           "\(tag): every pressed face's prism in H15's list")
            click(h, prisms)
            XCTAssertFalse(m.views.contains(.prisms), "\(tag): off again")
            XCTAssertTrue(stage.latticeOn, "\(tag): the Lattice view stays as he left it")
            // the third is still Lattice: it never touches the Prisms view
            let before = (stage.latticeOn, opened)
            click(h, lattice)
            XCTAssertFalse(m.views.contains(.prisms), "\(tag): Lattice is not Prisms")
            XCTAssertTrue(stage.latticeOn != before.0 || opened == before.1 + 1, "\(tag): the third button is Lattice (hides it, or opens Settings)")
            lines.append("\(tag) row \(row.integral)")
            snapshot(h, "R6_S1b_\(tag)_main_four_buttons.png")
        }
        // ★ the narrow pad (iPad mini portrait): two over two, as `rowFrame` says — [Prisms] bottom right, Lattice bottom left
        let mini = CGSize(width: 744, height: 1133)
        let h = host(FlexibleMainViewToggles(main: stage, openSettings: { opened += 1 }), size: mini)
        pump(0.3)
        let row = FlexibleMainViewToggles.rowFrame(viewport: mini)
        m.views = []
        stage.latticeOn = false
        click(h, CGPoint(x: row.maxX - 20, y: row.maxY - 20))
        XCTAssertTrue(m.views.contains(.prisms), "mini: [Prisms] is bottom right")
        XCTAssertTrue(stage.latticeOn, "mini: …with the Lattice view")
        click(h, CGPoint(x: row.maxX - 20, y: row.maxY - 20))
        let before = (stage.latticeOn, opened)
        click(h, CGPoint(x: row.minX + 20, y: row.maxY - 20))
        XCTAssertFalse(m.views.contains(.prisms), "mini: bottom left is not Prisms")
        XCTAssertTrue(stage.latticeOn != before.0 || opened == before.1 + 1, "mini: bottom left is Lattice")
        snapshot(h, "R6_S1b_mini_main_buttons_two_over_two.png")
        lines.append("mini row \(row.integral)")
        m.views = []
        print("FLEX-R6-3j " + lines.joined(separator: " · "))
    }

    /// ★ R6-3k: THE MAIN PAGE'S ONE LEGEND CARD GAINS THE PRISMS ROW while [Prisms] is on — one line, inside the card,
    /// "Prism = squish shown ×k" at the page's ONE k; with no scale to show, the card still comes, for its row. RED
    /// before: no row, and no card without a scale.
    func testTheMainLegendCardCarriesThePrismsRowWhilePrismsIsOn() throws {
        let legends = try FlexibleSource.code("FlexibleMainLegends.swift")
        XCTAssertEqual(legends.components(separatedBy: "FlexibleLegendViewRows.prisms(k: main.prismLegendK)").count - 1, 1,
                       "one Prisms row, in the one card, at the page's k")
        let rows1 = FlexibleMainLegendLayout.cardSize(rows: 1, minimized: false)
        let rows1Prisms = FlexibleMainLegendLayout.cardSize(rows: 1, minimized: false, viewRows: 1)
        XCTAssertEqual(rows1Prisms.height, rows1.height + FlexibleMainLegendLayout.viewRowHeight, accuracy: 0.5, "the row adds one line")
        XCTAssertGreaterThan(FlexibleMainLegendLayout.viewRowHeight, 0)
        let stage = FlexibleMainStage()
        let (_, m) = try his(stage)
        stage.heat = false
        stage.stress = false
        stage.latticeOn = false
        stage.refresh()
        XCTAssertEqual(stage.legendKinds, [], "premise: no scale on screen")
        let v = Self.sizes[0].1
        m.views = []
        XCTAssertFalse(stage.legendPrismsRow)
        XCTAssertNil(stage.legendCard(viewport: v, bottomClearance: 90, chipColumnWidth: 0), "no view, no scale: no card")
        m.views = [.prisms]
        XCTAssertTrue(stage.legendPrismsRow, "[Prisms] on: the row")
        let only = try XCTUnwrap(stage.legendCard(viewport: v, bottomClearance: 90, chipColumnWidth: 0), "[Prisms] with no scale: the card, for its row")
        XCTAssertTrue(only.expanded)
        XCTAssertEqual(stage.prismLegendK, Int(stage.prismK.rounded()), "the row's ×k is the prisms' k")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.legendPrismsRow(stage.prismLegendK).count, FlexibleRowCopy.maxChars)
        var lines: [String] = []
        for (tag, size) in [Self.sizes[0], Self.sizes[2]] {
            m.views = [.prisms]
            let h = host(FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)),
                                             bottomClearance: 90, chipColumnWidth: 0), size: size)
            pump(0.5)
            let card = try XCTUnwrap(stage.legendCard(viewport: size, bottomClearance: 90, chipColumnWidth: 0), "\(tag): the card")
            let row = try XCTUnwrap(h.frames.all["legendPrismsRow"], "\(tag): the Prisms row is drawn")
            XCTAssertLessThanOrEqual(row.height, 22, "\(tag): one line")
            XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(row), "\(tag): inside the one card (\(row) in \(card.frame))")
            snapshot(h, "R6_S1b_\(tag)_main_legend_prisms_row.png")
            m.views = []
            pump(0.5)
            XCTAssertNil(h.frames.all["legendPrismsRow"].flatMap { $0.width > 1 ? $0 : nil }, "\(tag): [Prisms] off: no row")
            lines.append("\(tag) card \(card.frame.integral) row \(row.integral)")
        }
        print("FLEX-R6-3k " + lines.joined(separator: " · "))
    }

    /// ★ R6-3l: SELECTING A GROUP ON THE MAIN PAGE SHOWS ITS SQUISH AT ONCE — no refresh, no view switch: its pressed
    /// faces' faint prisms (H15's list) and a read-only "%.1f mm" tag at each prism's floor; the Prisms view tags every
    /// uncovered prism, greedy (none overlap), hidden under a keep-out; nothing while a legend reads or off the stage.
    /// Hosted: the tag is ON the main page (FlexibleMainLegends' layer), where the page projects the floor. RED before:
    /// no tags.
    func testSelectingAGroupOnTheMainPageShowsItsSquishAtOnce() throws {
        let stage = FlexibleMainStage()
        let (r, m) = try his(stage)
        let size = CGSize(width: 900, height: 900)
        let proj = try projection(r.project)
        func tags(_ drilledIn: Bool = false, on s: WorkspaceStage = .lattice, keepOut: [CGRect] = []) -> [FlexibleStageViewTags.Tag] {
            stage.prismTags(r.project, on: s, drilledIn: drilledIn, viewport: size, keepOut: keepOut, projector: { proj.project($0) })
        }
        print("FLEX-R6-3l main groups: " + r.project.selection.groups.map { "\($0.name) faces \($0.faces) regions \($0.regionIDs.count)" }.joined(separator: " · "))
        var lines: [String] = []
        for (name, want) in [("Top", 1), ("Group C", 3)] {
            guard let g = r.project.selection.groups.first(where: { $0.name == name }) else { XCTFail("his group \(name)"); continue }
            r.project.selection.setActive(g.id)
            // AT ONCE: no refresh, no view switch
            let vols = stage.volumes(r.project, on: .lattice, drilledIn: false)
            XCTAssertEqual(vols.map(\.volume.faceID), [want], "\(name): face \(want)'s prism")
            let t = tags()
            XCTAssertEqual(t.map(\.region), [want], "\(name): face \(want)'s mm tag, at once")
            let f = try XCTUnwrap(m.settings.face(want))
            XCTAssertEqual(t.first?.text, String(format: "%.1f mm", f.deepestMM), "\(name): his deepest, read-only")
            if let v = vols.first, let tag = t.first {
                let floor = try XCTUnwrap(FlexibleDepthPrism.handle(v.volume)).anchor
                let p = try XCTUnwrap(proj.project(floor))
                XCTAssertEqual(tag.point.x, p.x, accuracy: 1e-3, "\(name): at the prism's floor")
                XCTAssertEqual(tag.point.y, p.y, accuracy: 1e-3)
                lines.append("\(name) → face \(tag.region) \(tag.text) at \(tag.point)")
            }
            XCTAssertEqual(m.views, [], "\(name): selecting never switches views")
        }
        // the Prisms view: a tag per uncovered prism, never overlapping, each his deepest
        m.views = [.prisms]
        let all = tags()
        XCTAssertGreaterThanOrEqual(all.count, 2, "the Prisms view's tags (overlaps dropped)")
        for t in all {
            XCTAssertEqual(t.text, String(format: "%.1f mm", try XCTUnwrap(m.settings.face(t.region)).deepestMM), "face \(t.region)")
        }
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] {
            XCTAssertFalse(FlexibleStageViewTags.frame(a).intersects(FlexibleStageViewTags.frame(b)), "tags \(a.region) and \(b.region) never overlap")
        } }
        if let first = all.first {
            XCTAssertFalse(tags(keepOut: [FlexibleStageViewTags.frame(first)]).contains { $0.region == first.region }, "a tag under a keep-out hides")
        }
        XCTAssertTrue(tags(true).isEmpty, "nothing while a legend reads")
        XCTAssertTrue(tags(on: .topology).isEmpty, "nothing off the Flexible stage")
        lines.append("Prisms view → " + all.map { "face \($0.region) \($0.text)" }.joined(separator: ", "))
        // hosted: the tag is on the main page, where the page projects the floor
        m.views = []
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        r.project.selection.setActive(top.id)
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        var cam = OrbitCamera()
        cam.frame(mesh.bounds)
        cam.setOrientation(azimuth: .pi / 4, elevation: .pi / 6)
        let v = Self.sizes[0].1
        let camera = CameraProjection(camera: cam, viewportSize: v)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let h = host(FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: camera, settle: settle,
                                         bottomClearance: 90, chipColumnWidth: 0), size: v)
        pump(0.5)
        let mark = try XCTUnwrap(h.frames.marks["tag-1"], "the Top's face 1 tag is ON the main page")
        let floor = try XCTUnwrap(stage.volumes(r.project, on: .lattice, drilledIn: false).first.flatMap { FlexibleDepthPrism.handle($0.volume) }).anchor
        let want = try XCTUnwrap(stage.screenPoint(floor))
        XCTAssertEqual(mark.midX, want.x, accuracy: 1, "at the floor, where the page projects it")
        XCTAssertEqual(mark.midY, want.y, accuracy: 1)
        snapshot(h, "R6_S1b_11l_main_top_tag.png")
        lines.append("hosted tag-1 \(mark.integral)")
        print("FLEX-R6-3l " + lines.joined(separator: " · "))
    }

    // MARK: - R6 REVIEW (the verifier's findings of 2026-10-08)

    /// ★ THE PAGE'S ONE LIST CARRIES THE GLASS AND THE PRISMS (the verifier: dropping the walls from
    /// `FlexibleStageVolumes.items` left every test green — item 1's whole Settings deliverable could vanish).
    func testThePagesOneListCarriesTheGlassAndThePrisms() throws {
        let (r, m) = try his()
        let part = try XCTUnwrap(r.project.viewerMesh)
        let k = 3.0
        func split(_ items: [ClearanceRenderItem]) -> (glass: [Int], prisms: [Int]) {
            (items.filter(\.surfaceOnly).map(\.volume.faceID), items.filter { !$0.surfaceOnly }.map(\.volume.faceID))
        }
        m.rail = .group(2)
        m.selectedRegion = 2
        var lines: [String] = []
        for (views, glass, prisms) in [(FlexibleStageViews(), Set([4, 2]), [2]), ([.groups], Set([1, 4, 2, 3, 5, 0]), [2]),
                                       ([.prisms, .groups], Set([1, 4, 2, 3, 5, 0]), [1, 4, 2, 3, 5]), ([.prisms], Set([4, 2]), [1, 4, 2, 3, 5])] {
            m.views = views
            let items = FlexibleStageVolumes.items(model: m, k: k, part: part)
            let s = split(items)
            XCTAssertEqual(Set(s.glass), glass, "views \(views.rawValue): the glass")
            XCTAssertEqual(s.glass.count, glass.count, "views \(views.rawValue): one glass per member")
            XCTAssertEqual(Set(s.prisms), Set(prisms), "views \(views.rawValue): the prisms")
            XCTAssertEqual(items, FlexibleDepthPrism.renderItems(model: m, k: k, views: views)
                           + FlexibleGroupWalls.items(model: m, views: views, mesh: part), "views \(views.rawValue): the prisms, then the glass")
            lines.append("views \(views.rawValue) → glass \(s.glass) · prisms \(s.prisms)")
        }
        m.views = []
        print("FLEX-R6R-0 " + lines.joined(separator: " · "))
    }

    /// ★ WITH NO DENT THE CHIP STANDS ON THE DRAWN PRISM'S FLOOR (the verifier: the page's k is 0 while no dent is
    /// shown; the prism and the tags drew at k 1, the chip and the stamp handle at 0 — the chip sat ON the face while
    /// the prism ended deepest × 1 inside the part: his img3 again). One k for all of them (`prismK`).
    func testWithNoDentTheChipStandsOnTheDrawnPrismsFloor() throws {
        let (r, m) = try his()
        let part = try XCTUnwrap(r.project.viewerMesh)
        m.rail = .group(2)
        m.selectedRegion = 2
        XCTAssertEqual(FlexibleStageVolumes.prismK(0), 1, "no dent: the prism's true depth")
        XCTAssertEqual(FlexibleStageVolumes.prismK(4.5), 4.5, "a dent: its exaggeration")
        let k = FlexibleStageVolumes.prismK(0)
        let prism = try XCTUnwrap(FlexibleStageVolumes.items(model: m, k: 0, part: part).first { !$0.surfaceOnly && $0.volume.faceID == 2 })
        let floor = try XCTUnwrap(FlexibleDepthPrism.handle(prism.volume)).anchor
        let chip = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k)).anchor
        XCTAssertLessThan(simd_distance(chip, floor), 1e-3, "the chip on the drawn prism's floor")
        // ★ RED CONTROL: the page's raw 0 (before) — the chip off the floor
        let raw = FlexibleDepthChips.handle(model: m, k: 0)?.anchor
        let off = raw.map { simd_distance($0, floor) } ?? .infinity
        XCTAssertGreaterThan(off, 1, "control: at k 0 the chip is \(off) mm off the floor")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(page.contains("FlexibleStageOverlays(model: model, proj: proj, exaggeration: FlexibleStageVolumes.prismK(dentExaggeration),"),
                      "the chips, the stamp handle and the tags read the same k")
        XCTAssertTrue(page.contains("clearanceVolumes: FlexibleStageVolumes.items(model: model, k: FlexibleStageVolumes.prismK(dentExaggeration),"),
                      "…as the prisms")
        XCTAssertTrue(page.contains("k: Int(FlexibleStageVolumes.prismK(dentExaggeration).rounded())"), "…and the legend's ×k")
        print(String(format: "FLEX-R6R-4 chip → floor %.4f mm · control (k 0) %.2f mm", simd_distance(chip, floor), off))
    }

    /// ★ THE TAGS, THE DISCS AND THE HIDDEN OUTLINES ARE ON THE PAGE (the verifier: unmounting the layer left every
    /// test green — they were tested as pure functions only). Hosted, his pad: both views on → the mm tags and the
    /// dashed outline of every shown member that faces away; [Rests] alone → the bottom's dashed outline (it faces
    /// away from every camera above it: its glass is culled, his tab looked unchanged); the nine groups → the discs.
    /// The [Groups] button's glyph is his groups' own colours.
    func testTheTagsDiscsAndHiddenOutlinesAreOnThePage() throws {
        let (r, m) = try his()
        XCTAssertEqual(FlexibleStageViews.glyphColours(model: m).map { [$0.r, $0.g, $0.b] },
                       m.squeezeGroups.prefix(3).map { m.groupColour($0) }.map { [$0.r, $0.g, $0.b] }, "the [Groups] glyph: his groups' colours")
        XCTAssertEqual(FlexibleStageViews.buttons.first { $0.view == .prisms }?.icon, "arrow.down.to.line", "[Prisms]: down to a depth")
        m.select(2)
        m.views = [.prisms, .groups]
        let size = Self.sizes[0].1
        var h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
        pump(2.5)
        let tags = h.frames.marks.keys.filter { $0.hasPrefix("tag-") }.sorted()
        let hidden = h.frames.marks.keys.filter { $0.hasPrefix("hidden-") }.sorted()
        XCTAssertFalse(tags.isEmpty, "the Prisms view's mm tags are on the page")
        XCTAssertFalse(tags.contains("tag-2"), "the selected face shows its chip")
        XCTAssertFalse(hidden.isEmpty, "the Groups view: the members that face away, dashed")
        snapshot(h, "R6R_11l_views_marks.png")
        // [Rests] alone: the bottom faces away
        m.views = []
        m.selectedRegion = nil
        m.rail = .rests
        pump(1.0)
        let rests = h.frames.marks.keys.filter { $0.hasPrefix("hidden-") }.sorted()
        XCTAssertEqual(rests, ["hidden-rests-0"], "[Rests]: the bottom's dashed outline")
        let box = try XCTUnwrap(h.frames.marks["hidden-rests-0"])
        XCTAssertGreaterThan(box.width * box.height, 100 * 100, "…round the whole bottom (\(box))")
        snapshot(h, "R6R_11l_rests_tab.png")
        m.rail = .group(2)
        // the nine groups: the discs of the shared colour
        let (pm, dir) = try FlexibleGroupPaletteHostedTests.prismProject()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (s, _, _) = try FlexibleGroupPaletteHostedTests.nineGroups(pm)
        pm.lattice.flexible = s
        let nine = settledModel(pm)
        nine.views = [.groups]
        h = host(FlexibleStagePage(project: pm, model: nine, onExit: {}), size: size)
        pump(2.5)
        let discs = h.frames.marks.keys.filter { $0.hasPrefix("disc-") }.sorted()
        XCTAssertFalse(discs.isEmpty, "the nine groups: the shared colour's discs are on the page")
        snapshot(h, "R6R_11l_nine_groups_discs.png")
        print("FLEX-R6R-2 tags \(tags) · hidden \(hidden) · [Rests] \(rests) \(box) · nine groups' discs \(discs)")
    }

    /// ★ A MEMBER THAT FACES AWAY IS DRAWN DASHED (the verifier: "the Rests tab, and Rests in the Groups view, show
    /// nothing but a thin outline" — the glass culls a member facing away, so colours never mix through the X-ray, and
    /// the renderer's 1 px line ran along the part's own edges). His img2 and img3 cameras.
    func testAMemberThatFacesAwayIsDrawnDashed() throws {
        let (r, m) = try his()
        let iso = try projection(r.project)
        let top = try projection(r.project, elevation: 1.1, azimuth: .pi / 5)
        func hidden(_ p: CameraProjection) -> [Int: FlexibleStageViewTags.Hidden] {
            Dictionary(FlexibleStageViewTags.hidden(model: m, projection: p).map { ($0.region, $0) }) { a, _ in a }
        }
        func length(_ h: FlexibleStageViewTags.Hidden) -> CGFloat {
            h.paths.reduce(0) { acc, loop in
                acc + loop.indices.reduce(0) { $0 + hypot(loop[$1].x - loop[($1 + 1) % loop.count].x, loop[$1].y - loop[($1 + 1) % loop.count].y) }
            }
        }
        var lines: [String] = []
        m.selectedRegion = nil
        m.rail = .rests
        for (name, p) in [("iso (img2)", iso), ("top (img3)", top)] {
            let h = hidden(p)
            XCTAssertEqual(Set(h.keys), [0], "\(name) · [Rests]: the bottom, dashed")
            let rest = try XCTUnwrap(h[0])
            XCTAssertEqual(rest.key, "rests")
            XCTAssertEqual(rest.paths.count, 1, "one loop")
            XCTAssertGreaterThan(length(rest), 600, "\(name): round the whole bottom (\(length(rest)) pt)")
            lines.append("\(name) [Rests] → face 0, \(Int(length(rest))) pt")
        }
        m.rail = .group(2)
        XCTAssertEqual(Set(hidden(iso).keys), [4], "iso · Group 2: face 4 faces away, face 2 does not")
        m.rail = .group(1)
        XCTAssertTrue(hidden(top).isEmpty, "top · Group 1: the top faces the camera")
        m.rail = .model
        m.views = [.groups]
        let all = Set(hidden(iso).keys)
        XCTAssertEqual(all, [4, 5, 0], "iso · the Groups view: the members that face away")
        m.views = []
        XCTAssertTrue(hidden(iso).isEmpty, "[Model], nothing selected: nothing shown")
        lines.append("Group 2 iso → [4] · Groups view iso → \(all.sorted())")
        print("FLEX-R6R-6 " + lines.joined(separator: " · "))
    }
}
#endif
