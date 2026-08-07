// SmoothingPageWiring — THE ENGINES THE SMOOTHING PAGE ACTUALLY RUNS, NAMED
// (task 2026-08-08-smoothing-that-works-and-is-usable, S1b / bar R3).
//
// WHY THIS FILE EXISTS. The live brush previewer was an anonymous closure
// written inline inside `WorkspacePlaceholder.openSmoothingPage`. Nothing outside
// that function could call it, so every test of the preview ran against a
// stand-in the test itself wrote — and the one thing a stand-in can never
// reproduce is what the real one does with the file system. That is exactly the
// shape this page has shipped defects in four times running: the layer is
// correct, the layer the maintainer reaches is not, and the suite is green
// because it never touched the second one.
//
// Naming it costs nothing and makes "the shipped preview opens no file" a
// statement a test can put its hands on.

import Foundation
import TopOptKit

public enum SmoothingPageWiring {

    /// ★ THE LIVE BRUSH PREVIEW. Same smoother as the certification, no
    /// certification: the Smoothed side shows the brush's own deformation as soon
    /// as a stroke settles.
    ///
    /// NO PATH, BY CONSTRUCTION. The geometry arrives as vertices and indices —
    /// the buffers the page is already drawing — so a settled stroke opens
    /// nothing. Before this, the bridge re-imported the variant's STL on every
    /// stroke: 14.4 MB and 164,228 triangles on the maintainer's own part, to
    /// rebuild the array the caller was holding.
    ///
    /// `weights` already carries the freeze: `SmoothBrushModel.normalizedWeights()`
    /// zeroes every frozen vertex, and weight 0 is the smoother's
    /// bit-identical copy-verbatim path. Passing the mask again here would be a
    /// second place for the two to disagree.
    ///
    /// It does NOT enforce the min-feature constraint, so the certified pass may
    /// smooth LESS — the page says so, in `smoothedSideNote`.
    public static let livePreviewer: SmoothingPageModel.Previewer = {
        vertices, indices, strength, weights in
        try await Task.detached(priority: .userInitiated) {
            let p = try TopOptKit.smoothBrushPreview(
                vertices: vertices, indices: indices,
                strength: strength, weights: weights)
            return SmoothingPageModel.BrushPreviewResult(
                meshVertices: p.meshVertices, meshIndices: p.meshIndices,
                movedVertices: p.movedVertices,
                maxDisplacementMM: p.maxDisplacementMM,
                seconds: p.seconds,
                secondsImport: p.secondsImport,
                secondsSmooth: p.secondsSmooth)
        }.value
    }
}
