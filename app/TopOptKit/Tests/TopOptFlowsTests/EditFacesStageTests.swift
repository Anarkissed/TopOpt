// EditFacesStageTests.swift — B5 (his picks 2026-10-24, S3 amended): Surface is no longer a stage; Edit faces is a mode
// reached from every stage. These tests use only APIs that existed at 564db991, so on that tree they fail on their
// assertions (the red-first record is in the B5 commit message).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class EditFacesStageTests: XCTestCase {

    // MARK: fixture — two square faces (0 at z = 0, 1 at z = 10), one group holding both

    static func twoFaceMesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        return ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7], faceIDs: [0, 0, 1, 1],
                          faceGeometry: [StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                                         StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))])
    }

    static func twoFaceProject() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "EditFaces", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = twoFaceMesh()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1])
        return p
    }

    static func topCut(_ p: ProjectModel) -> SurfaceCut {
        SurfaceCut.at(rayOrigin: SIMD3(5, 5, 50), rayDir: SIMD3(0, 0, -1), mesh: p.viewerMesh!)!
    }

    // MARK: (f) Surface is not a stage

    func testSurfaceIsNoLongerAStage() {
        XCTAssertEqual(WorkspaceStage.allCases, [.topology, .lattice], "two stages; Edit faces is a mode")
        XCTAssertNil(WorkspaceStage(rawValue: "surface"), "no Surface stage to land on")
        XCTAssertEqual(WorkspaceStage.topology.forward, [.lattice])
        XCTAssertEqual(WorkspaceStage.lattice.forward, [])
        XCTAssertNil(TopologyStageMenu.stage(for: .editFaces), "Edit faces is not a stage change")
    }

    /// The lifted capsule's default menu (Flexible's) offers "Edit faces…", never "Surface ›", and it acts through
    /// the same closure as the ✂.
    func testTheCapsuleMenuOffersEditFacesNotSurface() {
        let items = StageCapsule.menuItems(title: "Flexible", idPrefix: "flexible", anchors: 1, loads: 1)
        XCTAssertFalse(items.map(\.title).contains("Surface \u{203A}"))
        let row = items.first { $0.title == "Edit faces\u{2026}" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.action, .editFaces)
        var opened = 0
        StageCapsule.perform(.editFaces, fold: nil, go: { _ in XCTFail("not a stage change") }, about: {},
                             editFaces: { opened += 1 })
        XCTAssertEqual(opened, 1)
    }

    // MARK: (e) the undo-merge — every face edit is its own step

    /// A cut sealed before AND after: an edit made right after it (inside the 400 ms settle) is a step of its own, so
    /// one Undo takes back only that edit and a second Undo puts the face back.
    func testEveryFaceEditIsItsOwnUndoStep() {
        let p = Self.twoFaceProject()
        let kids = p.commitSurfaceCut(Self.topCut(p))
        XCTAssertEqual(kids.count, 2)
        let afterCut = p.faceRegions
        _ = p.selection.addGroup()               // the next edit, before the debounce settles
        XCTAssertEqual(p.selection.groups.count, 2)

        p.performUndo()
        XCTAssertEqual(p.selection.groups.count, 1, "the first Undo takes back the group")
        XCTAssertEqual(p.faceRegions, afterCut, "…and leaves the cut")
        p.performUndo()
        XCTAssertTrue(p.faceRegions.isEmpty, "the second Undo puts the face back")
    }

    // MARK: (i) a painted region reaches the Mac worker

    /// The worker upload carries the face-overrides sidecar (`<model>.faces`) when there is one: without it the worker's
    /// re-import has no painted face ids and a painted group reaches no face.
    func testThePaintedFacesSidecarRidesTheWorkerUpload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b5-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("part.stl")
        try Data("solid".utf8).write(to: model)
        let sidecar = Data([1, 2, 3, 4])
        try sidecar.write(to: URL(fileURLWithPath: model.path + ".faces"))

        let parts = RemoteRun.uploadParts(modelPath: model.path, model: Data("solid".utf8), jobJSON: Data("{}".utf8),
                                          projectName: "P")
        XCTAssertEqual(parts.map(\.name), ["step", "job", "project", "faces"])
        let faces = try XCTUnwrap(parts.first { $0.name == "faces" })
        XCTAssertEqual(faces.filename, "part.stl.faces", "saved beside the model, under the model's own name")
        XCTAssertEqual(faces.data, sidecar)

        // No sidecar ⇒ today's three parts, byte for byte.
        try FileManager.default.removeItem(atPath: model.path + ".faces")
        XCTAssertEqual(RemoteRun.uploadParts(modelPath: model.path, model: Data(), jobJSON: Data(), projectName: "P")
                        .map(\.name), ["step", "job", "project"])
    }

    // MARK: (j) a clearance on an edited piece — checked, pinned

    /// A painted piece in a Keep-clear group sends ITS run face id (the painted face core reads from `.faces`), never
    /// the CAD face under it.
    func testAClearanceOnAPaintedPieceSendsThePaintedFace() {
        let p = Self.twoFaceProject()
        p.paint = PaintModel(baseFaceCount: 2)
        let g = p.selection.addGroup()
        p.selection.setActive(g)
        p.paintStroke(.add, triangles: [2])              // face 1's first triangle
        let painted = p.selection.groups.first { $0.id == g }?.faces ?? []
        XCTAssertEqual(painted, [2], "one painted face, id 2 (≥ the base count)")
        p.force.setKeepClearAffix(g, .on)
        let ids = p.clearanceSpecs().map(\.faceID)
        XCTAssertTrue(ids.contains(Int(p.runFaceID(2))), "the painted piece's own face id")
    }

    /// A cut half moved into a Keep-clear group is never sent as the ORIGINAL CAD face (that would keep the whole face
    /// clear). Core's clearance takes a face_id only (job.cpp:722-735, no region_id), so the half's own clearance needs a
    /// core change — written in the handoff, not worked around here.
    func testAClearanceOnACutPieceIsNeverTheOriginalFace() throws {
        let p = Self.twoFaceProject()
        let kids = p.commitSurfaceCut(Self.topCut(p))
        let half = try XCTUnwrap(kids.last)
        let g = p.selection.addGroup()
        // the Topology piece tap's move (handleTopologyPiecePick): detach, drop everywhere, add to the new group
        for grp in p.selection.groups { p.surfaceDetachPiece(half, from: grp.id) }
        p.selection.removeRegions([half])
        for grp in p.selection.groups { p.selection.removeFaces(p.surfaceResolvedFaces(half), from: grp.id) }
        p.selection.addRegions([half], to: g)
        p.force.setKeepClearAffix(g, .on)
        XCTAssertFalse(p.clearanceSpecs().contains { $0.faceID == 1 }, "never the whole CAD face 1")
    }
}
