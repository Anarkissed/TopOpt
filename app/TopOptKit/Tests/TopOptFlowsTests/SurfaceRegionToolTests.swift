import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ THE REGION TOOL (the Regions task, approved 2026-10-08: "A new 'Region' tray tool"). Its rules
/// (`SurfaceRegionTool`), its two commits, and its place in the stage.
@MainActor
final class SurfaceRegionToolTests: XCTestCase {

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
        let p = ProjectModel(id: UUID(), name: "T", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    /// Faces are added to and dropped from a WHOLE face region only — and never its last face.
    func testTheTapAddsAndDropsOnAWholeRegionOnly() throws {
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        XCTAssertEqual(SurfaceRegionTool.tapEdit(aim: r, face: 1, regions: p.faceRegions, mesh: mesh), .add(1))
        XCTAssertNil(p.surfaceRegionToggleFace(r, face: 1))
        XCTAssertEqual(p.surfaceResolvedFaces(r), [0, 1], "★ added")
        XCTAssertNil(p.surfaceRegionToggleFace(r, face: 0))
        XCTAssertEqual(p.surfaceResolvedFaces(r), [1], "★ dropped")
        XCTAssertNotNil(p.surfaceRegionToggleFace(r, face: 1), "★ never its last face")
        XCTAssertEqual(p.surfaceResolvedFaces(r), [1])
        // a union, a cut piece and a split parent each say why
        let halves = p.faceRegions.splitManual(r, point: SIMD3(5, 5, 5), normal: SIMD3(1, 0, 0))
        XCTAssertNotNil(SurfaceRegionTool.editRefusal(r, regions: p.faceRegions), "a split parent")
        XCTAssertNotNil(SurfaceRegionTool.editRefusal(halves[0], regions: p.faceRegions), "a cut piece")
        let r2 = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var su = SurfaceUnion(); su.toggle(halves[1]); su.toggle(r2)
        let u = try XCTUnwrap(p.commitSurfaceUnion(su))
        XCTAssertNotNil(SurfaceRegionTool.editRefusal(u, regions: p.faceRegions), "a union")
        XCTAssertEqual(p.surfaceRegionToggleFace(u, face: 0), SurfaceRegionTool.editRefusal(u, regions: p.faceRegions),
                       "★ the refusal is the rule's own words")
    }

    /// ↖ steps from a piece to what it was cut from; Undo split takes back the pieces and no id
    /// dangles; a union's parts are not a split of it.
    func testUpUndoSplitAndTheUnionsParts() throws {
        let p = project()
        let r = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let halves = p.faceRegions.splitManual(r, point: SIMD3(5, 5, 5), normal: SIMD3(1, 0, 0))
        XCTAssertEqual(SurfaceRegionTool.parent(of: halves[0], regions: p.faceRegions), r)
        XCTAssertNil(SurfaceRegionTool.parent(of: r, regions: p.faceRegions), "a root has no up")
        XCTAssertTrue(SurfaceRegionTool.canUndoSplit(r, regions: p.faceRegions))
        let other = p.selection.addGroup()
        p.selection.addRegions([halves[1]], to: other)
        let dropped = p.surfaceUndoSplit(r)
        XCTAssertEqual(Set(dropped), Set(halves))
        for g in p.selection.groups { XCTAssertTrue(Set(g.regionIDs).isDisjoint(with: dropped), "★ nothing dangles") }
        XCTAssertFalse(SurfaceRegionTool.canUndoSplit(r, regions: p.faceRegions))
        // a union's parts hang off it and are not a split of it
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var su = SurfaceUnion(); su.toggle(a); su.toggle(b)
        let u = try XCTUnwrap(p.commitSurfaceUnion(su))
        XCTAssertFalse(SurfaceRegionTool.canUndoSplit(u, regions: p.faceRegions), "★ parts are not a split")
        XCTAssertNil(SurfaceRegionTool.parent(of: a, regions: p.faceRegions), "★ a part steps up by being tapped")
        XCTAssertEqual(SurfaceRegionTool.label(u, regions: p.faceRegions, resolvedFaces: 2), "Union of 2 · 2 faces")
    }

    /// The stage: the tool is last in the tray, a tap never makes a region, and each verb shows only
    /// where it applies (pinned on the view's source: these are private members).
    func testTheStageWiring() throws {
        XCTAssertEqual(SurfaceTool.allCases.last, .region)
        XCTAssertTrue(SurfaceTool.region.edits)
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        let engage = try XCTUnwrap(ws.range(of: "        case .region:\n            // ★★ THE REGION TOOL (2026-10-08)"))
        let body = String(ws[engage.lowerBound...].prefix(1400))
        XCTAssertFalse(body.contains("surfaceEnsureRegion"), "★ aiming never makes a region")
        XCTAssertTrue(body.contains("project.surfaceRegionToggleFace(aim, face: faceID)"))
        XCTAssertTrue(ws.contains("if SurfaceRegionTool.canUndoSplit(aim, regions: regions) {"), "Undo split only where it applies")
        XCTAssertTrue(ws.contains("if SurfaceDissolve.refusal(aim, regions: regions) == nil {"), "Dissolve only where it applies")
        XCTAssertTrue(ws.contains("surfaceRegionAim = nil\n        similar.clear()"), "a tool switch releases the aim")
    }
}
