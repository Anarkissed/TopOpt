import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ THE REGIONS TASK, the model half (the reviewer, 2026-10-08, approved by the maintainer):
/// 1. "Pattern on a face inside a union splits the WHOLE union."
/// 2. "Dissolve: the faces go back to the group they came from."
/// 3. "The Surface scratchpad carries groups, so Dissolve reverts cleanly."
@MainActor
final class SurfaceRegionsTaskTests: XCTestCase {

    /// Three stacked 10 × 10 mm square faces (ids 0, 1, 2) — `SurfaceUnionPartsTests`' fixture —
    /// with one group holding all three.
    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        V(0, 0, 9); V(10, 0, 9); V(10, 10, 9); V(0, 10, 9)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 8, 9, 10, 8, 10, 11],
                              faceIDs: [0, 0, 1, 1, 2, 2],
                              faceGeometry: (0..<3).map { _ in StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)) })
        let p = ProjectModel(id: UUID(), name: "R", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    private func union(_ p: ProjectModel, _ faces: [FaceID] = [1, 2]) throws -> (u: RegionID, parts: [RegionID]) {
        let parts = try faces.map { try XCTUnwrap(p.surfaceEnsureRegion(for: $0)) }
        var su = SurfaceUnion()
        for x in parts { su.toggle(x) }
        return (try XCTUnwrap(p.commitSurfaceUnion(su)), parts)
    }

    // MARK: 1. pattern on a union

    /// ★ The grid laid on the tapped face cuts EVERY part: each cell of the union holds both faces,
    /// the group reads the cells, and the preview priced both parts.
    func testPatternOnAUnionSplitsTheWholeUnion() throws {
        let p = project()
        let (u, parts) = try union(p)
        let one = try XCTUnwrap(p.surfacePatternPreview(face: 1, columns: 2, rows: 1, piece: parts[0]))
        let whole = try XCTUnwrap(p.surfacePatternPreview(face: 1, columns: 2, rows: 1, piece: u))
        XCTAssertTrue(whole.verdict.ok)
        XCTAssertEqual(whole.verdict.memberVoxels, 2 * one.verdict.memberVoxels, "★ priced over both parts")
        let cells = p.commitSurfacePattern(face: 1, columns: 2, rows: 1, piece: u)
        XCTAssertEqual(cells.count, 2)
        for c in cells {
            XCTAssertEqual(p.surfaceResolvedFaces(c), [1, 2], "★ every cell holds both parts' faces")
            XCTAssertTrue(p.faceRegions.region(c)?.isUnionOfParts ?? false, "a cell across two parts is a union")
            XCTAssertNil(p.faceRegions.region(c)?.partParents, "it OWNS its pieces")
        }
        let g = try XCTUnwrap(p.selection.groups.first)
        XCTAssertEqual(Set(p.surfaceEffectiveRegions(of: g)).intersection([u] + parts), [],
                       "★ the union and its parts are represented by the cells")
        XCTAssertTrue(Set(cells).isSubset(of: p.surfaceEffectiveRegions(of: g)))
        // the parts survive, still under the union
        for x in parts { XCTAssertEqual(p.faceRegions.region(x)?.parentID, u) }
        // ★ Undo split takes back the cells, never the parts
        p.faceRegions.revertSplit(u)
        XCTAssertEqual(Set(p.faceRegions.children(of: u).map(\.id)), Set(parts))
        XCTAssertEqual(p.surfaceResolvedFaces(u), [1, 2])
        XCTAssertEqual(p.surfaceEffectiveRegions(of: g).filter { $0 == u }, [u], "the union speaks for itself again")
    }

    /// ★ A selected union cell lights PIECE BY PIECE — its pieces' half-space chains, no whole-face
    /// picks — while a union of whole faces keeps lighting whole (nil). Pixels: SurfaceStageRenderSeamTests.
    func testASelectedUnionCellLightsByItsPieces() throws {
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let (u, _) = try union(p)
        XCTAssertNil(SurfaceTint.unionLighting(u, regions: p.faceRegions, mesh: mesh), "whole faces light whole")
        let cells = p.commitSurfacePattern(face: 1, columns: 2, rows: 1, piece: u)
        let ul = try XCTUnwrap(SurfaceTint.unionLighting(cells[0], regions: p.faceRegions, mesh: mesh))
        XCTAssertEqual(ul.chains.count, 2, "★ one chain per piece")
        XCTAssertEqual(ul.fragmentTested, [1, 2])
        XCTAssertTrue(ul.picked.isEmpty, "no piece lights its whole face")
    }

    /// A cell that reaches ONE part is that part's piece — no union of one.
    func testACellThatReachesOnePartIsItsPiece() throws {
        let p = project()
        // a union of a half of face 1 and the whole of face 2: cut face 1 in two first
        let r1 = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let halves = p.faceRegions.splitManual(r1, point: SIMD3(5, 5, 5), normal: SIMD3(1, 0, 0))
        XCTAssertEqual(halves.count, 2)
        let r2 = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var su = SurfaceUnion(); su.toggle(halves[0]); su.toggle(r2)
        let u = try XCTUnwrap(p.commitSurfaceUnion(su))
        // columns across x: the half x ≥ 5 reaches only the right column
        let cells = p.commitSurfacePattern(face: 2, columns: 2, rows: 1, piece: u)
        XCTAssertFalse(cells.isEmpty)
        let lone = cells.filter { !(p.faceRegions.region($0)?.isUnionOfParts ?? true) }
        XCTAssertFalse(lone.isEmpty, "★ a cell reaching one part is that part's own piece")
        for c in cells { XCTAssertFalse(p.surfaceResolvedFaces(c).isEmpty, "no cell holds nothing") }
    }

    // MARK: 2. dissolve

    /// ★ The faces go back to the group the region came from — not the active group.
    func testDissolveSendsTheFacesBackToTheirOwnGroup() throws {
        let p = project()
        let home = try XCTUnwrap(p.selection.groups.first).id
        let rid = try XCTUnwrap(p.commitSurfaceUnion(faces: [1, 2]))
        XCTAssertTrue(p.selection.group(forRegion: rid)?.id == home)
        // another group, made active
        let other = p.selection.addGroup()
        p.selection.pickFaces([0])
        p.selection.setActive(other)
        XCTAssertEqual(p.selection.activeGroupID, other)
        let r = try XCTUnwrap(p.surfaceDissolve(rid))
        XCTAssertEqual(r.group, home, "★ the group it came from")
        XCTAssertEqual(r.faces, [1, 2])
        let h = try XCTUnwrap(p.selection.groups.first { $0.id == home })
        XCTAssertTrue(Set(h.faces).isSuperset(of: [1, 2]))
        XCTAssertFalse(h.regionIDs.contains(rid))
        XCTAssertFalse(p.selection.groups.first { $0.id == other }!.faces.contains(1), "never the active group")
    }

    /// ★ A union of parts gives its parts back, under their own parents, in their groups.
    func testDissolvingAUnionGivesItsPartsBack() throws {
        let p = project()
        let r1 = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let halves = p.faceRegions.splitManual(r1, point: SIMD3(5, 5, 5), normal: SIMD3(1, 0, 0))
        let r2 = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var su = SurfaceUnion(); su.toggle(halves[0]); su.toggle(r2)
        let u = try XCTUnwrap(p.commitSurfaceUnion(su))
        XCTAssertEqual(p.faceRegions.region(u)?.partParents, [r1, -1], "the parts' parents are recorded")
        let r = try XCTUnwrap(p.surfaceDissolve(u))
        XCTAssertEqual(Set(r.restoredParts), [halves[0], r2])
        XCTAssertEqual(r.dropped, [u], "★ only the union goes")
        XCTAssertEqual(p.faceRegions.region(halves[0])?.parentID, r1, "★ back under its own parent")
        XCTAssertEqual(p.faceRegions.region(r2)?.parentID, -1)
        XCTAssertFalse(p.selection.groups.contains { $0.regionIDs.contains(u) }, "nothing dangling")
        XCTAssertEqual(p.surfaceResolvedFaces(halves[0]), [1])
    }

    /// Every region a dissolve removes leaves every group; a cut piece is refused (Undo split).
    func testNothingDanglesAndACutPieceIsRefused() throws {
        let p = project()
        let home = try XCTUnwrap(p.selection.groups.first).id
        let r0 = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        let halves = p.faceRegions.splitManual(r0, point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0))
        let other = p.selection.addGroup()
        p.selection.addRegions([halves[1]], to: other)          // a piece moved to another group
        XCTAssertNotNil(SurfaceDissolve.refusal(halves[0], regions: p.faceRegions), "★ a cut piece: Undo split")
        XCTAssertNil(p.surfaceDissolve(halves[0]))
        let r = try XCTUnwrap(p.surfaceDissolve(r0))
        XCTAssertEqual(Set(r.dropped), Set([r0] + halves))
        XCTAssertEqual(r.group, home)
        for g in p.selection.groups {
            XCTAssertTrue(Set(g.regionIDs).isDisjoint(with: r.dropped), "★ no dropped id in \(g.name)")
        }
    }

    // MARK: 3. the scratchpad

    /// ★ A dissolve reverts cleanly: regions, every group's faces AND regions, the active group.
    func testLeavingWithoutSavingRevertsADissolve() throws {
        let p = project()
        let rid = try XCTUnwrap(p.commitSurfaceUnion(faces: [1, 2]))
        // the faces themselves now sit in ANOTHER group — the dissolve will take them from it
        _ = p.selection.addGroup()
        p.selection.pickFaces([1, 2])
        let snap = p.surfaceCaptureScratch()
        let groupsBefore = p.selection.groups
        XCTAssertNotNil(p.surfaceDissolve(rid))
        XCTAssertTrue(p.surfaceHasEdits(since: snap))
        p.surfaceRestore(snap)
        XCTAssertEqual(p.selection.groups, groupsBefore, "★ the whole group layer, faces included")
        XCTAssertEqual(p.faceRegions, snap.regions)
        XCTAssertFalse(p.surfaceHasEdits(since: snap))
    }

    /// ★ A group the session SWEPT comes back — with its role and its protection.
    func testASweptGroupComesBackWithItsRoleAndProtection() throws {
        let p = project()
        let r0 = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        let halves = p.faceRegions.splitManual(r0, point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0))
        let other = p.selection.addGroup()
        p.selection.addRegions([halves[1]], to: other)
        p.force.makeAnchor(other)
        p.force.setProtected(other, true)
        p.selection.setActive(try XCTUnwrap(p.selection.groups.first).id)
        let snap = p.surfaceCaptureScratch()
        XCTAssertNotNil(p.surfaceDissolve(r0))
        XCTAssertFalse(p.selection.groups.contains { $0.id == other }, "control: the dissolve swept it")
        XCTAssertEqual(p.force.kind(for: other), .pending, "control: and its role went with it")
        p.surfaceRestore(snap)
        XCTAssertTrue(p.selection.groups.contains { $0.id == other }, "★ back")
        XCTAssertEqual(p.force.kind(for: other), .anchor, "★ with its role")
        XCTAssertTrue(p.force.isProtected(other), "★ and its protection")
        XCTAssertEqual(p.force, snap.force, "nothing else in the force model moved")
    }

    /// `restoreEntries` puts back exactly what `sync` prunes — the two read the same stores.
    func testRestoreEntriesMirrorsSync() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/ForceModel.swift"), encoding: .utf8)
        func body(_ decl: String) throws -> String {
            let r = try XCTUnwrap(src.range(of: decl))
            let rest = src[r.lowerBound...]
            return String(rest[..<(rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex)])
        }
        let stores = ["kinds", "clearanceOverrides", "keepClear", "faceProtect", "syncExcluded", "manualPrimitives", "BoreOverrides"]
        let sync = try body("public mutating func sync(groups: [SelectionGroup])")
        let restore = try body("public mutating func restoreEntries(for ids: Set<UUID>, from captured: ForceModel)")
        for s in stores {
            XCTAssertEqual(sync.contains(s), restore.contains(s), "★ \(s): sync and restoreEntries must name the same stores")
            XCTAssertTrue(sync.contains(s), "the list is sync's: \(s)")
        }
    }
}
