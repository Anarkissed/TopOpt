// RealPartPatternTests.swift — ★ THE PATTERN, ON THE MAINTAINER'S OWN PART.
//
// Five rounds of "the curved pattern still isn't working" passed every synthetic
// strip I built. What located the defect was his actual STEP file: face 4 of
// M2_verticalStand — the fillet band running round the inside of the hook, the one
// in his screenshots — divided 52 / 47 / 0 while my hand-built arcs came out in
// perfect thirds.
//
// ★ WHY NO INVENTED SHAPE COULD HAVE CAUGHT IT. That face is CYLINDRICAL, and
// `SurfacePatternAxis.grid` short-circuited a cylindrical frame straight to the old
// even-angle sector split, on the reasoning that "a cylindrical frame is already an
// angular parametrisation". It is — about the axis the SURFACE is swept around,
// which for a fillet band is across its width, not along its length. Every strip I
// wrote by hand was a plain triangle mesh with no analytic surface at all, so none
// of them ever took that branch.
//
// The part is checked in as a fixture for exactly this reason (handoff: "gate tests
// need real job documents — captured artifacts, not fixtures"), and the numbers
// below are the ones measured on it.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class RealPartPatternTests: XCTestCase {

    /// His part, tessellated through the same importer the app uses.
    private func realMesh() throws -> ViewerMesh {
        // ★ FOUND BY PATH, NOT THROUGH A RESOURCE BUNDLE. Declaring it as a
        // SwiftPM resource means the manifest, the bundle accessor and the cache
        // all have to agree before a test can read a file that is sitting right
        // next to it. `#filePath` needs none of that and is exact.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M2_verticalStand.step").path
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw XCTSkip("fixture absent")
        }
        let im = try TopOptKit.importMesh(path: fixture)
        return ViewerMesh(vertices: im.vertices, indices: im.indices,
                          faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
    }

    /// The share of a face's area each column holds.
    private func shares(_ mesh: ViewerMesh, face: FaceID, columns: Int) throws -> [Double] {
        let frame = FaceRegionGeometry.frame(members: [face], in: mesh)
            .rotatedInPlane(byDegrees: SurfacePatternAxis.alignmentDegrees(face: face,
                                                                          in: mesh),
                            members: [face], in: mesh)
        let result = SurfacePatternAxis.grid(face: face, frame: frame,
                                             columns: columns, rows: 1, in: mesh)
        guard case .success(let cells) = result else {
            throw XCTSkip("refused")
        }
        XCTAssertEqual(cells.count, columns)
        let polys = SurfacePatternAxis.piecePolygons(face: face, in: mesh, within: [])
        let total = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }
        return cells.map { c in
            polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea(
                SurfacePatternAxis.clipPolygon($1, to: c.cuts)) } / Swift.max(total, 1e-9)
        }
    }

    /// ★ FACE 4 — THE ARC IN HIS SCREENSHOTS. "Looking at the arc again, I can say
    /// without question there is no flat part that is selected … it is just an arc."
    ///
    /// Was 88/11 at two columns and 52/47/0 at three; the zero is the whole of
    /// "Smallest piece: 0 voxels, floor 16" and of "when I set 3 columns, there is
    /// only 1 cut in between, making 2 columns" — a piece with no surface has
    /// nothing to draw a divider against.
    func testTheArcHeReportedDividesEvenly() throws {
        let m = try realMesh()
        for (columns, tolerance) in [(2, 0.03), (3, 0.03), (4, 0.03), (6, 0.03)] {
            let got = try shares(m, face: 4, columns: columns)
            for s in got {
                XCTAssertEqual(s, 1 / Double(columns), accuracy: tolerance,
                               "★ face 4, \(columns) columns: "
                               + "\(got.map { Int(($0 * 100).rounded()) })")
            }
        }
    }

    /// Face 17, the same kind of band on the other side. Was 35/64/0 at three.
    func testTheOtherFilletBandDividesEvenly() throws {
        let m = try realMesh()
        for columns in [2, 3, 4, 6] {
            let got = try shares(m, face: 17, columns: columns)
            for s in got {
                XCTAssertEqual(s, 1 / Double(columns), accuracy: 0.03,
                               "★ face 17, \(columns) columns: "
                               + "\(got.map { Int(($0 * 100).rounded()) })")
            }
        }
    }

    /// ★ NO PIECE MAY EVER HOLD NOTHING. The property behind "Smallest piece: 0
    /// voxels", asserted across every face of the part big enough to divide — not
    /// just the two that were reported.
    func testNoFaceOfHisPartProducesAnEmptyPiece() throws {
        let m = try realMesh()
        let areas = FaceRegionGeometry.faceAreas(in: m)
        var checked = 0
        for face in Int32(0)..<Int32(m.faceGeometry.count) {
            guard let a = areas[face], a > 50 else { continue }
            let frame = FaceRegionGeometry.frame(members: [face], in: m)
                .rotatedInPlane(byDegrees: SurfacePatternAxis.alignmentDegrees(face: face,
                                                                              in: m),
                                members: [face], in: m)
            for columns in [2, 3, 4] {
                guard case .success(let cells) = SurfacePatternAxis.grid(
                    face: face, frame: frame, columns: columns, rows: 1, in: m)
                else { continue }          // a refusal is an answer, not a failure
                let polys = SurfacePatternAxis.piecePolygons(face: face, in: m, within: [])
                let total = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }
                guard total > 0 else { continue }
                for c in cells {
                    let held = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea(
                        SurfacePatternAxis.clipPolygon($1, to: c.cuts)) } / total
                    XCTAssertGreaterThan(held, 0.01,
                                         "★ face \(face), \(columns) columns: piece "
                                         + "\(c.i) holds \(Int(held * 100))% — an "
                                         + "empty piece is the '0 voxels' refusal")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40, "★ the sweep really ran")
    }

    /// ★ NO FACE OF HIS PART IS REFUSED AT 2, 3 OR 4 COLUMNS.
    ///
    /// This test began life asserting that a refusal never recommends the count it
    /// just refused — measured on face 3, which asked for two and was told "use 2 or
    /// more". It is now asserting the stronger thing that became true: with the
    /// second centreline as a fallback, no face of this part refuses at all at the
    /// counts a person actually uses. Its own guard is what noticed
    /// ("at least one face refuses, or this proves nothing" started failing).
    ///
    /// The suggestion arithmetic still has to be right for parts this one does not
    /// cover; `SurfacePatternArcRefusalTests.testTheSuggestedCountWorks` holds that,
    /// on a strip that sweeps 350° and genuinely cannot be halved by a plane.
    func testNoFaceOfHisPartIsRefusedAtOrdinaryCounts() throws {
        let m = try realMesh()
        let areas = FaceRegionGeometry.faceAreas(in: m)
        var refused: [String] = []
        var checked = 0
        for face in Int32(0)..<Int32(m.faceGeometry.count) {
            guard let a = areas[face], a > 50 else { continue }
            let frame = FaceRegionGeometry.frame(members: [face], in: m)
                .rotatedInPlane(byDegrees: SurfacePatternAxis.alignmentDegrees(face: face,
                                                                              in: m),
                                members: [face], in: m)
            for columns in [2, 3, 4] {
                checked += 1
                if case .failure(let r) = SurfacePatternAxis.grid(
                    face: face, frame: frame, columns: columns, rows: 1, in: m) {
                    refused.append("face \(face) x\(columns): \(r.reason)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 40, "★ the sweep really ran")
        // ★ ONE REFUSAL SURVIVES, AND IT IS THE RIGHT ANSWER. Face 65 is 24 mm
        // long; four pieces of it are under 7 mm each, and one of them comes out
        // holding no surface at all. Saying so is correct — the alternative is a
        // grid that quietly delivers three. Recorded exactly rather than tolerated
        // loosely, so a REGRESSION in either direction shows up here.
        XCTAssertEqual(refused,
                       ["face 65 x4: 4 pieces leaves one with nothing on this face."],
                       "★ exactly one honest refusal on this part")
    }
}
