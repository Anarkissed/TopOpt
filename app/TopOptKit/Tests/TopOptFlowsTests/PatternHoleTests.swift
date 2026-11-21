// PatternHoleTests — B8 (row 37; plan §B8 "Pattern follows the same rules: on a hole, rows run down its axis; either count
// can be 0"; mockup #cut-pattern, #cut-pattern-zero, #cut-pattern-none): the pattern on a hole, on the committed
// WallMount_ShelfBracket.stl (its bores are the importer's own fits, as CutAimTests uses them).
//   • The bore is seen on CutAim's own axis.
//   • n around: half-planes holding the axis; m down the hole: rings standing square to it, evenly down the bore.
//   • The cells part the bore: every bit of it is in exactly one piece.
//   • Either count can be 0; with no cut either way there is nothing to cut.
//   • Part of a ring (a STEP's half bore) is divided inside itself: n lines make n + 1 pieces there.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class PatternHoleTests: XCTestCase {

    /// The committed shelf bracket (CutAimTests' fixture).
    private func bracket() throws -> ViewerMesh {
        let m = try TopOptKit.importMesh(path: CutAimTests.repoRoot
            .appendingPathComponent("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl").path)
        return ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, faceGeometry: m.faceGeometry,
                          pseudoFaces: m.pseudoFaces)
    }

    private func boreOf(_ m: ViewerMesh) throws -> (FaceID, CutAim, PatternHole.Bore) {
        let f = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { FaceTopology.isFastenerBore($0, in: m) }, "a bore")
        let aim = try XCTUnwrap(CutAim.make(face: f, piece: nil, regions: FaceRegionModel(), mesh: m))
        let pts = CutAim.points(face: f, piece: nil, regions: FaceRegionModel(), mesh: m)
        let bore = try XCTUnwrap(PatternHole.bore(aim, points: pts), "★ a hole is a bore to the pattern")
        return (f, aim, bore)
    }

    /// The face's triangle middles (inside the face, off every divider in practice).
    private func middles(_ f: FaceID, _ m: ViewerMesh) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        var t = 0
        while t + 2 < m.indices.count {
            if t / 3 < m.faceIDs.count, m.faceIDs[t / 3] == f {
                var c = SIMD3<Double>(repeating: 0)
                for k in 0..<3 {
                    let b = Int(m.indices[t + k]) * 3
                    c += SIMD3(Double(m.positions[b]), Double(m.positions[b + 1]), Double(m.positions[b + 2]))
                }
                out.append(c / 3)
            }
            t += 3
        }
        return out
    }

    private func cells(_ b: PatternHole.Bore, _ a: Int, _ d: Int) throws -> [FaceRegionGeometry.GridCell] {
        switch PatternHole.cells(b, around: a, down: d) {
        case .success(let c): return c
        case .failure(let r): XCTFail("\(a) around × \(d) down refused: \(r.reason)"); return []
        }
    }

    /// ★ Lines hold the axis; rings stand square to it, evenly down the bore.
    func testLinesHoldTheAxisAndRingsStandSquareToIt() throws {
        let m = try bracket()
        let (_, aim, bore) = try boreOf(m)
        XCTAssertEqual(abs(simd_dot(bore.axis, aim.axis)), 1, accuracy: 1e-9, "★ the bore's axis is CutAim's")
        let cs = try cells(bore, 6, 3)
        XCTAssertEqual(cs.count, PatternHole.pieces(bore, around: 6, down: 3))
        XCTAssertEqual(cs.count, (bore.arc == nil ? 6 : 7) * 4, "6 around × 3 down")
        var ringPlaces = Set<Int>(), lines = 0
        for c in cs {
            for cut in c.cuts {
                let n = simd_normalize(cut.normal), along = abs(simd_dot(n, bore.axis))
                if along > 1 - 1e-9 {
                    ringPlaces.insert(Int((simd_dot(cut.point - bore.centre, bore.axis) * 1000).rounded()))
                } else {
                    XCTAssertEqual(along, 0, accuracy: 1e-9, "★ a line's plane holds the axis's direction …")
                    XCTAssertEqual(simd_dot(bore.centre - cut.point, n), 0, accuracy: 1e-9, "★ … and the axis itself")
                    lines += 1
                }
            }
        }
        XCTAssertGreaterThan(lines, 0, "lines round the bore")
        let len = bore.reach.upperBound - bore.reach.lowerBound
        let want = Set((1...3).map { Int(((bore.reach.lowerBound + len * Double($0) / 4) * 1000).rounded()) })
        XCTAssertEqual(ringPlaces, want, "★ 3 rings, evenly down the bore")
    }

    /// ★ The cells part the bore: each bit of it in exactly one piece.
    func testTheCellsPartTheBore() throws {
        let m = try bracket()
        let (f, _, bore) = try boreOf(m)
        for (a, d) in [(6, 3), (2, 1), (3, 0), (0, 2), (5, 12)] {
            let cs = try cells(bore, a, d)
            for p in middles(f, m) {
                let n = cs.filter { FaceRegionGeometry.inside(p, $0.cuts) }.count
                XCTAssertEqual(n, 1, "★ \(a) around × \(d) down: a bit of the bore is in \(n) pieces")
            }
        }
    }

    /// ★ P5: either count can be 0; nothing either way is nothing to cut.
    func testEitherCountCanBeZero() throws {
        let m = try bracket()
        let (_, _, bore) = try boreOf(m)
        let rings = try cells(bore, 0, 3)
        XCTAssertEqual(rings.count, 4, "★ 0 around: rings only")
        XCTAssertTrue(rings.allSatisfy { $0.cuts.allSatisfy { abs(simd_dot(simd_normalize($0.normal), bore.axis)) > 1 - 1e-9 } },
                      "★ … every cut a ring")
        let lines = try cells(bore, 6, 0)
        XCTAssertEqual(lines.count, bore.arc == nil ? 6 : 7, "0 down: lines only")
        XCTAssertTrue(lines.allSatisfy { $0.cuts.allSatisfy { abs(simd_dot($0.normal, bore.axis)) < 1e-9 } }, "… every cut a line")
        XCTAssertEqual(PatternHole.cells(bore, around: 0, down: 0), .failure(.init(PatternHole.nothingToCut)),
                       "★ both 0: nothing to cut")
        if bore.arc == nil {
            XCTAssertEqual(PatternHole.cells(bore, around: 1, down: 0), .failure(.init(PatternHole.nothingToCut)),
                           "one line cannot part a whole ring")
        }
        XCTAssertEqual(PatternHole.pieces(bore, around: 0, down: 0), 0)
    }

    /// ★ Part of a ring (a STEP bore's half, or a piece already cut along) is divided inside itself.
    func testPartOfARingIsDividedInsideIt() throws {
        let m = try bracket()
        let (f, aim, whole) = try boreOf(m)
        let pts = CutAim.points(face: f, piece: nil, regions: FaceRegionModel(), mesh: m)
        let half = pts.filter { whole.degrees(of: $0) < 180 }
        let bore = try XCTUnwrap(PatternHole.bore(aim, points: half))
        let arc = try XCTUnwrap(bore.arc, "★ half a ring is part of one")
        XCTAssertEqual(arc.span, 180, accuracy: 30, "about half")
        let cs = try cells(bore, 2, 0)
        XCTAssertEqual(cs.count, 3, "★ 2 lines on part of a ring make 3 pieces")
        let mids = middles(f, m).filter { let d = whole.degrees(of: $0); return d >= arc.start && d <= arc.start + arc.span }
        XCTAssertFalse(mids.isEmpty, "premise: some of the bore is in the half")
        for p in mids {
            XCTAssertEqual(cs.filter { FaceRegionGeometry.inside(p, $0.cuts) }.count, 1, "★ each bit of the half in one piece")
        }
        for c in cs { XCTAssertTrue(mids.contains { FaceRegionGeometry.inside($0, c.cuts) }, "★ every piece holds some of it") }
    }
}
