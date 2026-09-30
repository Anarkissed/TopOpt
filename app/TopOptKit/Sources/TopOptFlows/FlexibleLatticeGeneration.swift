// FlexibleLatticeGeneration — the moment the drawing becomes geometry (task
// 2026-09-29-flexible-screens; maintainer: "I'd like the lattice generated when everything is
// done and then an animation showing the squishing of the model playing on repeat").
//
// ★ ROUND 3 BATCH B (item 7.1): there is no Generate button. Save & Exit builds it
// (FlexibleMainStage.didExitSettings) and the MAIN Flexible page shows it; what may stop it is
// FlexibleReadiness (the old FlexibleLatticeGate said "calibrate-first" before the one thing
// that blocked his project, and refused a fifth face — neither blocks now).
//
// ★ WHAT IT BUILDS. Core's assembled density field for the faces' current designs
// (FlexibleScene.densityField) — or, for a calibrate-first filament, the SHAPE-ONLY field
// (FlexibleGeometryOnlyLattice: core's mask, density from the drawn map) — then
// FlexibleLatticeBuilder.inputs (the grids the preview marches) + one `FlexibleSquishFace` per
// pressed face, LARGEST FIRST (the pass squishes the first four), and the depths themselves
// (`columnDepths`), so the dent drawn beside the lattice is the SAME array the walls squish by.

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
    /// ★ BATCH B: the faces whose squish is SHOWN — the four largest (the pass's slots). The
    /// walls use every face in `keys`; the dent moves only these (the rest hold still, so the
    /// map never moves where the walls do not).
    public let squishedKeys: [FlexFaceKey]
    /// ★ BATCH B: set for a calibrate-first filament's SHAPE-ONLY lattice — "<filament>: shape
    /// only — no squish predicted" (his words). nil for a designed lattice.
    public let shapeOnlyLabel: String?
    public var shapeOnly: Bool { shapeOnlyLabel != nil }
    /// ★ BATCH B REVIEW: the scene it was built on (FlexibleStageModel's opened key) — a new
    /// grid or lattice region leaves it stale, not "Lattice ready". nil: not keyed (tests).
    public let sceneKey: String?

    public init(inputs: FlexibleLatticeInputs, faces: [FlexibleSquishFace], keys: [FlexFaceKey] = [],
                columnDepths: [FlexFaceKey: [Double?]] = [:], columnNoLattice: [FlexFaceKey: [Bool]] = [:],
                extentMM: Double = 0, generation: Int = 0, topology: String, tempC: Double, settingsKey: Int,
                squishedKeys: [FlexFaceKey]? = nil, shapeOnlyLabel: String? = nil, sceneKey: String? = nil) {
        self.inputs = inputs; self.faces = faces; self.keys = keys
        self.columnDepths = columnDepths; self.columnNoLattice = columnNoLattice
        self.extentMM = extentMM; self.generation = generation
        self.topology = topology; self.tempC = tempC; self.settingsKey = settingsKey
        self.squishedKeys = squishedKeys ?? Array(keys.prefix(FlexibleSquishField.maxFaces))
        self.shapeOnlyLabel = shapeOnlyLabel
        self.sceneKey = sceneKey
    }

    /// The deepest buildable squish over all faces (mm, full load), for the exaggeration.
    public var maxDepthMM: Double {
        faces.flatMap(\.cells).reduce(0) { Swift.max($0, $1.w > 0.5 ? Double($1.x) : 0) }
    }
    /// The largest exaggeration at which the walls still follow the dent (no column's face
    /// passes the shader's 0.95 clamp).
    public var maxSafeScale: Double { faces.maxSafeScale }
}

/// What the page hands MetalMeshView for the lattice.
public enum FlexibleLatticePreview {
    /// ★ ONLY IN X-RAY, ONLY WITH A LATTICE (maintainer: "Imagine an 'X-ray vision' with a
    /// plane with a heat map for the dent"): out of X-ray the body is opaque and the walls
    /// would be marched for nothing. Hidden while a new lattice builds, so the superseded
    /// one does not draw (the octet's `latticeHidden` rule during a rebake).
    /// ★ HIDDEN, NOT nil, OUT OF X-RAY: nil tears the pass down, and turning X-ray back on then
    /// recompiled its library and re-uploaded its volumes on the main thread — every View
    /// tap. A hidden pass leaves #354's frame byte-identical (T12) and re-shows by token.
    /// nil only when there is no lattice at all.
    /// `latticeShows`: the lattice decides the map (`latticeShows(checkStampShown:)`);
    /// while a stamp owns the map, the walls hide rather than squish by numbers the dent is
    /// not drawn with.
    /// `loop`: the MAIN page's squish loop, run by the renderer (FlexibleSquishLoop); nil on
    /// the Settings page, whose own ticker moves the one flexScale.
    public static func inputs(xray: Bool, lattice: FlexibleGeneratedLattice?, building: Bool,
                              latticeShows: Bool = true, loop: FlexibleSquishLoop? = nil) -> FlexibleLatticeLayerInputs? {
        guard let g = lattice else { return nil }
        return FlexibleLatticeLayerInputs(lattice: g.inputs, faces: g.faces, token: g.generation,
                                          hidden: building || !xray || !latticeShows, loop: loop)
    }

    /// The generated lattice owns the map, the dent and the walls whenever no check stamp is
    /// shown AND it still matches the settings; a stamp's dent ("Dent under the stamp") keeps
    /// its own map. ★ ROUND 3: the X / Y / 3D steps are gone (both curves are drawn at once
    /// and the map always bends), so the rule no longer depends on a step.
    /// ★ A STALE LATTICE NEVER OWNS THE MAP (verification of round 3): once a curve, the depth
    /// or a weight changed, the map is his live drawing, held still — the lattice's old depths
    /// looping beside it hid every edit (the rule a curve step used to give) — and its walls
    /// hide rather than squish by numbers the dent is not drawn with.
    public static func latticeShows(checkStampShown: UUID?, stale: Bool = false) -> Bool {
        checkStampShown == nil && !stale
    }

    /// The lattice the page DRAWS (and whose depths the map shows): only in X-ray, not while a
    /// new one builds, and only while it owns the map (`latticeShows`). The page's one call.
    public static func drawn(_ lattice: FlexibleGeneratedLattice?, xray: Bool, building: Bool,
                             checkStampShown: UUID?, stale: Bool) -> FlexibleGeneratedLattice? {
        xray && !building && latticeShows(checkStampShown: checkStampShown, stale: stale) ? lattice : nil
    }

    /// What the page's "a fresh lattice is shown" reset is keyed on: the GENERATION, so
    /// "Generate again" is fresh too (a `lattice != nil` key stayed true across a rebuild).
    public static func freshKey(_ lattice: FlexibleGeneratedLattice?) -> Int? { lattice?.generation }
}
