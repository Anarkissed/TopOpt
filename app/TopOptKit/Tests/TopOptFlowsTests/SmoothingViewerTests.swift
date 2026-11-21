// SmoothingViewerTests — V1/V2/V3 of task 2026-08-04-smoothing-viewer-and-ui.
//
// THE REPORT. The maintainer painted, pressed Re-certify, and the shape on screen
// did not change. Every number on the receipt moved except "mass (mesh)", so the
// reasonable reading was that the certification had solved the ORIGINAL shape.
//
// IT HAD NOT. The smoothed mesh is produced (core writes it), returned (the
// bridge runner imports it back into `CertifyOutcome.meshVertices`), and bound
// (`SmoothingPageModel.currentGeometry` → `smoothedVariantMesh` → `stageMesh`).
// The break is one step further down, in the RENDERER: `MetalMeshView` re-uploads
// its GPU buffers only when a signature changes, and that signature was
// `(vertexCount, triangleCount, bounds.min, bounds.max)`.
//
// Taubin smoothing preserves the welded topology exactly — same vertices, same
// triangles — and a LOCAL brush moves only the painted patch, so the bounding box
// is decided by vertices that never moved. The signature therefore could not see
// the smoothing at all, and the renderer went on drawing the mesh it already had.
//
// `smooth_viewer_identity_probe` measured it on the maintainer's own bracket:
//
//   patch      str  painted  moved  maxshift  cnt+bounds  content
//   corner    1.00     1692   1692    0.8314  differs     differs
//   interior  1.00       23     23    0.5927  IDENTICAL   differs
//
// — so the old signature was not merely weak, it was CONDITIONAL: it separated
// the two meshes only when the brush happened to reach the part's own outermost
// corner. Brushing the middle of the part, which is the whole point of a brush,
// showed nothing.
//
// These tests are written so that they FAIL against the shipped code: each one
// asserts the old tuple is blind on the same data where the new signature is not,
// so the negative control travels with the fix instead of being a claim about it.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SmoothingViewerTests: XCTestCase {

    // MARK: - the two meshes, and the tuple that could not tell them apart

    /// A slab with eight corners and one interior vertex. The corners are what the
    /// bounding box is made of; the interior vertex is what a local brush moves.
    /// This is the maintainer's geometry in miniature.
    private let originalVertices: [Float] = [
        -10, -10, 0,   10, -10, 0,   10, 10, 0,   -10, 10, 0,
        -10, -10, 4,   10, -10, 4,   10, 10, 4,   -10, 10, 4,
          0,   0, 4,                                     // the interior vertex
    ]
    private let meshIndices: [Int32] = [
        0, 1, 2,  0, 2, 3,
        4, 5, 8,  5, 6, 8,  6, 7, 8,  7, 4, 8,
        0, 1, 5,  0, 5, 4,
    ]

    /// The same mesh after a local smoothing: ONLY the interior vertex moved, and
    /// it moved INWARD, so every bounding plane is untouched. Nothing here is
    /// contrived to defeat the old signature — it is what constrained smoothing
    /// does, and it is what the probe measured on the real part.
    private var smoothedVertices: [Float] {
        var v = originalVertices
        v[8 * 3 + 2] = 3.4     // 4.0 → 3.4: the melt, 0.6 mm, entirely interior
        return v
    }

    private func mesh(_ vertices: [Float]) -> ViewerMesh {
        ViewerMesh(vertices: vertices, indices: meshIndices, faceIDs: [],
                   smoothShaded: true)
    }

    /// THE SIGNATURE THAT SHIPPED, reproduced verbatim from `MetalMeshView`'s own
    /// `meshSignature` before this task. Kept here as the negative control: every
    /// assertion below that the new signature separates two meshes is paired with
    /// the demonstration that this one did not.
    private func shippedSignature(_ m: ViewerMesh) -> [Float] {
        [Float(m.vertexCount), Float(m.triangleCount),
         m.bounds.min.x, m.bounds.min.y, m.bounds.min.z,
         m.bounds.max.x, m.bounds.max.y, m.bounds.max.z]
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V1 — WHY THE VIEWER DID NOT SHOW THE SMOOTHED MESH
    // ═══════════════════════════════════════════════════════════════════════

    /// THE BUG, PINNED. On a local smoothing the old tuple is identical in all
    /// eight components, so `updateUIView` took its early-out and the GPU kept the
    /// original vertex buffer. If this ever starts failing, the negative control
    /// has stopped describing the defect and the test below has stopped being
    /// load-bearing.
    func testTheShippedSignatureCannotSeeALocalSmoothing() {
        let before = mesh(originalVertices)
        let after = mesh(smoothedVertices)

        XCTAssertNotEqual(before.positions, after.positions,
                          "the fixture must actually differ, or nothing is proven")
        XCTAssertEqual(before.vertexCount, after.vertexCount)
        XCTAssertEqual(before.triangleCount, after.triangleCount)
        XCTAssertEqual(before.bounds.min, after.bounds.min,
                       "a local brush does not move the bounding box")
        XCTAssertEqual(before.bounds.max, after.bounds.max)
        XCTAssertEqual(shippedSignature(before), shippedSignature(after),
                       "V1: this is the defect — the shipped signature is blind "
                       + "to a smoothing that moved the interior of the part")
    }

    /// THE FIX. The same two meshes, separated.
    func testTheContentSignatureSeparatesThem() {
        XCTAssertNotEqual(mesh(originalVertices).signature,
                          mesh(smoothedVertices).signature,
                          "V1: the viewer must re-upload when the geometry moves")
    }

    /// A moved vertex is not the only way a mesh changes: re-winding a triangle
    /// leaves every position AND the bounding box untouched. The signature covers
    /// the index buffer too.
    func testTheSignatureCoversTheIndexBufferAsWell() {
        let a = ViewerMesh(vertices: originalVertices, indices: meshIndices,
                           faceIDs: [])
        var flipped = meshIndices
        flipped.swapAt(0, 1)
        let b = ViewerMesh(vertices: originalVertices, indices: flipped, faceIDs: [])
        XCTAssertEqual(shippedSignature(a), shippedSignature(b),
                       "the old tuple could not see this either")
        XCTAssertNotEqual(a.signature, b.signature)
    }

    /// B6. The signature is a cache key, so it must be the same on every launch.
    /// Swift's `Hasher` is seeded per process and would silently defeat that —
    /// asserted here by value and, below, by reading the source.
    func testTheSignatureIsDeterministic() {
        let a = ViewerMeshSignature(vertices: originalVertices, indices: meshIndices)
        let b = ViewerMeshSignature(vertices: originalVertices, indices: meshIndices)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.contentHash, b.contentHash)
        // A fixed expected value would pin the constant across launches, but this
        // test runs in ONE process — the cross-launch property is what the source
        // read below establishes.
        XCTAssertEqual(mesh(originalVertices).signature, a)
        XCTAssertEqual(ViewerMeshSignature.empty,
                       ViewerMeshSignature(vertices: [], indices: []))
    }

    func testTheSignatureDoesNotUseAProcessSeededHasher() throws {
        let src = try codeOnly(sourceURL("ViewerMesh.swift"))
        let sig = try body(of: "public struct ViewerMeshSignature", in: src)
        XCTAssertFalse(sig.contains("Hasher("),
                       "B6: a per-process seed would re-sign the same mesh "
                       + "differently on every launch")
        XCTAssertFalse(sig.contains("hashValue"))
        XCTAssertTrue(sig.contains("1099511628211"), "the FNV prime, fixed")
    }

    /// THE SHIPPING PATH (bar B1). It is not enough that a better signature
    /// exists — the renderer has to be the thing consuming it. `meshSignature` is
    /// what `updateUIView` compares, so this reads it: it must resolve to the
    /// mesh's own signature and must no longer mention the bounds.
    func testTheRendererGatesOnTheContentSignature() throws {
        let src = try codeOnly(sourceURL("MetalMeshView.swift"))
        let fn = try body(of: "private func meshSignature", in: src)
        XCTAssertTrue(fn.contains("mesh.signature"),
                      "V1: the renderer must gate on the mesh's own contents")
        XCTAssertFalse(fn.contains("bounds"),
                       "V1: the bounding box is exactly what could not see a "
                       + "local smoothing")
        XCTAssertFalse(fn.contains("vertexCount"),
                       "counts ride inside the signature; naming them here would "
                       + "be a second definition of the same key")
        // And the comparison site still exists — a signature nothing compares is
        // not a fix.
        XCTAssertTrue(src.contains("sig != appliedSignature"))
    }

    // ★ B4: the Smooth page and its viewer seam (V3) are deleted with the page (plan.md §B4); the renderer's content
    // signature above still guards every mesh swap (Results' versions, the lattice page).

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TopOptFlowsTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // TopOptKit
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }

    /// Source with `//` comments stripped, so an assertion is about what the code
    /// can REACH rather than about what the prose mentions.
    private func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// The brace-balanced body of the declaration starting with `header`.
    private func body(of header: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: header),
                                  "declaration not found: \(header)")
        var depth = 0
        var started = false
        var out = ""
        for ch in source[start.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { out.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 && started { break }
            }
        }
        XCTAssertFalse(out.isEmpty, "empty body for \(header)")
        return out
    }
}
