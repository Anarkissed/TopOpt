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
// the exporter both read) + one `FlexibleSquishFace` per loaded face for the animation.

import Foundation
import simd
import TopOptKit

/// One loaded face's columns for the squish animation: the frame, and per column the
/// depth at full load (core's buildable depth; nil when core has no number) plus where
/// the column enters and leaves the part along the load (02-squish-model §6 ramp).
public struct FlexibleSquishFace: Equatable, Sendable {
    public let region: Int
    public let centroid: SIMD3<Double>
    public let xAxis: SIMD3<Double>
    public let yAxis: SIMD3<Double>
    public let load: SIMD3<Double>
    public let uMin: Double, vMin: Double
    public let pitchMM: Double
    public let nu: Int, nv: Int
    /// nu*nv, row-major in v: (depth mm, entryT, exitT, exists 0/1)
    public let columns: [SIMD4<Float>]
    public var maxDepthMM: Double {
        columns.reduce(0) { Swift.max($0, $1.w > 0 ? Double($1.x) : 0) }
    }

    public init(region: Int, stack st: FlexStackInfo, design: FlexFaceDesignInfo) {
        self.region = region
        centroid = st.centroid; xAxis = st.xAxis; yAxis = st.yAxis; load = st.load
        uMin = st.uMin; vMin = st.vMin; pitchMM = st.pitchMM; nu = st.nu; nv = st.nv
        var cols = [SIMD4<Float>](repeating: .zero, count: st.nu * st.nv)
        for (k, c) in st.columns.enumerated() where k < design.columns.count {
            let d = design.columns[k]
            let depth = d.status != "no_lattice" && d.buildableOK ? d.buildableDepthMM : 0
            cols[c.iv * st.nu + c.iu] = SIMD4(Float(depth), Float(c.entryT), Float(c.exitT), 1)
        }
        columns = cols
    }
}

public struct FlexibleGeneratedLattice: Sendable {
    public let inputs: FlexibleLatticeInputs
    public let faces: [FlexibleSquishFace]
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
