// PatternHoleHostedTests — B8 (row 37; plan §B8 PatternDownHole / PatternZero; N1, P5; mockup #cut-pattern,
// #cut-pattern-zero, #cut-pattern-none): the Pattern tool on a hole, on the page, in Edit faces (Topology's ✂), on his
// l bracket (a STEP with bolt holes).
//   • PatternDownHole: on a hole the bar reads ✕ │ − n around + │ − n down the hole + │ ✓ (each count the app's number, with
//     its − and +); ✓ splits the bore so its rows run down its axis: every ring stands square to the bore, every line holds
//     its axis. A flat face keeps its grid's own bar until the reviewer's answer on it.
//   • PatternZero: 0 around is rings only; both 0 says "nothing to cut" and ✓ waits.
// A synthesised click never picks a face in the offscreen Metal view, so the test drives the page's own face tap (CutLive).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum PatternHoleHost {

    /// His 'l bracket 3' (S0's 92A8016E, frozen), through the app's own import, on the page at Topology, in Edit faces with
    /// Pattern armed.
    static func bracket(_ size: CGSize, test: XCTestCase) throws -> (AppBuildHost, ProjectModel, ViewerMesh) {
        let dir = FlexiblePressFixtures.frozenDir.appendingPathComponent("his7/92A8016E-FCCD-421D-B19E-4A1EC81C98A5", isDirectory: true)
        try FlexiblePressFixtures.assertFrozen(dir)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pattern-hole-\(UUID().uuidString)", isDirectory: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           rulesPath: core.appendingPathComponent("src/settings/rules.json").path, store: ProjectStore(rootDir: root))
        app.loadMaterials()
        app.newTopOpt()
        guard app.importFile(atPath: dir.appendingPathComponent("model.step").path, displayName: "l bracket 3.step") else {
            throw XCTSkip("the STEP importer refused the l bracket: \(app.toast ?? "")")
        }
        app.continueToWorkspace()
        let p = try XCTUnwrap(app.project, "the bracket opens")
        p.force.setGravity(direction: SIMD3(0, 0, -1))
        let h = AppBuildHost(ParityRoot(model: app), size: size, test: test)
        h.pump(3)
        try h.tap("capsuleScissors", "\(size): Topology's ✂")
        h.pump(1)
        try h.tap("cutTool-Pattern", "\(size): the rail's Pattern")
        h.pump(0.5)
        return (h, p, try XCTUnwrap(p.viewerMesh, "the bracket's mesh"))
    }

    /// His widest bore (the most surface to divide).
    static func widestBore(_ m: ViewerMesh) throws -> FaceID {
        let areas = FaceRegionGeometry.faceAreas(in: m)
        return try XCTUnwrap(FaceTopology.faceIDs(in: m).filter { FaceTopology.isFastenerBore($0, in: m) }
            .max { (areas[$0] ?? 0) < (areas[$1] ?? 0) }, "premise: his l bracket has bolt holes")
    }

    static func pick(_ h: AppBuildHost, _ f: FaceID) throws {
        let pick = try XCTUnwrap(CutLive.pick, "★ the page's face tap (Edit faces)")
        pick(f)
        h.pump(0.8)
    }

    /// Steps a count on the bar from `from` to `to` with its − / +.
    static func step(_ h: AppBuildHost, _ key: String, from: Int, to: Int, _ what: String) throws {
        guard from != to else { return }
        for _ in 0..<abs(to - from) { try h.tap(key + (to < from ? "Minus" : "Plus"), what) }
        h.pump(0.3)
    }

    /// The new pieces' own cuts (the bore's region had none of its own before).
    static func newCuts(_ p: ProjectModel, before: Set<RegionID>) -> (kids: [FaceRegion], cuts: [RegionCut]) {
        // the split's pieces (a face with no region of its own gets one first, which has no cuts)
        let kids = p.faceRegions.regions.filter { !before.contains($0.id) && !$0.cuts.isEmpty }
        var cuts: [RegionCut] = []
        for k in kids {
            let parent = p.faceRegions.region(k.parentID)?.cuts ?? []
            cuts += k.cuts.filter { !parent.contains($0) }
        }
        return (kids, cuts)
    }
}

@MainActor
final class PatternDownHoleHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset(); HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    /// ★ PatternDownHole: on a hole, the bar is around │ down the hole, and the rows run down the bore's axis.
    func testOnAHoleTheBarIsAroundAndDownAndTheRowsRunDownItsAxis() throws {
        for (name, size) in CutLookHostedTests.sizes {
            let (h, p, m) = try PatternHoleHost.bracket(size, test: self)
            let bore = try PatternHoleHost.widestBore(m)
            let b = try XCTUnwrap(p.surfacePatternBore(face: bore), "\(name): ★ a hole is a bore to the pattern")
            try PatternHoleHost.pick(h, bore)

            let bar = try h.onScreen("patternBar", "\(name): ★ the hole's bar")
            XCTAssertGreaterThanOrEqual(bar.minX, 0, "\(name): on the screen"); XCTAssertLessThanOrEqual(bar.maxX, size.width)
            _ = try h.probe("patternBarCancel", "\(name): ✕")
            for k in ["patternAround", "patternDown"] {
                let f = try h.onScreen("numberField-\(k)", "\(name): ★ \(k): the app's number (tap to type)")
                XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(name): \(k) is in the bar")
                _ = try h.probe(k + "Minus", "\(name): ★ \(k)'s −"); _ = try h.probe(k + "Plus", "\(name): ★ \(k)'s +")
            }

            // the most pieces the run holds on this bore, up to 4 around × 2 down, with a line and a ring at least
            let fit = [(4, 2), (4, 1), (3, 1), (2, 1)].first {
                p.surfacePatternPreview(face: bore, around: $0.0, down: $0.1)?.verdict.ok == true
            }
            let (a, d) = try XCTUnwrap(fit, "\(name): premise: his widest bore holds 2 around × 1 down at the run's size")
            try PatternHoleHost.step(h, "patternAround", from: PatternHole.defaultAround, to: a, "\(name): around")
            try PatternHoleHost.step(h, "patternDown", from: PatternHole.defaultDown, to: d, "\(name): down the hole")
            XCTAssertNil(h.frames.all["patternBarLine"], "\(name): \(a) × \(d) fits: no line")
            let before = Set(p.faceRegions.regions.map(\.id))
            try h.tap("patternBarOK", "\(name): ✓")

            let (kids, cuts) = PatternHoleHost.newCuts(p, before: before)
            XCTAssertEqual(kids.count, PatternHole.pieces(b, around: a, down: d), "\(name): ★ \(a) around × \(d) down")
            var rings = 0, lines = 0
            for c in cuts {
                let n = simd_normalize(c.normal), along = abs(simd_dot(n, b.axis))
                if along > 1 - 1e-6 { rings += 1; continue }
                XCTAssertEqual(along, 0, accuracy: 1e-6, "\(name): ★ a cut is a ring square to the bore or a line along it")
                XCTAssertEqual(simd_dot(b.centre - c.point, n), 0, accuracy: 1e-6, "\(name): ★ a line holds the bore's axis")
                lines += 1
            }
            XCTAssertGreaterThan(rings, 0, "\(name): ★ the rows run down the bore's axis (its rings stand square to it)")
            XCTAssertGreaterThan(lines, 0, "\(name): the columns run round it")
            XCTAssertNil(h.frames.all["patternBar"], "\(name): the bar goes with the split made")
        }
    }

    /// A flat face keeps its own grid's bar (until the reviewer's answer on a flat face's bar).
    func testAFlatFaceKeepsItsGridsBar() throws {
        let (h, p, m) = try PatternHoleHost.bracket(AppBuildHost.landscape13, test: self)
        let flat = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { m.faceGeometry($0)?.kind == .plane }, "a flat face")
        XCTAssertNil(p.surfacePatternBore(face: flat), "★ a flat face is not a bore")
        try PatternHoleHost.pick(h, flat)
        XCTAssertNil(h.frames.all["patternBar"], "★ no hole bar on a flat face")
    }
}

@MainActor
final class PatternZeroHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { CutLive.recordLive = true; HardwareKeyboard.override = false }
    }

    override func tearDown() async throws {
        await MainActor.run { CutLive.reset(); HardwareKeyboard.override = nil }
        try await super.tearDown()
    }

    /// ★ P5: 0 around is rings only; both 0 is nothing to cut, and ✓ waits.
    func testZeroAroundIsRingsOnlyAndBothZeroIsNothingToCut() throws {
        let (h, p, m) = try PatternHoleHost.bracket(AppBuildHost.landscape13, test: self)
        let bore = try PatternHoleHost.widestBore(m)
        let b = try XCTUnwrap(p.surfacePatternBore(face: bore))
        try PatternHoleHost.pick(h, bore)
        _ = try h.onScreen("patternBar", "the hole's bar")

        // ★ both 0: the bar says so, and ✓ waits
        try PatternHoleHost.step(h, "patternAround", from: PatternHole.defaultAround, to: 0, "around")
        try PatternHoleHost.step(h, "patternDown", from: PatternHole.defaultDown, to: 0, "down the hole")
        XCTAssertEqual(p.surfacePatternPreview(face: bore, around: 0, down: 0)?.verdict.reason, PatternHole.nothingToCut)
        _ = try h.onScreen("patternBarLine", "★ both 0: \"nothing to cut\"")
        _ = try h.onScreen("patternBarOK-off", "★ … and ✓ waits")
        XCTAssertNil(h.frames.all["patternBarOK"], "✓ is not ready")
        let count = p.faceRegions.regions.count
        try h.tap("patternBarOK-off", "✓ while it waits")
        XCTAssertEqual(p.faceRegions.regions.count, count, "★ nothing is cut")
        XCTAssertNotNil(h.frames.all["patternBar"], "the bar stays")

        // ★ 0 around: rings only
        try PatternHoleHost.step(h, "patternDown", from: 0, to: 1, "one ring")
        XCTAssertNil(h.frames.all["patternBarLine"], "a ring is something to cut")
        let before = Set(p.faceRegions.regions.map(\.id))
        try h.tap("patternBarOK", "✓")
        let (kids, cuts) = PatternHoleHost.newCuts(p, before: before)
        XCTAssertEqual(kids.count, 2, "★ 0 around × 1 down: two pieces")
        XCTAssertFalse(cuts.isEmpty)
        for c in cuts {
            XCTAssertEqual(abs(simd_dot(simd_normalize(c.normal), b.axis)), 1, accuracy: 1e-6, "★ 0 around: every cut is a ring")
        }
    }
}
#endif
