// FlexibleLatticeGeneration — "Generate lattice": the moment the drawing becomes geometry
// (task 2026-09-29-flexible-screens, overnight round; maintainer: "I'd like the lattice
// generated when everything is done and then an animation showing the squishing of the
// model playing on repeat with an 'export' button").
//
// ★ WHEN IT MAY RUN. Every loaded face has a design core did not refuse, the filament
// predicts (not calibrate-first), and no two loaded faces share a stack. Anything else
// is said in words instead of producing a lattice that describes nothing.
//
// ★ WHAT IT BUILDS. Core's assembled density field for the faces' current designs
// (FlexibleScene.densityField) → FlexibleLatticeBuilder.inputs (the grids the renderer and
// the exporter both read) + one `FlexibleSquishFace` (FlexibleLatticeRenderer.swift) per
// loaded face for the animation, at core's BUILDABLE depths — the densities the lattice
// was made from.

import Foundation
import simd
import TopOptKit

public struct FlexibleGeneratedLattice: Sendable {
    public let inputs: FlexibleLatticeInputs
    public let faces: [FlexibleSquishFace]
    /// The deepest buildable squish over all faces (mm, full load), for the exaggeration.
    public var maxDepthMM: Double {
        faces.flatMap(\.cells).reduce(0) { Swift.max($0, $1.w > 0.5 ? Double($1.x) : 0) }
    }
    public let topology: String
    public let tempC: Double
    /// When it was built, for the "out of date" hint (settings changed since).
    public let settingsKey: Int
}

public enum FlexibleLatticeGate {
    /// nil when Generate may run, else the one sentence that says why not.
    @MainActor
    public static func refusal(_ m: FlexibleStageModel) -> String? {
        guard let mat = m.material else { return "Pick a filament first." }
        if mat.noPrediction != nil { return "\(mat.displayName) is calibrate-first: there is no squish data to size the lattice from." }
        let loaded = m.settings.loadedFaces
        guard !loaded.isEmpty else { return "Mark at least one face that carries weight." }
        if let c = m.conflicts.first {
            return "\(m.name(c.faceA).capitalized) and \(m.name(c.faceB)) share a stack — mark one of them as where it rests."
        }
        for f in loaded {
            guard let d = m.design(f.faceRegionID) else { return "\(m.name(f.faceRegionID).capitalized) is still being designed." }
            if let r = d.refusal { return "\(m.name(f.faceRegionID).capitalized): \(m.text(r.reason))" }
        }
        return nil
    }
}

extension FlexibleSquishFace {
    /// A loaded face at core's buildable depths: a column core left without lattice, or
    /// whose buildable depth it could not reach, does not move.
    public init(stack st: FlexStackInfo, design: FlexFaceDesignInfo) {
        let depths: [Double?] = st.columns.indices.map { k in
            guard k < design.columns.count else { return nil }
            let d = design.columns[k]
            return d.status != "no_lattice" && d.buildableOK ? d.buildableDepthMM : nil
        }
        self.init(stack: st, depthsMM: depths)
    }
}
