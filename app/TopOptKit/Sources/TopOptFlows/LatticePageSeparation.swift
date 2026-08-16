// LatticePageSeparation.swift — ★ THE TO PAGE HAS ZERO LATTICE ON IT
// (task 2026-08-14-lattice-separation §1 and §2).
//
// ★ THE MAINTAINER'S SENTENCE, WHICH EVERYTHING ELSE FOLLOWS FROM:
//
//   "It is VERY important we separate the TO and Lattices out so the user can
//    choose between JUST TO or TO+lattice and have complete control with where
//    the lattice goes — or choose to set it automatically."
//
// PR 328 put the lattice DECLARATION on the TO page, on the theory that "don't TO
// here, lattice here" is one decision about one face taken where the faces are.
// That was the wrong shape: it made a topology-only run look like an unfinished
// lattice run, and it put six lattice affordances on a page whose user may never
// want a lattice at all.
//
// SO THE PAGE IS A STAGE, AND THE STAGE DECIDES WHAT IS ON SCREEN. Both stages
// are the SAME view over the SAME models — the Selections library, the button
// sizes, the gizmo position and the bottom bar are literally the same code, which
// is the only way "seeing the same style of page as before" can be true rather
// than approximately true (§3a; the round-3 complaint was that the buttons "feel
// different").
//
// ★ VISIBILITY IS NOT ARMING. Hiding the design box on the lattice stage does not
// disable it, and hiding the depth planes on the TO stage does not stop the depth
// from driving the protection (§2c). `LatticePageSeparationTests
// .testHidingIsNotDisabling` drives the emission on both stages and requires the
// SAME job — because "hidden" quietly becoming "off" is exactly the class of
// defect that produced empty lattices for weeks.

import Foundation

/// Which stage of the workspace is on screen.
public enum WorkspaceStage: String, Equatable, Sendable, CaseIterable {
    /// ★ THE TO PAGE. Anchors, loads, protect, keep-clear, the design box,
    /// Optimize. NOTHING about a lattice beyond one navigation button (§1a/§1b).
    case topology
    /// ★ THE LATTICE PAGE. The same page, the same style, lattice roles (§3).
    case lattice
    /// ★ THE SURFACE PAGE (§6, task 2026-08-15-lattice-and-face-ui). Editing the
    /// CAD faces themselves: select one, select the ones like it, cut one in two.
    /// The maintainer's ruling: *"I don't see 'Surface' mode. I think it should be
    /// a whole different 'Stage' with a button visible in both the TO and Lattice
    /// stages, below their respective Stage buttons."*
    case surface

    /// The title this stage's own button carries. Two words at most (R7).
    public var title: String {
        switch self {
        case .topology: return "Topology"
        case .lattice: return "Lattice"
        case .surface: return "Surface"
        }
    }

    /// ★ THE WAY BACK, or nil on the root. Topology is the root — you do not
    /// "go back" from it — so it is the destination of every other stage's
    /// top-left button and carries none of its own.
    public var back: WorkspaceStage? {
        self == .topology ? nil : .topology
    }

    /// ★ THE TOP-RIGHT NAVIGATION COLUMN — the stages you can go to FROM here,
    /// in a fixed reading order.
    ///
    /// ★ "WHERE YOU GO" ABOVE "WHAT YOU CONFIGURE" (the maintainer's own phrase,
    /// approved 2026-08-14). This column is navigation ONLY; a stage's settings
    /// button (today: the lattice wizard) is rendered BELOW it, never among it.
    /// That is why Surface takes the top slot on the lattice stage and Settings
    /// moves down one.
    public var forward: [WorkspaceStage] {
        switch self {
        case .topology: return [.lattice, .surface]
        case .lattice:  return [.surface]
        // ★ NO ONWARD NAV FROM SURFACE (maintainer, 2026-08-16: "Please make the
        // Save button much larger and place it where the greyed out 'Lattice'
        // button is (removing the greyed out lattice button)").
        //
        // The slot is worth more to SAVE than to a link. On this stage Lattice was
        // greyed out anyway — it needs an anchor and a load, which are set on the
        // Topology page — so it was a disabled button occupying the one place the
        // eye goes. Surface still reaches everywhere through the Topology button
        // top-left; nothing is unreachable.
        case .surface:  return []
        }
    }

    /// Kept for the call sites that predate the third stage: the FIRST forward
    /// destination's title.
    public var navigationTitle: String { forward.first?.title ?? "Topology" }
}

/// The parts a group row in the Selections library can be built from.
public enum LatticeGroupRowSection: String, Equatable, Sendable, CaseIterable {
    /// The keep-clear primitive chips + the per-row Sync box. The TO page's row,
    /// unchanged from before the separation.
    case clearanceEditor
    /// ★ THE COLLAPSED ROW (§4d): the grams handed over, and the verdict as
    /// COLOUR. One thing, and nothing else.
    case latticeSummary
    /// ★ THE DRAWER (§4a), beneath the group squircle, collapsed by default.
    case latticeDrawer
    /// ★ ONE ROW PER PRIMITIVE, each with its own lattice / no-lattice (§3c).
    case latticePrimitiveRows
}

/// What each stage draws in the viewport and offers in the Selections library.
///
/// ★ HIS WORDS (§2): "all primitives in TO like the Design Box and Group
/// Primitives should NOT be visible on the Lattice page. And the Lattice
/// primitives should NOT be visible in the TO page."
public struct WorkspaceStageVisibility: Equatable, Sendable {

    /// The translucent design box + its keep-out boxes.
    public let designBox: Bool
    /// The group primitives: the manual keep-out primitives, their transform
    /// gizmo, their clearance drag handles and their on-model value chips.
    public let groupPrimitives: Bool
    /// The red keep-clear clearance volumes.
    public let keepOuts: Bool
    /// ★ The lattice DEPTH PLANES — the slab each latticed face casts into the
    /// part, and the 3D handle that drags it (§3d).
    public let latticeDepthPlanes: Bool
    /// The per-primitive lattice / no-lattice controls and the region drawer.
    public let latticeControls: Bool
    /// ★ §6(b) — WHETHER THIS STAGE OFFERS THE MODEL'S WIREFRAME (and its x-ray).
    ///
    /// ★ A PERMISSION, NOT A STATE. The toggle itself lives in the page and is
    /// shared across stages, because the maintainer asked for exactly that: "We
    /// should keep wireframe and xray view throughout the entire app." This column
    /// says where the CONTROL appears; whether the lines are drawn is the toggle's
    /// business.
    ///
    /// True on Topology and Surface. It stays false on the LATTICE stage, whose
    /// geometry is a lattice preview rather than the imported B-rep — the edge set
    /// would describe a surface that stage is not showing.
    public let wireframe: Bool
    /// ★ §6 — the face-editing affordances: the hover preview, the cut's rotate
    /// control, the similar-faces double tap.
    public let surfaceEditing: Bool

    public init(designBox: Bool, groupPrimitives: Bool, keepOuts: Bool,
                latticeDepthPlanes: Bool, latticeControls: Bool,
                wireframe: Bool = false, surfaceEditing: Bool = false) {
        self.designBox = designBox
        self.groupPrimitives = groupPrimitives
        self.keepOuts = keepOuts
        self.latticeDepthPlanes = latticeDepthPlanes
        self.latticeControls = latticeControls
        self.wireframe = wireframe
        self.surfaceEditing = surfaceEditing
    }

    /// ★ WHAT A GROUP ROW IN THE SELECTIONS LIBRARY CONTAINS, on this stage.
    ///
    /// The row builder switches over exactly this list, so a section that is not
    /// in it is not BUILT — which is how "no lattice control, chip, readout or
    /// state text survives on the TO page" (R2) becomes a property the tests can
    /// read rather than a claim about a view.
    public var rowSections: [LatticeGroupRowSection] {
        latticeControls
            ? [.latticeSummary, .latticeDrawer, .latticePrimitiveRows]
            : [.clearanceEditor]
    }

    /// THE ONE TABLE. Every visibility site in the workspace reads this rather
    /// than testing the stage itself, so a new affordance cannot be added to one
    /// stage by accident — it has to be given a column here first.
    public static func of(_ stage: WorkspaceStage) -> WorkspaceStageVisibility {
        switch stage {
        case .topology:
            // ★ THE WIREFRAME AND X-RAY REACH THE TO PAGE (maintainer, 2026-08-16:
            // "We should keep wireframe and xray view throughout the entire app.
            // Please add to the TO page side-by-side just below the position
            // gizmo"). It is the same imported B-rep, so the same edge set — and
            // with it, the cuts and unions made on the Surface stage, which is how
            // you see on the TO page what you did on the Surface one.
            return WorkspaceStageVisibility(designBox: true, groupPrimitives: true,
                                            keepOuts: true,
                                            latticeDepthPlanes: false,
                                            latticeControls: false,
                                            wireframe: true)
        case .lattice:
            return WorkspaceStageVisibility(designBox: false, groupPrimitives: false,
                                            keepOuts: false,
                                            latticeDepthPlanes: true,
                                            latticeControls: true)
        case .surface:
            // ★ §6(a) — "NO PRIMITIVES ARE VISIBLE IN THIS MODE. None. Not dimmed
            // — hidden." Every primitive column is false, and the wireframe is on
            // so the faces you are editing are the only thing on screen.
            return WorkspaceStageVisibility(designBox: false, groupPrimitives: false,
                                            keepOuts: false,
                                            latticeDepthPlanes: false,
                                            latticeControls: false,
                                            wireframe: true,
                                            surfaceEditing: true)
        }
    }
}
