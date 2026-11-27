// PieceKeepClearBridgeTests.swift — E4 (j), ruling 2026-11-07 19:55, on the ON-DEVICE run (the bridge): a Keep clear on a
// CUT piece crosses the bridge by its region, core clears in front of the piece only, and the run's report names the
// piece. The l bracket's bolt hole, cut across half way down: the half-hole's bolt Keep clear forbids fewer voxels than
// the whole hole's, and more than none. A bolt Keep clear on a piece with no round face is refused in core's words.
// Each run is cancelled at its first iteration: the clearances are frozen (and reported) before the solve.
import XCTest
import simd
@testable import TopOptKit

final class PieceKeepClearBridgeTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String { repoRoot.appendingPathComponent("core/\(rel)").path }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var lbracketSTEP: String { core("tests/fixtures/demo/l-bracket.step") }
    /// 64, as core's own test_keep_clear_region: half a bore must clear the sliver guard's 16-voxel floor (at 24 it
    /// holds 2 voxels, at 32 it holds 8).
    private static let res = 64

    /// The l bracket's widest round hole, two flat faces that tag voxels (an anchor and a load, neither the hole), and
    /// the half-hole: region 900 = the hole's face, cut across half way down its axis.
    private func fixture() throws -> (bore: Int, anchor: Int, load: Int, half: TopOptKit.FaceRegionSpec, flat: Int) {
        let mesh = try TopOptKit.importMesh(path: Self.lbracketSTEP)
        let geo = mesh.faceGeometry
        let bore = try XCTUnwrap((0..<geo.count).filter { geo[$0].isCylinder }
                                    .max { geo[$0].cylinderRadiusMM < geo[$1].cylinderRadiusMM },
                                 "premise: the l bracket has a round hole")
        var flat: [Int] = []
        for f in 0..<mesh.faceCount where geo.indices.contains(f) && geo[f].isPlane {
            let n = (try? TopOptKit.tagStepFace(stepPath: Self.lbracketSTEP, faceID: f, asFixture: true,
                                                resolution: Self.res)) ?? 0
            if n > 0 { flat.append(f) }
            if flat.count == 3 { break }
        }
        try XCTSkipIf(flat.count < 3, "need three taggable flat faces on the fixture")
        // the hole's axial span, from its own triangles
        let g = geo[bore]
        let a = simd_normalize(g.axisDir)
        var lo = Double.infinity, hi = -Double.infinity
        for t in 0..<mesh.triangleCount where Int(mesh.faceIDs[t]) == bore {
            for k in 0..<3 {
                let i = Int(mesh.indices[3 * t + k]) * 3
                let p = SIMD3<Double>(Double(mesh.vertices[i]), Double(mesh.vertices[i + 1]), Double(mesh.vertices[i + 2]))
                let s = simd_dot(p - g.axisPoint, a)
                lo = min(lo, s); hi = max(hi, s)
            }
        }
        XCTAssertGreaterThan(hi - lo, 0.5, "premise: the hole has a length")
        let mid = g.axisPoint + a * (lo + hi) / 2
        let half = TopOptKit.FaceRegionSpec(id: 900, addFaces: [bore], cuts: [(point: mid, normal: a, strict: false)])
        return (bore, flat[0], flat[1], half, flat[2])
    }

    private func run(_ fx: (bore: Int, anchor: Int, load: Int, half: TopOptKit.FaceRegionSpec, flat: Int),
                     _ clearances: [TopOptKit.ClearanceSpec], regions: [TopOptKit.FaceRegionSpec]) throws -> OptimizeOutcome {
        try TopOptKit.minimizePlasticLoadCase(
            stepPath: Self.lbracketSTEP, material: "PLA", materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: Self.res, anchorFaceIDs: [fx.anchor],
            loadGroups: [.init(faceIDs: [fx.load], force: SIMD3(0, 0, -5))],
            minimizePlastic: true, clearances: clearances, faceRegions: regions,
            progress: { _, _, iteration in iteration < 1 })
    }

    /// ★ The half-hole keeps clear by its region: the report names the piece, and it forbade less than the whole hole.
    func testAHalfHolesKeepClearClearsOnlyItsHalf() throws {
        let fx = try fixture()
        let margin = 3.0, axial = 2.0
        let whole = try run(fx, [.init(faceID: fx.bore, kind: .bolt, concentricMarginMM: margin, axialClearanceMM: axial)],
                            regions: [])
        let piece = try run(fx, [.piece(regionID: 900, kind: .bolt, concentricMarginMM: margin, axialClearanceMM: axial)],
                            regions: [fx.half])
        let w = try XCTUnwrap(whole.appliedClearances.first, "the whole hole's row")
        XCTAssertEqual(w.regionID, -1, "a face's row names no region")
        XCTAssertGreaterThan(w.voxelsFrozen, 0, "premise: the whole hole's Keep clear forbids material")
        XCTAssertEqual(piece.appliedClearances.count, 1)
        let r = try XCTUnwrap(piece.appliedClearances.first, "★ the piece's row")
        XCTAssertEqual(r.regionID, 900, "★ the report names the piece by its region")
        XCTAssertEqual(r.faceID, -1)
        XCTAssertEqual(r.kind, .bolt)
        XCTAssertTrue(r.inGrid)
        XCTAssertGreaterThan(r.voxelsFrozen, 0, "★ the half-hole keeps clear")
        XCTAssertLessThan(r.voxelsFrozen, w.voxelsFrozen, "★ … only in front of its half (whole \(w.voxelsFrozen))")
    }

    /// ★ A bolt Keep clear on a piece with no round face is refused, in core's words, naming no number.
    func testABoltOnAPieceWithNoRoundFaceIsRefused() throws {
        let fx = try fixture()
        let flatPiece = TopOptKit.FaceRegionSpec(id: 901, addFaces: [fx.flat])
        XCTAssertThrowsError(try run(fx, [.piece(regionID: 901, kind: .bolt)], regions: [flatPiece])) { e in
            let why = "\(e)"
            XCTAssertTrue(why.contains("a bolt Keep clear needs a round hole, and this piece has no round face"), why)
            XCTAssertFalse(why.contains("901"), "never the piece's number: \(why)")
        }
    }
}
