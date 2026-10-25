// EditFacesModeTests.swift — B5: Edit faces as a MODE (the flag, where Done returns, Paint, the post-edit hook) and the
// EDITED FACES every stage selects (one per edited face, with lineage, ids kept). These name APIs B5 adds, so on 564db991
// they do not compile (the red-first record is in the B5 commit message).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class EditFacesModeTests: XCTestCase {

    // MARK: (b)(g) the mode flag and the way back

    func testDoneReturnsToThePageItCameFrom() {
        let origins: [EditFacesOrigin] = [
            .topology(.setup), .topology(.results), .topology(.smooth, smoothVariant: 2),
            .lattice(.regions), .lattice(.cells), .host("flexible.squish"),
        ]
        for o in origins {
            var s = EditFacesSession()
            XCTAssertFalse(s.isEditing)
            XCTAssertTrue(s.enter(from: o))
            XCTAssertTrue(s.isEditing)
            XCTAssertFalse(s.enter(from: .topology(.setup)), "already editing: the first way in is kept")
            XCTAssertEqual(s.done(), o, "Done goes back where it came from")
            XCTAssertFalse(s.isEditing)
            XCTAssertNil(s.done(), "a second Done goes nowhere")
        }
        XCTAssertEqual(EditFacesOrigin.lattice(.cells).stage, .lattice)
        XCTAssertEqual(EditFacesOrigin.topology(.results).stage, .topology)
        XCTAssertNil(EditFacesOrigin.host("flexible.lattice").stage, "a host page's owner puts itself back")
    }

    /// The mode draws what the Surface stage drew, on top of whichever stage it was opened from.
    func testEditingFacesIsAModeOverEveryStage() {
        for stage in WorkspaceStage.allCases {
            let v = WorkspaceStageVisibility.of(stage, editingFaces: true)
            XCTAssertEqual(v, .editingFaces)
            XCTAssertTrue(v.surfaceEditing)
            XCTAssertFalse(v.groupPrimitives || v.designBox || v.keepOuts || v.latticeControls || v.latticeDepthPlanes)
            XCTAssertEqual(WorkspaceStageVisibility.of(stage, editingFaces: false), .of(stage))
            XCTAssertFalse(WorkspaceStageVisibility.of(stage).surfaceEditing, "no stage edits faces by itself")
        }
    }

    /// Paint is an Edit faces tool on an STL (mesh) part only; on STEP it is greyed with one line why.
    func testPaintIsAnEditFacesToolOnAnSTLOnly() {
        XCTAssertEqual(EditFacesPaint.row(modelPath: "/p/part.stl", editingFaces: true), .enabled(EditFacesCopy.paintSTL))
        XCTAssertEqual(EditFacesPaint.row(modelPath: "/p/part.STEP", editingFaces: true), .greyed(EditFacesCopy.paintSTEP))
        XCTAssertEqual(EditFacesPaint.row(modelPath: "/p/part.stp", editingFaces: true), .greyed(EditFacesCopy.paintSTEP))
        XCTAssertEqual(EditFacesPaint.row(modelPath: "/p/part.stl", editingFaces: false), .hidden, "not outside Edit faces")
        XCTAssertEqual(EditFacesPaint.row(modelPath: nil, editingFaces: true), .hidden)
    }

    // MARK: (c) the post-edit hook, inside the edit's undo step

    func testAFaceEditRunsItsHookInsideItsOwnUndoStep() throws {
        let p = EditFacesStageTests.twoFaceProject()
        let gid = p.selection.groups[0].id
        var seen: [FaceEditEvent] = []
        p.onFaceEdit("test") { ev in
            seen.append(ev)
            p.selection.rename(gid, to: "Reacted")       // a stage reacting, inside the same step
        }
        let kids = p.commitSurfaceCut(EditFacesStageTests.topCut(p))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.kind, .cut)
        XCTAssertEqual(Set(seen.first?.made ?? []).isSuperset(of: kids), true, "the event names the pieces it made")
        XCTAssertEqual(p.selection.groups[0].name, "Reacted")

        p.performUndo()
        XCTAssertTrue(p.faceRegions.isEmpty, "one Undo takes back the cut…")
        XCTAssertNotEqual(p.selection.groups[0].name, "Reacted", "…and the hook's reaction with it")
        p.performRedo()
        XCTAssertFalse(p.faceRegions.isEmpty)
        XCTAssertEqual(p.selection.groups[0].name, "Reacted", "and Redo brings both back")

        p.removeFaceEditHook("test")
        _ = p.commitSurfaceCut(EditFacesStageTests.topCut(p))
        XCTAssertEqual(seen.count, 1, "a removed hook no longer runs")
    }

    // MARK: (a)(d) edited faces: ids kept, one outline each, lineage

    /// Face 1 as saved by his_0004's kind of project: region 102 ("Face 1") cut into 103 / 104 — the ids Flexible's
    /// 1M + rid keys (1000103 / 1000104) name. They decode and stay those ids; a new region takes the next id.
    static let savedRegions = """
    {"nextID":105,"regions":[
     {"id":102,"name":"Face 1","filterMatchedAtAuthor":-1,"add":[1],"remove":[],"cuts":[],
      "parentID":-1,"collapsed":false},
     {"id":103,"name":"Face 1 A","filterMatchedAtAuthor":-1,"add":[1],"remove":[],
      "cuts":[{"point":[5,5,10],"normal":[1,0,0],"strict":false}],"parentID":102,"collapsed":true},
     {"id":104,"name":"Face 1 B","filterMatchedAtAuthor":-1,"add":[1],"remove":[],
      "cuts":[{"point":[5,5,10],"normal":[-1,0,0],"strict":true}],"parentID":102,"collapsed":true}]}
    """

    /// Face 1 tessellated as a 2 × 2 grid (8 triangles), so each half of an x = 5 cut owns four of them.
    static func gridMesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)            // face 0: 0…3
        for j in 0...2 { for i in 0...2 { V(Float(i) * 5, Float(j) * 5, 10) } }   // face 1: 4…12
        var idx: [Int32] = [0, 1, 2, 0, 2, 3], f: [Int32] = [0, 0]
        for j in 0..<2 { for i in 0..<2 {
            let a = Int32(4 + j * 3 + i), b = a + 1, c = a + 4, d = a + 3
            idx += [a, b, c, a, c, d]; f += [1, 1]
        } }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: f,
                          faceGeometry: [StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                                         StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))])
    }

    func testSavedRegionIdsKeepResolvingAsEditedFaces() throws {
        let regions = try JSONDecoder().decode(FaceRegionModel.self, from: Data(Self.savedRegions.utf8))
        XCTAssertEqual(regions.regions.map(\.id), [102, 103, 104])
        let mesh = Self.gridMesh()

        let leaves = EditedFaces.leaves(mesh: mesh, regions: regions, paint: nil)
        XCTAssertEqual(leaves.map(\.id), [.face(0), .region(103), .region(104)],
                       "the cut halves replace face 1; its parent 102 is not a face any more")
        for l in leaves where l.id != .face(0) { XCTAssertEqual(l.lineage, [1], "each half came from CAD face 1") }
        // Flexible's saved keys: 1_000_000 + rid
        let live = Set(leaves.compactMap { if case .region(let r) = $0.id { return 1_000_000 + r } else { return nil } })
        XCTAssertEqual(live, [1_000_103, 1_000_104])

        // one outline per edited face, each its own
        let outlines = leaves.map { EditedFaces.outline($0.id, mesh: mesh, regions: regions, paint: nil) }
        XCTAssertEqual(outlines.count, 3)
        XCTAssertTrue(outlines.allSatisfy { !$0.isEmpty })
        XCTAssertNotEqual(outlines[1], outlines[2], "the two halves have different outlines")
        // a half's outline is 4 squares' rim: 6 boundary segments of the 2 × 1 block of cells
        XCTAssertEqual(outlines[1].count / 6, 6)

        // a new edit never renumbers what was saved
        var edited = regions
        let kids = edited.splitManual(103, point: SIMD3(2.5, 5, 10), normal: SIMD3(0, 1, 0))
        XCTAssertTrue(kids.allSatisfy { $0 >= 105 })
        XCTAssertNotNil(edited.region(103)); XCTAssertNotNil(edited.region(104))
    }

    /// Selecting a face selects the EDITED face under the finger — the cut half, the painted area — never the
    /// original underneath. One resolver, used by the tap on every stage.
    func testATapSelectsTheEditedFaceNotTheOriginal() throws {
        let regions = try JSONDecoder().decode(FaceRegionModel.self, from: Data(Self.savedRegions.utf8))
        let mesh = Self.gridMesh()
        XCTAssertEqual(EditedFaces.leaf(face: 1, point: SIMD3(7, 5, 10), mesh: mesh, regions: regions), .region(103))
        XCTAssertEqual(EditedFaces.leaf(face: 1, point: SIMD3(2, 5, 10), mesh: mesh, regions: regions), .region(104))
        XCTAssertEqual(EditedFaces.leaf(face: 0, point: SIMD3(2, 5, 0), mesh: mesh, regions: regions), .face(0))

        // a painted area is its own face, with its lineage
        var paint = PaintModel(baseFaceCount: 2)
        let painted = paint.mintFace()
        paint.apply(.add, target: painted, triangles: [2, 3])
        let leaves = EditedFaces.leaves(mesh: mesh, regions: FaceRegionModel(), paint: paint)
        let p = try XCTUnwrap(leaves.first { $0.id == .face(painted) })
        XCTAssertTrue(p.isPainted)
        XCTAssertEqual(p.lineage, [1], "painted over face 1")
        XCTAssertTrue(leaves.contains { $0.id == .face(1) }, "the rest of face 1 is still face 1")
    }
}
