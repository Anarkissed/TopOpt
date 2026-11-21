// PieceKeepClearTests.swift — E4 (j), ruling 2026-11-07 19:55 (ledger row 38: a cut piece "works everywhere a CAD face
// works … Keep clear"): a Keep clear on a CUT piece goes to core by the piece's region, and core clears in front of that
// piece only (its member faces' own Keep clear, clipped by its cuts). Before E4 the app sent nothing for a piece (a face
// id would have cleared the whole CAD face), so a Keep clear on a piece did nothing at all.
//   • a flat piece with Keep clear on → a face Keep clear by its region, on the LAN job too, and core's own parser takes it;
//   • a piece of a hole in an anchor group → a bolt Keep clear by its region (the auto rule, as for a whole hole);
//   • a piece that is neither a hole nor flat → nothing (core would refuse it; a whole face of that kind clears nothing);
//   • the results line names "a cut piece" in plain words, never a number, and a reopened run keeps it.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PieceKeepClearTests: XCTestCase {

    /// The Topology piece tap's move (EditFacesStageTests): the piece out of every group, into a new one.
    private func movePiece(_ piece: RegionID, _ p: ProjectModel) -> UUID {
        let g = p.selection.addGroup()
        for grp in p.selection.groups { p.surfaceDetachPiece(piece, from: grp.id) }
        p.selection.removeRegions([piece])
        for grp in p.selection.groups { p.selection.removeFaces(p.surfaceResolvedFaces(piece), from: grp.id) }
        p.selection.addRegions([piece], to: g)
        return g
    }

    /// The LAN job, as `AppModel.makeRunRequest` sends the Keep clears and the region layer.
    private func job(_ p: ProjectModel) throws -> [String: Any] {
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
            projectName: "piece", anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [1], force: SIMD3(0, 0, -50))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            clearances: p.clearanceSpecs(),
            faceRegions: FaceRegionSend.kept(p.faceRegions.regions))
        let data = try RemoteRun.buildJobJSON(request)
        XCTAssertNil(TopOptKit.jobSchemaError(data), "★ core's own parser takes the job: \(TopOptKit.jobSchemaError(data) ?? "")")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func clearances(_ j: [String: Any]) -> [[String: Any]] {
        ((j["loads"] as? [String: Any])?["clearances"] as? [[String: Any]]) ?? []
    }

    /// ★ A flat piece with Keep clear on goes as a FACE Keep clear by its region — never as its CAD face.
    func testAFlatPieceKeepsClearByItsRegion() throws {
        let p = EditFacesStageTests.twoFaceProject()
        let half = try XCTUnwrap(p.commitSurfaceCut(EditFacesStageTests.topCut(p)).last, "the cut leaves two pieces")
        let g = movePiece(half, p)
        p.force.setKeepClearAffix(g, .on)

        let j = try job(p)
        let mine = clearances(j).filter { ($0["region_id"] as? Int) == half }
        XCTAssertEqual(mine.count, 1, "★ the piece's Keep clear is on the job, by its region: \(clearances(j))")
        XCTAssertEqual(mine.first?["kind"] as? String, "face", "★ a flat piece keeps clear as a face")
        XCTAssertNil(mine.first?["face_id"], "★ a region, never a face id as well (core takes exactly one)")
        XCTAssertFalse(clearances(j).contains { ($0["face_id"] as? Int) == 1 }, "never the whole CAD face 1")
        let regions = ((j["loads"] as? [String: Any])?["face_regions"] as? [[String: Any]]) ?? []
        XCTAssertTrue(regions.contains { ($0["id"] as? Int) == half }, "the piece is declared in face_regions")
        XCTAssertEqual(p.clearanceSpecs().filter { $0.regionID == half }.map(\.faceID), [-1])
    }

    /// ★ Keep clear off: the piece sends nothing (control — the rule reads the group's switch).
    func testAPieceWithKeepClearOffSendsNothing() throws {
        let p = EditFacesStageTests.twoFaceProject()
        let half = try XCTUnwrap(p.commitSurfaceCut(EditFacesStageTests.topCut(p)).last)
        _ = movePiece(half, p)
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "no Keep clear, no clearance")
    }

    /// ★ A piece of a HOLE in an anchor group keeps clear by itself, as a bolt — the auto rule a whole hole gets.
    func testAPieceOfAnAnchoredHoleKeepsClearAsABolt() throws {
        let p = try FlexiblePressFixtures.lBracketProject("PieceKeepClearTests")
        let mesh = try XCTUnwrap(p.viewerMesh)
        let bore = try XCTUnwrap(FaceTopology.faceIDs(in: mesh).first { FaceTopology.isFastenerBore($0, in: mesh) },
                                 "premise: his l bracket has a bolt hole")
        let geo = try XCTUnwrap(mesh.faceGeometry(bore))
        // a ring cut across the hole, half way down it: two short holes
        let axis = simd_normalize(SIMD3<Double>(geo.axisDir))
        let span = try XCTUnwrap(mesh.faceAxialSpan(bore, axisPoint: SIMD3<Float>(geo.axisPoint), axisDir: SIMD3<Float>(axis)))
        let mid = SIMD3<Double>(geo.axisPoint) + axis * Double(span.lo + span.hi) / 2
        let pieces = p.commitSurfaceCut(SurfaceCut(point: mid, normal: axis, faceID: bore, faceNormal: axis))
        XCTAssertGreaterThanOrEqual(pieces.count, 2, "premise: the cut halves the hole")
        let half = try XCTUnwrap(pieces.first)
        let g = movePiece(half, p)
        p.force.makeAnchor(g)

        XCTAssertTrue(p.keepClearIsOn(try XCTUnwrap(p.selection.groups.first { $0.id == g })),
                      "★ an anchored hole's piece is kept clear by default, as the whole hole is")
        let mine = p.clearanceSpecs().filter { $0.regionID == half }
        XCTAssertEqual(mine.map(\.kind), [.bolt], "★ a piece of a hole keeps clear as a bolt, by its region")
        XCTAssertEqual(mine.map(\.faceID), [-1])
        XCTAssertFalse(p.clearanceSpecs().contains { $0.faceID == Int(p.runFaceID(bore)) && $0.regionID < 0 },
                       "never the whole hole")
        let j = try job(p)
        XCTAssertEqual(clearances(j).filter { ($0["region_id"] as? Int) == half }.map { $0["kind"] as? String }, ["bolt"])

        p.force.setKeepClearAffix(g, .suppressed)
        XCTAssertTrue(p.clearanceSpecs().filter { $0.regionID == half }.isEmpty, "control: Keep clear off → nothing")
    }

    /// ★ A piece of a face that is neither a hole nor flat is not sent: core refuses a piece that gives nothing to clear.
    /// His l bracket has none (every round face is a bolt hole), so a rounded OUTER edge: a convex arc of a fitted
    /// cylinder (r 5 mm, 135° of wrap, 10 mm tall) — curved, not flat, and not a hole (ClearanceDerivationTests' gate).
    static func roundedEdgeProject() -> ProjectModel {
        let n = 16, segments = 6, r: Float = 5
        var verts: [Float] = []
        for k in 0...segments { let a = Float(k) * (2 * .pi / Float(n)); verts += [r * cos(a), r * sin(a), 0] }
        for k in 0...segments { let a = Float(k) * (2 * .pi / Float(n)); verts += [r * cos(a), r * sin(a), 10] }
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k) }
        func T(_ k: Int) -> Int32 { Int32(segments + 1 + k) }
        for k in 0..<segments {
            indices += [B(k), B(k + 1), T(k + 1), B(k), T(k + 1), T(k)]   // outward: convex
            faceIDs += [0, 0]
        }
        let edge = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: Double(r),
                                    axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let p = ProjectModel(id: UUID(), name: "RoundedEdge", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: [edge])
        p.selection.addGroup()
        p.selection.pickFaces([0])
        return p
    }

    func testAPieceThatIsNeitherAHoleNorFlatIsNotSent() throws {
        let p = Self.roundedEdgeProject()
        let mesh = try XCTUnwrap(p.viewerMesh)
        XCTAssertFalse(FaceTopology.isFastenerBore(0, in: mesh), "premise: not a hole")
        XCTAssertFalse(mesh.faceGeometry(0)?.isPlane ?? true, "premise: not flat")
        let cut = try XCTUnwrap(SurfaceCut.centred(onFace: 0, in: mesh), "a cut through the edge's centre")
        let half = try XCTUnwrap(p.commitSurfaceCut(cut).first, "premise: the cut makes pieces")
        let g = movePiece(half, p)
        p.force.setKeepClearAffix(g, .on)
        let group = try XCTUnwrap(p.selection.groups.first { $0.id == g })
        XCTAssertEqual(p.keepClearPieces(group).map(\.region), [half],
                       "control: the piece IS one of the group's Keep clear pieces, so the rule below is the kind rule")
        XCTAssertTrue(p.clearanceSpecs().filter { $0.regionID == half }.isEmpty,
                      "★ nothing for core to clear on it, so nothing is sent (core would refuse the run)")
    }

    /// ★ The results line names a piece in plain words, never a number; a face's line is unchanged.
    func testThePiecesResultsLineSaysACutPiece() {
        let notes = ResultsModel.clearanceNotes([
            AppliedClearance(faceID: -1, kind: .bolt, voxelsFrozen: 54, inGrid: true, regionID: 7),
            AppliedClearance(faceID: 3, kind: .face, voxelsFrozen: 0, inGrid: true),
        ])
        // ★ RE-PINNED (B10 §3 words, UI-Notes 8560bcb6): "Keep clear (bolt)" / "Keep clear (face)"; the piece is still plain words
        XCTAssertEqual(notes[0], "Keep clear (bolt) on a cut piece: kept clear (54 voxels reserved as empty).")
        XCTAssertFalse(notes[0].contains("-1") || notes[0].contains(" 7"), "never the piece's number")
        XCTAssertEqual(notes[1], "Keep clear (face) on face 3: applied, but forbade no new material here.")
    }

    /// ★ A reopened run keeps the piece's row (and an older saved run, with no region, reads as a face).
    func testAReopenedRunKeepsThePiece() throws {
        let o = OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0,
                                voxelVolumeMM3: 1, gridNx: 1, gridNy: 1, gridNz: 1, gridOrigin: .zero, spacing: 1,
                                appliedClearances: [AppliedClearance(faceID: -1, kind: .face, voxelsFrozen: 9,
                                                                     inGrid: true, regionID: 12),
                                                    AppliedClearance(faceID: 4, kind: .bolt, voxelsFrozen: 2, inGrid: true)])
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(back.appliedClearances.map(\.regionID), [12, -1])
        XCTAssertEqual(back.appliedClearances.map(\.faceID), [-1, 4])
    }
}
