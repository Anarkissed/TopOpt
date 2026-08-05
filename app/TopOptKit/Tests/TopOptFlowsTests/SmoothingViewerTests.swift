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

    // ═══════════════════════════════════════════════════════════════════════
    // V3 — THE SMOOTHED VIEW DIFFERS FROM ORIGINAL AFTER RE-CERTIFY
    // ═══════════════════════════════════════════════════════════════════════

    /// The shipping seam, end to end through the page model: re-certify, then take
    /// `currentGeometry` — the ONE property the host builds `smoothedVariantMesh`
    /// from and `stageMesh` reads — and check that the mesh the viewer would be
    /// handed is a different mesh from the one it is showing.
    func testTheSmoothedViewMeshDiffersFromOriginalAfterRecertify() async throws {
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        let page = self.page(runner)

        let atRest = page.currentGeometry
        XCTAssertFalse(atRest.smoothed, "nothing smoothed yet")
        let originalMesh = mesh(atRest.vertices)

        await page.recertify(brush: brushed())
        XCTAssertNotNil(page.receipt, "the fixture must certify, or V3 is vacuous")

        let now = page.currentGeometry
        XCTAssertTrue(now.smoothed, "the Smoothed view shows the smoothed geometry")
        let smoothedMesh = mesh(now.vertices)

        XCTAssertNotEqual(originalMesh.signature, smoothedMesh.signature,
                          "V3/B1: the viewer must re-upload — this is the bar")
        XCTAssertEqual(shippedSignature(originalMesh), shippedSignature(smoothedMesh),
                       "and the shipped signature would NOT have, on this very "
                       + "data — the test is load-bearing, not decorative")
    }

    /// The Original tab shows the original. The two tabs must not be a relabelling
    /// of one mesh — which is precisely what the maintainer saw.
    func testTheOriginalViewStillShowsTheOriginal() async throws {
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        let page = self.page(runner)
        await page.recertify(brush: brushed())

        page.showingSmoothed = true
        let smoothed = mesh(page.currentGeometry.vertices)
        page.showingSmoothed = false
        let original = mesh(page.currentGeometry.vertices)

        XCTAssertFalse(page.currentGeometry.smoothed)
        XCTAssertNotEqual(original.signature, smoothed.signature)
        XCTAssertEqual(original.signature, mesh(originalVertices).signature,
                       "Original is the variant as the run made it, unchanged")
    }

    /// Discard returns the stage to the original, and the signature says so — so
    /// the renderer re-uploads on the way BACK too.
    func testDiscardReturnsTheOriginalMeshToTheViewer() async throws {
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        let page = self.page(runner)
        await page.recertify(brush: brushed())
        XCTAssertNotEqual(mesh(page.currentGeometry.vertices).signature,
                          mesh(originalVertices).signature)

        page.discard()
        XCTAssertEqual(mesh(page.currentGeometry.vertices).signature,
                       mesh(originalVertices).signature)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // V2 — AND THE REPORTED MESH MASS CHANGES WITH IT
    // ═══════════════════════════════════════════════════════════════════════

    /// V2, ANSWERED. Mesh mass is NOT computed from the original mesh: bridge.cpp's
    /// `analyze_loadcase` derives it from whatever mesh it analysed, which on the
    /// after column is the smoothed file, and the probe watched that column move
    /// (245.650462 → 245.790474 g). So this is not a second instance of the viewer
    /// defect.
    ///
    /// What WAS wrong is the reporting. The row printed at one decimal, and Taubin
    /// is volume-preserving by construction — that is the whole reason core uses a
    /// λ|μ pair rather than a plain Laplacian — so a real change of 0.14 g on
    /// 245 g rounded to the same string. "Unchanged" then could not be told apart
    /// from "unchanged shape", which is the inference the maintainer drew and the
    /// reason this bar exists.
    func testReportedMeshMassChangesWithTheSmoothedShape() async throws {
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        // The maintainer's own magnitudes: a sub-0.05 g move on a ~182 g part.
        runner.beforeMeshMass = 182.640
        runner.afterMeshMass = 182.601
        let page = self.page(runner)
        await page.recertify(brush: brushed())

        let receipt = try XCTUnwrap(page.receipt)
        let row = try XCTUnwrap(receipt.rows.first { $0.label == "Mass (mesh)" })
        XCTAssertNotEqual(row.beforeText, row.afterText,
                          "V2: a change in the certified mesh must be legible in "
                          + "the row that reports it")

        // Load-bearing: at the precision that shipped, these two ARE the same
        // string. The assertion above passes because the precision changed, not
        // because the fixture was chosen to be large.
        XCTAssertEqual(String(format: "%.1f", runner.beforeMeshMass),
                       String(format: "%.1f", runner.afterMeshMass),
                       "the fixture reproduces the maintainer's '182.6 → 182.6'")
    }

    /// The resolution is a named constant, so the two mass rows cannot drift apart
    /// and a future edit cannot quietly round the change away again.
    func testBothMassRowsPrintAtTheSameStatedResolution() async throws {
        XCTAssertGreaterThanOrEqual(SmoothReceipt.massDecimals, 3,
                                    "0.14 g on 245 g needs three places to show")
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        runner.beforeMeshMass = 182.640
        runner.afterMeshMass = 182.601
        runner.beforeVoxelMass = 207.712
        runner.afterVoxelMass = 197.348
        let page = self.page(runner)
        await page.recertify(brush: brushed())
        let rows = try XCTUnwrap(page.receipt).rows

        for label in ["Mass (mesh)", "Mass (voxel)"] {
            let row = try XCTUnwrap(rows.first { $0.label == label })
            for text in [row.beforeText, row.afterText] {
                let digits = text.replacingOccurrences(of: " g", with: "")
                    .split(separator: ".").last.map(String.init) ?? ""
                XCTAssertEqual(digits.count, SmoothReceipt.massDecimals,
                               "\(label) prints \(text)")
            }
        }
    }

    /// The honest other direction (and the reason V2's premise had to be MEASURED
    /// rather than assumed): a smoothing whose enclosed volume genuinely does not
    /// move must still report an unchanged mass. The probe measured exactly this
    /// on the interior patch — 23 vertices moved up to 0.59 mm and the mesh volume
    /// changed by less than a microgram. Reporting a change there would be a lie.
    func testAVolumePreservingSmoothingHonestlyReportsNoMassChange() async throws {
        let runner = MovingRunner(smoothed: smoothedVertices, indices: meshIndices)
        runner.beforeMeshMass = 245.650462
        runner.afterMeshMass = 245.650462
        let page = self.page(runner)
        await page.recertify(brush: brushed())

        let receipt = try XCTUnwrap(page.receipt)
        let row = try XCTUnwrap(receipt.rows.first { $0.label == "Mass (mesh)" })
        XCTAssertEqual(row.beforeText, row.afterText)
        // ...and the VIEWER still changed, which is the whole point: the two facts
        // are independent, and only one of them was ever broken.
        XCTAssertNotEqual(mesh(page.currentGeometry.vertices).signature,
                          mesh(originalVertices).signature)
    }

    // MARK: - harness

    /// A runner whose smoothed column returns geometry that DIFFERS from the input
    /// only in the interior — the shape of a real local smoothing.
    private final class MovingRunner: @unchecked Sendable {
        let smoothed: [Float]
        let indices: [Int32]
        var beforeMeshMass = 41.9
        var afterMeshMass = 40.4
        var beforeVoxelMass = 41.2
        var afterVoxelMass = 39.8

        init(smoothed: [Float], indices: [Int32]) {
            self.smoothed = smoothed
            self.indices = indices
        }

        func run(_ r: SmoothingPageModel.CertifyRequest) throws
            -> SmoothingPageModel.CertifyOutcome {
            let before = r.subject == .originalVariant
            let cert = SmoothCertification(
                subject: r.subject,
                TopOptKit.MeshCertification(
                    accepted: true, nonConvergent: false,
                    marginWorstCase: before ? 14.03 : 12.57,
                    marginInPlane: before ? 14.03 : 12.57,
                    marginInterlayer: before ? 22.74 : 20.61,
                    marginEffective: before ? 2.91 : 2.60,
                    marginRequired: 1.5, maxStressMPa: before ? 3.92 : 4.38,
                    minFeatureViolations: before ? 3271 : 2347,
                    voxelMassGrams: before ? beforeVoxelMass : afterVoxelMass,
                    meshMassGrams: before ? beforeMeshMass : afterMeshMass,
                    spacingMM: 1.25, meshVolumeFraction: 0.31,
                    voxelVolumeFraction: 0.33,
                    meshPath: before ? r.inputMeshPath : r.outputMeshPath))
            return SmoothingPageModel.CertifyOutcome(
                certification: cert,
                smoothing: before ? nil : SmoothingApplied(
                    maxStrength: r.strength, pairsRequested: 20, pairsApplied: 20,
                    totalVertices: 9, frozenVertices: 0, brushedVertices: 1,
                    unbrushedVertices: 8, volumeDriftFraction: 0.0006,
                    volumeDriftBound: 0.0056, minFeatureLimited: false,
                    regionLines: []),
                meshVertices: before ? [] : smoothed,
                meshIndices: before ? [] : indices)
        }
    }

    private func page(_ runner: MovingRunner) -> SmoothingPageModel {
        SmoothingPageModel(
            context: context(),
            variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { try runner.run($0) })
    }

    private func context() -> SmoothVariantContext {
        // The retained job document AE3 requires, in the CLI's own schema — a
        // hand-written approximation would resolve to no load case and every
        // `recertify` below would return without running.
        let job = try! JSONSerialization.data(withJSONObject: [
            "model": "b.stl", "material": "PLA", "mode": "minimize_plastic",
            "resolution": 64,
            "loads": [
                "anchor_face_ids": [3],
                "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                "build_dir": [0.0, 0.0, -1.0],
                "infill_percent": 35,
            ] as [String: Any],
        ] as [String: Any])
        return SmoothPageEntry.context(
            runName: "Run", variantIndex: 0, requestedVolumeFraction: 0.38,
            massGrams: 182.6, reportedMargin: 14.03, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: originalVertices,
                                     indices: meshIndices),
            latticed: false, retainedJob: job, modelPath: "/tmp/b.stl",
            meshUnreadable: nil)
    }

    private func brushed() -> SmoothBrushModel {
        var b = SmoothBrushModel(
            indices: meshIndices, vertexCount: originalVertices.count / 3,
            freeze: SmoothFreezeMask(
                frozen: [Bool](repeating: false, count: originalVertices.count / 3),
                toleranceMM: 1.2, meshPath: "/tmp/variant_1.stl"),
            meshPath: "/tmp/variant_1.stl")
        b.addRegion(strength: 0.6)
        b.paint(.add, triangles: [2, 3])
        return b
    }

    // MARK: - source reading

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
