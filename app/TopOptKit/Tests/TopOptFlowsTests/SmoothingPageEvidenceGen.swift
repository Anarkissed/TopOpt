// SmoothingPageEvidenceGen — the B4 screenshots for task
// 2026-08-04-smoothing-viewer-and-ui. Opt-in, exactly as the lattice page's own
// generator is: set TOPOPT_SMOOTHING_PAGE_EVIDENCE=1 and it writes into
// evidence/2026-08-04-smoothing-viewer-and-ui/; without it these SKIP.
//
// Offscreen ImageRenderer captures, the /app/ evidence precedent (numeric-input,
// plane-extents, import-sheet, lattice page). The page is CHROME ONLY — the Metal
// stage renders beneath it in the app — so these frames show the full chrome over
// the dark backdrop at exact iPad-11" point sizes, in BOTH orientations, which is
// what bar B4 asks for. The live-device frame remains the maintainer's own QA
// step; nothing here claims to be one.

#if canImport(SwiftUI) && os(macOS)
import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class SmoothingPageEvidenceGen: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_SMOOTHING_PAGE_EVIDENCE"] == "1"
    }

    private static var outDir: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }   // → worktree root
        dir.appendPathComponent("evidence/2026-08-04-smoothing-viewer-and-ui",
                                isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    private func retainedJob() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "bracket.stl", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 64,
            "loads": [
                "anchor_face_ids": [3],
                "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                "build_dir": [0.0, 0.0, -1.0],
                "infill_percent": 35,
            ] as [String: Any],
        ] as [String: Any])
    }

    private func pageModel() -> SmoothingPageModel {
        let ctx = SmoothPageEntry.context(
            runName: "WallMount bracket", variantIndex: 2,
            requestedVolumeFraction: 0.38, massGrams: 182.6,
            reportedMargin: 14.03, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_3.stl",
                                     vertices: verts, indices: tris),
            latticed: false, retainedJob: retainedJob(),
            modelPath: "/tmp/bracket.stl")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: "/tmp/variant_3.stl",
            smoothedMeshPath: "/tmp/variant_3_smoothed.stl",
            runner: { r in
                // The maintainer's own receipt numbers, so the drawer capture
                // shows the case this task was opened on.
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
                        voxelMassGrams: before ? 207.712 : 197.348,
                        meshMassGrams: before ? 182.640 : 182.601,
                        spacingMM: 1.25, meshVolumeFraction: 0.31,
                        voxelVolumeFraction: 0.33,
                        meshPath: before ? r.inputMeshPath : r.outputMeshPath))
                return SmoothingPageModel.CertifyOutcome(
                    certification: cert,
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: r.strength, pairsRequested: 20,
                        pairsApplied: 20, totalVertices: 11556,
                        frozenVertices: 228, brushedVertices: 1692,
                        unbrushedVertices: 9636, volumeDriftFraction: 0.00057,
                        volumeDriftBound: 0.00565, minFeatureLimited: false,
                        regionLines: []),
                    meshVertices: before ? [] : [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.9, 0.9, 0],
                    meshIndices: before ? [] : self.tris)
            })
    }

    private func brushed(strokes: Int) -> SmoothBrushModel {
        var b = SmoothBrushModel(
            indices: tris, vertexCount: 4,
            freeze: SmoothFreezeMask(frozen: [false, false, false, true],
                                     toleranceMM: 2.43,
                                     meshPath: "/tmp/variant_3.stl"),
            meshPath: "/tmp/variant_3.stl")
        for _ in 0..<strokes {
            b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke()
        }
        return b
    }

    private func makePage(_ page: SmoothingPageModel,
                          brush: SmoothBrushModel,
                          tools: SmoothBrushTools = SmoothBrushTools())
        -> some View {
        let project = ProjectModel(id: UUID(), name: "WallMount ShelfBracket",
                                   material: "PLA", process: .fdm,
                                   importedFile: nil, importedMesh: nil)
        return SmoothingPage(
            project: project, page: page,
            brush: .constant(brush), tools: .constant(tools),
            showingSmoothed: .constant(true),
            onRecertify: {}, onDiscard: {}, onSendToLattice: {}, onClose: {},
            staticRender: true)
    }

    func testWriteScreenshots() async throws {
        guard enabled else { throw XCTSkip("set TOPOPT_SMOOTHING_PAGE_EVIDENCE=1") }
        let landscape = CGSize(width: 1366, height: 1024)   // iPad Pro 11" points
        let portrait = CGSize(width: 1024, height: 1366)

        // 1. ON ENTRY — the ONE dismissible notice (U6), and nothing else.
        let entry = pageModel()
        capture(makePage(entry, brush: brushed(strokes: 0)),
                name: "page_entry_notice_landscape.png", size: landscape)
        capture(makePage(entry, brush: brushed(strokes: 0)),
                name: "page_entry_notice_portrait.png", size: portrait)

        // 2. AT REST, notice dismissed — the brush-only modal (U2), nothing
        //    standing (U6), and the two-row action cluster (U3).
        let rest = pageModel()
        rest.dismissEntryNotice()
        capture(makePage(rest, brush: brushed(strokes: 0)),
                name: "page_at_rest_landscape.png", size: landscape)
        capture(makePage(rest, brush: brushed(strokes: 0)),
                name: "page_at_rest_portrait.png", size: portrait)

        // 3. BRUSHED — the panel is UNCHANGED by a stroke (U1: the tint on the
        //    model is the readout, and there is no region row to grow).
        capture(makePage(rest, brush: brushed(strokes: 3)),
                name: "page_brushed_landscape.png", size: landscape)

        // 4. PENCIL ONLY on (U2).
        capture(makePage(rest, brush: brushed(strokes: 1),
                         tools: SmoothBrushTools(pencilOnly: true)),
                name: "page_pencil_only_landscape.png", size: landscape)

        // 5. CERTIFIED, drawer CLOSED — the transient note is the only thing at
        //    the top (U5), and the receipt is behind its handle (U4).
        let certified = pageModel()
        certified.dismissEntryNotice()
        await certified.recertify(brush: brushed(strokes: 2))
        capture(makePage(certified, brush: brushed(strokes: 2)),
                name: "page_certified_note_landscape.png", size: landscape)

        // 6. THE RECEIPT DRAWER OPEN (U4), both orientations — B4's own case,
        //    since portrait is where the panel yields so the two cannot overlap.
        certified.receiptOpen = true
        capture(makePage(certified, brush: brushed(strokes: 2)),
                name: "page_receipt_drawer_landscape.png", size: landscape)
        capture(makePage(certified, brush: brushed(strokes: 2)),
                name: "page_receipt_drawer_portrait.png", size: portrait)
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) {
        let host = ZStack {
            Color(red: 0.02, green: 0.024, blue: 0.047)   // the stage-gradient base
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: host)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            XCTFail("ImageRenderer produced no image for \(name)")
            return
        }
        let url = Self.outDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("could not create destination for \(name)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "could not write \(name)")
        print("SMOOTHING-PAGE-EVIDENCE wrote \(url.path)")
    }
}
#endif
