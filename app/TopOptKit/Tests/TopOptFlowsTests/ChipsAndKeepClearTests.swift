import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ His iPad 2026-10-27: holes losing their keep-clear, chips overlapping, chips everywhere.
@MainActor
final class ChipsAndKeepClearTests: XCTestCase {
    private func bore(r: Double, z0: Double, z1: Double, n: Int = 48) -> [[SIMD3<Double>]] {
        var out: [[SIMD3<Double>]] = []
        for i in 0..<n {
            let t0 = 2 * .pi * Double(i) / Double(n), t1 = 2 * .pi * Double(i + 1) / Double(n)
            let A = SIMD3(r * cos(t0), r * sin(t0), z0), B = SIMD3(r * cos(t1), r * sin(t1), z0)
            let C = SIMD3(r * cos(t1), r * sin(t1), z1), D = SIMD3(r * cos(t0), r * sin(t0), z1)
            out += [[A, C, B], [A, D, C]]
        }
        return out
    }
    private func mesh(_ faces: [[[SIMD3<Double>]]]) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        for (f, tris) in faces.enumerated() {
            for t in tris { for p in t { idx.append(Int32(v.count / 3)); v += [Float(p.x), Float(p.y), Float(p.z)] }; fid.append(Int32(f)) }
        }
        let g = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid, faceGeometry: Array(repeating: g, count: faces.count))
    }

    /// ★ The bug (16 of his 42 bore faces): two lined-up holes in two parallel plates — same axis, same radius, different
    /// stretch of the axis — were taken for one hole and one lost its keep-clear.
    func testLinedUpHolesInTwoPlatesAreTwoHoles() {
        let m = mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)])
        XCTAssertEqual(FaceTopology.borePartners(0, in: m), [0], "a hole in the other plate is not this hole's half")
        XCTAssertTrue(FaceTopology.isBoreRepresentative(1, among: [0, 1], in: m), "★ each plate's hole keeps its own cylinder")
    }

    private func project(_ m: ViewerMesh) -> (ProjectModel, UUID) {
        let p = ProjectModel(id: UUID(), name: "plates", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = m
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([0, 1])
        p.selection = sel
        return (p, sel.groups[0].id)
    }

    func testBothPlatesHolesClearInAnAnchorGroup() {
        let (p, g) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        p.force.makeAnchor(g)
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ both holes")
    }

    /// ★ "I tried unselecting and reselecting and it didn't work": a deleted auto keep-clear was remembered forever.
    func testTakingAHoleOutOfEveryGroupForgetsItsDeletion() {
        let (p, g) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        p.force.makeAnchor(g)
        p.deleteAutoClearance(face: 1, in: g)
        XCTAssertEqual(p.clearanceSpecs().map(\.faceID), [0])
        p.selection.setActive(g); p.selection.pickFaces([1])          // out of the group
        XCTAssertFalse(p.force.isClearanceFaceSuppressed(1, in: g), "★ out of the group: the deletion is forgotten")
        p.selection.pickFaces([1])                                     // back in
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ reselected, it clears again")
    }

    /// ★ His iPad 2026-10-28 (third report): a keep-clear deleted — or turned into a movable primitive — in ONE group used
    /// to kill that hole's keep-clear in EVERY group holding it. Now the mark is the group's own.
    func testADeletionInOneGroupLeavesTheSameHoleClearInAnother() {
        let (p, a) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        var sel = p.selection
        let b = sel.addGroup(); sel.joinFaces([0, 1], to: b); p.selection = sel   // the same two holes in a second group too
        p.force.makeAnchor(a); p.force.makeAnchor(b)
        p.deleteAutoClearance(face: 1, in: a)
        let specs = p.clearanceSpecs().map(\.faceID)
        XCTAssertEqual(specs.filter { $0 == 1 }.count, 1, "★ hole 1 still clears — in the group that didn't delete it")
        XCTAssertEqual(p.selection.groups.count, 2, "premise: both groups hold both holes")
        XCTAssertFalse(p.listedClearanceFaces(p.selection.groups.first { $0.id == a }!).contains(1))
        XCTAssertTrue(p.listedClearanceFaces(p.selection.groups.first { $0.id == b }!).contains(1), "★ its row is there in B")
        // converting it into a movable primitive in A behaves the same
        _ = p.convertAutoClearanceToManual(face: 0, in: a)
        XCTAssertTrue(p.listedClearanceFaces(p.selection.groups.first { $0.id == b }!).contains(0), "★ B keeps hole 0's auto keep-clear")
        // the marks survive a relaunch, per group
        let back = try? JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(p.force))
        XCTAssertEqual(back?.isClearanceFaceSuppressed(1, in: a), true)
        XCTAssertEqual(back?.isClearanceFaceSuppressed(1, in: b), false)
    }

    /// ★ An older project's per-face marks (his) are sorted into groups once the geometry and the groups are here: kept
    /// only where a group converted that hole into a movable primitive; forgotten everywhere else.
    func testAnOlderProjectsMarksAreSortedIntoGroups() {
        let (p, a) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        p.force.makeAnchor(a)
        _ = p.convertAutoClearanceToManual(face: 0, in: a)       // a real conversion: a manual cylinder on hole 0's axis
        p.force.unsuppressClearanceFace(0, in: a)                // …written the OLD way below
        p.force.loadSuppressedClearanceFaces([0, 1])             // what an older project / sidecar carries
        XCTAssertTrue(p.clearanceSpecs().filter { $0.manual == nil }.isEmpty, "premise: the old marks kill both holes")
        p.migrateLegacyClearanceSuppressions()
        XCTAssertTrue(p.force.isClearanceFaceSuppressed(0, in: a), "★ kept where the hole became a movable primitive")
        XCTAssertFalse(p.force.isClearanceFaceSuppressed(1, in: a), "★ forgotten where nothing replaced it")
        XCTAssertEqual(p.clearanceSpecs().filter { $0.manual == nil }.map(\.faceID), [1], "★ hole 1's keep-clear is back")
        XCTAssertTrue(p.force.suppressedClearanceFaceList.isEmpty, "the old list is gone once sorted")
    }

    /// ★ A hole held through a region (isolated / cut on the Surface stage) is held by its group — and clears like one.
    func testARegionHeldHoleGetsItsKeepClear() {
        let (p, a) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        p.force.makeAnchor(a)
        let rid = p.faceRegions.union(faces: [1], named: "Face 1")
        p.selection.removeFaces([1], from: a)
        p.selection.addRegions([rid], to: a)
        XCTAssertFalse(p.selection.groups[0].faces.contains(1), "premise: hole 1 is held only through the region")
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ the region-held hole clears too")
        XCTAssertTrue(p.listedClearanceFaces(p.selection.groups[0]).contains(1), "★ and has its row")
    }

    /// ★ Bug 3: a chip never stays on the Selections panel — it moves just outside it, or (no room) is withdrawn.
    func testAChipNeverSitsOnTheSelectionsPanel() {
        let panel = CGRect(x: 30, y: 520, width: 510, height: 780)
        let pill = KeepOutPlacement(id: "load.x", center: CGPoint(x: 430, y: 660), displacement: .zero, needsLeader: false, hidden: false)
        let out = SelectionsPanelKeepOut.clear(["load.x": pill], sizes: ["load.x": CGSize(width: 240, height: 92)],
                                               panel: panel, viewport: CGSize(width: 1032, height: 1376))
        let r = CGRect(x: out["load.x"]!.center.x - 120, y: out["load.x"]!.center.y - 46, width: 240, height: 92)
        XCTAssertFalse(out["load.x"]!.hidden)
        XCTAssertFalse(r.intersects(panel.insetBy(dx: -KeepOutSolver.separation, dy: -KeepOutSolver.separation)), "★ moved off the panel: \(r)")
        // no room anywhere (a panel the width of the screen): withdrawn, never left on it
        let wide = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        XCTAssertTrue(SelectionsPanelKeepOut.clear(["load.x": pill], sizes: ["load.x": CGSize(width: 240, height: 92)],
                                                   panel: wide, viewport: CGSize(width: 1032, height: 1376))["load.x"]!.hidden)
    }

    /// ★ Bug 5: a tap's ray picks the keep-clear volume it enters — where it hangs in the air past the part too.
    func testATapRayEntersAKeepClearVolume() {
        let geo = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2, axisPoint: .zero, axisDir: SIMD3(0, 0, 1))
        let v = ClearanceVolume.bolt(faceID: 0, geometry: geo, axialSpan: (0, 5), marginMM: 1, axialMM: 2)   // r 3, z −2…7
        XCTAssertEqual(v.rayEntry(origin: SIMD3(10, 0, 6.5), dir: SIMD3(-1, 0, 0)) ?? -1, 7, accuracy: 1e-4,
                       "★ the part ends at z 5 — the volume still picks at z 6.5, in the air")
        XCTAssertNil(v.rayEntry(origin: SIMD3(10, 0, 8), dir: SIMD3(-1, 0, 0)), "past its axial end: a miss")
        XCTAssertNil(v.rayEntry(origin: SIMD3(10, 4, 3), dir: SIMD3(-1, 0, 0)), "beside it: a miss")
        XCTAssertEqual(v.rayEntry(origin: SIMD3(0, 0, 20), dir: SIMD3(0, 0, -1)) ?? -1, 13, accuracy: 1e-4, "down its axis: the cap")
        XCTAssertEqual(v.rayEntry(origin: SIMD3(0, 1, 3), dir: SIMD3(1, 0, 0)), 0, "starting inside: 0")
    }

    /// ★ His "Auto keep clear" switch: works on ANY group; on brings deleted holes back.
    func testAutoKeepClearSwitch() {
        let (p, g) = project(mesh([bore(r: 2, z0: 0, z1: 5), bore(r: 2, z0: 10, z1: 15)]))
        p.force.makeLoad(g)
        XCTAssertFalse(p.force.autoKeepClearIsOn(g), "a Load group starts off")
        XCTAssertTrue(p.clearanceSpecs().isEmpty)
        let group = p.selection.groups[0]
        p.setAutoKeepClear(group, on: true)
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ on: every hole clears, whatever the role")
        p.deleteAutoClearance(face: 0, in: g)
        p.setAutoKeepClear(group, on: true)
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ turning it on brings a deleted hole back")
        p.setAutoKeepClear(group, on: false)
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "off: none")
        // survives a relaunch
        let back = try? JSONDecoder().decode(ForceModel.self, from: JSONEncoder().encode(p.force))
        XCTAssertEqual(back?.autoKeepClearIsOn(g), false)
    }

    /// ★ The app-wide chip rules.
    func testChipsShowOnlyForThePickedPiece() {
        let g = UUID()
        XCTAssertFalse(SelectionArrowRule.chipsShow(group: g, piece: 3, selectedGroup: g, selectedPiece: nil),
                       "★ a selected group alone shows no chips")
        XCTAssertTrue(SelectionArrowRule.chipsShow(group: g, piece: 3, selectedGroup: g, selectedPiece: 3))
        XCTAssertFalse(SelectionArrowRule.chipsShow(group: g, piece: 4, selectedGroup: g, selectedPiece: 3))
    }

    /// ★ His iPad 2026-10-27: a Keep clear group picked again (its primitive tapped) put up the NEW selection's bar — "Add to
    /// Group G as anchor" + Anchor | Load | Keep clear | Protect — and it never went away. A keep-clear / Protect group is done.
    func testAKeepClearOrProtectGroupNeedsNoRole() {
        var f = ForceModel()
        let a = UUID(), b = UUID(), c = UUID()
        f.setKeepClearAffix(a, .on)
        f.setProtected(b, true)
        XCTAssertFalse(f.needsRole(a), "★ keep clear: done")
        XCTAssertFalse(f.needsRole(b), "★ Protect: done")
        XCTAssertTrue(f.needsRole(c), "control: a bare new selection still needs Anchor or Load")
        XCTAssertFalse(f.needsRole(c, latticeRoleGroups: [c]), "a lattice role is a declaration too")
        f.makeAnchor(a)
        XCTAssertFalse(f.needsRole(a))
    }

    func testChipsNeverComeCloseEnoughToMisTap() {
        let a = KeepOutElement(id: "a", anchor: CGPoint(x: 200, y: 200), bounds: CGSize(width: 46, height: 46),
                               touch: CGSize(width: 46, height: 46), priority: .handle)
        let b = KeepOutElement(id: "b", anchor: CGPoint(x: 205, y: 200), bounds: CGSize(width: 46, height: 46),
                               touch: CGSize(width: 46, height: 46), priority: .handle)
        let r = KeepOutSolver.resolve([a, b], viewport: CGSize(width: 1000, height: 1000))
        let pa = r.first { $0.id == "a" }!.center, pb = r.first { $0.id == "b" }!.center
        let gap = max(abs(pa.x - pb.x), abs(pa.y - pb.y)) - 46
        XCTAssertGreaterThanOrEqual(gap, KeepOutSolver.separation - 0.5, "★ at least the app-wide gap between touch areas")
        XCTAssertGreaterThanOrEqual(KeepOutSolver.separation, 16)
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import SwiftUI
import AppKit
import MetalKit
import simd

@MainActor
final class AutoKeepClearHostedTests: XCTestCase {
    private let ui = LoadScenarioHostedTests()

    /// ★ The switch is on his screen, on the open group's lines, and a tap on it flips the group.
    func testTheAutoKeepClearSwitchIsOnHisScreen() throws {
        let r = try ui.project()
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        let h = ui.host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1032, height: 1376))
        ui.pump(3)
        XCTAssertTrue(p.force.autoKeepClearIsOn(c.id), "premise: Group C is an anchor (on by default)")
        let sw = try ui.onScreen(h, "autoKeepClear-\(c.id.uuidString)", "Group C's Auto keep clear switch")
        let line = try ui.onScreen(h, "selGroup-\(c.id.uuidString)", "Group C's line")
        XCTAssertLessThan(sw.minY - line.maxY, 60, "★ right under the group's line, above its primitives")
        try ui.picture(h, "auto_keep_clear.png")
        ui.click(h, CGPoint(x: sw.midX, y: sw.midY))
        XCTAssertFalse(p.force.autoKeepClearIsOn(c.id), "★ the tap turns it off")
        XCTAssertTrue(p.force.autoKeepClearIsSet(c.id))
    }

    /// ★ His iPad 2026-10-27: picking a Keep clear group again must not put up "Add to … as anchor" (it never went away).
    /// The control: a bare new selection still gets it.
    func testAKeepClearGroupPickedAgainGetsNoNewSelectionBar() throws {
        let r = try ui.project()
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.force.clearKind(c.id)                       // Group C: no role …
        p.force.setKeepClearAffix(c.id, .on)                       // … and keep clear: a keep-clear-only group
        p.selection.setActive(c.id)
        let h = ui.host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1032, height: 1376))
        ui.pump(3)
        XCTAssertTrue(p.force.isKeepClearOnly(c.id), "premise")
        XCTAssertNil(h.frames.all["chipJoin"], "★ no 'Add to … as anchor' for a Keep clear group")
        // control: the same group as a bare selection gets the bar, on the same screen
        p.force.setKeepClearAffix(c.id, nil)
        ui.pump(1.5)
        XCTAssertNotNil(h.frames.all["chipJoin"], "control: a selection with no role yet shows 'Add to … as anchor'")
    }

    /// A screen point (view coordinates) whose tap reaches `face` first, through no keep-clear volume — found with the
    /// viewer's own ray and picker, so the tap below is exactly the one his finger makes there.
    static func tapPoint(on face: FaceID, viewer: MetalMeshView.Coordinator, view mtk: MTKView, project p: ProjectModel) -> CGPoint? {
        guard let r = viewer.renderer, let mesh = r.mesh else { return nil }
        let size = mtk.bounds.size, frame = r.pickModelFrame, inv = frame.rotation.inverse
        for y in stride(from: 0.05, to: 0.95, by: 0.01) {
            for x in stride(from: 0.05, to: 0.95, by: 0.01) {
                let (o, d) = FacePicker.ray(camera: r.camera, aspect: Float(size.width / size.height), point: CGPoint(x: x, y: y))
                let mo = frame.centre + inv.act(o - frame.centre), md = simd_normalize(inv.act(d))
                guard let h = FacePicker.hit(rayOrigin: mo, rayDir: md, mesh: mesh), h.faceID == face else { continue }
                let t = simd_dot(h.point - mo, md)
                if p.clearancePieceVolumes().contains(where: { ($0.volume.rayEntry(origin: mo, dir: md) ?? .infinity) < t + 0.5 }) { continue }
                return CGPoint(x: x * size.width, y: y * size.height)
            }
        }
        return nil
    }

    /// ★ His iPad 2026-10-28 (bug 1), HIS CASE: Scenario 2 open, a tap on a face only Scenario 1's load holds starts a NEW
    /// selection — it never re-selects the load he can't see ("Scrub the weight…"). Control: with Scenario 1 open, the same
    /// tap selects that load. Through the viewer's own pick, as his finger reaches it.
    func testATapOnAFaceOnlyAnotherScenarioHoldsStartsANewSelection() throws {
        let r = try ui.project()
        let p = r.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertTrue(p.force.kind(for: top.id).isLoad, "premise: Top is a load")
        let s2 = p.force.addScenario()                 // Scenario 1 becomes real with every load; Scenario 2 opens
        let s1 = try XCTUnwrap(p.force.scenarioList.first?.id)
        XCTAssertEqual(p.force.scenarioID(of: top.id), s1, "premise: Top is Scenario 1's")
        p.selection.clearActive()
        let h = ui.host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1376, height: 1032))
        ui.pump(3)
        let mtk = try XCTUnwrap(ResultsRedesignHostedTests.metalView(in: h.view))
        let click = try XCTUnwrap(mtk.gestureRecognizers.first { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 })
        let viewer = try XCTUnwrap(click.target as? MetalMeshView.Coordinator)
        let only = try XCTUnwrap(top.faces.first { f in p.selection.groups.filter { $0.faces.contains(f) }.count == 1 },
                                 "premise: a face only Top holds")
        let at = try XCTUnwrap(Self.tapPoint(on: only, viewer: viewer, view: mtk, project: p), "a visible spot on that face")

        // control: Scenario 1 open — the tap selects Top
        p.force.openScenario(s1); ui.pump(1)
        viewer.pick(at: at, in: mtk); ui.pump(1)
        XCTAssertEqual(p.selection.activeGroupID, top.id, "control: in its own scenario the tap selects the load")

        // his case: Scenario 2 open — the same tap starts a new selection
        p.selection.clearActive()
        p.force.openScenario(s2); ui.pump(1)
        let before = Set(p.selection.groups.map(\.id))
        viewer.pick(at: at, in: mtk); ui.pump(1)
        let active = try XCTUnwrap(p.selection.activeGroupID, "★ the tap selected something")
        XCTAssertNotEqual(active, top.id, "★ never the load he can't see")
        XCTAssertFalse(before.contains(active), "★ a NEW selection")
        XCTAssertTrue(p.selection.activeGroup?.faces.contains(only) ?? false, "★ started with the tapped face")
        XCTAssertTrue(p.force.needsRole(active), "★ it asks for a role (Anchor / Load / …), not 'Scrub the weight'")
        XCTAssertTrue(p.selection.groups.first { $0.id == top.id }?.faces.contains(only) ?? false, "Top keeps its face")
    }

    /// ★ His iPad 2026-10-28 ("I can't seem to tap on a primitive to select it"): a tap on a keep-clear volume — where it
    /// hangs in the AIR past the part — picks that primitive: its group selected, its row picked. Through the viewer's own pick.
    func testATapOnAPrimitiveInTheAirPicksIt() throws {
        let r = try ui.project()
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.clearActive()
        let h = ui.host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1376, height: 1032))
        ui.pump(3)
        let mtk = try XCTUnwrap(ResultsRedesignHostedTests.metalView(in: h.view))
        let click = try XCTUnwrap(mtk.gestureRecognizers.first { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 1 })
        let viewer = try XCTUnwrap(click.target as? MetalMeshView.Coordinator)
        let rend = try XCTUnwrap(viewer.renderer), mesh = try XCTUnwrap(rend.mesh)
        let manual = Set(p.force.manualPrimitives(for: c.id).map { ProjectModel.manualFaceKey($0.id) })
        // a spot where the nearest volume the ray enters is one of Group C's cylinders, and the PART is not under the finger
        var at: CGPoint?, want: Int?
        let size = mtk.bounds.size, frame = rend.pickModelFrame, inv = frame.rotation.inverse
        search: for y in stride(from: 0.05, to: 0.95, by: 0.01) {
            for x in stride(from: 0.05, to: 0.95, by: 0.01) {
                let (o, d) = FacePicker.ray(camera: rend.camera, aspect: Float(size.width / size.height), point: CGPoint(x: x, y: y))
                let mo = frame.centre + inv.act(o - frame.centre), md = simd_normalize(inv.act(d))
                guard FacePicker.hit(rayOrigin: mo, rayDir: md, mesh: mesh) == nil else { continue }   // air under the finger
                let hits = p.clearancePieceVolumes().compactMap { v in v.volume.rayEntry(origin: mo, dir: md).map { (v.groupID, v.piece, $0) } }
                guard let first = hits.min(by: { $0.2 < $1.2 }), first.0 == c.id, manual.contains(first.1) else { continue }
                at = CGPoint(x: x * size.width, y: y * size.height); want = first.1; break search
            }
        }
        let tap = try XCTUnwrap(at, "a spot on a primitive that hangs in the air")
        viewer.pick(at: tap, in: mtk); ui.pump(1)
        XCTAssertEqual(p.selection.activeGroupID, c.id, "★ the tap picked the primitive's group (not an empty-space clear)")
        let picked = h.frames.all.keys.filter { $0.hasPrefix("piecePicked:") }
        let id = try XCTUnwrap(p.force.manualPrimitives(for: c.id).first { ProjectModel.manualFaceKey($0.id) == want })?.id
        XCTAssertEqual(picked, ["piecePicked:pick-manual-\(id!.uuidString)"], "★ its own row is the picked one")
        try ui.picture(h, "primitive_tapped_in_air.png")
    }
}
#endif
