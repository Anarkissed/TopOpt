// PrintOrientationDrawnTests — ★ notes27 P1 (builder H; his print orientation 11-23, SPEC 2a + 2b).
//
// His words: "I want the part first drawn the way it prints." Results, Results Compare and Library compare stand the part on the
// bed the way it prints (its file's print frame, else his chosen face, else against his gravity); a file made standing on a
// face is un-baked on load; the chosen face is saved with the project (older files decode); and the words are honest:
// "Prints as you placed it" / "Prints on the chosen face" / "On its edge, held by supports", the supports line from the file's
// own word, never "load paths align", never "+Z".
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintOrientationDrawnTests: XCTestCase {

    // MARK: the turn

    func testTheTurnStandsThePrintUpOnTheBed() {
        let cases: [(String, SIMD3<Float>)] = [
            ("his stand: +Z up", SIMD3(0, 0, 1)),
            ("a Y-up STL with gravity −Y", SIMD3(0, 1, 0)),
            ("an unset gravity (+Z)", BuildOrientation().resolved(gravity: nil)),
            ("printed upside down (−Y)", SIMD3(0, -1, 0)),
            ("an edge (45° between −Y and +Z)", simd_normalize(SIMD3<Float>(0, -1, 1))),
            ("a chosen face −X", SIMD3(-1, 0, 0)),
        ]
        for (what, up) in cases {
            let q = PrintDraw.settle(up: up)
            XCTAssertEqual(simd_distance(q.act(simd_normalize(up)), PrintDraw.worldUp), 0, accuracy: 1e-5, "\(what): ★ up → the screen's up")
            XCTAssertEqual(q.length, 1, accuracy: 1e-5, "\(what): a rotation")
        }
        // as placed is Setup's own gravity settle (gravity → world −Y)
        let g = SIMD3<Float>(0, 0, -1)
        let setup = simd_quatf(from: simd_normalize(g), to: SIMD3<Float>(0, -1, 0))   // ForceModel.settleRotation
        let results = PrintDraw.settle(up: BuildOrientation().resolved(gravity: g))
        let p = SIMD3<Float>(3, -7, 11)
        XCTAssertEqual(simd_distance(setup.act(p), results.act(p)), 0, accuracy: 1e-4, "★ as placed draws as Setup draws it")
        XCTAssertEqual(PrintDraw.up(frame: nil, orientation: BuildOrientation(plateUp: SIMD3(1, 0, 0)), gravity: g), SIMD3(1, 0, 0),
                       "a chosen face wins over gravity")
        let f = PrintFrameTurn(up: SIMD3(0, 1, 0), r: [1, 0, 0, 0, 0, -1, 0, 1, 0], t: .zero)
        XCTAssertEqual(PrintDraw.up(frame: f, orientation: BuildOrientation(), gravity: g), SIMD3(0, 1, 0), "★ the file's own frame first")
    }

    /// A marker pinned to a point of the part lands on the turned part: the overlay's projection and the renderer's draw agree.
    func testOverlaysProjectOntoTheTurnedPart() {
        var cam = OrbitCamera()
        cam.frame(MeshBounds(min: SIMD3(-60, -30, 0), max: SIMD3(60, 30, 70), isEmpty: false))
        let raw = CameraProjection(camera: cam, viewportSize: CGSize(width: 1376, height: 1032))
        let centre = SIMD3<Float>(0, 0, 35)
        for up in [SIMD3<Float>(0, 0, 1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), simd_normalize(SIMD3<Float>(0, -1, 1))] {
            let q = PrintDraw.settle(up: up)
            let pm = PrintDraw.modelProjection(raw, centre: centre, rotation: q)
            for m in [SIMD3<Float>(50, 20, 60), SIMD3(-40, -10, 5), centre] {
                let world = centre + q.act(m - centre)   // where the renderer draws that point (ViewerModelFrame)
                let a = pm.project(m), b = raw.project(world)
                XCTAssertNotNil(a)
                if let a, let b {
                    XCTAssertEqual(a.x, b.x, accuracy: 0.01, "\(up) \(m)")
                    XCTAssertEqual(a.y, b.y, accuracy: 0.01, "\(up) \(m)")
                }
            }
        }
    }

    // MARK: the print frame (core's print_frame_for_up, the same numbers)

    func testThePrintFrameIsCoresAndUnbakesExactly() throws {
        // print_frame.cpp: up along x → perm (2, 1, 0), sign (−1, 1, 1); −Z → a half turn about X
        let px = try XCTUnwrap(PrintFrameTurn.forUp(SIMD3(1, 0, 0)))
        XCTAssertEqual(px.r, [0, 0, -1, 0, 1, 0, 1, 0, 0])
        XCTAssertEqual(px.rot(SIMD3(1, 0, 0)), SIMD3(0, 0, 1), "★ the chosen up is +Z in the file")
        let mz = try XCTUnwrap(PrintFrameTurn.forUp(SIMD3(0, 0, -1)))
        XCTAssertEqual(mz.r, [1, 0, 0, 0, -1, 0, 0, 0, -1])
        let edge = try XCTUnwrap(PrintFrameTurn.forUp(SIMD3(0, -1, 1)))
        XCTAssertEqual(simd_distance(edge.rot(simd_normalize(SIMD3<Double>(0, -1, 1))), SIMD3(0, 0, 1)), 0, accuracy: 1e-12)
        // the base: the part's lowest point at z = 0
        let stand = Self.standMesh()
        let based = try XCTUnwrap(PrintFrameTurn.forUp(SIMD3(0, 1, 0), base: stand.vertices))
        var file = stand.vertices
        var lo = Float.infinity
        for i in stride(from: 0, to: file.count, by: 3) {
            let p = based.toPrint(SIMD3(Double(file[i]), Double(file[i + 1]), Double(file[i + 2])))
            file[i] = Float(p.x); file[i + 1] = Float(p.y); file[i + 2] = Float(p.z)
            lo = min(lo, file[i + 2])
        }
        XCTAssertEqual(lo, 0, accuracy: 1e-4, "★ standing on the bed")
        based.unbake(&file)
        for i in 0..<file.count { XCTAssertEqual(file[i], stand.vertices[i], accuracy: 1e-3) }
        // the report's block
        let rep = try JSONSerialization.data(withJSONObject: ["ok": true, "print_frame": [
            "up": [1, 0, 0], "rotation_row_major": [0, 0, -1, 0, 1, 0, 1, 0, 0], "translation_mm": [0, 0, 60]]])
        let f = try XCTUnwrap(PrintFrameTurn.of(report: rep))
        XCTAssertEqual(f.up, SIMD3(1, 0, 0))
        XCTAssertEqual(f.t, SIMD3(0, 0, 60))
        XCTAssertEqual(f.toModel(f.toPrint(SIMD3(5, 6, 7))), SIMD3(5, 6, 7))
        XCTAssertNil(PrintFrameTurn.of(report: try JSONSerialization.data(withJSONObject: ["ok": true])), "RED CONTROL: no frame")
    }

    // MARK: the chosen face is saved

    func testThePlateIsSavedWithTheProjectAndOldFilesDecode() throws {
        var snap = try Self.snapshot()
        XCTAssertNil(snap.plateUp)
        let plain = try JSONEncoder().encode(snap)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("plateUp"), "★ never written when he chose none")
        snap.plateUp = SIMD3(0, 1, 0)
        let again = try JSONDecoder().decode(ProjectSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(again.plateUp, SIMD3(0, 1, 0), "★ a snapshot round trip keeps the face")
        XCTAssertNil(try JSONDecoder().decode(ProjectSnapshot.self, from: plain).plateUp, "an older file decodes: as placed")
        // a new face is a change (his 11-23 rule: the next version), never a pick
        XCTAssertFalse(VersionSettings.same(try Self.snapshot(), snap), "★ a new face on a version with a result is a change")
    }

    @MainActor
    func testTheProjectWritesAndReadsItsFace() throws {
        let p = ProjectModel(id: UUID(), name: "Stand", material: "PLA", process: .fdm,
                             importedFile: ImportedFile(name: "stand.step", path: "/nonexistent/stand.step", triangleCount: 12,
                                                        faceCount: 6, watertight: true),
                             importedMesh: nil)
        XCTAssertNil(p.snapshot(savedAt: Date())?.plateUp)
        p.buildOrientation.plateUp = SIMD3(-1, 0, 0)
        let s = try XCTUnwrap(p.snapshot(savedAt: Date()))
        XCTAssertEqual(s.plateUp, SIMD3(-1, 0, 0))
        XCTAssertEqual(LatticeFileJob.printFrameUp(p), SIMD3(-1, 0, 0), "★ the print file's job stands it on that face")
        p.buildOrientation.plateUp = nil
        XCTAssertNil(LatticeFileJob.printFrameUp(p), "as placed: no key, the job as before")
    }

    // MARK: the words

    func testTheChecksSayHowItPrintsNeverUpright() throws {
        let o = try ResultsRedesignTests.strengthenOutcome()
        let m = ResultsModel(projectName: "Stand", outcome: o)
        func row(_ p: ResultsPrinting?) -> ResultsCheck? {
            ResultsChecks.checks(tab: m.selected, margin: 2, required: 1.5, safetyMargin: 1.5, scenarios: [], thinJoints: 0,
                                 bridged: false, printing: p).first { $0.tab == .printing && $0.kind == .info }
        }
        XCTAssertEqual(row(ResultsPrinting(way: .asPlaced))?.title, "Prints as you placed it")
        XCTAssertEqual(row(ResultsPrinting(way: .chosenFace))?.title, "Prints on the chosen face")
        XCTAssertEqual(row(ResultsPrinting(way: .onEdge))?.title, "On its edge, held by supports")
        // a Y-up STL (the certified up is +Y): "as placed", never "tilted 90°"
        XCTAssertEqual(row(nil)?.title, "Prints as you placed it", "★ the default is his placement, not the file's axis")
        let painted = try XCTUnwrap(row(ResultsPrinting(way: .chosenFace, slicerSupports: "painted", linked: true)))
        XCTAssertEqual(painted.detail, "Supports painted for you")
        XCTAssertEqual(painted.info, "The file turns supports on, only where painted. Bambu, Orca: Type tree (manual). "
            + "PrusaSlicer: For support enforcers only. In Bambu Studio, open the file as a project.")
        XCTAssertEqual(painted.link, "Print orientation")
        XCTAssertEqual(row(ResultsPrinting(way: .asPlaced, slicerSupports: "off"))?.detail, "No supports needed")
        XCTAssertEqual(row(ResultsPrinting(way: .asPlaced, slicerSupports: "needed"))?.detail, "Supports needed here")
        for w in [PrintWay.asPlaced, .chosenFace, .onEdge] {
            let t = PrintOrientationWords.title(w)
            // (362's words for the edge, "On its edge, held by supports", are six: a row's title, not a caption)
            XCTAssertLessThanOrEqual(t.split(separator: " ").count, w == .onEdge ? 6 : 5, "his rule: ≤ 5 words")
            XCTAssertFalse(t.contains("+Z") || t.lowercased().contains("upright") || t.lowercased().contains("face 1"))
        }
        for w in [PrintOrientationWords.painted, PrintOrientationWords.none, PrintOrientationWords.needed] {
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 5, w)
        }
        // Details › Printing: no "load paths"
        m.printing = ResultsPrinting(way: .chosenFace, slicerSupports: "painted")
        let orient = m.detailRows(.printing, version: nil).first { $0.label == "Orientation" }?.value ?? ""
        XCTAssertEqual(orient, "Prints on the chosen face · layers across the height · Supports painted for you")
        XCTAssertFalse(ResultsModel.orientationSummary(tiltDegrees: 0, supportCm3: 0, supportLabel: "").contains("load paths"),
                       "★ never computed: never said")
        // the Settings Plate row
        XCTAssertEqual(PrintOrientationWords.plateValue(BuildOrientation()), "As placed")
        XCTAssertEqual(PrintOrientationWords.plateValue(BuildOrientation(plateUp: SIMD3(0, 1, 0))), "Chosen face")
    }

    func testTheFilesOwnSupportsWord() throws {
        var r = IPadNotes1121Tests.report()
        for (word, line) in [("painted", "Supports painted for you"), ("off", "No supports needed"), ("needed", "Supports needed here")] {
            r["slicer_supports"] = word
            let f = try XCTUnwrap(LatticeFileFacts.decode(r))
            XCTAssertEqual(f.slicerSupports, word)
            XCTAssertNil(f.checks.first { $0.title == "Print file ready" }?.more, "★ never \"Turn supports off\": the row below says")
            XCTAssertEqual(f.rows(.printing).first { $0.label == "Supports" }?.value, line)
        }
        r["slicer_supports"] = "painted"
        r["painted"] = ["places": 3, "places_painted": 1, "triangles": 27, "area_mm2": 34.9, "est_volume_mm3": 2139.8,
                        "support_type": "tree(manual)", "at": [[-0.9, 18.9, 64.5]],
                        "stand": ["rests_on": "edge", "stands": true, "band_mm": [2, 13], "area_mm2": 1845]] as [String: Any]
        let facts = PrintReportFacts.decode(r)
        XCTAssertTrue(facts.onEdge, "★ a file standing on an edge says so")
        XCTAssertEqual(facts.slicerSupports, "painted")
    }

    @MainActor
    func testAFileMadeStandingOnAFaceIsUnbakedOnLoad() throws {
        // the stand turned so +Y is up (core's frame for up = +Y), written as the Mac would, then read back
        let s = PrintOrientationDrawnTests.standMesh()
        let turn = try XCTUnwrap(PrintFrameTurn.forUp(SIMD3(0, 1, 0), base: s.vertices))
        var file = s.vertices
        for i in stride(from: 0, to: file.count, by: 3) {
            let p = turn.toPrint(SIMD3(Double(file[i]), Double(file[i + 1]), Double(file[i + 2])))
            file[i] = Float(p.x); file[i + 1] = Float(p.y); file[i + 2] = Float(p.z)
        }
        let stl = MeshExport.binarySTL(vertices: file, indices: s.indices, header: Data())
        let report: [String: Any] = ["ok": true, "file": "lattice.stl", "layout": ["bars": 0], "mesh": ["mm3": 1.0, "part_mm3": 2.0],
                                     "print_check": ["clean": true],
                                     "print_frame": ["up": [0, 1, 0], "rotation_row_major": turn.r,
                                                     "translation_mm": [turn.t.x, turn.t.y, turn.t.z]]]
        let rd = try JSONSerialization.data(withJSONObject: report)
        let made = LatticeFileRun.Made(stl: stl, report: try XCTUnwrap(LatticeFileReport.parse(rd)), reportJSON: rd)
        let o = try LatticeFileButton.outcome(made, densityGCm3: 1.2)
        let v = try XCTUnwrap(o.variants.first?.meshVertices)
        let lo = stride(from: 0, to: v.count, by: 3).map { v[$0 + 2] }.min() ?? -1
        XCTAssertEqual(lo, 0, accuracy: 1e-3, "★ back in the part's own coordinates: its base at z = 0 again (as placed)")
        let hi = stride(from: 0, to: v.count, by: 3).map { v[$0 + 2] }.max() ?? -1
        XCTAssertEqual(hi, 70, accuracy: 1e-3)
    }

    // MARK: the job

    func testTheJobCarriesThePrintFrameOnlyForAChosenFace() throws {
        let s = LatticeLayoutSession.Settings()
        let plain = try LatticeFileJob.build(s, modelName: "model.step")
        XCTAssertNil((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["print_frame"], "as placed: no key")
        let turned = try LatticeFileJob.build(s, modelName: "model.step", printFrameUp: SIMD3(0, 1, 0))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: turned) as? [String: Any])
        XCTAssertEqual((o["print_frame"] as? [String: Any])?["up"] as? [Double], [0, 1, 0], "★ core's key: the up in the part's own frame")
    }

    // MARK: fixtures

    /// His stand, roughly: a 120 mm long prism whose end profile is a base 60 mm deep, a back wall 70 mm high and a sloped front
    /// (y, z): (0, 0) (60, 0) (60, 10) (10, 70) (0, 70), extruded along X from −60 to 60. Closed, outward-facing.
    nonisolated static func standMesh() -> (vertices: [Float], indices: [Int32]) {
        let prof: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(60, 0), SIMD2(60, 10), SIMD2(10, 70), SIMD2(0, 70)]
        var v: [Float] = []
        for x in [Float(-60), 60] { for p in prof { v += [x, p.x - 30, p.y] } }
        var t: [Int32] = []
        let n = Int32(prof.count)
        // the two ends (fans), left end facing −X, right end facing +X
        for i in 1..<(n - 1) { t += [0, i + 1, i]; t += [n, n + i, n + i + 1] }
        // the sides
        for i in 0..<n {
            let j = (i + 1) % n
            t += [i, j, n + j, i, n + j, n + i]
        }
        return (v, t)
    }

    static func snapshot() throws -> ProjectSnapshot {
        ProjectSnapshot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000027")!, name: "Stand", material: "PLA",
                        process: .fdm, modelFileName: "model.step", originalFileName: "stand.step",
                        savedAt: Date(timeIntervalSince1970: 0), selection: SelectionModel(), force: ForceModel())
    }
}
