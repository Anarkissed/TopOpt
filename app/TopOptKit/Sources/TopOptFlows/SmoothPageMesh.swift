// SmoothPageMesh.swift — THE SMOOTHING PAGE HAS EXACTLY ONE MESH
// (handoff 2026-08-03-smoothing-page-round2, bars S1–S3).
//
// THE DEFECT THIS TYPE EXISTS TO MAKE IMPOSSIBLE. On device the page refused to
// paint at all:
//
//   "The protected-surface map describes a different mesh (17496 vertices vs
//    105060) — refusing to paint rather than guess which vertices it means."
//
// The refusal was right. There genuinely were two meshes:
//
//   * THE ONE BEING PAINTED — `OptimizeVariant.meshVertices`, which on a LAN run
//     comes from `MeshExport.parseBinarySTL`. That reader is documented to
//     produce a TRIANGLE SOUP — "each triangle its own three vertices — STL
//     shares none" — so it holds 3 x triangle_count vertices.
//   * THE ONE BEING MASKED — whatever `smooth_freeze_mask` reads off disk, i.e.
//     core's `import_part_file`, whose `weld_and_clean` welds by exact
//     coordinate. A closed surface welds to about triangle_count / 2 vertices.
//
//   3F : F/2  =  6.  Measured 6.0030 on the maintainer's own fixture
//   (`smooth_mesh_identity_probe`); their screen read 105060 : 17496 = 6.0048.
//
// The on-device path was NOT affected — marching cubes already welds, and the
// probe measured its mesh agreeing with core's index for index. That is why this
// shipped: the defect is remote-only, and the remote path is the one that has a
// retained job document, hence the only one that can reach this page at all.
//
// THE FIX IS NOT A REMAP. Reconciling two meshes would be exactly the "guess
// which vertices it means" the guard exists to refuse. Instead the page stops
// having two: its mesh IS core's import of the ONE file the page wrote, so the
// stage, the brush, the freeze mask, the smoother and the certifier are all
// reading the same artifact. There is nothing left to reconcile.
//
// WHAT MAKES THAT STRUCTURAL RATHER THAN A HABIT:
//
//   1. `imported(from:by:)` is the only way production code builds one, and it
//      names a PATH — there is no route from an in-memory variant buffer.
//   2. `freezeMaskRequest(...)` fills in `meshPath` from `self.path`. The caller
//      supplies the load case and nothing else, so it CANNOT ask core about a
//      different file. `SmoothFreezeMaskRequest` has no other initialiser.
//   3. `brush(freeze:)` builds the `SmoothBrushModel` from this mesh's own
//      indices and count, and stamps this mesh's path on it — so the runtime
//      guard has a second, sharper thing to compare than a count.
//
// The guard STAYS (bar S3). Making the mismatch unreachable is not the same as
// proving it unreachable, and a count that happens to match is not proof the
// vertices are the same ones — see `SmoothBrushModel.unusableReason`.

import Foundation

/// The smoothing page's ONE mesh: core's own import of the file at `path`.
///
/// Not the buffer the run streamed. What core reads back — because core is what
/// masks it, smooths it and certifies it, and the brush must be indexed against
/// the same vertices those three are.
public struct SmoothPageMesh: Equatable, Sendable {

    /// The file this mesh was read from. Every question the page asks core about
    /// this geometry names THIS path.
    public let path: String
    /// Interleaved xyz, exactly as core returned them.
    public let vertices: [Float]
    /// Triangle corner indices into `vertices`.
    public let indices: [Int32]

    /// Direct construction. Present because a test must be able to build a
    /// DELIBERATELY MISMATCHED pair to prove the guard still fires (bar S3);
    /// production code goes through `imported(from:by:)`, and a source-reading
    /// test asserts the page has exactly one construction site.
    public init(path: String, vertices: [Float], indices: [Int32]) {
        self.path = path
        self.vertices = vertices
        self.indices = indices
    }

    /// THE PRODUCTION CONSTRUCTOR: read `path` back through core's importer.
    ///
    /// `importer` is injected so this is testable headlessly, but note what it is
    /// NOT — it takes a path and returns geometry. There is no parameter through
    /// which a caller's own vertex buffer could arrive.
    public static func imported(
        from path: String,
        by importer: (String) throws -> (vertices: [Float], indices: [Int32])
    ) rethrows -> SmoothPageMesh {
        let m = try importer(path)
        return SmoothPageMesh(path: path, vertices: m.vertices, indices: m.indices)
    }

    public var vertexCount: Int { vertices.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }

    // MARK: - the two things the page derives from it, both keyed on `path`

    /// The request for THIS mesh's protected-surface map. `meshPath` is filled in
    /// from `self.path`; the caller supplies only the load case. That is the
    /// "by construction" in bar S2 — asking core about a different mesh is not a
    /// thing this API can express.
    public func freezeMaskRequest(modelPath: String,
                                  loadCase: SmoothRecertLoadCase)
        -> SmoothFreezeMaskRequest {
        SmoothFreezeMaskRequest(meshPath: path, modelPath: modelPath,
                                loadCase: loadCase)
    }

    /// A brush over THIS mesh, stamped with its path so the guard can compare
    /// more than a vertex count.
    public func brush(freeze: SmoothFreezeMask = .unavailable) -> SmoothBrushModel {
        SmoothBrushModel(indices: indices, vertexCount: vertexCount,
                         freeze: freeze, meshPath: path)
    }
}

/// Everything core needs to answer "which vertices of this mesh are protected".
///
/// `meshPath` can ONLY be set by `SmoothPageMesh.freezeMaskRequest` — the
/// initialiser is private to this file. A caller holding a page mesh cannot
/// build a request naming some other file.
public struct SmoothFreezeMaskRequest: Equatable, Sendable {
    public let meshPath: String
    public let modelPath: String
    public let loadCase: SmoothRecertLoadCase

    fileprivate init(meshPath: String, modelPath: String,
                     loadCase: SmoothRecertLoadCase) {
        self.meshPath = meshPath
        self.modelPath = modelPath
        self.loadCase = loadCase
    }
}
