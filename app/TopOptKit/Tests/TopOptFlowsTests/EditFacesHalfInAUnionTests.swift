// EditFacesHalfInAUnionTests — ★ his iPad 11-16 (the "T"): "I tried undoing the cut. I did so with the "region" tool. And then
// when I selected the horizontal top line of the "T" the only thing that it selects is the unioned faces of the vertical line
// now." His job of 15:55 (79b695c5) showed the state: the thin face's piece "Face 25 A" (cut once) inside the union of the stem
// (parent 138, the union's record of its own parent 100), the face's own region 100 and its other half gone.
//   1. Taking a cut back (the Region tool's dissolve of the cut face, or Undo split) takes back BOTH halves, even the one a
//      union took; the union keeps its other parts (RED CONTROL: the old rule leaves that half behind, still cut).
//   2. A tap where no piece lies is on the bare face, never the piece across the cut (RED CONTROL: the old fallback).
//   3. A project saved in between is repaired by one tap in Edit faces, as one undo step.
//   4. The open rail is a squircle, not a pill (his "the tools don't fit the expanding pill").
#if canImport(AppKit)
import XCTest
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class EditFacesHalfInAUnionTests: XCTestCase {

    /// Two 10 × 10 mm squares side by side on z = 0: face 0 on x 0…10 (the thin face he cut), face 1 on x 10…20 (the stem).
    static func mesh() -> ViewerMesh {
        ViewerMesh(vertices: [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0, 20, 0, 0, 20, 10, 0],
                   indices: [0, 1, 2, 0, 2, 3, 1, 4, 5, 1, 5, 2],
                   faceIDs: [0, 0, 1, 1],
                   faceGeometry: (0..<2).map { _ in StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)) })
    }

    /// His state before the edit: face 0 cut at x = 5 into two halves; one half joined with face 1's region in a union.
    static func cutAndJoined() -> (m: FaceRegionModel, face: RegionID, halves: [RegionID], stem: RegionID, union: RegionID) {
        var m = FaceRegionModel()
        let face = m.union(faces: [0], named: "Face 0")
        let halves = m.splitManual(face, point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0))
        let stem = m.union(faces: [1], named: "Face 1")
        let union = m.unionOfParts([halves[0], stem], named: "The stem")!
        return (m, face, halves, stem, union)
    }

    func testTakingTheCutBackTakesBackTheHalfTheUnionTook() {
        // the Region tool's dissolve of the cut face
        var t = Self.cutAndJoined()
        _ = t.m.dissolve(t.face, includingLent: true)
        XCTAssertNil(t.m.region(t.halves[0]), "★ the half the union took goes with its face")
        XCTAssertNil(t.m.region(t.halves[1]))
        XCTAssertEqual(t.m.region(t.union)?.parts, [t.stem], "★ the union keeps its other part")
        XCTAssertEqual(t.m.orphanedCutPieces, [])
        // Undo split
        var u = Self.cutAndJoined()
        XCTAssertTrue(SurfaceRegionTool.canUndoSplit(u.face, regions: u.m))
        XCTAssertEqual(Set(SurfaceRegionTool.splitChildren(u.face, regions: u.m)), Set(u.halves), "both halves are the split's")
        u.m.revertSplit(u.face, includingLent: true)
        XCTAssertNotNil(u.m.region(u.face), "the face stays, whole")
        XCTAssertNil(u.m.region(u.halves[0]), "★ Undo split takes back the half the union took")
        XCTAssertEqual(u.m.region(u.union)?.parts, [u.stem])
        // RED CONTROL: the old rule (Flexible's scratch copy keeps it) leaves that half behind, still cut — his state
        var c = Self.cutAndJoined()
        _ = c.m.dissolve(c.face)
        XCTAssertNotNil(c.m.region(c.halves[0]), "RED CONTROL: the old dissolve leaves the union's half")
        XCTAssertEqual(c.m.orphanedCutPieces, [c.halves[0]], "…an orphaned cut piece")
    }

    func testATapWhereNoPieceLiesIsOnTheBareFace() {
        var c = Self.cutAndJoined()
        _ = c.m.dissolve(c.face)   // his state
        let mesh = Self.mesh()
        let sides = [SIMD3<Double>(2, 5, 0), SIMD3<Double>(8, 5, 0)]
        let hits = sides.map { SurfaceTint.regionAt(point: $0, face: 0, mesh: mesh, regions: c.m) }
        XCTAssertEqual(hits.compactMap { $0 }, [c.halves[0]], "the piece answers on its own side only")
        XCTAssertEqual(hits.filter { $0 == nil }.count, 1, "★ the other side is the bare face")
        let bare = sides[hits.firstIndex(where: { $0 == nil })!]
        XCTAssertEqual(EditedFaces.leaf(face: 0, point: bare, mesh: mesh, regions: c.m, fallback: c.halves[0]), .face(0),
                       "★ a tap there selects the face, not the union across the cut")
        SurfaceTint.controlCutPieceFallback = true
        defer { SurfaceTint.controlCutPieceFallback = false }
        XCTAssertEqual(SurfaceTint.regionAt(point: bare, face: 0, mesh: mesh, regions: c.m), c.halves[0],
                       "RED CONTROL: the old fallback picks the piece across the cut (and so the union: his 'T')")
    }

    func testHisSavedStateIsRepairedInOneUndoableStep() throws {
        let p = ProjectModel(id: UUID(), name: "T", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = Self.mesh()
        var c = Self.cutAndJoined()
        _ = c.m.dissolve(c.face)   // his state, saved before the fix
        p.faceRegions = c.m
        p.selection.addGroup()
        let g = try XCTUnwrap(p.selection.groups.last?.id)
        p.selection.setRegions([c.union], for: g)
        XCTAssertEqual(p.surfaceOrphanedCutPieces, [c.halves[0]])
        let dropped = p.surfaceRepairOrphanedCutPieces()
        XCTAssertEqual(dropped, [c.halves[0]], "★ the orphaned half goes")
        XCTAssertEqual(p.faceRegions.region(c.union)?.parts, [c.stem], "the union keeps the stem")
        XCTAssertEqual(p.surfaceOrphanedCutPieces, [])
        XCTAssertEqual(SurfaceTint.regionAt(point: SIMD3(5.5, 5, 0), face: 0, mesh: Self.mesh(), regions: p.faceRegions), nil,
                       "the face is whole again: no piece on it")
        p.performUndo()
        XCTAssertEqual(p.surfaceOrphanedCutPieces, [c.halves[0]], "★ one Undo takes the repair back")
    }

    /// On the page: Edit faces says it in one line beside the rail, and one tap makes the face whole again. The open rail is a
    /// squircle.
    func testEditFacesOffersTheRepairInOneTap() throws {
        let (h, p, _) = try ParityTopologyShots.pad(AppBuildHost.landscape13, test: self)
        try h.tap("capsuleScissors", "Topology's ✂")
        h.pump(1)
        XCTAssertNil(h.frames.all["cutOrphanRepair"], "nothing to repair: no line")
        let mesh = try XCTUnwrap(p.viewerMesh)
        let faces = Array(Set(mesh.faceIDs.map { FaceID($0) })).sorted()
        XCTAssertGreaterThanOrEqual(faces.count, 2)
        // a real face of the pad, cut through its centre; one half joined with another face; the cut face dissolved the old way
        var m = p.faceRegions
        let f0 = faces[0]
        var centre = SIMD3<Double>.zero, n = 0.0
        for t in 0..<mesh.triangleCount where FaceID(mesh.faceIDs[t]) == f0 {
            for k in 0..<3 {
                let i = Int(mesh.indices[3 * t + k])
                centre += SIMD3(Double(mesh.positions[3 * i]), Double(mesh.positions[3 * i + 1]), Double(mesh.positions[3 * i + 2]))
                n += 1
            }
        }
        centre /= max(n, 1)
        let face = m.union(faces: [f0], named: "cut face")
        let halves = m.splitManual(face, point: centre, normal: SIMD3(1, 0, 0))
        let other = m.union(faces: [faces[1]], named: "other face")
        let union = try XCTUnwrap(m.unionOfParts([halves[0], other], named: "joined"))
        _ = m.dissolve(face)
        p.faceRegions = m
        h.pump(1)
        let card = try h.onScreen("cutOrphanRepair", "★ the line beside the rail")
        let rail = try h.onScreen("cutRail", "the rail")
        XCTAssertLessThanOrEqual(card.maxX, rail.minX, "beside the rail, not over it")
        try h.tap("cutOrphanRepairButton", "★ Make it whole", settle: 1)
        XCTAssertEqual(p.surfaceOrphanedCutPieces, [], "★ one tap repairs it")
        XCTAssertEqual(p.faceRegions.region(union)?.parts, [other])
        XCTAssertNil(h.frames.all["cutOrphanRepair"], "the line goes with it")

        // ★ the open rail: a squircle, its corner well under half its width (a pill's is half)
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/TopOptFlows/WorkspacePlaceholder.swift").standardizedFileURL, encoding: .utf8)
        XCTAssertTrue(ws.contains("RoundedRectangle(cornerRadius: cutRailOpen ? CutRailInfo.openCorner : 28, style: .continuous)"),
                      "the rail's shape follows open / closed")
        XCTAssertLessThan(CutRailInfo.openCorner * 2, CutRailInfo.nameWidth, "★ open, a squircle: the corner is no pill end")
    }
}
#endif
