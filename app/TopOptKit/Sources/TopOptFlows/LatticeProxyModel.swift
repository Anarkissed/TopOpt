// LatticeProxyModel.swift — the @MainActor state behind the lattice viewer proxy
// (handoff 2026-07-28-lattice-viewer-proxy). Holds the local lattice parameters and
// derives, on device with no worker round trip:
//   • the per-vertex density tints the viewer paints the part surface with
//     (through the existing `stressTints` channel — zero new GPU buffers),
//   • the small true-geometry sample-patch thumbnail (the "what the cells look like"
//     reference), memoised so it only re-renders when its own inputs change,
//   • the honest cost comparison (proxy vs the real lattice at 8/6/4 mm) and the
//     member-scale readout the legend shows.
// Changing any parameter re-derives all of this immediately (requirement V3): the
// derivations are pure functions of the params + the already-on-device demand field.

import Foundation
import simd
import CoreGraphics

/// Observable state for the lattice density proxy.
@MainActor
public final class LatticeProxyModel: ObservableObject {

    /// Whether the proxy is showing (the "Lattice preview" toggle).
    @Published public var isActive: Bool = false

    /// The local lattice parameters. Any change re-derives the tints, patch and cost.
    @Published public var params: LatticeProxyParams {
        didSet { if params != oldValue { patchImageCache = nil; patchImageKey = nil } }
    }

    public init(params: LatticeProxyParams = LatticeProxyParams()) {
        self.params = params
    }

    // MARK: surface shading (feeds MetalMeshView.stressTints)

    /// The per-flat-vertex density colours for `mesh`, graded by `field` (the
    /// on-device von Mises demand) or uniform when `field` is nil/empty. A pure
    /// function of (mesh, field, params) — cheap enough to recompute on every param
    /// change, which is exactly what makes the update local and instant (V3).
    public func densityTints(for mesh: ViewerMesh, field: StressField?) -> [SIMD4<Float>] {
        LatticeDensityProxy.tints(for: mesh, demand: field, params: params)
    }

    // MARK: sample patch (the true-geometry reference, memoised)

    private var patchImageCache: CGImage?
    private var patchImageKey: String?

    /// How many cells the sample patch shows (kept tiny — the whole point).
    public var patchCells: Int = 2

    /// The relative density the sample patch is rendered at — the densest the current
    /// grading reaches, so the struts are clearly visible.
    public var patchRelativeDensity: Double { params.densitySpan.hi }

    /// The sample-patch geometry (true struts + node blobs), for a live inset or a
    /// thumbnail. Small by construction (a few thousand triangles).
    public func samplePatchMesh() -> ViewerMesh {
        LatticeSamplePatch.mesh(lattice: params.lattice, cellMM: params.cellMM,
                                cells: patchCells, relativeDensity: patchRelativeDensity)
    }

    /// A rendered thumbnail of the sample patch, memoised on the inputs that change
    /// its geometry, so orbiting/param-sweeping the MAIN scene never re-renders it.
    public func samplePatchThumbnail(size: Int = 240) -> CGImage? {
        let key = "\(params.latticeID)|\(params.cellMM)|\(patchRelativeDensity)|\(patchCells)|\(size)"
        if key == patchImageKey, let img = patchImageCache { return img }
        let img = MeshThumbnail.cgImage(for: samplePatchMesh(), size: size)
        patchImageCache = img; patchImageKey = key
        return img
    }

    /// The sample patch's true triangle count (shown in the legend as the honest
    /// "this is all the geometry on the device" number).
    public var samplePatchTriangles: Int {
        LatticeSamplePatch.triangleCount(lattice: params.lattice, cells: patchCells)
    }

    // MARK: legend + cost (all local)

    /// Colour-ramp samples for the legend gradient (sparse → dense).
    public func legendStops(_ n: Int = 12) -> [RGBAColor] {
        (0..<n).map { i in
            let f = Double(i) / Double(n - 1)
            let c = LatticeDensityProxy.densityColor(fraction: f)
            return RGBAColor(r: c.r, g: c.g, b: c.b)
        }
    }

    /// The honest cost comparison for a part of `volumeMM3` at the current cell —
    /// proxy (sample patch only) vs the real lattice mesh.
    public func cost(volumeMM3: Double) -> LatticeDensityProxy.CostComparison {
        LatticeDensityProxy.cost(latticeID: params.latticeID, cellMM: params.cellMM,
                                 volumeMM3: volumeMM3, proxyPatchTriangles: samplePatchTriangles)
    }

    /// The cost comparison across the three named cells (8/6/4 mm) for the bar-V1
    /// table, at a given part volume.
    public func costTable(volumeMM3: Double) -> [LatticeDensityProxy.CostComparison] {
        [8.0, 6.0, 4.0].map {
            LatticeDensityProxy.cost(latticeID: params.latticeID, cellMM: $0,
                                     volumeMM3: volumeMM3, proxyPatchTriangles: samplePatchTriangles)
        }
    }

    /// Cells across a member of thickness `memberMM` at the current cell — the
    /// scale-separation readout (updates instantly on a cell change, V3).
    public func cellsAcrossMember(_ memberMM: Double) -> Double {
        LatticeDensityProxy.cellsAcrossMember(memberMM: memberMM, cellMM: params.cellMM)
    }
}

/// A plain sRGB colour triple for the SwiftUI legend gradient (kept UI-framework-
/// free here so the model stays testable).
public struct RGBAColor: Equatable, Sendable {
    public let r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
}

/// How the legend card participates in the PR-217 keep-out pass (requirement V4).
/// The legend is registered as the LOWEST-priority element — a movable `.label` — so
/// it never displaces the gizmo, chips or design-box handles; when one of THEM lands
/// on it, the pass floats the legend clear instead of letting them fight. It is not
/// rigid and carries no locus, so it simply steps aside by the minimum distance.
public enum LatticeProxyLayout {
    /// The legend card's fixed size (must track LatticeProxyLegend's frame).
    public static let panelSize = CGSize(width: 260, height: 232)

    /// The keep-out element for the legend, anchored at its home corner `anchor`
    /// (the centre it wants to sit at). Priority `.label` (0) → lowest → it yields to
    /// everything and floats clear rather than overlapping a control.
    public static func keepOutElement(anchor: CGPoint) -> KeepOutElement {
        KeepOutElement(id: "lattice.legend", anchor: anchor,
                       bounds: panelSize, touch: panelSize, priority: .label)
    }
}
