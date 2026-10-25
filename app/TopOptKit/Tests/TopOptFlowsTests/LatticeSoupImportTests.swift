import XCTest
@testable import TopOptKit
@testable import TopOptFlows

/// ★★★ THE LATTICE STL IS A SOUP, AND THE RUN MUST NOT DIE ON IT (2026-08-24).
///
/// Entering the lattice stage on his project ran the on-device lattice job to
/// completion — core certified it and wrote `variant_022_lattice.stl` — and the run
/// then FAILED with "cannot import … the mesh has non-manifold edges that could not
/// be resolved automatically". Measured on that file: 17,172 triangles written twice
/// (two overlapping declared regions each write the sheets they share) and, after
/// perfect dedup, 194 genuine T-junction edges where three sheets meet. No solid
/// repair can disambiguate that, and none needs to: the certification already ran in
/// core, and the mesh is only the picture. The RELATTICE path has always displayed
/// this soup through `MeshExport.parseBinarySTL`; the on-device runner now falls
/// back to the same parse instead of throwing the whole run away.
final class LatticeSoupImportTests: XCTestCase {

    /// A minimal soup with the two defects the real file has: a duplicated triangle
    /// (same winding, written twice) and a T-junction (an edge shared by three).
    private func writeSoupSTL() throws -> String {
        var d = Data(count: 80)                       // header
        func tri(_ a: (Float, Float, Float), _ b: (Float, Float, Float),
                 _ c: (Float, Float, Float), into out: inout Data) {
            for _ in 0..<3 { out.append(contentsOf: withUnsafeBytes(of: Float(0)) { Array($0) }) }
            for p in [a, b, c] {
                out.append(contentsOf: withUnsafeBytes(of: p.0) { Array($0) })
                out.append(contentsOf: withUnsafeBytes(of: p.1) { Array($0) })
                out.append(contentsOf: withUnsafeBytes(of: p.2) { Array($0) })
            }
            out.append(contentsOf: [0, 0])            // attribute byte count
        }
        var body = Data()
        let A: (Float, Float, Float) = (0, 0, 0), B: (Float, Float, Float) = (10, 0, 0)
        let C: (Float, Float, Float) = (0, 10, 0), D: (Float, Float, Float) = (0, 0, 10)
        let E: (Float, Float, Float) = (10, 10, 10)
        tri(A, B, C, into: &body)
        tri(A, B, C, into: &body)                     // duplicated, same winding
        tri(A, B, D, into: &body)
        tri(A, B, E, into: &body)                     // edge A–B now shared by 4
        var count = UInt32(4).littleEndian
        d.append(contentsOf: withUnsafeBytes(of: &count) { Array($0) })
        d.append(body)
        let path = NSTemporaryDirectory() + "/soup-\(UUID().uuidString).stl"
        try d.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The premise of the fallback: core's solid importer refuses this class of
    /// file. If this ever starts SUCCEEDING, the fallback is dead code and the
    /// import path owns the soup — delete the fallback then, not before.
    func testTheSolidImporterRefusesTheSoup() throws {
        let path = try writeSoupSTL()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try TopOptKit.importMesh(path: path))
    }

    /// The fallback pieces: the raw parse reads every triangle of the same file the
    /// solid importer refused, and the outcome built from it carries the job's own
    /// certification verdict, not the mesh's.
    func testTheRawParseCarriesTheSoupIntoTheOutcome() throws {
        let path = try writeSoupSTL()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let raw = MeshExport.parseBinarySTL(try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(raw.indices.count / 3, 4, "all four facets, duplicates included")
        let result = TopOptKit.LatticeJobOutcome(
            meshPaths: [path], reportPath: "", latticeReceiptPath: "",
            latticedVoxels: 288, achievedVolumeFraction: 0.22,
            marginWorstCase: 140.0, graded: true, cellMM: 12.3,
            rhoMinUsed: 0.1, rhoMaxUsed: 0.32, analysisSolves: 3, wallSeconds: 30)
        let outcome = TopOptKit.latticeOutcome(result: result,
                                               meshVertices: raw.vertices,
                                               meshIndices: raw.indices)
        XCTAssertEqual(outcome.variants.count, 1)
        XCTAssertEqual(outcome.variants[0].meshTriangleCount, 4)
        XCTAssertTrue(outcome.variants[0].accepted,
                      "accepted is the certified margin's verdict, not the mesh's")
        XCTAssertEqual(outcome.variants[0].worstCaseMargin, 140.0)
    }
}
