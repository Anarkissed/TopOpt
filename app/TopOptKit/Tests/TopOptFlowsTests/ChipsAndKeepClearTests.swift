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
        p.deleteAutoClearance(face: 1)
        XCTAssertEqual(p.clearanceSpecs().map(\.faceID), [0])
        p.selection.setActive(g); p.selection.pickFaces([1])          // out of the group
        XCTAssertFalse(p.force.isClearanceFaceSuppressed(1), "★ out of every group: the deletion is forgotten")
        p.selection.pickFaces([1])                                     // back in
        XCTAssertEqual(Set(p.clearanceSpecs().map(\.faceID)), [0, 1], "★ reselected, it clears again")
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
        p.deleteAutoClearance(face: 0)
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
}
#endif
