// FlexibleLatticeGeneration — "Generate lattice": the moment the drawing becomes geometry
// (task 2026-09-29-flexible-screens; maintainer: "I'd like the lattice generated when
// everything is done and then an animation showing the squishing of the model playing on
// repeat").
//
// ★ WHEN IT MAY RUN. Every loaded face has a design core did not refuse, the filament
// predicts (not calibrate-first), no two loaded faces share a stack, and there are at most
// four loaded faces (the preview's squish slots). Anything else is said in one sentence
// instead of producing a lattice that describes nothing — or silently drops a face.
//
// ★ WHAT IT BUILDS. Core's assembled density field for the faces' current designs
// (FlexibleScene.densityField) → FlexibleLatticeBuilder.inputs (the grids the preview
// marches) + one `FlexibleSquishFace` per loaded face at core's BUILDABLE depths — and
// those depths themselves (`columnDepths`), so the dent drawn beside the lattice is the
// SAME array the walls squish by.

import Foundation
import simd
import TopOptKit

public struct FlexibleGeneratedLattice: Sendable {
    public let inputs: FlexibleLatticeInputs
    public let faces: [FlexibleSquishFace]
    /// The loaded faces, in the order `faces` was built.
    public let keys: [FlexFaceKey]
    /// Per face: core's buildable depth per column (nil = no lattice there, or core could
    /// not reach one) — the exact arrays `faces` were built from.
    public let columnDepths: [FlexFaceKey: [Double?]]
    /// Per face and column: core left it without lattice (drawn unpainted, like "solid").
    public let columnNoLattice: [FlexFaceKey: [Bool]]
    /// The largest face extent (mm) — the exaggeration rule's scale.
    public let extentMM: Double
    /// Bumped per Generate: the token MeshRenderer uploads once per.
    public let generation: Int
    public let topology: String
    public let tempC: Double
    /// When it was built, for the "out of date" hint (settings changed since).
    public let settingsKey: Int

    public init(inputs: FlexibleLatticeInputs, faces: [FlexibleSquishFace], keys: [FlexFaceKey] = [],
                columnDepths: [FlexFaceKey: [Double?]] = [:], columnNoLattice: [FlexFaceKey: [Bool]] = [:],
                extentMM: Double = 0, generation: Int = 0, topology: String, tempC: Double, settingsKey: Int) {
        self.inputs = inputs; self.faces = faces; self.keys = keys
        self.columnDepths = columnDepths; self.columnNoLattice = columnNoLattice
        self.extentMM = extentMM; self.generation = generation
        self.topology = topology; self.tempC = tempC; self.settingsKey = settingsKey
    }

    /// The deepest buildable squish over all faces (mm, full load), for the exaggeration.
    public var maxDepthMM: Double {
        faces.flatMap(\.cells).reduce(0) { Swift.max($0, $1.w > 0.5 ? Double($1.x) : 0) }
    }
    /// The largest exaggeration at which the walls still follow the dent (no column's face
    /// passes the shader's 0.95 clamp).
    public var maxSafeScale: Double { faces.maxSafeScale }
}

public enum FlexibleLatticeGate {
    /// nil when Generate may run, else the one sentence that says why not.
    @MainActor
    public static func refusal(_ m: FlexibleStageModel) -> String? {
        guard let mat = m.material else { return "Pick a filament first." }
        if mat.noPrediction != nil { return "\(mat.displayName) is calibrate-first: there is no squish data to size the lattice from." }
        let loaded = m.settings.loadedFaces
        guard !loaded.isEmpty else { return "Mark at least one face that carries weight." }
        if let why = faceCountRefusal(loaded.count) { return why }
        if let c = m.conflicts.first {
            return "\(m.name(c.faceA).capitalized) and \(m.name(c.faceB)) share a stack — mark one of them as where it rests."
        }
        for f in loaded {
            guard let d = m.design(f.faceRegionID) else { return "\(m.name(f.faceRegionID).capitalized) is still being designed." }
            if let r = d.refusal { return "\(m.name(f.faceRegionID).capitalized): \(m.text(r.reason))" }
        }
        return nil
    }

    /// The preview squishes at most `FlexibleSquishField.maxFaces` loaded faces; more are
    /// refused in one sentence rather than dropped without a word.
    public static func faceCountRefusal(_ loaded: Int) -> String? {
        loaded > FlexibleSquishField.maxFaces
            ? "The preview squishes up to \(FlexibleSquishField.maxFaces) faces that carry weight — mark the others as where it rests."
            : nil
    }
}

/// What the page hands MetalMeshView for the lattice.
public enum FlexibleLatticePreview {
    /// ★ ONLY IN X-RAY, ONLY WITH A LATTICE (maintainer: "Imagine an 'X-ray vision' with a
    /// plane with a heat map for the dent"): out of X-ray the body is opaque and the walls
    /// would be marched for nothing. Hidden while a new lattice builds, so the superseded
    /// one does not draw (the octet's `latticeHidden` rule during a rebake).
    public static func inputs(xray: Bool, lattice: FlexibleGeneratedLattice?, building: Bool) -> FlexibleLatticeLayerInputs? {
        guard xray, let g = lattice else { return nil }
        return FlexibleLatticeLayerInputs(lattice: g.inputs, faces: g.faces, token: g.generation, hidden: building)
    }
}
