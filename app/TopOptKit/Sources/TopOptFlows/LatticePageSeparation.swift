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

    /// The title the stage's own navigation button carries. Two words at most (R7).
    public var navigationTitle: String {
        self == .topology ? "Lattice" : "Topology"
    }
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

    public init(designBox: Bool, groupPrimitives: Bool, keepOuts: Bool,
                latticeDepthPlanes: Bool, latticeControls: Bool) {
        self.designBox = designBox
        self.groupPrimitives = groupPrimitives
        self.keepOuts = keepOuts
        self.latticeDepthPlanes = latticeDepthPlanes
        self.latticeControls = latticeControls
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
            return WorkspaceStageVisibility(designBox: true, groupPrimitives: true,
                                            keepOuts: true,
                                            latticeDepthPlanes: false,
                                            latticeControls: false)
        case .lattice:
            return WorkspaceStageVisibility(designBox: false, groupPrimitives: false,
                                            keepOuts: false,
                                            latticeDepthPlanes: true,
                                            latticeControls: true)
        }
    }
}
