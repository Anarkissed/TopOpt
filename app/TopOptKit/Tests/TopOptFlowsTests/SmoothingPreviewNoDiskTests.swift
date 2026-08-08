// SmoothingPreviewNoDiskTests — A SETTLED STROKE MUST NOT RE-READ THE FILE
// (task 2026-08-08-smoothing-that-works-and-is-usable, S1b / bar R2).
//
// THE DEFECT. `refreshPreview` handed the previewer a PATH, and the bridge behind
// it called `import_any` on that path — a full STL parse — on every settled
// stroke, to rebuild vertices the page was already holding and drawing. On the
// maintainer's own variant that file is 14.4 MB / 164,228 triangles. PR 299
// measured the re-read at 93% of the preview's cost against 7% for the smoothing
// it exists to do.
//
// HOW THIS IS ASSERTED. Not by counting calls, and not by timing: by taking the
// file away. The variant mesh is written, the page is built on it, the file is
// DELETED, and then a stroke is settled. A preview that reads the disk cannot
// survive that; a preview that was handed the geometry does not notice.
//
// AND IT DRIVES THE SHIPPED ENGINE. `SmoothingPageWiring.livePreviewer` is the
// exact value `WorkspacePlaceholder` passes to `SmoothingPageModel`. A test
// against a stand-in previewer would prove nothing at all here, because the
// stand-in is the one thing that definitely does no I/O.

import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

@MainActor
final class SmoothingPreviewNoDiskTests: XCTestCase {

    // MARK: - a variant with enough surface to smooth

    /// A closed icosphere-ish blob: 42 vertices, 80 triangles. Small enough to be
    /// instant, closed enough that the smoother has interior vertices to move.
    private static func blob() -> (verts: [Float], idx: [Int32]) {
        // An octahedron subdivided twice, projected to the sphere.
        var verts: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        var tris: [(Int, Int, Int)] = [
            (0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
            (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
        for _ in 0..<2 {
            var mid: [String: Int] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = a < b ? "\(a)_\(b)" : "\(b)_\(a)"
                if let m = mid[key] { return m }
                let p = simd_normalize((verts[a] + verts[b]) * 0.5)
                verts.append(p)
                mid[key] = verts.count - 1
                return verts.count - 1
            }
            var next: [(Int, Int, Int)] = []
            for t in tris {
                let ab = midpoint(t.0, t.1), bc = midpoint(t.1, t.2), ca = midpoint(t.2, t.0)
                next += [(t.0, ab, ca), (ab, t.1, bc), (ca, bc, t.2), (ab, bc, ca)]
            }
            tris = next
        }
        // Scale to a part-like size so displacements read in millimetres.
        let v = verts.flatMap { [$0.x * 20, $0.y * 20, $0.z * 20] }
        let i = tris.flatMap { [Int32($0.0), Int32($0.1), Int32($0.2)] }
        return (v, i)
    }

    /// BINARY STL, deliberately — it stores float32, which is exactly what
    /// `ViewerMesh` and the bridge carry. An ASCII STL round-trips through
    /// decimal text and comes back differing in the last bits, which would make
    /// the parity test below compare two slightly different meshes and report it
    /// as a difference between the two ROUTES. It is not; it is the file format.
    private func writeSTL(_ g: (verts: [Float], idx: [Int32]), to url: URL) throws {
        var d = Data(count: 80)
        var count = UInt32(g.idx.count / 3)
        withUnsafeBytes(of: &count) { d.append(contentsOf: $0) }
        for t in stride(from: 0, to: g.idx.count, by: 3) {
            for _ in 0..<3 { var z = Float(0); withUnsafeBytes(of: &z) { d.append(contentsOf: $0) } }
            for k in 0..<3 {
                let v = Int(g.idx[t + k]) * 3
                for c in 0..<3 {
                    var f = g.verts[v + c]
                    withUnsafeBytes(of: &f) { d.append(contentsOf: $0) }
                }
            }
            var attr = UInt16(0)
            withUnsafeBytes(of: &attr) { d.append(contentsOf: $0) }
        }
        try d.write(to: url)
    }

    private func page(meshPath: String, geometry g: (verts: [Float], idx: [Int32]))
        -> SmoothingPageModel {
        let ctx = SmoothVariantContext(
            runName: "Bracket", variantIndex: 3, requestedVolumeFraction: 0.32,
            massGrams: 628.9, reportedMargin: 4595.80, accepted: true,
            pageMesh: SmoothPageMesh(path: meshPath, vertices: g.verts, indices: g.idx),
            loadCase: nil, unavailable: nil, modelPath: "/tmp/part.step")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: meshPath, smoothedMeshPath: meshPath + ".out",
            runner: { _ in
                XCTFail("no certification may run for a preview")
                throw TopOptError(message: "unreachable")
            },
            // ★ THE SHIPPED ENGINE, not a stand-in.
            previewer: SmoothingPageWiring.livePreviewer)
    }

    /// A brush with every triangle painted.
    private func fullyPainted(vertexCount: Int, indices: [Int32]) -> SmoothBrushModel {
        var b = SmoothBrushModel(
            indices: indices, vertexCount: vertexCount,
            freeze: SmoothFreezeMask(frozen: [Bool](repeating: false, count: vertexCount),
                                     toleranceMM: 0.75))
        b.addRegion(strength: 0.6)
        b.paint(.add, triangles: (0..<(indices.count / 3)).map { Int32($0) })
        return b
    }

    // MARK: - the bar

    /// ★ DELETE THE FILE, THEN STROKE. The preview must still produce geometry.
    func testAStrokePreviewsWithTheVariantFileDeleted() async throws {
        let g = Self.blob()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smoothing-nodisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appendingPathComponent("variant_068.stl")
        try writeSTL(g, to: stl)

        let p = page(meshPath: stl.path, geometry: g)
        let brush = fullyPainted(vertexCount: g.verts.count / 3, indices: g.idx)

        // PRECONDITION: the page is pointed at a real file, and the preview works
        // while it is there. Without this the test would pass on a page that
        // never previews at all.
        await p.refreshPreview(brush: brush)
        XCTAssertNotNil(p.preview, "precondition: the preview works with the file present")

        // NOW TAKE THE FILE AWAY.
        try FileManager.default.removeItem(at: stl)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stl.path),
                       "precondition: the file is really gone")

        await p.refreshPreview(brush: brush)

        let after = try XCTUnwrap(p.preview,
                                  "the stroke must preview from the geometry the page holds, "
                                  + "not by re-reading an STL")
        XCTAssertGreaterThan(after.movedVertices, 0, "the stroke must actually have moved something")
        XCTAssertEqual(after.secondsImport, 0, accuracy: 0,
                       "no file may be imported for a preview")
    }

    /// ★ THE POSITIVE CONTROL FOR THE BAR ABOVE, AND THE R2 "THE DISK IS READ
    /// TODAY" ASSERTION IN ONE.
    ///
    /// The engine that shipped is `smoothBrushPreview(inputMeshPath:)`. Deleting
    /// the file must BREAK it — if it did not, then the test above would pass
    /// whether or not the preview reads the disk, and would be proving nothing.
    /// This is kept permanently rather than run once against a stashed tree,
    /// because the property it pins ("that route does open the file") is what
    /// makes the property next to it meaningful.
    func testTheRouteThePageUsedToTakeDoesReadTheFile() throws {
        let g = Self.blob()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smoothing-diskproof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appendingPathComponent("variant_068.stl")
        try writeSTL(g, to: stl)

        let present = try TopOptKit.smoothBrushPreview(
            inputMeshPath: stl.path, strength: 0.5, weights: [])
        XCTAssertGreaterThan(present.totalVertices, 0, "precondition: it works with the file there")
        XCTAssertGreaterThan(present.secondsImport, 0,
                             "THE DISK IS READ: the path route spends time importing")

        try FileManager.default.removeItem(at: stl)
        XCTAssertThrowsError(
            try TopOptKit.smoothBrushPreview(inputMeshPath: stl.path, strength: 0.5, weights: []),
            "the path route cannot preview without the file — which is why the page no longer takes it")
    }

    /// The two routes must agree bit for bit, or "we stopped reading the file"
    /// would quietly also mean "we started smoothing something else".
    func testTheInMemoryRouteMatchesTheFileRouteExactly() throws {
        let g = Self.blob()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smoothing-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appendingPathComponent("variant.stl")
        try writeSTL(g, to: stl)

        // The file route must be fed the mesh AS THE IMPORTER SEES IT — an STL is
        // triangle soup and the importer welds it, so the vertex order is its own.
        // Comparing against the pre-write arrays would compare two different
        // meshes and tell us nothing about the two routes.
        let imported = try TopOptKit.importMesh(path: stl.path)
        let n = imported.vertices.count / 3
        let weights = [Double](repeating: 0.8, count: n)

        let viaFile = try TopOptKit.smoothBrushPreview(
            inputMeshPath: stl.path, strength: 0.5, weights: weights)
        let viaMemory = try TopOptKit.smoothBrushPreview(
            vertices: imported.vertices, indices: imported.indices,
            strength: 0.5, weights: weights)

        XCTAssertEqual(viaMemory.meshVertices, viaFile.meshVertices,
                       "the same geometry must smooth to the same bytes either way")
        XCTAssertEqual(viaMemory.meshIndices, viaFile.meshIndices)
        XCTAssertEqual(viaMemory.movedVertices, viaFile.movedVertices)
        XCTAssertGreaterThan(viaFile.movedVertices, 0, "positive control: it smoothed something")

        // …and the split is real: the file route pays an import, the other does not.
        XCTAssertGreaterThan(viaFile.secondsImport, 0, "the file route does read the file")
        XCTAssertEqual(viaMemory.secondsImport, 0, accuracy: 0)
    }

    /// A malformed hand-off must be refused with a message, not indexed past the
    /// end of the vertex array inside the operator.
    func testAnOutOfRangeTriangleIsRefused() {
        let g = Self.blob()
        var bad = g.idx
        bad[0] = Int32(g.verts.count / 3 + 5)
        XCTAssertThrowsError(try TopOptKit.smoothBrushPreview(
            vertices: g.verts, indices: bad, strength: 0.5, weights: []))
    }
}
