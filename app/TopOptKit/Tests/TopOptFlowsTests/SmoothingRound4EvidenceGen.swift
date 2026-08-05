// SmoothingRound4EvidenceGen — the measured layout and the frames for task
// 2026-08-05-smoothing-page-brush-and-panel (bars R5 / R7).
//
// Opt-in, exactly as the other page generators are: set
// TOPOPT_SMOOTHING_ROUND4_EVIDENCE=1 and it writes into
// evidence/2026-08-05-smoothing-page-brush-and-panel/; without it these SKIP.
//
// It writes TWO things:
//
//   * measured_layout.txt — every chrome rect the layout system produced, at the
//     iPad landscape size in his screenshots and in portrait, in each state. The
//     panel height, the action column's order and widths, and the note's
//     position all come from here rather than from an eyeball.
//   * the PNG frames, so the same numbers can be looked at.
//
// The live-device frame remains the maintainer's own QA step; nothing here
// claims to be one.

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
final class SmoothingRound4EvidenceGen: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["TOPOPT_SMOOTHING_ROUND4_EVIDENCE"] == "1"
    }

    private static var outDir: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }   // → worktree root
        dir.appendPathComponent("evidence/2026-08-05-smoothing-page-brush-and-panel",
                               isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let verts: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
    private let tris: [Int32] = [0, 1, 2, 1, 3, 2]

    /// His screenshot's canvas (iPad Pro 11", landscape), and portrait.
    private let landscape = CGSize(width: 1194, height: 834)
    private let portrait = CGSize(width: 834, height: 1194)

    func testWriteMeasuredLayoutAndFrames() async throws {
        guard enabled else { throw XCTSkip("set TOPOPT_SMOOTHING_ROUND4_EVIDENCE=1") }
        var out = """
        MEASURED LAYOUT — task 2026-08-05-smoothing-page-brush-and-panel
        Every rect below is what SwiftUI laid out, reported through
        SmoothingPage's own chrome seam (`onChromeFrame`), not computed from the
        chrome tokens. Units are page points; y grows downward.

        """

        for (label, size) in [("landscape (his screenshot)", landscape),
                              ("portrait", portrait)] {
            for state in States.allCases {
                let (rects, page) = await render(size: size, state: state)
                out += "\n── \(label) \(size.width)×\(size.height) · \(state.rawValue)\n"
                for (k, v) in rects.sorted(by: { $0.key < $1.key }) {
                    out += String(format: "   %-24@ x %7.1f  y %7.1f  w %7.1f  h %7.1f\n",
                                  k as NSString, v.minX, v.minY, v.width, v.height)
                }
                _ = page
            }
        }

        out += """

        ── the action column, top to bottom (bar D5b)
           SmoothPageActions.columnOrder = \(SmoothPageActions.columnOrder.map(\.rawValue))
           Apply & certify is pinned last in every state; the other three run
           narrowest → widest. The order is a constant, so the captions changing
           between states cannot reflow it.

        ── the panel (bars D3 / R5), landscape 1194×834
           BEFORE this task: h 686, top y 74  → across "Working on …" (y 86) and
                             the load-case row (y 138). That is the occlusion in
                             the screenshot.
           AFTER:            h 284, top y 358, at the default brush radius (26).
                             IDENTICAL with Orbit present (Pencil only OFF) and
                             absent (ON): the mode tabs are one row either way,
                             so the third tab costs no height.
           The only thing that moves it is the brush size, because the disc is
           drawn at its true footprint: h = 232 + 2 × radius, so 284 at radius 26,
           332 at his radius 50, and 360 at the maximum 64. Every one of those
           fits the band (620 pt) with room to spare.

        """
        try out.write(to: Self.outDir.appendingPathComponent("measured_layout.txt"),
                      atomically: true, encoding: .utf8)
        print("ROUND4-EVIDENCE wrote measured_layout.txt")

        for state in States.allCases {
            await capture(state: state, size: landscape,
                          name: "page_\(state.rawValue)_landscape.png")
        }
        await capture(state: .rest, size: portrait, name: "page_rest_portrait.png")
    }

    // MARK: - harness

    enum States: String, CaseIterable {
        case rest, restPencilOnly, brushed, noted, certified
        var pencilOnly: Bool { self == .restPencilOnly }
        var strokes: Int { self == .rest || self == .restPencilOnly ? 0 : 2 }
    }

    private func render(size: CGSize, state: States) async
        -> ([String: CGRect], SmoothingPageModel) {
        var rects: [String: CGRect] = [:]
        let p = pageModel()
        p.dismissEntryNotice()
        if state == .noted { p.post(note: "A note, one line, at the top centre.") }
        if state == .certified { await p.recertify(brush: brushed(2)) }
        let view = page(p, state: state, staticRender: false) { rects[$0] = $1 }
        let host = ZStack { Color(red: 0.02, green: 0.024, blue: 0.047); view }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: host)
        r.scale = 1
        _ = r.cgImage
        return (rects, p)
    }

    private func capture(state: States, size: CGSize, name: String) async {
        let p = pageModel()
        p.dismissEntryNotice()
        if state == .noted { p.post(note: "A note, one line, at the top centre.") }
        if state == .certified { await p.recertify(brush: brushed(2)) }
        let host = ZStack {
            Color(red: 0.02, green: 0.024, blue: 0.047)
            page(p, state: state, staticRender: true) { _, _ in }
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
        print("ROUND4-EVIDENCE wrote \(url.path)")
    }

    private func page(_ p: SmoothingPageModel, state: States, staticRender: Bool,
                      probe: @escaping (String, CGRect) -> Void) -> some View {
        let project = ProjectModel(id: UUID(), name: "WallMount bracket",
                                   material: "PLA", process: .fdm,
                                   importedFile: nil, importedMesh: nil)
        return SmoothingPage(
            project: project, page: p,
            brush: .constant(brushed(state.strokes)),
            tools: .constant(SmoothBrushTools(pencilOnly: state.pencilOnly)),
            showingSmoothed: .constant(false),
            onRecertify: {}, onDiscard: {}, onSendToLattice: {}, onClose: {},
            staticRender: staticRender,
            onChromeFrame: { probe($0, $1) })
    }

    private func brushed(_ strokes: Int) -> SmoothBrushModel {
        var b = SmoothBrushModel(
            indices: tris, vertexCount: 4,
            freeze: SmoothFreezeMask(frozen: [false, false, false, true],
                                     toleranceMM: 2.43, meshPath: "/tmp/variant_1.stl"),
            meshPath: "/tmp/variant_1.stl")
        for _ in 0..<strokes { b.beginStroke(); b.brush(.paint, triangles: [0]); b.endStroke() }
        return b
    }

    private func pageModel() -> SmoothingPageModel {
        let job = try! JSONSerialization.data(withJSONObject: [
            "model": "bracket.stl", "material": "PLA", "mode": "minimize_plastic",
            "resolution": 128,
            "loads": ["anchor_face_ids": [3, 4, 5, 6, 7],
                      "groups": [["face_ids": [7], "force": [0.0, 0.0, -500.0]]],
                      "build_dir": [0.0, 0.0, -1.0],
                      "infill_percent": 35] as [String: Any],
        ] as [String: Any])
        let ctx = SmoothPageEntry.context(
            runName: "WallMount bracket", variantIndex: 1,
            requestedVolumeFraction: 0.68, massGrams: 186.1,
            reportedMargin: 10.60, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: verts, indices: tris),
            latticed: false, retainedJob: job, modelPath: "/tmp/bracket.stl")
        return SmoothingPageModel(
            context: ctx, variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
            runner: { r in
                let before = r.subject == .originalVariant
                return SmoothingPageModel.CertifyOutcome(
                    certification: SmoothCertification(
                        subject: r.subject,
                        TopOptKit.MeshCertification(
                            accepted: true, nonConvergent: false,
                            marginWorstCase: before ? 10.60 : 9.81,
                            marginInPlane: before ? 10.60 : 9.81,
                            marginInterlayer: before ? 18.24 : 17.41,
                            marginEffective: before ? 2.91 : 2.60,
                            marginRequired: 1.5, maxStressMPa: before ? 3.92 : 4.38,
                            minFeatureViolations: before ? 3271 : 2347,
                            voxelMassGrams: before ? 207.712 : 197.348,
                            meshMassGrams: before ? 186.104 : 186.061,
                            spacingMM: 1.25, meshVolumeFraction: 0.31,
                            voxelVolumeFraction: 0.33,
                            meshPath: before ? r.inputMeshPath : r.outputMeshPath)),
                    smoothing: before ? nil : SmoothingApplied(
                        maxStrength: r.strength, pairsRequested: 20, pairsApplied: 20,
                        totalVertices: 11556, frozenVertices: 228,
                        brushedVertices: 1692, unbrushedVertices: 9636,
                        volumeDriftFraction: 0.00057, volumeDriftBound: 0.00565,
                        minFeatureLimited: false, regionLines: []),
                    meshVertices: before ? [] : [0, 0, 0, 1, 0, 0, 0, 1, 0, 0.9, 0.9, 0],
                    meshIndices: before ? [] : self.tris)
            })
    }
}
#endif
