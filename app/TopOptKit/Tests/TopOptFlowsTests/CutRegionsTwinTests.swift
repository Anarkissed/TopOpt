// CutRegionsTwinTests — B8, the reviewer's ruling of 11-08 21:32Z (item 1): "Before the Regions sheet goes, one test must show
// that each of its functions (filter, union, grid split) has a rail twin. If one doesn't, keep that function reachable and tell
// me." On his l bracket (S0's 92A8016E, frozen: a STEP with bolt holes), through the model calls each surface makes:
//   • union — the sheet's Combine and the rail's Similar → Union ✓ join the same faces (twin; the sheet's union also keeps its
//     rule, so a CAD change is reported as drift — the rail's is the faces it joined);
//   • grid split — the sheet's Split and the rail's Pattern are one operation, N × M pieces (twin);
//   • filter — Similar is its twin for "Bores of one size" only. "Fillets & chamfers" is reached a tap per kind and radius (a
//     round fillet's Similar rule is a bore's: cylinders of its radius), not as one rule; "Small faces" (every face under a size,
//     any kind, any neighbours) not at all: Similar's rule is always a kind or a blend's neighbours. So the Regions sheet stays
//     reachable in Cut (CutFootHostedTests), and the reviewer is told.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class CutRegionsTwinTests: XCTestCase {

    private func bracket(_ test: String) throws -> (ProjectModel, ViewerMesh) {
        let p = try FlexiblePressFixtures.lBracketProject(test)
        return (p, try XCTUnwrap(p.viewerMesh, "the bracket's mesh"))
    }

    /// The faces Similar picks for a tap on `seed` (the tool's own rule: `surfaceSimilarFilter`, matched on the mesh).
    private func similar(_ p: ProjectModel, _ m: ViewerMesh, seed: FaceID) throws -> Set<FaceID> {
        Set(FaceRegionGeometry.match(try XCTUnwrap(p.surfaceSimilarFilter(to: seed), "Similar's rule for face \(seed)"), in: m))
    }

    /// A bolt hole of the bracket and its radius.
    private func bore(_ m: ViewerMesh) throws -> (FaceID, Double) {
        let f = try XCTUnwrap(FaceTopology.faceIDs(in: m).first {
            m.faceGeometry($0)?.kind == .cylinder && (m.faceGeometry($0)?.cylinderRadiusMM ?? 0) > 0
        }, "premise: the bracket has a bolt hole")
        return (f, try XCTUnwrap(m.faceGeometry(f)).cylinderRadiusMM)
    }

    private func sheet(_ p: ProjectModel, _ m: ViewerMesh, _ regions: FaceRegionModel, preset: FaceRegionSheetModel.Preset,
                       boreRadiusMM: Double = 0) -> FaceRegionSheetModel {
        var s = FaceRegionSheetModel()
        s.preset = preset
        s.boreRadiusMM = boreRadiusMM
        s.refresh(mesh: m, resolution: p.quality.resolution, model: regions, selectedRegion: nil)
        return s
    }

    /// ★ Union: the sheet's Combine (on "Bores of one size") and the rail's chain — Similar on one bore, its pick carried into
    /// Union, ✓ — join the same faces into one region.
    func testTheSheetsUnionHasARailTwin() throws {
        let (p, m) = try bracket(#function)
        let (seed, r) = try bore(m)
        var sheetRegions = p.faceRegions
        let s = sheet(p, m, sheetRegions, preset: .bores, boreRadiusMM: r)
        XCTAssertGreaterThanOrEqual(s.matched.count, 2, "premise: the bracket has more than one bolt hole of its size")
        let combined = sheetRegions.union(faces: s.matched, named: s.preset.title, filter: s.filter, matchedAtAuthor: s.matched.count)
        let sheetFaces = Set(FaceRegionGeometry.members(of: try XCTUnwrap(sheetRegions.region(combined)), in: m))

        var u = SurfaceUnion()
        for f in try similar(p, m, seed: seed).sorted() { if let piece = p.surfaceEnsureRegion(for: f) { u.toggle(piece) } }
        let joined = try XCTUnwrap(p.commitSurfaceUnion(u), "★ the rail's Union joins Similar's pick")
        XCTAssertEqual(Set(p.surfaceResolvedFaces(joined)), sheetFaces, "★ the same faces, in one region")
        // the one difference, said in the report: the sheet's union keeps its rule; the rail's is the faces it joined
        XCTAssertTrue(try XCTUnwrap(sheetRegions.region(combined)).filter.any, "the sheet's union keeps its rule (drift is reported)")
        XCTAssertFalse(try XCTUnwrap(p.faceRegions.region(joined)).filter.any, "the rail's union is the faces it joined")
    }

    /// ★ Grid split: the sheet's Split and the rail's Pattern are one operation (`FaceRegionModel.splitGrid`) — 2 × 2 on the
    /// bracket's largest flat face makes four pieces either way.
    func testGridSplitHasARailTwin() throws {
        let (p, m) = try bracket(#function)
        let areas = FaceRegionGeometry.faceAreas(in: m)
        let face = try XCTUnwrap(FaceTopology.faceIDs(in: m).filter { m.faceGeometry($0)?.kind == .plane }
            .max { (areas[$0] ?? 0) < (areas[$1] ?? 0) }, "premise: a flat face")

        var sheetRegions = p.faceRegions
        let rid = sheetRegions.union(faces: [face], named: "Face \(face)")
        var s = FaceRegionSheetModel()
        s.gridN = 2; s.gridM = 2
        s.refresh(mesh: m, resolution: p.quality.resolution, model: sheetRegions, selectedRegion: rid)
        let region = try XCTUnwrap(sheetRegions.region(rid))
        XCTAssertTrue(try XCTUnwrap(s.gridPreview(of: region, in: m)).verdict.ok, "premise: the sheet's 2 × 2 clears the floor")
        let sheetPieces = sheetRegions.splitGrid(rid, cells: s.gridCells(of: region, in: m))
        let railPieces = p.commitSurfacePattern(face: face, columns: 2, rows: 2)
        XCTAssertEqual(sheetPieces.count, 4, "the sheet's Split: 2 × 2")
        XCTAssertEqual(railPieces.count, 4, "★ the rail's Pattern: the same 2 × 2")
    }

    /// ★ The filter: Similar is its twin for "Bores of one size" (one tap, the same faces); "Fillets & chamfers" only in part
    /// (Similar on a round fillet asks for cylinders of its radius — a bore's rule — so the sheet's one blend rule takes a tap per
    /// kind and radius, and a bore of that radius comes along); and never for "Small faces": no tap anywhere on the part gives
    /// Similar a rule by size alone (any kind, any neighbours).
    func testTheFilterHasARailTwinForBoresOnly() throws {
        let (p, m) = try bracket(#function)
        // bores: one tap
        let (seed, r) = try bore(m)
        let bores = sheet(p, m, p.faceRegions, preset: .bores, boreRadiusMM: r)
        XCTAssertEqual(try similar(p, m, seed: seed), Set(bores.matched), "★ Bores of one size: Similar on a bore picks the same faces")
        // fillets & chamfers: every face the sheet catches is reachable by Similar's taps, but not as the sheet's one rule
        let blends = sheet(p, m, p.faceRegions, preset: .blends)
        var rules: [RegionFilter] = []
        for b in blends.matched {
            let rule = try XCTUnwrap(p.surfaceSimilarFilter(to: b), "Similar's rule for face \(b)")
            XCTAssertTrue(Set(FaceRegionGeometry.match(rule, in: m)).contains(b), "face \(b) is reachable by a Similar tap on it")
            if !rules.contains(rule) { rules.append(rule) }
        }
        print("CutRegionsTwinTests: Fillets & chamfers catches \(blends.matched.count) faces; Similar needs \(rules.count) taps "
              + "(rules: \(rules.map { $0.cylinderRadiusMM > 0 ? "cylinder r \($0.cylinderRadiusMM)" : $0.minLargerNeighbours > 0 ? "blend" : "kind \($0.kind)" }))")
        // small faces: no twin
        let small = sheet(p, m, p.faceRegions, preset: .small)
        XCTAssertFalse(small.matched.isEmpty, "premise: the bracket has small faces")
        for f in FaceTopology.faceIDs(in: m) {
            guard let rule = p.surfaceSimilarFilter(to: f) else { continue }
            let bySizeAlone = rule.kind.isEmpty && rule.minLargerNeighbours == 0 && rule.cylinderRadiusMM == 0
            XCTAssertFalse(bySizeAlone, "★ Small faces has no rail twin: Similar on face \(f) asks \(rule)")
        }
    }
}
