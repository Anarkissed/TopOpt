// FlexibleSettingsMigrationTests — a project saved before round 3 still opens, and reads the
// new way (task 2026-09-29-flexible-screens, round 3; items 1.2, 1.3, 2.1, 5, 6b).
//   * the new fields (weightFrom, shape, curveConvention) are OPTIONAL: his saved project
//     decodes; a non-optional twin of the same field cannot (RED control);
//   * beads 2 → 1, either / centre_edge → both (curves kept), rotation 90 → 0;
//   * a DRAWN curve keeps its picture (stored y flips once); the default dome is kept;
//   * the model reads THROUGH the migration (the raw file still says 2 beads: RED control),
//     and core's parser reads the job with 1 bead and no frame rotation.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSettingsMigrationTests: XCTestCase {

    /// HIS saved Flexible block (project 0004, before round 3).
    static func hisSavedJSON() throws -> Data {
        let url = FlexibleHisProject.repoRoot
            .appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004/project.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let lattice = obj["lattice"] as! [String: Any]
        return try JSONSerialization.data(withJSONObject: lattice["flexible"]!)
    }

    func testHisSavedSettingsDecodeWithTheNewOptionalFields() throws {
        let s = try JSONDecoder().decode(FlexibleStageSettings.self, from: Self.hisSavedJSON())
        XCTAssertEqual(s.faces.count, 7)
        XCTAssertNil(s.curveConvention, "saved before round 3: no convention marker")
        XCTAssertTrue(s.faces.allSatisfy { $0.weightFrom == nil && $0.shape == nil })
        // ★ RED CONTROL: the same field made NON-optional cannot read his file
        struct StrictFace: Decodable { let faceRegionID: Int; let weightFrom: UUID }
        struct Strict: Decodable { let faces: [StrictFace] }
        XCTAssertThrowsError(try JSONDecoder().decode(Strict.self, from: Self.hisSavedJSON()),
                             "control: a non-optional weightFrom must fail on his saved project")
        // a face without the new values writes no new keys (old readers see the old shape)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let face = String(decoding: try enc.encode(FlexibleFaceSettings(faceRegionID: 3)), as: UTF8.self)
        XCTAssertFalse(face.contains("weightFrom")); XCTAssertFalse(face.contains("shape"))
        // …and a new face that has them round-trips
        let g = UUID()
        let f = FlexibleFaceSettings(faceRegionID: 3, weightFrom: g, shape: "curves")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleFaceSettings.self, from: enc.encode(f)), f)
    }

    func testBeadsModeAndRotationReadTheRoundThreeWay() {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", beadsPerWall: 2)
        s.setFace(FlexibleFaceSettings(faceRegionID: 1, rotationDeg: 90, mode: "either",
                                       curveX: FlexCurve(x: [0, 1], y: [0.2, 0.9]), curveY: FlexCurve(x: [0, 1], y: [0.4, 1])))
        s.setFace(FlexibleFaceSettings(faceRegionID: 2, rotationDeg: 270, mode: "centre_edge"))
        let m = FlexibleSettingsMigration.migrated(s)
        XCTAssertEqual(s.beadsPerWall, 2, "control: the saved value is 2")
        XCTAssertEqual(m.beadsPerWall, 1)
        XCTAssertEqual(m.faces.map(\.mode), ["both", "both"])
        XCTAssertEqual(m.faces.map(\.rotationDeg), [0, 0])
        // the curves themselves are kept (convention is current, so no flip either)
        XCTAssertEqual(m.faces[0].curveX, FlexCurve(x: [0, 1], y: [0.2, 0.9]))
        XCTAssertEqual(m.faces[0].curveY, FlexCurve(x: [0, 1], y: [0.4, 1]))
        XCTAssertEqual(FlexibleSettingsMigration.migrated(m), m, "idempotent")
    }

    /// ★ HIS img-1 V (face 3's X curve: ends at the guide, middle on the face) keeps its
    /// PICTURE; the default dome is re-seeded as itself (not flipped).
    func testHisDrawnCurveKeepsItsPictureAndTheDefaultIsKept() throws {
        let s = try JSONDecoder().decode(FlexibleStageSettings.self, from: Self.hisSavedJSON())
        let m = FlexibleSettingsMigration.migrated(s)
        XCTAssertEqual(m.curveConvention, FlexibleSettingsMigration.currentCurveConvention)
        let before = try XCTUnwrap(s.face(3)), after = try XCTUnwrap(m.face(3))
        XCTAssertEqual(before.curveX.y, [0, 0, 1, 0, 0], "premise: his V as saved")
        // the picture: the old editor drew height y, the new one draws 1 − y
        let oldHeights = before.curveX.y
        let newHeights = after.curveX.y.map { FlexibleCurveEditor.displayHeight($0) }
        XCTAssertEqual(oldHeights, newHeights, "his V keeps its picture")
        XCTAssertEqual(after.curveX.x, before.curveX.x)
        XCTAssertEqual(after.curveY, FlexibleFaceSettings.defaultCurve, "the untouched default is kept, not flipped")
        XCTAssertEqual(before.curveY, FlexibleFaceSettings.defaultCurve)
        // RED CONTROL: without the flip his V would read upside down
        XCTAssertNotEqual(before.curveX.y.map { FlexibleCurveEditor.displayHeight($0) }, oldHeights)
        XCTAssertEqual(FlexibleSettingsMigration.migrated(m), m, "flipped once, never twice")
    }

    /// The model reads THROUGH the migration: designs, Auto and the job use 1 bead.
    @MainActor
    func testTheModelDesignsAndBuildsWithOneBead() throws {
        let project = ProjectModel(id: UUID(), name: "flex", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", beadsPerWall: 2)
        s.setFace(FlexibleFaceSettings(faceRegionID: 1, rotationDeg: 90))
        project.lattice.flexible = s
        let m = FlexibleStageModel(project: project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        XCTAssertEqual(project.lattice.flexible?.beadsPerWall, 2, "control: the raw saved value is 2")
        XCTAssertEqual(m.settings.beadsPerWall, 1)
        XCTAssertEqual(m.build.beadsPerWall, 1)
        XCTAssertEqual(m.loadedKeys, [FlexFaceKey(region: 1, rotation: 0)], "the stack key collapses to rotation 0")
        // core's parser reads the job the model would write: 1 bead, no frame rotation
        let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(m.settings)))
        XCTAssertEqual(b.beadsPerWall, 1)
        XCTAssertEqual(b.faces.first?.rotationDeg, 0)
        XCTAssertEqual(b.faces.first?.map.mode, "both")
    }
}
