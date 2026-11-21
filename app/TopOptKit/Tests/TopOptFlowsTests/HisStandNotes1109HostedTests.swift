// HisStandNotes1109HostedTests — his iPad notes 11-09 (relayed by 362; install 8e1b257f) on HIS 2040 Extrusion Stand, on the
// page (Lattice Setup). His STEP is read where it is, read-only, never copied (TOPOPT_HIS_STAND overrides the path); absent,
// these skip.
//   (1)   a tap on his rounded edge strip — a face a region covers — makes a LATTICE group (its role picker opens) and
//         leaves Topology's groups alone; the next taps take nothing away.
//   (2.1) shot 2: Aesthetic, Start from Solid · + Lattice faces, three groups, two zones, Group 3 picked → its chips show.
//   (2.2) shot 2 → 3: zones stay through a group's pick and de-pick (and a tap into nothing).
//   (2.5) the Selections panel stops above the hint line, 24 pt clear of it, at both window sizes.
//   (3.1) a picked face row has its Expand line; (3.3) its number's pad opens beside it.
//   (3.2) the Expand handle is the one DragHandle and stays under the finger along its line.
// A synthesised click never reaches the offscreen 3D view, so the tests drive the page's own closures (LatticeSetupHandles).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class HisStandNotes1109HostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { LatticeSetupHandles.recordLive = true; HardwareKeyboard.override = false; NumberPadProbe.lastOpen = nil }
    }

    override func tearDown() async throws {
        await MainActor.run {
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.litThrough = []
            LatticeSetupHandles.livePick = nil
            LatticeSetupHandles.liveEmptyTap = nil
            LatticeSetupHandles.liveViewerTap = nil
            LatticeSetupHandles.latticeTinted = []
            LatticeSetupHandles.chipSpots = [:]
            LatticeSetupHandles.chipTrue = [:]
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    struct Stand {
        let h: AppBuildHost
        let p: ProjectModel
        let mesh: ViewerMesh
    }

    /// His stand on the Lattice stage as `mode` (the stage menu), his Topology first (down −Z, the flat underside anchored,
    /// the flat top loaded); `before` sets his lattice up before the page opens.
    func stand(_ mode: LatticeStageMode, size: CGSize = AppBuildHost.landscape13,
               before: (ProjectModel, ViewerMesh) throws -> Void = { _, _ in }) throws -> Stand {
        let path = HisStandChipsHostedTests.standPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("his 2040 Extrusion Stand STEP is not on this Mac (\(path))")
        }
        let p = try FlexiblePressFixtures.project(path: path, name: "2040 Extrusion Stand")
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(mode)
        let mesh = try XCTUnwrap(p.viewerMesh)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        func flat(_ s: Float) -> FaceID? {
            FaceTopology.faceIDs(in: mesh).filter { f in
                guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
                return simd_normalize(SIMD3<Float>(g.planeNormal)).z * s > 0.99
            }.max { (mesh.faceCentroid($0)?.z ?? 0) * s < (mesh.faceCentroid($1)?.z ?? 0) * s }
        }
        let anchor = p.selection.addGroup()
        p.selection.addFaces([try XCTUnwrap(flat(-1), "premise: a flat underside")], to: anchor)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.addFaces([try XCTUnwrap(flat(1), "premise: a flat top")], to: load)
        p.force.makeLoad(load)
        p.syncForceGroups()
        p.selection.clearActive()
        try before(p, mesh)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("his-stand-1109-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: size, test: self)
        h.pump(2)
        try h.pickFromMenu("capsuleMenu", mode == .aesthetic ? "Aesthetic" : "Structural", what: "\(size): the stage menu")
        h.pump(1.5)
        return Stand(h: h, p: p, mesh: mesh)
    }

    static func slanted(_ sign: Float, _ mesh: ViewerMesh) -> [FaceID] {
        FaceTopology.faceIDs(in: mesh).filter { f in
            guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
            let n = simd_normalize(SIMD3<Float>(g.planeNormal))
            return n.x * sign > 0.3 && abs(n.z) > 0.2 && abs(n.z) < 0.95
        }
    }

    /// His rounded edge strips (fillets beside the slanted sides) and his bores — shot 2's Group 3 ("Hole, ⌀ 10…", "Rounded…").
    static func holesAndRounds(_ p: ProjectModel, _ mesh: ViewerMesh) -> [FaceID] {
        FaceTopology.faceIDs(in: mesh).filter { p.faceName($0).hasPrefix("Rounded edge") || p.faceName($0).hasPrefix("Hole") }
    }

    /// Tap `faces` into a fresh lattice group, the way his taps make it.
    static func group(_ p: ProjectModel, _ mesh: ViewerMesh, _ faces: [FaceID]) -> UUID? {
        var l = p.latticeList
        l.clearActive()
        p.latticeList = l
        for f in faces where p.latticeList.group(forFace: f) == nil {
            let loop = p.surfaceLoopRespectingRegions(FaceTopology.loop(fromFace: f, in: mesh), from: f)
            _ = p.latticeStageTap(face: f, loop: loop)
        }
        return p.latticeList.activeGroupID
    }

    struct ShotTwo {
        let s: Stand
        let g1: UUID, g2: UUID, g3: UUID
        let zones: [UUID]
    }

    /// ★ Shot 2: Aesthetic, Start from "Solid · + Lattice faces", Group 1 (his −X slanted sides, Lattice, 7 mm), Group 2 (+X,
    /// Lattice, 13 mm), Group 3 (his holes and rounded edges, No lattice, 4 mm), and two zones (the last one added picked).
    func shotTwo(_ size: CGSize = AppBuildHost.landscape13) throws -> ShotTwo {
        var ids: [UUID] = []
        var zones: [UUID] = []
        let s = try stand(.aesthetic, size: size) { p, mesh in
            p.lattice.wholePart = false
            let g1 = try XCTUnwrap(Self.group(p, mesh, Self.slanted(-1, mesh)), "Group 1")
            let g2 = try XCTUnwrap(Self.group(p, mesh, Self.slanted(1, mesh)), "Group 2")
            let rounds = Self.holesAndRounds(p, mesh)
            XCTAssertGreaterThanOrEqual(rounds.count, 6, "premise: his stand has holes and rounded edges")
            let g3 = try XCTUnwrap(Self.group(p, mesh, rounds), "Group 3")
            let roles: [(UUID, LatticeGroupRole, Double)] = [(g1, .include, 7), (g2, .include, 13), (g3, .exclude, 4)]
            for (id, role, mm) in roles {
                p.lattice.groupRoles[id] = role
                p.writeGroupDepthMM(id, mm: mm)
            }
            zones = [try XCTUnwrap(p.addLatticeZone()), try XCTUnwrap(p.addLatticeZone())]
            ids = [g1, g2, g3]
        }
        XCTAssertEqual(s.p.latticeZones.count, 2, "premise: his two zones")
        XCTAssertGreaterThanOrEqual(s.p.latticeSelectableRefs(try XCTUnwrap(s.p.latticeGroups.first { $0.id == ids[2] })).count, 6,
                                    "premise: Group 3 holds his holes and rounded edges")
        return ShotTwo(s: s, g1: ids[0], g2: ids[1], g3: ids[2], zones: zones)
    }

    private func keys(_ p: ProjectModel, _ id: UUID) -> Set<String> {
        guard let g = p.latticeGroups.first(where: { $0.id == id }) else { return [] }
        return Set(p.latticeSelectableRefs(g).map(\.key))
    }

    // MARK: (1)

    /// ★ (1) "he tapped the rounded vertical EDGE strip. It coloured, but no Lattice │ No lattice │ Protect skin pop-up and no
    /// group was made. A 2nd tap only changed its colour; a 3rd tap unselected it." — his strip is a piece (a region covers
    /// it), and the tap went to Topology's piece picker. Now: a lattice group holding the piece, open (its role picker on the
    /// screen), Topology untouched; the next taps take nothing away.
    func testATapOnHisRoundedEdgeStripMakesALatticeGroup() throws {
        var strip: FaceID = -1
        var piece: RegionID = -1
        var topo: UUID?
        let s = try stand(.structural) { p, mesh in
            strip = try XCTUnwrap(FaceTopology.faceIDs(in: mesh).first { p.faceName($0).hasPrefix("Rounded edge") },
                                  "premise: his rounded edge strips")
            let t = p.selection.addGroup()   // one of his Topology groups holds it
            p.selection.addFaces([strip], to: t)
            p.selection.clearActive()
            piece = try XCTUnwrap(p.surfaceEnsureRegion(for: strip), "a region covers the strip (his)")
            topo = t
        }
        let (h, p) = (s.h, s.p)
        XCTAssertEqual(EditedFaces.leaf(face: strip, point: nil, mesh: s.mesh, regions: p.faceRegions,
                                        fallback: p.surfaceCutTarget(face: strip)), .region(piece),
                       "premise: the strip is a piece — the edited face a tap selects")
        XCTAssertTrue(p.latticeGroups.isEmpty, "premise: no lattice groups yet (shot 1)")
        let topology = p.selection.groups
        let tap = try XCTUnwrap(LatticeSetupHandles.liveViewerTap, "the page's tap, as the viewer makes it")

        tap(strip, nil)
        h.pump(1)
        let g = try XCTUnwrap(p.latticeGroups.first { $0.regionIDs.contains(piece) },
                              "★ a lattice group holds his strip (groups: \(p.latticeGroups.map { ($0.name, $0.faces, $0.regionIDs) }))")
        XCTAssertEqual(p.latticeList.activeGroupID, g.id, "★ … and it is open")
        _ = try h.onScreen("latticeRoleRow-\(g.id.uuidString)", "★ its Lattice │ No lattice │ Protect skin")
        XCTAssertEqual(p.selection.groups, topology, "★ Topology's groups are untouched")
        XCTAssertEqual(p.selection.groups.first { $0.id == topo }?.regionIDs, [piece], "★ its Topology group keeps the strip")

        tap(strip, nil); h.pump(0.6)
        tap(strip, nil); h.pump(0.6)
        XCTAssertEqual(p.latticeGroups.first { $0.id == g.id }?.regionIDs, [piece], "★ a 2nd and 3rd tap take nothing away")
        XCTAssertEqual(p.latticeGroups.count, 1)
        XCTAssertEqual(p.selection.groups, topology, "★ … and never reach Topology")

        // control: a face no region covers starts its own group through the same tap, as on 11-08
        let free = try XCTUnwrap(Self.slanted(1, s.mesh).first, "a slanted side")
        var l = p.latticeList
        l.clearActive()
        p.latticeList = l
        tap(free, nil)
        h.pump(0.6)
        XCTAssertTrue(p.latticeGroups.contains { $0.faces.contains(free) && $0.id != g.id }, "control: a plain face still starts a group")
    }

    // MARK: (2.1), (2.2)

    /// ★ (2.2) "He adds a zone, picks a group, then de-picks → the zone is GONE (Lattice zones 2 → 0)" — and ★ (2.1) shot 2:
    /// Group 3 picked, "NO chips show on the part".
    func testZonesStayThroughAPickAndDePickAndGroup3sChipsShow() throws {
        let t = try shotTwo()
        let (h, p) = (t.s.h, t.s.p)
        try h.tap("selGroup-\(t.g3.uuidString)", "Group 3's line: pick it", settle: 1)
        XCTAssertEqual(p.latticeList.activeGroupID, t.g3, "premise: Group 3 picked (shot 2)")
        XCTAssertEqual(p.latticeZones.count, 2, "★ picking a group keeps the zones")

        // control for (2.1): a No lattice Group 3 wears its chips (his was Protect skin, "= Colour": no prism, no chips —
        // what its rows say is the reviewer's ruling, 19:21Z)
        let g3keys = keys(p, t.g3)
        let handles = Set(h.frames.all.keys.filter { $0.hasPrefix("handle-prism-") }.map { String($0.dropFirst("handle-prism-".count)) })
        if handles.isDisjoint(with: g3keys) {
            let planes = p.latticeDepthPlanes().filter { $0.groupID == t.g3 }
            XCTFail("control: a No lattice Group 3 picked shows no chip of its. Its planes \(planes.count) (of \(g3keys.count) rows); chips laid out \(LatticeSetupHandles.chipSpots.count); prisms drawn \(LatticeSetupHandles.drawnPrisms.intersection(g3keys).count); role \(String(describing: p.lattice.groupRoles[t.g3])); hidden \(p.groupView.isHidden(t.g3)); editable \(p.groupView.canEdit(t.g3))")
        }
        try h.picture("his_stand_shot2_group3.png")

        // (2.2) de-pick: its line again
        try h.tap("selGroup-\(t.g3.uuidString)", "Group 3's line again: de-pick it", settle: 1)
        XCTAssertNil(p.latticeList.activeGroupID, "premise: nothing picked")
        XCTAssertEqual(Set(p.latticeZones.map(\.id)), Set(t.zones), "★ the de-pick keeps both zones (shot 3 had 0)")
        for z in t.zones {
            XCTAssertNotNil(p.latticeZoneShape(z), "★ … with their boxes")
            _ = try h.onScreen("latticeZone-\(z.uuidString)", "★ its row in LATTICE ZONES")
        }
        // a tap into nothing, and a face tapped into a group, keep them too
        try XCTUnwrap(LatticeSetupHandles.liveEmptyTap)()
        h.pump(0.6)
        try h.tap("selGroup-\(t.g1.uuidString)", "Group 1's line", settle: 0.6)
        if let more = Self.holesAndRounds(p, t.s.mesh).first(where: { p.latticeList.group(forFace: $0) == nil }) {
            try XCTUnwrap(LatticeSetupHandles.liveViewerTap)(more, nil)
            h.pump(0.6)
        }
        try h.tap("selGroup-\(t.g1.uuidString)", "and de-pick it", settle: 0.6)
        XCTAssertEqual(Set(p.latticeZones.map(\.id)), Set(t.zones), "★ every sweep keeps both zones")
    }

    // MARK: (2.1) — on HIS saved project

    /// His project as he saved it (12:29 AM, pulled read-only by #362 to agent-scratch — never into a repo or evidence;
    /// TOPOPT_HIS_STAND_1109 overrides the folder), restored as the app restores it, on Lattice Setup.
    func hisProject() throws -> (AppBuildHost, ProjectModel) {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOPOPT_HIS_STAND_1109"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("dev/TopOpt/agent-scratch/ipad-notes-1109/his-stand-0A2C4653"))
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.json").path) else {
            throw XCTSkip("his saved 2040 stand project is not on this Mac (\(dir.path))")
        }
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        let stepPath = dir.appendingPathComponent("model.step").path
        let im = try TopOptKit.importMesh(path: stepPath)
        let file = ImportedFile(name: "model.step", path: stepPath, triangleCount: im.triangleCount, faceCount: im.faceCount,
                                watertight: im.watertight, pseudoFaces: im.pseudoFaces)
        let p = ProjectModel(restoring: snap, importedFile: file, importedMesh: im)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("his-project-1109-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.pickFromMenu("capsuleMenu", "Aesthetic", what: "his stage menu")
        h.pump(1.5)
        return (h, p)
    }

    /// ★ (2.1) "Group 3 selected, NO chips show on the part" — his Group 3 is Protect skin: by his rule (Protect Skin =
    /// Colour) it draws no prism and no handle. What was wrong is its rows: "No lattice · 4 mm" beside a depth with nothing
    /// to drag. They say "Protect skin · 4 mm" now (the reviewer's (a)); still no handle on the part.
    func testHisProtectSkinGroupsRowsSayProtectSkin() throws {
        let (h, p) = try hisProject()
        let g3 = try XCTUnwrap(UUID(uuidString: "629226D0-B6CD-49E1-9946-B96FCF85EF31"))
        XCTAssertTrue(p.lattice.skinGroups.contains(g3), "premise: his Group 3 is Protect skin")
        let g = try XCTUnwrap(p.latticeGroups.first { $0.id == g3 }, "premise: his Group 3")
        let refs = p.latticeSelectableRefs(g)
        XCTAssertGreaterThanOrEqual(refs.count, 6, "premise: his holes, rounds and Left side 2")
        try h.tap("selGroup-\(g3.uuidString)", "his Group 3's line: pick it", settle: 1.2)
        XCTAssertEqual(p.latticeList.activeGroupID, g3, "premise: Group 3 picked (shot 2)")
        let keys = Set(refs.map(\.key))
        XCTAssertTrue(h.frames.all.keys.filter { $0.hasPrefix("handle-prism-") }.allSatisfy { !keys.contains(String($0.dropFirst("handle-prism-".count))) },
                      "his rule holds: a Protect skin group wears no handle")
        for ref in refs.prefix(4) {
            h.scrollIntoList("latticeFace-\(ref.key)")
            _ = try h.onScreen("latticeFaceSkin-\(ref.key)", "★ \(p.latticeRowName(ref)) says Protect skin, not No lattice")
        }
        try h.picture("his_project_group3.png")
    }

    // MARK: (2.5)

    /// ★ (2.5) "the Selections modal grows down INTO the bottom hint bubble … His rule: the modal stops ABOVE the hint
    /// bubbles, with a buffer so it doesn't feel crowded." — shot 2's list (Group 3 open, two zones), at both sizes.
    func testTheSelectionsPanelStopsAboveTheHint() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let t = try shotTwo(size)
            let h = t.s.h
            try h.tap("selGroup-\(t.g3.uuidString)", "\(size): Group 3's line", settle: 1.2)
            h.pump(0.6)
            let list = try XCTUnwrap(h.frames.all["selectionsList"], "\(size): the Selections panel")
            let hint = try h.onScreen("stageHint", "\(size): the hint line")
            XCTAssertLessThanOrEqual(list.maxY, size.height - PageChrome.panelBottom + 1,
                                     "\(size): ★ the panel ends on its band (\(list.maxY) vs \(size.height - PageChrome.panelBottom))")
            XCTAssertLessThanOrEqual(list.maxY, hint.minY - 12, "\(size): ★ above the hint, with room: \(list) vs \(hint)")
            for z in t.zones {
                let row = try h.onScreen("latticeZone-\(z.uuidString)", "\(size): ★ a zone row")
                XCTAssertLessThanOrEqual(row.maxY, list.maxY + 0.5, "\(size): ★ inside the panel")
            }
            try h.picture("his_stand_panel_\(Int(size.width)).png")
        }
    }

    // MARK: (3.1), (3.2), (3.3)

    /// Group 1 picked, then one of its faces' rows (scrolled into the list).
    private func pickFace(_ t: ShotTwo) throws -> LatticeSelectableRef {
        let (h, p) = (t.s.h, t.s.p)
        try h.tap("selGroup-\(t.g1.uuidString)", "Group 1's line", settle: 1)
        let g = try XCTUnwrap(p.latticeGroups.first { $0.id == t.g1 })
        let ref = try XCTUnwrap(p.latticeSelectableRefs(g).first, "a face of Group 1")
        h.scrollIntoList("latticeFace-\(ref.key)")
        try h.tap("latticeFace-\(ref.key)", "its row: pick it", settle: 1)
        return ref
    }

    /// ★ (3.1) "the Selections row shows only the depth value — no Expand value": the picked row's Expand line — its number
    /// typed through the pad (★ 3.3: beside it, never over it) lands on the face's Expand.
    func testThePickedFaceRowHasItsExpandAndItsPadOpensBeside() throws {
        let t = try shotTwo()
        let (h, p) = (t.s.h, t.s.p)
        let ref = try pickFace(t)
        h.scrollIntoList("latticeFaceExpandLine-\(ref.key)")
        _ = try h.onScreen("latticeFaceExpandLine-\(ref.key)", "★ the picked row's Expand line")
        let field = try h.onScreen("numberField-latticeFaceExpand-\(ref.key)", "★ its number")
        NumberPadProbe.lastOpen = nil
        try h.tap("numberField-latticeFaceExpand-\(ref.key)", "tap it: the pad")
        _ = try XCTUnwrap(h.padFrame("numberPad"), "★ its pad opens")
        // (3.3) what the page asked of the popover — an offscreen window can't show where a popover lands (it is kept on
        // the screen), so the side is read from the page: a side, the one with room, measured in its own window
        let open = try XCTUnwrap(NumberPadProbe.lastOpen, "the pad says how it opened")
        let edge = try XCTUnwrap(open.edge, "★ (3.3) its number measured, it opens to a side")
        XCTAssertTrue(edge == .leading || edge == .trailing, "★ (3.3) beside its number, never above or below: \(edge)")
        XCTAssertEqual(open.windowWidth, h.size.width, accuracy: 0.5, "its own window")
        XCTAssertEqual(open.anchor.midY, field.midY, accuracy: 2, "its own number")
        XCTAssertEqual(edge, NumberPadPlacement.arrowEdge(anchor: field, windowWidth: h.size.width), "★ the side with room")
        try h.padTap("numberPad-key-2", "2")
        try h.padTap("numberPad-done", "Done")
        XCTAssertEqual(p.latticeExpandMM(ref), 2, accuracy: 1e-9, "★ the face's Expand is 2 mm")
    }

    /// ★ (3.2) "the Expand chip is barely visible and VERY hard to drag": it is the one DragHandle (44 pt, ±), and a drag
    /// along its line moves it with the finger — the Expand changes by the millimetres the finger travels along the face.
    func testTheExpandHandleIsTheDragHandleAndStaysUnderTheFinger() throws {
        let t = try shotTwo()
        let (h, p) = (t.s.h, t.s.p)
        let ref = try pickFace(t)
        p.writeLatticeExpandMM(ref, mm: 10)   // out from the prism's end, clear of its handle
        h.pump(1)
        let key = "expand-\(ref.key)"
        _ = try h.probe("handle-\(key)", "★ the Expand handle: the one DragHandle, a 44 pt target")
        _ = try h.onScreen("handleValue-\(key)", "★ its number beside it (its face picked)")
        let p0 = try XCTUnwrap(LatticeSetupHandles.chipTrue[key], "its true point")
        let axis = try XCTUnwrap(LatticeSetupHandles.live[key], "the handle's drag").axis
        let before = p.latticeExpandMM(ref)
        /// A finger's drag: `to` points along the handle's line, in steps, the page redrawn between them (as a gesture is).
        func drag(to: CGFloat) throws {
            for k in 1...8 {
                try XCTUnwrap(LatticeSetupHandles.live[key], "the handle's drag, as the page last built it").drag(to * CGFloat(k) / 8, false)
                h.pump(0.15)
            }
            try XCTUnwrap(LatticeSetupHandles.live[key]).drag(to, true)
            h.pump(0.8)
        }
        try drag(to: 40)
        let p1 = try XCTUnwrap(LatticeSetupHandles.chipTrue[key])
        let want = CGPoint(x: p0.x + axis.dx * 40, y: p0.y + axis.dy * 40)
        XCTAssertGreaterThan(p.latticeExpandMM(ref), before + 0.1, "★ dragged out, it grows")
        XCTAssertLessThan(hypot(p1.x - want.x, p1.y - want.y), 4,
                          "★ the handle stays under the finger: it is at \(p1), the finger at \(want) (from \(p0), axis \(axis); Expand \(before) → \(p.latticeExpandMM(ref)))")
        try drag(to: -40)
        XCTAssertEqual(p.latticeExpandMM(ref), before, accuracy: 0.5, "★ and back: the same millimetres")
    }
}
#endif
