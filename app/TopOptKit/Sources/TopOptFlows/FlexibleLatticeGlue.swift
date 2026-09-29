// FlexibleLatticeGlue — the page's two seams onto the lattice renderer and the STL
// exporter (built in parallel tonight; see FlexibleLatticeRenderer.swift and
// FlexibleLatticeExport.swift). Kept here so the page never depends on their internals.

import SwiftUI
import simd

/// The lattice drawn over the part, squishing with the page's loop.
struct FlexibleLatticeLayer: View {
    let lattice: FlexibleGeneratedLattice
    @ObservedObject var proj: FlexibleProjectionBox
    /// 0 … 1 of the full design load (the loop's amplitude).
    let squish: Float

    var body: some View {
        Color.clear   // replaced by FlexibleLatticeView when the renderer lands
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
