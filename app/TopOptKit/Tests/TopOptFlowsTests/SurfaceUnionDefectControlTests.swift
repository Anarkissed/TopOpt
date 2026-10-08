import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ TWO DEFECTS FOUND READING THE REGIONS-POPOVER TASK (2026-10-08), proven here before any
/// fix — the task file's own warning: "patterning a face inside a Surface union aims at the union,
/// which owns no faces, so the cells would hold none. Run a positive control before relying on
/// 'combine, then pattern' through the Surface stage."
///
/// 1. PATTERN INSIDE A UNION. A tap on a face inside a union selects the union
///    (`outermostUnion`, WorkspacePlaceholder.swift:7109-7115); Pattern divides that piece; the
///    union owns no faces — its membership is its `parts` — and `splitGrid` copies the parent's
///    filter, add and cuts but not its parts, so every cell resolves to no face. The preview is
///    priced on the one tapped face, so the ✓ stays enabled.
/// 2. A UNION ON THE WIRE. `face_regions` carries a region's add/remove/filter/cuts — never
///    `parts` — so a union-of-parts goes out with no membership, and core refuses any declared
///    region that resolves to no faces (core/src/io/face_region.cpp:347-352).
///
/// Each is wrapped in `XCTExpectFailure(strict: true)`: green while the defect stands, RED the day
/// it is fixed (so the wrapper comes off in the fixing commit). Each has a working twin, so the
/// failure cannot come from the fixture. NOT FIXED here: the fix touches the face-region emission
/// (must-not-touch for the task) and needs a ruling on what "pattern inside a union" means.
@MainActor
final class SurfaceUnionDefectControlTests: XCTestCase {

    /// Three stacked 10 × 10 mm square faces (ids 0, 1, 2), one group holding all three — the
    /// fixture `SurfaceUnionPartsTests` uses.
    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        V(0, 0, 9); V(10, 0, 9); V(10, 10, 9); V(0, 10, 9)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3,
                                        4, 5, 6, 4, 6, 7,
                                        8, 9, 10, 8, 10, 11],
                              faceIDs: [0, 0, 1, 1, 2, 2],
                              faceGeometry: (0..<3).map { _ in
                                  StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "U", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    private func union(_ p: ProjectModel) throws -> (union: RegionID, a: RegionID, b: RegionID) {
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var u = SurfaceUnion()
        u.toggle(a); u.toggle(b)
        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))
        XCTAssertEqual(p.surfaceResolvedFaces(rid), [1, 2], "control: the union resolves to its parts' faces")
        return (rid, a, b)
    }

    /// ★ Defect 1. The twin: patterning a plain one-face region gives cells that hold its face.
    func testPatterningAFaceInsideAUnionCommitsEmptyCells() throws {
        // twin — a plain region: the split runs and every cell holds the face
        let plain = project()
        let c = try XCTUnwrap(plain.surfaceEnsureRegion(for: 0))
        let plainKids = plain.commitSurfacePattern(face: 0, columns: 2, rows: 1, piece: c)
        XCTAssertEqual(plainKids.count, 2, "control: a plain region splits into 2")
        for k in plainKids { XCTAssertEqual(plain.surfaceResolvedFaces(k), [0], "control: each cell holds face 0") }

        // the union, aimed the way the stage aims it: the tap on face 1 resolves to the union
        let p = project()
        let (u, a, _) = try union(p)
        XCTAssertEqual(p.faceRegions.outermostUnion(containing: a), u,
                       "the stage aims Pattern at the outermost union (WorkspacePlaceholder.swift:7109-7115)")
        let preview = try XCTUnwrap(p.surfacePatternPreview(face: 1, columns: 2, rows: 1, piece: u))
        XCTAssertTrue(preview.verdict.ok, "the preview, priced on the one tapped face, enables the ✓")
        let kids = p.commitSurfacePattern(face: 1, columns: 2, rows: 1, piece: u)
        XCTAssertEqual(kids.count, 2, "the split really ran on the union")
        XCTExpectFailure("DEFECT (2026-10-08): a union's cells copy its add/filter/cuts, not its parts — they hold no face",
                         strict: true) {
            for k in kids {
                XCTAssertFalse(p.surfaceResolvedFaces(k).isEmpty, "★ a pattern cell holds faces")
            }
        }
        print("UNION-PATTERN cells \(kids) resolve to \(kids.map { p.surfaceResolvedFaces($0) })")
    }

    /// ★ Defect 2. Every region the job declares must carry a membership core can resolve — an
    /// `add` list or a `filter` (core refuses one that resolves to no faces). The twin: a plain
    /// region carries `add`; a cut half carries its parent's.
    func testAUnionGoesOnTheWireWithNoMembership() throws {
        let p = project()
        let (u, a, b) = try union(p)
        let entries = try faceRegionEntries(p)
        func entry(_ id: RegionID) throws -> [String: Any] {
            try XCTUnwrap(entries.first { ($0["id"] as? Int) == Int(id) }, "region \(id) is declared")
        }
        // twin: the parts are plain regions and carry their faces
        XCTAssertEqual(try entry(a)["add"] as? [Int], [1])
        XCTAssertEqual(try entry(b)["add"] as? [Int], [2])
        // the union itself is declared too
        let ue = try entry(u)
        print("UNION-WIRE union entry: \(ue)")
        XCTExpectFailure("DEFECT (2026-10-08): face_regions never carries `parts`; a union ships with no add and no filter",
                         strict: true) {
            XCTAssertTrue(ue["add"] != nil || ue["filter"] != nil,
                          "★ a declared region carries a membership core can resolve")
        }
        // ★ AND CORE'S OWN PARSER REFUSES THE JOB (frozen CLI on his 102117B9 job + this entry:
        // "face region 900 declares neither a filter nor any \"add\" faces — it would resolve to
        // nothing and tag nothing"). The twin — the same project before the union — parses.
        let twin = project()
        _ = twin.surfaceEnsureRegion(for: 1); _ = twin.surfaceEnsureRegion(for: 2)
        XCTAssertNil(TopOptKit.jobSchemaError(try jobData(twin)), "control: the parts alone parse")
        let refusal = TopOptKit.jobSchemaError(try jobData(p))
        print("UNION-WIRE core's parser: \(refusal ?? "accepted")")
        XCTExpectFailure("DEFECT (2026-10-08): core's parser refuses a job carrying a Surface union", strict: true) {
            XCTAssertNil(refusal, "★ a project with a union writes a job core accepts")
        }
    }

    private func faceRegionEntries(_ p: ProjectModel) throws -> [[String: Any]] {
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try jobData(p)) as? [String: Any])
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        return try XCTUnwrap(loads["face_regions"] as? [[String: Any]], "the regions are declared")
    }

    private func jobData(_ p: ProjectModel) throws -> Data {
        let request = RunRequest(modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
                                 rulesPath: "", resolution: 64, projectName: "union",
                                 anchorFaceIDs: [0],
                                 loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [2], force: SIMD3(0, 0, -60))],
                                 faceRegions: p.faceRegions.regions)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request, progress: { _, _, _ in true }, onVariant: { _ in })
        return try run.buildJobJSON()
    }
}
