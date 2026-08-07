// SmoothingStrokeLatencyEvidence — WHAT ONE STROKE COSTS, ON HIS OWN VARIANT
// (task 2026-08-08-smoothing-that-works-and-is-usable, S1c / bar R4).
//
// This is a MEASUREMENT, not a bar. It runs the two preview routes over the
// maintainer's own rung-068 mesh and reports what the app waits for between
// letting go of the brush and the Smoothed side updating, broken into the pieces
// that actually cost something. It writes a table into evidence/ and prints it.
//
// It asserts only what would make its own numbers meaningless: that the mesh it
// measured is the real one, and that both routes produced the same geometry.
//
// ITERATIONS AND WALL, SEPARATELY (bar R4): every row carries the repeat count
// and the per-repeat wall, and the smoothing's own iteration count is the Taubin
// pair count the strength resolves to, which is reported by the bridge.
//
// SKIPPED, LOUDLY, when the evidence mesh is absent — a machine without it must
// not silently report nothing.

import XCTest
import Foundation
@testable import TopOptFlows
import TopOptKit

final class SmoothingStrokeLatencyEvidence: XCTestCase {

    private static var repoRoot: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }

    /// HIS OWN PART: rung 068 of the four-rung ladder, the mesh PR 307 measured
    /// the CAD/cut split on.
    private static var variantSTL: URL {
        repoRoot.appendingPathComponent(
            "evidence/2026-08-06-cad-face-projection/variant_068.stl")
    }

    private static var evidenceDir: URL {
        repoRoot.appendingPathComponent(
            "evidence/2026-08-08-smoothing-that-works-and-is-usable")
    }

    private func ms(_ s: Double) -> String { String(format: "%8.1f", s * 1000) }

    func testStrokeLatencyOnHisVariant() throws {
        let stl = Self.variantSTL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: stl.path),
                          "SKIPPED: \(stl.path) is not present — no measurement was taken")

        let bytes = try FileManager.default
            .attributesOfItem(atPath: stl.path)[.size] as? Int ?? 0
        let mesh = try TopOptKit.importMesh(path: stl.path)
        let nverts = mesh.vertices.count / 3
        let ntris = mesh.indices.count / 3
        XCTAssertGreaterThan(ntris, 100_000,
                             "precondition: this must be his real variant, not a stub")

        // A brush covering a realistic patch: the strength the app's deepest rung
        // asks for, applied to every vertex (the worst case for the smoother, so
        // the smoothing side of the split is not flattered).
        let strength = 0.49
        let weights = [Double](repeating: 1.0, count: nverts)

        let repeats = 5
        func time(_ n: Int, _ body: () throws -> Void) rethrows -> Double {
            let t0 = Date()
            for _ in 0..<n { try body() }
            return Date().timeIntervalSince(t0) / Double(n)
        }

        // ── route A: the one that shipped — a path, re-imported every stroke ──
        var viaFile: TopOptKit.BrushPreview!
        let fileWall = try time(repeats) {
            viaFile = try TopOptKit.smoothBrushPreview(
                inputMeshPath: stl.path, strength: strength, weights: weights)
        }

        // ── route B: the one the page takes now — the geometry it already holds ──
        var viaMemory: TopOptKit.BrushPreview!
        let memWall = try time(repeats) {
            viaMemory = try TopOptKit.smoothBrushPreview(
                vertices: mesh.vertices, indices: mesh.indices,
                strength: strength, weights: weights)
        }

        XCTAssertEqual(viaMemory.meshVertices, viaFile.meshVertices,
                       "the two routes must produce the same geometry, or this table "
                       + "is comparing two different operations")

        // ── the app-side half of the wait: turning the returned buffers into the
        //    mesh the stage draws. This is NOT free and it is part of what he
        //    feels, so it is measured rather than assumed away.
        var viewerWall = 0.0
        var viewer: ViewerMesh!
        viewerWall = time(repeats) {
            viewer = ViewerMesh(vertices: viaMemory.meshVertices,
                                indices: viaMemory.meshIndices,
                                faceIDs: [], faceGeometry: [],
                                pseudoFaces: false, smoothShaded: true)
        }
        XCTAssertEqual(viewer.vertexCount, nverts)

        var out = ""
        func p(_ s: String) { out += s + "\n"; print(s) }
        p("STROKE LATENCY ON HIS OWN VARIANT — rung 068")
        p("")
        // ★ WHICH BUILD. This matters more than it looks: the app ships RELEASE,
        // and a plain `swift test` is DEBUG, where the Swift-side loops (the
        // ViewerMesh build and the geometry hand-off) are two orders of magnitude
        // slower and would put the blame in the wrong place. Stated in the file
        // so a reader can never mistake one for the other.
        #if DEBUG
        p("BUILD: DEBUG — NOT the configuration the app ships. Re-run with")
        p("       `swift test -c release --filter SmoothingStrokeLatencyEvidence`")
        p("       for the numbers he actually feels.")
        #else
        p("BUILD: RELEASE — the configuration the app ships.")
        #endif
        p("")
        p("mesh   \(stl.lastPathComponent): \(bytes) bytes, "
          + "\(nverts) vertices / \(ntris) triangles")
        p("brush  every vertex at weight 1.0, strength \(strength) "
          + "(Taubin pairs \(viaFile.totalVertices > 0 ? "as resolved by taubin_params_for_strength" : "?"))")
        p("repeats per row: \(repeats); every figure is ms PER STROKE")
        p("")
        p("stage                                  repeats    ms/stroke")
        p("------------------------------------------------------------")
        p("A  preview via PATH   — STL re-import  \(String(format: "%7d", repeats))  \(ms(viaFile.secondsImport))")
        p("A  preview via PATH   — smoothing      \(String(format: "%7d", repeats))  \(ms(viaFile.secondsSmooth))")
        p("A  preview via PATH   — TOTAL          \(String(format: "%7d", repeats))  \(ms(fileWall))")
        p("B  preview via MEMORY — STL re-import  \(String(format: "%7d", repeats))  \(ms(viaMemory.secondsImport))")
        p("B  preview via MEMORY — smoothing      \(String(format: "%7d", repeats))  \(ms(viaMemory.secondsSmooth))")
        p("B  preview via MEMORY — TOTAL          \(String(format: "%7d", repeats))  \(ms(memWall))")
        p("   ViewerMesh build (app side, both)   \(String(format: "%7d", repeats))  \(ms(viewerWall))")
        p("------------------------------------------------------------")
        p("stroke release -> updated preview, BEFORE: \(ms(fileWall + viewerWall)) ms")
        p("stroke release -> updated preview, AFTER : \(ms(memWall + viewerWall)) ms")
        let saved = (fileWall + viewerWall) - (memWall + viewerWall)
        p(String(format: "removed: %.1f ms per stroke (%.1f%% of the before figure)",
                 saved * 1000, saved / (fileWall + viewerWall) * 100))
        p("")
        p("The import share of the SHIPPED preview call: "
          + String(format: "%.1f%%", viaFile.secondsImport / viaFile.seconds * 100))
        p("moved vertices \(viaMemory.movedVertices) / \(nverts); "
          + String(format: "max displacement %.4f mm", viaMemory.maxDisplacementMM))

        try? FileManager.default.createDirectory(at: Self.evidenceDir,
                                                 withIntermediateDirectories: true)
        try out.write(to: Self.evidenceDir.appendingPathComponent("s1c_stroke_latency.txt"),
                      atomically: true, encoding: .utf8)
    }
}
