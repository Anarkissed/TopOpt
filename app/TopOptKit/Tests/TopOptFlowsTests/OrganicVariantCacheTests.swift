import XCTest
import simd
@testable import TopOptFlows

/// ★ THE TOPOLOGY CACHE (maintainer, 2026-09-04): a beam-lattice 3MF round-trips the
/// emitted spans byte-for-value; the key excludes thickness and includes core's SHA.
final class OrganicVariantCacheTests: XCTestCase {
    private func doc() -> OrganicBeamLattice3MF.Document {
        OrganicBeamLattice3MF.Document(
            spans: [(a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0), r: 0.21),
                    (a: SIMD3(1, 0, 0), b: SIMD3(1, 2.5, 0), r: 0.21),      // shares a vertex
                    (a: SIMD3(1, 2.5, 0), b: SIMD3(1, 2.5, 3.25), r: 0.35)], // a thicker one
            metadata: ["census": "3 struts & <test>", "core": "abc123"])
    }

    func testBeamLatticeRoundTripsSpansRadiiAndMetadata() throws {
        let d = doc()
        let bytes = OrganicBeamLattice3MF.write(d)
        // a real zip with the three 3MF parts
        let parts = try XCTUnwrap(StoredZip.entries(bytes)).map { $0.name }
        XCTAssertEqual(Set(parts), ["[Content_Types].xml", "_rels/.rels", "3D/3dmodel.model"])
        let model = String(decoding: try XCTUnwrap(StoredZip.entries(bytes)?.first { $0.name == "3D/3dmodel.model" }?.data), as: UTF8.self)
        XCTAssertTrue(model.contains(OrganicBeamLattice3MF.beamLatticeNamespace))
        XCTAssertTrue(model.contains("<b:beam v1="), "beams, not triangles")
        XCTAssertEqual(model.components(separatedBy: "<vertex ").count - 1, 4, "shared ends are welded to ONE vertex")
        XCTAssertTrue(model.contains("&lt;test&gt;"), "metadata is escaped")
        let back = try XCTUnwrap(OrganicBeamLattice3MF.read(bytes))
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.totalLengthMM, 1 + 2.5 + 3.25, accuracy: 1e-9)
    }

    func testCRC32MatchesTheKnownVector() {
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    func testTheKeyIgnoresThicknessAndFollowsCoreAndTopology() {
        var s = LatticeSettings(); s.enabled = true; s.stageMode = .aesthetic; s.algorithm = "organic"
        s.densityMode = .sim; s.cellSizeMode = .auto; s.organicShapeFit = true
        let a = OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2), fieldIdentity: "f")
        var thick = s; thick.organicStrutWidthMM = 1.5
        XCTAssertEqual(OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: thick, layerHeightMM: 0.2), fieldIdentity: "f"), a,
                       "★ thickness is live — it must not fork the cache")
        var grown = s; grown.organicGrowth = true
        XCTAssertNotEqual(OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: grown, layerHeightMM: 0.2), fieldIdentity: "f"), a)
        var scaled = s; scaled.organicScale = 1.5
        XCTAssertNotEqual(OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: scaled, layerHeightMM: 0.2), fieldIdentity: "f"), a)
        XCTAssertNotEqual(OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2), fieldIdentity: "g"), a)
        var structural = s; structural.stageMode = .structural
        XCTAssertEqual(OrganicVariantCache.key(picks: OrganicSampleCube.Picks(settings: structural, layerHeightMM: 0.2), fieldIdentity: "f"), a,
                       "★ the stage is not a topology pick for the sample (no allowable stress reaches it)")
        XCTAssertEqual(a.count, 24)
    }

    func testStoreThenLoadFromTheDeviceCache() throws {
        let key = "test-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(at: OrganicVariantCache.cachedURL(for: key)) }
        XCTAssertNil(OrganicVariantCache.load(key: key))
        XCTAssertNotNil(OrganicVariantCache.store(key: key, doc: doc()))
        let hit = try XCTUnwrap(OrganicVariantCache.load(key: key))
        XCTAssertEqual(hit.source, .device)
        XCTAssertEqual(hit.doc, doc())
    }
}
