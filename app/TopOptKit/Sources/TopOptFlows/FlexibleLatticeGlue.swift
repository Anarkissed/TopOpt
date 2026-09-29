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
    static func estimate(_ inputs: FlexibleLatticeInputs, hMM: Double) -> FlexibleExportSheet.Estimate? { nil }
    static func export(_ inputs: FlexibleLatticeInputs, hMM: Double, to url: URL,
                       progress: @escaping (Double) -> Bool) async throws -> FlexibleExportSheet.Estimate {
        throw FlexibleLatticeBuilder.Refusal(description: "The exporter is not linked yet.")
    }
}
