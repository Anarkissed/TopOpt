// PatternFlatHostedTests — B8 (row 37; the reviewer's 11-09 18:31Z ruling (b)): the Pattern tool on a FLAT face, on the page,
// in Edit faces (Topology's ✂), on his l bracket (a STEP).
//   • The bar reads ✕ │ − n along + │ − n across + │ Rotate ↺ n° ↻ │ ✓: each count the app's number with its − and +, Rotate
//     the Cut bar's own (↺ / ↻ 15°, its number typed). Whole on the screen at 13L and 11P.
//   • The counts are cut lines: 1 along is two pieces; 0 and 0 says "nothing to cut" and ✓ waits.
//   • ✓ splits by the grid the bar shows, turned by Rotate; a newly tapped face starts square to its longest edge (0°).
// A synthesised click never picks a face in the offscreen Metal view, so the test drives the page's own face tap (CutLive).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PatternFlatHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset(); HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    /// His flat faces, the widest first (the most surface to divide).
    static func flats(_ p: ProjectModel, _ m: ViewerMesh) throws -> [FaceID] {
        let areas = FaceRegionGeometry.faceAreas(in: m)
        let out = FaceTopology.faceIDs(in: m).filter { m.faceGeometry($0)?.kind == .plane && p.surfacePatternIsFlat(face: $0) }
            .sorted { (areas[$0] ?? 0) > (areas[$1] ?? 0) }
        XCTAssertGreaterThanOrEqual(out.count, 2, "premise: his l bracket has flat faces")
        return out
    }

    /// The preview's own cuts (every cell's), to hold the split against.
    static func cuts(_ p: ProjectModel, _ f: FaceID, columns: Int, rows: Int, rotate: Double) throws -> [RegionCut] {
        let pv = try XCTUnwrap(p.surfacePatternPreview(face: f, columns: columns, rows: rows, rotationDegrees: rotate))
        XCTAssertTrue(pv.verdict.ok, "premise: \(columns) × \(rows) at \(rotate)° fits")
        return pv.cells.flatMap(\.cuts)
    }

    /// ★ The flat face's bar, whole on the screen, with its counts and Rotate; a hole's has no Rotate.
    func testAFlatFacesBarIsAlongAcrossAndRotate() throws {
        for (name, size) in CutLookHostedTests.sizes {
            let (h, p, m) = try PatternHoleHost.bracket(size, test: self)
            let flat = try XCTUnwrap(Self.flats(p, m).first)
            XCTAssertNil(p.surfacePatternBore(face: flat), "premise: not a bore")
            try PatternHoleHost.pick(h, flat)

            let bar = try h.onScreen("patternBar", "\(name): ★ the flat face's bar")
            XCTAssertGreaterThanOrEqual(bar.minX, 0, "\(name): ★ whole on the screen"); XCTAssertLessThanOrEqual(bar.maxX, size.width)
            _ = try h.probe("patternBarCancel", "\(name): ✕")
            for k in ["patternAlong", "patternAcross", "patternRotate"] {
                let f = try h.onScreen("numberField-\(k)", "\(name): ★ \(k): the app's number (tap to type)")
                XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(name): \(k) is in the bar")
                _ = try h.probe(k + "Minus", "\(name): ★ \(k)'s −"); _ = try h.probe(k + "Plus", "\(name): ★ \(k)'s +")
            }
            for k in ["numberField-patternAround", "numberField-patternDown"] {
                XCTAssertNil(h.frames.all[k], "\(name): ★ no hole words on a flat face")
            }

            // a hole's bar has no Rotate (its lines hang on its own axis)
            try PatternHoleHost.pick(h, try PatternHoleHost.widestBore(m))
            _ = try h.onScreen("numberField-patternAround", "\(name): the hole's bar")
            XCTAssertNil(h.frames.all["numberField-patternRotate"], "\(name): ★ no Rotate on a hole")
        }
    }

    /// ★ The counts are cut lines and Rotate turns the grid: 1 along at ↻ 15° is two pieces, cut where the bar's grid is.
    func testOneLineAlongTurnedFifteenSplitsByThatGrid() throws {
        let (h, p, m) = try PatternHoleHost.bracket(AppBuildHost.landscape13, test: self)
        let flat = try XCTUnwrap(Self.flats(p, m).first)
        try PatternHoleHost.pick(h, flat)
        _ = try h.onScreen("patternBar", "the bar")
        try PatternHoleHost.step(h, "patternAlong", from: PatternGrid.defaultAlong, to: 1, "1 along")
        try h.tap("patternRotatePlus", "↻ 15°")
        h.pump(0.3)
        let want = try Self.cuts(p, flat, columns: 2, rows: 1, rotate: 15)
        let square = try Self.cuts(p, flat, columns: 2, rows: 1, rotate: 0)
        XCTAssertNil(h.frames.all["patternBarLine"], "it fits: no line")
        let before = Set(p.faceRegions.regions.map(\.id))
        try h.tap("patternBarOK", "✓")

        let (kids, made) = PatternHoleHost.newCuts(p, before: before)
        XCTAssertEqual(kids.count, 2, "★ 1 line along: two pieces")
        XCTAssertFalse(made.isEmpty)
        for c in made { XCTAssertTrue(want.contains(c), "★ the split is the bar's grid, turned 15°: \(c)") }
        let a = simd_normalize(try XCTUnwrap(made.first).normal), b = simd_normalize(try XCTUnwrap(square.first).normal)
        XCTAssertEqual(acos(Swift.min(1, abs(simd_dot(a, b)))) * 180 / .pi, 15, accuracy: 0.01, "★ turned 15° from square")
        XCTAssertNil(h.frames.all["patternBar"], "the bar goes with the split made")
    }

    /// ★ "starting square to the longest edge": a turn on one face does not follow to the next face tapped.
    func testANewFaceStartsSquareToItsLongestEdge() throws {
        let (h, p, m) = try PatternHoleHost.bracket(AppBuildHost.landscape13, test: self)
        let fl = try Self.flats(p, m)
        let (a, b) = (fl[0], fl[1])
        try PatternHoleHost.pick(h, a)
        try h.tap("patternRotatePlus", "↻ 15°"); try h.tap("patternRotatePlus", "↻ 30°")
        try PatternHoleHost.pick(h, b)
        try PatternHoleHost.pick(h, a)
        try PatternHoleHost.step(h, "patternAlong", from: PatternGrid.defaultAlong, to: 1, "1 along")
        let square = try Self.cuts(p, a, columns: 2, rows: 1, rotate: 0)
        let before = Set(p.faceRegions.regions.map(\.id))
        try h.tap("patternBarOK", "✓")
        let (_, made) = PatternHoleHost.newCuts(p, before: before)
        XCTAssertFalse(made.isEmpty)
        for c in made { XCTAssertTrue(square.contains(c), "★ back to 0°: square to its longest edge") }
    }

    /// ★ P5: 0 along and 0 across is nothing to cut, and ✓ waits.
    func testNoLinesIsNothingToCut() throws {
        let (h, p, m) = try PatternHoleHost.bracket(AppBuildHost.landscape13, test: self)
        let flat = try XCTUnwrap(Self.flats(p, m).first)
        try PatternHoleHost.pick(h, flat)
        try PatternHoleHost.step(h, "patternAlong", from: PatternGrid.defaultAlong, to: 0, "0 along")
        XCTAssertEqual(p.surfacePatternPreview(face: flat, columns: 1, rows: 1)?.verdict.reason, PatternHole.nothingToCut)
        _ = try h.onScreen("patternBarLine", "★ 0 × 0: \"nothing to cut\"")
        _ = try h.onScreen("patternBarOK-off", "★ … and ✓ waits")
        let count = p.faceRegions.regions.count
        try h.tap("patternBarOK-off", "✓ while it waits")
        XCTAssertEqual(p.faceRegions.regions.count, count, "★ nothing is cut")
        try PatternHoleHost.step(h, "patternAcross", from: 0, to: 1, "1 across")
        XCTAssertNil(h.frames.all["patternBarLine"], "a line across is something to cut")
        _ = try h.onScreen("patternBarOK", "✓ is ready")
    }
}
#endif
