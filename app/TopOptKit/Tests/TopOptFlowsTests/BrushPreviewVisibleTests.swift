// BrushPreviewVisibleTests.swift — bar L4 / failure C of task
// 2026-08-04-variant-volume-fraction-mismatch.
//
// THE DEFECT. The smoothing page showed
//
//     "Nothing smoothed yet — both show the variant as the run made it."
//
// while a brush region carried 71,752 triangles / 38,122 vertices at strength
// 0.49 with 201 frozen vertices correctly reported. The Original/Smoothed toggle
// was INERT until a re-certification ran: both tabs drew the same geometry. So
// the maintainer painted, toggled, saw no difference and concluded smoothing was
// broken. It was not — the page was offering a comparison it could not make, and
// then describing its own inability as a fact about his brush.
//
// These tests hold the toggle to what it claims:
//   * after a stroke, and BEFORE any certification, Smoothed differs from
//     Original;
//   * a page with no preview engine SAYS so instead of offering the comparison;
//   * a certified or kept result always outranks the preview.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class BrushPreviewVisibleTests: XCTestCase {

    private let indices: [Int32] = [0, 1, 2, 1, 3, 2]
    private let originalVertices: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]

    private func context() -> SmoothVariantContext {
        SmoothPageEntry.context(
            runName: "WallMount", variantIndex: 1, requestedVolumeFraction: 0.52,
            massGrams: 41.2, reportedMargin: 2.31, accepted: true,
            pageMesh: SmoothPageMesh(path: "/tmp/variant_1.stl",
                                     vertices: originalVertices, indices: indices),
            latticed: false, retainedJob: nil, modelPath: "/tmp/bracket.stl")
    }

    private func brushed(strength: Double = 0.49) -> SmoothBrushModel {
        var b = SmoothBrushModel(
            indices: indices, vertexCount: 4,
            freeze: SmoothFreezeMask(frozen: [false, false, false, false],
                                     toleranceMM: 0.75))
        b.addRegion(strength: strength)
        b.paint(.add, triangles: [0, 1])
        return b
    }

    /// A previewer standing in for core's smoother: it MOVES the geometry, which
    /// is the only property the toggle depends on.
    private func movingPreviewer(counter: Counter)
        -> SmoothingPageModel.Previewer {
        { verts, idx, strength, weights in
            counter.n += 1
            // THE PREVIEW IS HANDED THE PAGE'S OWN GEOMETRY, NOT A PATH
            // (task 2026-08-08, S1b). Asserted here, at every stand-in, so the
            // model cannot start previewing some other buffer without a failure.
            XCTAssertEqual(verts, self.originalVertices,
                           "the previewer must be given the variant the page holds")
            XCTAssertEqual(idx, self.indices)
            var v: [Float] = []
            for i in 0..<4 {
                let w = Float(i < weights.count ? weights[i] : 0) * Float(strength)
                v.append(contentsOf: [Float(i % 2) + w * 0.1,
                                      Float(i / 2) + w * 0.1, w * 0.1])
            }
            return SmoothingPageModel.BrushPreviewResult(
                meshVertices: v, meshIndices: [0, 1, 2, 1, 3, 2],
                movedVertices: 3, maxDisplacementMM: 0.42, seconds: 0.031)
        }
    }

    final class Counter: @unchecked Sendable { var n = 0 }

    private func neverRuns() -> SmoothingPageModel.Runner {
        { _ in
            XCTFail("L4: the preview must not need the certification engine")
            throw TopOptError(message: "unreachable")
        }
    }

    // MARK: L4 — the brush is VISIBLE before re-certification

    func testSmoothedDiffersFromOriginalAfterAStrokeBeforeRecertifying() async {
        let counter = Counter()
        let p = SmoothingPageModel(context: context(),
                                   variantMeshPath: "/tmp/variant_1.stl",
                                   smoothedMeshPath: "/tmp/variant_1_smoothed.stl",
                                   runner: neverRuns(),
                                   previewer: movingPreviewer(counter: counter))

        p.showingSmoothed = false
        let original = p.currentGeometry
        XCTAssertFalse(original.smoothed)
        XCTAssertEqual(original.vertices, originalVertices)

        await p.refreshPreview(brush: brushed())

        XCTAssertEqual(counter.n, 1, "L4: the preview ran")
        XCTAssertEqual(p.certifyCallCount, 0,
                       "L4: and it ran WITHOUT a certification — that is the whole "
                       + "point; the old toggle was inert until one had")
        p.showingSmoothed = true
        let smoothed = p.currentGeometry
        XCTAssertTrue(smoothed.smoothed)
        XCTAssertNotEqual(smoothed.vertices, original.vertices,
                          "L4: Smoothed must actually DIFFER from Original after a "
                          + "stroke — a toggle that flips a label over unchanged "
                          + "geometry is the defect this closes")
        XCTAssertFalse(p.smoothedSideNote?.contains("Nothing painted") ?? false,
                       "the page no longer claims nothing is painted while a brush "
                       + "region is live — that sentence over a painted brush is the "
                       + "defect")
    }

    /// The note must describe what is on screen, not what the page wishes were.
    func testTheNoteNamesTheLivePreviewAndWhatRecertifyingAdds() async {
        let p = SmoothingPageModel(context: context(),
                                   variantMeshPath: "/tmp/variant_1.stl",
                                   smoothedMeshPath: "/tmp/s.stl",
                                   runner: neverRuns(),
                                   previewer: movingPreviewer(counter: Counter()))
        await p.refreshPreview(brush: brushed())
        let note = p.smoothedSideNote ?? ""
        XCTAssertTrue(note.contains("0.42 mm"),
                      "C1: the note states the measured deepest displacement")
        XCTAssertTrue(note.contains("min-feature"),
                      "C1: and states what re-certifying adds — the preview does "
                      + "NOT enforce the min-feature constraint, so the certified "
                      + "shape may move less. Claiming otherwise would be the same "
                      + "dishonesty one layer down")
    }

    // MARK: the toggle never offers what it cannot do

    func testAPageWithNoPreviewEngineSaysSoRatherThanOfferingTheComparison() async {
        let p = SmoothingPageModel(context: context(),
                                   variantMeshPath: "/tmp/variant_1.stl",
                                   smoothedMeshPath: "/tmp/s.stl",
                                   runner: neverRuns(), previewer: nil)
        await p.refreshPreview(brush: brushed())
        XCTAssertFalse(p.canPreviewBrush)
        p.showingSmoothed = true
        XCTAssertEqual(p.currentGeometry.vertices, originalVertices,
                       "with no engine there is no smoothed side")
        let note = p.smoothedSideNote ?? ""
        XCTAssertTrue(note.contains("can’t preview"),
                      "C1: it must SAY the comparison is unavailable, not offer one "
                      + "it cannot perform. Got: \(note)")
    }

    /// A brush with nothing painted must not claim a difference.
    func testAnUnpaintedBrushProducesNoSmoothedSide() async {
        let counter = Counter()
        let p = SmoothingPageModel(context: context(),
                                   variantMeshPath: "/tmp/variant_1.stl",
                                   smoothedMeshPath: "/tmp/s.stl",
                                   runner: neverRuns(),
                                   previewer: movingPreviewer(counter: counter))
        var empty = SmoothBrushModel(
            indices: indices, vertexCount: 4,
            freeze: SmoothFreezeMask(frozen: [false, false, false, false],
                                     toleranceMM: 0.75))
        empty.addRegion(strength: 0.49)
        await p.refreshPreview(brush: empty)
        XCTAssertEqual(counter.n, 0, "nothing painted ⇒ the smoother is not run")
        XCTAssertNil(p.preview)
        p.showingSmoothed = true
        XCTAssertEqual(p.currentGeometry.vertices, originalVertices)
    }

    /// A preview that moved nothing is not a smoothed side either.
    func testAPreviewThatMovedNothingIsNotOfferedAsASmoothedSide() async {
        let p = SmoothingPageModel(
            context: context(), variantMeshPath: "/tmp/variant_1.stl",
            smoothedMeshPath: "/tmp/s.stl", runner: neverRuns(),
            previewer: { verts, idx, _, _ in
                XCTAssertEqual(verts, self.originalVertices,
                               "the previewer must be given the variant the page holds")
                XCTAssertEqual(idx, self.indices)
                return SmoothingPageModel.BrushPreviewResult(
                    meshVertices: self.originalVertices, meshIndices: self.indices,
                    movedVertices: 0, maxDisplacementMM: 0, seconds: 0.01)
            })
        await p.refreshPreview(brush: brushed())
        XCTAssertNil(p.preview,
                     "two identical meshes are not a before/after")
        p.showingSmoothed = true
        XCTAssertFalse(p.currentGeometry.smoothed)
    }

    // MARK: C2 — the action names what it does

    func testTheActionSaysItAppliesTheSmoothingRatherThanMerelyCheckingIt() {
        let a = SmoothPageActions.compute(brush: brushed(), working: false,
                                          hasReceipt: false, hasKept: false,
                                          unavailable: nil)
        XCTAssertEqual(a.recertify.label, "Apply & certify",
                       "C2: \"Re-certify\" read as a CHECK on a smoothing that had "
                       + "already happened. Nothing is smoothed until this runs")
        XCTAssertTrue(a.recertify.sub.contains("applies the brush"),
                      "C2: the sub-line names the two halves in order. Got: "
                      + a.recertify.sub)
    }
}
