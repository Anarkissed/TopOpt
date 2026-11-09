// LatticeSetupChipsTests — his iPad notes 11-08 (~17:10 EST, via #362 22:20Z: "very important … I am unable to get a decent
// lattice"), Lattice Setup's interaction items, on HIS 2040 Extrusion Stand (Squish Mechanism, PA12, Structural, Start from
// "All lattice · − Lattice faces", two face groups, both No lattice, 4 mm deep):
//   1. a tap into nothing, with a group's face-prisms showing, deselects — the chips go;
//   2. a group collapses: the open row's tap (or its chevron) leaves nothing open, and the next free face starts a new group
//      with no "+ New group";
//   3. every chip has clear space between it and the next (KeepOutSolver.separation);
//   4. ONLY THE PICKED THING'S CHIPS: one face-prism → that one's; a group row → that group's; a zone → that zone's; nothing
//      picked → none (on 2a7c7bd8 every face of every group a model tap had opened wore its handle and ± knob).
// His STEP is read where it is, read-only, and never copied (TOPOPT_HIS_STAND overrides the path); absent, the hosted tests
// skip, counted.
import XCTest
import CoreGraphics
@testable import TopOptFlows

final class LatticeSetupChipsTests: XCTestCase {

    private let a = UUID(), b = UUID(), z = UUID()
    private func refs(_ id: UUID) -> [String] { id == a ? ["a1", "a2"] : id == b ? ["b1", "b2"] : [] }

    func testTheScopeIsWhatIsPicked() {
        typealias S = LatticeSetupHandles.ChipScope
        XCTAssertEqual(S.of(active: nil, zones: [z], facePick: "a1", groupRefs: refs), .none, "★ nothing picked → none")
        XCTAssertEqual(S.of(active: a, zones: [z], facePick: nil, groupRefs: refs), .group(a))
        XCTAssertEqual(S.of(active: a, zones: [z], facePick: "a2", groupRefs: refs), .face(group: a, key: "a2"))
        XCTAssertEqual(S.of(active: b, zones: [z], facePick: "a2", groupRefs: refs), .group(b),
                       "★ another group's picked face does not follow")
        XCTAssertEqual(S.of(active: z, zones: [z], facePick: nil, groupRefs: refs), .zone(z))
    }

    func testOnlyThePickedThingsChipsShow() {
        typealias S = LatticeSetupHandles.ChipScope
        XCTAssertFalse(S.none.shows(group: a, key: "a1"), "★ nothing picked → no chip")
        XCTAssertTrue(S.group(a).shows(group: a, key: "a1"))
        XCTAssertTrue(S.group(a).shows(group: a, key: "a2"))
        XCTAssertFalse(S.group(a).shows(group: b, key: "b1"), "★ a group → never another group's")
        XCTAssertTrue(S.face(group: a, key: "a2").shows(group: a, key: "a2"))
        XCTAssertFalse(S.face(group: a, key: "a2").shows(group: a, key: "a1"), "★ one face → never its group's other faces")
        XCTAssertFalse(S.zone(z).shows(group: a, key: "a1"), "★ a zone → no face chips")
    }

    /// ★ (3): two chips on one point, and a third beside them, come out with the app's gap between every footprint; the
    /// first stays on its point; one in the page's UI slides out of it.
    func testEveryChipGetsClearSpace() {
        let p = CGPoint(x: 400, y: 300)
        let chips: [LatticeSetupHandles.Chip] = [
            .init(key: "h1", at: p, axis: CGVector(dx: 0, dy: -1), shape: .init(size: 44, pill: true)),
            .init(key: "k1", at: CGPoint(x: 410, y: 305), axis: CGVector(dx: 1, dy: 0), shape: .init(size: 44)),
            .init(key: "h2", at: CGPoint(x: 395, y: 290), axis: CGVector(dx: 0.6, dy: -0.8), shape: .init(size: 44, pill: true)),
        ]
        let out = LatticeSetupHandles.layout(chips, keepOut: [])
        XCTAssertEqual(out["h1"], p, "the first chip stays on its point")
        let rects = chips.map { $0.shape.rect(out[$0.key] ?? .zero) }
        for i in rects.indices { for j in rects.indices where j > i {
            XCTAssertFalse(rects[i].insetBy(dx: -LatticeSetupHandles.chipGap / 2 + 0.5, dy: -LatticeSetupHandles.chipGap / 2 + 0.5)
                .intersects(rects[j].insetBy(dx: -LatticeSetupHandles.chipGap / 2 + 0.5, dy: -LatticeSetupHandles.chipGap / 2 + 0.5)),
                           "★ \(chips[i].key) and \(chips[j].key) have \(LatticeSetupHandles.chipGap) pt between them: \(rects[i]) \(rects[j])")
        } }
        let panel = CGRect(x: 0, y: 0, width: 360, height: 900)
        let slid = LatticeSetupHandles.layout([.init(key: "x", at: CGPoint(x: 340, y: 200), axis: CGVector(dx: 1, dy: 0),
                                                     shape: .init(size: 44))], keepOut: [panel])
        XCTAssertFalse(panel.intersects(LatticeSetupHandles.FootprintShape(size: 44).rect(slid["x"] ?? .zero)), "out of the page's UI")
    }

    /// ★ (3) on his stand, a crowded chip (38 over one slanted side) found nothing on its four lines and stayed ON another
    /// chip: here both lines through its point are taken end to end; the nearest room is on a diagonal, and it goes there.
    func testACrowdedChipFindsRoomOnADiagonal() {
        let at = CGPoint(x: 400, y: 400)
        let bands = [CGRect(x: 0, y: 370, width: 1000, height: 60), CGRect(x: 370, y: 0, width: 60, height: 1000)]
        let out = LatticeSetupHandles.layout([.init(key: "k", at: at, axis: CGVector(dx: 1, dy: 0), shape: .init(size: 44))],
                                             keepOut: bands)
        let r = LatticeSetupHandles.FootprintShape(size: 44).rect(out["k"] ?? at)
        XCTAssertFalse(bands.contains { $0.intersects(r) }, "★ the crowded chip found room off both its lines: \(r)")
        XCTAssertLessThan(hypot((out["k"] ?? at).x - at.x, (out["k"] ?? at).y - at.y), 120, "… the nearest room, not a far one")
    }

    func testAChipWithRoomStaysOnItsPoint() {
        let chips: [LatticeSetupHandles.Chip] = [
            .init(key: "h1", at: CGPoint(x: 100, y: 100), axis: CGVector(dx: 0, dy: -1), shape: .init(size: 44)),
            .init(key: "h2", at: CGPoint(x: 400, y: 400), axis: CGVector(dx: 0, dy: -1), shape: .init(size: 44)),
        ]
        let out = LatticeSetupHandles.layout(chips, keepOut: [])
        XCTAssertEqual(out["h1"], CGPoint(x: 100, y: 100))
        XCTAssertEqual(out["h2"], CGPoint(x: 400, y: 400), "control: nothing moves that need not")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import SwiftUI
import AppKit
import simd
@testable import TopOptKit

@MainActor
final class HisStandChipsHostedTests: XCTestCase {

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
            LatticeSetupHandles.liveEmptyTap = nil
            LatticeSetupHandles.latticeTinted = []
            LatticeSetupHandles.chipSpots = [:]
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    /// His STEP, where it is (read-only; never copied into the repo or evidence).
    static var standPath: String {
        ProcessInfo.processInfo.environment["TOPOPT_HIS_STAND"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(
                "Desktop/3D Model Projects/Squish Mechanism/TO_STEP-files/2040 Extrusion Stand.step")
    }

    struct Stand {
        let h: AppBuildHost
        let p: ProjectModel
        let g1: SelectionGroup
        let g2: SelectionGroup
    }

    /// His project as he set it: Structural, Start from "All lattice · − Lattice faces" (whole part), two face groups —
    /// Group 1 the stand's −X slanted faces, Group 2 its +X slanted faces with their rounded edges — both No lattice, 4 mm
    /// deep, each made the way his taps make it (the app's loop, `latticeStageTap`), on the Lattice stage at `size`.
    func stand(_ size: CGSize = AppBuildHost.landscape13) throws -> Stand {
        guard FileManager.default.fileExists(atPath: Self.standPath) else {
            throw XCTSkip("his 2040 Extrusion Stand STEP is not on this Mac (\(Self.standPath))")
        }
        let p = try FlexiblePressFixtures.project(path: Self.standPath, name: "2040 Extrusion Stand")
        p.lattice.flexible = nil
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        let mesh = try XCTUnwrap(p.viewerMesh)
        // His Topology first (the ● menu greys Lattice until gravity, an anchor and a load are set, and the gravity step
        // hides the capsule): down is −Z, the flat underside anchored, the flat top loaded.
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        func flat(_ s: Float) -> FaceID? {
            FaceTopology.faceIDs(in: mesh).filter { f in
                guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
                return simd_normalize(SIMD3<Float>(g.planeNormal)).z * s > 0.99
            }.max { (mesh.faceCentroid($0)?.z ?? 0) * s < (mesh.faceCentroid($1)?.z ?? 0) * s }
        }
        let base = try XCTUnwrap(flat(-1), "premise: his stand has a flat underside")
        let top = try XCTUnwrap(flat(1), "premise: his stand has a flat top")
        let anchor = p.selection.addGroup()
        p.selection.addFaces([base], to: anchor)
        p.force.makeAnchor(anchor)
        let load = p.selection.addGroup()
        p.selection.addFaces([top], to: load)
        p.force.makeLoad(load)
        p.syncForceGroups()
        p.selection.clearActive()
        func slanted(_ sign: Float) -> [FaceID] {
            FaceTopology.faceIDs(in: mesh).filter { f in
                guard let g = mesh.faceGeometry(f), g.isPlane else { return false }
                let n = simd_normalize(SIMD3<Float>(g.planeNormal))
                return n.x * sign > 0.3 && abs(n.z) > 0.2 && abs(n.z) < 0.95
            }
        }
        let left = slanted(-1), right = slanted(1)
        XCTAssertFalse(left.isEmpty, "premise: his stand has −X slanted faces")
        XCTAssertFalse(right.isEmpty, "premise: his stand has +X slanted faces")
        let adj = FaceTopology.adjacency(in: mesh)
        let edges = Set(right.flatMap { adj[$0] ?? [] }).filter { p.faceName($0).hasPrefix("Rounded edge") }.sorted()
        func tap(_ faces: [FaceID]) -> UUID? {
            for f in faces {
                let loop = p.surfaceLoopRespectingRegions(FaceTopology.loop(fromFace: f, in: mesh), from: f)
                _ = p.latticeStageTap(face: f, loop: loop)
            }
            return p.latticeList.activeGroupID
        }
        p.latticeList.clearActive()
        let id1 = try XCTUnwrap(tap(left), "Group 1")
        p.latticeList.clearActive()
        let id2 = try XCTUnwrap(tap(right + edges), "Group 2")
        XCTAssertNotEqual(id1, id2)
        p.lattice.wholePart = true   // Start from "All lattice · − Lattice faces"
        for id in [id1, id2] {
            p.lattice.groupRoles[id] = .exclude   // No lattice
            p.writeGroupDepthMM(id, mm: 4)
        }
        p.latticeList.clearActive()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("his-stand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: size, test: self)
        h.pump(2)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1.5)
        let g1 = try XCTUnwrap(p.latticeGroups.first { $0.id == id1 })
        let g2 = try XCTUnwrap(p.latticeGroups.first { $0.id == id2 })
        XCTAssertGreaterThanOrEqual(p.latticeSelectableRefs(g2).count, 2, "premise: Group 2 holds several of his faces")
        return Stand(h: h, p: p, g1: g1, g2: g2)
    }

    /// The chips on the part now: each face's end handle and ± knob (by row key), a zone side, the ×.
    private func chips(_ h: AppBuildHost) -> (handles: Set<String>, knobs: Set<String>) {
        let keys = h.frames.all.keys
        return (Set(keys.filter { $0.hasPrefix("handle-prism-") }.map { String($0.dropFirst("handle-prism-".count)) }),
                Set(keys.filter { $0.hasPrefix("latticeExpandKnob-") }.map { String($0.dropFirst("latticeExpandKnob-".count)) }))
    }

    private func keys(_ p: ProjectModel, _ g: SelectionGroup) -> Set<String> { Set(p.latticeSelectableRefs(g).map(\.key)) }

    /// ★ (4) "ONLY THE PICKED THING'S CHIPS", repeated as he did it: taps on both groups' faces on the part (each opened its
    /// group's drawer, and on 2a7c7bd8 every face of both kept its chips), then ONE face-prism of Group 2 picked.
    func testOnlyThePickedFacesChipsShow() throws {
        let s = try stand()
        let (h, p) = (s.h, s.p)
        let pick = try XCTUnwrap(LatticeSetupHandles.livePick, "the page's face tap")
        for g in [s.g1, s.g2] { if let f = g.faces.first { pick(f); h.pump(0.6) } }
        XCTAssertEqual(p.latticeList.activeGroupID, s.g2.id, "premise: his last tap picked Group 2")
        let ref = try XCTUnwrap(p.latticeSelectableRefs(s.g2).first, "a face of Group 2")
        try h.tap("latticeFace-\(ref.key)", "Group 2's first face row", settle: 1)
        let c = chips(h)
        XCTAssertEqual(c.handles, [ref.key], "★ one face-prism picked → its end handle only, got \(c.handles.sorted())")
        XCTAssertEqual(c.knobs, [ref.key], "★ … and its ± knob only, got \(c.knobs.sorted())")
        XCTAssertTrue(c.handles.isDisjoint(with: keys(p, s.g1)), "★ never Group 1's")
        try h.picture("his_stand_one_face.png")

        // the group row → that group's (control: a group's chips still show on its row)
        try h.tap("latticeFace-\(ref.key)", "the picked row again: back to the group", settle: 1)
        let g = chips(h)
        XCTAssertFalse(g.handles.isEmpty, "control: Group 2 picked → its faces' chips")
        XCTAssertTrue(g.handles.isSubset(of: keys(p, s.g2)) && g.knobs.isSubset(of: keys(p, s.g2)),
                      "★ a group row → that group's chips only, got \(g.handles.sorted()) \(g.knobs.sorted())")
    }

    /// ★ (1): a tap into nothing with Group 2's prisms showing deselects — the group closes and every chip goes.
    func testATapIntoNothingDeselects() throws {
        let s = try stand()
        let (h, p) = (s.h, s.p)
        p.latticeList.setActive(s.g2.id)
        h.pump(1)
        XCTAssertFalse(chips(h).handles.isEmpty, "premise: Group 2's chips show")
        let empty = try XCTUnwrap(LatticeSetupHandles.liveEmptyTap, "the page's tap into nothing")
        empty()
        h.pump(1)
        XCTAssertNil(p.latticeList.activeGroupID, "★ nothing picked")
        let c = chips(h)
        XCTAssertTrue(c.handles.isEmpty && c.knobs.isEmpty, "★ no chip on the part: \(c.handles.sorted()) \(c.knobs.sorted())")
        XCTAssertNil(h.frames.all.keys.first { $0.hasPrefix("latticeFace-") && !$0.hasSuffix("-line") },
                     "★ no group's rows open")
    }

    /// ★ (2): a group collapses — its chevron closes it (and its line does), nothing is open after, and the next free face
    /// starts a NEW group with no "+ New group".
    func testAGroupCollapsesAndTheNextFaceStartsANewGroup() throws {
        let s = try stand()
        let (h, p) = (s.h, s.p)
        try h.tap("selGroup-\(s.g2.id.uuidString)", "Group 2's line: open it", settle: 1)
        XCTAssertEqual(p.latticeList.activeGroupID, s.g2.id, "premise: Group 2 open")
        try h.tap("selOpen-\(s.g2.id.uuidString)", "★ Group 2's chevron", settle: 1)
        XCTAssertNil(p.latticeList.activeGroupID, "★ the chevron closes the open group")
        XCTAssertTrue(keys(p, s.g2).allSatisfy { h.frames.all["latticeFace-\($0)"] == nil }, "★ its rows are gone")
        try h.tap("selGroup-\(s.g2.id.uuidString)", "Group 2's line again: open", settle: 1)
        try h.tap("selGroup-\(s.g2.id.uuidString)", "and its line: close", settle: 1)
        XCTAssertNil(p.latticeList.activeGroupID, "control: the open line's tap closes it")

        let mesh = try XCTUnwrap(p.viewerMesh)
        let held = Set(p.latticeGroups.flatMap(\.faces))
        let free = try XCTUnwrap(FaceTopology.faceIDs(in: mesh).first { !held.contains($0) && (mesh.faceGeometry($0)?.isPlane ?? false) })
        let before = p.latticeGroups.count
        try XCTUnwrap(LatticeSetupHandles.livePick)(free)
        h.pump(1)
        XCTAssertEqual(p.latticeGroups.count, before + 1, "★ the next free face starts a new group, no + New group")
        XCTAssertFalse(p.latticeGroups.contains { $0.id != p.latticeList.activeGroupID && $0.faces.contains(free) })
    }

    /// ★ (3): with Group 2 picked on his slanted faces, every chip on the part — each face's end handle (with its number
    /// when picked) and ± knob — has the app's clear space to the next; at both window sizes.
    func testEveryChipOnHisSlantedFacesHasClearSpace() throws {
        for size in [AppBuildHost.landscape13, CGSize(width: 820, height: 1180)] {
            let s = try stand(size)
            let (h, p) = (s.h, s.p)
            p.latticeList.setActive(s.g2.id)
            h.pump(1)
            let all = h.frames.all
            var rects: [(String, CGRect)] = []
            for k in keys(p, s.g2) {
                if var r = all["handle-prism-\(k)"] {
                    if let v = all["handleValue-prism-\(k)"] { r = r.union(v) }
                    rects.append(("handle \(k)", r))
                }
                if let r = all["latticeExpandKnob-\(k)"] { rects.append(("knob \(k)", r)) }
            }
            XCTAssertGreaterThanOrEqual(rects.count, 4, "\(size): premise: several chips on Group 2")
            let gap = LatticeSetupHandles.chipGap - 1
            let spots = LatticeSetupHandles.chipSpots
            func laid(_ name: String) -> String {
                let k = name.hasPrefix("handle ") ? "prism-" + name.dropFirst(7) : "expand-" + name.dropFirst(5)
                return spots[k].map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "none"
            }
            for i in rects.indices { for j in rects.indices where j > i {
                let a = rects[i].1.insetBy(dx: -gap / 2, dy: -gap / 2), b = rects[j].1.insetBy(dx: -gap / 2, dy: -gap / 2)
                XCTAssertFalse(a.intersects(b), "\(size): ★ \(rects[i].0) and \(rects[j].0) are under \(Int(gap)) pt apart: \(rects[i].1) \(rects[j].1); laid out at \(laid(rects[i].0)) \(laid(rects[j].0)); \(spots.count) chips laid out")
            } }
            try h.picture("his_stand_group2_\(Int(size.width)).png")
        }
    }
}
#endif
