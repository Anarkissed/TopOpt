// TopologyInLatticeNotes1122Tests — his iPad notes 2026-11-22 (img 6, 11, 12).
//
// His words: "When I tap on the "Topology" selections, it should automatically show all the topology assets - I should be able
// to edit the groups/faces/anchors/loads/design box from Topology. It should immediately hide all things for the lattice
// selections." — "I only want 6 handles at a time, for each primitive I select." — on the Forces view: "I'd rather have something
// that hides all the keep clears" (his decision: keep Forces, add "Hide keep clears" beside it). His decisions: (a) the Topology
// on Lattice Setup is the SAME setup (an edit there is Topology's, and the stress check is out of date after it); (b) modify only —
// no new group, load, scenario or shape.
//
// Before (read off the code at 3ed7a2d5): opening Topology on Lattice Setup left the lattice prisms and their handles up, drew
// none of Topology's shapes and offered no row to edit; every Design box row showed its seven handles at once; no "Hide keep
// clears". RED CONTROLS here: DesignRowHandles.controlEveryRow (every row's handles), TopologyViewLive.controlNoStressMark.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

// MARK: - the rules, without a screen

final class TopologyInLatticeRulesTests: XCTestCase {

    func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> DesignBoxBounds { DesignBoxBounds(min: lo, max: hi) }

    func model() -> DesignBoxModel {
        var d = DesignBoxModel()
        let part = MeshBounds(min: .zero, max: SIMD3<Float>(10, 10, 10), isEmpty: false)
        let a = d.add(around: part)!, b = d.add(around: part)!
        d.writeBounds(a, box(SIMD3(-5, -5, -5), SIMD3(15, 15, 15)), draggedAxis: nil)   // the run's box, around the part
        d.writeBounds(b, box(SIMD3(2, 2, 20), SIMD3(8, 8, 26)), draggedAxis: nil)       // a small box above the part
        d.setSign(b, .negative)
        return d
    }

    /// ★ "6 handles at a time": nothing picked, no row's handles; the picked row's alone; a hidden keep clear none.
    @MainActor func testOnlyThePickedRowShowsItsHandles() {
        let d = model()
        let (a, b) = (d.primitives[0].id, d.primitives[1].id)
        XCTAssertEqual(DesignRowHandles.shown(d, picked: nil, keepClearsHidden: false), [], "★ nothing picked: none")
        XCTAssertEqual(DesignRowHandles.shown(d, picked: a, keepClearsHidden: false), [a])
        XCTAssertEqual(DesignRowHandles.shown(d, picked: b, keepClearsHidden: false), [b])
        XCTAssertEqual(DesignRowHandles.shown(d, picked: b, keepClearsHidden: true), [], "★ a Negative row is a keep clear: hidden")
        XCTAssertEqual(DesignRowHandles.shown(d, picked: 99, keepClearsHidden: false), [], "a row since deleted: none")
        DesignRowHandles.controlEveryRow = true
        defer { DesignRowHandles.controlEveryRow = false }
        XCTAssertEqual(DesignRowHandles.shown(d, picked: nil, keepClearsHidden: false), [a, b], "RED CONTROL: every row")
    }

    /// A tap picks the nearest row it enters — the box around the part only where no part is under the finger.
    func testATapPicksTheRowUnderTheFinger() {
        let d = model()
        let (a, b) = (d.primitives[0].id, d.primitives[1].id)
        let down = SIMD3<Float>(0, 0, -1)
        // straight down onto the small box above the part (the part's top at z = 10, 40 mm along the ray)
        XCTAssertEqual(DesignRowHandles.pick(d, origin: SIMD3(5, 5, 50), dir: down, surface: 40, keepClearsHidden: false), b,
                       "★ the box in front of the part")
        XCTAssertNil(DesignRowHandles.pick(d, origin: SIMD3(5, 5, 50), dir: down, surface: 40, keepClearsHidden: true),
                     "★ hidden keep clears take no tap — and the part's tap is the part's (it is inside the run's box)")
        // beside the part, through the run's box only: no part under the finger
        XCTAssertEqual(DesignRowHandles.pick(d, origin: SIMD3(13, 5, 50), dir: down, surface: nil, keepClearsHidden: false), a,
                       "★ the run's box, where it is all he touches")
        // on the part where nothing stands in front: the part's
        XCTAssertNil(DesignRowHandles.pick(d, origin: SIMD3(1, 1, 50), dir: down, surface: 40, keepClearsHidden: false))
        // into nothing
        XCTAssertNil(DesignRowHandles.pick(d, origin: SIMD3(40, 40, 50), dir: down, surface: nil, keepClearsHidden: false))
    }

    /// The table: Lattice Setup with Topology open draws Topology's editors and no lattice selection, its rows Topology's.
    func testTheTopologyViewOnLatticeSetup() {
        let v = WorkspaceStageVisibility.of(.lattice, editingFaces: false, topologyInLattice: true)
        XCTAssertTrue(v.designBox && v.groupPrimitives && v.keepOuts, "★ Topology's shapes and their handles")
        XCTAssertFalse(v.latticeDepthPlanes, "★ no prism, depth handle or zone box")
        XCTAssertTrue(v.latticeControls, "the lattice's own preview and watchers stay mounted")
        XCTAssertEqual(v.rowSections, [.clearanceEditor], "★ a group's row is Topology's")
        XCTAssertEqual(WorkspaceStageVisibility.of(.lattice, editingFaces: false, topologyInLattice: false), .of(.lattice))
        XCTAssertEqual(WorkspaceStageVisibility.of(.topology, editingFaces: false, topologyInLattice: true), .of(.topology))
        XCTAssertEqual(WorkspaceStageVisibility.of(.lattice, editingFaces: true, topologyInLattice: true), .editingFaces)
        // the two notes that sat in the panel are its (i)'s words now
        XCTAssertTrue(TopologyViewCopy.panelInfo.contains(LatticeSetupCopy.resultKeepsGroups))
        XCTAssertTrue(TopologyViewCopy.panelInfo.contains(LatticeSetupCopy.protectStillApplies))
        XCTAssertEqual(TopologyViewCopy.hideKeepClears, "Hide keep clears")
        XCTAssertLessThanOrEqual(TopologyViewCopy.hideKeepClears.split(separator: " ").count, 5, "his 5-word rule")
    }

    /// (b): the Topology view on Lattice Setup makes nothing — no "+ Add" shape on a group's row there, no new group by a tap.
    func testTheViewMakesNothingNew() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("if active, !latticeTopologyOpen, visible.groupPrimitives,"), "★ no + Add shape there")
        XCTAssertTrue(ws.contains("if topologyTapWouldStartGroup(fid, at: pt, mesh: m) { emptyTapClears(); return true }"),
                      "★ a tap that would start a group starts nothing")
    }
}

// MARK: - on the page

@MainActor
final class TopologyInLatticeNotes1122Tests: XCTestCase {

    static let sizes = [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)]

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            LatticeSetupHandles.recordLive = true
            TopologyViewLive.recordLive = true
            HardwareKeyboard.override = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.litThrough = []
            LatticeSetupHandles.latticeTinted = []
            LatticeSetupHandles.livePick = nil
            LatticeSetupHandles.liveEmptyTap = nil
            TopologyViewLive.recordLive = false
            TopologyViewLive.controlNoStressMark = false
            TopologyViewLive.stressMarkedStale = 0
            TopologyViewLive.keepClearVolumes = 0
            DesignRowHandles.controlEveryRow = false
            LatticeSimModel.testRunner = nil
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    // MARK: helpers

    /// ParityTopologyShots' pad with no scenarios (Bottom and Top anchors, Top protected, Group C a 51 kg load), a keep-clear
    /// cylinder on Bottom; on Structural with a lattice group of three faces as Lattice, open (its prisms and handles up).
    func latticeSetup(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, AppModel) {
        LatticeSetupHandles.live = [:]
        let (h, p, app) = try ParityTopologyShots.pad(size, scenarios: false, test: self)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let bottom = try group(p, "Bottom")
        p.force.setKeepClearAffix(bottom, .on)
        let b = mesh.bounds
        p.force.addManualPrimitive(ManualPrimitive(kind: .bolt, center: SIMD3(Double(b.max.x) + 15, Double(b.center.y), Double(b.center.z)),
                                                   axis: SIMD3(0, 0, 1), radiusMM: 3, halfLengthMM: 5), to: bottom)
        p.syncForceGroups()
        p.selection.clearActive()   // the pad's saved Group C is picked: nothing picked on Topology, as he comes to the Lattice
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        let others = Set(mesh.faceIDs).subtracting(top.faces).sorted()
        for f in top.faces.prefix(1) + others.prefix(2) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        let g = try XCTUnwrap(p.latticeGroups.first, "the lattice group")
        p.latticeList.setActive(g.id)
        h.pump(1)
        return (h, p, app)
    }

    func group(_ p: ProjectModel, _ name: String) throws -> UUID {
        try XCTUnwrap(p.selection.groups.first { $0.name == name }, "his \(name)").id
    }

    func keys(_ h: AppBuildHost, _ prefix: String) -> [String] { h.frames.all.keys.filter { $0.hasPrefix(prefix) }.sorted() }

    /// The lattice selections' handles on the part: the prisms' end handles and expand knobs.
    func latticeHandles(_ h: AppBuildHost) -> [String] { keys(h, "handle-prism-") + keys(h, "latticeExpandKnob-") }

    /// Type a number on the app's pad behind the number field `key` (Done keeps it).
    func type(_ h: AppBuildHost, _ key: String, _ digits: String, panel: String) throws {
        h.scrollIntoPanel(key, panel: panel)
        try h.tap(key, "the number \(key)")
        XCTAssertNotNil(h.padFrame("numberPad"), "a tap opens the app's pad")
        for c in digits { try h.padTap("numberPad-key-\(c)", "\(c)") }
        try h.padTap("numberPad-done", "Done")
        h.pump(0.5)
    }

    // MARK: (1) Topology inside Lattice Setup

    /// ★ img 6: opening Topology on Lattice Setup hides every lattice selection at once and shows Topology's own view; its rows
    /// edit Topology (a load's kind and weight, a group's role) — the same setup the Topology stage shows; nothing is made new;
    /// closing it brings the lattice view back.
    func testOpeningTopologyShowsTopologyAndHidesTheLattice() throws {
        for size in Self.sizes {
            let (h, p, _) = try latticeSetup(size)
            let what = "\(size)"
            // premise: the lattice selections are up
            XCTAssertFalse(LatticeSetupHandles.drawnPrisms.isEmpty, "\(what): premise — the lattice group's prisms")
            XCTAssertFalse(latticeHandles(h).isEmpty, "\(what): premise — their handles on the part")
            XCTAssertNil(h.frames.all["view-\(TopologyViewCopy.hideKeepClears)"], "\(what): Lattice's own views, closed")

            TopologyViewLive.keepClearVolumes = -1
            try h.tap("latticeTopologyPanelHeader", "\(what): Topology's header", settle: 1.2)
            // ★ every lattice selection hidden at once
            XCTAssertTrue(LatticeSetupHandles.drawnPrisms.isEmpty, "\(what): ★ no prism: \(LatticeSetupHandles.drawnPrisms.sorted())")
            XCTAssertTrue(latticeHandles(h).isEmpty, "\(what): ★ no depth or expand handle: \(latticeHandles(h))")
            XCTAssertTrue(LatticeSetupHandles.latticeTinted.isEmpty, "\(what): ★ no lattice face tint")
            XCTAssertTrue(keys(h, "placedBox-zone-").isEmpty, "\(what): ★ no zone box")
            XCTAssertNil(h.frames.all["view-\(LatticePrismsView.label)-on"], "\(what): ★ no Face prisms view")
            // ★ Topology's view: its shapes drawn, its views beside the others
            XCTAssertGreaterThan(TopologyViewLive.keepClearVolumes, 0, "\(what): ★ Topology's keep-clear shapes drawn")
            _ = try h.onScreen("view-Forces-on", "\(what): ★ Forces")
            let hide = try h.onScreen("view-\(TopologyViewCopy.hideKeepClears)", "\(what): ★ Hide keep clears, off")
            XCTAssertEqual(hide.midY, try h.onScreen("view-Forces-on", "Forces").midY, accuracy: 1, "\(what): beside Forces")
            // ★ the include line keeps its place; the two notes are the panel's (i) now — nothing inside the panel says them
            _ = try h.onScreen("latticeTopologyLine", "\(what): the include line")
            _ = try h.onScreen("latticeTopologyInfo", "\(what): ★ the panel's (i)")
            XCTAssertNil(h.frames.all["latticeResultKeepsGroups"])
            XCTAssertNil(h.frames.all["latticeProtectStillApplies"])
            XCTAssertNil(h.frames.all["addLoadScenario"], "\(what): ★ (b) no new scenario")
            XCTAssertNil(h.frames.all["latticeFacesSectionAction"], "\(what): ★ (b) no \"+ New group\" (the lattice list is its pill)")

            // ★ a row is Topology's: its load's Kind and Weight, here
            let c = try group(p, "Group C")
            try h.tap("latticeTopo-\(c.uuidString)", "\(what): Group C's row", settle: 1)
            XCTAssertEqual(p.selection.activeGroupID, c, "\(what): ★ the row picks Topology's group")
            _ = try h.onScreen("latticeTopoRows-\(c.uuidString)", "\(what): ★ Topology's own rows under it")
            h.scrollIntoPanel("loadKind-push-\(c.uuidString)", panel: "latticeTopologyPanel")
            try h.tap("loadKind-push-\(c.uuidString)", "\(what): ★ Push", settle: 1)
            XCTAssertEqual(p.force.kind(for: c).loadDirection, .push, "\(what): ★ a Push now")
            _ = try h.onScreen("aimHandle-\(c.uuidString)", "\(what): ★ its arrow's handle on the part, in Lattice Setup")
            try type(h, "numberField-loadWeight-\(c.uuidString)", "25", panel: "latticeTopologyPanel")
            XCTAssertEqual(p.force.kind(for: c).weightKg ?? 0, 25, accuracy: 1e-6, "\(what): ★ the weight typed here")

            // ★ a group's role: Bottom protected, from its row here
            let bottom = try group(p, "Bottom")
            try h.tap("latticeTopo-\(bottom.uuidString)", "\(what): Bottom's row", settle: 1)
            XCTAssertEqual(p.selection.activeGroupID, bottom)
            XCTAssertFalse(p.force.isProtected(bottom), "premise: Bottom is not protected")
            h.scrollIntoPanel("protectAffix-\(bottom.uuidString)", panel: "latticeTopologyPanel")
            try h.tap("protectAffix-\(bottom.uuidString)", "\(what): ★ Bottom's Protect", settle: 1)
            XCTAssertTrue(p.force.isProtected(bottom), "\(what): ★ protected here")

            // ★ closed: the lattice view back, exactly
            try h.tap("latticeTopologyPanelHeader", "\(what): Topology's header again", settle: 1.2)
            XCTAssertFalse(LatticeSetupHandles.drawnPrisms.isEmpty, "\(what): ★ the prisms back")
            XCTAssertFalse(latticeHandles(h).isEmpty, "\(what): ★ their handles back")
            XCTAssertNil(h.frames.all["view-\(TopologyViewCopy.hideKeepClears)"], "\(what): Topology's views gone")
            XCTAssertNil(h.frames.all["aimHandle-\(c.uuidString)"], "\(what): Topology's arrows gone")

            // ★ (a): the Topology stage shows the very same change
            try h.pickFromMenu("capsuleMenu", "Topology", what: "\(what): the stage menu")
            h.pump(1.2)
            _ = try h.onScreen("view-Forces-on", "\(what): on the Topology stage")
            XCTAssertEqual(p.force.kind(for: c).weightKg ?? 0, 25, accuracy: 1e-6, "\(what): ★ Topology's load is 25 kg")
            XCTAssertEqual(p.force.kind(for: c).loadDirection, .push)
            XCTAssertTrue(p.force.isProtected(bottom), "\(what): ★ and Bottom protected")
        }
    }

    /// ★ (a): an edit made in the Topology view leaves the stress check out of date — the Lattice button says Refresh Lattice
    /// (Click to refresh). RED CONTROL: without the mark, the same edit leaves the button as it was.
    func testAnEditThereMarksTheStressCheckOutOfDate() throws {
        let settings = AppSettings.shared
        let wasEngine = settings.newEngineTest
        addTeardownBlock { @MainActor in
            AppSettings.shared.newEngineTest = wasEngine
            AppSettings.shared.latticeLivePreview = false
        }
        final class Calls: @unchecked Sendable { var n = 0; let lock = NSLock()
            func add() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n } }
        let calls = Calls()
        LatticeSimModel.testRunner = { _ in
            calls.add()
            let n = 6, cells = n * n * n
            return TopOptKit.SimAnalysisResult(accepted: true, nonConvergent: false, maxStressMPa: 2, marginWorstCase: 5,
                                               marginRequired: 1.5, maxDisplacementMM: 0.01,
                                               vonMisesField: [Float](repeating: 1, count: cells),
                                               stressTensorField: [Double](repeating: 0.5, count: cells * 6),
                                               gridNX: n, gridNY: n, gridNZ: n, gridOrigin: SIMD3(-150, -150, -150), spacingMM: 60)
        }
        for size in Self.sizes {
            settings.newEngineTest = false
            let (h, p, _) = try latticeSetup(size)
            let what = "\(size)"
            p.lattice.simulateStresses = true
            p.lattice.densityMode = .sim
            p.lattice.enabled = true
            h.pump(1)
            // the lattice preview, its settings saved: the stress check runs (here, the stub)
            if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "\(what): the lattice preview", settle: 1.5) }
            if h.frames.all["latticeSettingsPanel"] != nil { try h.tap("capsuleSetup", "\(what): the page's Save", settle: 1.5) }
            let end = Date().addingTimeInterval(60)
            while h.frames.all["view-Stress"] == nil && h.frames.all["view-Stress-on"] == nil, Date() < end { h.pump(0.5) }
            XCTAssertGreaterThan(calls.count, 0, "\(what): premise — the stress check ran")
            _ = try XCTUnwrap(h.frames.all["view-Stress"] ?? h.frames.all["view-Stress-on"], "\(what): premise — its result is in")
            settings.latticeLivePreview = false   // his default: Click to refresh
            h.pump(1.5)
            XCTAssertNil(h.frames.all["latticeRefreshButton"], "\(what): premise — the preview is up to date")

            try h.tap("latticeTopologyPanelHeader", "\(what): Topology's header", settle: 1.2)
            let c = try group(p, "Group C")
            try h.tap("latticeTopo-\(c.uuidString)", "\(what): Group C's row", settle: 1)
            // RED CONTROL: the weight changed with the mark switched off — the button stays Lattice
            TopologyViewLive.controlNoStressMark = true
            let before = TopologyViewLive.stressMarkedStale
            try type(h, "numberField-loadWeight-\(c.uuidString)", "30", panel: "latticeTopologyPanel")
            XCTAssertEqual(p.force.kind(for: c).weightKg ?? 0, 30, accuracy: 1e-6)
            XCTAssertEqual(TopologyViewLive.stressMarkedStale, before, "\(what): RED CONTROL — nothing marked")
            XCTAssertNil(h.frames.all["latticeRefreshButton"], "\(what): RED CONTROL — the stale check goes unsaid")
            // ★ with the mark: Refresh Lattice
            TopologyViewLive.controlNoStressMark = false
            try type(h, "numberField-loadWeight-\(c.uuidString)", "25", panel: "latticeTopologyPanel")
            XCTAssertEqual(TopologyViewLive.stressMarkedStale, before + 1, "\(what): ★ the stress check found out of date")
            _ = try h.onScreen("latticeRefreshButton", "\(what): ★ the Lattice button reads Refresh Lattice")
        }
    }

    // MARK: (2) one shape's handles at a time

    /// The Topology stage of the pad: a Design box (the run's box) and a Negative box above the part; Group C a keep clear with
    /// two cylinders hanging in the air either side of the part. Nothing picked.
    func topologyStage(_ size: CGSize) throws -> (AppBuildHost, ProjectModel, (run: Int, neg: Int), [UUID], UUID, TopologyViewState) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        let mesh = try XCTUnwrap(p.viewerMesh)
        let b = mesh.bounds
        let run = try XCTUnwrap(p.designBox.add(around: b))
        let neg = try XCTUnwrap(p.designBox.add(around: b))
        let w = (b.max - b.min) * 0.2
        p.designBox.writeBounds(neg, DesignBoxBounds(min: SIMD3(b.center.x - w.x, b.center.y - w.y, b.max.z + 30),
                                                     max: SIMD3(b.center.x + w.x, b.center.y + w.y, b.max.z + 30 + w.z * 2)),
                                draggedAxis: nil)
        p.designBox.setSign(neg, .negative)
        let c = try group(p, "Group C")
        p.force.makeAnchor(c)
        p.force.setKeepClearAffix(c, .on)
        let dx = Double(b.max.x - b.min.x)
        for x in [Double(b.max.x) + dx * 0.3, Double(b.min.x) - dx * 0.3] {
            p.force.addManualPrimitive(ManualPrimitive(kind: .bolt, center: SIMD3(x, Double(b.center.y), Double(b.center.z)),
                                                       axis: SIMD3(0, 0, 1), radiusMM: Double(dx) * 0.08, halfLengthMM: Double(dx) * 0.15),
                                       to: c)
        }
        p.syncForceGroups()
        p.selection.clearActive()
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        return (h, p, (run, neg), p.force.manualPrimitives(for: c).map(\.id), c, r.app.topologyView)
    }

    /// The viewer's own tap (a synthesised click never reaches the Metal view's pick): at a spot whose ray `wants`.
    func viewerTap(_ h: AppBuildHost, _ p: ProjectModel, _ what: String,
                   wants: (_ origin: SIMD3<Float>, _ dir: SIMD3<Float>, _ surface: Float?) -> Bool) throws {
        let mtk = try XCTUnwrap(ResultsRedesignHostedTests.metalView(in: h.view))
        let click = try XCTUnwrap(mtk.gestureRecognizers.first { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 })
        let viewer = try XCTUnwrap(click.target as? MetalMeshView.Coordinator)
        let rend = try XCTUnwrap(viewer.renderer), mesh = try XCTUnwrap(rend.mesh)
        let size = mtk.bounds.size, frame = rend.pickModelFrame, inv = frame.rotation.inverse
        for y in stride(from: 0.04, to: 0.96, by: 0.01) {
            for x in stride(from: 0.04, to: 0.96, by: 0.01) {
                let (o, d) = FacePicker.ray(camera: rend.camera, aspect: Float(size.width / size.height), point: CGPoint(x: x, y: y))
                let mo = frame.centre + inv.act(o - frame.centre), md = simd_normalize(inv.act(d))
                let s = FacePicker.hit(rayOrigin: mo, rayDir: md, mesh: mesh).map { simd_dot($0.point - mo, md) }
                if wants(mo, md, s) {
                    viewer.pick(at: CGPoint(x: x * size.width, y: y * size.height), in: mtk)
                    h.pump(1)
                    return
                }
            }
        }
        XCTFail("\(what): no spot on the screen")
    }

    /// The keep-clear volume a ray enters first, if any (group, piece, where).
    func firstVolume(_ p: ProjectModel, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> (UUID, Int, Float)? {
        p.clearancePieceVolumes().compactMap { v in v.volume.rayEntry(origin: o, dir: d).map { (v.groupID, v.piece, $0) } }
            .min { $0.2 < $1.2 }
    }

    /// Whether a ray's first keep-clear volume is (group, piece), in the air or in front of the part.
    func hits(_ p: ProjectModel, _ o: SIMD3<Float>, _ d: SIMD3<Float>, _ s: Float?, _ g: UUID, _ key: Int) -> Bool {
        guard let v = firstVolume(p, o, d), v.0 == g, v.1 == key else { return false }
        return s.map { v.2 < $0 - 1 } ?? true
    }

    func designHandles(_ h: AppBuildHost) -> [String] { keys(h, "designHandle-") }
    func keepHandles(_ h: AppBuildHost) -> [String] { keys(h, "placedBox-keep-") }
    /// One shape's handles: its move dot and the six squares on its faces.
    func assertSix(_ found: [String], _ prefix: String, _ what: String) {
        XCTAssertEqual(found.filter { $0.hasPrefix(prefix) }.count, 7, "\(what): its move dot and six squares: \(found)")
        XCTAssertEqual(found.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("move") }.count, 6, "\(what): ★ six face handles")
        XCTAssertTrue(found.allSatisfy { $0.hasPrefix(prefix) }, "\(what): ★ no other shape's handles: \(found)")
    }

    /// ★ img 11/12: with nothing picked no shape shows a handle; a picked Design box row shows its own six (and its move dot),
    /// another moves them; a tapped keep-clear shape shows only ITS handles; a tap into nothing lets go. RED CONTROL: every
    /// row's at once.
    func testOnlyThePickedShapeShowsItsHandles() throws {
        for size in Self.sizes {
            let (h, p, rows, prims, c, v) = try topologyStage(size)
            let what = "\(size)"
            XCTAssertTrue(designHandles(h).isEmpty, "\(what): ★ nothing picked: no Design box handle: \(designHandles(h))")
            XCTAssertTrue(keepHandles(h).isEmpty, "\(what): ★ … and no keep-clear handle")
            DesignRowHandles.controlEveryRow = true
            v.objectWillChange.send()   // (the page redraws for it)
            h.pump(1)
            XCTAssertEqual(designHandles(h).count, 14, "\(what): RED CONTROL — every row's handles at once")
            DesignRowHandles.controlEveryRow = false
            v.objectWillChange.send()
            h.pump(1)
            XCTAssertTrue(designHandles(h).isEmpty)

            // a row picks its shape (Settings › Allow growth here)
            try h.tap("setupChip", "\(what): the Settings chip", settle: 1)
            h.scrollIntoPanel("designRowPick-\(rows.run)", panel: "settingsPanel")
            try h.tap("designRowPick-\(rows.run)", "\(what): the run's box's row", settle: 1)
            XCTAssertEqual(v.pickedDesignRow, rows.run)
            assertSix(designHandles(h), "designHandle-\(rows.run)-", "\(what): ★ the run's box")
            h.scrollIntoPanel("designRowPick-\(rows.neg)", panel: "settingsPanel")
            try h.tap("designRowPick-\(rows.neg)", "\(what): the Negative box's row", settle: 1)
            assertSix(designHandles(h), "designHandle-\(rows.neg)-", "\(what): ★ the Negative box's, only")
            try h.tap("setupChip", "\(what): the Settings chip, folded", settle: 1)

            // a tap into nothing lets go
            try viewerTap(h, p, "\(what): empty space") { o, d, s in
                s == nil && self.firstVolume(p, o, d) == nil
                    && p.designBox.primitives.allSatisfy { DesignRowHandles.entry($0.bounds, origin: o, dir: d) == nil }
            }
            XCTAssertNil(v.pickedDesignRow, "\(what): ★ a tap into nothing lets go")
            XCTAssertTrue(designHandles(h).isEmpty, "\(what): ★ no handle left")

            // a keep-clear cylinder tapped on the part's view: ITS handles alone; the other one: only the other's
            for (i, mp) in prims.enumerated() {
                let key = ProjectModel.manualFaceKey(mp)
                try viewerTap(h, p, "\(what): cylinder \(i + 1)") { o, d, s in
                    self.hits(p, o, d, s, c, key)
                }
                XCTAssertEqual(p.selection.activeGroupID, c, "\(what): the tap picked its group")
                assertSix(keepHandles(h), "placedBox-keep-\(mp.uuidString)-", "\(what): ★ cylinder \(i + 1)")
                XCTAssertTrue(designHandles(h).isEmpty, "\(what): ★ one shape at a time")
            }
            // the Negative box above the part, tapped: its handles, and the cylinder's go
            try viewerTap(h, p, "\(what): the Negative box") { o, d, s in
                s == nil && self.firstVolume(p, o, d) == nil
                    && DesignRowHandles.pick(p.designBox, origin: o, dir: d, surface: s, keepClearsHidden: false) == rows.neg
            }
            XCTAssertEqual(v.pickedDesignRow, rows.neg, "\(what): ★ the tap picked the Negative box")
            assertSix(designHandles(h), "designHandle-\(rows.neg)-", "\(what): ★ its handles")
            XCTAssertTrue(keepHandles(h).isEmpty, "\(what): ★ the cylinder's gone")
            v.reset()
        }
    }

    // MARK: (3) Hide keep clears

    /// ★ img 12: "Hide keep clears" beside Forces hides every keep-clear shape and its handles, and a tap shows them again;
    /// Forces still hides the selected load's arrow and handle.
    func testHideKeepClearsAndForcesStillWorks() throws {
        for size in Self.sizes {
            let (h, p, _, prims, c, v) = try topologyStage(size)
            let what = "\(size)"
            let key = ProjectModel.manualFaceKey(prims[0])
            try viewerTap(h, p, "\(what): cylinder 1") { o, d, s in
                self.hits(p, o, d, s, c, key)
            }
            assertSix(keepHandles(h), "placedBox-keep-\(prims[0].uuidString)-", "\(what): premise — its handles")
            XCTAssertGreaterThan(TopologyViewLive.keepClearVolumes, 0, "\(what): premise — the shapes drawn")

            try h.tap("view-\(TopologyViewCopy.hideKeepClears)", "\(what): ★ Hide keep clears", settle: 1)
            XCTAssertTrue(v.keepClearsHidden)
            _ = try h.onScreen("view-\(TopologyViewCopy.hideKeepClears)-on", "\(what): ★ on")
            XCTAssertEqual(TopologyViewLive.keepClearVolumes, 0, "\(what): ★ no keep-clear shape drawn")
            XCTAssertTrue(keepHandles(h).isEmpty, "\(what): ★ nor a handle")
            XCTAssertTrue(p.force.keepClearAffix(for: c) == .on, "\(what): a view only — Group C still keeps clear")

            // Forces still works: the Top's push and its handle hide and come back
            let top = try group(p, "Top")
            p.force.setDirection(top, .push)
            p.selection.setActive(top)
            h.pump(1)
            _ = try h.onScreen("aimHandle-\(top.uuidString)", "\(what): the Top's arrow handle")
            try h.tap("view-Forces-on", "\(what): Forces", settle: 1)
            XCTAssertNil(h.frames.all["aimHandle-\(top.uuidString)"], "\(what): ★ Forces hides it")
            try h.tap("view-Forces", "\(what): Forces again", settle: 1)
            _ = try h.onScreen("aimHandle-\(top.uuidString)", "\(what): ★ and shows it")

            p.selection.clearActive()   // (a picked group draws only its own shapes: the Top has none)
            try h.tap("view-\(TopologyViewCopy.hideKeepClears)-on", "\(what): Hide keep clears, off", settle: 1)
            XCTAssertFalse(v.keepClearsHidden)
            XCTAssertGreaterThan(TopologyViewLive.keepClearVolumes, 0, "\(what): ★ the shapes back")
            v.reset()
        }
    }
}
#endif
