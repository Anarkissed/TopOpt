// PatternFlatTests — B8 (row 37; "On a flat face, the grid sits square to the face's own edges"; the reviewer's 11-09 18:31Z
// ruling (b): the bar ✕ │ − n along + │ − n across + │ Rotate ↺ n° ↻ │ ✓, "starting square to the longest edge", Rotate in 15°
// steps): the pure parts — the straight grid (PatternFlat), the counts as cut lines and Rotate's number (PatternGrid), and
// which faces lay it (CutAim.isFlat). The page: PatternFlatHostedTests.
import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

final class PatternFlatTests: XCTestCase {

    /// A flat plate, `long` × `wide` mm, turned `turn`° in its own plane and tilted out of every axis plane, as a triangle
    /// grid (so a walk over its triangles has a long diagonal to take). The CAD calls it a plane. Its long sides' boundary
    /// segments (15 mm) are its longest (the app's longest straight edge is the longest boundary segment, as a CAD
    /// tessellation draws a straight edge).
    /// `narrow`: the far end's width (a trapezoid when it differs from `wide`).
    static func plate(long: Double = 60, wide: Double = 20, narrow: Double? = nil, turn: Double = 30)
        -> (mesh: ViewerMesh, along: SIMD3<Double>, normal: SIMD3<Double>, at: (Double, Double) -> SIMD3<Double>) {
        let n = simd_normalize(SIMD3<Double>(0.3, -0.4, 1))
        let e1 = simd_normalize(simd_cross(SIMD3<Double>(0, 1, 0), n))
        let e2 = simd_cross(n, e1)
        let t = turn * .pi / 180
        let u = e1 * cos(t) + e2 * sin(t), v = simd_cross(n, u)
        let origin = SIMD3<Double>(5, -3, 7)
        let far = narrow ?? wide
        func at(_ x: Double, _ y: Double) -> SIMD3<Double> {
            // y runs 0…1 across the width at x (the width shrinks linearly to `far`)
            let w = wide + (far - wide) * x / long
            return origin + u * x + v * (y * w)
        }
        let nx = 4, ny = 6
        var verts: [Float] = [], idx: [Int32] = []
        for j in 0...ny {
            for i in 0...nx {
                let p = at(long * Double(i) / Double(nx), Double(j) / Double(ny))
                verts += [Float(p.x), Float(p.y), Float(p.z)]
            }
        }
        for j in 0..<ny {
            for i in 0..<nx {
                let a = Int32(j * (nx + 1) + i), b = a + 1, c = a + Int32(nx + 1), d = c + 1
                idx += [a, b, d, a, d, c]
            }
        }
        let mesh = ViewerMesh(vertices: verts, indices: idx, faceIDs: [Int32](repeating: 0, count: idx.count / 3),
                              faceGeometry: [StepFaceGeometry(kind: .plane, planeNormal: n)])
        return (mesh, u, n, at)
    }

    /// The frame the page lays its grid in: the face's own, turned to its longest straight edge, then by Rotate.
    static func frame(_ m: ViewerMesh, rotate: Double = 0) -> FaceRegionGeometry.Frame {
        FaceRegionGeometry.frame(members: [0], in: m)
            .rotatedInPlane(byDegrees: SurfacePatternAxis.alignmentDegrees(face: 0, in: m) + rotate, members: [0], in: m)
    }

    /// Each cell's area on the plate (its triangles clipped to the cell).
    static func areas(_ cells: [FaceRegionGeometry.GridCell], _ m: ViewerMesh, within: [RegionCut] = []) -> [Double] {
        let polys = SurfacePatternAxis.piecePolygons(face: 0, in: m, within: within)
        return cells.map { c in polys.reduce(0) { $0 + SurfacePatternAxis.polygonArea(SurfacePatternAxis.clipPolygon($1, to: c.cuts)) } }
    }

    /// ★ "the grid sits square to the face's own edges": on a flat plate the lines along stand square to its longest edge
    /// (and the lines across run along it), and the pieces are even.
    func testAFlatPlatesGridIsSquareToItsLongestEdge() throws {
        let p = Self.plate()
        let cells = try PatternFlat.cells(face: 0, frame: Self.frame(p.mesh), columns: 3, rows: 2, in: p.mesh).get()
        XCTAssertEqual(cells.count, 6)
        var along = 0, across = 0
        for c in cells {
            for cut in c.cuts {
                let k = simd_normalize(cut.normal)
                XCTAssertEqual(simd_dot(k, p.normal), 0, accuracy: 1e-9, "every line lies across the plate")
                let d = abs(simd_dot(k, p.along))
                if d > 1 - 1e-6 { along += 1 } else {
                    XCTAssertEqual(d, 0, accuracy: 1e-6, "★ every line is square to the longest edge, or runs along it"); across += 1
                }
            }
        }
        XCTAssertGreaterThan(along, 0, "★ lines square to the longest edge"); XCTAssertGreaterThan(across, 0, "and along it")
        let a = Self.areas(cells, p.mesh)
        // (the mesh holds single-precision positions: areas agree to ~1e-5 mm², so 1e-3 mm² on a 200 mm² piece)
        for x in a { XCTAssertEqual(x, 60 * 20 / 6, accuracy: 1e-3, "★ six even pieces") }
    }

    /// ★ Rotate turns the grid by its own degrees, about the face's normal.
    func testRotateTurnsTheGridByItsDegrees() throws {
        let p = Self.plate()
        for r in [15.0, 45, 90, 345] {
            let cells = try PatternFlat.cells(face: 0, frame: Self.frame(p.mesh, rotate: r), columns: 2, rows: 1, in: p.mesh).get()
            let k = simd_normalize(try XCTUnwrap(cells[1].cuts.first).normal)
            XCTAssertEqual(abs(simd_dot(k, p.along)), abs(cos(r * .pi / 180)), accuracy: 1e-6, "★ \(r)°: the line turns by \(r)°")
            let a = Self.areas(cells, p.mesh)
            XCTAssertEqual(a[0], a[1], accuracy: 1e-3, "\(r)°: two even halves")
        }
    }

    /// ★ On any outline the lines sit where the area divides evenly (no end piece a sliver) — still square to the long edge.
    func testOnATaperedPlateEveryPieceHoldsAnEvenShare() throws {
        let p = Self.plate(long: 60, wide: 30, narrow: 6, turn: 0)
        let cells = try PatternFlat.cells(face: 0, frame: Self.frame(p.mesh), columns: 4, rows: 1, in: p.mesh).get()
        let a = Self.areas(cells, p.mesh), total = 60 * (30 + 6) / 2.0
        for x in a { XCTAssertEqual(x, total / 4, accuracy: 1e-3, "★ four even shares on a taper") }
        // control: even spacing on the same taper leaves the narrow end's piece far smaller
        let even = FaceRegionGeometry.gridSplitCells(Self.frame(p.mesh), n: 4, m: 1)
        let e = Self.areas(even, p.mesh)
        XCTAssertLessThan(e.min() ?? 0, total / 4 * 0.8, "control: even spacing would leave a small end piece")
    }

    /// ★ Inside a piece already cut, the lines divide that piece only.
    func testInsideACutPieceTheLinesDivideThatPiece() throws {
        let p = Self.plate(turn: 0)
        let keep = [RegionCut(point: p.at(30, 0), normal: p.along)]   // the far half
        let cells = try PatternFlat.cells(face: 0, frame: Self.frame(p.mesh), columns: 2, rows: 1, in: p.mesh, within: keep).get()
        let a = Self.areas(cells, p.mesh, within: keep)
        XCTAssertEqual(a[0], 300, accuracy: 1e-3, "★ half of the far half"); XCTAssertEqual(a[1], 300, accuracy: 1e-3)
        let line = try XCTUnwrap(cells[1].cuts.first)
        XCTAssertEqual(simd_dot(line.point - p.at(0, 0), p.along), 45, accuracy: 1e-4, "★ the line sits at 45 mm, inside the piece")
    }

    /// ★ The bar's counts are cut lines (P5: from 0); Rotate's number is the Cut bar's 0..<360.
    func testTheCountsAreCutLinesAndRotateWraps() {
        XCTAssertEqual(PatternGrid.pieces(lines: 0), 1); XCTAssertEqual(PatternGrid.pieces(lines: 2), 3)
        XCTAssertEqual(PatternGrid.lines(pieces: 3), 2); XCTAssertEqual(PatternGrid.lines(pieces: 1), 0)
        for n in PatternGrid.linesRange { XCTAssertEqual(PatternGrid.lines(pieces: PatternGrid.pieces(lines: n)), n) }
        XCTAssertEqual(PatternGrid.pieces(lines: PatternGrid.defaultAlong), 3, "today's first grid: 3 × 1")
        XCTAssertEqual(PatternGrid.pieces(lines: PatternGrid.defaultAcross), 1)
        XCTAssertEqual(PatternGrid.rotation(-15), 345, "↺ from 0")
        XCTAssertEqual(PatternGrid.rotation(360), 0); XCTAssertEqual(PatternGrid.rotation(375), 15); XCTAssertEqual(PatternGrid.rotation(-0.0), 0)
        XCTAssertEqual(PatternBarCopy.along, "along"); XCTAssertEqual(PatternBarCopy.across, "across")
        XCTAssertEqual(PatternBarCopy.rotate, "Rotate")
    }

    /// The straight grid is for flat faces only (the Cut tool's own test); a curve keeps the arc grid.
    func testOnlyAFlatFaceLaysTheStraightGrid() {
        XCTAssertTrue(CutAim.isFlat(0, in: Self.plate().mesh), "★ a CAD plane")
        let v: [Float] = [1, 0, 0, 0, 1, 0, 0, 1, 5]
        let band = ViewerMesh(vertices: v, indices: [0, 1, 2], faceIDs: [0],
                              faceGeometry: [StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 1, axisPoint: .zero,
                                                              axisDir: SIMD3(0, 0, 1))])
        XCTAssertFalse(CutAim.isFlat(0, in: band), "★ a CAD cylinder (a band, a fillet) keeps the arc grid")
    }
}
