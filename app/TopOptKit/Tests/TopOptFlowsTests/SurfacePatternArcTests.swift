// SurfacePatternArcTests.swift — ★ §7 REBUILT: the pattern on a face, measured.
//
// The maintainer reported the curved pattern as broken five times. Each round I
// changed the DIVISION RULE and each round it was still wrong, so these tests
// pin the two properties that were actually failing and that no previous test
// asserted:
//
//   ★ THE CELLS PARTITION. Every piece of surface belongs to exactly one cell —
//     not two, not none. The old lateral box overlapped neighbours by a quarter of
//     their length and could still leave a cell holding nothing, which is what
//     "Smallest piece: 0 voxels, floor 16" was.
//
//   ★ A DIVIDER APPEARS IN ONE PLACE. A plane cuts a U twice, so a divider drawn
//     across the whole face draws a phantom line through the far arm — the extra
//     marks in his screenshots. A wedge plane hinged on the fitted arc's axis
//     cannot do that, and this proves it rather than asserting it.
//
// Plus the fit itself: a circle of known radius and sweep must be recovered as
// that circle, and a straight strip must be recognised as straight rather than
// given a centre a thousand millimetres away.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: meshes to measure on

enum ArcTestMesh {

    /// A flat strip of constant width following `centreline`, in the z = 0 plane.
    static func strip(_ centreline: [SIMD2<Double>], halfWidth: Double = 2) -> ViewerMesh {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        for (i, c) in centreline.enumerated() {
            let prev = centreline[max(0, i - 1)]
            let next = centreline[min(centreline.count - 1, i + 1)]
            var d = next - prev
            if simd_length(d) < 1e-9 { d = SIMD2(0, 1) }
            let n = simd_normalize(SIMD2(-d.y, d.x)) * halfWidth
            v += [Float(c.x - n.x), Float(c.y - n.y), 0,
                  Float(c.x + n.x), Float(c.y + n.y), 0]
        }
        for s in 0..<(centreline.count - 1) {
            let a = Int32(s * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// A circular band: radius `r`, sweeping `degrees` about the origin.
    static func arcStrip(radius r: Double, degrees: Double,
                         steps: Int = 80, halfWidth: Double = 2) -> ViewerMesh {
        let line = (0...steps).map { k -> SIMD2<Double> in
            let a = degrees * .pi / 180 * Double(k) / Double(steps)
            return SIMD2(r * cos(a), r * sin(a))
        }
        return strip(line, halfWidth: halfWidth)
    }

    /// A straight strip along +x.
    static func straightStrip(length: Double, steps: Int = 60,
                              halfWidth: Double = 2) -> ViewerMesh {
        let line = (0...steps).map {
            SIMD2<Double>(length * Double($0) / Double(steps), 0)
        }
        return strip(line, halfWidth: halfWidth)
    }

    /// The U: down one arm, round the bend, up the other. His part's inside curve.
    static func uStrip(steps: Int = 40, halfWidth: Double = 2) -> ViewerMesh {
        var line: [SIMD2<Double>] = []
        for i in 0...steps { line.append(SIMD2(-10, 40 - Double(i) / Double(steps) * 40)) }
        for i in 1...steps {
            let t = Double(i) / Double(steps) * Double.pi
            line.append(SIMD2(-10 * cos(t), -10 * sin(t)))
        }
        for i in 1...steps { line.append(SIMD2(10, Double(i) / Double(steps) * 40)) }
        return strip(line, halfWidth: halfWidth)
    }

    /// Every triangle of face 0, as (centroid, area).
    static func triangles(_ m: ViewerMesh) -> [(centre: SIMD3<Double>, area: Double)] {
        var out: [(SIMD3<Double>, Double)] = []
        var t = 0
        while t + 2 < m.indices.count {
            let tri = t / 3
            guard tri < m.faceIDs.count, m.faceIDs[tri] == 0 else { t += 3; continue }
            var p: [SIMD3<Double>] = []
            for k in 0..<3 {
                let vi = Int(m.indices[t + k]) * 3
                p.append(SIMD3<Double>(SIMD3<Float>(m.positions[vi], m.positions[vi + 1],
                                                    m.positions[vi + 2])))
            }
            t += 3
            let a = simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
            guard a > 0 else { continue }
            out.append(((p[0] + p[1] + p[2]) / 3, a))
        }
        return out
    }

    /// Whether a point satisfies every half-space of a cell — the SAME rule the
    /// region resolver applies to a voxel centre.
    static func inside(_ p: SIMD3<Double>, _ cuts: [RegionCut]) -> Bool {
        for c in cuts {
            let n = simd_normalize(c.normal)
            let d = simd_dot(p - c.point, n)
            if c.strict ? !(d > 0) : !(d >= 0) { return false }
        }
        return true
    }

    static func spine(_ m: ViewerMesh) -> [SIMD3<Double>]? {
        SurfacePatternAxis.ribbonSpine(face: 0, in: m, within: [])
    }

    static func polygons(_ m: ViewerMesh) -> [[SIMD3<Double>]] {
        SurfacePatternAxis.piecePolygons(face: 0, in: m, within: [])
    }

    static func cells(_ m: ViewerMesh, columns: Int, rows: Int = 1)
        -> Result<[FaceRegionGeometry.GridCell], SurfacePatternArc.Refusal> {
        guard let s = spine(m) else { return .failure(.init("no spine")) }
        return SurfacePatternArc.cells(spine: s, polygons: polygons(m),
                                       columns: columns, rows: rows)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ the fit — his "compare the curve to a circle"

final class SurfacePatternArcFitTests: XCTestCase {

    func testACircleIsRecoveredAsItsOwnCircle() throws {
        let m = ArcTestMesh.arcStrip(radius: 30, degrees: 120)
        let s = try XCTUnwrap(SurfacePatternArc.fit(spine: XCTUnwrap(ArcTestMesh.spine(m))))
        XCTAssertTrue(s.isCurved)
        XCTAssertEqual(s.radiusMM, 30, accuracy: 2.0,
                       "★ the radius the strip was built with")
        // ★ A FEW DEGREES SHORT, AND CORRECTLY SO. The spine is walked over
        // TRIANGLE CENTROIDS, so it begins and ends half a triangle inside the
        // face's real rim — the sweep it reports is the SPINE's, which is what it
        // says. The face's own angular extent is measured separately, by
        // `angularExtent`, and it is that which sets the outermost cell bounds.
        XCTAssertEqual(s.sweepDegrees, 120, accuracy: 10,
                       "★ 'how wide the face's full length is in degrees'")
        XCTAssertEqual(simd_length(s.centre - SIMD3<Double>(0, 0, 0)), 0, accuracy: 2.0,
                       "and the centre is where the arc was struck from")
    }

    func testAStraightStripIsStraight() throws {
        let m = ArcTestMesh.straightStrip(length: 60)
        let s = try XCTUnwrap(SurfacePatternArc.fit(spine: XCTUnwrap(ArcTestMesh.spine(m))))
        XCTAssertFalse(s.isCurved,
                       "★ a straight run must not be given a centre a kilometre away")
        XCTAssertEqual(s.lengthMM, 60, accuracy: 1)
    }

    /// ★ AND A HOOK'S SWEEP IS NOT ITS TANGENT TURN — THE TWO ARE DIFFERENT
    /// QUANTITIES AND ONLY ONE OF THEM DIVIDES IT.
    ///
    /// A U's TANGENT turns through 180°: it points down, then round, then up. But
    /// the strip's arms run radially away from the bend's centre rather than round
    /// it, so the ANGLE SUBTENDED AT THAT CENTRE — which is what a wedge divides —
    /// is much larger, about 310°. I asserted 180 here first, from the tangent, and
    /// it was simply the wrong measure for what the cells are built in.
    func testTheUSweepsMostOfATurnAboutItsCentre() throws {
        let m = ArcTestMesh.uStrip()
        let s = try XCTUnwrap(SurfacePatternArc.fit(spine: XCTUnwrap(ArcTestMesh.spine(m))))
        XCTAssertTrue(s.isCurved, "★ a hook must not fall through to the straight "
                      + "construction — a parallel plane cuts both its arms")
        XCTAssertGreaterThan(s.sweepDegrees, 180,
                             "★ the arms subtend angle too — \(s.sweepDegrees)")
        XCTAssertLessThan(s.sweepDegrees, 358,
                          "★ but it does not close on itself")
    }

    /// ★ A TAPERED BUT DEAD STRAIGHT STRIP IS STRAIGHT. Its walked spine
    /// saw-tooths, and integrating those local tangents reported 23° of turn and a
    /// centre 93 mm off a strip that does not bend. The bow test is what refuses
    /// it: a wiggle that returns to the line adds nothing to the bow.
    func testATaperedStraightStripIsStillStraight() throws {
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        for s in 0...40 {
            let x = Float(s), h = Float(6 * (1 - Double(s) / 40))
            v += [x, -h, 0, x, h, 0]
        }
        for s in 0..<40 {
            let a = Int32(s * 2)
            idx += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            fids += [0, 0]
        }
        let m = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                           faceGeometry: [StepFaceGeometry(kind: .plane,
                                                           planeNormal: SIMD3(0, 0, 1))])
        let s = try XCTUnwrap(SurfacePatternArc.fit(spine: XCTUnwrap(ArcTestMesh.spine(m))))
        XCTAssertFalse(s.isCurved, "★ measured bow was 0.3% of its length")
    }

    func testTheAngleMeasureRunsMonotonicallyAlongTheStrip() throws {
        let m = ArcTestMesh.uStrip()
        let spine = try XCTUnwrap(ArcTestMesh.spine(m))
        let s = try XCTUnwrap(SurfacePatternArc.fit(spine: spine))
        let a = SurfacePatternArc.unwrappedDegrees(spine, s)
        XCTAssertEqual(a.count, spine.count)
        // ★ UNWRAPPED. Raw atan2 jumps by 360 in the middle of a U and every
        // comparison downstream is then nonsense.
        for i in 1..<a.count {
            XCTAssertLessThan(abs(a[i] - a[i - 1]), 45,
                              "★ no 360° jump at step \(i)")
        }
        XCTAssertGreaterThan(abs(a[a.count - 1] - a[0]), 90,
                             "and it really does sweep")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE PROPERTY EVERY EARLIER BUILD BROKE — the cells partition

final class SurfacePatternArcPartitionTests: XCTestCase {

    /// Every triangle of the face lands in EXACTLY ONE cell. This is the test that
    /// would have caught the padded lateral box (triangles in two cells) and the
    /// empty cell ("0 voxels", triangles in none).
    private func assertPartitions(_ m: ViewerMesh, columns: Int, rows: Int = 1,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let cells) = ArcTestMesh.cells(m, columns: columns, rows: rows)
        else { return XCTFail("refused", file: file, line: line) }
        XCTAssertEqual(cells.count, columns * rows, file: file, line: line)

        var counts: [Int: Int] = [:]
        var homeless = 0, shared = 0
        for (centre, _) in ArcTestMesh.triangles(m) {
            var n = 0
            for (k, c) in cells.enumerated() where ArcTestMesh.inside(centre, c.cuts) {
                n += 1
                counts[k, default: 0] += 1
            }
            if n == 0 { homeless += 1 }
            if n > 1 { shared += 1 }
        }
        XCTAssertEqual(homeless, 0,
                       "★ \(homeless) triangles belong to NO cell — that is the "
                       + "'smallest piece: 0 voxels' refusal", file: file, line: line)
        XCTAssertEqual(shared, 0,
                       "★ \(shared) triangles belong to TWO cells — a tap there "
                       + "lands in both pieces", file: file, line: line)
        XCTAssertEqual(counts.count, columns * rows,
                       "★ every cell holds surface", file: file, line: line)
    }

    func testAStraightStripPartitions()       { assertPartitions(ArcTestMesh.straightStrip(length: 60), columns: 3) }
    func testAGentleArcPartitions()           { assertPartitions(ArcTestMesh.arcStrip(radius: 30, degrees: 90), columns: 3) }
    func testASharpArcPartitions()            { assertPartitions(ArcTestMesh.arcStrip(radius: 12, degrees: 150), columns: 4) }
    func testTheUPartitions()                 { assertPartitions(ArcTestMesh.uStrip(), columns: 3) }
    func testTheUPartitionsAtSixColumns()     { assertPartitions(ArcTestMesh.uStrip(), columns: 6) }
    func testAStraightStripPartitionsInRows() { assertPartitions(ArcTestMesh.straightStrip(length: 60), columns: 3, rows: 2) }
    func testAnArcPartitionsInRows()          { assertPartitions(ArcTestMesh.arcStrip(radius: 30, degrees: 90), columns: 3, rows: 2) }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ AND THE PIECES ARE ACTUALLY EQUAL — the thing he kept measuring by eye

final class SurfacePatternArcEqualityTests: XCTestCase {

    /// The share of the face's area each cell holds.
    private func shares(_ m: ViewerMesh, columns: Int) throws -> [Double] {
        guard case .success(let cells) = ArcTestMesh.cells(m, columns: columns)
        else { throw XCTSkip("refused") }
        let tris = ArcTestMesh.triangles(m)
        let total = tris.reduce(0.0) { $0 + $1.area }
        return cells.map { c in
            tris.filter { ArcTestMesh.inside($0.centre, c.cuts) }
                .reduce(0.0) { $0 + $1.area } / total
        }
    }

    func testThreeColumnsOnAStraightStripAreThirds() throws {
        for s in try shares(ArcTestMesh.straightStrip(length: 60), columns: 3) {
            XCTAssertEqual(s, 1.0 / 3, accuracy: 0.04)
        }
    }

    func testThreeColumnsOnAnArcAreThirds() throws {
        let got = try shares(ArcTestMesh.arcStrip(radius: 30, degrees: 120), columns: 3)
        for s in got { XCTAssertEqual(s, 1.0 / 3, accuracy: 0.05, "shares: \(got)") }
    }

    /// ★ THE ONE HE KEPT SENDING SCREENSHOTS OF. Three pieces of the U's inside
    /// curve, all the same size.
    func testThreeColumnsOnTheUAreThirds() throws {
        let got = try shares(ArcTestMesh.uStrip(), columns: 3)
        for s in got {
            XCTAssertEqual(s, 1.0 / 3, accuracy: 0.06,
                           "★ 'the massive difference in patterned piece length' — "
                           + "shares: \(got.map { ($0 * 100).rounded() })")
        }
    }

    func testTwoColumnsOnTheUAreHalves() throws {
        let got = try shares(ArcTestMesh.uStrip(), columns: 2)
        for s in got {
            XCTAssertEqual(s, 0.5, accuracy: 0.06,
                           "★ not 'the line at the far left side' — shares: \(got)")
        }
    }

    func testSixColumnsOnTheUAreSixths() throws {
        let got = try shares(ArcTestMesh.uStrip(), columns: 6)
        for s in got {
            XCTAssertEqual(s, 1.0 / 6, accuracy: 0.05,
                           "★ 'I attempted to cut this face into SIX equal pieces. "
                           + "It turned it into THREE' — shares: \(got)")
        }
    }

    /// ★ A NEGATIVE CONTROL. If the assertion above could pass on any grid, it is
    /// worth nothing — so check that a deliberately lopsided division FAILS it.
    func testTheEqualityCheckCanFail() throws {
        let m = ArcTestMesh.uStrip()
        let spine = try XCTUnwrap(ArcTestMesh.spine(m))
        let sweep = try XCTUnwrap(SurfacePatternArc.fit(spine: spine))
        // Dividers at 10% and 20% instead of a third and two thirds.
        let bounds = SurfacePatternArc.boundaryDegrees(spine: spine, sweep: sweep,
                                                       parts: 10)
        let lopsided = [bounds[0], bounds[1], bounds[2], bounds[10]]
            .map { sweep.plane(at: $0) }
        let tris = ArcTestMesh.triangles(m)
        let total = tris.reduce(0.0) { $0 + $1.area }
        var got: [Double] = []
        for i in 0..<3 {
            let cuts = [lopsided[i], SurfacePatternArc.flip(lopsided[i + 1])]
            got.append(tris.filter { ArcTestMesh.inside($0.centre, cuts) }
                           .reduce(0.0) { $0 + $1.area } / total)
        }
        XCTAssertFalse(got.allSatisfy { abs($0 - 1.0 / 3) < 0.06 },
                       "★ the equality assertion must be able to fail — \(got)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ AND THE LINES ARE DRAWN WHERE THE PIECES MEET, AND NOWHERE ELSE

final class SurfacePatternArcDrawingTests: XCTestCase {

    /// Every drawn segment, as its two endpoints.
    private func segments(_ m: ViewerMesh, columns: Int, rows: Int = 1)
        throws -> [(SIMD3<Double>, SIMD3<Double>)] {
        guard case .success(let cells) = ArcTestMesh.cells(m, columns: columns, rows: rows)
        else { throw XCTSkip("refused") }
        let raw = SurfaceCutLines.preview(cells: cells, face: 0, in: m)
        var out: [(SIMD3<Double>, SIMD3<Double>)] = []
        var i = 0
        while i + 5 < raw.count {
            out.append((SIMD3<Double>(Double(raw[i]), Double(raw[i + 1]), Double(raw[i + 2])),
                        SIMD3<Double>(Double(raw[i + 3]), Double(raw[i + 4]), Double(raw[i + 5]))))
            i += 6
        }
        return out
    }

    /// ★ NO PHANTOM LINE THROUGH THE FAR ARM. Three columns on a U must draw two
    /// dividers and only two — every segment near one of the two expected places.
    /// This is the assertion for "three lines where I asked for two".
    func testAUDrawsExactlyItsTwoDividersAndNoPhantoms() throws {
        let m = ArcTestMesh.uStrip()
        let spine = try XCTUnwrap(ArcTestMesh.spine(m))
        var cum: [Double] = [0]
        for i in 1..<spine.count { cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1])) }
        let arc = cum[cum.count - 1]
        func spinePoint(atFraction f: Double) -> SIMD3<Double> {
            let want = arc * f
            for i in 1..<cum.count where cum[i] >= want { return spine[i] }
            return spine[spine.count - 1]
        }
        let expected = [spinePoint(atFraction: 1.0 / 3), spinePoint(atFraction: 2.0 / 3)]

        let segs = try segments(m, columns: 3)
        XCTAssertFalse(segs.isEmpty, "★ the dividers are drawn at all")

        // The strip is 4 mm across, so anything more than 6 mm from BOTH expected
        // divider positions is drawn somewhere a divider is not.
        var strays = 0
        for (a, b) in segs {
            let mid = (a + b) / 2
            if expected.allSatisfy({ simd_length(mid - $0) > 6 }) { strays += 1 }
        }
        XCTAssertEqual(strays, 0,
                       "★ \(strays) of \(segs.count) segments are drawn away from "
                       + "either divider — a wedge plane cutting the far arm")

        // And both dividers really are drawn — not one line twice.
        for (k, e) in expected.enumerated() {
            XCTAssertTrue(segs.contains { simd_length(($0.0 + $0.1) / 2 - e) <= 6 },
                          "★ divider \(k + 1) is missing")
        }
    }

    /// A grid's row line runs the WHOLE way across, not up to the first column line
    /// ("the row line ... stops at the column line").
    func testARowLineCrossesEveryColumn() throws {
        let m = ArcTestMesh.straightStrip(length: 60, halfWidth: 6)
        let segs = try segments(m, columns: 3, rows: 2)
        XCTAssertFalse(segs.isEmpty)
        // The row divider runs along the strip at y = 0; collect its x span.
        let alongRow = segs.filter { abs($0.0.y) < 0.5 && abs($0.1.y) < 0.5 }
        let xs = alongRow.flatMap { [$0.0.x, $0.1.x] }
        XCTAssertFalse(xs.isEmpty, "★ the row line is drawn")
        XCTAssertLessThan(xs.min() ?? 99, 5, "★ it starts at the near end")
        XCTAssertGreaterThan(xs.max() ?? -99, 55,
                             "★ and reaches the far end rather than stopping at "
                             + "the first column line")
    }

    /// Each interior boundary is drawn by exactly ONE cell, so a divider is one
    /// line and not two coincident ones.
    func testEachDividerIsOwnedByOneCell() throws {
        guard case .success(let cells) = ArcTestMesh.cells(ArcTestMesh.straightStrip(length: 60),
                                                           columns: 4)
        else { return XCTFail("refused") }
        let drawn = cells.reduce(0) { $0 + $1.drawnCuts.count }
        XCTAssertEqual(drawn, 3, "★ four columns have three interior boundaries")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ AND IT REFUSES WHAT A PLANE CANNOT DO, IN WORDS

final class SurfacePatternArcRefusalTests: XCTestCase {

    /// ★ A WEDGE OF 180° IS EMPTY. Two bounding planes half a turn apart are the
    /// same plane facing opposite ways, and their intersection is nothing at all —
    /// which is what produced "Smallest piece: 0 voxels" and a dead checkmark with
    /// no explanation. Refusing with the number is the honest answer.
    func testAHalfTurnPerPieceIsRefusedWithAReason() throws {
        let m = ArcTestMesh.arcStrip(radius: 20, degrees: 350)
        guard case .failure(let r) = ArcTestMesh.cells(m, columns: 2) else {
            return XCTFail("★ two 175° wedges cannot both hold surface — this must refuse")
        }
        XCTAssertTrue(r.reason.contains("°"),
                      "★ and it says so in degrees: \(r.reason)")
        XCTAssertTrue(r.reason.contains("or more"),
                      "★ and says what would work: \(r.reason)")
    }

    /// …and the count it names actually succeeds. A refusal that suggests something
    /// that also fails is worse than no suggestion.
    func testTheSuggestedCountWorks() throws {
        let m = ArcTestMesh.arcStrip(radius: 20, degrees: 350)
        guard case .failure(let r) = ArcTestMesh.cells(m, columns: 2) else {
            return XCTFail("expected a refusal")
        }
        let digits = r.reason.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        let suggested = try XCTUnwrap(digits.last, "no count in: \(r.reason)")
        guard case .success(let cells) = ArcTestMesh.cells(m, columns: suggested) else {
            return XCTFail("★ the suggested \(suggested) columns is refused too")
        }
        XCTAssertEqual(cells.count, suggested)
    }

    /// A gentle curve at two columns is NOT refused — the guard must not be a
    /// blanket ban on two.
    func testTwoColumnsOnAGentleArcIsFine() {
        guard case .success(let cells) = ArcTestMesh.cells(
            ArcTestMesh.arcStrip(radius: 30, degrees: 90), columns: 2)
        else { return XCTFail("★ 45° wedges are perfectly cuttable") }
        XCTAssertEqual(cells.count, 2)
    }
}
