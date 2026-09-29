// FlexibleLatticeGlue — the page's two seams onto the lattice renderer
// (FlexibleLatticeRenderer.swift) and the STL exporter (FlexibleLatticeExport.swift), so
// the page never depends on their internals.

import SwiftUI
import simd

/// The lattice drawn over the part, squishing in step with the page's dent.
///
/// ★ ONE CLOCK. The page's 30 fps ticker drives both the dent (MetalMeshView's flexScale)
/// and this layer, as `.still(amount)` each tick — the renderer's own `.loop` would run
/// on a different clock and drift out of phase with the dent.
/// ★ It observes the projection box itself, so a camera move redraws only this layer.
struct FlexibleLatticeMount: View {
    let lattice: FlexibleGeneratedLattice
    @ObservedObject var proj: FlexibleProjectionBox
    /// 0 … 1 of the full design load (the loop's amplitude).
    let squish: Float
    /// The dent's exaggeration, so the walls move exactly as far as the face does.
    let exaggeration: Float

    var body: some View {
        FlexibleLatticeView(inputs: lattice.inputs, projection: proj.projection,
                            squishFaces: lattice.faces, motion: .still(squish),
                            exaggeration: exaggeration)
    }
}

enum FlexibleLatticeExporting {
    /// The export sheet asks for an estimate on every redraw (each progress tick); the
    /// probe marches 32 768 cubes, so it is computed once per (lattice, pitch).
    @MainActor private static var estimates: [String: FlexibleExportSheet.Estimate] = [:]

    @MainActor
    static func estimate(_ g: FlexibleGeneratedLattice, hMM: Double) -> FlexibleExportSheet.Estimate? {
        let key = "\(g.settingsKey)|\(g.topology)|\(hMM)"
        if let e = estimates[key] { return e }
        guard let e = try? FlexibleLatticeExport.estimate(g.inputs, hMM: hMM) else { return nil }
        let out = FlexibleExportSheet.Estimate(triangles: e.triangles, bytes: e.bytes)
        if estimates.count > 32 { estimates.removeAll() }
        estimates[key] = out
        return out
    }

    /// Marches off the main actor; `progress` returns false to cancel (the partial file
    /// is deleted by the exporter).
    static func export(_ inputs: FlexibleLatticeInputs, hMM: Double, to url: URL,
                       progress: @escaping (Double) -> Bool) async throws -> FlexibleExportSheet.Estimate {
        try? FileManager.default.removeItem(at: url)
        let r = try await Task.detached(priority: .userInitiated) {
            try FlexibleLatticeExport.export(inputs, hMM: hMM, to: url, progress: progress)
        }.value
        return FlexibleExportSheet.Estimate(triangles: r.triangles, bytes: r.bytes)
    }
}
