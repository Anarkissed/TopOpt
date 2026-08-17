// WorkspacePlaceholder.swift — the workspace stage with the M7.6 force & gravity
// experience (MOD-F1 D1–D6; docs/design/TopOpt_force_proto.html).
//
// M7.4 rendered the mesh; M7.5 added face-selection groups. M7.6 replaces the
// Orbit/Faces/Force tool segment (deleted per D1: drag always orbits, tap always
// selects) with the force/gravity flow:
//   * D2 — a post-import "which way is down?" gravity prompt; tapping a face sets
//     gravity (its outward model-space normal) and a persistent gravity chip with
//     "Change" appears.
//   * D3 — an explicit Anchor | Load chip beside a live selection (no implicit
//     "arrow-less = anchor" rule / explainer).
//   * D4 — a load spawns along gravity; its direction changes only via the snap
//     row Gravity / Push / Pull.
//   * D5 — the weight is edited in place on a pill: horizontal scrub to change,
//     tap to type; a global kg / lbs toggle. No modal dialog.
//   * Optimize enables only with ≥1 anchor and ≥1 load and summarizes the case.
//
// All the *logic* here (gravity vector, roles, direction, weight, optimize
// enablement) lives in the headlessly-tested ForceModel / SelectionModel /
// ViewerMesh.faceNormal; this SwiftUI shell renders over them and is maintainer
// device QA (the M7 /app/ standard). The 3D settle animation + ground grid, the
// projected-to-centroid floating placement of these controls, and the in-scene
// force arrows are pure Metal-renderer visuals deferred to a renderer follow-up
// (see the handoff); the interaction + data are complete and driven from the model.

import SwiftUI
import simd
import TopOptKit
import TopOptDesign

public struct WorkspacePlaceholder: View {
    @ObservedObject var model: AppModel
    /// The per-project working state, OWNED by AppModel so it survives navigation
    /// (M7.x-persist-a). The mesh / selection groups / force load case / run all
    /// live here; the workspace forwards to them via the computed properties below
    /// so its call sites are unchanged from the old `@State`.
    @ObservedObject var project: ProjectModel

    /// The load group whose weight is being typed (nil = none / scrub mode).
    /// Which load's weight pill has the compact number pad open (numeric-input handoff);
    /// nil = none. A tap opens the pad beside the pill — never the system keyboard.
    @State private var weightPadGroup: UUID?
    @State private var scrubBase: Double?
    /// The latest camera→screen projection the viewer publishes, so the floating
    /// overlays + arrows track the 3D selection as the camera moves (M7.6 D3–D6).
    @State private var projection: CameraProjection?
    /// The ONE shared orbit camera for the workspace stage (STEP 1) — driven by both the
    /// Metal viewer's drag and the orientation gizmo.
    @StateObject private var cameraModel = OrbitCameraModel()
    /// WHERE the run executes (handoff 097): iPad by default, or a LAN worker
    /// discovered by Bonjour. Owned here so the choice + discovery live for the
    /// workspace session; nil `activeRemote` → the on-device bridge runner (unchanged).
    @StateObject private var compute = ComputeLocationModel()
    /// The lattice viewer proxy (handoff 2026-07-28): shades the part surface by local
    /// lattice DENSITY instead of rendering the ~316k-triangle-and-up lattice mesh the
    /// device cannot hold. Off by default; when on, feeds the density tints into the
    /// viewer's existing per-vertex colour channel (zero new GPU buffers) and shows the
    /// honest legend + true-geometry sample patch.
    @StateObject private var latticeProxy = LatticeProxyModel()
    // Strut preview (handoff 2026-07-29-lattice-preview): the raymarched TRUE-strut
    // layer. Off by default → the workspace draw is byte-identical. The scene (part
    // occupancy + exact narrow-band SDF + segment soup) bakes ONCE off-main when the
    // toggle turns on or the lattice type changes — never per frame (P2).
    /// Whether the build-orientation panel is unfurled beneath its chip (handoff
    /// 2026-08-01-build-direction-separation). Purely presentational — the panel's
    /// state lives on the project, so closing it never discards a choice.
    @State private var showBuildOrientation = false
    @State private var showStrutPreview = false
    @State private var strutScene: LatticeSDFScene? = nil
    @State private var strutSceneToken = 0
    /// Snap the settle instead of animating it, for reduced-motion users (D2).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When a project has saved variants, results show by default; tapping "See
    /// Original" flips this to reveal the editable workspace (the variants stay).
    @State private var viewOriginal = false
    /// Rename dialog (tap the project title).
    @State private var renaming = false
    @State private var nameDraft = ""
    /// Collapse the (bottom-left) Selections panel by tapping its header.
    @State private var selectionsCollapsed = false
    /// ★ The Regions surface (task 2026-08-14-face-regions). Opened from the
    /// Selections header; it is where a union, a filter and a split are made.
    @State private var regionsOpen = false
    /// The region a viewer tap corrects, or nil. Hoisted out of the sheet so the
    /// workspace's tap router can see it — the sheet SELECTS, the viewer EDITS.
    @State private var regionTapTarget: RegionID?
    /// The request that was last optimized — Optimize greys out until the inputs
    /// (load case / material / quality) change from it (or a run is in flight).
    @State private var lastRunRequest: RunRequest?
    /// The group whose colour-swatch popover is open (nil = none).
    @State private var recoloringGroup: UUID?

    // Group editing (handoff group-editing). A group the user tapped is LOCKED IN
    // (`selection.activeGroupID`); rename fires ONLY when the NAME is tapped (sets
    // `renamingGroup`), never the group body. `addingPrimitiveGroup` drives the
    // CYLINDER/PLANE picker for the "+" affordance; `lastSnapLabels` surfaces what a
    // move detent snapped to.
    @State private var renamingGroup: UUID?
    @State private var addingPrimitiveGroup: UUID?
    /// Round-2 T2: the group whose primitive CHIPS are revealed. Chips open only
    /// after an explicit tap on the primitive (its knob), one of its faces on the
    /// model, or its group row in the library — never as a side effect of a face
    /// tap that merely grew a selection (the "too easy to hit by accident" report).
    @State private var chipsRevealedGroup: UUID?
    @FocusState private var renameFieldFocused: Bool

    // ★ THE BARRIER MODEL on the face page (task 2026-08-12 §0b / §5a).
    // `latticeFaceCards` is what each role face hands the lattice at its CURRENT
    // dragged depth, plus the per-region verdict core's own bounds produce —
    // computed off the main thread from ONE voxelization and cached, so a drag
    // never blocks. `latticeDepthDragSeed` holds the depth a drag started from.
    @State private var latticeFaceCards: [UUID: LatticeFaceCard] = [:]
    // ★ AND ONE CARD PER SELECTABLE, AT THAT SELECTABLE'S OWN DEPTH (task
    // 2026-08-17-lattice-stage-repair §2). Keyed by `LatticeSelectableRef.key`.
    // Before this task there was only the group dictionary above, and the drawer
    // under a face or a region row was handed the GROUP's card while being
    // labelled with the selectable's own depth — so dragging a face's 3D handle
    // moved the label and nothing else on the card. The two are one value now,
    // and `LatticeRegionDrawer.depthDivergence` is what proves it.
    @State private var latticeSelectableCards: [String: LatticeFaceCard] = [:]
    @State private var latticeDepthDragSeed: Double?
    // ★ The depth detent currently HELD (maintainer, 2026-08-17). Non-nil while a
    // drag is magnetised to a candidate; the hysteresis band is measured from it,
    // so it must span frames. Cleared on `onEnded`.
    @State private var latticeDepthDetent: LatticeDepthDetent.Candidate?
    // ★ The CAD-surfaces drawer's disclosure (maintainer, 2026-08-17: "when you
    // click on it, a on/off glass slider is made visible in a drawer").
    @State private var cadFacesDrawerOpen = false
    // The expand handle currently being dragged (nil = none).
    @State private var draggingExpandPlane: String?
    /// ★ §3(b) — which group's (i) pop-up is open. One at a time, PER UNION.
    @State private var diagnosisPopoverGroup: UUID?
    /// ★ §5 — which DEPTH field has the numeric keypad open. Keyed by the row's
    /// identifier so a group row and a selectable row cannot share one pad.
    @State private var depthPadKey: String?
    /// ★ §6(g) — THE HOVERED CUT. Where the pencil currently is over the model,
    /// as a cut plane, before anything is committed. Nil when nothing is hovered.
    @State private var hoveredCut: SurfaceCut?
    /// ★ §6(h) — the rotation applied to the hovered/held cut, in degrees.
    @State private var cutRotation: Double = 0
    /// The cut the user has TAPPED and is now aiming — the one the checkmark
    /// commits. Nil while merely hovering.
    @State private var heldCut: SurfaceCut?
    /// Where the current rotate drag started, so successive drags accumulate.
    @State private var cutRotationBase: Double = 0
    /// §6 — how far the cut has been nudged off the piece's centre, in mm, along
    /// the plane's own normal (the only direction that moves it).
    @State private var cutOffsetMM: Double = 0
    /// §6(b) — the wireframe switch. ★ OFF BY DEFAULT (maintainer, 2026-08-16: "I
    /// also don't want the wireframe view to be the default. Please turn off all
    /// views by default"). A view aid is something you reach for, not the resting
    /// state of the page — and the stage reads as the part rather than as a drawing
    /// of it until you ask.
    @State private var surfaceWireframeOn = false
    /// §6 — X-RAY, its own switch. Off by default: seeing every hidden edge at once
    /// is a specific request, not the resting state of a page about surfaces.
    @State private var surfaceXrayOn = false
    /// ★ THE ARMED TOOL. `select` by default — the one tool that edits nothing, so
    /// arriving on the stage cannot make the first exploratory tap destructive.
    @State private var surfaceTool: SurfaceTool = .initial
    /// The region an action will act on — a HALF of a cut face, once one is cut.
    @State private var surfaceSelected: RegionID?
    /// The tapped FACE when it has no region of its own — so an ordinary face can
    /// be selected and lit without selection quietly creating model state.
    @State private var surfaceSelectedFace: FaceID?
    /// The pattern tool's grid, before it is committed.
    @State private var patternColumns = 3
    @State private var patternRows = 1
    /// §7 — the user's own rotation of the grid, ON TOP of the automatic alignment
    /// to the face's longest edge. Drag the knob; releases on 15°.
    @State private var patternRotation: Double = 0
    @State private var patternRotationBase: Double = 0
    /// The face the pattern tool is aimed at.
    @State private var surfacePatternFace: FaceID?
    /// The PIECE the pattern divides — the region under the tap, captured at the
    /// tap. Looked up later it becomes "the deepest region on this face", which
    /// after a cut is one particular half and not necessarily the one you touched.
    @State private var surfacePatternPiece: RegionID?
    /// ★ THE UNION TOOL ACCUMULATES *REGIONS*, NOT FACES.
    ///
    /// ★ THIS IS WHY MULTI-SELECT COULD NOT REACH TWO. The two halves of a cut face
    /// are two REGIONS sharing ONE CAD face id — a cut never re-partitions layer 1.
    /// Held as a `Set<FaceID>`, tapping either half hands the set the SAME id, so
    /// the second tap toggled the first one back OFF. The count sat at 1 forever,
    /// which is exactly what "Still cannot select the two split faces to union
    /// them" looks like. A set of FACES cannot represent two pieces of one face;
    /// only a set of REGIONS can.
    @State private var surfaceUnion = SurfaceUnion()
    /// §6(c) — the filter derived from the tapped face, and the face it came from.
    /// §6(c) — the KINDS of face currently selected. A multi-select of RULES, not
    /// of faces: see `SurfaceSimilar`.
    @State private var similar = SurfaceSimilar()
    /// ★ THE FACES A SELECT-SIMILAR HANDED TO THE NEXT TOOL. Empty unless a tool
    /// was picked while a similar selection was live; the cut and pattern confirms
    /// read it so their action lands on ALL of them rather than on the one face the
    /// controls happen to be aimed at.
    @State private var surfaceCarried: [FaceID] = []
    /// Where the current move drag started, and how fast it slides.
    @State private var cutOffsetBase: Double = 0
    /// Why the last surface tap was refused, shown in the panel. Nil when it wasn't.
    @State private var surfaceRefusal: String?

    /// ★ THE SURFACE STAGE'S SCRATCHPAD (maintainer, 2026-08-16: "I think we should
    /// have a 'Save' button on the Surfaces page. This way someone can fuck around
    /// and mess things up, and just go back and nothing is saved. Everything should
    /// reset when you leave and come back — unless it has been saved").
    ///
    /// What the model looked like on ENTERING the stage. Leaving without saving puts
    /// it back; Save drops it, which is what makes the edits permanent.
    @State private var surfaceEntrySnapshot: SurfaceScratch?

    /// ★ The bottom bar's MEASURED height — its CONTENT only, without the inset
    /// that lifts it off the bottom edge. Seeded at the one-line Optimize height
    /// so the first frame is right. Read through `bottomBarClearance`, never
    /// directly: the inset is part of what a view above the bar has to clear.
    @State private var bottomBarHeight: CGFloat = 50

    /// ★ HOW FAR ABOVE THE BOTTOM EDGE ANYTHING MUST SIT TO CLEAR THE BAR — the
    /// bar's measured content plus the inset it floats on. One expression, so a
    /// second call site cannot clear a different amount than the first.
    private var bottomBarClearance: CGFloat { bottomBarHeight + DS.Space.xl4 }
    @State private var latticeCardsToken = 0

    // DEFECT 2 — the manual-primitive TRANSFORM GIZMO. `gizmoTarget` is the primitive the
    // gizmo is attached to (nil = no gizmo shown). `gizmoDrag` captures the grab context of
    // the handle currently being dragged (a value type on @State so it survives the
    // body-update churn a live drag causes). `gizmoSnap` keeps the magnetic detents ON (round 3
    // removed the crosshair toggle, not the snapping); `gizmoSnapLabels` surfaces what the last
    // drag frame snapped to.
    @State private var gizmoTarget: GizmoTarget?
    @State private var gizmoDrag: PrimitiveGizmo.Drag?
    @State private var gizmoSnap = true
    @State private var gizmoSnapLabels: [String] = []
    /// Which 15°-tick the current rotation drag has passed, so a haptic fires once per step.
    @State private var gizmoRotTickStep = 0
    /// The raymarched gizmo's glowing handle (0 = hub/free, 1…3 = arms X/Y/Z, 4…6 = plane squares,
    /// 7…9 = rotation ribbons XY/YZ/ZX), or -1.
    @State private var gizmoActiveId: Float = -1
    /// True while a drag that started on empty gizmo-box space is orbiting the camera.
    @State private var gizmoBoxOrbiting = false
    /// The previous drag location, for orbit deltas / first-frame guard.
    @State private var gizmoBoxDragLast: CGPoint?

    // Lattice mode (handoff 2026-07-29-lattice-mode-ui → 2026-07-30-lattice-page).
    // The full-screen lattice PAGE replaced the old side panel; the lattice-region
    // gizmo drag state stays — the region reuses the SAME transform-gizmo
    // components as the manual primitives (renderer + SDF pick + PrimitiveGizmo.Drag),
    // committing to `project.lattice.region` instead of a force-group primitive.
    @State private var showLatticePage = false
    /// ★ PAGE 3 — the LATTICE SETTINGS wizard (task 2026-08-12 §2, rearranged by
    /// task 2026-08-14 §5). Opened from the LATTICE STAGE, not the TO page. The
    /// variant path keeps `showLatticePage`: that page relattices a finished design
    /// and carries the ladder, the sim and the receipt, which the wizard
    /// deliberately does not.
    @State private var showLatticeWizard = false

    /// ★ WHICH STAGE THE WORKSPACE IS SHOWING (task 2026-08-14-lattice-separation
    /// §1/§2/§3). The TO page and the lattice page are the SAME page — same
    /// Selections library, same button sizes, same gizmo position — differing only
    /// in what `WorkspaceStageVisibility` lets each of them draw. That is the only
    /// way "seeing the same style of page as before" can be structurally true.
    @State private var stage: WorkspaceStage = .topology
    /// ★ THE ONE DISCLOSURE STATE IN THE SELECTIONS PANEL (bar R12). A region's
    /// expansion is stored in PR 331's own `FaceRegion.collapsed`; a group's and a
    /// face's live in this value. One type, one call, and the region case is
    /// literally the same bit the Regions sheet reads.
    @State private var latticeDisclosure = LatticeRowDisclosure()
    /// The depth plane whose 3D handle owns the current drag (§3d), and the depth
    /// it started from.
    @State private var draggingDepthPlane: String?

    /// What this stage may draw. Every visibility site reads THIS, never `stage`.
    private var visible: WorkspaceStageVisibility { .of(stage) }
    /// The variants-entry demand field (that run's own von Mises); nil from the
    /// workspace entry (bar B6's two paths).
    @State private var latticePageVariantField: LatticeDemandField?
    /// The finished VARIANT the lattice page is working on (task
    /// 2026-08-02-lattice-a-variant, bars Z7/Z9/Z11). Non-nil ONLY when the page
    /// was entered from the variants list. When it is set the stage renders THAT
    /// VARIANT'S geometry, face tapping is off (a TO surface has no selectable
    /// faces), and the page offers "Lattice this variant" as a job distinct from
    /// re-running the ladder.
    @State private var latticeVariantContext: LatticeVariantContext?
    /// The variant's own render-ready mesh, built once when the page opens so the
    /// stage does not rebuild it per frame (the viewer-lag lesson).
    @State private var latticeVariantMesh: ViewerMesh?
    @StateObject private var latticeSim = LatticeSimModel()
    @StateObject private var latticePageModel = LatticePageModel()
    /// The pre-flight forecast (bar F3). Held HERE, not in the page, so closing and
    /// reopening the lattice page does not throw away an answer that is still true.
    @StateObject private var latticeForecast = LatticeForecastModel()
    @State private var latticeRegionDrag: PrimitiveGizmo.Drag?
    @State private var latticeRegionActiveId: Float = -1
    @State private var latticeRegionOrbiting = false

    // The SMOOTHING page (handoff 2026-08-02-smoothing-page) — the third page,
    // entered from a finished variant. Like the lattice page it is CHROME over the
    // same live stage, and while it is open the stage renders THAT variant (or its
    // smoothed twin, per `smoothingPageModel.currentGeometry`).
    @State private var showSmoothingPage = false
    @State private var smoothingPageModel: SmoothingPageModel?
    /// The brush. Owned here so a stroke on the stage and the panel's region list
    /// are one value.
    @State private var smoothBrush = SmoothBrushModel(indices: [], vertexCount: 0,
                                                      freeze: .unavailable)
    /// The brush's OWN tools — paint / erase / orbit and the disc size (bar L4).
    /// Round 1 borrowed the TO page's paint drawer for these, which is why the
    /// page could not hide the TO chrome without disarming its own brush.
    @State private var smoothTools = SmoothBrushTools()
    /// The variant's own render mesh, and the smoothed twin once one has been
    /// certified. Built once when they change (the viewer-lag lesson).
    @State private var smoothVariantMesh: ViewerMesh?
    @State private var smoothedVariantMesh: ViewerMesh?
    /// Where the variant's mesh was written for the certification engine to read.
    @State private var smoothVariantMeshPath = ""

    // Gravity DIRECTION widget (2026-07-26 — "set gravity by pointing, not by hunting for a
    // clean face"). During setup the user drags an arrow to point which way is down instead
    // of tapping a face (the STL pseudo-face segmentation makes a face tap unreliable);
    // face-tap stays as a shortcut where it lands cleanly. `gravityDraft` is the pending
    // model-space direction while pointing (nil → follow the current gravity, else −Y);
    // `gravityDrag` is the pure-math grab context (survives the body churn a live drag
    // causes); `gravitySnap` is the axis magnet; `gravitySnapLabel` drives the "Snapped to"
    // badge. Committing calls `ForceModel.setGravity(direction:)` — the SAME stored vector
    // the face tap writes, so the job can't tell them apart (BAR V1).
    @State private var gravityDraft: SIMD3<Float>?
    @State private var gravityDrag: GravityDirectionGizmo.Drag?
    @State private var draggingGravity = false
    @State private var gravitySnap = true
    @State private var gravitySnapLabel: String?
    // Round 2 (2026-07-27): the arrow's BASE is movable via the transform gizmo and magnetically
    // attaches to any face. `gravityBaseDraft` is the pending base while editing (nil → the
    // stored `force.gravityBaseModel`, else the mesh centre); `gravityBaseDrag` is the transform
    // gizmo's pure-math grab context; `gravityBaseActiveId` glows the grabbed handle; the orbit
    // flags let an empty-box drag fall through to the camera. The base is PURELY VISUAL — it is
    // committed to `ForceModel.gravityBaseModel` (which no run/serializer reads) so it round-trips
    // but never reaches the job (BAR V4).
    @State private var gravityBaseDraft: SIMD3<Float>?
    @State private var gravityBaseDrag: PrimitiveGizmo.Drag?
    @State private var gravityBaseActiveId: Float = -1
    @State private var gravityBaseSnapped = false
    @State private var gravityBaseOrbiting = false
    @State private var gravityBaseDragLast: CGPoint?

    /// The primitive a transform gizmo is bound to (group + primitive id).
    struct GizmoTarget: Equatable { let group: UUID; let id: UUID }
    /// M7.dom-app / design-overhaul 109: the SINGLE-OWNER design-box drag session. Captures the
    /// box (or keep-out) at the start of the owning handle's drag so each frame applies an
    /// absolute delta from the drag-start snapshot, and REJECTS any concurrent second handle so
    /// two overlapping gestures can't fight over the box (the "ghost duplicate boxes" bug — see
    /// `DesignBoxDragSession`).
    @State private var boxDrag = DesignBoxDragSession()
    /// handoff 111: a debug-toggleable diagnostic HUD for the design-box drag (chosen
    /// handle, owner, base→current delta in points + mm). Toggled by a long-press on
    /// the design-box panel header. Ships off; the maintainer flips it on and a
    /// screenshot then carries the diagnosis if the drag ever misbehaves again.
    @State private var boxDragDebug = false
    /// BAR 4: the pending "this replaces your finished variants" confirmation.
    /// Non-nil presents it; the user either confirms (the run starts) or cancels
    /// (nothing happens, and the variants are untouched).
    @State private var pendingReplacement: ResultsReplacementPrompt?
    /// The live diagnostic for the in-flight box drag (nil between drags).
    @State private var boxDragDiag: BoxDragDiagnostic?
    /// The magnetic face-detent candidate the dragged box face is currently HELD on (device
    /// round 3, item 10), or nil when the face is free. Carried across drag frames to drive the
    /// snap/release hysteresis; reset when the drag ends.
    @State private var boxFaceDetent: Float?
    /// The pending detent face-highlight pulse (device round 3, item 2): the part face a box-face
    /// drag just snapped to, flashed in the Metal viewer (replaces the old "Snapped to face"
    /// toast). The token advances on every fresh snap so re-snapping the SAME face re-pulses.
    @State private var detentPulse: DetentPulse?
    /// Measured intrinsic width (points) of each bottom-right settings chip, so the cluster
    /// orders them smallest→largest (design-overhaul round 2, item 12; `BottomChipOrder`).
    @State private var settingsChipWidths: [SettingsChipID: CGFloat] = [:]

    /// The debug HUD payload for a box drag (handoff 111).
    struct BoxDragDiagnostic: Equatable {
        var handle: DesignBoxDragSession.HandleID
        var owner: DesignBoxDragSession.HandleID?
        var deltaPoints: CGSize
        var deltaMM: Float
    }
    /// Keep-clear Phase B: which clearance handle is currently being dragged (id =
    /// "group:face:role"), nil = none. Drives the live-readout highlight + haptics.
    @State private var draggingHandleID: String?
    /// The last mm value written this drag, to fire a haptic tick when it crosses Auto.
    @State private var lastHandleValue: Float?
    /// Paint mode (handoff 2026-07-25): ON → a one-finger drag brushes triangles into the active
    /// group (the escape when tap-selection over-selects); OFF → tap-select is unchanged. The
    /// painted region becomes a pseudo-face routed through the SAME face-id contract as a tap.
    @State private var paintActive = false
    /// Paint mode: the erase MODIFIER — when on, the brush reverts triangles to their native face.
    @State private var paintErasing = false
    /// Paint mode: brush radius in view points; a small stepper in the paint drawer changes it.
    @State private var brushRadiusPoints: CGFloat = 26

    // Forwarders onto the project's persistent state. The `nonmutating set`
    // mutates the ProjectModel (a reference), so `selection.mutate()` /
    // `force = …` etc. behave exactly as the previous `@State` did — republishing
    // and re-rendering — while the storage now outlives the view.
    private var viewerMesh: ViewerMesh? {
        get { project.viewerMesh }
        nonmutating set { project.viewerMesh = newValue }
    }
    private var selection: SelectionModel {
        get { project.selection }
        nonmutating set { project.selection = newValue }
    }
    private var force: ForceModel {
        get { project.force }
        nonmutating set { project.force = newValue }
    }
    private var run: RunModel { project.run }

    private static let identityQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// The run resolution, from the project's chosen quality (Fast/Balanced/Fine).
    private var runResolution: Int { project.quality.resolution }

    // MARK: - sub-voxel load-face warning (handoff 099)

    /// The voxelizer's spacing at the current resolution (mm) — `longest bbox axis /
    /// resolution`, the same `h` topopt::voxelize uses. Nil until a mesh is loaded.
    private var voxelSpacingMM: Double? {
        guard let mesh = viewerMesh else { return nil }
        return VoxelFit.spacing(forBounds: mesh.bounds, resolution: runResolution)
    }

    /// Whether a LOAD group is likely to tag zero voxels at the current resolution:
    /// true only when EVERY face in the group is sub-voxel (the group tags nothing
    /// iff all of its faces do — matching the core, where a group registers if ANY
    /// face tags a voxel). A heuristic — labelled "may not register", never certain.
    private func loadGroupMayNotRegister(_ g: SelectionGroup) -> Bool {
        guard force.kind(for: g.id).isLoad, !g.faces.isEmpty,
              let mesh = viewerMesh, let h = voxelSpacingMM else { return false }
        for f in g.faces {
            guard let fp = VoxelFit.footprint(ofFace: f, in: mesh) else { continue }
            if !VoxelFit.mayTagZeroVoxels(fp, spacing: h) { return false }
        }
        return true
    }

    /// Per load group, its pre-run health for the Optimize pre-flight (099 D3):
    /// zero-force, may-not-register, or ok. Anchors and pending groups are ignored
    /// (only load groups carry a force the run must apply).
    private func loadGroupDiagnoses() -> [LoadGroupDiagnosis] {
        selection.groups.compactMap { g in
            let kind = force.kind(for: g.id)
            guard kind.isLoad else { return nil }
            let n = groupNormalModel(g) ?? SIMD3<Float>(0, 1, 0)
            let f = force.loadForceVectorModel(g.id, groupNormal: n) ?? .zero
            let health: LoadGroupHealth
            if simd_length(f) < 1e-6 {
                health = .zeroForce
            } else if loadGroupMayNotRegister(g) {
                health = .mayNotRegister
            } else {
                health = .ok
            }
            return LoadGroupDiagnosis(label: g.name, health: health)
        }
    }

    public init(model: AppModel, project: ProjectModel) {
        self.model = model
        self.project = project
    }

    /// TRUE while a full-screen PAGE owns the screen — the lattice page or the
    /// smoothing page.
    ///
    /// ROUND-2 BAR L1. The smoothing page shipped drawing over a live TO
    /// workspace: the Design Box panel and its buttons, Paint, the resolution
    /// chip, Minimize plastic, Plate up, Gravity set, the Selections list, the
    /// red clearance primitives and the design-box wireframe were all still there
    /// and still interactive underneath it. That is an overlay, not a page.
    ///
    /// The lattice page already hid the chrome — but it did it by writing
    /// `!showLatticePage` at each site, so the third page had to remember to add
    /// itself to eight separate conditions, and it did not. ONE predicate,
    /// gating every site, is what makes a fourth page correct by default.
    private var fullScreenPageUp: Bool { showLatticePage || showSmoothingPage || showLatticeWizard }

    /// THE BRUSH GESTURE, AS ONE VALUE (task 2026-08-05, bar D1). The SMOOTHING
    /// PAGE OWNS IT while it is up: its brush is the page's whole point, so it
    /// cannot depend on the TO page's Paint toggle — which L1 hides.
    ///
    /// WHAT WENT WRONG HERE. This site used to read `smoothTools.paints`, a
    /// property that answered "does a FINGER paint?", to decide whether the
    /// gesture existed AT ALL — so with "Pencil only" checked it evaluated false,
    /// the viewer's brush was disarmed, and the pencil (which that toggle exists
    /// to privilege) could not paint either. Two mechanisms decided one thing and
    /// the stricter one won. `BrushGesture` is now the only mechanism: `armed`
    /// comes from the MODE, `requiresPencil` decides WHICH contact, and both
    /// travel to the recognizers together.
    private var brushGesture: BrushGesture {
        showSmoothingPage ? .smoothingPage(smoothTools)
                          : .workspacePaint(active: paintActive)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: stageMesh,
                          camera: cameraModel,
                          selection: selection,
                          // ★ §6 — THE SURFACE STAGE DOES NOT WEAR THE TO PAGE'S
                          // COLOURS (maintainer, 2026-08-14: "all colours from the
                          // TO page cannot be the same in the Surface page … they
                          // should all have a slight blue hue to differentiate
                          // faces that can be modified and faces that can't").
                          //
                          // ★ SUPPRESSED, NOT OVERDRAWN. `roleTints` is the ROLE
                          // palette — anchor green, load red, lattice violet — and
                          // those answer a question this stage does not ask. Left
                          // in and merely covered, a role colour would survive
                          // wherever the surface tint has nothing to say, and the
                          // page would read as two colour systems at once. Here
                          // colour means ONE thing: this face can be modified.
                          faceTints: visible.surfaceEditing ? [:] : roleTints,
                          vertexTints: visible.surfaceEditing ? surfaceVertexTints : nil,
                          extraLines: surfaceCutLineBuffer,
                          previewLines: surfacePreviewLineBuffer,
                          // ★ A UNION'S INTERNAL EDGES ARE NOT EDGES ANY MORE.
                          // Two faces combined ARE one face, so the B-rep line
                          // between them stops being a boundary — leaving it drawn
                          // says the union did not happen.
                          weldedFaces: visible.wireframe && surfaceWireframeOn
                              ? project.surfaceWeldedFaces() : [],
                          // ★ THE SURFACE RIBBON IS GONE. It widened each segment in
                          // the plane of ONE face normal and collapsed to nothing
                          // wherever a curve turned edge-on to it — the stray gold
                          // ticks on the maintainer's curved face. The wide-line
                          // pipeline widens in SCREEN space and has no such blind
                          // direction, so the traces ride the wireframe instead.
                          cutRibbon: nil,
                          cutPlane: visible.surfaceEditing && surfaceTool != .union
                              ? SurfaceTint.planeFor(surfaceSelected,
                                                     in: project.faceRegions) : nil,
                          // ★ §6 — THE PICKED PIECES, each as its own half-space
                          // chain, so a tap lights the PIECE and not the whole face
                          // it belongs to ("why are they being considered one face
                          // when I tapped only one of them?"). Union only: the other
                          // tools act on one piece and use `cutPlane` above.
                          pickChains: visible.surfaceEditing && surfaceTool == .union
                              ? SurfaceTint.pickChains(
                                  surfaceUnion.partialPicks(regions: project.faceRegions),
                                  in: project.faceRegions)
                              : [],
                          xray: surfaceXrayOn,
                          settleRotation: settleQuat,           // D2: settle onto the floor
                          settleAnimated: !reduceMotion,
                          showGround: showGround,
                          // D1: tap always selects (routed by phase) — EXCEPT on
                          // the smoothing page, which authors no selection at all
                          // (bar L1/AE6). With the brush parked in Orbit a tap
                          // would otherwise fall through to the face picker and
                          // change the very selections the freeze mask was
                          // computed from.
                          faceToolActive: !showSmoothingPage,
                          onPickFace: handlePick,
                          // ★ §6 — the same tap, with its 3D point. Only the point
                          // distinguishes the two halves of a cut face.
                          onPickPoint: { fid, pt in
                              guard let m = viewerMesh else { return false }
                              if visible.surfaceEditing {
                                  handleSurfacePick(fid, at: pt, mesh: m)
                                  return true
                              }
                              // ★ ON THE TOPOLOGY PAGE, A DIVIDED FACE IS TAPPED BY
                              // THE PIECE. Its pieces are independent selections —
                              // one can join a group while its sibling stays out —
                              // and only the hit POINT can tell them apart.
                              return handleTopologyPiecePick(fid, at: pt, mesh: m)
                          },
                          // ★ TAPPING NOTHING CLEARS THE SELECTION (maintainer:
                          // "touching the ground or the air (i.e. nothing) should
                          // de-select all selected faces"). A tap that hit no
                          // geometry is an intent to stop working on the last
                          // thing, not a no-op — and leaving a piece lit while the
                          // user has visibly moved on makes the next action apply
                          // somewhere they are no longer looking.
                          onMiss: {
                              guard visible.surfaceEditing else { return }
                              // ★ CLEARING THE SELECTION IS NOT THE SAME AS THROWING
                              // AWAY WORK IN PROGRESS. A tap on the ground clears
                              // what is SELECTED, as asked. It must NOT empty a
                              // union that is being built: the pick can miss on a
                              // glancing tap near a silhouette, and one such miss
                              // silently reset the set to nothing — after which the
                              // next tap put it back to one face, forever.
                              //
                              // The ✕ on the cluster is how a union is abandoned,
                              // and it is right there.
                              surfaceSelected = nil
                              surfaceSelectedFace = nil
                              surfaceRefusal = nil
                              heldCut = nil
                              hoveredCut = nil
                              if surfaceTool != .union { surfacePatternFace = nil }
                          },
                          onProjection: { projection = $0 },
                          // Round-6 item 4 (redo gesture updated 2026-07-25): two-finger
                          // double-tap undoes, THREE-finger double-tap redoes.
                          onUndo: { project.performUndo() },
                          onRedo: { project.performRedo() },
                          // Lattice proxy (2026-07-28): when previewing, paint the body
                          // by local lattice density through the existing per-vertex
                          // tint channel — no lattice geometry, no new GPU buffer. No
                          // demand field in the workspace pre-run → a uniform preview;
                          // graded shading engages when a result's von Mises field is
                          // present (proven in LatticeProxyTests + the evidence render).
                          // On the smoothing page this channel carries the BRUSH:
                          // painted regions in their own colour at their own
                          // strength, and every FROZEN vertex flatly tinted, so
                          // what the brush will refuse is visible before it is
                          // tried (handoff 2026-08-02-smoothing-page).
                          // `viewerTints`, NOT `vertexTints` (task 2026-08-05, bar
                          // D4): the renderer's tint buffer is per FLAT vertex —
                          // three per triangle — and it drops an array of any
                          // other length in silence. This page had been handing it
                          // one entry per WELDED vertex since the brush shipped,
                          // so no stroke the maintainer ever painted could have
                          // tinted anything.
                          stressTints: showSmoothingPage ? smoothBrush.viewerTints()
                                                         : latticeProxyTints,
                          // M7.dom-app: the translucent design box + keep-outs (model
                          // space); nil when the tool is off → nothing drawn. L1: a
                          // full-screen page draws NO design-box wireframe.
                          // …AND NOT ON THE SMOOTHING PAGE (task 2026-08-05, bar
                          // D5a). The comment above says a full-screen page draws
                          // no design-box wireframe; the CONDITION never said so.
                          // `showDesignGizmo` is only "the tool is on and we are
                          // in the edit phase", so a user who had ever switched
                          // the Design Box on kept its translucent box and bright
                          // edges drawn straight through the part he was trying to
                          // brush — the bounding box in the maintainer's
                          // screenshots. Gated on THIS page alone, deliberately:
                          // the lattice page mounts the same view and its geometry
                          // is unchanged by this.
                          // …AND NOT ON THE LATTICE STAGE (task 2026-08-14 §2b):
                          // "all primitives in TO like the Design Box and Group
                          // Primitives should NOT be visible on the Lattice page."
                          // VISIBILITY ONLY — `project.designBox` is untouched, so
                          // the box still bounds the run from either stage (§2c).
                          // ★ §6(b) — THE B-REP WIREFRAME, on the surface stage
                          // only. The stage-visibility table owns the decision, so
                          // a new affordance cannot appear on a stage by accident.
                          // ★ …OR WHENEVER THERE IS A PREVIEW TO DRAW. The line layer is
                          // the only channel these reach the renderer through, so a
                          // pattern being aimed has to open it regardless of the
                          // view toggle. See `surfacePreviewLineBuffer`.
                          showWireframe: (visible.wireframe && surfaceWireframeOn)
                              || !surfacePreviewLineBuffer.isEmpty,
                          designBox: (showDesignGizmo && !showSmoothingPage
                                      && visible.designBox)
                              ? project.designBox.box : nil,
                          keepOutBoxes: (showDesignGizmo && !showSmoothingPage
                                         && visible.keepOuts)
                              ? project.designBox.keepOuts : [],
                          // Keep-clear v2 (Part 3): the true red clearance volumes, drawn
                          // whenever gravity is set (edit phase) so the user can SEE and
                          // reason about every keep-out; the selected group's volume brightens.
                          //
                          // L1: NOT on the smoothing page. Protected regions are still
                          // INDICATED there — better than these boxes, in fact: the brush
                          // tints the actual FROZEN VERTICES of the mesh being painted, so
                          // what the brush will refuse is shown on the surface itself
                          // rather than as a red box floating near it.
                          //
                          // …AND ON THE LATTICE PAGE (task
                          // 2026-08-03-variant-postprocessing-fix, defect 3 / bar
                          // V2). The maintainer's run reported 99,558 include-region
                          // voxels sitting on VOID — regions covering space the
                          // optimizer had emptied. He could not have known: this
                          // condition read `!fullScreenPageUp`, so the moment the
                          // lattice page opened, every region volume stopped being
                          // drawn — and the workspace only ever drew them over the
                          // ORIGINAL part, never over an optimized variant. The page
                          // whose whole subject is those regions was the one page
                          // that hid them. The stage here shows the VARIANT's own
                          // mesh (`stageMesh`), so a region sitting in empty space is
                          // now visibly sitting in empty space — and the forecast
                          // puts a number on it.
                          //
                          // …AND SEGREGATED BY STAGE (task 2026-08-14 §2). The TO
                          // stage draws the keep-outs and the group primitives; the
                          // LATTICE stage draws the depth planes and nothing else.
                          // `stageVolumeItems` is the one place that decides.
                          clearanceVolumes:
                              (showLatticePage
                               || (force.phase == .edit && !fullScreenPageUp))
                              ? stageVolumeItems : [],
                          // Strut preview (2026-07-30 alignment handoff, bar A3): while the
                          // raymarched lattice layer is up there is ONE visible object — the
                          // body is not drawn at all (alpha 0), it only keeps serving the
                          // pick/id pass; face markings read on the lattice instead (A4).
                          // 1 (opaque) otherwise — byte-identical when off.
                          // …and the body is hidden ONLY where that layer is drawn
                          // (§1a): the TO page no longer draws it, so the body must
                          // not be made invisible for it either.
                          bodyAlpha: (showStrutPreview && strutScene != nil
                                      && (visible.latticeControls || showLatticePage))
                              ? 0 : 1,
                          // Detent face-highlight pulse (item 2): flash the snapped part face.
                          detentPulse: detentPulse,
                          // Paint mode (handoff 2026-07-25): when on, a one-finger drag brushes
                          // triangles into the active group; `paintFaceIDs` re-labels painted
                          // triangles so the highlight + picker treat them as one face (live paint
                          // highlight). `onBrush` resolves the covered triangles and applies the
                          // stroke; two-finger drag still orbits.
                          paintActive: brushGesture.armed,
                          paintFaceIDs: project.effectivePaintFaceIDs(),
                          onBrush: { center, phase, input in
                              handleBrush(center, phase,
                                          input == .pencil ? .pencil : .finger)
                          },
                          // Bar U2: on the smoothing page the maintainer can give
                          // the brush to the pencil, and a finger drag then orbits
                          // with no mode to switch. Off everywhere else, so the TO
                          // page's paint gesture is byte-for-byte unchanged.
                          brushRequiresPencil: brushGesture.requiresPencil,
                          // BAR D1b: an armed brush that refuses a contact says so
                          // AT THE MOMENT the user tries it. Once per page — a
                          // note on every orbit would be noise, and orbiting with
                          // a finger is the intended behaviour, not a mistake.
                          onBrushRefused: { _ in
                              guard showSmoothingPage, smoothTools.pencilOnly else { return }
                              smoothingPageModel?.notePencilOnlyRefusedFinger()
                          })
                .ignoresSafeArea()
                // ★ §6(g) — THE PENCIL HOVER, ON THE MESH VIEW ITSELF.
                //
                // ★ HOVER IS NOT A TOUCH. A pencil held above the glass reports on a
                // separate event stream, so mounted here it yields the hovered cut
                // line WITHOUT contending for a touch: the viewport orbits exactly as
                // it did before this stage existed. Mounted instead on the drawing
                // overlay (with the `.contentShape` such an overlay needs), it took
                // the whole viewport with it — see that overlay's note.
                //
                // On hardware with no hover this simply never fires, and the stage
                // still works by tap.
                .onContinuousHover { phase in
                    guard visible.surfaceEditing, heldCut == nil else { return }
                    switch phase {
                    case let .active(p): hoveredCut = cutUnder(p)
                    case .ended:         hoveredCut = nil
                    }
                }

            // Strut preview: the raymarched true-strut layer, riding the SAME shared
            // orbit camera AND the same settle model transform as the mesh view (one
            // transform, one camera — the 2026-07-30 alignment fix), with the mesh
            // view's own face tints so markings read on the lattice (the body is not
            // drawn while this layer is up, bar A3). Non-interactive — orbit/tap
            // gestures fall through to the mesh view, whose pick structure is intact.
            //
            // ★ AND NOT ON THE TO PAGE (task 2026-08-14 §1a). The toggle left with
            // the rest of the lattice affordances, but the LAYER is separate state:
            // turn it on, navigate back, and a raymarched lattice would have been
            // drawn over the topology page with no control to turn it off. The
            // ladder page keeps it — that page is about a lattice.
            if showStrutPreview, visible.latticeControls || showLatticePage,
               let scene = strutScene {
                LatticeSDFPreviewView(camera: cameraModel, scene: scene,
                                      params: latticeProxy.params,
                                      sceneToken: strutSceneToken,
                                      modelRotation: settleQuat,
                                      modelCenter: meshCenter,
                                      faceTints: roleTints)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // EVERY in-scene editing affordance below is gated on `!fullScreenPageUp`
            // (bar L1): a page shows the part and its own tool, and nothing the page
            // does not own. The design-box handles, the primitive transform gizmo and
            // the clearance drag handles are all EDITORS — on the smoothing page they
            // would let a user move the very geometry the freeze mask was computed
            // against, behind a page that could not react to it.
            if !fullScreenPageUp {
                // ★ §6(a) — NOT ON THE SURFACE STAGE. Force arrows are a TOPOLOGY
                // affordance: they answer "what is pushing on this part", which is
                // not a question this stage asks. `visible.groupPrimitives` is the
                // stage table's own word for "the TO page's in-scene editors".
                if visible.groupPrimitives {
                    arrowsOverlay.ignoresSafeArea()             // D6: force arrow shafts
                }
                // Gravity direction (round 2, item 4): the arrow is shown ONLY while gravity is
                // being edited (the setup phase, below) — the persistent dim arrow + "down" tag are
                // REMOVED as viewport clutter; the "Gravity set · <axis>" chip is the at-a-glance
                // readout the rest of the time.
                // §2a/§2b: the design box is a TO-PAGE primitive. Its handles go
                // with it — hidden on the lattice stage, and NOT disabled: the box
                // is still armed and still bounds the run.
                if showDesignGizmo, visible.designBox {
                    designGizmoOverlay.ignoresSafeArea()            // dom-app resize/move handles
                }
                // DEFECT 2: the manual-primitive transform gizmo (translate on one axis / plane /
                // freely, rotate, + copy) — drawn on the active group's primitives so they can be
                // grabbed. Rendered BENEATH the clearance chips below, so the 330 pt gizmo box can
                // never occlude a value chip (the chip/knob hit areas are small and the rest of that
                // overlay is hit-transparent, so gizmo drags in empty box space still reach it).
                if force.phase == .edit, visible.groupPrimitives {
                    primitiveGizmoOverlay.ignoresSafeArea()
                }
                // Keep-clear Phase B: the draggable clearance handles (wall → margin, caps →
                // axial, face → depth) and the floating glass value pill near the selection — ON TOP
                // of the gizmo so the values stay readable while transforming.
                if force.phase == .edit, visible.groupPrimitives {
                    clearanceHandlesOverlay.ignoresSafeArea()
                }
                // ★ §3d — THE 3D DEPTH-PLANE HANDLES, the lattice stage's own tool.
                if visible.latticeDepthPlanes { latticeDepthHandlesOverlay.ignoresSafeArea() }
                // ★ §6(g) — THE HOVERED CUT LINE, the surface stage's own tool.
                if visible.surfaceEditing { surfaceCutOverlay.ignoresSafeArea() }
            }
            // The lattice region's transform gizmo — only while the lattice panel is open
            // and a region exists, so it never coincides with the force gizmo (U5). It is
            // the LATTICE page's own tool, so it is not gated with the workspace's.
            if !showSmoothingPage { latticeRegionGizmoOverlay.ignoresSafeArea() }

            if !fullScreenPageUp { chrome }
            if force.phase == .setup, !fullScreenPageUp {
                gravityBanner
                // Point which way is down — the reliable route that doesn't depend on a
                // clean single face. The tip SNAPS to the part's own face normals (item 1);
                // the base is moved by the transform gizmo and magnetically sticks to a face
                // (item 2). Face-tap still works (handled in `handlePick`).
                if viewerMesh != nil {
                    // The base gizmo's large transparent hit-box must sit BELOW the direction
                    // overlay, otherwise it swallows taps on the confirm ✓ / snap buttons that
                    // float near the arrow tip (the "checkmark doesn't work" bug). The arrow
                    // canvas is non-interactive and the tip knob/cluster are small, so the base
                    // gizmo stays grabbable everywhere else.
                    gravityBaseGizmoOverlay.ignoresSafeArea()
                    gravityDirectionOverlay.ignoresSafeArea()
                }
            } else if !fullScreenPageUp {
                // The Design Box drawer now lives INSIDE `bottomRightControls` (item 11), so it
                // is no longer placed separately here.
                if force.gravityIsSet { bottomRightControls }
                if viewerMesh != nil { selectionsPanel }
                // ★ The Regions surface, beside the Selections panel it edits
                // (task 2026-08-14-face-regions). Union, split and grid-split are
                // a SELECTION facility, not a lattice one, so it belongs to BOTH
                // stages — the lattice page needs the same regions the TO page
                // authored, and PR 331's own parent/child collapse is the ONE
                // disclosure mechanism in that panel (bar R12).
                if viewerMesh != nil, regionsOpen { regionsPanelOverlay }
                // The lattice preview legend + the Struts toggle are LATTICE
                // affordances (§1a): they left the TO page with everything else.
                if viewerMesh != nil, visible.latticeControls { latticePreviewOverlay }
                // ★ §1b — the ONE button: it NAVIGATES between the two stages.
                if viewerMesh != nil { stageNavigationButtonOverlay }
                if viewerMesh != nil { latticeSettingsButtonOverlay }
                // ★ SAVE, in the slot the greyed-out "Lattice" button vacated.
                surfaceSaveButtonOverlay
                // ★ §6 — THE SURFACE STAGE'S TOOLS, on the right BELOW THE GIZMO
                // (maintainer, 2026-08-14: "I am not seeing any of the tools
                // required for the Surface stage").
                if viewerMesh != nil, visible.surfaceEditing {
                    surfaceToolsPanel
                    // ★ the confirm floats NEXT TO the action, not in the tray.
                    surfaceActionCluster.ignoresSafeArea()
                }
                // ★ THE WIREFRAME AND X-RAY, ON THE TOPOLOGY PAGE TOO (maintainer,
                // 2026-08-16: "We should keep wireframe and xray view throughout
                // the entire app. Please add to the TO page side-by-side just below
                // the position gizmo (with padding between them)"). The Surface
                // stage keeps them in its own tray, where the rest of its tools are.
                if viewerMesh != nil, visible.wireframe, !visible.surfaceEditing {
                    viewModeToggles
                }
            }
            // ★ AND NEITHER ARE THE LOAD PILLS — the weight readout and its
            // Gravity/Push/Pull switch. The maintainer found the whole load editor
            // sitting on the Surface stage: "Anything from the TO page like the
            // Load indicator should not be visible on this stage."
            if !fullScreenPageUp, visible.groupPrimitives {
                loadOverlays.ignoresSafeArea()                  // D3/D4/D5: load pills
            }
            if !fullScreenPageUp {
                bottomBar
                    // ★ REFUSE AN IMPLAUSIBLE READING (see `BottomBarMeasurement`).
                    // A height near the viewport's is the expanded frame, not a
                    // bar, and adopting it pushes every view that clears the bar
                    // off the screen.
                    .onPreferenceChange(BottomBarHeightKey.self) { h in
                        if let ok = BottomBarMeasurement.accept(
                            measured: h,
                            viewport: projection?.viewportSize.height ?? 0) {
                            bottomBarHeight = ok
                        }
                    }
            }
            // The full-screen lattice page (handoff 2026-07-30-lattice-page): chrome
            // over the SAME live stage — the workspace chrome above is hidden while
            // it is open, so exactly one set of controls exists at a time.
            if showLatticePage { latticePageOverlay }
            if showLatticeWizard {
                LatticeSetupWizard(project: project) {
                    showLatticeWizard = false
                    refreshLatticeFaceCards()
                }
                .transition(.opacity)
            }
            // Round-2 L18: the ONE Selections library, mounted OVER the lattice page
            // when its Regions & faces row opens it — the SAME `selectionsPanel`
            // view over the SAME `project.selection` the TO page uses. Never a
            // second selection UX.
            if showLatticePage, latticePageModel.libraryOpen,
               force.phase == .edit, viewerMesh != nil {
                selectionsPanel
            }
            // The SMOOTHING page (handoff 2026-08-02-smoothing-page) — chrome over
            // the same stage, mounted like the lattice page.
            if showSmoothingPage { smoothingPageOverlay }
            // ROUND-2 BAR L1 — NO SELECTIONS PANEL OVER THE SMOOTHING PAGE.
            //
            // Round 1 mounted the shared library here, reading AE6 ("one selection
            // model, never a second UX") as licence to show the EDITOR. But the
            // freeze mask the brush is painting against was computed from those
            // very selections: editing an anchor or a keep-clear volume mid-stroke
            // would leave every stroke on screen measured against a mask that no
            // longer describes the part, and the page has no way to react.
            //
            // AE6 is unweakened — the page still authors no selection state, and
            // there is still exactly one `selectionsPanel` in the app. It simply
            // shows a READ-ONLY readout of that one model instead of its editor,
            // which is what L1's "indicated, not editable" asks for.
            // ═══ THE POSITION GIZMO — ONE PLACEMENT, EVERY PAGE (round-2 bar L2) ═══
            //
            // This is the THIRD time the maintainer has asked for gizmo invariance:
            // round-3 lattice feedback, again when it was REMOVED from the lattice
            // page, and now here. Both earlier answers were local — round 1 hid it
            // on the lattice page and drew it from a SECOND `if` site for the
            // smoothing page — so "the same corner on every page" kept being a claim
            // about two pages out of three.
            //
            // It is now mounted ONCE, LAST in the ZStack, above every page. That
            // placement is what fixed the lattice page's L6 in the first place: the
            // gizmo's Metal-backed glass composites over pure-SwiftUI chrome
            // whatever the z order says, so the answer is to put it genuinely on
            // top rather than to hide it. Each page insets its own top-right column
            // by `PageChrome.gizmoClearance` so nothing lands under it.
            if viewerMesh != nil { orientationGizmo }
            RunScreen(model: run,                               // M7.7: progress card + failure sheets
                      materialName: project.material,
                      resolution: runResolution,
                      onRetry: startRun)
                // The running card / failure sheet dim their OWN full-bleed
                // backdrops; keeping RunScreen inside the safe area lets the
                // minimized "Optimizing…" chip sit under the status bar / nav row.
            // Results appear as soon as the FIRST variant streams in (progressive
            // results), while the rest keep optimizing behind them. They PERSIST on
            // the project, so leaving to Home and reopening shows them again — until
            // the user views the original and re-optimizes.
            if let outcome = run.outcome, outcome.variants.contains(where: { $0.accepted }), !viewOriginal {
                ResultsScreen(projectName: project.name, outcome: outcome,
                              materialName: project.material,
                              yieldStrengthMPa: model.yieldStrengthMPa(for: project.material),
                              // M7.viz.6: the failure-load prediction scales from the
                              // user's applied load (kgf) in their kg/lbs unit, with the
                              // infill % for the infill-adjusted estimate. All app data.
                              appliedLoadKg: force.totalLoadKg(in: selection.groups),
                              loadUnit: force.unit,
                              infillPercent: project.printParams.infillPercent,
                              infillPattern: project.printParams.infillPattern,
                              // Handoff 070 load-path FLOW: the load-group centroids are
                              // where each comet arrow starts (app-side data, like the
                              // applied load). Empty → the results screen falls back to
                              // the most-deflected node.
                              loadLocations: loadFlowSeeds,
                              // M7.viz.5 load→anchor flow: the per-load force directions
                              // d̂ (index-aligned with the seeds) and the anchor face
                              // centroids — the flux streamline's direction + target set.
                              loadDirections: loadFlowDirections,
                              anchorPoints: anchorFlowPoints,
                              streaming: run.isStreaming,

                              // Pass the live run so the streaming pill can surface the
                              // honest progress readout (variant N of M · elapsed · ETA)
                              // and offer Cancel — reads only (run-progress-visibility).
                              run: run, runResolution: runResolution,
                              runMaterialName: project.material,
                             
                              // Home, KEEP the variants — and DON'T cancel: an in-flight
                              // ladder must keep optimizing so leaving and returning shows
                              // MORE variants (an 80-minute run survives being looked at,
                              // left, and returned to). Cancelling here used to wipe the
                              // streamed results (RunModel.finish cancelled branch → nil).
                              onClose: { model.backHome() },
                              onSeeOriginal: { viewOriginal = true },
                              // Per-variant lattice entry (handoff 2026-07-30-lattice-
                              // page): the selected variant's own field rides in as the
                              // demand field; the results overlay steps aside so the
                              // page (mounted above the workspace stage) is visible.
                              onLattice: { idx in
                                  viewOriginal = true
                                  openLatticePage(variantIndex: idx)
                              },
                              // Per-variant SMOOTHING entry (handoff
                              // 2026-08-02-smoothing-page): brush locally,
                              // re-certify, keep or discard.
                              onSmooth: { idx in
                                  viewOriginal = true
                                  openSmoothingPage(variantIndex: idx)
                              },
                              // AJ2: the two entries are DECIDED HERE, before either
                              // page can be reached, and each blocked one carries its
                              // own reason on the disabled control.
                              smoothEntry: { smoothEntry($0) },
                              latticeEntry: { latticeEntry($0) })
                    .ignoresSafeArea()
            }
            // Returning to the saved variants from the original view. L5: NOT while
            // a page is up — this chip is pinned top-centre, which is exactly where
            // both pages put their own status banner, and the two overlapped.
            if viewOriginal, !fullScreenPageUp, let outcome = run.outcome,
               outcome.variants.contains(where: { $0.accepted }) {
                seeResultsChip
            }
        }
    }

    /// Start the M7.7 optimize run for the current load case. Gated on the same
    /// `canOptimize` the button uses; nil request only if a file/material is
    /// somehow missing (Optimize is disabled in that case).
    /// The "See Results" chip — pinned to the TOP EDGE at the EXACT horizontal centre, in
    /// every workspace state it appears in (design-overhaul round 2, item 8). Vertically
    /// aligned with the top-left chrome row so it reads as part of the top bar; the chrome is
    /// top-left and the gizmo top-right, so the centre is always clear.
    private var seeResultsChip: some View {
        VStack {
            Button { viewOriginal = false } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold))
                    Text("See Results").dsStyle(DS.TypeScale.bodyStrong)
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Color.accent.opacity(0.22).color)
                    .overlay(Capsule().strokeBorder(DS.Color.accent.opacity(0.6).color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Space.xl3)   // align with the top chrome row
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)   // exact horizontal centre
    }

    /// The orientation gizmo lives in the ABSOLUTE top-right corner, ALWAYS (design-overhaul
    /// 109; round 2 item 4). The settings chips that used to crowd this corner stack BOTTOM-
    /// right above Optimize (`bottomRightControls`). ONE shared size (`standardSize`) on every
    /// screen — the workspace-210 / results-300 divergence is dead; the ResultsScreen gizmo
    /// uses the same constant + corner.
    private var gizmoSize: CGFloat { OrientationGizmoView.standardSize }
    private var orientationGizmo: some View {
        VStack {
            HStack {
                Spacer()
                OrientationGizmoView(camera: cameraModel, size: gizmoSize)
            }
            Spacer()
        }
        .padding(.top, PageChrome.gizmoInset)
        .padding(.trailing, PageChrome.gizmoInset)
    }

    private var replacementPromptBinding: Binding<Bool> {
        Binding(get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } })
    }

    /// Say that a failed run gave the previous variants back (bar 4).
    private func announceRestoredResults(_ restored: Bool) {
        guard restored else { return }
        let n = run.outcome?.variants.filter { $0.accepted }.count ?? 0
        guard n > 0 else { return }
        let subject = n == 1 ? "1 variant is" : "\(n) variants are"
        model.toast = "That run produced no variants, so your previous \(subject) still here."
    }

    /// Optimize was tapped. BAR 4: when a finished run is about to be retired, the
    /// user is TOLD what they are about to lose and CONFIRMS it. This is the only
    /// remaining path that retires results at all — editing the setup never does,
    /// and a run that produces nothing puts them back — so the prompt is rare and
    /// always about a real loss. Nothing to lose ⇒ no prompt, and Optimize behaves
    /// exactly as it always did.
    private func requestRun() {
        guard canOptimize else { return }
        if let prompt = ResultsReplacementPrompt.forNewRun(existing: run.outcome) {
            pendingReplacement = prompt
            return
        }
        startRun()
    }

    /// ★ THE "LATTICE" BUTTON'S RUN (maintainer, 2026-08-17) — lattice the
    /// selection, run no ladder. Goes through the SAME replacement prompt the
    /// optimize path uses, because it produces a result that would replace one.
    private func requestLatticeRun() {
        guard canLatticeThis else { return }
        guard let request = model.makeLatticeRunRequest() else {
            model.toast = "Import a part and set a lattice region first."
            return
        }
        if let prompt = ResultsReplacementPrompt.forNewRun(existing: run.outcome) {
            pendingReplacement = prompt
            return
        }
        run.start(request)
    }

    private func startRun() {
        guard canOptimize else { return }
        // Pre-flight (099 D3): if EVERY load group is zero-force or on a sub-voxel
        // face, the run would reach the core with empty external_loads and be
        // refused — so block it up front with an actionable message naming the group
        // and the fix, not the solver's exception text. If only some groups are
        // dead, warn but proceed. The core's require_external_loads guard still backs
        // this. Skipped for a no-load-group (self-weight / STL) case.
        if let h = voxelSpacingMM {
            switch LoadCasePreflight.evaluate(loadGroupDiagnoses(),
                                              qualityTitle: project.quality.title, spacingMM: h) {
            case .block(let message):
                model.toast = message
                return
            case .warn(let message):
                model.toast = message
            case .allow:
                break
            }
        }
        viewOriginal = false   // a fresh run replaces the saved variants → show results
        guard let request = model.makeRunRequest() else {
            model.toast = "Can’t start — import a model and choose a material first."
            return
        }
        lastRunRequest = request   // Optimize greys out until the inputs change
        // Pick the runner for THIS run from the compute-location choice. A remote
        // config (a worker was selected + resolved) offloads to the LAN worker;
        // otherwise the on-device bridge runs it, byte-identical to before. Always
        // set explicitly so switching back to iPad after a remote run restores local.
        let isRemote = compute.activeRemote != nil
        // THE RETENTION PAIR IS CAPTURED AT RUN TIME (task
        // 2026-08-03-variant-entry-gating-and-retention). PR 274 defined
        // `RelatticeArtifacts` and persisted them, but nothing ever produced a pair
        // from a live run — they were only ever READ back from disk, so every run
        // made in the app reported "kept no design file" and neither the smoothing
        // page nor "Lattice this variant" was reachable at all. The remote runner
        // now hands the pair back, and it lands on the project here.
        //
        // The pair is reported to the RUN, which adopts it only if this run goes on
        // to produce results — so a design belonging to a different run than the
        // results on screen can never be latticed against them. An ON-DEVICE run
        // reports none (the bridge writes no job document and no design container,
        // PR 274's disclosed limit), and the entry controls then say exactly that.
        let liveRun = run
        run.runner = compute.activeRemote.map { cfg in
            RunModel.remoteRunner(cfg, onArtifacts: { art in
                DispatchQueue.main.async { liveRun.noteRetainedArtifacts(art) }
            }, onLatticeMeshSource: { src in
                // THE ADDRESS OF THIS RUN'S LATTICED MESHES (task 2026-08-07-
                // lattice-variants-on-screen). Lands on the run so the results
                // screen can ask for one; nothing is transferred until it does.
                DispatchQueue.main.async { liveRun.noteLatticeMeshSource(src) }
            })
        } ?? RunModel.bridgeRunner
        // A remote run's liveness is RemoteRun's (queue- + heartbeat-aware); only a
        // LOCAL run arms RunModel's setup-stall watchdog (handoff 129).
        // The worker's own name rides along so the finished run can say WHICH
        // machine solved it (bar AJ5) instead of only "on a Mac".
        run.start(request, remote: isRemote, workerName: compute.selectedWorkerName)
    }

    // MARK: derived render inputs

    /// The settle rotation to display (identity until gravity is set).
    private var settleQuat: simd_quatf { force.settleRotation ?? Self.identityQuat }
    /// Draw the ground grid + contact shadow once gravity is set and we're editing.
    private var showGround: Bool { force.phase == .edit && force.gravityIsSet }
    /// Per-face tint (rgba) — anchors green (`ForceModel.tint`), loads/pending the
    /// group palette — so the 3D highlight matches the panel (D3/D5).
    private var roleTints: [FaceID: SIMD4<Float>] {
        var tints: [FaceID: SIMD4<Float>] = [:]
        for g in selection.groups {
            let c = force.tint(for: g)
            let v = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1)
            for f in groupTintedFaces(g) { tints[f] = v }
        }
        // Handoff 124 — a protected face gets the UNIQUE protect mint-teal, applied
        // AFTER the role tints so it wins: the mesh shader recognises this exact
        // colour and draws a CROSSHATCH over the face ("preserved", distinct from the
        // red clearance VOLUMES that read "forbidden").
        let p = Self.protectFaceRGB
        for g in selection.groups where force.isProtected(g.id) {
            for f in groupTintedFaces(g) { tints[f] = SIMD4<Float>(p.x, p.y, p.z, 1) }
        }
        return tints
    }

    /// ★ EVERY FACE A GROUP CONTAINS — BY EITHER MEMBERSHIP.
    ///
    /// Maintainer, 2026-08-16: "It's showing as something was selected — but it
    /// won't show the highlight."
    ///
    /// ★ THE THIRD PLACE `faces` WAS READ WITHOUT `regionIDs`. He tapped the
    /// isolated band, it joined Group A, the panel said so — and the model stayed
    /// grey, because the tint was built from `g.faces` alone and that group holds
    /// its surface as a REGION. The selection was real and invisible.
    ///
    /// A group has two memberships and what it CONTAINS is the union of them, so
    /// anything that answers "which faces are in this group" has to ask both. This
    /// is that question, once.
    private func groupTintedFaces(_ g: SelectionGroup) -> Set<FaceID> {
        Set(g.faces).union(project.latticeRegionCoveredFaces(g))
    }

    /// The per-vertex density tints the lattice proxy paints the body with, or nil when
    /// the proxy is off (body keeps its neutral clay). Uniform in the workspace (no
    /// demand field pre-run); the density GRADING engages wherever a von Mises field is
    /// supplied (see LatticeDensityProxy.tints).
    private var latticeProxyTints: [SIMD4<Float>]? {
        // ★ §1a — the density shading is a LATTICE readout, so it does not appear
        // on the TO page. The ladder page keeps it: that page is about a lattice.
        guard visible.latticeControls || showLatticePage else { return nil }
        guard project.lattice.enabled, let mesh = viewerMesh else { return nil }
        // Derive the proxy params FRESH from the lattice settings (density range clamped
        // to the core band), so the surface shading always reflects the current controls
        // with no stateful sync.
        let params = project.lattice.proxyParams(limits: latticeLimits)
        // Round-2 L11: in AUTO density the overlay grades from the page's own
        // demand field (the variant's field on the variants entry, else the
        // sim's) — the same source the strut preview grades from. Before this,
        // production always passed `demand: nil`, so the overlay was a constant
        // violet under EVERY setting (the graded branch ran only in tests): the
        // app HAD graded fields and never handed one over — an app-side bug, not
        // core's. Uniform mode stays deliberately flat (its density IS uniform).
        let field: StressField?
        if project.lattice.densityMode == .auto,
           let f = latticePageVariantField ?? latticeSim.field {
            field = StressField(nx: f.nx, ny: f.ny, nz: f.nz,
                                origin: SIMD3<Float>(f.origin), spacing: Float(f.spacingMM),
                                values: f.vonMises)
        } else {
            field = nil
        }
        // Round-2 L5: the SELECTION tints ride ABOVE the overlay — the stress-tint
        // channel replaces face highlights wholesale in the renderer, so the
        // groups' colours must be composed into the per-vertex buffer here.
        return LatticeDensityProxy.tints(for: mesh, demand: field, params: params,
                                         selectionTints: roleTints,
                                         effectiveFaceIDs: project.effectivePaintFaceIDs())
    }

    /// The certifiable limits for the current topology, READ FROM CORE at runtime (the
    /// controls' single source of truth — nothing bound here is hardcoded in the app).
    private var latticeLimits: TopOptKit.LatticeLimits {
        TopOptKit.latticeLimits(topology: project.lattice.topologyID)
    }

    /// The governing member width (mm) for the cells-per-member readout, from the region
    /// if one is placed (nil ⇒ whole part → the readout is omitted, not faked).
    private var latticeMemberMM: Double? { project.lattice.regionMemberMM }

    /// Push the current lattice settings into the proxy model that backs the legend's
    /// sample patch + gradient + cost. Reading `project.lattice` (a reference-held value)
    /// is always current here. The surface tints derive their own params, so this only
    /// keeps the LEGEND in step.
    private func syncLatticeProxy() {
        latticeProxy.params = project.lattice.proxyParams(limits: latticeLimits)
        latticeProxy.isActive = project.lattice.enabled
    }

    /// ★ THE ONE PLACE THE VIEWPORT'S VOLUMES ARE CHOSEN, BY STAGE (§2).
    ///
    /// TO stage      the keep-outs and the group primitives, in the keep-out red —
    ///               and NOT tinted as lattice regions, because on this page there
    ///               is no such thing as a lattice region.
    /// LATTICE stage the depth planes, and nothing else.
    ///
    /// The full-screen LADDER page (`showLatticePage`, entered from a finished
    /// variant) keeps drawing its regions, unchanged: it is a different page with a
    /// different subject, and defect 3 of the variant-postprocessing task is why
    /// its regions must stay visible.
    private var stageVolumeItems: [ClearanceRenderItem] {
        if showLatticePage { return latticeRegionRenderItems }
        // ★ §6(a) — THE SURFACE STAGE DRAWS NO VOLUMES AT ALL (maintainer,
        // 2026-08-14: "should not show any of the primitives or the design box on
        // screen … hidden from view to make things clearer").
        //
        // ★ THE DEFECT THIS FIXES was a FALL-THROUGH, not a missing gate. This
        // read `latticeDepthPlanes ? planes : keepOuts` — a two-way choice written
        // when there were two stages. A third stage that wants NEITHER took the
        // else branch and drew the topology stage's keep-out boxes, over a stage
        // whose whole point is an unobstructed look at the surface. The
        // visibility table already said `keepOuts == false`; nothing read it here.
        if !visible.keepOuts, !visible.latticeDepthPlanes { return [] }
        return visible.latticeDepthPlanes ? latticeDepthPlaneItems : keepOutRenderItems
    }

    /// The keep-out volumes (keep-clear v2 Part 3), each tagged whether its group is
    /// the ACTIVE selection so the viewport brightens it. Built from the same
    /// resolved geometry the run freezes (`ProjectModel.clearanceVolumes`).
    private var keepOutRenderItems: [ClearanceRenderItem] {
        let active = selection.activeGroupID
        return project.clearanceVolumes().map {
            ClearanceRenderItem(volume: $0.volume, selected: $0.groupID == active)
        }
    }

    /// ★ §3d — THE LATTICE DEPTH PLANES: one slab per latticed face or primitive,
    /// reaching INTO the part, tinted by the role the user gave THAT primitive
    /// (§3c) — include mid-violet, exclude deep indigo.
    private var latticeDepthPlaneItems: [ClearanceRenderItem] {
        let active = selection.activeGroupID
        return project.latticeDepthPlanes().map {
            ClearanceRenderItem(volume: $0.volume, selected: $0.groupID == active,
                                tint: latticeRegionTint($0.role))
        }
    }

    /// The ladder page's region volumes — the pre-separation behaviour, kept for
    /// the page that is about a finished variant's regions.
    private var latticeRegionRenderItems: [ClearanceRenderItem] {
        let active = selection.activeGroupID
        var items = project.clearanceVolumes().map {
            ClearanceRenderItem(volume: $0.volume, selected: $0.groupID == active,
                                tint: latticeRegionTint(project.lattice.enabled
                                    ? project.lattice.groupRoles[$0.groupID] : nil))
        }
        // Legacy lattice-include primitives (no owning group) — previously they had
        // NO volume render path at all (part of the L21 "invisible primitives"
        // finding). They draw through the same volume pass, region-tinted.
        if project.lattice.enabled {
            for p in project.lattice.includePrimitives {
                items.append(ClearanceRenderItem(
                    volume: latticeIncludeVolume(p), selected: false,
                    tint: latticeRegionTint(.include)))
            }
        }
        return items
    }

    /// The volume colour for a lattice role (nil → keep the clearance red).
    private func latticeRegionTint(_ role: LatticeGroupRole?) -> SIMD3<Float>? {
        switch role {
        case .include: return SIMD3<Float>(124.0 / 255, 111.0 / 255, 214.0 / 255)  // ramp mid violet
        case .exclude: return SIMD3<Float>(74.0 / 255, 52.0 / 255, 158.0 / 255)    // ramp deep indigo
        case nil: return nil
        }
    }

    /// A legacy include primitive's render volume: the primitive IS the region
    /// (zero margins), through the same `ClearanceVolume` shapes the run freezes.
    private func latticeIncludeVolume(_ p: ManualPrimitive) -> ClearanceVolume {
        let key = ProjectModel.manualFaceKey(p.id)
        if p.kind == .bolt {
            return .bolt(faceID: key, geometry: p.syntheticGeometry,
                         axialSpan: (Float(-p.halfLengthMM), Float(p.halfLengthMM)),
                         marginMM: 0, axialMM: 0)
        }
        let n = SIMD3<Float>(p.axis)
        let (u, v) = planeBasis(normal: n)
        let outline = PlaneOutline(center: SIMD3<Float>(p.center), uAxis: u, vAxis: v,
                                   halfU: Float(p.halfUMM), halfV: Float(p.halfWMM))
        return .slab(faceID: key, geometry: p.syntheticGeometry, outline: outline,
                     depthMM: p.resolvedDepthMM)
    }

    // MARK: tap routing (D1/D2)

    /// Tapped-face callback from the viewer. In the gravity-setup phase a tap picks
    /// the floor-facing face and sets gravity; otherwise it routes into the selection
    /// via `WorkspaceTap` — re-selecting a set group, or growing/starting one — and
    /// never removes anything (removal is the panel trash only).
    private func handlePick(_ faceID: FaceID) {
        // BAR Z11. On a finished variant there is nothing to pick: the stage is
        // showing a marching-cubes iso-surface with no segmentation, and the
        // ORIGINAL model's face ids describe surfaces this design no longer has.
        // Resolving a selector against the wrong geometry is the PR-261 failure —
        // it tags nothing and says nothing — so the tap is refused with the
        // reason instead of accepted into a selection that would mean nothing.
        if latticeVariantContext != nil {
            latticePageModel.post(note: LatticeVariantAuthoring
                .compute(variant: latticeVariantContext).note)
            return
        }
        guard let mesh = viewerMesh else { return }
        // ★ §6 — IN THE SURFACE STAGE A TAP ARMS A CUT, not a selection. The stage
        // has no roles and no loads; its one subject is the face under the finger.
        // ★ §6 — the surface stage is served by `onPickPoint`, which carries the
        // 3D hit; this callback has only the face id and would select the wrong
        // half. Nothing to do here.
        if visible.surfaceEditing { return }
        if force.phase == .setup {
            if let n = mesh.faceNormal(faceID) {
                force.setGravity(faceNormal: n, face: faceID)
                // Anchor the (purely-visual) arrow base on the tapped face so the indicator
                // reads from the surface the part rests on.
                force.setGravityBase(mesh.faceCentroid(faceID))
                // A face tap commits too — drop any half-pointed draft + stale snap badge
                // so re-entering setup starts from the direction just set, not the old draft.
                gravityDraft = nil
                gravityBaseDraft = nil
                gravitySnapLabel = nil
                model.toast = "Gravity set — the part now rests the way it will in real life"
            }
            return
        }
        // Lattice page (round-2 L18/L23): while the ONE Selections library is
        // open, taps route through the NON-DESTRUCTIVE lattice router — an owned
        // face selects its group (nothing is ever toggled off or stolen; removal
        // lives on the TO page only), a free face grows/starts a group. With the
        // library closed the page owns the tap and the selection is untouched.
        // ★ THE LATTICE STAGE ROUTES THE SAME WAY (task 2026-08-14 §3a): it is the
        // same Selections library, and L23/M2 still holds — nothing is removed or
        // stolen from a group on a lattice surface; removal lives on the TO page.
        if stage == .lattice {
            let loop = project.surfaceLoopRespectingRegions(
                FaceTopology.loop(fromFace: faceID, in: mesh), from: faceID)
            if let gid = LatticeLibraryTap.route(faceID: faceID, loop: loop,
                                                 selection: &selection) {
                latticeDisclosure.toggle(gid.uuidString)
            }
            force.sync(groups: selection.groups)
            refreshLatticeFaceCards()
            return
        }
        if showLatticePage {
            if latticePageModel.libraryOpen {
                let loop = project.surfaceLoopRespectingRegions(
                FaceTopology.loop(fromFace: faceID, in: mesh), from: faceID)
                let gid = LatticeLibraryTap.route(faceID: faceID, loop: loop,
                                                  selection: &selection)
                // T2: a tap on one of the group's own cleared faces reveals its
                // primitive chips (same rule as the TO page below).
                if let gid, let g = selection.groups.first(where: { $0.id == gid }),
                   groupClearanceFaces(g).contains(faceID) || !force.manualPrimitives(for: gid).isEmpty {
                    chipsRevealedGroup = gid
                }
                force.sync(groups: selection.groups)
            }
            return
        }
        // ★ THE REGION SHEET OWNS THE TAP WHILE A REGION IS SELECTED (task
        // 2026-08-14-face-regions §2c). A heuristic that cannot be corrected by
        // hand is worse than no heuristic, so a tap here ADDS the face to the
        // region — or DROPS it if the region already holds it — writing the
        // explicit add/remove list the persistence re-applies on every import.
        if regionsOpen, let rid = regionTapTarget,
           let region = project.faceRegions.region(rid) {
            if FaceRegionGeometry.members(of: region, in: mesh).contains(faceID) {
                project.faceRegions.removeFace(faceID, from: rid)
            } else {
                project.faceRegions.addFace(faceID, to: rid)
            }
            project.refreshFaceRegionDrift()
            return
        }
        let loop = project.surfaceLoopRespectingRegions(
                FaceTopology.loop(fromFace: faceID, in: mesh), from: faceID)
        WorkspaceTap.route(faceID: faceID, loop: loop, selection: &selection, force: force)
        // Round-2 T2: primitive chips are reachable ONLY by tapping the primitive,
        // one of its faces, or its group row in the library — a tap that merely
        // grew a selection must NOT pop the chip editor open. Reveal only when
        // the tapped face is one of the (now-active) group's own cleared faces.
        if let g = selection.activeGroup, groupClearanceFaces(g).contains(faceID) {
            chipsRevealedGroup = g.id
        } else if chipsRevealedGroup != selection.activeGroupID {
            chipsRevealedGroup = nil
        }
        force.sync(groups: selection.groups)
    }

    /// Brush callback from the viewer (paint mode, handoff 2026-07-25). Each sample resolves the
    /// triangles under the brush disc (`BrushHitTest`, front-facing only) and paints/erases them
    /// into the active group's pseudo-face via `ProjectModel.paintStroke` — the SAME face-id
    /// contract a tap produces. Only in the edit phase (gravity set); no-op during gravity setup.
    /// On stroke END the sidecar is persisted so the run + live tagging reproduce the paint. The
    /// `.add`/`.erase` mode follows the erase modifier; `force.sync` keeps the load case aligned
    /// with the group the stroke may have created.
    private func handleBrush(_ center: CGPoint, _ phase: BrushPhase,
                             _ input: SmoothBrushTools.Input = .finger) {
        // On the SMOOTHING page the same gesture paints SMOOTHING strength onto the
        // variant's own surface (handoff 2026-08-02-smoothing-page). It is routed
        // here rather than given its own gesture so the brush feels identical on
        // both pages — and it hit-tests the VARIANT mesh, which is what the stage
        // is showing, so a stroke can never land on the original part's geometry.
        if showSmoothingPage {
            // The page's OWN tools decide the mode and the disc size (bar L4) —
            // the TO page's paint drawer is hidden here and no longer reachable.
            //
            // WHICH CONTACT (bar U2). A pencil always paints; a finger paints
            // only while `pencilOnly` is off. The recognizer reports the kind, so
            // this is not a guess — see `MetalMeshView.handlePencilPan`. Asked of
            // the SAME gate the recognizer routes through (bar D1), so the page
            // and the viewer cannot disagree about who may paint.
            guard brushGesture.admits(input) else { return }
            // THE STAGE'S OWN MESH is what the brush hit-tests. On the smoothing
            // page that is `smoothVariantMesh` — the ORIGINAL variant surface —
            // even while the stage is showing the smoothed twin, because the
            // brush's triangle indices, the freeze mask and the weight vector are
            // all defined on the original. Painting against the smoothed mesh
            // would index a second mesh, which is the whole class of bug round 2
            // closed.
            guard let mesh = smoothVariantMesh, let proj = projection else { return }
            switch phase {
            case .began:
                // ONE STROKE, ONE RUNG (bar U1). A drag emits many samples over
                // the same triangles; without this boundary a single stroke would
                // run straight to the deepest level.
                smoothBrush.beginStroke()
                fallthrough
            case .moved:
                let tris = BrushHitTest.triangles(under: center,
                                                  radiusPoints: CGFloat(smoothTools.radiusPoints),
                                                  mesh: mesh, projection: proj,
                                                  modelRotation: settleQuat,
                                                  modelCenter: meshCenter)
                guard !tris.isEmpty else { return }
                smoothBrush.brush(smoothTools.mode, triangles: tris.map { Int32($0) })
            case .ended:
                smoothBrush.endStroke()
                // THE STROKE SETTLED — apply it to the preview mesh, so Smoothed
                // shows the smoothed shape NOW rather than after a certification
                // (task 2026-08-04-variant-volume-fraction-mismatch, bar C1/L4).
                // On `.ended` only: previewing mid-drag would re-smooth the whole
                // mesh on every frame of the stroke.
                if let page = smoothingPageModel {
                    let brush = smoothBrush
                    Task {
                        await page.refreshPreview(brush: brush)
                        // The stage draws `smoothedVariantMesh`, so the preview has
                        // to land THERE or the toggle flips a label over unchanged
                        // geometry — which is the defect, not the fix. A certified
                        // or kept result outranks a preview and is never clobbered.
                        guard page.receipt == nil, page.kept == nil else { return }
                        smoothedVariantMesh = page.preview.map {
                            ViewerMesh(vertices: $0.meshVertices,
                                       indices: $0.meshIndices,
                                       faceIDs: [], faceGeometry: [],
                                       pseudoFaces: false, smoothShaded: true)
                        }
                    }
                }
            }
            return
        }
        guard force.phase == .edit, let mesh = viewerMesh, let proj = projection else { return }
        switch phase {
        case .began, .moved:
            // Project the SETTLED positions the viewer shows (gravity rotates the model about its
            // centre); without this the brush paints the un-rotated mesh and lands on the wrong
            // face — the "colouring the other wall" bug.
            let tris = BrushHitTest.triangles(under: center, radiusPoints: brushRadiusPoints,
                                              mesh: mesh, projection: proj,
                                              modelRotation: settleQuat, modelCenter: meshCenter)
            guard !tris.isEmpty else { return }
            project.paintStroke(paintErasing ? .erase : .add, triangles: tris)
            force.sync(groups: selection.groups)
        case .ended:
            project.persistPaint()
        }
    }

    private var activeGroup: SelectionGroup? { selection.activeGroup }

    // MARK: model → world → screen (via the published camera projection)

    private var meshCenter: SIMD3<Float> { viewerMesh?.bounds.center ?? .zero }

    /// A model-space point in its settled world position (rotation about the centre).
    private func settledWorld(_ modelPoint: SIMD3<Float>) -> SIMD3<Float> {
        let c = meshCenter
        return c + settleQuat.act(modelPoint - c)
    }

    /// The tagged LOAD groups as (centroid, unit force direction) pairs in the model
    /// frame — the start points AND the per-load d̂ the load-path flow needs. The
    /// centroid is where a comet arrow starts; the direction is the load's model-space
    /// force (`ForceModel.loadForceVectorModel`, gravity = the tapped floor normal,
    /// push/pull = ∓/± face normal), normalised, which the `.anchor` mode integrates as
    /// `F = σ·d̂`. Built together so the two arrays stay index-aligned. Same model frame
    /// (mm) as the results grid/variant, so a centroid here lines up with the stress
    /// field there. A load with a centroid but no computable direction gets a zero d̂
    /// (the anchor mode skips it; the stress-point mode ignores direction).
    private var loadFlowPairs: [(seed: SIMD3<Float>, dir: SIMD3<Float>)] {
        selection.groups.compactMap { g in
            guard force.kind(for: g.id).isLoad, let c = groupCentroidModel(g) else { return nil }
            let n = groupNormalModel(g) ?? SIMD3<Float>(0, 1, 0)
            let f = force.loadForceVectorModel(g.id, groupNormal: n) ?? .zero
            let len = simd_length(f)
            return (c, len > 1e-6 ? f / len : SIMD3<Float>.zero)
        }
    }

    /// The model-space centroids of the tagged LOAD groups — the start points for the
    /// redesigned load-path flow (handoff 070). Same model frame (mm) as the results
    /// grid/variant, so a centroid here lines up with the derived stress field there.
    private var loadFlowSeeds: [SIMD3<Float>] { loadFlowPairs.map(\.seed) }

    /// The per-load unit force directions d̂ (model frame), INDEX-ALIGNED with
    /// `loadFlowSeeds` — the `.anchor` flux-streamline direction for each load (M7.viz.5).
    private var loadFlowDirections: [SIMD3<Float>] { loadFlowPairs.map(\.dir) }

    /// The model-space centroids of every tagged ANCHOR face — the load→anchor flow's
    /// target set (M7.viz.5). Per-FACE (not per-group) so the support surface rasterises
    /// to enough voxels; voxelised once per run into an `AnchorVoxelSet` by the results
    /// model. Same model frame as the loads/grid. Empty when no anchors are tagged.
    private var anchorFlowPoints: [SIMD3<Float>] {
        guard let mesh = viewerMesh else { return [] }
        var pts: [SIMD3<Float>] = []
        for g in selection.groups where force.kind(for: g.id).isAnchor {
            // Both memberships — an anchor held as a region must still rasterise.
            for f in groupTintedFaces(g) {
                if let c = mesh.faceCentroid(f) { pts.append(c) }
            }
        }
        return pts
    }

    /// A group's model-space centroid (mean of its faces' centroids).
    ///
    /// ★ OVER BOTH MEMBERSHIPS. A group whose surface is held as a REGION rather
    /// than as bare faces had NO centroid at all, so every control anchored to it
    /// fell back to a default position — which is why the Anchor/Load row appeared
    /// at the bottom of the screen instead of beside the face ("the 'load/anchor…'
    /// is not close to the actual face"). See `groupTintedFaces`.
    private func groupCentroidModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var sum = SIMD3<Float>.zero, n = 0
        for f in groupTintedFaces(g) {
            if let c = mesh.faceCentroid(f) { sum += c; n += 1 }
        }
        return n > 0 ? sum / Float(n) : nil
    }

    /// A group's model-space outward normal (mean of its faces' normals). Over both
    /// memberships, for the same reason as the centroid — a load arrow on a
    /// region-held group had no direction to point in.
    private func groupNormalModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var acc = SIMD3<Float>.zero, found = false
        for f in groupTintedFaces(g) {
            if let nrm = mesh.faceNormal(f) { acc += nrm; found = true }
        }
        guard found else { return nil }
        let len = simd_length(acc)
        return len > 1e-6 ? acc / len : nil
    }

    /// A group's centroid projected to the screen, or nil (no projection / behind).
    private func groupScreen(_ g: SelectionGroup) -> CGPoint? {
        guard let proj = projection, let cm = groupCentroidModel(g) else { return nil }
        return proj.project(settledWorld(cm))
    }

    // MARK: keep-out layout pass (handoff 2026-07-27)

    // Approximate touch/drawn sizes of the floating controls (points). The pass only
    // needs rects — a small over-estimate is safe (it keeps a touch margin).
    private static let clrPillSize   = CGSize(width: 64, height: 40)   // number-only value pill
    private static let clrKnobTouch  = CGSize(width: 46, height: 46)   // red clearance drag knob
    private static let loadPillSize  = CGSize(width: 96, height: 44)   // weight pill (+ snap row headroom)
    private static let boxHandleTouch = CGSize(width: 44, height: 44)  // design-box grab circle

    /// How far a chip/pill may be nudged from its anchor before it stops (a slight nudge to
    /// clear a neighbour, never floated far — the LOCUS sliding does the heavy lifting).
    private static let keepOutMaxShift: CGFloat = 60
    /// The radius (points) a clearance knob is seated at, out from the gizmo centre — a TIGHT ring
    /// just past the gizmo's outer rotation ribbons (≈0.42·box) so the knob clears the gizmo but
    /// still hugs it, whatever the primitive's size.
    private static var gizmoRingRadius: CGFloat { gizmoBoxSize * 0.42 + 30 }

    /// The stable keep-out id for a clearance knob / its value pill / a box handle.
    private func boxHandleID(_ i: Int) -> String { "box.\(i)" }
    private func clrKnobID(_ item: ClearanceHandleItem) -> String { "clr.knob.\(item.id)" }
    private func clrPillID(_ item: ClearanceHandleItem) -> String { "clr.pill.\(item.id)" }

    /// The screen centre of the manual-primitive transform gizmo currently up (the `gizmoTarget`
    /// primitive's centre), or nil if none — the point clearance knobs/pills are seated around.
    private func manualGizmoScreenCentre(_ proj: CameraProjection) -> CGPoint? {
        gizmoClearInfo(proj)?.centre
    }

    /// The transform gizmo's screen centre + a SHAPE test: `isClear(p)` is true when stage point `p`
    /// misses the gizmo's (fat) pick zones — the SAME shape the gizmo grabs with (`TransformGizmo.pick`),
    /// so a clearance knob is only seated where it won't sit on the gizmo OR steal its touches. Nil
    /// when no manual-primitive gizmo is up.
    private func gizmoClearInfo(_ proj: CameraProjection) -> (centre: CGPoint, isClear: (CGPoint) -> Bool)? {
        guard force.phase == .edit, let gid = selection.activeGroupID else { return nil }
        for mp in project.manualPrimitives(in: gid)
        where gizmoTarget == GizmoTarget(group: gid, id: mp.id) {
            guard let centre = proj.project(settledWorld(SIMD3<Float>(mp.center))) else { return nil }
            let box = Self.gizmoBoxSize
            let rot = gizmoRotation * primitiveOrientation(mp)
            let test: (CGPoint) -> Bool = { p in
                let local = CGPoint(x: p.x - (centre.x - box / 2), y: p.y - (centre.y - box / 2))
                if local.x < 0 || local.y < 0 || local.x > box || local.y > box { return true }   // outside the box
                return TransformGizmo.pick(point: local, in: CGSize(width: box, height: box), rotation: rot) == nil
            }
            return (centre, test)
        }
        return nil
    }

    /// Candidate SCREEN positions a clearance knob may occupy — its geometric locus (the cylinder
    /// wall for margin, the end-face rim for axial) at the CURRENT clearance boundary radius (so it
    /// tracks the margin), sampled at angles ordered NEAREST-FIRST from the home angle. The drag math
    /// is angle-agnostic, so any is an exact grab point. A slab handle (no cylinder) → just home.
    private func clearanceKnobCandidates(_ item: ClearanceHandleItem, _ proj: CameraProjection) -> [CGPoint] {
        let h = item.handle.settled(center: meshCenter, rotation: settleQuat)
        let home = proj.project(h.anchor)
        func rot(_ v: SIMD3<Float>, _ axis: SIMD3<Float>, _ a: Float) -> SIMD3<Float> {
            let k = simd_normalize(axis), c = cosf(a), s = sinf(a)
            return v * c + simd_cross(k, v) * s + k * (simd_dot(k, v) * (1 - c))
        }
        guard simd_length(h.axisDir) > 1e-5 else { return [home].compactMap { $0 } }
        let axis = simd_normalize(h.axisDir)
        // 0, +30, −30, +60, −60, … so the FIRST clear candidate is the closest angle to home.
        var degs: [Float] = [0]
        for d in stride(from: 30, through: 180, by: 30) { degs.append(Float(d)); if d != 180 { degs.append(-Float(d)) } }
        let angles = degs.map { $0 * .pi / 180 }
        var world: [SIMD3<Float>] = []
        switch item.handle.role {
        case .margin:
            // Slide around the cylinder WALL at the boundary radius (rotate the axis→knob radial).
            let onAxis = h.axisPoint + axis * simd_dot(h.anchor - h.axisPoint, axis)
            let radial = h.anchor - onAxis
            guard simd_length(radial) > 1e-4 else { return [home].compactMap { $0 } }
            world = angles.map { onAxis + rot(radial, axis, $0) }
        case .axialLo, .axialHi:
            // Slide around the END-FACE RIM (the axial anchor sits on the axis; offset it onto the
            // rim so it can move off the gizmo end into the "space below").
            let (u, _) = planeBasis(normal: axis)
            let r = Swift.max(h.boreRadiusMM, 1)
            world = angles.map { h.anchor + rot(u * r, axis, $0) }
        case .slabDepth:
            return [home].compactMap { $0 }
        }
        let projected = world.compactMap { proj.project($0) }
        return projected.isEmpty ? [home].compactMap { $0 } : projected
    }

    /// The BASE keep-out elements (everything EXCEPT the clearance value pills) for the CURRENT
    /// camera projection + model state. Built fresh each read so a handle tracks the primitive
    /// live. The gizmo box + static chrome are RIGID; the clearance KNOBS slide on their cylinder
    /// locus to clear the gizmo. The value pills are placed in a SECOND pass beside each knob's
    /// resolved position (see `keepOutResolved`). See `ViewportKeepOut.swift` for the priorities.
    private func keepOutBaseElements(_ proj: CameraProjection) -> [KeepOutElement] {
        let W = proj.viewportSize.width
        var elements: [KeepOutElement] = []

        // ── RIGID: the top-right orientation gizmo (screen-fixed chrome band) ─────────
        elements.append(KeepOutElement(
            id: "chrome.orientationGizmo",
            anchor: CGPoint(x: W - 74, y: 74), bounds: CGSize(width: 132, height: 132),
            touch: CGSize(width: 132, height: 132), priority: .chrome))


        if force.phase == .edit {
            // The transform gizmo's shape test (if one is up). A clearance knob keeps its home on
            // the clearance boundary (tracking the margin); only if that lands ON the gizmo does it
            // SLIDE around its locus (wall / rim, same boundary radius) to the nearest angle the
            // gizmo's own pick shape says is clear — using the real arms/gaps, not a circle. If the
            // whole boundary is inside the gizmo it falls back to the tight radial ring.
            let gizmo = gizmoClearInfo(proj)

            // ── MOVABLE (handle): each clearance knob, shape-aware around the gizmo. ──
            for item in clearanceHandleItems {
                guard let raw = proj.project(settledWorld(item.handle.anchor)) else { continue }
                var anchor = raw
                if let gizmo, !gizmo.isClear(raw) {
                    let cands = clearanceKnobCandidates(item, proj)
                    anchor = cands.first(where: gizmo.isClear)
                        ?? ClearanceRing.place(raw, around: gizmo.centre, ringRadius: Self.gizmoRingRadius)
                }
                elements.append(KeepOutElement(id: clrKnobID(item), anchor: anchor,
                                               bounds: Self.clrKnobTouch, touch: Self.clrKnobTouch,
                                               priority: .handle, maxShift: Self.keepOutMaxShift))
            }

            // ── MOVABLE (pill): the pending selection's Anchor/Load/Keep-clear action bar ──
            if let g = activeGroup, force.kind(for: g.id).isPending,
               let cm = groupCentroidModel(g), let c = proj.project(settledWorld(cm)) {
                elements.append(KeepOutElement(id: "load.pendingchip",
                                               anchor: CGPoint(x: c.x, y: c.y - 60),
                                               bounds: CGSize(width: 300, height: 44),
                                               touch: CGSize(width: 300, height: 44),
                                               priority: .pill, maxShift: Self.keepOutMaxShift))
            }

            // ── MOVABLE (pill): each load group's weight pill at its arrow tail ──
            if let mesh = viewerMesh {
                for g in loadGroups {
                    if let arrow = loadArrowGeometry(g, mesh: mesh, proj: proj) {
                        let active = g.id == selection.activeGroupID
                        let anchor = CGPoint(x: arrow.tail.x, y: arrow.tail.y - (active ? 26 : 0))
                        elements.append(KeepOutElement(id: "load.\(g.id.uuidString)", anchor: anchor,
                                                       bounds: Self.loadPillSize, touch: Self.loadPillSize,
                                                       priority: .pill, maxShift: Self.keepOutMaxShift))
                    }
                }
            }
        }

        // ── MOVABLE (handle): the design-box / keep-out grab handles (visual + hit layer
        //    both read the resolved position, so they can't desync) ──
        if showDesignGizmo {
            for (i, t) in boxCandidates(proj).enumerated() {
                elements.append(KeepOutElement(id: boxHandleID(i), anchor: t.screen,
                                               bounds: Self.boxHandleTouch, touch: Self.boxHandleTouch,
                                               priority: .handle, maxShift: Self.keepOutMaxShift))
            }
        }

        return elements
    }

    /// Resolve the keep-out layout INLINE (two passes) for this projection, keyed by id. Pure +
    /// stateless, computed fresh on demand so overlays draw at live positions that track the
    /// geometry — no cache to go stale, no smoothing lag while a primitive is dragged.
    ///
    /// Pass 1 places everything but the clearance value pills (knobs slide on their locus off the
    /// gizmo). Pass 2 anchors each pill beside its knob's RESOLVED position and clears it against
    /// the pass-1 layout (held rigid) — so a pill never separates from its knob and two pills never
    /// stack, even after the knob slid.
    private func keepOutResolved(_ proj: CameraProjection) -> [String: KeepOutPlacement] {
        guard proj.isUsable else { return [:] }
        let vp = proj.viewportSize
        let base = keepOutBaseElements(proj)
        let r1 = KeepOutSolver.resolve(base, viewport: vp)
        var map = Dictionary(r1.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Pass 2: value pills seated just beyond their resolved knobs — radially outward from the
        // gizmo, nudged further out until they clear the gizmo shape too (or beside the knob when
        // no gizmo is up).
        let gizmo = gizmoClearInfo(proj)
        let pillOut = Self.chipKnobClearance + Self.clrPillSize.width / 2
        var pass2: [KeepOutElement] = []
        for item in syncCollapsedChipItems {
            guard let knob = map[clrKnobID(item)]?.center, !(map[clrKnobID(item)]?.hidden ?? true) else { continue }
            var anchor = gizmo.map { ClearanceRing.nudgeOutward(knob, from: $0.centre, by: pillOut) }
                ?? CGPoint(x: knob.x + pillOut, y: knob.y)
            // Push the pill further out along the radial until it clears the gizmo (a few steps max).
            if let gizmo {
                var step = 0
                while step < 4, !gizmo.isClear(anchor) {
                    anchor = ClearanceRing.nudgeOutward(anchor, from: gizmo.centre, by: Self.clrPillSize.width / 2)
                    step += 1
                }
            }
            pass2.append(KeepOutElement(id: clrPillID(item), anchor: anchor,
                                        bounds: Self.clrPillSize, touch: Self.clrPillSize,
                                        priority: .label, maxShift: Self.keepOutMaxShift))
        }
        if !pass2.isEmpty {
            // The pass-1 layout, held rigid, so the pills clear the gizmo/knobs/each other.
            let occupiers = base.compactMap { e -> KeepOutElement? in
                guard let c = map[e.id]?.center, !(map[e.id]?.hidden ?? true) else { return nil }
                return KeepOutElement(id: "occ.\(e.id)", anchor: c, bounds: e.bounds, touch: e.touch,
                                      priority: .gizmo, rigid: true)
            }
            for p in KeepOutSolver.resolve(occupiers + pass2, viewport: vp) where p.id.hasPrefix("clr.pill.") {
                map[p.id] = p
            }
        }
        return map
    }

    // MARK: top-left chrome (back + project / material chip)

    private var chrome: some View {
        HStack(spacing: DS.Space.m) {
            Button { model.backHome() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(DS.Surface.bar.color)
                        .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            }
            .buttonStyle(.plain)

            HStack(spacing: DS.Space.sm) {
                // Tap the title to rename.
                Button { nameDraft = project.name; renaming = true } label: {
                    Text(project.name).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                        .foregroundStyle(DS.Color.textPrimary.color)
                }
                .buttonStyle(.plain)
                Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                // Tap the material to switch it — only same-category materials.
                Menu {
                    ForEach(model.materials(for: project.process)) { opt in
                        Button(opt.name) { model.setCurrentProjectMaterial(opt.name) }
                    }
                } label: {
                    Text(project.material)
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            .foregroundStyle(DS.Color.textPrimary.color)

            // Round-6 item 4: Undo / Redo, to the RIGHT of the name/material header. They enable/
            // disable with the history (`project.undo`); the same actions are reachable by the
            // two-finger double-/triple-tap on the viewport (see `MetalMeshView`).
            HStack(spacing: DS.Space.xs) {
                undoRedoButton("arrow.uturn.backward", label: "Undo",
                               enabled: project.canUndoNow) { project.performUndo() }
                undoRedoButton("arrow.uturn.forward", label: "Redo",
                               enabled: project.canRedoNow) { project.performRedo() }
            }
        }
        .padding(.top, DS.Space.xl3)
        .padding(.leading, DS.Space.xl4)
        .alert("Rename project", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { model.renameCurrentProject(to: nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A round Undo/Redo header button, matching the back-chevron chrome. Dims + disables when
    /// there is nothing to undo/redo (round-6 item 4).
    private func undoRedoButton(_ system: String, label: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((enabled ? DS.Color.textPrimary : DS.Color.textPrimary.opacity(0.28)).color)
                .frame(width: 42, height: 42)
                .background(Circle().fill(DS.Surface.bar.color)
                    .overlay(Circle().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: gravity setup prompt (D2) + persistent chip

    private var gravityBanner: some View {
        VStack(spacing: 3) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Color.accent.color)
                Text("Which way is down?").dsStyle(DS.TypeScale.headline)
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            Text("Drag the arrow to point straight down — it snaps to the part's own faces. Slide its base with the gizmo to sit it on the floor. Or tap the face that rests on the floor. Drag empty space to orbit, pinch to zoom.")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, DS.Space.ml).padding(.horizontal, DS.Space.xl3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, DS.Space.xl4)
    }

    // MARK: lattice viewer proxy (handoff 2026-07-28)

    /// The lattice-preview toggle + legend, LEADING-anchored so it is clear of the
    /// centre gizmo, the top-right orientation gizmo and the bottom-right settings
    /// chips (the legend also carries a `.label` keep-out element — the lowest
    /// priority — so it floats clear of any control it would otherwise touch; see
    /// LatticeProxyLayout + LatticeProxyKeepOutTests). Off by default.
    private var latticePreviewOverlay: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // ★ THE STRUTS CHIP MOVED INTO THE SELECTIONS MODAL (maintainer,
            // 2026-08-14): "The 'Struts' chip is in the middle of the 'Selections'
            // modal. Just floating. Make it attached to the bottom-right corner,
            // inside the 'selections' modal."
            //
            // It was mounted here, LEADING-anchored and offset down from the top
            // bar — a screen-space guess that happened to land on top of the
            // panel's rows. It is now the last row INSIDE `selectionsPanel`, so
            // it cannot overlap what it sits on. Only the honesty banner stays
            // floating, and only while the layer is actually up.
            // Honesty banner (bar P1): whenever the strut layer is up the user is told
            // in place what they are looking at — the live analytic strut field, not
            // the worker's exported mesh.
            // ★ THE NOTICE MOVED UNDER THE SELECTIONS PANEL (maintainer,
            // 2026-08-17). It was anchored here by a fixed top padding and
            // landed in the middle of that panel; it is now the row beneath the
            // panel's card, attached by layout rather than by a guess.
            EmptyView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, DS.Space.l)
        .padding(.top, DS.Space.xl6)   // clear the top bar
        .animation(DS.Motion.emphasized, value: showLatticePage)
        // Keep the legend/panel proxy in step with the settings (the legend is the only
        // consumer of `latticeProxy`; the surface tints derive their own params).
        .onChange(of: project.lattice) { _ in
            syncLatticeProxy()
            // The strut preview follows lattice mode: off with it; rebaked when the
            // lattice TYPE changes (the segment soup is per-lattice; cell size and
            // density are live shader params and need no rebake).
            if !project.lattice.enabled {
                showStrutPreview = false
            } else if showStrutPreview {
                // ★★ REBAKE ON ANY LATTICE CHANGE, NOT ONLY A TYPE CHANGE
                // (maintainer, 2026-08-17: "I am still not seeing the lattice
                // preview change based on the density percentage change").
                //
                // ★ THE OLD CONDITION WAS CORRECT WHEN IT WAS WRITTEN and its
                // comment said why: "cell size and density are live shader
                // params and need no rebake". That stopped being true in this
                // task. Density is now baked into the DEMAND grid (it has to be
                // — a per-region density needs one value per cell, and the
                // shader has only one uniform), the region clipping is baked
                // into the OCCUPANCY grid, and the in-plane expand moves those
                // regions. All three are bake-time inputs now, so a preview that
                // only rebakes on a topology change shows none of them.
                //
                // ★ NOT WHILE A HANDLE IS HELD. A bake is ~a second; a drag
                // writes every frame. The drags rebake on `.onEnded` instead,
                // so the picture lands once, when the value settles.
                if draggingExpandPlane == nil, draggingDepthPlane == nil,
                   latticeDepthDragSeed == nil {
                    buildStrutScene()
                }
            }
        }
        .onChange(of: showLatticePage) { open in if open { syncLatticeProxy() } }
        // Graded follow-up: when a run's accepted variants land (streamed or final),
        // rebake the strut scene so its radii grade by the fresh von Mises field.
        // Keyed on acceptedCount (cheap, Equatable); no-op while the preview is off.
        .onChange(of: run.outcome?.acceptedCount ?? -1) { _ in
            if showStrutPreview { buildStrutScene() }
        }
        // BAR 4, the other half: when a run produced nothing and the previous run's
        // variants came BACK, say so — results reappearing behind a failure sheet
        // with no explanation is its own confusion.
        .onChange(of: run.restoredPreviousResults) { restored in
            announceRestoredResults(restored)
        }
        // BAR 4: a new run is the ONE remaining thing that retires finished
        // variants, and it says so before it does.
        .alert("Replace your results?", isPresented: replacementPromptBinding) {
            Button("Optimize anyway", role: .destructive) {
                pendingReplacement = nil
                startRun()
            }
            Button("Keep my results", role: .cancel) { pendingReplacement = nil }
        } message: {
            Text(pendingReplacement?.message ?? "")
        }
        .onAppear {
            syncLatticeProxy()
            // A reopened project already carries roles and depths — the cards
            // must be there on arrival, not only after the user touches a chip.
            refreshLatticeFaceCards()
        }
    }

    // MARK: the lattice page (handoff 2026-07-30-lattice-page)

    /// THE MESH THE STAGE DRAWS (bar Z9). When the lattice page was entered from
    /// a finished variant, that is THAT VARIANT'S geometry — not the original
    /// part with a label claiming otherwise. Everything drawn over the stage
    /// (the preview overlay, the region volumes, the picker) reads the same
    /// mesh through this one property, so the page cannot show one object and
    /// operate on another.
    private var stageMesh: ViewerMesh? {
        // The smoothing page's stage shows what its model says is current — the
        // smoothed twin only when there IS one and the user is looking at it.
        // `currentGeometry` is the single decision; nothing here second-guesses it.
        if showSmoothingPage, let page = smoothingPageModel {
            return page.currentGeometry.smoothed
                ? (smoothedVariantMesh ?? smoothVariantMesh)
                : smoothVariantMesh
        }
        return latticeVariantMesh ?? viewerMesh
    }

    /// Open the full-screen lattice page. `variantIndex` non-nil = the variants
    /// entry: the page then WORKS ON THAT VARIANT — its geometry is what the
    /// stage renders, its own von Mises field is the demand field (so Auto
    /// density is available with NO sim, bar B6's second path), and the action
    /// row offers "Lattice this variant" as a job distinct from re-running the
    /// ladder (bar Z7).
    /// The facts BOTH entry gates decide on, for one finished variant (bar AJ2/AJ4).
    ///
    /// Every field comes from the RUN's own record — its outcome and the job
    /// document retained beside it — or from the compute choice. Nothing here reads
    /// `project.designBox`, `project.force` or `project.selection`: whether a
    /// finished variant can be worked on is a question about the run that produced
    /// it, not about what the workspace happens to be set to now.
    private func variantEntryFacts(_ index: Int) -> VariantEntryFacts? {
        guard let o = run.outcome, o.variants.indices.contains(index) else { return nil }
        let v = o.variants[index]
        let art = project.relatticeArtifacts
        return VariantEntryFacts(
            hasGeometry: !v.meshVertices.isEmpty && !v.meshIndices.isEmpty,
            machine: SolvingMachine.of(o),
            retainedJob: art?.jobJSON, retainedDesign: art?.designBin,
            runGeneratedLattice: o.latticeReport != nil,
            modelPath: project.importedFile?.path,
            workerSelected: compute.activeRemote != nil,
            runInFlight: run.phase == .running,
            // A RE-ATTACHED run has no submitted document to retain (the app was
            // restarted since), and says exactly that rather than borrowing the
            // "predates retention" sentence, which would be false.
            reattached: run.wasReattached,
            // The rung the retained design container is indexed by.
            requestedVolumeFraction: v.requestedVolumeFraction)
    }

    /// The Smooth entry control's verdict for a variant — what the results screen's
    /// button renders, enabled or disabled-with-a-reason.
    private func smoothEntry(_ index: Int) -> VariantEntryVerdict {
        guard let f = variantEntryFacts(index) else {
            return VariantEntryVerdict(label: "Smooth", enabled: false,
                                       reason: "this run has no variant here",
                                       allReasons: ["this run has no variant here"])
        }
        return VariantEntry.smoothing(f)
    }

    /// The Lattice entry control's verdict for a variant.
    private func latticeEntry(_ index: Int) -> VariantEntryVerdict {
        guard let f = variantEntryFacts(index) else {
            return VariantEntryVerdict(label: "Lattice", enabled: false,
                                       reason: "this run has no variant here",
                                       allReasons: ["this run has no variant here"])
        }
        return VariantEntry.lattice(f)
    }

    private func openLatticePage(variantIndex: Int?,
                                 smoothed: SmoothKeptResult? = nil) {
        // AJ2: the page is UNREACHABLE when the entry is blocked, not merely
        // apologetic once you are inside it. The button is already disabled; this is
        // the second layer, so no other caller can open a dead end either.
        if let idx = variantIndex {
            let gate = latticeEntry(idx)
            guard gate.enabled else {
                model.toast = gate.reason ?? "This variant can’t be latticed."
                return
            }
        }
        latticeVariantContext = nil
        latticeVariantMesh = nil
        if let idx = variantIndex, let o = run.outcome, o.variants.indices.contains(idx),
           !o.variants[idx].vonMisesField.isEmpty {
            var v = o.variants[idx]
            // AE8, forward: a KEPT smoothing hands its own geometry on, so the
            // lattice is generated on the SMOOTHED shape and not on the original
            // under a label that says smoothed. The field, the rung and the
            // retained artifacts are the variant's own and travel unchanged — only
            // the geometry differs, which is exactly what smoothing changed.
            if let k = smoothed {
                v = v.withGeometry(vertices: k.meshVertices, indices: k.meshIndices)
            }
            let field = LatticeDemandField(
                vonMises: v.vonMisesField,
                nx: o.gridNx, ny: o.gridNy, nz: o.gridNz,
                origin: o.gridOrigin, spacingMM: o.spacing,
                provenance: .variant(runName: project.name, variantIndex: idx,
                                     date: nil))
            latticePageVariantField = field
            // Whether this variant can actually be re-latticed is a question
            // about what the RUN kept, and it is answered here rather than at
            // the button, so the page can say WHY when the answer is no.
            // A pair with NO DESIGN half is a real state since task
            // 2026-08-03-variant-postprocessing-fix (the job document is retained at
            // submit, the design only once the solver has produced one), so
            // "artifacts != nil" is no longer the same question as "can this be
            // latticed". The page reads the design, not the pair.
            let artifacts = project.relatticeArtifacts
            let why: RelatticeUnavailable? = artifacts?.hasDesign == true
                ? nil
                : (SolvingMachine.of(o).isThisDevice ? .computedOnDevice
                                                     : .runPredatesDesignStore)
            // ONE builder (task 2026-08-04-variant-volume-fraction-mismatch, bar
            // L2): every field that describes the design comes from the variant's
            // own record and from the retained container, in a pure function the
            // tests drive on this same path.
            latticeVariantContext = LatticeVariantContext.from(
                variant: v, runName: project.name, variantIndex: idx,
                field: field, artifacts: artifacts, unavailable: why)
            // The variant's own render mesh. `faceIDs` is deliberately EMPTY: an
            // optimized result has no B-rep and no pseudo-faces, and claiming
            // otherwise is what would let a tap resolve to a face that is not
            // there. Smooth-shaded, like the results screen draws it.
            if !v.meshVertices.isEmpty, !v.meshIndices.isEmpty {
                latticeVariantMesh = ViewerMesh(vertices: v.meshVertices,
                                                indices: v.meshIndices,
                                                faceIDs: [], faceGeometry: [],
                                                pseudoFaces: false,
                                                smoothShaded: true)
            }
        } else {
            latticePageVariantField = nil
        }
        // TWO FULL-SCREEN PAGES MUST NEVER BOTH BE UP (round-2 bar L5). Each page
        // owns the whole screen, so overlapping them is the overlay defect in its
        // purest form. Making it structural here also lets `showLatticePage` be
        // read as "and therefore not the smoothing page" at every placement site.
        showSmoothingPage = false
        showLatticePage = true
    }

    // MARK: the smoothing page (handoff 2026-08-02-smoothing-page)

    /// The scratch directory the page's meshes live in: the variant as the run
    /// made it, and the smoothed twin core writes.
    private var smoothScratchDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-smoothing", isDirectory: true)
    }

    /// Open the SMOOTHING page on a finished variant. The load case comes from the
    /// variant's RETAINED JOB DOCUMENT (bar AE3) — never from `project.force` /
    /// `project.selection`, which the user may have edited since the run. Nothing
    /// in this function reads either.
    private func openSmoothingPage(variantIndex: Int) {
        guard let o = run.outcome, o.variants.indices.contains(variantIndex) else { return }
        // AJ2: never open a page that will then refuse. The button is disabled with
        // this same reason; this is the second layer, so the dead end is unreachable
        // even from a caller that forgot to check.
        let gate = smoothEntry(variantIndex)
        guard gate.enabled else {
            model.toast = gate.reason ?? "This variant can’t be smoothed."
            return
        }
        let v = o.variants[variantIndex]

        // Write the variant's own mesh out once: the certification engine reads
        // meshes from disk, and BOTH columns of the receipt are measured on this
        // exact file (the before directly, the after after smoothing it).
        try? FileManager.default.createDirectory(at: smoothScratchDir,
                                                 withIntermediateDirectories: true)
        let inPath = smoothScratchDir
            .appendingPathComponent("variant_\(variantIndex).stl").path
        let outPath = smoothScratchDir
            .appendingPathComponent("variant_\(variantIndex)_smoothed.stl").path
        smoothVariantMeshPath = inPath
        try? TopOptKit.exportSTL(
            mesh: ImportedMesh(
                vertices: v.meshVertices, indices: v.meshIndices, faceIDs: [],
                vertexCount: v.meshVertices.count / 3,
                triangleCount: v.meshIndices.count / 3, faceCount: 0,
                watertight: true),
            to: inPath)

        // ROUND 2, BAR S2 — THE PAGE'S ONE MESH. From here on the page does NOT
        // use `v.meshVertices` for anything: it reads the file back through
        // CORE's own importer, and that is the mesh the stage draws, the brush
        // paints, `smooth_freeze_mask` masks, and the smoother moves.
        //
        // Why this is the fix and not a remap: those four already all read this
        // file. The app was the only participant holding a different buffer —
        // on a LAN run a triangle soup with 6x core's vertex count, because
        // `MeshExport.parseBinarySTL` shares no vertices between facets while
        // core's `import_part_file` welds by exact coordinate. Measured 6.0030
        // on the maintainer's fixture (`smooth_mesh_identity_probe`); their
        // screen read 105060 vs 17496. Reconciling the two would be the guess
        // the guard refuses to make. Dropping one of them leaves nothing to
        // reconcile.
        var meshError: String?
        var pageMesh = SmoothPageMesh(path: inPath, vertices: [], indices: [])
        do {
            pageMesh = try SmoothPageMesh.imported(from: inPath) { path in
                let m = try TopOptKit.importMesh(path: path)
                return (m.vertices, m.indices)
            }
        } catch {
            meshError = (error as? TopOptError)?.message ?? "\(error)"
        }

        let ctx = SmoothPageEntry.context(
            runName: project.name, variantIndex: variantIndex,
            requestedVolumeFraction: v.requestedVolumeFraction,
            massGrams: v.massGrams, reportedMargin: v.worstCaseMargin,
            accepted: v.accepted, pageMesh: pageMesh,
            // The RUN's own record of whether it generated a lattice — not the
            // project's current lattice settings (AE8, reverse).
            latticed: o.latticeReport != nil,
            retainedJob: project.relatticeArtifacts?.jobJSON,
            modelPath: project.importedFile?.path,
            meshUnreadable: meshError)

        // A `.meshUnreadable` context is the one refusal the ENTRY GATE cannot
        // reach: it is only knowable after writing the file and asking core to
        // read it back, which the gate must not do for every disabled button. So
        // it takes the page's own `gateOverlay` — the full-screen "this variant
        // can't be smoothed" card, carrying core's own words — rather than a
        // toast that scrolls away. AJ2 is about not opening a page that will
        // refuse SILENTLY; naming the refusal on the page is the point of that
        // overlay existing.

        // THE STAGE DRAWS THE PAGE MESH, not the run's buffer — so what is on
        // screen is what the brush indexes and what core masks.
        smoothVariantMesh = pageMesh.isEmpty
            ? nil
            : ViewerMesh(vertices: pageMesh.vertices, indices: pageMesh.indices,
                         faceIDs: [], faceGeometry: [],
                         pseudoFaces: false, smoothShaded: true)
        smoothedVariantMesh = nil

        guard let cfg = model.certificationConfigPaths() else { return }
        let materials = cfg.materials, rules = cfg.rules
        smoothingPageModel = SmoothingPageModel(
            context: ctx, variantMeshPath: inPath, smoothedMeshPath: outPath,
            runner: { request in
                try await Task.detached(priority: .userInitiated) {
                    let lc = request.loadCase
                    switch request.subject {
                    case .originalVariant:
                        // THE BEFORE COLUMN IS MEASURED (bar AE2): a real
                        // analyze_fixed_design pass over the UNSMOOTHED variant,
                        // through the same seam the after column uses.
                        let c = try TopOptKit.certifyMeshLoadCase(
                            modelPath: request.modelPath,
                            meshPath: request.inputMeshPath,
                            material: lc.material, materialsPath: materials,
                            rulesPath: rules, resolution: lc.resolution,
                            anchorFaceIDs: lc.anchorFaceIDs,
                            loadGroups: lc.loadGroups,
                            buildDirection: lc.buildDirection,
                            infillPercent: lc.infillPercent)
                        return SmoothingPageModel.CertifyOutcome(
                            certification: SmoothCertification(subject: .originalVariant, c),
                            smoothing: nil)
                    case .smoothedVariant:
                        let r = try TopOptKit.smoothBrushAndRecertifyLoadCase(
                            modelPath: request.modelPath,
                            inputMeshPath: request.inputMeshPath,
                            smoothedOutPath: request.outputMeshPath,
                            material: lc.material, materialsPath: materials,
                            rulesPath: rules, resolution: lc.resolution,
                            strength: request.strength, weights: request.weights,
                            enforceMinFeature: true,
                            anchorFaceIDs: lc.anchorFaceIDs,
                            loadGroups: lc.loadGroups,
                            buildDirection: lc.buildDirection,
                            infillPercent: lc.infillPercent, freeze: lc.freeze)
                        let mesh = try TopOptKit.importMesh(
                            path: r.smoothing.smoothedMeshPath)
                        return SmoothingPageModel.CertifyOutcome(
                            certification: SmoothCertification(subject: .smoothedVariant,
                                                               r.certification),
                            smoothing: SmoothingApplied(
                                maxStrength: request.strength,
                                pairsRequested: r.smoothing.pairsRequested,
                                pairsApplied: r.smoothing.pairsApplied,
                                totalVertices: r.smoothing.totalVertices,
                                frozenVertices: r.smoothing.frozenVertices,
                                brushedVertices: r.smoothing.brushedVertices,
                                unbrushedVertices: r.smoothing.unbrushedVertices,
                                volumeDriftFraction: r.smoothing.volumeDriftFraction,
                                volumeDriftBound: r.smoothing.volumeDriftBound,
                                minFeatureLimited: r.smoothing.minFeatureLimited,
                                regionLines: []),
                            meshVertices: mesh.vertices, meshIndices: mesh.indices)
                    }
                }.value
            },
            // THE LIVE BRUSH PREVIEW (task
            // 2026-08-04-variant-volume-fraction-mismatch, failure C / bar L4;
            // moved out of this closure by task 2026-08-08, S1b). Same smoother,
            // no certification, and NO FILE: see `SmoothingPageWiring`, which
            // exists so a test can drive the engine the page actually runs
            // instead of a stand-in that cannot reproduce its I/O.
            previewer: SmoothingPageWiring.livePreviewer)

        // The freeze mask, from CORE's own predicate resolution. Until it arrives
        // the brush is inert and the page says so — it must not paint into the
        // unknown.
        //
        // BOTH the brush and the request are built BY the page mesh: `brush()`
        // takes its indices and count from it, and `freezeMaskRequest` fills the
        // mesh path in from it. Neither has a parameter through which a different
        // mesh could enter — bar S2's "by construction".
        smoothBrush = pageMesh.brush()
        smoothTools = SmoothBrushTools()
        // Mutually exclusive, both ways (bar L5) — see `openLatticePage`.
        showLatticePage = false
        showSmoothingPage = true
        if let req = ctx.freezeMaskRequest {
            Task {
                let lc = req.loadCase
                let mask = try? await Task.detached(priority: .userInitiated) {
                    try TopOptKit.smoothFreezeMask(
                        modelPath: req.modelPath, meshPath: req.meshPath,
                        resolution: lc.resolution,
                        anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
                        buildDirection: lc.buildDirection,
                        infillPercent: lc.infillPercent, freeze: lc.freeze)
                }.value
                guard let mask else { return }
                smoothBrush = pageMesh.brush(
                    freeze: SmoothFreezeMask(frozen: mask.frozen,
                                             toleranceMM: mask.toleranceMM,
                                             meshPath: req.meshPath))
            }
        }
    }

    private func closeSmoothingPage() {
        showSmoothingPage = false
        smoothingPageModel = nil
        smoothVariantMesh = nil
        smoothedVariantMesh = nil
        smoothBrush = SmoothBrushModel(indices: [], vertexCount: 0, freeze: .unavailable)
    }

    private var smoothingPageOverlay: some View {
        Group {
            if let page = smoothingPageModel {
                SmoothingPage(
                    project: project, page: page,
                    brush: $smoothBrush,
                    tools: $smoothTools,
                    showingSmoothed: Binding(
                        get: { page.showingSmoothed },
                        set: { page.showingSmoothed = $0 }),
                    onRecertify: {
                        let brush = smoothBrush
                        Task {
                            await page.recertify(brush: brush)
                            // Render the smoothed twin only once it CERTIFIED —
                            // an uncertified shape never becomes the stage's
                            // "smoothed" view (the honesty rule, on the stage).
                            if page.receipt != nil {
                                let g = page.currentGeometry
                                smoothedVariantMesh = g.smoothed
                                    ? ViewerMesh(vertices: g.vertices, indices: g.indices,
                                                 faceIDs: [], faceGeometry: [],
                                                 pseudoFaces: false, smoothShaded: true)
                                    : nil
                            }
                        }
                    },
                    onDiscard: {
                        // AE9: the original is never mutated, so discarding is a
                        // state reset and the stage goes straight back to the
                        // variant the run produced.
                        page.discard()
                        smoothBrush.clearStrokes()
                        smoothedVariantMesh = nil
                    },
                    onSendToLattice: {
                        guard let kept = page.kept else {
                            model.toast = "Keep the smoothing first — a lattice needs "
                                + "certified geometry."
                            return
                        }
                        let idx = page.context.variantIndex
                        closeSmoothingPage()
                        openLatticePage(variantIndex: idx, smoothed: kept)
                    },
                    onClose: { closeSmoothingPage() })
                    .ignoresSafeArea(.keyboard)
            }
        }
    }

    /// Close the lattice page and DROP the variant context — the stage goes back
    /// to the original part, face tapping comes back, and no later action can
    /// still be pointing at a variant the user has left.
    private func closeLatticePage() {
        showLatticePage = false
        latticePageModel.libraryOpen = false
        latticeVariantContext = nil
        latticeVariantMesh = nil
        // The page is gone; a forecast still in flight is about settings nobody is
        // looking at, and the answer would describe a variant that has been left.
        latticeForecast.clear()
    }

    /// LATTICE THIS VARIANT (bar Z7). Submits the `lattice_variant` job against
    /// the RETAINED design + the RETAINED job document — no ladder runs. Refused
    /// (with the reason already on the button) when the run kept neither, and
    /// refused when there is no worker: the certification solves run where the
    /// core runs, and the on-device bridge has no lattice path at all.
    /// THE `lattice_variant` JOB DOCUMENT — built ONCE, for both the run and the
    /// forecast of it (bar F3).
    ///
    /// The forecast is only worth anything if it describes the job the button
    /// actually submits. Two builders would be two chances to drift, which is the
    /// [[infill-knockdown-duplicated-app-core]] failure exactly. So there is one:
    /// `startRelatticeRun` submits what this returns, and the forecast is a
    /// forecast OF these bytes (RelatticeRun arms `lattice.forecast_only` inside
    /// the runner, on this same document, so the two differ in one key and no
    /// other). `noteSkippedFaces` is off for the forecast — it must not post
    /// transient notes on every settings change.
    private func relatticeJobJSON(noteSkippedFaces: Bool) -> Data? {
        guard let ctx = latticeVariantContext, let art = ctx.artifacts else { return nil }
        // The regions the page authored, as EXPLICIT GEOMETRY PREDICATES (bar
        // Z11): on a variant only placed primitives are emitted, because a face
        // id would resolve against the ORIGINAL part's surface, which this design
        // no longer has.
        let emission = project.variantLatticeJobRegions()
        if noteSkippedFaces, emission.skippedFaces > 0 {
            latticePageModel.post(
                note: "\(emission.skippedFaces) face selection(s) were not carried "
                    + "onto this variant — an optimized surface has no faces to "
                    + "resolve them against. Place a region instead.")
        }
        // The SAME spec builder the optimize request uses — only the regions
        // differ, and they differ for the Z11 reason above.
        // The STRUT width, matching AppModel.makeRunRequest (task
        // 2026-08-06-strut-line-width-field): a re-lattice must use the same
        // printability reference the optimize run did, or the two jobs derive
        // different cells from the same project.
        let spec = project.lattice.runSpec(
            topology: project.lattice.topologyID,
            memberMM: project.lattice.regionMemberMM ?? 0,
            lineWidthMM: project.printParams.strutLineWidthMM,
            regions: emission.regions)
        // THE VARIANT'S OWN IDENTITY AND ITS OWN NUMBER (task
        // 2026-08-04-variant-volume-fraction-mismatch). This passed
        // `ctx.requestedVolumeFraction` — the LADDER RUNG — into a job key core
        // validates as a fraction in (0, 1]. On the maintainer's growth run the
        // rung is 1.1 and every attempt died at schema validation. Both values
        // now come from the variant itself.
        return try? RelatticeJobBuilder.build(
            original: art.jobJSON, variant: ctx, lattice: spec)
    }

    /// The forecast's input and identity: the job above, but only when a forecast
    /// can actually be produced. No worker, no retained design, no variant ⇒ nil,
    /// and the drawer says so rather than spinning forever.
    private var latticeForecastJob: Data? {
        guard showLatticePage, compute.activeRemote != nil,
              latticeVariantContext?.artifacts != nil else { return nil }
        return relatticeJobJSON(noteSkippedFaces: false)
    }

    /// Runs the forecast on the worker: the same submit + poll as the run, with
    /// `lattice.forecast_only` armed. Core measured it at 0.09–0.55 s against the
    /// 4–39 s runs it forecasts.
    private func makeForecastDriver() -> (@Sendable (Data) async throws -> LatticeForecast)? {
        guard let config = compute.activeRemote,
              let file = project.importedFile,
              let art = latticeVariantContext?.artifacts,
              let vf = latticeVariantContext?.requestedVolumeFraction else { return nil }
        let name = project.name
        let designBin = art.designBin
        let path = file.path
        return { job in
            let inputs = RelatticeRun.Inputs(
                config: config, modelPath: path, jobJSON: job,
                designBin: designBin, projectName: name,
                requestedVolumeFraction: vf)
            return try await Task.detached(priority: .utility) {
                try RelatticeRun.forecast(inputs)
            }.value
        }
    }

    private func startRelatticeRun() {
        guard let ctx = latticeVariantContext, let art = ctx.artifacts else {
            if let why = latticeVariantContext?.unavailable { model.toast = why.reason }
            return
        }
        guard run.phase != .running else { return }
        guard let config = compute.activeRemote else {
            model.toast = "Latticing a variant runs on a Mac worker — pick one in Compute."
            return
        }
        guard let file = project.importedFile else {
            model.toast = "Can’t re-lattice — the model file is missing."
            return
        }
        // THE SAME DOCUMENT THE FORECAST DESCRIBED — one builder, so the prediction
        // and the job cannot drift apart.
        guard let jobJSON = relatticeJobJSON(noteSkippedFaces: true) else {
            model.toast = "Can’t build the re-lattice job from this run’s retained "
                + "job document."
            return
        }
        // BAR Z2, app side: the document about to be submitted must differ from
        // the one that produced this variant ONLY in the lattice question. If any
        // load-case key moved, refuse HERE — before the worker spends solves
        // certifying under a load case the variant was never optimized under.
        let moved = RelatticeJobBuilder.loadCaseDifferences(art.jobJSON, jobJSON)
        guard moved.isEmpty else {
            model.toast = "Can’t re-lattice: the load case changed (\(moved.joined(separator: ", "))). "
                + "This job must certify under the load case the variant was optimized under."
            return
        }
        viewOriginal = false
        let inputs = RelatticeRun.Inputs(
            config: config, modelPath: file.path, jobJSON: jobJSON,
            designBin: art.designBin, projectName: project.name,
            requestedVolumeFraction: ctx.requestedVolumeFraction)
        // THE RECEIPT WAS BEING THROWN AWAY (task
        // 2026-08-05-lattice-retention-app-control, S4). `RelatticeRun.run` has
        // always fetched the variant's graded lattice receipt and this call site
        // took `.outcome` and dropped it on the floor — so a re-lattice, which is
        // the path the Lattice page actually drives, showed no lattice record at
        // all. It now carries the receipt onto the outcome, which is what puts the
        // per-region breakdown on the results screen.
        // The STRUT width, matching the job this receipt describes.
        let echo = project.lattice.runSpec(
            topology: project.lattice.topologyID,
            memberMM: project.lattice.regionMemberMM ?? 0,
            lineWidthMM: project.printParams.strutLineWidthMM,
            regions: project.variantLatticeJobRegions().regions)
        run.runner = { _, _, _ in
            let result = try RelatticeRun.run(inputs)
            guard let spec = echo else { return result.outcome }
            return result.outcome.withLatticeReport(LatticeReport(
                topologyID: spec.topologyID, cellMM: spec.cellMM,
                generateRelativeDensity: spec.generateRelativeDensity,
                minRelativeDensity: spec.minRelativeDensity,
                maxRelativeDensity: spec.maxRelativeDensity,
                regionScoped: spec.regionScoped,
                emittedRegions: spec.regions.count,
                // The per-region rows only exist when the job asked for them; a
                // receipt that carries none parses to nil and shows nothing.
                regionCellsJSON: spec.reportRegionCells ? result.receiptJSON : nil))
        }
        guard let request = model.makeRunRequest() else { return }
        closeLatticePage()
        run.start(request, remote: true, workerName: compute.selectedWorkerName)
    }

    private var latticePageOverlay: some View {
        LatticePage(model: model, project: project, run: run,
                    sim: latticeSim, page: latticePageModel,
                    variantField: latticePageVariantField,
                    variantContext: latticeVariantContext,
                    previewOn: Binding(
                        get: { showStrutPreview },
                        set: { on in
                            showStrutPreview = on
                            if on, strutScene == nil { buildStrutScene() }
                        }),
                    baseCanOptimize: canOptimize,
                    baseSummary: force.optimizeSummary(
                        in: selection.groups,
                        latticeRoleGroups: latticeRoleGroupIDs),
                    onOptimize: { requestRun() },
                    onRelattice: { startRelatticeRun() },
                    onClose: { closeLatticePage() },
                    onBackToSetup: { closeLatticePage() },
                    // L17: the page's Refresh re-runs the preview with the CURRENT
                    // settings — a fresh strut-scene bake + proxy sync.
                    onRefreshPreview: {
                        syncLatticeProxy()
                        buildStrutScene()
                    },
                    // BAR F3's CALL SITE, from this side: the model outlives the
                    // page (close and reopen and the answer is still there), the
                    // job document is both the input and the identity, and the
                    // driver is nil exactly when no forecast is possible.
                    forecast: latticeForecast,
                    forecastJob: latticeForecastJob,
                    driveForecast: makeForecastDriver())
            .ignoresSafeArea(.keyboard)
    }

    /// The strut-preview toggle chip — shows the ACTUAL lattice geometry, raymarched
    /// with zero triangles (handoff 2026-07-29-lattice-preview). Off by default.
    private var strutPreviewChip: some View {
        Button {
            if showStrutPreview {
                showStrutPreview = false
            } else {
                showStrutPreview = true
                if strutScene == nil { buildStrutScene() }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "cube.transparent").font(.system(size: 12, weight: .bold))
                Text(showStrutPreview ? "Struts · on" : "Struts")
                    .dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
            }
            // ★ §4(c) — NOT PURPLE. This chip read its tint off the DENSITY RAMP
            // (`densityColor(0.75)`), which is where the purple chrome came from.
            // The ramp is the LATTICE'S colour language and belongs on the
            // lattice itself; a toggle chip is chrome and wears the accent (S7).
            .foregroundStyle(showStrutPreview
                ? DS.Color.accent.color
                : DS.Color.textSecondary.color)
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.panel.color)
                .overlay(Capsule().strokeBorder(
                    (showStrutPreview ? DS.Color.accent.opacity(0.6)
                                      : DS.Color.strokeSubtle).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .dsShadow(DS.Shadow.panel)
        .help("Show the actual strut lattice, raymarched live — a preview of the geometry, not the exported mesh.")
    }

    /// Bake the strut-preview scene (occupancy + exact part SDF + segment soup) OFF
    /// the main thread — ~a second on a big part, once per mesh/lattice-type/result
    /// change, never per frame (P2). The layer appears when the bake lands.
    ///
    /// GRADED after a run (follow-up, maintainer-approved): when the run's outcome
    /// carries a von Mises field, the strut radii grade by it — thick struts on the
    /// load path, sparse in quiet regions, the lattice the grading law would build.
    /// Pre-run (or when no field exists) the preview is uniform, like the proxy.
    private func buildStrutScene() {
        guard let mesh = viewerMesh else { return }
        let latticeID = latticeProxy.params.latticeID
        // Auto density on the lattice page grades the preview from the page's OWN
        // demand field (the variant's field on the variants entry, else the sim's) —
        // provenance the page shows next to the Auto control (bar B6). Otherwise the
        // shipped behaviour: the newest accepted variant's field, uniform pre-run.
        let field: StressField?
        if showLatticePage, project.lattice.densityMode == .auto,
           let f = latticePageVariantField ?? latticeSim.field {
            field = StressField(nx: f.nx, ny: f.ny, nz: f.nz,
                                origin: SIMD3<Float>(f.origin), spacing: Float(f.spacingMM),
                                values: f.vonMises)
        } else {
            field = LatticeSDFScene.demandField(from: run.outcome)
        }
        // ★ THE REGIONS THE RUN WILL ACTUALLY LATTICE (maintainer, 2026-08-17).
        // Read on the main actor and captured, because `latticeJobRegions()`
        // walks the selection and the settings. Empty on the settings page's
        // sample block, which is exactly when clipping must NOT happen.
        let regions = project.latticeJobRegions().regions
        // The SAME band and gamma the raymarcher grades with, so a stated
        // per-region density can be inverted into the demand value that comes
        // back out as exactly that density.
        let span = latticeProxy.params.densitySpan
        let gamma = max(0.05, latticeProxy.params.gamma)
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = LatticeSDFScene(mesh: mesh, field: field,
                                        latticeID: latticeID, regions: regions,
                                        rhoMin: span.lo, rhoMax: span.hi,
                                        gamma: gamma)
            DispatchQueue.main.async {
                strutScene = scene
                strutSceneToken += 1
            }
        }
    }

    /// ★ §1b — THE ONE BUTTON THAT REMAINS ON THE TO PAGE. It NAVIGATES; it is
    /// NOT a state readout.
    ///
    /// It was "Lattice settings · on" over a sub-line describing the configuration,
    /// which is exactly the "the TO page tells me about lattices" complaint: a user
    /// who never wants a lattice was being told about one on every frame. Now it is
    /// one word, the same word whether or not a lattice is configured, and it is
    /// ★ GREEN, not purple (standing backlog item 8).
    ///
    /// It still says what is MISSING while it is disabled — that is a
    /// prerequisites message, not a description of the lattice — and says nothing
    /// at all once it is enabled.
    ///
    /// ★ §4 — THE STAGE BUTTON. **ONLY THE COLOUR CHANGED.**
    ///
    /// ★ THE MAINTAINER'S CORRECTION, IN SESSION, AND IT SUPERSEDES §4(a)/§4(b)
    /// AS WRITTEN: "I meant for the 'Lattice' button to be a dark blue like the
    /// *colour* of the chips with the icons! But stay the size and position they
    /// are at the top of the screen just to the left of the gizmo with the perfect
    /// amount of spacing. This is the same space where 'Lattice Settings' will be
    /// on the other page."
    ///
    /// So the size (64 pt, Optimize's stature) and the slot (top-right, LEFT of
    /// the gizmo by `gizmoClearance`) are UNCHANGED. What changed is one thing:
    ///
    ///   ★ the fill was `DS.Color.accentGreen` (#30D158) and is now
    ///     `DS.Color.accent` (#0A84FF) — the dark blue the bottom-right chips use
    ///     for their ICONS (`gravityChip`'s `arrow.down.to.line`, and every chip
    ///     beside it). §4(c): "The purple fucking colour should never happen again
    ///     (same with the green)."
    ///
    /// ★ AND IT SITS AT THE TOP OF THE SCREEN, NOT CENTRED ON THE GIZMO — his
    /// second correction. It used to be offset by `(gizmoSize - 64) / 2`, which
    /// centred a 64 pt button inside the 210 pt gizmo and pushed it 81 pt down.
    /// Its top edge now lines up with the gizmo's own top inset, so the two read
    /// as one top row. The gizmo itself does not move (§4d / rule S10).
    ///
    /// It still says what is MISSING while disabled — a prerequisites message,
    /// not a description of the lattice — and says nothing once enabled.
    @ViewBuilder private var stageNavigationButtonOverlay: some View {
        // ★ THE WAY BACK — top-left, under the project name. Topology is the root
        // and carries none.
        if let back = stage.back {
            stageNavButton(to: back, icon: "chevron.left")
                .modifier(StageNavPlacement(stage: stage))
        }
        // ★ THE WAY FORWARD — the top-right column, LEFT of the gizmo.
        //
        // ★ "WHERE YOU GO" ABOVE "WHAT YOU CONFIGURE" (the maintainer's phrase,
        // approved 2026-08-14). This column is NAVIGATION ONLY; the lattice
        // stage's Settings button renders BELOW it, offset by
        // `settingsButtonTopInset`, never among it.
        VStack(alignment: .trailing, spacing: PageChrome.gap) {
            ForEach(stage.forward, id: \.rawValue) { dest in
                stageNavButton(to: dest, icon: Self.stageIcon(dest))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, PageChrome.gizmoClearance)
        // ★ THE GIZMO'S VISIBLE TOP, NOT ITS FRAME'S. See
        // `PageChrome.gizmoAlignedTop` — the housing is 90% of the frame and
        // centred, so `gizmoInset` alone left these ~10 pt high.
        .padding(.top, PageChrome.gizmoAlignedTop)
    }

    /// One stage's glyph.
    static func stageIcon(_ s: WorkspaceStage) -> String {
        switch s {
        case .topology: return "chevron.left"
        case .lattice:  return "square.grid.3x3.fill"
        case .surface:  return "square.on.square.dashed"
        }
    }

    // MARK: ★ CHANGING STAGE — and the Surface stage's save/revert
    //
    // Maintainer, 2026-08-16: "I think we should have a 'Save' button on the
    // 'Surfaces' page. This way someone can fuck around and mess things up, and
    // just go back and nothing is saved. Everything should reset when you leave and
    // come back — unless it has been saved."

    /// ★ THE ONE PLACE THE STAGE CHANGES. Routed through a function rather than
    /// assigned at each button, because "leaving Surface reverts unsaved work" has
    /// to be true of EVERY way out — a second `stage = dest` somewhere else is a
    /// silent hole in the promise.
    private func goToStage(_ dest: WorkspaceStage) {
        if stage == .surface, dest != .surface {
            if let snap = surfaceEntrySnapshot,
               project.surfaceHasEdits(since: snap) {
                project.surfaceRestore(snap)
                // ★ SAY SO. A silent revert is indistinguishable from a crash that
                // ate the work; the whole point is that discarding is SAFE, and
                // safe is only useful if it is also legible.
                model.toast = "Surface edits discarded — use Save to keep them."
            }
            surfaceEntrySnapshot = nil
            surfaceResetTools()
        }
        if dest == .surface, stage != .surface {
            surfaceEntrySnapshot = project.surfaceCaptureScratch()
            surfaceResetTools()
        }
        stage = dest
        latticeDisclosure.closeAll()
        if dest == .lattice { refreshLatticeFaceCards() }
    }

    /// Whether anything has been committed since entering the stage (or since the
    /// last save). DERIVED, never a flag: a flag has to be set at every commit site
    /// and one missed site makes Save quietly do nothing.
    private var surfaceDirty: Bool {
        guard let snap = surfaceEntrySnapshot else { return false }
        return project.surfaceHasEdits(since: snap)
    }

    /// ★ SAVE: keep what has been done, and make THAT the new "back to". Nothing is
    /// written anywhere new — the edits were always live in the model — what
    /// changes is that leaving no longer takes them away.
    private func surfaceSave() {
        surfaceEntrySnapshot = project.surfaceCaptureScratch()
        project.sealUndoStep()
        model.toast = "Surface edits saved."
    }

    /// Put every tool back to its resting state, so the stage is entered the same
    /// way every time.
    private func surfaceResetTools() {
        surfaceTool = .initial
        surfaceSelected = nil
        surfaceSelectedFace = nil
        heldCut = nil
        hoveredCut = nil
        surfaceUnion.clear()
        surfacePatternFace = nil
        surfacePatternPiece = nil
        similar.clear()
        surfaceCarried = []
        surfaceRefusal = nil
    }

    /// How far down the Settings button sits: clear of every forward nav button
    /// in the column above it. DERIVED from the count, so adding a stage can
    /// never leave the two stacked on top of each other.
    private var settingsButtonTopInset: CGFloat {
        PageChrome.gizmoInset
            + CGFloat(stage.forward.count) * (PageChrome.compactButton + PageChrome.gap)
    }

    private func stageNavButton(to dest: WorkspaceStage, icon: String) -> some View {
        let entry = LatticeEntryButtonGate.compute(gravitySet: force.gravityIsSet,
                                                   anchors: force.anchorCount(in: selection.groups),
                                                   loads: force.loadCount(in: selection.groups))
        // ★ ONLY THE LATTICE DESTINATION IS GATED — it needs an anchor, a load and
        // gravity before a lattice means anything. Going BACK, and going to
        // SURFACE (which edits the CAD faces themselves), never are.
        let enabled = dest != .lattice || entry.enabled
        return Button {
            guard enabled else { return }
            goToStage(dest)
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                    Text(dest.title)
                        .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                }
                if !enabled {
                    Text(entry.subtitle)
                        .font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                        .lineLimit(1)
                }
            }
            .foregroundStyle((enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .modifier(StageNavChrome(stage: stage))
            // ★ THE COLOUR: `accentDeep` + `accentDeepEdge`. A DARKER blue than
            // Optimize's `accent`, because these buttons NAVIGATE and Optimize
            // ACTS — with a lighter hairline so the deep fill has an edge instead
            // of reading as a flat slab. See `DS.Color.accentDeep`.
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                    .fill(enabled ? DS.Color.accentDeep.color
                                  : DS.Color.fillDisabled.color)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                        .strokeBorder((enabled ? DS.Color.accentDeepEdge
                                               : DS.Color.strokeSubtle).color,
                                      lineWidth: 1.5)))
            .dsShadow(enabled ? DS.Shadow.accentDeepGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("stage-nav-\(dest.rawValue)")
        .accessibilityLabel(enabled ? dest.title
                            : "Lattice — needs \(entry.missing.joined(separator: " and "))")
    }

    /// ★ WHERE THE STAGE BUTTON SITS, AND IT DIFFERS BY STAGE.
    ///
    /// **TO stage — "Lattice" goes FORWARD.** Top-right, LEFT of the gizmo by
    /// exactly `gizmoClearance`: the slot the maintainer calls "the perfect amount
    /// of spacing", and the slot **Lattice Settings occupies on the other page**.
    /// ★ At the TOP OF THE SCREEN, not centred on the gizmo — it used to be
    /// `DS.Space.s + (gizmoSize − 64) / 2`, 81 pt down, centring a 64 pt button
    /// inside the 210 pt gizmo. Its top edge now matches the gizmo's own inset.
    ///
    /// **Lattice stage — "Topology" goes BACK.** ★ His instruction: *"put the
    /// 'Topology' button below the name of the project. It should be flush with
    /// the LEFT side of the screen, directly below the name and < arrow with the
    /// regular padding between the two."* So it is LEADING-aligned on the same
    /// `DS.Space.xl4` inset the back chevron uses, one `PageChrome.gap` below the
    /// identity row — which frees the top-right slot for Settings, so each page
    /// has exactly one button in that corner.
    ///
    /// Every number is derived from the chrome's own tokens (`chrome` is
    /// `.padding(.top, DS.Space.xl3)` over 42 pt controls at
    /// `.padding(.leading, DS.Space.xl4)`), so the two cannot drift apart.
    /// ★ HOW TALL THE STAGE BUTTON IS, and it differs by stage for the same
    /// reason its position does.
    ///
    /// **TO stage — "Lattice" keeps Optimize's stature** (`PageChrome.actionButton`,
    /// 64 pt). His instruction: *"stay the size and position they are at the top of
    /// the screen."*
    ///
    /// **Lattice stage — "Topology" is AS THIN AS THE PROJECT NAME.** His
    /// instruction: *"make the 'Topology' button as thin as the name of the project
    /// as well."* It is thin BY CONSTRUCTION rather than by a matched constant: the
    /// name capsule is `.padding(.vertical, 9).padding(.horizontal, DS.Space.l)`
    /// around `DS.TypeScale.bodyStrong` (`chrome`, this file), and so is this. Edit
    /// one and the other has to be edited too — a shared number could drift.
    private struct StageNavChrome: ViewModifier {
        let stage: WorkspaceStage
        func body(content: Content) -> some View {
            switch stage {
            case .topology:
                // ★ THE SAME HEIGHT AS "SETTINGS" (maintainer, 2026-08-14): "The
                // 'lattice' button on the TO stage and the 'Settings' button on
                // the Lattice Stage should be the same height. Make them both the
                // height of the 'Settings' button." That is
                // `PageChrome.compactButton` (48) — they share one top-right slot
                // across the two pages, so they must share its stature.
                content.padding(.horizontal, DS.Space.xl5)
                    .frame(height: PageChrome.compactButton)
            case .lattice, .surface:
                content.padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            }
        }
    }

    private struct StageNavPlacement: ViewModifier {
        let stage: WorkspaceStage
        /// The identity row's height — the circle buttons the title bar is built from.
        static let identityRowHeight: CGFloat = 42

        func body(content: Content) -> some View {
            switch stage {
            case .topology:
                content
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, PageChrome.gizmoClearance)
                    // ★ Aligned to the gizmo's VISIBLE top — see
                    // `PageChrome.gizmoAlignedTop`.
                    .padding(.top, PageChrome.gizmoAlignedTop)
            case .lattice, .surface:
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DS.Space.xl4)
                    .padding(.top, DS.Space.xl3 + Self.identityRowHeight
                             + PageChrome.gap)
            }
        }
    }

    /// ★ THE SURFACE STAGE'S TOP SLOT: SAVE, AT FULL STATURE.
    ///
    /// Maintainer, 2026-08-16: "Please make the Save button much larger and place
    /// it where the greyed out 'Lattice' button is (removing the greyed out lattice
    /// button)."
    ///
    /// ★ AND IT EARNS THAT SLOT. This stage's default is DISCARD — walk away and
    /// the work goes — so Save is not one control among several, it is the only one
    /// that makes anything permanent. It gets the size and the position the page's
    /// most consequential action gets everywhere else (`PageChrome.actionButton`,
    /// the stature "Lattice" and "Optimize" wear), and it says how much is riding on
    /// it rather than making the user remember.
    @ViewBuilder private var surfaceSaveButtonOverlay: some View {
        if stage == .surface, viewerMesh != nil {
            Button { surfaceSave() } label: {
                VStack(spacing: 2) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: surfaceDirty
                              ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 15, weight: .bold))
                        Text("Save").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    }
                    // ★ THE SECOND LINE IS THE WARNING, not decoration. With edits
                    // pending it says what leaving would cost; with none it says
                    // there is nothing to lose.
                    Text(surfaceDirty ? "or leave and lose these edits"
                                      : "no changes yet")
                        .font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                        .lineLimit(1)
                }
                .foregroundStyle((surfaceDirty ? DS.Color.textPrimary
                                               : DS.Color.textDisabled).color)
                .padding(.horizontal, DS.Space.xl3)
                .frame(height: PageChrome.actionButton)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                        .fill(surfaceDirty ? DS.Color.accent.color
                                           : DS.Color.fillDisabled.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                            .strokeBorder((surfaceDirty ? DS.Color.accentDeepEdge
                                                        : DS.Color.strokeSubtle).color,
                                          lineWidth: 1.5)))
                .dsShadow(surfaceDirty ? DS.Shadow.accentDeepGlow : DS.Shadow.panel)
            }
            .buttonStyle(.plain)
            .disabled(!surfaceDirty)
            .accessibilityIdentifier("surface-save")
            .accessibilityLabel(surfaceDirty ? "Save surface edits"
                                             : "Save — nothing to save yet")
            // The slot the greyed-out "Lattice" button used to occupy.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, PageChrome.gizmoClearance)
            // ★ Aligned to the gizmo's VISIBLE top — see
            // `PageChrome.gizmoAlignedTop`.
            .padding(.top, PageChrome.gizmoAlignedTop)
        }
    }

    /// ★ THE LATTICE STAGE'S TOP-RIGHT CONTROL — and it now has that corner to
    /// itself. The settings wizard lives here, not on the TO page (§1a/§5).
    ///
    /// ★ This IS the slot the maintainer means by *"the same space where 'Lattice
    /// Settings' will be on the other page"*: the TO page puts "Lattice" here, the
    /// lattice page puts "Settings" here, and now that "Topology" has moved
    /// top-left under the project name there is exactly ONE button in this corner
    /// on either page.
    @ViewBuilder private var latticeSettingsButtonOverlay: some View {
        if stage == .lattice {
            Button { showLatticeWizard = true } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .bold))
                    Text("Settings").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.xl).frame(height: PageChrome.compactButton)
                // ★ §4(c) — NOT PURPLE. This was
                // `LatticeDensityProxy.densityColor(fraction: 0.75)` — a point on
                // the DENSITY RAMP used as chrome, which is where the purple came
                // from. It is the SAME `accentDeep` + `accentDeepEdge` pair the
                // stage button wears: all three NAVIGATE, none of them runs
                // anything.
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                        .fill(DS.Color.accentDeep.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                            .strokeBorder(DS.Color.accentDeepEdge.color,
                                          lineWidth: 1.5)))
                .dsShadow(DS.Shadow.accentDeepGlow)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lattice-settings")
            // ★ THE TOP-RIGHT SLOT, exactly where the TO page's "Lattice" button
            // sits: LEFT of the gizmo by `gizmoClearance`, top edge on the gizmo's
            // own inset. It moved UP into the space "Topology" vacated.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, PageChrome.gizmoClearance)
            // ★ Aligned to the gizmo's VISIBLE top — see
            // `PageChrome.gizmoAlignedTop`.
            .padding(.top, PageChrome.gizmoAlignedTop)
        }
    }

    /// The part's solid volume (mm³) for the proxy cost comparison — signed tetra sum
    /// over the viewer mesh (0 when no mesh).
    private var partSolidVolumeMM3: Double {
        guard let mesh = viewerMesh else { return 0 }
        let p = mesh.positions, idx = mesh.indices
        var vol = 0.0
        var t = 0
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3<Double>(Double(p[b]), Double(p[b + 1]), Double(p[b + 2]))
        }
        while t + 2 < idx.count {
            vol += simd_dot(v(idx[t]), simd_cross(v(idx[t + 1]), v(idx[t + 2]))) / 6
            t += 3
        }
        return abs(vol)
    }

    /// The settings chips (Gravity · Minimize plastic · quality · Design Box) stack BOTTOM-right,
    /// above the Optimize button (design-overhaul 109; round 2). Ordered SMALLEST width at the
    /// top → LARGEST at the bottom by their MEASURED width (item 12, `BottomChipOrder`), so the
    /// column reads as a tidy width ramp. The Design Box chip carries its own DRAWER, which opens
    /// BENEATH it (extending LEFT) when the tool is on (device round 3, item 11) — a taller row
    /// that pushes the chips above it up. Bottom-anchored and lifted to clear the Optimize button.
    private var bottomRightControls: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            Spacer()
            ForEach(BottomChipOrder.sorted(visibleSettingsChips, widths: settingsChipWidths), id: \.self) { id in
                settingsChipRow(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, PageChrome.edge)   // ★ the one right-hand line
        // ★ CLEAR THE BAR'S REAL HEIGHT, not a guess. This was
        // `DS.Space.xl4 + 50 + DS.Space.m` — a hardcoded 50 pt for Optimize. A
        // DISABLED Optimize carries a "what is missing" subtitle and is taller
        // than that, so the bar grew up into the Gravity chip and the two
        // overlapped. `bottomBarHeight` is measured, so the cluster cannot be
        // wrong at any size the bar becomes.
        .padding(.bottom, bottomBarClearance + DS.Space.m)
        .onPreferenceChange(SettingsChipWidthKey.self) { settingsChipWidths = $0 }
        .animation(DS.Motion.emphasized, value: bottomBarClearance)          // bar grew/shrank
        .animation(DS.Motion.emphasized, value: showDesignGizmo)   // drawer open/close + reflow
        .animation(DS.Motion.emphasized, value: paintActive)       // paint drawer open/close
    }

    /// One chip in the ordered cluster. Each chip measures its OWN width (`chipWidthReader`) so
    /// the sort is by the chip alone. The Design Box row is special: when the tool is on it
    /// becomes a trailing-aligned VStack whose chip sits ON TOP and the Design Box DRAWER opens
    /// BENEATH it (device round 3, item 11 — round 2 put it above; corrected). The drawer is
    /// wider than the chip and right-aligned, so it extends LEFT out from under the chip; its
    /// height grows the row and, because the cluster is bottom-anchored, pushes the chips ABOVE
    /// it up to make room. The drawer is NOT measured, so opening it never reshuffles the sort.
    @ViewBuilder private func settingsChipRow(_ id: SettingsChipID) -> some View {
        switch id {
        case .gravity: gravityChip.background(chipWidthReader(id))
        case .buildOrientation:
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                buildOrientationChip.background(chipWidthReader(id))
                if showBuildOrientation {
                    buildOrientationDrawer
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        case .minimizePlastic: minimizePlasticChip.background(chipWidthReader(id))
        case .quality: qualityChip.background(chipWidthReader(id))
        case .cadFaces: cadFacesChip.background(chipWidthReader(id))
        case .faceProtectDepth: faceProtectDepthChip.background(chipWidthReader(id))
        case .designBox:
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                designBoxChip.background(chipWidthReader(id))
                if showDesignGizmo {
                    designBoxDrawer
                        // Unfurl DOWNWARD from beneath the chip (slides in from the top edge).
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        case .paint:
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                paintChip.background(chipWidthReader(id))
                if paintActive {
                    paintDrawer
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    /// The settings chips actually shown: the Face-protection depth chip appears ONLY
    /// when at least one face is protected (handoff 124 — "the single global depth
    /// chip appears when ≥ 1 Face protection exists"); the rest are always present.
    private var visibleSettingsChips: [SettingsChipID] {
        SettingsChipID.allCases.filter { id in
            switch id {
            // The Face-protection depth chip appears only once ≥ 1 face is protected (124).
            case .faceProtectDepth: return force.explicitProtectCount(in: selection.groups) > 0
            // ★ §2b — A CONTROL FOR A HIDDEN PRIMITIVE IS A DEAD CONTROL. The
            // Design Box chip toggles the box's VISIBILITY and its drawer adds
            // keep-outs; on the lattice stage neither is drawn, so the chip would
            // appear to do nothing. Hidden with the primitive it controls, and —
            // like the primitive — not disarmed: the box still bounds the run.
            case .designBox: return visible.designBox
            // The Paint toggle needs a mesh to brush on, and it paints face
            // regions, which are the TO stage's business.
            case .paint: return viewerMesh != nil && visible.groupPrimitives
            // CAD-face projection has nothing to project ONTO unless the part
            // came from a STEP B-rep. On an STL/3MF import every face is a
            // manufactured pseudo-face (handoff 134) with no analytic surface
            // behind it, so core attributes nothing and the switch would be a
            // control over an operation that cannot run.
            case .cadFaces: return isStepPart
            default: return true
            }
        }
    }

    /// THE SECOND QUESTION as its own chip (handoff 2026-08-01-build-direction-
    /// separation). Deliberately adjacent to the gravity chip: "down in service" and
    /// "up on the plate" are DIFFERENT questions the pipeline used to answer with one
    /// number, and on the test part that assumption picked the worst of 26
    /// orientations. The chip states which way is up AND whether that was CHOSEN or
    /// merely assumed — a fallback the UI does not label is a fallback the user will
    /// mistake for a decision.
    private var buildOrientationChip: some View {
        Button {
            withAnimation(DS.Motion.emphasized) { showBuildOrientation.toggle() }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 12, weight: .bold))
                Text("Plate up \(BuildOrientation.label(project.buildOrientation.resolved(gravity: force.gravity)))")
                    .dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                if project.buildOrientation.isInferredFromGravity {
                    Text("assumed")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.vertical, 2).padding(.horizontal, 5)
                        .background(Capsule().fill(DS.Color.fillSubtle.color))
                }
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.panel.color))
        }
        .buttonStyle(.plain)
    }

    /// The panel itself: the two questions side by side, the six-axis picker, and the
    /// last run's RANKING with the recommendation marked. It never applies the
    /// recommendation — when the recommended orientation would gate differently from
    /// the one certified, the panel states BOTH verdicts and the user chooses.
    private var buildOrientationDrawer: some View {
        BuildOrientationView(
            orientation: Binding(get: { project.buildOrientation },
                                 set: { project.buildOrientation = $0 }),
            gravity: force.gravity,
            ranking: project.orientationRanking)
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(DS.Surface.panel.color))
    }

    /// The ONE global Face-protection depth chip (handoff 124), styled like the other
    /// settings chips. Tapping steps the shared preserve-depth through a few sensible
    /// values (mm); every Face protection in the project uses this single number.
    private var faceProtectDepthChip: some View {
        Button {
            let steps = [3.0, 5.0, 8.0, 12.0]
            let cur = force.faceProtectDepthMM
            let next = steps.first { $0 > cur + 0.01 } ?? steps.first!
            force.faceProtectDepthMM = Swift.min(
                FaceProtection.maxDepthMM, Swift.max(FaceProtection.minDepthMM, next))
            model.toast = "Protect depth \(Int(force.faceProtectDepthMM.rounded())) mm — applies to every protected face"
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 12, weight: .bold))
                Text("Protect \(Int(force.faceProtectDepthMM.rounded())) mm")
                    .dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
            }
            .foregroundStyle(Self.protectTint)
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.panel.color)
                .overlay(Capsule().strokeBorder(Self.protectTint.opacity(0.5), lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .dsShadow(DS.Shadow.panel)
        .help("The one preserve-depth every Face protection uses. Tap to change.")
    }

    // MARK: paint mode (handoff 2026-07-25)

    /// Paint-mode tint — a distinct violet so the brush toggle + drawer read as their own tool,
    /// apart from anchor-green / clearance-red / protect-teal.
    static let paintTint = Color(red: 0.64, green: 0.44, blue: 0.98)

    /// The Paint-mode toggle chip. OFF → tap to enter paint mode (a one-finger drag then brushes
    /// faces into the active group — the escape when tap-selection over-selects); ON → tap to leave.
    /// Styled like the other settings chips; brightens when active.
    private var paintChip: some View {
        Button {
            paintActive.toggle()
            if paintActive {
                paintErasing = false
                model.toast = "Paint mode — drag one finger to brush faces into the selection; two fingers orbit"
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: paintActive ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(paintActive ? DS.Color.textPrimary.color : Self.paintTint)
                Text("Paint").dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(paintActive ? Self.paintTint : DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(paintActive ? Color.clear : DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .dsShadow(DS.Shadow.panel)
        .help("Brush faces into the active group when a tap over-selects. One finger paints; two fingers orbit.")
    }

    /// The paint controls that unfurl beneath the chip when paint mode is on: the ERASE modifier
    /// (revert triangles to their native face) and a brush-size stepper, plus a one-line reminder
    /// of the gesture. Kept small and right-aligned like the design-box drawer.
    private var paintDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button { paintErasing.toggle() } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: paintErasing ? "eraser.fill" : "eraser")
                        .font(.system(size: 12, weight: .bold))
                    Text(paintErasing ? "Erasing" : "Erase")
                        .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(paintErasing ? DS.Color.textPrimary.color : DS.Color.textSecondary.color)
                .padding(.vertical, 8).padding(.horizontal, DS.Space.m)
                .background(Capsule().fill(paintErasing ? Self.paintTint.opacity(0.9)
                                                        : DS.Color.fillSubtle.color))
            }
            .buttonStyle(.plain)

            HStack(spacing: DS.Space.s) {
                Text("Brush").dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textSecondary.color)
                Button { brushRadiusPoints = Swift.max(12, brushRadiusPoints - 6) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 16))
                }.buttonStyle(.plain)
                Text("\(Int(brushRadiusPoints))").dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color).frame(minWidth: 22)
                Button { brushRadiusPoints = Swift.min(64, brushRadiusPoints + 6) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 16))
                }.buttonStyle(.plain)
            }
            .foregroundStyle(Self.paintTint)

            Text("Drag one finger to paint into the selection; two fingers orbit. Then pick Anchor or Load.")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(Self.paintTint.opacity(0.5), lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    /// Reads a chip's rendered width into `SettingsChipWidthKey` (item 12: MEASURED width).
    private func chipWidthReader(_ id: SettingsChipID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SettingsChipWidthKey.self, value: [id: proxy.size.width])
        }
    }

    /// Resolution / quality picker chip (Fast 64³ / Balanced 96³ / Fine 128³).
    private var qualityChip: some View {
        Menu {
            ForEach(RunQuality.allCases, id: \.self) { q in
                Button { project.quality = q } label: { Text("\(q.title) · \(q.detail)") }
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
                Text("\(project.quality.title) · \(project.quality.resolution)³")
                    .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            .foregroundStyle(DS.Color.textPrimary.color)
        }
    }

    /// True when the part came from a STEP/STP B-rep, which is the only source
    /// that carries the analytic surfaces CAD-face projection puts vertices back
    /// onto. Matches `RunRequest.isStepModel`'s test on the same path.
    private var isStepPart: Bool {
        guard let p = project.importedFile?.path.lowercased() else { return false }
        return p.hasSuffix(".step") || p.hasSuffix(".stp")
    }

    /// ★ CAD-FACE PROJECTION — the OFF control (task
    /// 2026-08-06-arm-projection-and-void-check, S1c).
    ///
    /// A Menu rather than a plain toggle, for one reason: the copy has to say
    /// WHAT IT DOES, and a switch has nowhere to say it. Both choices are
    /// spelled out, so turning it off is a decision rather than a guess about
    /// what the label meant.
    ///
    /// It is ON by default — the maintainer armed it — and the chip states
    /// which state it is in rather than only the setting's name, the same rule
    /// `minimizePlasticChip` follows.
    private var cadFacesChip: some View {
        // ★ A CHIP THAT OPENS A DRAWER, NOT A MENU (maintainer, 2026-08-17:
        // "can you make it so when you click on it, a on/off glass slider is
        // made visible in a drawer? ... Please make a little blurb about what it
        // does and its benefit/detriment, too").
        //
        // ★ WHY THIS BEATS DELETING IT. The chip looked like a view toggle, but
        // `projectCADFaces` is an EXPORT setting: it is saved with the project,
        // travels to core as `output.project_cad_faces`, and decides whether the
        // exported mesh is snapped back onto the CAD geometry or shipped as the
        // voxel approximation. Removing the chip would have left a live setting
        // stuck on with no way to reach it. A drawer that SAYS what the switch
        // does — and what it costs — turns a mystery label into a decision.
        //
        // The two-line menu it replaces stated the options but never the
        // TRADE-OFF, which is the only part a user cannot infer.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.emphasized) { cadFacesDrawerOpen.toggle() }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: project.projectCADFaces
                            ? "ruler.fill" : "square.grid.3x3.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((project.projectCADFaces
                                            ? DS.Color.accent
                                            : DS.Color.textTertiary).color)
                    Text(project.projectCADFaces ? "CAD surfaces" : "Voxel surfaces")
                        .dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
                    Image(systemName: cadFacesDrawerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color)
                    .overlay(Capsule().strokeBorder(
                        DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
                .foregroundStyle(DS.Color.textPrimary.color)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cad-faces-chip")

            if cadFacesDrawerOpen { cadFacesDrawer }
        }
    }

    /// ★ THE DRAWER: the switch, and the honest sentence on each side of it.
    private var cadFacesDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Restore CAD surfaces")
                    .dsStyle(DS.TypeScale.subhead).fontWeight(.semibold)
                Spacer(minLength: DS.Space.s)
                Toggle("", isOn: $project.projectCADFaces)
                    .labelsHidden()
                    .tint(DS.Color.accent.color)
                    .accessibilityIdentifier("cad-faces-toggle")
            }
            // ★ WHAT IT DOES — the same sentence either way, because the
            // mechanism does not change with the switch.
            Text(Self.cadFacesWhat)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            // ★ AND WHAT IT COSTS, on the side you are actually on. Benefit AND
            // detriment, which the menu never stated.
            Text(project.projectCADFaces ? Self.cadFacesOnNote : Self.cadFacesOffNote)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle((project.projectCADFaces
                                    ? DS.Color.textQuaternary
                                    : DS.Color.warning).color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .padding(.top, DS.Space.xs)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityIdentifier("cad-faces-drawer")
    }

    /// ★ THE BLURB, as constants so the wording is testable and cannot drift
    /// between the drawer and anything that quotes it.
    ///
    /// WHAT IT DOES — the optimiser works on a grid of cubes, so its result is
    /// blocky: round holes come out faceted and flat walls stair-stepped.
    /// Projection snaps the exported surface back onto the geometry you drew.
    static let cadFacesWhat =
        "The optimiser works on a grid of cubes, so its result is slightly "
        + "blocky — round holes come out faceted, flat walls stair-stepped. "
        + "This snaps the exported surface back onto the shapes you actually "
        + "drew."

    /// ON — the benefit, and the one real risk. `projection-weld-guard-float32`
    /// measured projection closing a gap it should not have; the guard exists,
    /// and the user is told the direction of the danger rather than reassured.
    static let cadFacesOnNote =
        "ON — holes stay round and walls stay flat, so the part fits its "
        + "mating hardware. On very thin features projection can pull two "
        + "surfaces together and close a gap that should stay open; the run "
        + "checks for that and says so."

    /// OFF — what you get instead, and why you might want it.
    static let cadFacesOffNote =
        "OFF — you get the raw voxel shape: visibly stair-stepped, and holes "
        + "that may not pass a gauge. Useful when you want to see exactly what "
        + "the optimiser produced, with nothing moved."


    private var gravityChip: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Color.accent.color)
            Text("Gravity set").dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
            // Show WHICH way is down without opening anything — the snapped axis (or
            // "custom"). One inline tag, so the chip stays a single row (BAR V5).
            Text(gravityDirectionLabel)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(Capsule().fill(DS.Color.fillSubtle.color))
                .fixedSize()
            Button {
                force.enterGravitySetup()
                selection.clearActive()
                // Seed the pointing arrow from the CURRENT gravity (draft nil → falls back to
                // it) and clear any stale snap badge, so re-opening setup shows what is set.
                gravityDraft = nil
                gravitySnapLabel = nil
            } label: {
                Text("Change").dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                    .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
                    .background(Capsule().fill(DS.Color.fillSubtle.color))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.textPrimary.color)
        }
        .padding(.vertical, 9).padding(.leading, DS.Space.l).padding(.trailing, 9)
        .background(Capsule().fill(DS.Surface.bar.color)
            .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    /// The "Minimize plastic" toggle chip. ON → the REDUCTION ladder (remove as much
    /// plastic as possible while holding the margin). OFF → the GROWTH ladder (add as
    /// little as possible to reach it) — task 2026-08-03-growth-ladder. The chip
    /// shows the MODE it is currently in, not just the setting's name, because off
    /// is a mode of its own now and not the absence of one.
    private var minimizePlasticChip: some View {
        let mode = LadderMode.of(minimizePlastic: project.minimizePlastic)
        return Button { project.minimizePlastic.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: project.minimizePlastic ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle((project.minimizePlastic ? DS.Color.accent : DS.Color.textTertiary).color)
                Text(mode.title).dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            .foregroundStyle(DS.Color.textPrimary.color)
        }
        .buttonStyle(.plain)
    }

    // MARK: design box tool (M7.dom-app) — define grow room + keep-outs

    /// Whether the design-box gizmo (translucent box + drag handles) is shown: the
    /// tool is active and we're in the normal edit phase (not gravity setup).
    private var showDesignGizmo: Bool {
        force.phase == .edit && force.gravityIsSet && project.designBox.isActive
    }

    /// The design-box tool toggle chip. Off → tap to open (seeds a grow-room box
    /// around the part). On → tap to close (reverts to the default no-box run).
    private var designBoxChip: some View {
        Button {
            if project.designBox.isActive {
                project.designBox.disable()
            } else if let mesh = viewerMesh {
                project.designBox.enable(around: mesh.bounds)
                model.toast = "Design box on — drag the handles to size the space the optimizer can grow into"
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: project.designBox.isActive ? "cube.fill" : "cube")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((project.designBox.isActive ? DS.Color.accentGreen : DS.Color.textTertiary).color)
                Text("Design Box").dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            .foregroundStyle(DS.Color.textPrimary.color)
        }
        .buttonStyle(.plain)
    }

    /// The design-box control DRAWER (design-overhaul round 2, item 11): a short explainer,
    /// Reset (back to the default grow-room box), Add keep-out, and per-keep-out remove. It
    /// slides out LEFTWARD from the Design Box chip in the bottom-right cluster (the placement +
    /// slide transition live in `settingsChipRow`); this is just the card content. The sizing
    /// itself is the on-scene drag handles.
    private var designBoxDrawer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "cube.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accentGreen.color)
                Text("Design Box").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            // Long-press the header to toggle the drag diagnostic HUD (handoff 111):
            // if the box drag ever misbehaves again, the maintainer's screenshot then
            // carries the chosen handle / owner / delta.
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 1.2) {
                boxDragDebug.toggle()
                model.toast = boxDragDebug ? "Box-drag diagnostics ON" : "Box-drag diagnostics off"
            }
            Text("Drag the green handles to size the space the optimizer may grow material into — it can extend past the part.")
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button {
                    if let mesh = viewerMesh { project.designBox.reset(around: mesh.bounds) }
                } label: { designBoxPanelButton("arrow.counterclockwise", "Reset") }
                    .buttonStyle(.plain)
                Button {
                    if let mesh = viewerMesh {
                        project.designBox.addKeepOut(around: mesh.bounds)
                        model.toast = "Keep-out added — the optimizer must leave this region empty"
                    }
                } label: { designBoxPanelButton("nosign", "Add keep-out") }
                    .buttonStyle(.plain)
            }
            if !project.designBox.keepOuts.isEmpty {
                Divider().overlay(DS.Color.strokeSubtle.color)
                ForEach(Array(project.designBox.keepOuts.enumerated()), id: \.offset) { idx, _ in
                    HStack(spacing: DS.Space.s) {
                        Circle().fill(Color(red: 0.95, green: 0.42, blue: 0.38)).frame(width: 8, height: 8)
                        Text("Keep-out \(idx + 1)").dsStyle(DS.TypeScale.footnote)
                            .foregroundStyle(DS.Color.textSecondary.color)
                        Spacer(minLength: DS.Space.l)
                        Button { project.designBox.removeKeepOut(at: idx) } label: {
                            Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(DS.Space.l)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private func designBoxPanelButton(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
        }
        .foregroundStyle(DS.Color.textPrimary.color)
        .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
        .background(Capsule().fill(DS.Color.fillSubtle.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }

    // MARK: design box on-scene handles (resize + move)

    private static let designGreen = Color(red: 0.30, green: 0.78, blue: 0.55)
    private static let keepOutRed = Color(red: 0.95, green: 0.42, blue: 0.38)
    /// Liquid-glass tints for the on-scene handles (design-overhaul 109): the design box keeps
    /// its green identity, keep-outs the forbidden-space red — both as the shared glass.
    private static let designGlass = LiquidGlass.Tint.frost(RGBA(0.30 * 255, 0.78 * 255, 0.55 * 255), intensity: 0.6)
    private static let keepOutGlass = LiquidGlass.Tint.red

    /// A model-space axis' settled world direction (unit), for the drag-projection math.
    private func settledAxis(_ axis: Int) -> SIMD3<Float> {
        var a = SIMD3<Float>(0, 0, 0); a[axis] = 1
        return simd_normalize(settleQuat.act(a))
    }

    /// The screen position of a box face-centre handle, or nil if it can't project.
    private func faceHandleScreen(_ box: DesignBoxBounds, axis: Int, isMax: Bool,
                                  proj: CameraProjection) -> CGPoint? {
        proj.project(settledWorld(box.faceCenter(axis: axis, isMax: isMax)))
    }

    /// The probe step (mm) the drag math uses to measure an axis' on-screen scale.
    private var handleProbe: Float { Swift.max(viewerMesh?.bounds.radius ?? 1, 1e-3) * 0.1 }

    /// handoff 111 — the SINGLE-GESTURE design-box gizmo. Every box + keep-out handle
    /// used to carry its OWN `DragGesture`; overlapping ~44 pt targets let one touch
    /// drive two gestures (the "ghost duplicate boxes") and each gesture measured
    /// `.translation` in its handle's LOCAL space, which shifts as the box moves under
    /// the finger (the teleport). Now:
    ///   * the VISIBLE handles are pure chrome (`.allowsHitTesting(false)`), and
    ///   * ONE `DragGesture` on the hit layer, in ONE named stage space, hit-tests the
    ///     touch-down point ONCE to pick exactly one handle (`DesignBoxHitTest`).
    /// Overlapping handles are impossible by construction, and all math reads the touch
    /// in the stable stage space (`boxStageSpace`), so a repositioning handle can't
    /// corrupt the delta. `DesignBoxDragSession` stays as the write guard beneath.
    private static let boxStageSpace = "designBoxStage"
    /// Grab radius (points) for the touch-down hit-test — a touch this far from a
    /// handle centre still selects it (matches the ~44 pt visual target).
    private static let boxHandleGrabRadius: CGFloat = 30

    private var designGizmoOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let proj = projection, project.designBox.box != nil {
                boxHandleVisuals(proj)
                    .allowsHitTesting(false)                 // chrome only — the hit layer owns touches
                boxHitLayer(resolvedBoxCandidates(proj))
                if boxDragDebug, let d = boxDragDiag { boxDragDiagnosticHUD(d) }
            }
        }
        // Fill the stage so the named space shares the top-left origin the camera
        // projection uses, and the ONE gesture reads the touch in that stable frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.boxStageSpace)
    }

    /// The visible handles — a centre move dot + six face squares for the design box, and the
    /// same per keep-out. Keep-out pass owns placement (handoff 2026-07-27): each is drawn at
    /// its RESOLVED position so a handle floats clear of the gizmo/pills. Visual + hit layers
    /// both iterate the SAME `boxCandidates` list and read `boxHandleScreen(i)`, so they can't
    /// desync. Pure chrome; the hit layer below owns all touches.
    @ViewBuilder private func boxHandleVisuals(_ proj: CameraProjection) -> some View {
        let targets = boxCandidates(proj)
        let placed = keepOutResolved(proj)
        ForEach(targets.indices, id: \.self) { i in
            let t = targets[i]
            let pos = placed[boxHandleID(i)]?.center ?? t.screen
            let keepOutTint: Bool = { if case .keepOut = t.handle.target { return true } else { return false } }()
            let tint = keepOutTint ? Self.keepOutGlass : Self.designGlass
            if case .move = t.handle.kind {
                moveHandle(tint: tint).position(pos)
            } else {
                resizeHandle(tint: tint).position(pos)
            }
        }
    }

    /// The canonical hit-test candidates (design box, then each keep-out) projected to
    /// stage points — the input to `DesignBoxHitTest.choose`.
    private func boxCandidates(_ proj: CameraProjection) -> [DesignBoxHitTest.Target] {
        DesignBoxHandles.candidates(box: project.designBox.box, keepOuts: project.designBox.keepOuts,
                                    settledWorld: settledWorld, project: proj.project)
    }

    /// `boxCandidates` with each handle moved to its RESOLVED keep-out position — the hit set the
    /// drag chooses among, so a touch on a displaced handle picks that handle (visual + hit agree).
    private func resolvedBoxCandidates(_ proj: CameraProjection) -> [DesignBoxHitTest.Target] {
        let placed = keepOutResolved(proj)
        return boxCandidates(proj).enumerated().map { i, t in
            DesignBoxHitTest.Target(handle: t.handle, screen: placed[boxHandleID(i)]?.center ?? t.screen)
        }
    }

    /// The ONE interactive layer: a transparent grab circle per handle, offset into
    /// place, with the single drag gesture attached to the container. Because the
    /// container has no fill/`contentShape`, only the grab circles are hittable — a
    /// touch on empty space still falls through to the camera (orbit/zoom keep working
    /// while the gizmo is up). `.offset` (not `.position`) keeps each grab area SMALL,
    /// so the container's hit region is exactly the union of the circles.
    private func boxHitLayer(_ targets: [DesignBoxHitTest.Target]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(targets.indices, id: \.self) { i in
                Color.clear
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .offset(x: targets[i].screen.x - 22, y: targets[i].screen.y - 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .gesture(designBoxDrag())
    }

    /// The diagnostic HUD (debug-toggleable) — chosen handle, current owner, and the
    /// base→current delta in points and mm. The maintainer flips it on with a long-
    /// press on the panel header; a screenshot then carries the diagnosis.
    private func boxDragDiagnosticHUD(_ d: BoxDragDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("box drag · debug").foregroundStyle(DS.Color.accentGreen.color)
            Text("handle: \(Self.handleLabel(d.handle))")
            Text("owner:  \(d.owner.map(Self.handleLabel) ?? "—")")
            Text(String(format: "Δ pts:  %.0f, %.0f", d.deltaPoints.width, d.deltaPoints.height))
            Text(String(format: "Δ mm:   %.2f", d.deltaMM))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.72)))
        .position(x: 150, y: 150)
        .allowsHitTesting(false)
    }

    /// A short label for a handle in the diagnostic HUD, e.g. "box/x+", "ko0/move".
    private static func handleLabel(_ h: DesignBoxDragSession.HandleID) -> String {
        let t: String
        switch h.target {
        case .designBox: t = "box"
        case .keepOut(let i): t = "ko\(i)"
        }
        switch h.kind {
        case .move: return "\(t)/move"
        case .face(let axis, let isMax): return "\(t)/\(["x", "y", "z"][axis])\(isMax ? "+" : "-")"
        }
    }

    /// A face-resize handle: a small LIQUID-GLASS square (draggable along its axis).
    private func resizeHandle(tint: LiquidGlass.Tint) -> some View {
        Color.clear
            .frame(width: 22, height: 22)
            .liquidGlass(tint, cornerRadius: 7)
            .shadow(color: tint.accent(0.45), radius: 4)
            .contentShape(Rectangle().inset(by: -12))
    }

    /// A centre move handle: a LIQUID-GLASS dot with the move glyph (slides the whole box).
    private func moveHandle(tint: LiquidGlass.Tint) -> some View {
        Image(systemName: "move.3d").font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .liquidGlass(tint, in: Circle())
            .shadow(color: tint.accent(0.45), radius: 4)
            .contentShape(Circle())
    }

    // The model-space delta (mm) a drag represents along one axis (settled).
    private func axisDelta(fromWorld world: SIMD3<Float>, axis: Int, drag: CGSize,
                           proj: CameraProjection) -> Float {
        DesignBoxDrag.axisDelta(handleWorld: world, worldAxis: settledAxis(axis),
                                drag: CGVector(dx: drag.width, dy: drag.height),
                                projection: proj, probe: handleProbe)
    }

    /// The ONE design-box drag gesture (handoff 111). On the first frame it hit-tests
    /// the touch-down point to choose exactly one handle, then holds that choice for
    /// the whole drag; every later frame applies an ABSOLUTE delta from the drag-start
    /// snapshot the session captured. Reads the touch in the stable `boxStageSpace`, so
    /// the box repositioning under the finger can't skew the delta (no teleport), and
    /// there is only ever one gesture, so overlapping handles can't fight (no ghosts).
    private func designBoxDrag() -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.boxStageSpace))
            .onChanged { v in
                guard let proj = projection, let mesh = viewerMesh else { return }
                // Choose the handle ONCE: reuse the live owner if the drag is already
                // claimed, else hit-test the touch-DOWN point. No handle → fall through.
                let chosen: DesignBoxDragSession.HandleID
                if let owner = boxDrag.activeOwner {
                    chosen = owner
                } else if let hit = DesignBoxHitTest.choose(at: v.startLocation,
                                                            among: resolvedBoxCandidates(proj),
                                                            radius: Self.boxHandleGrabRadius) {
                    chosen = hit
                } else {
                    return
                }
                // Claim/continue the drag; the session hands back the drag-start base
                // (and rejects any stray second claim — defence in depth beneath the
                // single gesture).
                guard let current = boxBounds(for: chosen),
                      let base = boxDrag.begin(chosen, current: current) else { return }
                let result = applyBoxDrag(chosen, base: base, drag: v.translation, proj: proj, mesh: mesh)
                writeBox(chosen, result.bounds)
                if boxDragDebug {
                    boxDragDiag = BoxDragDiagnostic(handle: chosen, owner: boxDrag.activeOwner,
                                                    deltaPoints: v.translation, deltaMM: result.mm)
                }
            }
            .onEnded { _ in
                if let owner = boxDrag.activeOwner { boxDrag.end(owner) }
                boxDragDiag = nil
                boxFaceDetent = nil          // release the magnetic detent (item 10)
            }
    }

    /// The current model bounds a handle edits (the design box, or a keep-out by index).
    private func boxBounds(for handle: DesignBoxDragSession.HandleID) -> DesignBoxBounds? {
        switch handle.target {
        case .designBox: return project.designBox.box
        case .keepOut(let i):
            return project.designBox.keepOuts.indices.contains(i) ? project.designBox.keepOuts[i] : nil
        }
    }

    /// Write a handle's new bounds back to the model (index-checked for keep-outs).
    private func writeBox(_ handle: DesignBoxDragSession.HandleID, _ bounds: DesignBoxBounds) {
        switch handle.target {
        case .designBox: project.designBox.box = bounds
        case .keepOut(let i):
            guard project.designBox.keepOuts.indices.contains(i) else { return }
            project.designBox.keepOuts[i] = bounds
        }
    }

    /// Apply a stage-space drag translation to a handle's base bounds, returning the
    /// new bounds and the model-space (mm) delta (for the diagnostic HUD). Move handles
    /// slide in the ground plane (model X + Z); face handles resize along their axis.
    private func applyBoxDrag(_ handle: DesignBoxDragSession.HandleID, base: DesignBoxBounds,
                              drag: CGSize, proj: CameraProjection, mesh: ViewerMesh)
        -> (bounds: DesignBoxBounds, mm: Float) {
        switch handle.kind {
        case .move:
            let world = settledWorld(base.center)
            let dx = axisDelta(fromWorld: world, axis: 0, drag: drag, proj: proj)
            let dz = axisDelta(fromWorld: world, axis: 2, drag: drag, proj: proj)
            return (base.translated(by: SIMD3<Float>(dx, 0, dz)), (dx * dx + dz * dz).squareRoot())
        case .face(let axis, let isMax):
            let world = settledWorld(base.faceCenter(axis: axis, isMax: isMax))
            let delta = axisDelta(fromWorld: world, axis: axis, drag: drag, proj: proj)
            let rawTarget = (isMax ? base.max[axis] : base.min[axis]) + delta
            // Magnetic face detent (item 10 / round-4 item 5): the WHOLE snap pipeline (candidates
            // → hysteresis resolve → movingFace → matched face) runs in `applyFaceDrag`, the exact
            // function the integration test drives — so the wiring can't silently go dead.
            let r = DesignBoxDetent.applyFaceDrag(
                axis: axis, isMax: isMax, base: base, rawTarget: rawTarget,
                faces: mesh.faceGeometry, aabbMin: mesh.bounds.min, aabbMax: mesh.bounds.max,
                current: boxFaceDetent, minSize: DesignBoxModel.minSize(for: mesh.bounds))
            boxFaceDetent = r.detent
            if r.didSnap {
                // A fresh detent: PULSE the matched part face in the viewer + tick the haptic (item 2,
                // replacing the toast). `matchedFace` is nil for a bare AABB-extent snap → only haptic.
                flashDesignBoxDetent(r.matchedFace)
                ClearanceHaptics.detent()
            }
            let mm = (isMax ? r.bounds.max[axis] - base.max[axis] : r.bounds.min[axis] - base.min[axis])
            return (r.bounds, abs(mm))
        }
    }

    /// The brief highlight PULSE of the snapped part face in the Metal viewer (device round 3,
    /// item 2 — the finished in-viewer feedback that replaces the old "Snapped to face" toast).
    /// Advances the pulse token so the coordinator flashes even when the same face is re-snapped;
    /// a nil `face` (an AABB-extent snap with no part face) leaves the pulse untouched.
    private func flashDesignBoxDetent(_ face: FaceID?) {
        guard let face else { return }
        let token = (detentPulse?.token ?? 0) + 1
        detentPulse = DetentPulse(faceID: face, token: token)
    }

    // MARK: keep-clear Phase B — draggable clearance handles + floating value pill

    /// The named coordinate space the handle drags read their touch LOCATION in — the
    /// full-stage space the camera projection also lives in, so `projection.ray` builds
    /// the right camera ray. (The design-box handles get by with `.translation`, which
    /// is space-invariant; a ray needs the absolute point, hence a named space.)
    private static let clearanceStageSpace = "clearanceStage"

    /// One flattened clearance handle for the overlay: a stable id, the owning group,
    /// and the pure handle (model space).
    private struct ClearanceHandleItem: Identifiable {
        let id: String
        let groupID: UUID
        let faceID: FaceID
        let handle: ClearanceHandle
    }

    /// Every clearance handle to draw, flattened across groups/faces. Degenerate
    /// volumes contribute none (ProjectModel already dropped them).
    private var clearanceHandleItems: [ClearanceHandleItem] {
        guard force.gravityIsSet else { return [] }
        var items: [ClearanceHandleItem] = []
        for entry in project.clearanceHandles() {
            for h in entry.handles {
                items.append(ClearanceHandleItem(
                    id: "\(entry.groupID.uuidString):\(entry.faceID):\(h.role)",
                    groupID: entry.groupID, faceID: FaceID(entry.faceID), handle: h))
            }
        }
        return items
    }

    /// The kind (bore vs plane) a handle role's chip belongs to, for the sync collapse.
    private static func chipKind(_ role: ClearanceHandle.Role) -> ClearanceChipKind {
        role == .slabDepth ? .plane : .bore
    }

    /// The on-model value chips AFTER the sync collapse (Task A6 item 1): a synced group keeps
    /// only its representative primitive's chips (first bore, first plane, in selection order);
    /// an unsynced group keeps every primitive's chips. The knobs draw from the uncollapsed
    /// `clearanceHandleItems`, so every wall/cap/face stays draggable regardless.
    private var syncCollapsedChipItems: [ClearanceHandleItem] {
        ClearanceChipLayout.collapseSynced(
            clearanceHandleItems,
            group: { $0.groupID }, face: { $0.faceID },
            kind: { Self.chipKind($0.handle.role) },
            isSynced: { force.isClearanceSynced($0) })
    }

    /// The draggable clearance handles + the floating glass value pill for the active
    /// clearance selection. Each handle binds its gesture to the SIZED knob BEFORE
    /// `.position` (same rule as the design-box gizmo): a gesture applied after
    /// `.position` fills the stage and swallows the orbit camera. So a touch on a knob
    /// owns the drag; anywhere else orbits as today.
    private var clearanceHandlesOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let proj = projection {
                let placed = keepOutResolved(proj)
                ForEach(clearanceHandleItems) { item in
                    if let raw = proj.project(settledWorld(item.handle.anchor)) {
                        // The knob slid around its cylinder locus to clear the gizmo (keep-out pass);
                        // the drag reads the finger ray, so sliding it stays exact. Fallback to the
                        // raw projection before the first resolve.
                        let knob = placed[clrKnobID(item)]?.center ?? raw
                        clearanceHandleKnob(role: item.handle.role, active: draggingHandleID == item.id)
                            .gesture(clearanceHandleDrag(item))
                            .position(knob)
                            .animation(DS.Motion.emphasized, value: knob)
                    }
                }
                clearanceValuePill(proj, placed)
            }
        }
        // Fill the stage so the named coordinate space (and the `.position` anchors)
        // share the origin the camera projection uses (top-left of the full stage).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.clearanceStageSpace)
    }



    // MARK: ★ §6 — THE SURFACE STAGE'S COLOUR AND ITS SELECTION

    /// Every face the Topology page put in a group — the faces this stage may act
    /// on, and therefore the ones it tints.
    /// ★ EVERY FACE OF THE PART — this stage acts on all of them.
    ///
    /// The name is now historical: it once meant "the faces the Topology page
    /// grouped", which was also the permission. The permission is gone; what a face
    /// belongs to is carried by `surfaceGroupHues` and shown as a hint of colour.
    private var surfaceGroupedFaces: Set<FaceID> {
        guard let mesh = viewerMesh else { return [] }
        return Set(0..<Int32(mesh.faceGeometry.count))
    }

    /// ★ THE ONE BLUE, PER VERTEX. Per VERTEX and not per face because a cut does
    /// not create a face: both halves keep the same id, and a `[FaceID: colour]`
    /// map cannot tell them apart no matter what colour it holds.
    private var surfaceVertexTints: [Float] {
        guard let mesh = viewerMesh else { return [] }
        return SurfaceTint.buffer(mesh: mesh, groupedFaces: surfaceGroupedFaces,
                                  regions: project.faceRegions,
                                  selected: surfaceSelected,
                                  // Whole-face picks are coloured directly…
                                  // The matches light exactly as tapped faces do —
                                  // they are whole faces, so no fragment test.
                                  picked: surfaceTool == .similar
                                      ? similarMatches
                                      : (surfaceTool == .union
                                         ? surfaceUnion.wholeFacePicks(
                                             regions: project.faceRegions, mesh: mesh)
                                         : surfaceSelectedFace.map { [$0] } ?? []),
                                  // …and only the PARTS are handed to the shader.
                                  // Every other tool tests the SELECTED region's
                                  // faces, which is where its one cut plane applies.
                                  fragmentTested: surfaceTool == .union
                                      ? surfaceUnionPickedFaces
                                      : surfaceSelectedTestedFaces,
                                  groupColours: surfaceGroupHues)
    }

    /// ★ WHICH WAY THE PLANE'S NORMAL POINTS ON SCREEN: +1 when it runs to the
    /// right, −1 when it runs to the left. The move drag multiplies by this, so a
    /// rightward drag always moves the cut rightward however the part is turned.
    private var cutMoveSign: Double {
        guard let held = heldCut, let proj = projection else { return 1 }
        let cut = held.rotated(by: SurfaceCut.snap(cutRotation))
        let a = settledWorld(SIMD3<Float>(cut.point))
        let b = settledWorld(SIMD3<Float>(cut.point + cut.normal * cutMoveScale * 40))
        guard let pa = proj.project(a), let pb = proj.project(b) else { return 1 }
        return (pb.x - pa.x) >= 0 ? 1 : -1
    }

    /// mm per point of drag on the move knob — the piece's own size, so the knob
    /// crosses it in about a screen's worth of travel on any part.
    private var cutMoveScale: Double {
        guard let m = viewerMesh else { return 0.1 }
        return Double(m.bounds.radius) / 260
    }

    /// ★ THE CUT BOUNDARIES, AS REAL LINES — every committed cut, plus the grid a
    /// pattern WOULD make while it is being aimed. Drawn with the wireframe, so a
    /// divided face reads as two pieces with an edge between them at any
    /// tessellation, and the pattern can be seen before it is committed.
    private var surfaceCutLineBuffer: [Float] {
        // ★ ON EVERY STAGE THAT DRAWS THE WIREFRAME, NOT JUST THIS ONE. A cut is a
        // real boundary of the surface once it is made, so it belongs to the edge
        // set wherever that edge set is shown — which is how the Topology page now
        // shows what the Surface stage did to it (maintainer: "The wireframe
        // doesn't reflect the unions or cuts I made. This needs to be updated
        // live").
        guard visible.wireframe, surfaceWireframeOn, let mesh = viewerMesh
        else { return [] }
        return SurfaceCutLines.committed(regions: project.faceRegions, in: mesh)
    }

    /// ★ THE GRID A PATTERN *WOULD* MAKE — the only thing on screen that has not
    /// happened yet, so the only thing drawn in the accent colour.
    /// ★ NOT GATED ON THE WIREFRAME TOGGLE. The wireframe is a VIEW; this is the
    /// thing being decided right now. With the toggle off by default, gating the
    /// preview on it would leave the pattern tool aiming at a grid nobody can see —
    /// the toggle would silently be a prerequisite for a tool.
    private var surfacePreviewLineBuffer: [Float] {
        guard visible.surfaceEditing, surfaceTool == .pattern,
              let mesh = viewerMesh, let f = surfacePatternFace,
              let p = surfacePatternPreview else { return [] }
        // ★ CLIPPED TO THE SELECTED PIECE. Without this the grid is traced across
        // the whole FACE — including the sibling half of a cut, which is not what
        // is being patterned. The SAME piece the cells were measured within:
        // reading a different one here is how the count and the drawing came to
        // disagree.
        return SurfaceCutLines.preview(
            cells: p.cells, face: f, in: mesh,
            within: surfacePatternPiece
                .flatMap { project.faceRegions.region($0)?.cuts } ?? [])
    }

    // ★ `surfaceCutRibbon` DELETED (2026-08-16). It built two triangles per
    // segment, widened in the plane of a single face normal — which is correct on
    // a flat face and degenerate on a curved one: wherever the segment ran
    // parallel to that normal the in-plane perpendicular collapsed and the ribbon
    // vanished. On the maintainer's curved face a full divider line rendered as
    // two or three stray ticks. The wide-line pipeline (`wideline_vertex`) expands
    // every segment in SCREEN space, where there is no such direction, so the cut
    // traces now ride the wireframe and this layer had nothing left to do.

    /// The faces the single-plane cut test applies to: the selected region's own,
    /// and only when it IS a cut (a whole region has no plane to test).
    private var surfaceSelectedTestedFaces: Set<FaceID> {
        guard let id = surfaceSelected,
              project.faceRegions.region(id)?.isCut == true else { return [] }
        return Set(project.latticeRegionMemberFaces(id))
    }

    /// ★ EACH GROUPED FACE'S OWN GROUP COLOUR, for the Surface stage's muted hue.
    /// Read from `force.tint(for:)` — the SAME source the TO page paints with, so a
    /// group cannot read red on one page and orange on the other.
    private var surfaceGroupHues: [FaceID: SIMD3<Float>] {
        var out: [FaceID: SIMD3<Float>] = [:]
        for g in selection.groups {
            let c = force.tint(for: g)
            let v = SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b))
            for f in g.faces { out[f] = v }
        }
        return out
    }

    /// §6(c) — the faces the derived rule currently matches. Recomputed rather
    /// than stored: the RULE is the membership, and a cached id list is exactly
    /// the drift PR 331 measured (a 24-face union grew to 32 after a CAD edit).
    private var similarMatches: Set<FaceID> {
        guard let mesh = viewerMesh else { return [] }
        return similar.matches(in: mesh)
    }

    /// ★ THE TOPOLOGY PAGE'S TAP ON A DIVIDED FACE (maintainer, 2026-08-15: "I want
    /// to be able to go *back* to the TO page and deselect any face that I have cut
    /// up as its own piece, removing it from the Group. I would also like to be able
    /// to add it to another Group — these faces need to be selectable afterwards").
    ///
    /// Returns true when it handled the tap. A face with no pieces returns false and
    /// the ordinary face route runs, byte-for-byte as before.
    ///
    /// ★ A REGION BELONGS TO EXACTLY ONE GROUP — the same invariant `faces` keeps —
    /// so adding a piece to a group removes it from whichever held it. That is what
    /// "add it to another Group" means, and doing it in one step is what stops a
    /// piece being claimed twice.
    private func handleTopologyPiecePick(_ faceID: FaceID, at point: SIMD3<Float>?,
                                         mesh: ViewerMesh) -> Bool {
        guard force.phase == .edit, !showLatticePage, !regionsOpen else { return false }

        // ★ ANY FACE A REGION COVERS IS TAPPED BY ITS REGION — not just a DIVIDED
        // one, which is all this used to handle.
        //
        // ★ WHY THAT WAS THE BUG. The maintainer isolated a curved surface with
        // select-similar, came back here, and "it stayed connected to its group".
        // An isolate produces a region with no CUTS, so this returned false, the
        // ordinary face route ran, and it toggled the group's `faces` list — while
        // the REGION carried on covering exactly those faces. The group therefore
        // still contained them, by the other of its two memberships. A face covered
        // by a region has to be reached through that region or it cannot be reached
        // at all.
        let covering = project.faceRegions.regions.filter {
            FaceRegionGeometry.members(of: $0, in: mesh).contains(faceID)
        }
        guard !covering.isEmpty else { return false }

        // Which piece is under the finger, resolved up through any union.
        let hit = point.flatMap {
            SurfaceTint.regionAt(point: SIMD3<Double>($0), face: faceID,
                                 mesh: mesh, regions: project.faceRegions)
        } ?? project.surfaceCutTarget(face: faceID)
        guard let piece = hit.map({ project.faceRegions.outermostUnion(containing: $0) })
        else { return false }

        project.sealUndoStep()
        let owner = selection.groups.first { $0.regionIDs.contains(piece) }
        // ★ AND THE RAW FACES GO WITH IT. A group holds BOTH a `faces` list and a
        // `regionIDs` list, and `latticeRegionCoveredFaces` subtracts one from the
        // other — so dropping only the region leaves the bare face behind, still in
        // the group, still emitted. That is the same defect from the other side:
        // one surface, two memberships, and both have to move together.
        let faces = project.surfaceResolvedFaces(piece)
        // ★ A GROUP HOLDING THE PIECE'S *PARENT* HOLDS THE PIECE IMPLICITLY, so
        // dropping the piece alone changes nothing and the face freezes lit. The
        // ancestor is replaced by the pieces it stands for first — see
        // `ProjectModel.surfaceDetachPiece`.
        for g in selection.groups { project.surfaceDetachPiece(piece, from: g.id) }
        // `removeRegions` drops the id from EVERY group, which is the invariant a
        // region belongs to exactly one — so a move is a remove then an add, and a
        // piece can never be claimed twice.
        selection.removeRegions([piece])
        for g in selection.groups { selection.removeFaces(faces, from: g.id) }

        // ★ `if let owner`, NOT `owner?.id == activeGroupID`.
        //
        // ★ THE BUG THAT MADE AN ISOLATED PIECE UNSELECTABLE. An isolated piece
        // belongs to NO group, so `owner` is nil; on a page where nothing is
        // selected yet `activeGroupID` is ALSO nil — and `nil == nil` is true. The
        // tap therefore took the "already in the active group, remove it and stop"
        // branch and did nothing at all, every time, for the one kind of piece that
        // has no owner by design. Optional equality quietly turned "owned by the
        // active group" into "owned by nobody, and nothing is active".
        switch TopologyPieceTap.route(owner: owner?.id,
                                      active: selection.activeGroupID) {
        case .removeOnly:
            break   // it was in the active group; the removal above is the whole act
        case .moveToActive:
            if selection.activeGroupID == nil { selection.addGroup() }
            if let target = selection.activeGroupID {
                selection.addRegions([piece], to: target)
            }
        }
        force.sync(groups: selection.groups)
        return true
    }

    /// ★ ONE TAP, ROUTED BY THE ARMED TOOL. `select` edits nothing; the rest arm a
    /// confirm and commit nothing until it is tapped.
    ///
    /// `point` is the 3D hit — the only thing that distinguishes the two halves of
    /// a cut face, since they share a face id.
    private func handleSurfacePick(_ faceID: FaceID, at point: SIMD3<Float>?,
                                   mesh: ViewerMesh) {
        // ★ ONLY A FACE THE TO PAGE ALREADY GROUPED (maintainer: "cuts and unions
        // can only happen on faces that are grouped together from the TO page").
        //
        // ★ AND THE REASON IS NOT TIDINESS. A region carries a ROLE, a DEPTH and a
        // lattice choice, and all three live on the GROUP. Acting on an ungrouped
        // face manufactures a region that belongs to no group — it appears in no
        // Selections list, and there is nowhere to give it any of the three. It is
        // geometry a user can make and then cannot reach.
        // ★ EVERY FACE IS EDITABLE HERE. NO GATE.
        //
        // This used to refuse any face the Topology page had not grouped. The
        // maintainer named the cost: "It wouldn't make sense to group a bunch of
        // faces together, only to ungroup most of them and re-group them according
        // to their new cuts. It should be that all faces are editable right away."
        // The gate forced the workflow backwards — group, come here, cut, go back
        // and regroup — and it was the reason a union could not reach two pieces on
        // a part with one grouped face.
        //
        // Grouping stays VISIBLE: a grouped face wears a hint of its group's colour
        // (`surfaceGroupHues`), an ungrouped one stays neutral. That distinction is
        // real and worth showing. It is no longer a permission.
        surfaceRefusal = nil

        // ★ WHICH PIECE. With a point, the half-space test picks the HALF that was
        // tapped; without one (no hit, e.g. the id pass answered but the ray
        // missed), the deepest region holding the face.
        // ★ THE PIECE UNDER THE FINGER, RESOLVED UP THROUGH ANY UNION. Once pieces
        // are combined they ARE one piece, so a tap on either selects the whole.
        // Landing on the part is why two combined faces still selected separately.
        //
        // ★ AND A FACE WITH NO REGION IS STILL SELECTABLE. Selection is not an edit,
        // so it does not manufacture one — the tapped FACE is remembered instead and
        // lit directly. Requiring a region is why "select still won't highlight any
        // face at the start. It requires a cut first."
        let hitPiece = point.map {
            SurfaceTint.regionAt(point: SIMD3<Double>($0), face: faceID,
                                 mesh: mesh, regions: project.faceRegions)
        } ?? project.surfaceCutTarget(face: faceID)
        surfaceSelected = hitPiece.map {
            project.faceRegions.outermostUnion(containing: $0)
        }
        surfaceSelectedFace = surfaceSelected == nil ? faceID : nil

        surfaceEngage(surfaceTool, face: faceID, mesh: mesh)
    }

    /// ★ POINT THE ARMED TOOL AT WHAT IS SELECTED — without clearing anything.
    ///
    /// The one place a tool decides what it does with a piece, so a TAP and a TOOL
    /// SWITCH cannot mean different things (maintainer, 2026-08-16: "When a face is
    /// selected with the selection tool and a tool is changed, the tool's action
    /// should automatically be turned on on the selected face"). Before this, the
    /// tray button threw the selection away and the switch was a dead end: you had
    /// to find the same face and tap it a second time.
    private func surfaceEngage(_ tool: SurfaceTool, face faceID: FaceID,
                               mesh: ViewerMesh) {
        switch tool {
        case .select:
            heldCut = nil

        case .cut:
            // ★ THE MIDDLE OF THE PIECE YOU TAPPED, not of the face it came from
            // (maintainer: "I tried cutting again and the cut line was in the exact
            // spot it had been when the two faces were one").
            //
            // `centred(onFace:)` reads the FACE's frame, and a cut does not change
            // the face — so cutting a half put the line back through the middle of
            // the original, i.e. exactly along the cut that made it. Reading the
            // REGION's own frame puts it through the middle of the half, which is
            // what "cut this in two" means the second time as much as the first.
            heldCut = surfaceSelected.flatMap {
                SurfaceCut.centred(onRegion: $0, of: faceID,
                                   regions: project.faceRegions, in: mesh)
            } ?? SurfaceCut.centred(onFace: faceID, in: mesh)
            cutRotation = 0
            cutRotationBase = 0
            cutOffsetMM = 0
            cutOffsetBase = 0
            hoveredCut = nil

        case .similar:
            // ★ §6(c) — DERIVE A RULE FROM THE TAP, don't freeze a list.
            //
            // PR 331 measured why: storing the matches makes a union "a stale id
            // list wearing a filter's clothes", and a simulated CAD edit grew a
            // 24-face union to 32. The FILTER is the membership, so it is what is
            // stored and what is re-evaluated on the next import.
            // ★ MULTI-SELECT OF KINDS. Tap a face and its kind joins; tap a face
            // already covered and that kind leaves. The rules are stored, never
            // their matches — see `SurfaceSimilar`.
            guard let f = project.surfaceSimilarFilter(to: faceID) else { break }
            similar.toggle(seed: faceID, filter: f) { pick in
                Set(FaceRegionGeometry.match(pick.filter, in: mesh))
            }

        case .union:
            // ★ A UNION IS MANY PIECES, SO THE TOOL ACCUMULATES (maintainer: "you
            // select a face, and click union … then select another face, and
            // another, and however many more, and you press the checkmark when
            // you're done").
            //
            // ★ AND TAPPING A PICKED PIECE DROPS IT AGAIN (maintainer, 2026-08-16:
            // "When multi-selecting in Union, tapping a selected face should
            // unselect it"). `SurfaceUnion.toggle` has always done that; what made
            // it look like it did not is the line below it. `surfaceSelected` is set
            // by every tap, and the tint lights the SELECTED region as well as the
            // picked ones — so a piece toggled OFF stayed blue, because it was now
            // merely selected. In union the picks ARE the selection; nothing else
            // may light.
            if let r = surfaceSelected ?? project.surfaceEnsureRegion(for: faceID) {
                surfaceUnion.toggle(r)
            }
            surfaceSelected = nil
            surfaceSelectedFace = nil

        case .pattern:
            surfacePatternFace = faceID
            surfacePatternPiece = surfaceSelected
        }
    }

    /// The face the current selection sits on — a selected PIECE's face, or the
    /// face selected directly when it has no region.
    private var surfaceSelectedFaceID: FaceID? {
        if let f = surfaceSelectedFace { return f }
        if let r = surfaceSelected {
            return project.surfaceResolvedFaces(r).first
        }
        return nil
    }

    /// ★ SWITCHING TOOL: abandon the last tool's work in progress, then point the
    /// new one at whatever is still selected.
    private func surfaceSwitch(to tool: SurfaceTool) {
        // ★ A SELECT-SIMILAR SELECTION SURVIVES THE SWITCH, AND THE NEW TOOL ACTS ON
        // ALL OF IT (maintainer, 2026-08-16: "ensure that if a tool is touched after
        // similar faces are selected, that it works" — the tool's action goes "to
        // all the similar faces").
        //
        // Captured BEFORE the reset below, which is what clears it.
        let carried: [FaceID] = surfaceTool == .similar && !similar.isEmpty
            ? Array(similarMatches).sorted() : []

        surfaceTool = tool
        heldCut = nil
        hoveredCut = nil
        surfaceRefusal = nil
        surfaceUnion.clear()
        surfacePatternFace = nil
        surfacePatternPiece = nil
        similar.clear()
        guard let mesh = viewerMesh else { return }

        if !carried.isEmpty {
            surfaceCarried = carried
            switch tool {
            case .select:
                // Nothing to arm; the set stays lit so it can be handed to a tool.
                surfaceSelected = nil
                surfaceSelectedFace = carried.first
            case .union:
                // ★ EVERY MATCH BECOMES A PICK. Confirm and they are one piece.
                for f in carried {
                    if let r = project.surfaceEnsureRegion(for: f) {
                        surfaceUnion.toggle(r)
                    }
                }
            case .cut, .pattern:
                // Aimed at the first, COMMITTED across all — see the confirms,
                // which read `surfaceCarried`.
                if let f = carried.first { surfaceEngage(tool, face: f, mesh: mesh) }
            case .similar:
                break
            }
            return
        }

        surfaceCarried = []
        guard let face = surfaceSelectedFaceID else { return }
        surfaceEngage(tool, face: face, mesh: mesh)
    }

    /// The face the pattern tool will split, once one is tapped.
    private var surfacePatternPreview: (cells: [FaceRegionGeometry.GridCell],
                                        verdict: SliverVerdict)? {
        guard let f = surfacePatternFace else { return nil }
        return project.surfacePatternPreview(face: f, columns: patternColumns,
                                             rows: patternRows,
                                             rotationDegrees: patternRotation,
                                             piece: surfacePatternPiece)
    }

    // MARK: ★ VIEW MODE — the wireframe and its x-ray, on every stage that has them
    //
    // ★ ONE PAIR OF SWITCHES, SHARED ACROSS STAGES. The maintainer asked for the
    // view to persist ("keep wireframe and xray view throughout the entire app"),
    // and two independent copies of the state is precisely how a view mode stops
    // persisting: turn it on here, walk next door, and it is off again. So these
    // read and write the SAME `surfaceWireframeOn` / `surfaceXrayOn` the Surface
    // tray does. Which stages offer them is `WorkspaceStageVisibility.wireframe`.

    /// The two toggles, SIDE BY SIDE with padding between them, in the slot
    /// directly under the position gizmo.
    @ViewBuilder private var viewModeToggles: some View {
        HStack(spacing: DS.Space.s) {
            viewModeButton("grid", label: "Wireframe", on: surfaceWireframeOn) {
                surfaceWireframeOn.toggle()
            }
            viewModeButton("square.stack.3d.up", label: "X-ray", on: surfaceXrayOn) {
                surfaceXrayOn.toggle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // ★ BELOW THE GIZMO, in the slot `gizmoClearance` defines — the same one
        // the Surface tray uses, so the two stages put the control in one place.
        .padding(.top, PageChrome.belowGizmo)
        // ★ ON `edge`, LIKE EVERYTHING ELSE ON THIS SIDE. These sat on
        // `gizmoInset` — the gizmo's FRAME — and so stood ~16 pt proud of both the
        // gizmo's glass and the bottom-right chips.
        .padding(.trailing, PageChrome.edge)
    }

    private func viewModeButton(_ icon: String, label: String, on: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle((on ? DS.Color.textPrimary
                                     : DS.Color.textTertiary).color)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                        .fill(on ? DS.Color.accentDeep.opacity(0.55).color
                                 : DS.Surface.bar.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill,
                                                  style: .continuous)
                            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: ★ §6 — THE SURFACE STAGE'S TOOL PANEL
    //
    // ★ THE TOOLS LIVE IN A PANEL, NOT ON THE VIEWPORT. The first attempt put the
    // tap and the rotate drag on a layer over the model, and that layer ate orbit
    // and pinch outright — the stage became one you could not turn the part in.
    // A panel cannot do that: it occupies its own rectangle, the viewport keeps
    // every gesture it had, and the maintainer can see what the stage offers
    // instead of having to discover it ("I am not seeing any of the tools").
    //
    // It sits on the RIGHT, BELOW THE GIZMO — the slot `PageChrome.gizmoClearance`
    // and `gizmoInset` already define, so it lines up with the stage-nav column
    // above it rather than being placed by eye.

    // ★ AN ICON TRAY, NOT A TEXT MODAL (maintainer, 2026-08-14: "The modal on the
    // right should be about half that width and think of it more like an icon tray
    // - not a full text modal … Think Adobe Photoshop's tools").
    //
    // ★ AND THE CONFIRM IS NOT IN IT. A checkmark inside the tray puts the verb an
    // arm's length from the thing it acts on; Photoshop's options never live in the
    // tool well either. The ✓ / rotate / ✕ float NEXT TO THE ACTION on the model —
    // see `surfaceActionCluster`.
    //
    // ~60 pt wide against the old panel's 260: a 44 pt target with the tray's own
    // padding either side, and nothing else.
    @ViewBuilder private var surfaceToolsPanel: some View {
        VStack(spacing: DS.Space.xs) {
            ForEach(SurfaceTool.allCases, id: \.rawValue) { tool in
                Button {
                    // Abandons the last tool's work in progress, then arms this one
                    // on whatever is still selected — see `surfaceSwitch`.
                    surfaceSwitch(to: tool)
                } label: {
                    Image(systemName: tool.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle((surfaceTool == tool
                                          ? DS.Color.textPrimary
                                          : DS.Color.textTertiary).color)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                .fill(surfaceTool == tool
                                      ? DS.Color.accentDeep.color : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
            }

            // ★ WIDTH-BOUND. A bare `Divider()` in a VStack expands to the widest
            // width offered — which here is the whole viewport, so the tray's
            // background became a full-screen band and its icons centred on it.
            Divider().overlay(DS.Color.strokePanel.color)
                .frame(width: 28).padding(.vertical, 2)

            // §6(b) — the wireframe, as one more icon rather than a labelled switch.
            Button { surfaceWireframeOn.toggle() } label: {
                Image(systemName: "grid")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle((surfaceWireframeOn
                                      ? DS.Color.textPrimary
                                      : DS.Color.textTertiary).color)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                            .fill(surfaceWireframeOn
                                  ? DS.Color.accentDeep.opacity(0.55).color : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wireframe")

            // ★ X-RAY, SEPARATELY. `#` decides whether there are lines; this
            // decides whether they show THROUGH the solid. They were one control
            // and the wireframe was washed out because of it.
            Button { surfaceXrayOn.toggle() } label: {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle((surfaceXrayOn
                                      ? DS.Color.textPrimary
                                      : DS.Color.textTertiary).color)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                            .fill(surfaceXrayOn
                                  ? DS.Color.accentDeep.opacity(0.55).color : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("X-ray")

        }
        .padding(DS.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                .fill(DS.Surface.panel.color)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall,
                                          style: .continuous)
                    .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        )
        .dsShadow(DS.Shadow.panel)
        // ONE LINE saying what a tap does, to the LEFT of the tray — a tray of
        // icons must not be a guessing game, and this is the only text the stage
        // carries.
        .overlay(alignment: .topLeading) {
            Text(surfaceRefusal ?? surfaceHint)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle((surfaceRefusal == nil
                                  ? DS.Color.textTertiary : DS.Color.warning).color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 160, alignment: .trailing)
                .offset(x: -172, y: 10)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, PageChrome.belowGizmo)
        // ★ ON `edge` — the same right-hand line as the gizmo's glass and the
        // bottom-right chips.
        .padding(.trailing, PageChrome.edge)
    }

    // ★ §6/§7 — THE ACTION CLUSTER: every tool's confirm, FLOATING NEXT TO WHAT IT
    // ACTS ON (maintainer: "Add a floating checkbox, rotation icon, or 'x' *next*
    // to the cut/action, not in the modal as a confirmation").
    //
    // One cluster serves all four tools, anchored to the point the action is
    // aimed at, so the verb is never an arm's length from its object. `select`
    // carries none: selecting is not a change, so there is nothing to confirm.
    @ViewBuilder private var surfaceActionCluster: some View {
        if visible.surfaceEditing, let proj = projection, let at = surfaceActionAnchor(proj) {
            HStack(spacing: DS.Space.xs) {
                switch surfaceTool {
                case .select:
                    EmptyView()

                case .cut:
                    if let held = heldCut {
                        surfaceClusterButton("xmark", tint: DS.Color.textSecondary) {
                            releaseCut()
                        }
                        // ★ §6(h) — ROTATE, 15° DETENTS. The drag lives on this knob
                        // and not on the viewport: on the viewport it consumed the
                        // camera's own gestures and orbit stopped working.
                        ZStack {
                            Circle().fill(DS.Surface.bar.color)
                            VStack(spacing: 0) {
                                Image(systemName: "rotate.3d")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(DS.Color.textPrimary.color)
                                Text("\(Int(cutAngleDegrees))°")
                                    .dsStyle(DS.TypeScale.caption)
                                    .foregroundStyle(DS.Color.textTertiary.color)
                                    .monospacedDigit()
                            }
                        }
                        .frame(width: 52, height: 52)
                        // ★ A TAP IS A QUARTER TURN. The common case by far is
                        // "the other way" — across the piece instead of along it —
                        // and asking for a 90° drag to get there is a chore. The
                        // drag stays for everything in between.
                        .onTapGesture {
                            cutRotation = SurfaceCut.snap(cutRotation + 90)
                            cutRotationBase = cutRotation
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { g in
                                    cutRotation = cutRotationBase
                                        + Double(g.translation.width) * 0.8
                                }
                                .onEnded { _ in
                                    cutRotation = SurfaceCut.snap(cutRotation)
                                    cutRotationBase = cutRotation
                                }
                        )
                        // ★ MOVE — the half-way point is a default, not a verdict.
                        // The drag slides the plane along its OWN normal, the only
                        // direction that moves a plane; sliding it within itself
                        // changes nothing and sliding it out of the face is
                        // meaningless.
                        ZStack {
                            Circle().fill(DS.Surface.bar.color)
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                        }
                        .frame(width: 44, height: 44)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { g in
                                    // ★ DRAG RIGHT ALWAYS MOVES RIGHT. The offset
                                    // runs along the plane's NORMAL, and that normal
                                    // points left or right on screen depending on
                                    // where the camera is and how far the cut has
                                    // been rotated — so a fixed mapping is correct
                                    // from one side and INVERTED from the other,
                                    // which is exactly what "working about half the
                                    // time and the other half, it's inverted" is.
                                    // Projecting the normal onto the screen gives
                                    // the sign, so the control matches the hand.
                                    cutOffsetMM = cutOffsetBase
                                        + Double(g.translation.width)
                                            * cutMoveScale * cutMoveSign
                                }
                                .onEnded { _ in cutOffsetBase = cutOffsetMM }
                        )
                        surfaceClusterConfirm {
                            // ★ ACROSS EVERY FACE A SELECT-SIMILAR HANDED OVER, each
                            // through its OWN centre at the same angle — see
                            // `surfaceCarried`. Otherwise just the one aimed at.
                            let kids = surfaceCarried.count > 1
                                ? project.commitSurfaceCut(
                                    faces: surfaceCarried,
                                    rotationDegrees: cutRotation,
                                    offsetMM: cutOffsetMM)
                                : project.commitSurfaceCut(
                                    held.rotated(by: SurfaceCut.snap(cutRotation))
                                        .moved(byMM: cutOffsetMM))
                            if surfaceCarried.count > 1 {
                                model.toast = "Cut \(surfaceCarried.count) faces."
                            }
                            surfaceCarried = []
                            releaseCut()
                            // ★ SELECT A HALF, so the split is visible the moment it
                            // is made rather than only after a further tap.
                            surfaceSelected = kids.first
                        }
                    }

                case .similar:
                    if !similar.isEmpty {
                        surfaceClusterButton("xmark", tint: DS.Color.textSecondary) {
                            similar.clear()
                        }
                        // ★ THE COUNT BELONGS HERE, unlike on union. These faces
                        // were DERIVED, not tapped — the user has not counted them
                        // and cannot, so the number is the only way to know whether
                        // the rule caught what was meant before acting on it.
                        surfaceClusterLabel(similarMatches.count == 1
                                            ? "1 like this"
                                            : "\(similarMatches.count) selected")
                        // ★ ISOLATE — "make all the similar faces (even if it's a
                        // singular one) into its own face, disconnecting from every
                        // other face it is currently connected with". Enabled at ONE
                        // match, because isolating a single face is a real thing to
                        // want: it is how you pull one face out of a union.
                        //
                        // ★ AND IT SPLITS BY CONNECTIVITY. "If they are *not*
                        // directly attached to one another, they should separate
                        // into isolated pieces … However, if multi-select connects
                        // the pieces, then they are all made into a single face
                        // group." That is `commitSurfaceIsolate(faces:named:)`.
                        surfaceClusterButton("scissors.badge.ellipsis",
                                             tint: DS.Color.textPrimary) {
                            let faces = Array(similarMatches).sorted()
                            let name = similar.seeds.first.map { "Face \($0) & like it" }
                                ?? "Isolated"
                            let made = project.commitSurfaceIsolate(faces: faces,
                                                                    named: name)
                            similar.clear()
                            // ★ AND SAY THAT IT HAPPENED (maintainer: "We need some
                            // sort of confirmation for the cutting of the
                            // select-similar step. Otherwise, there is no visual cue
                            // to show that it worked").
                            //
                            // Isolating is invisible by nature: the faces do not
                            // move, do not change shape and — until now — did not
                            // even change colour, because the tool stayed on
                            // `similar` and kept lighting its MATCHES. Dropping to
                            // `select` with a new piece selected lights what was
                            // made, and the toast says how it came out.
                            surfaceSelected = made.first
                            surfaceTool = .select
                            surfaceSelectedFace = nil
                            model.toast = made.count > 1
                                ? "Isolated \(faces.count) faces into \(made.count) "
                                  + "separate pieces — they do not touch, so each is "
                                  + "its own selection."
                                : "Isolated \(faces.count == 1 ? "this face" : "\(faces.count) faces") "
                                  + "into one piece — it is now its own selection "
                                  + "on the Topology page."
                        }
                        // ★ NO ✓ (maintainer, 2026-08-16: "What exactly does the
                        // checkbox of the 'select-similar' do? In my mind it
                        // shouldn't be there").
                        //
                        // It made a filter-defined UNION of every match — one row,
                        // one role, one depth. That is a real operation and the
                        // Regions sheet still offers it, but as the FIRST answer to
                        // "these faces are alike" it is the wrong one: it welds them
                        // together when the whole point of selecting them is to get
                        // at them. Removed rather than left as a second confusing
                        // verb next to ✂.
                    }

                case .union:
                    if !surfaceUnion.isEmpty {
                        // ★ ✓ AND ✕, NOTHING ELSE (maintainer: "what is with the
                        // '36 faces' section? No need for that. Just have a
                        // checkbox and 'x'"). What is selected is already visible
                        // ON THE MODEL — every picked face is lit — so a number
                        // restating it is a second, worse copy of the same fact.
                        surfaceClusterButton("xmark", tint: DS.Color.textSecondary) {
                            surfaceUnion.clear()
                        }
                        surfaceClusterConfirm(enabled: surfaceUnion.canCommit) {
                            surfaceSelected = project.commitSurfaceUnion(surfaceUnion)
                            surfaceUnion.clear()
                        }
                    }

                case .pattern:
                    if surfacePatternFace != nil {
                        surfaceClusterButton("xmark", tint: DS.Color.textSecondary) {
                            surfacePatternFace = nil
                            surfacePatternPiece = nil
                        }
                        // ★ §7 — COLUMNS x ROWS, with the SLIVER VERDICT on the
                        // confirm. The guard is priced at the run's own voxel
                        // spacing, so the panel refuses with the number the run
                        // would, and the confirm is simply not tappable when it does.
                        surfaceClusterStepper("col", value: $patternColumns)
                        surfaceClusterStepper("row", value: $patternRows)
                        // ★ §7 — TURN THE GRID. The automatic alignment is the
                        // face's longest straight edge; this is the override for
                        // when that is not the axis you meant.
                        ZStack {
                            Circle().fill(DS.Color.chipSolid.color)
                                .overlay(Circle().strokeBorder(
                                    DS.Color.textPrimary.opacity(0.22).color, lineWidth: 1))
                            VStack(spacing: 0) {
                                Image(systemName: "rotate.3d")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(DS.Color.textPrimary.color)
                                Text("\(Int(patternRotation))°")
                                    .dsStyle(DS.TypeScale.caption)
                                    .foregroundStyle(DS.Color.textTertiary.color)
                                    .monospacedDigit()
                            }
                        }
                        .frame(width: 52, height: 52)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { g in
                                    // ★ FOLDED AS IT TURNS. A grid is symmetric
                                    // every 90°, so an accumulating raw drag shows
                                    // meaningless numbers (−405° on his screen) for
                                    // grids already named inside one quarter-turn.
                                    patternRotation = SurfacePatternAxis.foldAngle(
                                        patternRotationBase
                                            + Double(g.translation.width) * 0.5)
                                }
                                .onEnded { _ in
                                    patternRotation = SurfacePatternAxis.foldAngle(
                                        SurfaceCut.snap(patternRotation))
                                    patternRotationBase = patternRotation
                                }
                        )
                        let preview = surfacePatternPreview
                        surfaceClusterLabel(preview.map {
                            $0.verdict.ok ? "\($0.cells.count) pieces" : $0.verdict.reason
                        } ?? "—", warn: preview.map { !$0.verdict.ok } ?? false)
                        surfaceClusterConfirm(enabled: preview?.verdict.ok ?? false) {
                            guard let face = surfacePatternFace else { return }
                            // ★ ACROSS EVERY CARRIED FACE — same grid, each in its
                            // own frame. A face the grid does not fit is skipped
                            // rather than failing the batch.
                            let kids = surfaceCarried.count > 1
                                ? project.commitSurfacePattern(
                                    faces: surfaceCarried, columns: patternColumns,
                                    rows: patternRows, rotationDegrees: patternRotation)
                                : project.commitSurfacePattern(
                                    face: face, columns: patternColumns, rows: patternRows,
                                    rotationDegrees: patternRotation,
                                    piece: surfacePatternPiece)
                            if surfaceCarried.count > 1 {
                                model.toast = "Patterned \(surfaceCarried.count) faces."
                            }
                            surfaceCarried = []
                            surfaceSelected = kids.first
                            surfacePatternFace = nil
                            surfacePatternPiece = nil
                        }
                    }
                }
            }
            // ★ KEPT ON SCREEN. Anchored to a point on the model, the cluster can
            // sit under the top chrome or off an edge — where it cannot be tapped
            // at all. Clamped into the viewport with room for its own height.
            // ★ WHERE THE CLUSTER SITS DEPENDS ON WHETHER THE TOOL STILL NEEDS THE
            // MODEL — not on whether it is "an action".
            //
            // CUT and PATTERN each aim at ONE face: after that tap the model is no
            // longer being touched, so their controls belong AT the thing they act
            // on. UNION keeps taking taps — every further face joins the set — and a
            // cluster floating over the part then sits on the very faces you are
            // trying to tap, which is why a union could be neither built nor
            // confirmed ("I cannot multi-select for the union", "Pressing the
            // checkbox for the union is impossible").
            //
            // So UNION alone docks. Docking pattern too was over-correction: it
            // moved a control away from its subject for a problem pattern does not
            // have ("The pattern action chips are no longer on the face they are
            // meant to be").
            .position(x: surfaceDocksCluster
                      ? (projection?.viewportSize.width ?? 1032) / 2
                      : min(max(at.x, 200),
                            max((projection?.viewportSize.width ?? 1032) - 200, 200)),
                      y: surfaceDocksCluster
                      ? (projection?.viewportSize.height ?? 1376) - bottomBarClearance - 40
                      : min(max(at.y - 84, 96),
                            max((projection?.viewportSize.height ?? 1376)
                                - bottomBarClearance - 90, 96)))
        }
    }

    /// The faces the picked PIECES resolve to — what the viewport lights. Two
    /// halves of one face light that face; the count in the hint is what says two
    /// distinct pieces are held.
    /// The faces the picked PIECES live on — the `member` set the fragment stage
    /// tests its half-space chains against. The chains decide what actually lights.
    private var surfaceUnionPickedFaces: Set<FaceID> {
        guard let mesh = viewerMesh else { return [] }
        return Set(surfaceUnion.facesTouched(regions: project.faceRegions, mesh: mesh))
    }

    /// ★ THE HINT, WITH THE COUNT WHERE ONE MATTERS. Union accumulates, and a
    /// tool that accumulates has to say how much it has — otherwise a tap that did
    /// not register and a tap that did look identical.
    private var surfaceHint: String {
        // ★ THE COUNT IS SHOWN EVEN AT ZERO. Otherwise a tap that TOGGLED A PIECE
        // OFF and a tap that never registered read identically — both fall back to
        // the tool's generic hint, and there is no way to tell "you tapped the same
        // piece twice" from "the tap did nothing".
        if surfaceTool == .similar, let mesh = viewerMesh {
            return similar.hint(in: mesh)
        }
        guard surfaceTool == .union, let mesh = viewerMesh else {
            return surfaceTool.hint
        }
        return surfaceUnion.hint(regions: project.faceRegions, mesh: mesh)
    }

    /// ★ WHICH TOOLS DOCK: the ones that keep taking taps on the model. Only union
    /// does — every further tap adds a face, so its controls must never be on top
    /// of the part.
    private var surfaceDocksCluster: Bool { false }

    /// Where the cluster floats: the point the armed tool is aimed at.
    private func surfaceActionAnchor(_ proj: CameraProjection) -> CGPoint? {
        guard let mesh = viewerMesh else { return nil }
        let model: SIMD3<Double>?
        switch surfaceTool {
        case .select:  model = nil
        case .cut:     model = heldCut?.point
        // The cluster floats over the CENTRE OF EVERYTHING PICKED, so it stays
        // with the selection as it grows rather than anchoring to the first tap.
        // ★ OVER WHAT IS PICKED — the centre of the whole set, so it stays with the
        // selection as it grows rather than anchoring to the first tap. Lifted well
        // clear by the placement below, so it does not sit on the faces still to be
        // tapped ("Same with union").
        // ★ OVER EVERYTHING SELECTED, not over the first tap — the selection is a
        // multi-select now and can span the part.
        case .similar: model = similar.isEmpty ? nil
            : FaceRegionGeometry.frame(members: Array(similarMatches).sorted(),
                                       in: mesh).origin
        case .union:   model = surfaceUnion.isEmpty ? nil
            : FaceRegionGeometry.frame(members: Array(surfaceUnionPickedFaces).sorted(),
                                       in: mesh).origin
        // Pattern floats over the face it will divide, like the cut does.
        case .pattern: model = surfacePatternFace.map {
            FaceRegionGeometry.frame(members: [$0], in: mesh).origin
        }
        }
        guard let m = model else { return nil }
        if surfaceDocksCluster { return .zero }   // docked: the slot is fixed
        return proj.project(settledWorld(SIMD3<Float>(m)))
    }

    private func surfaceClusterButton(_ icon: String, tint: RGBA,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DS.Color.chipSolid.color)
                    .overlay(Circle().strokeBorder(
                        DS.Color.textPrimary.opacity(0.22).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    /// The ✓. Disabled when the action would be refused, so the guard is visible
    /// BEFORE the tap rather than as a message after it.
    private func surfaceClusterConfirm(enabled: Bool = true,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle((enabled ? DS.Color.textPrimary
                                          : DS.Color.textTertiary).color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(enabled ? DS.Color.accentDeep.color
                                                  : DS.Surface.bar.color))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func surfaceClusterLabel(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .dsStyle(DS.TypeScale.caption)
            .foregroundStyle((warn ? DS.Color.warning : DS.Color.textSecondary).color)
            .lineLimit(2)
            .frame(maxWidth: 140)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 52)
            .background(Capsule().fill(DS.Color.chipSolid.color)
                .overlay(Capsule().strokeBorder(
                    DS.Color.textPrimary.opacity(0.22).color, lineWidth: 1)))
    }

    /// A −/+ pair with its number, for the pattern grid. Typed entry is the
    /// Regions sheet's job; here the values are 1..12 and a stepper is the faster
    /// control at that range.
    private func surfaceClusterStepper(_ label: String,
                                       value: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Button { value.wrappedValue = max(1, value.wrappedValue - 1) } label: {
                // ★ THE WHOLE 44 pt IS THE TARGET, NOT THE GLYPH. A bare `Image`
                // in a button is hit-tested on its DRAWN pixels — an 11 pt minus
                // sign is a ~10 pt target however large the frame around it, which
                // is why these could not be pressed. `contentShape` makes the frame
                // the target, and 44 is Apple's minimum.
                Image(systemName: "minus").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 44, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(spacing: -2) {
                Text("\(value.wrappedValue)")
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .monospacedDigit()
                Text(label)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            Button { value.wrappedValue = min(12, value.wrappedValue + 1) } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 44, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Capsule().fill(DS.Color.chipSolid.color)
            .overlay(Capsule().strokeBorder(
                DS.Color.textPrimary.opacity(0.22).color, lineWidth: 1)))
    }

    /// The held cut's angle, snapped, wrapped into 0..<360.
    private var cutAngleDegrees: Double {
        var d = SurfaceCut.snap(cutRotation).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    // MARK: ★ §6(g)/(h) — THE HOVERED CUT LINE AND ITS ROTATE CONTROL

    /// ★ §6(g) — "WITH A PENCIL, SHOW THE HOVERED POSITION while attempting a cut
    /// — the cut line follows the hover before it is committed."
    ///
    /// The hover runs through the SAME ray cast the tap picker uses
    /// (`CameraProjection.ray` → `FacePicker.hit`), so the line cannot disagree
    /// with the face a tap would select. `onContinuousHover` reports a pencil
    /// hovering above the glass on an M-series iPad; on hardware without hover it
    /// simply never fires and the mode still works by tap.
    @ViewBuilder private var surfaceCutOverlay: some View {
        if visible.surfaceEditing {
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    if let proj = projection {
                        // The line being aimed: the held one if a face is chosen,
                        // otherwise whatever the pencil is over.
                        if let base = heldCut ?? hoveredCut {
                            let cut = base.rotated(by: cutRotation)
                                .moved(byMM: heldCut == nil ? 0 : cutOffsetMM)
                            let seg = cut.previewSegment(halfLengthMM: cutPreviewHalfLengthMM)
                            if let a = proj.project(settledWorld(SIMD3<Float>(seg.a))),
                               let b = proj.project(settledWorld(SIMD3<Float>(seg.b))) {
                                Path { p in p.move(to: a); p.addLine(to: b) }
                                    .stroke(DS.Color.accentDeepEdge.color,
                                            // Thin: it marks a plane, it is not an
                                            // object with a width of its own.
                                            style: StrokeStyle(lineWidth: 1.5,
                                                               lineCap: .round,
                                                               dash: heldCut == nil ? [6, 5] : []))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            // ★ PURELY VISUAL, AND THAT IS LOAD-BEARING. This layer covers the
            // whole viewport. Mounted with a `.contentShape(Rectangle())` plus a
            // tap and a drag, it ATE THE VIEWPORT: orbit and pinch stopped working
            // the moment the Surface stage was entered, and `simultaneousGesture`
            // did not rescue it — the SwiftUI hit-test layer still wins over the
            // MTKView beneath. Caught on device; no test would have.
            .allowsHitTesting(false)
        }
    }

    private func releaseCut() {
        heldCut = nil
        hoveredCut = nil
        cutRotation = 0
        cutRotationBase = 0
    }


    /// ★ EFFECTIVELY INFINITE (maintainer: "Make the line infinitely thin and
    /// infinitely long. It needs to cut the entire way through the object both
    /// length and width").
    ///
    /// A cut IS a half-space: the plane has no ends, and it divides the whole part,
    /// not the patch near where you tapped. Drawn at 0.6 x the bounding radius the
    /// line stopped inside the face and read as a short stroke someone had drawn
    /// on it — which invites exactly the question of what happens past the end.
    /// The part's full diagonal always spans it from any angle, so the line leaves
    /// the silhouette on both sides and the plane's endlessness is visible.
    private var cutPreviewHalfLengthMM: Double {
        guard let m = viewerMesh else { return 1000 }
        let b = m.bounds
        let d = SIMD3<Double>(SIMD3<Float>(b.max.x - b.min.x,
                                           b.max.y - b.min.y,
                                           b.max.z - b.min.z))
        return simd_length(d)          // a full diagonal EITHER SIDE of the point
    }

    /// The cut plane under a view point, or nil on a miss.
    private func cutUnder(_ p: CGPoint) -> SurfaceCut? {
        guard let proj = projection, let mesh = viewerMesh,
              let ray = proj.ray(throughViewPoint: p) else { return nil }
        return SurfaceCut.at(rayOrigin: ray.origin, rayDir: ray.dir, mesh: mesh)
    }

    // MARK: ★ §3d — THE DEPTH PLANE'S 3D HANDLE

    /// ★ THE GRAB HANDLE PR 328 DID NOT GET TO. Each latticed face's slab carries
    /// a knob at its inner face; dragging it along the face normal sets how far in
    /// the lattice may go — and that number IS the protection depth (R4).
    ///
    /// It reuses the keep-clear drag pair verbatim: `ClearanceHandle(role:
    /// .slabDepth)` for the anchor and `ClearanceDragMath.slabDepth` for the value,
    /// both already unit-tested. The only new thing is the WRITE:
    /// `ProjectModel.writeLatticeDepthMM`, which lands on the one depth store.
    private var latticeDepthHandlesOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let proj = projection {
                ForEach(project.latticeDepthPlanes()) { plane in
                    if let at = proj.project(settledWorld(plane.handle.anchor)) {
                        latticeDepthKnob(active: draggingDepthPlane == plane.id)
                            // ★ A GRABBABLE TARGET. The knob draws at 22 pt, which
                            // is half Apple's 44 pt minimum — "I cannot drag the
                            // face primitive out" is partly that you have to hit a
                            // 22 pt dot buried in the model. The DRAWN size is
                            // unchanged; the TOUCH area is the standard 44.
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .gesture(latticeDepthPlaneDrag(plane))
                            .position(at)
                    }
                    // ★ THE EXPAND HANDLE (maintainer, 2026-08-17: "I specifically
                    // requested a handle to drag the expansion to be able to both
                    // visually and numerically set the expansion. Please add a
                    // handle -- make it only visible when the group/face/primitive
                    // is selected, hide it otherwise").
                    //
                    // ★ ONLY ON THE SELECTED THING. Every latticed face casts a
                    // DEPTH handle — that one is always useful — but an expand
                    // handle on every face at once is a field of knobs. It appears
                    // for the active group's selectables and nowhere else.
                    if latticeExpandHandleIsVisible(plane),
                       let ex = proj.project(settledWorld(latticeExpandAnchor(plane))) {
                        latticeExpandKnob(active: draggingExpandPlane == plane.id)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .gesture(latticeExpandDrag(plane))
                            .position(ex)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.clearanceStageSpace)
    }

    private func latticeDepthKnob(active: Bool) -> some View {
        let tint = LiquidGlass.Tint.frost(
            LatticeDensityProxy.densityColor(fraction: 0.6),
            intensity: active ? 0.85 : 0.55)
        let size: CGFloat = active ? 26 : 22
        return Image(systemName: "arrow.down.to.line")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .liquidGlass(tint, in: Circle(), specular: active ? 1.3 : 1)
            .contentShape(Circle().inset(by: -12))   // generous ~46pt target
    }

    /// ★ THE EXPAND HANDLE IS SHOWN FOR THE ACTIVE GROUP'S SELECTABLES ONLY.
    /// "Selected" is the group the user is working in — the same notion the rest
    /// of this panel uses (`selection.activeGroupID`) — so the handle appears
    /// exactly where the drawer the user is reading is.
    private func latticeExpandHandleIsVisible(_ plane: ProjectModel.LatticeDepthPlane) -> Bool {
        guard visible.latticeDepthPlanes else { return false }
        // ★ "SELECTED" MEANS EITHER WAY IN (maintainer, 2026-08-17: "I do not see
        // a handle for the expansion of a face"). The first cut required
        // `selection.activeGroupID`, which is set by tapping the group's BODY —
        // but the natural way to reach a face's controls is to EXPAND its row,
        // which writes the disclosure and never touches the active group. So a
        // user looking straight at the Expand number had no handle beside it.
        // Either route counts now: the active group, or an open drawer.
        if latticeDisclosure.isExpanded(plane.ref,
                                        regions: project.faceRegions) { return true }
        if latticeDisclosure.isExpanded(plane.groupID.uuidString) { return true }
        return plane.groupID == selection.activeGroupID
    }

    /// Where the expand knob sits: OUT along the slab's in-plane u axis, at the
    /// current expanded half-extent, so the knob is literally on the edge it
    /// moves. Offset from the depth knob so the two never overlap.
    private func latticeExpandAnchor(_ plane: ProjectModel.LatticeDepthPlane) -> SIMD3<Float> {
        let e = Float(project.latticeExpandMM(plane.ref))
        let n = simd_normalize(plane.handle.axisDir)
        // Any unit vector perpendicular to the slab axis — the same basis rule
        // `LatticeRegionMask` uses, so the knob points along the axis that grows.
        let a: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(n, a))
        return plane.handle.anchor + u * (Self.latticeExpandKnobBaseMM + e)
    }

    /// How far out the knob sits when the expand is 0, so it is never buried in
    /// the depth knob.
    static let latticeExpandKnobBaseMM: Float = 8

    private func latticeExpandKnob(active: Bool) -> some View {
        let tint = LiquidGlass.Tint.frost(
            LatticeDensityProxy.densityColor(fraction: 0.25),
            intensity: active ? 0.85 : 0.55)
        let size: CGFloat = active ? 26 : 22
        return Image(systemName: "arrow.left.and.right")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .liquidGlass(tint, in: Circle(), specular: active ? 1.3 : 1)
            .contentShape(Circle().inset(by: -12))
    }

    /// ★ DRAG THE EXPANSION. Horizontal drag in screen space, at the same
    /// 0.05 mm-per-point scrub the depth chip uses, so the two controls feel the
    /// same in the hand. The number in the drawer and the handle are ONE value —
    /// both write `writeLatticeExpandMM`.
    private func latticeExpandDrag(_ plane: ProjectModel.LatticeDepthPlane)
        -> some Gesture {
        let ref = plane.ref
        let seed = project.latticeExpandMM(ref)
        return DragGesture(minimumDistance: 1,
                           coordinateSpace: CoordinateSpace.named(Self.clearanceStageSpace))
            .onChanged { v in
                if draggingExpandPlane != plane.id {
                    draggingExpandPlane = plane.id
                    ClearanceHaptics.grab()
                }
                project.writeLatticeExpandMM(
                    ref, mm: seed + Double(v.translation.width) * 0.05)
            }
            .onEnded { _ in
                draggingExpandPlane = nil
                ClearanceHaptics.release()
                refreshLatticeFaceCards()
                // The expand moves the region the preview is clipped to, so the
                // picture is rebaked ONCE, when the value settles.
                if showStrutPreview { buildStrutScene() }
            }
    }

    private func latticeDepthPlaneDrag(_ plane: ProjectModel.LatticeDepthPlane)
        -> some Gesture {
        // Fixed geometry: `settled` only rotates it, and the value math reads none
        // of the moving fields, so capturing it here stays correct.
        let world = plane.handle.settled(center: meshCenter, rotation: settleQuat)
        let ref = plane.ref
        return DragGesture(minimumDistance: 1,
                           coordinateSpace: CoordinateSpace.named(Self.clearanceStageSpace))
            .onChanged { v in
                guard let proj = projection else { return }
                if draggingDepthPlane != plane.id {
                    draggingDepthPlane = plane.id
                    ClearanceHaptics.grab()
                }
                guard let ray = proj.ray(throughViewPoint: v.location),
                      let value = world.value(rayOrigin: ray.origin, rayDir: ray.dir)
                else { return }
                // ★ MAGNETIC DETENTS (maintainer, 2026-08-17). The 3D handle and
                // the row chip resolve through the SAME call, so the two cannot
                // develop different feels.
                project.writeLatticeDepthMM(ref, mm: snappedDepthMM(Double(value)))
            }
            .onEnded { _ in
                draggingDepthPlane = nil
                latticeDepthDetent = nil
                ClearanceHaptics.release()
                refreshLatticeFaceCards()
                if showStrutPreview { buildStrutScene() }
            }
    }

    /// The on-model glass value chips — round-4 items 3+4: ONE chip PER HANDLE, anchored right
    /// beside its handle icon (adjacency is the point — each chip visually belongs to its handle),
    /// shown for EVERY keep-clear site with no selection required. When a group is UNSYNCED each
    /// bore's chips edit that bore alone; when synced they edit the shared value (item 3). Sized to
    /// the weight-pill class (`compact`). Each is the primary editor AND the live readout while its
    /// handle drags (reading the same per-bore override the drag writes).
    ///
    /// Round-5 (Task A6 item 1): a SYNCED group collapses to ONE shared chip set — only its
    /// representative primitive's chips draw (`syncCollapsedChipItems`), so the maintainer's
    /// duplicate stacked "DEPTH 3 mm" chips are gone. The drag knobs are NOT collapsed.
    @ViewBuilder private func clearanceValuePill(_ proj: CameraProjection, _ placed: [String: KeepOutPlacement]) -> some View {
        ForEach(syncCollapsedChipItems) { item in
            // The pill was placed (pass 2) beside its knob's resolved position and cleared of the
            // gizmo / other pills — so it stays with its knob and never stacks. Fallback beside the
            // raw projection before the first resolve.
            let fallback = proj.project(settledWorld(item.handle.anchor)).map {
                CGPoint(x: $0.x + Self.chipKnobClearance + Self.clrPillSize.width / 2, y: $0.y)
            }
            if let center = placed[clrPillID(item)]?.center ?? fallback {
                clearanceHandleChip(item).fixedSize()
                    .position(center)
                    .animation(DS.Motion.emphasized, value: center)
            }
        }
    }

    /// Round-6 item 1: how far right of a clearance knob's CENTRE the value chip's leading edge
    /// sits. The knob's grab target is a circle of radius `size/2 + 12` ≈ 25 pt when active
    /// (`clearanceHandleKnob`); 40 pt clears that with ~15 pt of breathing room, so the chip
    /// never overlaps the hit area of the handle it belongs to.
    private static let chipKnobClearance: CGFloat = 40

    /// The value chip for ONE clearance handle (Margin/Axial for a bore, Depth for a plane),
    /// reading and writing that bore's effective override (per-bore when unsynced, shared when
    /// synced — item 3). Highlights while its own handle owns the drag.
    @ViewBuilder private func clearanceHandleChip(_ item: ClearanceHandleItem) -> some View {
        let gid = item.groupID
        let fid = Int(item.faceID)
        let role = item.handle.role.metricRole
        let live = draggingHandleID == item.id
        // DEFECT 1: read the ONE resolved value `ProjectModel.clearanceMetric` returns — the
        // SAME call the Selections-panel chip makes (`manualPrimitiveLine`/`clearancePrimitiveLine`)
        // and the SAME value the rendered volume is built from. The old path derived a manual
        // primitive's Auto from a B-rep face lookup that has no entry for it (→ nil → 0 mm) while
        // the panel derived it from the primitive's own radius — two numbers for one value.
        //
        // Round-6 item 2: the 3D-viewport chips are NUMBER-ONLY (like the load-weight chip) —
        // `showTitle`/`showChrome` off. The handle's own glyph (↔ margin, ↕ axial, ⊤ depth) names
        // the value, so the caption is redundant here. Reset-to-Auto lives in the panel.
        let m = project.clearanceMetric(groupID: gid, faceID: fid, role: role)
        GlassValuePill(title: Self.metricTitle(role), valueMM: m?.override, autoMM: m?.auto,
                       active: live, compact: true, showTitle: false, showChrome: false) {
            project.writeClearanceMetric(groupID: gid, faceID: fid, role: role, mm: $0)
        }
    }

    /// The chip caption for a clearance role (used for accessibility even when `showTitle` is off).
    private static func metricTitle(_ role: ClearanceMetric.Role) -> String {
        switch role {
        case .margin: return "Margin"
        case .axial: return "Axial"
        case .slabDepth: return "Depth"
        }
    }

    /// One bore face's exact cylinder radius (mm) for building a `ClearancePrimitive`; nil for a
    /// non-cylindrical / STL face.
    private func faceBoreRadius(_ f: FaceID) -> Double? {
        guard let mesh = viewerMesh, let geo = mesh.faceGeometry(f), geo.isCylinder else { return nil }
        return geo.cylinderRadiusMM
    }

    /// A clearance drag knob — a LIQUID-GLASS RED dot with a role glyph and a generous (~46pt)
    /// hit target (design-overhaul 109: a reskin of the chrome only — the grab target and drag
    /// math are unchanged; red keeps the forbidden-space colour language). Brightens (stronger
    /// frost + specular) while it owns the drag.
    private func clearanceHandleKnob(role: ClearanceHandle.Role, active: Bool) -> some View {
        let tint = LiquidGlass.Tint.frost(DS.Color.clearance, intensity: active ? 0.85 : 0.55)
        let size: CGFloat = active ? 26 : 22
        return Image(systemName: clearanceRoleIcon(role))
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .liquidGlass(tint, in: Circle(), specular: active ? 1.3 : 1)
            .shadow(color: Self.clearanceTint.opacity(0.5), radius: 4)
            .contentShape(Circle().inset(by: -12))   // generous ~46pt target
    }

    private func clearanceRoleIcon(_ role: ClearanceHandle.Role) -> String {
        switch role {
        case .margin: return "arrow.left.and.right"
        case .axialHi: return "arrow.up"
        case .axialLo: return "arrow.down"
        case .slabDepth: return "arrow.up.to.line"
        }
    }

    /// Route a handle pan through `ClearanceDragMath` (via the pure `ClearanceHandle`):
    /// build the per-frame camera ray at the touch, run the value math in settled-world
    /// space, and WRITE the mm continuously (Auto → explicit happens on the first write;
    /// the volume re-tessellates live via the Equatable-gated path). Haptics on grab /
    /// release and when the value crosses its Auto suggestion.
    private func clearanceHandleDrag(_ item: ClearanceHandleItem) -> some Gesture {
        // Fixed geometry: `settled` only rotates it, and the value math reads none of the
        // moving fields, so capturing it here (even across body updates) stays correct.
        let world = item.handle.settled(center: meshCenter, rotation: settleQuat)
        return DragGesture(minimumDistance: 1, coordinateSpace: CoordinateSpace.named(Self.clearanceStageSpace))
            .onChanged { v in
                guard let proj = projection else { return }
                if draggingHandleID != item.id {
                    draggingHandleID = item.id
                    lastHandleValue = nil
                    ClearanceHaptics.grab()
                }
                guard let ray = proj.ray(throughViewPoint: v.location),
                      let value = world.value(rayOrigin: ray.origin, rayDir: ray.dir) else { return }
                writeClearance(item.groupID, face: item.faceID, role: item.handle.role, mm: Double(value))
                if let auto = clearanceAutoValue(item.groupID, role: item.handle.role),
                   let last = lastHandleValue,
                   (last - auto).sign != (value - auto).sign {
                    ClearanceHaptics.crossedAuto()
                }
                lastHandleValue = value
            }
            .onEnded { _ in
                draggingHandleID = nil
                lastHandleValue = nil
                ClearanceHaptics.release()
            }
    }

    /// Write the dragged mm to this bore's override (per-bore when the group is unsynced, shared
    /// when synced — round-4 item 3), quantized to the 0.25 mm grid live (item 12) so a handle-drag
    /// ticks in whole steps just like the scrub pill.
    private func writeClearance(_ gid: UUID, face: FaceID, role: ClearanceHandle.Role, mm: Double) {
        // DEFECT 1: route through the ONE writer so a viewport handle drag on a MANUAL
        // primitive lands on the primitive's own override (not a phantom group/bore slot the
        // run ignores). `writeClearanceMetric` dispatches manual vs auto by the sign of faceID.
        project.writeClearanceMetric(groupID: gid, faceID: Int(face), role: role.metricRole,
                                     mm: ClearanceQuantize.snap(mm))
    }

    /// The Auto suggestion (mm) for a group's role — the reference the crossing haptic
    /// fires at. Nil for a bolt role with no bore geometry.
    private func clearanceAutoValue(_ gid: UUID, role: ClearanceHandle.Role) -> Float? {
        guard let g = selection.groups.first(where: { $0.id == gid }) else { return nil }
        switch role {
        case .margin:
            return project.clearanceBoreRadius(for: g).map { Float(ClearanceSuggestion.boltMarginMM(boreRadiusMM: $0)) }
        case .axialLo, .axialHi:
            return project.clearanceBoreRadius(for: g).map { Float(ClearanceSuggestion.boltAxialMM(boreRadiusMM: $0)) }
        case .slabDepth:
            return Float(ClearanceSuggestion.faceSlabDepthMM)
        }
    }

    /// Keep a floated overlay on-screen horizontally (mirror of `clamp` for y).
    private func clampX(_ x: CGFloat, _ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(x, 90), Swift.max(100, width - 90))
    }

    // MARK: DEFECT 2 — manual-primitive TRANSFORM GIZMO (device-QA'd interaction layer)

    /// The named coordinate space the gizmo drags read their touch LOCATION in — the same
    /// rationale as `clearanceStageSpace`: `projection.ray` needs the absolute stage point.
    private static let gizmoStageSpace = "primitiveGizmoStage"

    /// The transform-gizmo overlay. For the active group, each unselected manual primitive
    /// shows a small SELECT knob; the selected one (`gizmoTarget`) shows the full connected
    /// gizmo (`gizmoHandles`) — three axis arrows (axis move), three square plates (plane move),
    /// three rotation ribbons (rotate about the ⟂ axis) and a free-move hub, plus the
    /// COPY / snap / dismiss cluster.
    ///
    /// Camera non-fighting (G4): every hit target binds its gesture to the SIZED view BEFORE
    /// `.position` (the clearance-handle rule), so a touch on a control owns the drag and
    /// empty space falls through to orbit — and, symmetrically, an orbit touch never lands on
    /// a control so it can't nudge a primitive. The transform math is the pure, tested
    /// `PrimitiveGizmo`; THIS gesture + body draw are the device-QA'd layers.
    @ViewBuilder private var primitiveGizmoOverlay: some View {
        if let proj = projection, let gid = selection.activeGroupID {
            ZStack(alignment: .topLeading) {
                ForEach(project.manualPrimitives(in: gid)) { mp in
                    if gizmoTarget == GizmoTarget(group: gid, id: mp.id) {
                        gizmoHandles(proj, group: gid, mp: mp)
                    } else if let pt = proj.project(settledWorld(SIMD3<Float>(mp.center))) {
                        // Round-2 T6: the move knob is the ONLY way to grab a
                        // primitive — enlarged (26 → 40 pt glass, ~64 pt hit
                        // target with the knob's −12 pt inset) so it is easy to hit.
                        gizmoCircleKnob(active: false, size: 40) {
                            Image(systemName: "move.3d").font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .onTapGesture {
                            gizmoTarget = GizmoTarget(group: gid, id: mp.id)
                            chipsRevealedGroup = gid   // T2: tapping the primitive reveals chips
                        }
                        .position(pt)
                        .accessibilityLabel("Select primitive to transform")
                    }
                }
            }
            .coordinateSpace(name: Self.gizmoStageSpace)
        }
    }

    /// The SELECTED primitive's transform gizmo — rebuilt (redesign 2026-07-26, take 2) as a
    /// genuine 3D RAYMARCHED LIQUID-GLASS object, the same way the Position (orientation)
    /// gizmo is built, so the two read as one set. Take 1's flat 2D path was rejected: it
    /// looked like squashed rectangles, grew seam lines/holes, and lost half of itself at some
    /// angles. This renders `TransformGizmo`'s SDF (hub + three axis arms with arrowheads +
    /// three flat SQUARE plane plates + three rotation ribbons) in Metal, with real depth,
    /// translucency and a lit rim, floating at the primitive's projected centre and rotating
    /// with the view.
    ///
    /// The glass itself is a non-interactive `TransformGizmoMetalView`. A same-size transparent
    /// box captures the drag: on grab it SDF-picks the handle (`TransformGizmo.pick`); a hit
    /// runs the untouched `PrimitiveGizmo` + `moveManualPrimitive` translate; a miss orbits the
    /// camera (so the box is never a dead zone — G4: a handle drag never orbits, an empty-box
    /// or outside drag orbits and never nudges).
    @ViewBuilder private func gizmoHandles(_ proj: CameraProjection, group gid: UUID,
                                           mp: ManualPrimitive) -> some View {
        #if canImport(MetalKit)
        if let center = proj.project(settledWorld(SIMD3<Float>(mp.center))) {
            let box = Self.gizmoBoxSize
            ZStack(alignment: .topLeading) {
                // The gizmo tracks the primitive's OWN orientation (rotates WITH the body), so the
                // glass stays visually attached as you turn it. Same matrix drives render + pick +
                // handle axes below, so the drawn ribbons and the axis a grab rotates about agree.
                TransformGizmoMetalView(camera: cameraModel,
                                        settle: gizmoSettleMatrix * primitiveOrientation(mp),
                                        activeId: gizmoActiveId)
                    .frame(width: box, height: box)
                    .allowsHitTesting(false)
                    .position(center)

                Color.clear
                    .frame(width: box, height: box)
                    .contentShape(Rectangle())
                    .gesture(gizmoBoxGesture(proj, group: gid, mp: mp,
                                             boxCenter: center, boxSize: box))
                    .position(center)

                // COPY / snap-override / dismiss cluster above the gizmo; snap feedback below.
                gizmoActionCluster(group: gid, mp: mp)
                    .position(x: center.x, y: center.y - box / 2 - 4)
                if !gizmoSnapLabels.isEmpty {
                    gizmoSnapBadge.position(x: center.x, y: center.y + box / 2 + 4)
                }
            }
        }
        #else
        EmptyView()
        #endif
    }

    /// The gizmo's square overlay footprint (pt). This is the SINGLE size knob: it scales the
    /// Metal render AND the CPU pick together (both read it), so the drawn glass and the grab
    /// geometry can't diverge. Enlarged to 330 (round 4 packs in the rotation ribbons too) so the
    /// manipulator reads as a control you reach for; with the fat pick radii in
    /// `TransformGizmo.Constants` the touch targets are ≈ 48 pt arms, ≈ 48 pt hub, ≈ 34 pt plane
    /// squares (kept small so they clear the ribbons) and long ribbon bands (asserted in
    /// `TransformGizmoTests`). Empty box space orbits.
    static let gizmoBoxSize: CGFloat = 297

    /// The model→world settle rotation as a matrix (identity when the part isn't settled), so
    /// the gizmo's arms line up with the model axes exactly as the viewer draws them.
    private var gizmoSettleMatrix: simd_float3x3 { simd_float3x3(settleQuat) }

    /// The object→view rotation the render + pick share: the live camera view-rotation
    /// composed with the settle, so a tap lands on the arm the user sees.
    private var gizmoRotation: simd_float3x3 { cameraModel.viewRotation * gizmoSettleMatrix }

    /// The primitive's OWN orientation as a model-space rotation (shortest arc from the default
    /// axis +Z to `mp.axis`), so the gizmo rotates WITH the body. Composed into the render, the
    /// pick and the handle axes identically, so grabbing a ribbon rotates about the axis the user
    /// sees. Identity for a fresh (+Z) primitive → byte-identical to the old world-aligned gizmo.
    private func primitiveOrientation(_ mp: ManualPrimitive) -> simd_float3x3 {
        let to = simd_normalize(SIMD3<Float>(mp.axis))
        let from = SIMD3<Float>(0, 0, 1)
        let d = simd_dot(from, to)
        if d >= 0.99999 { return matrix_identity_float3x3 }
        if d <= -0.99999 { return simd_float3x3(simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))) }
        let axis = simd_normalize(simd_cross(from, to))
        return simd_float3x3(simd_quatf(angle: acosf(d), axis: axis))
    }

    private func gizmoActiveIdValue(_ hit: TransformGizmo.Hit) -> Float {
        switch hit {
        case .free:            return 0
        case .axis(let i):     return Float(1 + i)
        case .plane(let p):    return Float(4 + p)
        case .rotate(let p):   return Float(7 + p)
        }
    }

    /// Map a picked handle to its model-space vector, rotated into the primitive's own frame by
    /// `O` so a tap on a tilted ribbon rotates about the axis drawn under the finger (the gizmo
    /// tracks the body). `O = identity` reproduces the world-aligned mapping exactly.
    private func gizmoHandle(for hit: TransformGizmo.Hit, orientation O: simd_float3x3) -> PrimitiveGizmo.Handle {
        func local(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3<Double>(O * SIMD3<Float>(v)) }
        switch hit {
        case .free:            return .free
        case .axis(let i):     return .axis(local(TransformGizmo.axisVectors[i]))
        case .plane(let p):    return .plane(local(TransformGizmo.planeNormals[p]))
        case .rotate(let p):   return .rotate(local(TransformGizmo.planeNormals[p]))
        }
    }

    /// The ONE gesture on the gizmo box: pick a handle on grab (SDF), then either run the
    /// translate drag (untouched `PrimitiveGizmo` → `moveManualPrimitive`) or, on a miss,
    /// orbit the camera — so the box never fights the camera in either direction.
    private func gizmoBoxGesture(_ proj: CameraProjection, group gid: UUID, mp: ManualPrimitive,
                                 boxCenter: CGPoint, boxSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: CoordinateSpace.named(Self.gizmoStageSpace))
            .onChanged { v in
                // First frame: decide handle-drag vs orbit via the SDF pick.
                if gizmoDrag == nil && !gizmoBoxOrbiting && gizmoBoxDragLast == nil {
                    let local = CGPoint(x: v.startLocation.x - (boxCenter.x - boxSize / 2),
                                        y: v.startLocation.y - (boxCenter.y - boxSize / 2))
                    // Pick + handle axes use the SAME primitive-orientation matrix the render does,
                    // so a grab on a tilted ribbon rotates about the axis drawn under the finger.
                    let orient = primitiveOrientation(mp)
                    if let hit = TransformGizmo.pick(point: local,
                                                     in: CGSize(width: boxSize, height: boxSize),
                                                     rotation: gizmoRotation * orient),
                       let ray = modelRay(proj, at: v.location) {
                        gizmoActiveId = gizmoActiveIdValue(hit)
                        gizmoDrag = PrimitiveGizmo.Drag(handle: gizmoHandle(for: hit, orientation: orient),
                                                        startCenter: mp.center, startAxis: mp.axis,
                                                        grab: ray, viewDir: ray.dir)
                        gizmoRotTickStep = 0
                        ClearanceHaptics.grab()
                    } else {
                        gizmoBoxOrbiting = true
                    }
                    gizmoBoxDragLast = v.location
                }
                if gizmoBoxOrbiting {
                    let last = gizmoBoxDragLast ?? v.startLocation
                    cameraModel.orbit(dx: Float(v.location.x - last.x), dy: Float(v.location.y - last.y))
                    gizmoBoxDragLast = v.location
                    return
                }
                guard let drag = gizmoDrag, let ray = modelRay(proj, at: v.location) else { return }
                let out = drag.resolve(currentRay: ray)
                // A ribbon ROTATES (writes the axis, centre fixed); every other handle
                // TRANSLATES (writes the centre, axis fixed). Same detent-magnet toggle both ways.
                let labels: [String]
                if case .rotate = drag.handle {
                    // Pass the grabbed start axis so the detent won't snap the turn back onto the
                    // orientation it's leaving (the 8° dead-zone that made the ribbons read dead).
                    labels = project.rotateManualPrimitive(id: mp.id, in: gid, to: out.axis,
                                                           from: drag.startAxis, snap: gizmoSnap)
                    // Tactile TICKS every 15° swept, so a rotation feels stepped, not silent.
                    let deg = acos(min(1, abs(simd_dot(PrimitiveGizmo.unit(drag.startAxis),
                                                       PrimitiveGizmo.unit(out.axis))))) * 180 / .pi
                    let step = Int(deg / 15)
                    if step != gizmoRotTickStep {
                        if step > gizmoRotTickStep { ClearanceHaptics.detent() }
                        gizmoRotTickStep = step
                    }
                } else {
                    labels = project.moveManualPrimitive(id: mp.id, in: gid, to: out.center, snap: gizmoSnap)
                }
                if labels != gizmoSnapLabels {
                    if !labels.isEmpty { ClearanceHaptics.detent() }
                    gizmoSnapLabels = labels
                }
            }
            .onEnded { _ in
                let wasDragging = gizmoDrag != nil
                gizmoDrag = nil
                gizmoBoxOrbiting = false
                gizmoBoxDragLast = nil
                gizmoActiveId = -1
                gizmoSnapLabels = []
                if wasDragging { ClearanceHaptics.release() }
            }
    }

    /// The LATTICE REGION's transform gizmo (handoff 2026-07-29-lattice-mode-ui). Reuses
    /// the SAME components as the manual-primitive gizmo — the raymarched
    /// `TransformGizmoMetalView` glass, the analytic `TransformGizmo.pick`, and the
    /// `PrimitiveGizmo.Drag` translate/rotate math — but commits to `project.lattice.region`
    /// instead of a force-group primitive (task requirement 2: reuse the gizmo, don't build
    /// a second placement mechanism). Shown only while the lattice panel is open and a
    /// region exists, so it never coincides with the force gizmo or steals its taps (U5).
    @ViewBuilder private var latticeRegionGizmoOverlay: some View {
        #if canImport(MetalKit)
        // Never while a force primitive is selected for transform (gizmoTarget != nil): that
        // is the only time the force gizmo draws its full 297pt box, so gating here means the
        // two gizmo boxes can never coincide or steal each other's taps (U5).
        if showLatticePage, project.lattice.enabled, gizmoTarget == nil,
           let region = project.lattice.region,
           let proj = projection,
           let center = proj.project(settledWorld(SIMD3<Float>(region.center))) {
            let box = Self.gizmoBoxSize
            ZStack(alignment: .topLeading) {
                TransformGizmoMetalView(camera: cameraModel,
                                        settle: gizmoSettleMatrix * primitiveOrientation(region),
                                        activeId: latticeRegionActiveId)
                    .frame(width: box, height: box)
                    .allowsHitTesting(false)
                    .position(center)
                Color.clear
                    .frame(width: box, height: box)
                    .contentShape(Rectangle())
                    .gesture(latticeRegionGizmoGesture(proj, region: region,
                                                       boxCenter: center, boxSize: box))
                    .position(center)
            }
            .coordinateSpace(name: Self.gizmoStageSpace)
        }
        #endif
    }

    /// The lattice-region gizmo's gesture — the trimmed twin of `gizmoBoxGesture`
    /// (translate + rotate, no copy/dismiss cluster), committing to the region.
    private func latticeRegionGizmoGesture(_ proj: CameraProjection, region: ManualPrimitive,
                                           boxCenter: CGPoint, boxSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: CoordinateSpace.named(Self.gizmoStageSpace))
            .onChanged { v in
                if latticeRegionDrag == nil && !latticeRegionOrbiting && gizmoBoxDragLast == nil {
                    let local = CGPoint(x: v.startLocation.x - (boxCenter.x - boxSize / 2),
                                        y: v.startLocation.y - (boxCenter.y - boxSize / 2))
                    let orient = primitiveOrientation(region)
                    if let hit = TransformGizmo.pick(point: local,
                                                     in: CGSize(width: boxSize, height: boxSize),
                                                     rotation: gizmoRotation * orient),
                       let ray = modelRay(proj, at: v.location) {
                        latticeRegionActiveId = gizmoActiveIdValue(hit)
                        latticeRegionDrag = PrimitiveGizmo.Drag(
                            handle: gizmoHandle(for: hit, orientation: orient),
                            startCenter: region.center, startAxis: region.axis,
                            grab: ray, viewDir: ray.dir)
                        ClearanceHaptics.grab()
                    } else {
                        latticeRegionOrbiting = true
                    }
                    gizmoBoxDragLast = v.location
                }
                if latticeRegionOrbiting {
                    let last = gizmoBoxDragLast ?? v.startLocation
                    cameraModel.orbit(dx: Float(v.location.x - last.x), dy: Float(v.location.y - last.y))
                    gizmoBoxDragLast = v.location
                    return
                }
                guard let drag = latticeRegionDrag, let ray = modelRay(proj, at: v.location) else { return }
                let out = drag.resolve(currentRay: ray)
                if case .rotate = drag.handle {
                    _ = project.rotateLatticeRegion(to: out.axis, from: drag.startAxis)
                } else {
                    _ = project.moveLatticeRegion(to: out.center)
                }
            }
            .onEnded { _ in
                let was = latticeRegionDrag != nil
                latticeRegionDrag = nil
                latticeRegionOrbiting = false
                gizmoBoxDragLast = nil
                latticeRegionActiveId = -1
                if was { ClearanceHaptics.release() }
            }
    }

    /// Project a model-space anchor and position a knob there (knob keeps its own gesture,
    /// applied BEFORE `.position` — the camera-non-fighting rule).
    @ViewBuilder private func gizmoAt(_ proj: CameraProjection, _ p: SIMD3<Double>,
                                      @ViewBuilder _ knob: () -> some View) -> some View {
        if let pt = proj.project(settledWorld(SIMD3<Float>(p))) { knob().position(pt) }
    }

    /// COPY (duplicate, G6), the snap OVERRIDE toggle (the magnet), and dismiss.
    @ViewBuilder private func gizmoActionCluster(group gid: UUID, mp: ManualPrimitive) -> some View {
        HStack(spacing: DS.Space.s) {
            Button {
                if let new = project.copyManualPrimitive(id: mp.id, in: gid) {
                    gizmoTarget = GizmoTarget(group: gid, id: new)   // edit the fresh copy
                }
            } label: {
                gizmoCircleKnob(active: false, size: 26) {
                    Image(systemName: "plus.square.on.square").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }.buttonStyle(.plain).accessibilityLabel("Copy primitive")

            // (Round 3 removed the `scope` crosshair toggle here: it read as an aiming/re-centre
            // control and confused the maintainer. Magnetic detents are UNCHANGED — they stay ON
            // (`gizmoSnap` below), just without the misleading crosshair button.)
            Button { gizmoTarget = nil } label: {
                gizmoCircleKnob(active: false, size: 26) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }.buttonStyle(.plain).accessibilityLabel("Done transforming")
        }
    }

    /// What the last drag frame snapped to ("Snapped to: bore axis, world Z") — the handoff
    /// requires the UI to STATE what it snapped to and why.
    private var gizmoSnapBadge: some View {
        Text("Snapped to: " + gizmoSnapLabels.joined(separator: ", "))
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(Capsule().fill(DS.Color.accent.color.opacity(0.9)))
            .fixedSize()
            .accessibilityLabel("Snapped to \(gizmoSnapLabels.joined(separator: ", "))")
    }

    /// Bind the transform gizmo to a just-created primitive (from "+ primitive" or an
    /// auto→manual conversion) and dismiss the add dialog, so the user can grab it at once.
    private func selectNewPrimitive(_ id: UUID?, in gid: UUID) {
        addingPrimitiveGroup = nil
        guard let id else { return }
        gizmoTarget = GizmoTarget(group: gid, id: id)
        chipsRevealedGroup = gid   // T2: an explicit primitive interaction reveals its chips
    }

    /// Turn a stage touch into a MODEL-space ray: the camera ray (settled world) inverse-settled
    /// back into the frame the primitive is stored in, so `PrimitiveGizmo` runs in one frame and
    /// the result is stored directly (no post-hoc transform).
    private func modelRay(_ proj: CameraProjection, at loc: CGPoint) -> PrimitiveGizmo.Ray? {
        guard let w = proj.ray(throughViewPoint: loc) else { return nil }
        let c = meshCenter
        let inv = settleQuat.inverse
        let o = c + inv.act(w.origin - c)
        let d = inv.act(w.dir)
        return PrimitiveGizmo.Ray(origin: SIMD3<Double>(o), dir: SIMD3<Double>(d))
    }

    /// A round blue liquid-glass gizmo knob (the app's gizmo material — 109's blue frost),
    /// with a generous ~48 pt hit target so a fingertip owns it over the orbit camera.
    @ViewBuilder private func gizmoCircleKnob(active: Bool, size: CGFloat,
                                              @ViewBuilder glyph: () -> some View) -> some View {
        glyph()
            .frame(width: size, height: size)
            .liquidGlass(LiquidGlass.Tint.frost(DS.Color.accent, intensity: active ? 0.85 : 0.55),
                         in: Circle(), specular: active ? 1.3 : 1)
            .shadow(color: DS.Color.accent.color.opacity(0.5), radius: 4)
            .contentShape(Circle().inset(by: -12))
    }

 // MARK: gravity DIRECTION widget (2026-07-26; round 2 2026-07-27) — point which way is down

    /// The arrow's model-space length. ROUND 2 item 3: SHORT + THICK — a stubby direction
    /// indicator, not the old long thin line that ran well past the part (was radius × 1.25).
    /// Scaled off the model radius so it still fits a small bolt and a large bracket.
    private var gravityGizmoLength: Double { Double(viewerMesh?.bounds.radius ?? 1) * 0.55 }

    /// The direction the setup arrow points RIGHT NOW: the live draft while pointing, else
    /// the current gravity, else model-space down (−Y) as the sensible first guess.
    private var effectiveGravityDraft: SIMD3<Float> {
        gravityDraft ?? force.gravity ?? SIMD3<Float>(0, -1, 0)
    }

    /// The arrow's BASE position RIGHT NOW (round 2 item 2): the live draft while dragging the
    /// base gizmo, else the stored (purely-visual) base, else the mesh centre.
    private var effectiveGravityBase: SIMD3<Float> {
        gravityBaseDraft ?? force.gravityBaseModel ?? meshCenter
    }

    /// The magnet pull radius (model mm) for the arrow base: the base sticks to the nearest
    /// face within this distance, and releases when dragged farther for free placement.
    private var gravityBaseMagnetDist: Float { (viewerMesh?.bounds.radius ?? 1) * 0.4 }

    /// The part's own flat-face normals as snap targets for the pointing tip (round 2 item 1) —
    /// the real fix for "Gravity set · custom": gravity snaps perpendicular to the part's actual
    /// faces, however the import is oriented, not to the model axes. Empty (→ axes only) when the
    /// mesh carries no face ids.
    private var gravityFaceSnapTargets: [GravityDirectionGizmo.SnapTarget] {
        guard let mesh = viewerMesh else { return [] }
        return GravityDirectionGizmo.faceSnapTargets(mesh.flatFaceNormals().map { SIMD3<Double>($0.normal) })
    }

    /// The axis label for the CURRENT gravity ("−Y", "+Z", …) or "custom" for an off-axis
    /// direction — shown on the persistent chip so the set direction reads at a glance.
    /// A near-zero tolerance so only an exactly-snapped direction earns an axis label.
    private var gravityDirectionLabel: String {
        guard let g = force.gravity else { return "custom" }
        return GravityDirectionGizmo.snap(SIMD3<Double>(g), toleranceDeg: 0.25).label ?? "custom"
    }

    /// Draw the stubby gravity arrow (base → tip along `direction`) into the stage, using the
    /// SAME projection + settle as every other overlay so it tracks the part. The tail is the
    /// (movable) base; the head is a short hop away — thick, so it reads as a solid indicator.
    private func gravityArrowCanvas(_ proj: CameraProjection, base: SIMD3<Float>,
                                    direction: SIMD3<Float>, color: Color) -> some View {
        Canvas { ctx, _ in
            let tip = SIMD3<Float>(GravityDirectionGizmo.tip(center: SIMD3<Double>(base),
                                                             direction: SIMD3<Double>(direction),
                                                             length: gravityGizmoLength))
            guard let a = proj.project(settledWorld(base)), let b = proj.project(settledWorld(tip))
            else { return }
            // Thick widths (item 3): a stubby solid arrow, distinct from the slim force arrows.
            drawArrow(ctx, from: a, to: b, color: color, w0: 11, w1: 5, headMax: 30)
        }
        .allowsHitTesting(false)
    }

    /// The INTERACTIVE pointing widget (setup / "being edited" phase — round 2 item 4: it is NOT
    /// drawn otherwise). A draggable, snapping arrow: the TIP points which way is down (snaps to
    /// the part's own faces, item 1) and the BASE is moved by the transform gizmo, magnetically
    /// sticking to a face (item 2, `gravityBaseGizmoOverlay`). The magnet toggle, "Snapped to"
    /// badge and confirm check sit by the tip. Face-tap still sets gravity (`handlePick`).
    @ViewBuilder private var gravityDirectionOverlay: some View {
        if let proj = projection {
            let dir = effectiveGravityDraft
            let base = effectiveGravityBase
            let tipModel = SIMD3<Double>(GravityDirectionGizmo.tip(center: SIMD3<Double>(base),
                                                                   direction: SIMD3<Double>(dir),
                                                                   length: gravityGizmoLength))
            ZStack(alignment: .topLeading) {
                gravityArrowCanvas(proj, base: base, direction: dir, color: DS.Color.accent.color)
                // The draggable tip knob (gesture bound to the knob BEFORE `.position` — the
                // camera-non-fighting rule, so empty space still orbits and a face still taps).
                gizmoAt(proj, tipModel) {
                    gizmoCircleKnob(active: draggingGravity, size: 32) {
                        Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .gesture(gravityDragGesture())
                    .accessibilityLabel("Drag to point gravity")
                }
                if let pt = proj.project(settledWorld(SIMD3<Float>(tipModel))) {
                    gravitySetupCluster.position(x: pt.x, y: pt.y - 54)
                    if let label = gravitySnapLabel {
                        gravitySnapBadge(label).position(x: pt.x, y: pt.y + 40)
                    }
                }
            }
            .coordinateSpace(name: Self.gizmoStageSpace)
        }
    }

    /// The base-mover: the SAME 3D liquid-glass TRANSFORM GIZMO the manual primitives use
    /// (`TransformGizmoMetalView` + `TransformGizmo.pick`), floated at the arrow's base. A drag
    /// SDF-picks a translate handle and slides the base (magnetically attaching to the nearest
    /// face); a miss orbits the camera. This is a SEPARATE overlay from the pointing arrow above,
    /// so the two coexist without fighting (BAR V7): the arrow canvas is non-interactive, the tip
    /// knob only aims, and this gizmo only moves the base. Setup-phase only (item 4).
    @ViewBuilder private var gravityBaseGizmoOverlay: some View {
        #if canImport(MetalKit)
        if let proj = projection,
           let center = proj.project(settledWorld(effectiveGravityBase)) {
            let box = Self.gizmoBoxSize
            ZStack(alignment: .topLeading) {
                TransformGizmoMetalView(camera: cameraModel, settle: gizmoSettleMatrix,
                                        activeId: gravityBaseActiveId)
                    .frame(width: box, height: box)
                    .allowsHitTesting(false)
                    .position(center)
                Color.clear
                    .frame(width: box, height: box)
                    .contentShape(Rectangle())
                    .gesture(gravityBaseGizmoGesture(proj, boxCenter: center, boxSize: box))
                    .position(center)
            }
            .coordinateSpace(name: Self.gizmoStageSpace)
        }
        #else
        EmptyView()
        #endif
    }

    /// The magnet toggle + confirm check above the arrow tip (matches `gizmoActionCluster`).
    /// The one magnet governs BOTH the tip's face-snap and the base's face-attach.
    private var gravitySetupCluster: some View {
        HStack(spacing: DS.Space.s) {
            Button { gravitySnap.toggle() } label: {
                gizmoCircleKnob(active: gravitySnap, size: 26) {
                    Image(systemName: "scope").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(gravitySnap ? 1 : 0.4))
                }
            }.buttonStyle(.plain)
                .accessibilityLabel(gravitySnap ? "Face snapping on" : "Face snapping off")

            Button { commitGravityDraft() } label: {
                gizmoCircleKnob(active: true, size: 32) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }.buttonStyle(.plain).accessibilityLabel("Set this as down")
        }
    }

    /// "Snapped to −Y" / "Snapped to face" — the handoff requires the UI to STATE what it
    /// snapped to.
    private func gravitySnapBadge(_ label: String) -> some View {
        Text("Snapped to \(label)")
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(Capsule().fill(DS.Color.accent.color.opacity(0.9)))
            .fixedSize()
            .accessibilityLabel("Snapped to \(label)")
    }

    /// Commit the pending pointed direction as gravity via `setGravity(direction:)` — the same
    /// stored `gravity` vector a face tap writes (BAR V1) — AND the purely-visual arrow base via
    /// `setGravityBase`. Mutating `force` republishes `ProjectModel`, so the debounced round-6
    /// UndoHistory records the whole gravity edit as ONE step (BAR V3/V5).
    private func commitGravityDraft() {
        force.setGravity(direction: effectiveGravityDraft)
        force.setGravityBase(effectiveGravityBase)
        gravityDraft = nil
        gravityBaseDraft = nil
        gravitySnapLabel = nil
        selection.clearActive()
        model.toast = "Gravity set — the part now rests the way it will in real life"
    }

    /// One drag of the arrow tip: build the pure-math grab context on the first frame (into
    /// `@State` so it survives the body churn), resolve each frame to a pointed direction, then
    /// snap to the nearest FACE NORMAL (or principal axis) when the magnet is on (item 1). Haptics
    /// on grab / snap / release; the snap label drives the badge. Nothing is committed until ✓.
    private func gravityDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: CoordinateSpace.named(Self.gizmoStageSpace))
            .onChanged { v in
                guard let proj = projection, let ray = modelRay(proj, at: v.location) else { return }
                if !draggingGravity {
                    draggingGravity = true
                    gravityDrag = GravityDirectionGizmo.Drag(
                        startDirection: SIMD3<Double>(effectiveGravityDraft),
                        center: SIMD3<Double>(effectiveGravityBase),
                        length: gravityGizmoLength,
                        grab: ray, viewDir: ray.dir)
                    ClearanceHaptics.grab()
                }
                guard let drag = gravityDrag else { return }
                var dir = drag.resolve(currentRay: ray)
                var label: String?
                if gravitySnap {
                    let s = GravityDirectionGizmo.snap(dir, extraTargets: gravityFaceSnapTargets)
                    dir = s.dir; label = s.label
                }
                if label != gravitySnapLabel {
                    if label != nil { ClearanceHaptics.detent() }
                    gravitySnapLabel = label
                }
                gravityDraft = SIMD3<Float>(dir)
            }
            .onEnded { _ in
                draggingGravity = false
                gravityDrag = nil
                ClearanceHaptics.release()
            }
    }

    /// The gravity gizmo's ONE gesture: on grab, SDF-pick a handle; then either RIBBON → rotate the
    /// gravity DIRECTION (aim the arrow, snapping to face normals), ARM/PLANE/HUB → slide the base
    /// (untouched `PrimitiveGizmo` translate → magnetic face-attach), or on a miss orbit — so the
    /// box never fights the camera (the manual-primitive gizmo's rule). Both are live drafts; ✓
    /// commits. (Ribbons used to be dead here — the base gesture read only `.center`; 2026-07-27.)
    private func gravityBaseGizmoGesture(_ proj: CameraProjection,
                                         boxCenter: CGPoint, boxSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: CoordinateSpace.named(Self.gizmoStageSpace))
            .onChanged { v in
                if gravityBaseDrag == nil && !gravityBaseOrbiting && gravityBaseDragLast == nil {
                    let local = CGPoint(x: v.startLocation.x - (boxCenter.x - boxSize / 2),
                                        y: v.startLocation.y - (boxCenter.y - boxSize / 2))
                    if let hit = TransformGizmo.pick(point: local,
                                                     in: CGSize(width: boxSize, height: boxSize),
                                                     rotation: gizmoRotation),
                       let ray = modelRay(proj, at: v.location) {
                        gravityBaseActiveId = gizmoActiveIdValue(hit)
                        // startAxis = the CURRENT gravity direction, so a RIBBON grab rotates
                        // the arrow's aim (a ribbon `resolve` turns `startAxis` about the ribbon
                        // axis). Arms/plane/hub ignore startAxis and slide the base as before.
                        gravityBaseDrag = PrimitiveGizmo.Drag(handle: gizmoHandle(for: hit, orientation: matrix_identity_float3x3),
                                                              startCenter: SIMD3<Double>(effectiveGravityBase),
                                                              startAxis: SIMD3<Double>(effectiveGravityDraft),
                                                              grab: ray, viewDir: ray.dir)
                        ClearanceHaptics.grab()
                    } else {
                        gravityBaseOrbiting = true
                    }
                    gravityBaseDragLast = v.location
                }
                if gravityBaseOrbiting {
                    let last = gravityBaseDragLast ?? v.startLocation
                    cameraModel.orbit(dx: Float(v.location.x - last.x), dy: Float(v.location.y - last.y))
                    gravityBaseDragLast = v.location
                    return
                }
                guard let drag = gravityBaseDrag, let ray = modelRay(proj, at: v.location) else { return }
                let out = drag.resolve(currentRay: ray)
                // A RIBBON rotates the gravity DIRECTION (aims the arrow) about that axis — the
                // same affordance the manual-primitive gizmo uses; the arms/plane/hub keep sliding
                // the base. Snaps to the part's own face normals like the tip drag (item 1).
                if case .rotate = drag.handle {
                    var dir = SIMD3<Float>(out.axis)
                    var label: String?
                    if gravitySnap {
                        let s = GravityDirectionGizmo.snap(SIMD3<Double>(dir), extraTargets: gravityFaceSnapTargets)
                        dir = SIMD3<Float>(s.dir); label = s.label
                    }
                    if label != gravitySnapLabel {
                        if label != nil { ClearanceHaptics.detent() }
                        gravitySnapLabel = label
                    }
                    gravityDraft = dir
                    return
                }
                var p = SIMD3<Float>(out.center)
                var snapped = false
                if gravitySnap, let mesh = viewerMesh,
                   let hit = mesh.nearestSurfacePoint(to: p, within: gravityBaseMagnetDist) {
                    p = hit.point; snapped = true          // magnetically attach to the face
                }
                if snapped != gravityBaseSnapped {
                    if snapped { ClearanceHaptics.detent() }
                    gravityBaseSnapped = snapped
                }
                gravityBaseDraft = p
            }
            .onEnded { _ in
                gravityBaseDrag = nil
                gravityBaseOrbiting = false
                gravityBaseDragLast = nil
                gravityBaseActiveId = -1
                gravityBaseSnapped = false
                ClearanceHaptics.release()
            }
    }

    /// ★ THE REGIONS SURFACE (task 2026-08-14-face-regions). Bound straight to
    /// the project's own region model and selection, so a union made here is the
    /// union the run emits — no second store, no copy to keep in sync.
    private var regionsPanelOverlay: some View {
        FaceRegionSheet(model: Binding(get: { project.faceRegions },
                                       set: { project.faceRegions = $0 }),
                        selection: Binding(get: { project.selection },
                                           set: { project.selection = $0 }),
                        selectedRegion: $regionTapTarget,
                        mesh: viewerMesh,
                        resolution: project.quality.resolution,
                        onChange: { project.refreshFaceRegionDrift() },
                        onClose: { regionsOpen = false })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 320)
            .padding(.bottom, 96)
    }

    // MARK: left Selections panel (design) with the kg/lbs toggle

    /// ★ THE PANEL AND THE PREVIEW NOTICE, AS ONE COLUMN (maintainer,
    /// 2026-08-17: "'Lattice Preview' notice should be just below the Selections
    /// modal, attached to the bottom edge, but off it. Currently it is in the
    /// middle of the modal").
    ///
    /// ★ IT WAS A SCREEN-SPACE GUESS. The notice lived in `latticePreviewOverlay`
    /// with `.padding(.top, DS.Space.xl6)` — a fixed drop from the top bar that
    /// happened to land on the panel's rows, exactly like the Struts chip did
    /// before it moved inside. Stacking it UNDER the card in the same column
    /// makes "attached to the bottom edge, but off it" a property of the layout
    /// instead of a number that has to keep being right.
    private var selectionsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // ★ ABOVE THE CARD WHEN MINIMIZED (maintainer, 2026-08-17: "The
            // 'lattice preview' notification should go *on top* of the minimized
            // selections modal when it is in the bottom left corner"). Below it
            // when the panel is open, where "under the modal" is what reads.
            if selectionsCollapsed { latticePreviewNotice }
            selectionsLibraryCard
            if !selectionsCollapsed { latticePreviewNotice }
        }
        .modifier(WorkspacePanelPlacement(minimized: selectionsCollapsed))
    }

    /// The honesty banner for the strut layer — one row, shown only while that
    /// layer is actually up.
    @ViewBuilder private var latticePreviewNotice: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showStrutPreview, let scene = strutScene {
                Text(scene.preview.previewLabel)
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.vertical, DS.Space.xs)
                    .padding(.horizontal, DS.Space.s)
                    .background(Capsule().fill(DS.Surface.panel.color.opacity(0.9))
                        .overlay(Capsule().strokeBorder(
                            DS.Color.strokePanel.color, lineWidth: 1)))
                    .accessibilityIdentifier("lattice-preview-notice")
            }
        }
    }

    /// ★ THE NAME AVOIDS A PREFIX COLLISION, DELIBERATELY. Three separate guards
    /// assert "exactly ONE selections panel definition exists" by COUNTING a
    /// source substring, so any helper whose name begins with the panel's would
    /// trip all three while the invariant they protect — no second selection UX —
    /// was never in danger. Renaming the helper is the honest fix; editing three
    /// real guards to accommodate a private helper is not.
    ///
    /// (And the first cut of this very comment QUOTED the searched string, which
    /// tripped the same guards a second time. A source-text guard counts
    /// comments too.)
    private var selectionsLibraryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // Tap the header to collapse/expand.
                Button { selectionsCollapsed.toggle() } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: selectionsCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                        Text("Selections").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                            .foregroundStyle(DS.Color.textPrimary.color)
                        if selectionsCollapsed, !selection.isEmpty {
                            Text("\(selection.groups.count)").dsStyle(DS.TypeScale.footnote)
                                .foregroundStyle(DS.Color.textTertiary.color)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if !selectionsCollapsed {
                    // ★ REGIONS (task 2026-08-14-face-regions). Combine faces
                    // into one selection, and split one into pieces.
                    Button { regionsOpen.toggle() } label: {
                        Image(systemName: "square.on.square.dashed")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle((regionsOpen ? DS.Color.accent
                                              : DS.Color.textTertiary).color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Regions")
                    keepClearQuickAction
                    unitToggle
                }
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)

            if !selectionsCollapsed {
                Divider().overlay(DS.Color.strokeSubtle.color)
                // Sync is per-row now (device round 3, items 5+6): the checkbox rides EACH
                // keep-clear row (see `clearanceEditor`), not a single panel-wide control, so the
                // 109 global toggle and its round-2 on-model checkbox are both gone from here.
                if selection.isEmpty {
                    Text("Tap faces on the model to select them — a chip asks whether they’re an **anchor** or a **load**.")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(DS.Space.xl)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(selection.groups) { g in groupRow(g) }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                // ★ THE STRUTS TOGGLE, INSIDE THE PANEL, BOTTOM-RIGHT (maintainer,
                // 2026-08-14). It used to float over these rows from
                // `latticePreviewOverlay`. It is a lattice-stage affordance, so it
                // appears with the lattice controls and nowhere else.
                if visible.latticeControls, project.lattice.enabled {
                    HStack {
                        Spacer(minLength: 0)
                        strutPreviewChip
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.m)
                    .padding(.top, DS.Space.s)
                }
            }
        }
        // §6/§3a: the ONE panel width every page uses, so the lattice stage and the
        // TO stage are not "similar" — they are the same panel.
        .frame(width: PageChrome.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        // Leave the locked group by tapping ELSEWHERE in the Selections area
        // (handoff item 3). Rows + controls consume their own taps (child gestures
        // win), so this only fires on empty panel space: it closes any open rename
        // and unlocks the active group. Scoped to the 300-wide panel box — attached
        // BEFORE the screen-filling frame below, so it never captures the whole view.
        .contentShape(Rectangle())
        .onTapGesture { leaveGroupEditing() }
        // One animation keyed on the collapse state so the header + body move
        // together (not at different speeds).
        .animation(DS.Motion.emphasized, value: selectionsCollapsed)
        // ★ §6 — THE MODAL GEOMETRY STANDARD lives on the COLUMN now
        // (`selectionsPanel` above), not on this card, so the preview notice
        // travels with the panel instead of being placed against the screen.
    }

    /// The §6 placement, in a modifier so the panel body does not have to hold a
    /// `GeometryReader` of its own.
    private struct WorkspacePanelPlacement: ViewModifier {
        /// ★ MINIMIZED ⇒ BOTTOM-LEFT (maintainer, 2026-08-17). One placement for
        /// the ONE Selections panel, so both of its mount sites — the workspace
        /// and the lattice page's library — move together by construction.
        let minimized: Bool
        func body(content: Content) -> some View {
            GeometryReader { geo in
                content.pageLeftModal(canvasHeight: geo.size.height,
                                      minimized: minimized,
                                      canvasWidth: geo.size.width)
            }
        }
    }

    /// The Selections-header "Keep clear" quick-action (keep-clear v2): affixes /
    /// removes the keep-clear attribute on the ACTIVE group, alongside the role
    /// actions the in-scene chip offers. Shown only when a group is active on a
    /// face-selectable (STEP) part.
    @ViewBuilder private var keepClearQuickAction: some View {
        if let g = activeGroup, let mesh = viewerMesh, !mesh.faceGeometry.isEmpty {
            let on = project.keepClearIsOn(g)
            Button {
                force.setKeepClear(g.id, on: !on, autoDefault: project.keepClearAutoDefault(g))
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "nosign").font(.system(size: 11, weight: .bold))
                    Text("Keep clear").dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                }
                .foregroundStyle(on ? Self.clearanceTint : DS.Color.textTertiary.color)
                .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                .background(Capsule().fill(on ? Self.clearanceTint.opacity(0.18) : DS.Color.fillSelected.color))
            }
            .buttonStyle(.plain)
            .help("Toggle Keep clear on the active selection")
        }
    }

    private var unitToggle: some View {
        HStack(spacing: 2) {
            ForEach(WeightUnit.allCases, id: \.self) { u in
                Button { force.unit = u } label: {
                    Text(u.label)
                        .dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
                        .foregroundStyle((u == force.unit ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                        .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                        .background(Capsule().fill(u == force.unit ? DS.Color.fillSelected.color : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.Color.background.opacity(0.35).color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
    }

    private func groupRow(_ g: SelectionGroup) -> some View {
        let active = g.id == selection.activeGroupID
        let tint = force.tint(for: g)
        return VStack(alignment: .trailing, spacing: 5) {
          HStack(alignment: .top, spacing: DS.Space.s) {
            // Tap the swatch to recolor the group — a row of colour swatches.
            Button { recoloringGroup = g.id } label: {
                RoundedRectangle(cornerRadius: 4).fill(tint.color)
                    .frame(width: 14, height: 14)
                    .shadow(color: tint.opacity(0.4).color, radius: 4)
                    .padding(.top, 3)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { recoloringGroup == g.id },
                                          set: { if !$0 { recoloringGroup = nil } })) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(Array(DS.Color.groupPalette.enumerated()), id: \.offset) { idx, c in
                        Button { selection.setColorIndex(g.id, idx); recoloringGroup = nil } label: {
                            Circle().fill(c.color).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(
                                    g.colorIndex == idx ? DS.Color.textPrimary.color : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DS.Space.ml)
            }
            VStack(alignment: .leading, spacing: 3) {
                groupNameControl(g)
                HStack(spacing: DS.Space.s) {
                    Text(force.panelKindLabel(for: g.id))
                        .dsStyle(DS.TypeScale.footnote)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                    keepClearAffixToggle(g)
                    protectAffixToggle(g)   // handoff 124 — the Protect affix
                }
                if loadGroupMayNotRegister(g), let h = voxelSpacingMM {
                    // Sub-voxel load face (099 D2): the load may tag no voxels at
                    // this resolution, so flag it in plain English. A warning, not a
                    // verdict — only the voxelizer knows for sure.
                    Label(VoxelFit.badgeText(qualityTitle: project.quality.title, spacingMM: h),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: DS.TypeScale.footnote.size))
                        .foregroundStyle(DS.Color.warning.color)
                        .help(VoxelFit.warningText(qualityTitle: project.quality.title, spacingMM: h))
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                // Round-2 L23/M2: NO destructive affordance in the lattice context —
                // groups and faces can be removed only back on the TO page.
                if !showLatticePage, stage == .topology {
                    Button { removeGroup(g.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
                    }
                    .buttonStyle(.plain)
                }
                // "+ a primitive" — revealed once the group is LOCKED IN (active).
                // Tapping asks CYLINDER or PLANE (handoff item 1). §2b: group
                // primitives are a TO-page affordance, so the way to ADD one is a
                // TO-page affordance too.
                if active, visible.groupPrimitives {
                    Button { addingPrimitiveGroup = g.id } label: {
                        Label("primitive", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Self.clearanceTint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("add-primitive-\(g.id.uuidString)")
                }
            }
          }
          // ★ WHAT THIS ROW CONTAINS IS THE STAGE'S DECISION, NOT THIS FUNCTION'S
          // (task 2026-08-14 §1a/§2). The TO page's row is the keep-clear editor
          // and nothing else: no role chips, no slab row, no per-region readout.
          // A section that is not in `rowSections` is not BUILT.
          ForEach(visible.rowSections, id: \.rawValue) { section in
              switch section {
              case .clearanceEditor:
                  // Item 4: the clearance chips (+ per-row Sync box) sit right-aligned
                  // to the row's trailing edge, directly below the trash icon.
                  clearanceEditor(g)
              case .latticeSummary:
                  latticeSummaryRow(g)
              case .latticeDrawer:
                  // ★ NOT BUILT — no stage lists this section any more
                  // (maintainer, 2026-08-17: per FACE only). The case survives so
                  // the switch stays exhaustive and so a future stage cannot
                  // re-enable it by accident without coming through here.
                  EmptyView()
              case .latticePrimitiveRows:
                  if latticeDisclosure.isExpanded(g.id.uuidString) { latticePrimitiveRows(g) }
              }
          }
        }
        .padding(.vertical, 11).padding(.leading, DS.Space.l).padding(.trailing, DS.Space.m)
        .background(active ? DS.Color.fillSubtle.color : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(active ? tint.color : .clear).frame(width: 3)
        }
        .contentShape(Rectangle())
        // Tapping the group BODY LOCKS INTO it (handoff item 3) — it NEVER starts a
        // rename (handoff item 4); rename fires only from `groupNameControl`. If a
        // different group's rename was open, tapping away commits + closes it.
        .onTapGesture {
            if renamingGroup != nil, renamingGroup != g.id { renamingGroup = nil }
            selection.setActive(g.id)
            // T2: tapping the group IN THE LIBRARY is one of the three explicit
            // paths that reveal its primitive chips.
            chipsRevealedGroup = g.id
        }
        .confirmationDialog("Add a primitive", isPresented: Binding(
            get: { addingPrimitiveGroup == g.id },
            set: { if !$0 { addingPrimitiveGroup = nil } })) {
            // A freshly-placed primitive becomes the gizmo target so the user can move it
            // straight away (DEFECT 2: PR 190 had no handles to grab it by).
            Button("Cylinder") { selectNewPrimitive(project.addManualPrimitive(.bolt, to: g.id), in: g.id) }
            Button("Plane") { selectNewPrimitive(project.addManualPrimitive(.face, to: g.id), in: g.id) }
            Button("Cancel", role: .cancel) { addingPrimitiveGroup = nil }
        } message: {
            Text("A keep-out the finder missed. Place it, then move it onto the part with magnetic detents.")
        }
        .overlay(alignment: .bottom) { Divider().overlay(DS.Color.strokeSubtle.color) }
    }

    /// The group NAME control (handoff item 4): a plain label by default, so tapping
    /// the group BODY only locks in — never edits. Tapping the NAME both locks the
    /// group in AND opens an inline rename field; committing or tapping elsewhere
    /// closes it. This is the ONLY path that starts a rename.
    @ViewBuilder private func groupNameControl(_ g: SelectionGroup) -> some View {
        let editing = renamingGroup == g.id
        if editing {
            TextField("Group", text: binding(for: g))
                .textFieldStyle(.plain)
                .font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .focused($renameFieldFocused)
                .submitLabel(.done)
                .onSubmit { renamingGroup = nil }
                .onAppear { renameFieldFocused = true }
                .accessibilityIdentifier("group-name-field-\(g.id.uuidString)")
        } else {
            Text(g.name.isEmpty ? "Group" : g.name)
                .font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.setActive(g.id)
                    renamingGroup = g.id
                    chipsRevealedGroup = g.id   // T2: a name tap is a group tap too
                }
                .accessibilityIdentifier("group-name-\(g.id.uuidString)")
        }
    }

    private func binding(for g: SelectionGroup) -> Binding<String> {
        Binding(get: { selection.groups.first { $0.id == g.id }?.name ?? g.name },
                set: { selection.rename(g.id, to: $0) })
    }

    /// A group's OWN keep-clear faces (bores + explicit slabs) — the WITHIN-group scope the Sync
    /// flag couples (round-4 item 3). ForceModel can't classify geometry, so the view supplies them.
    private func groupClearanceFaces(_ g: SelectionGroup) -> [FaceID] {
        // T5: the ONE shared listing rule (suppression filter included).
        project.listedClearanceFaces(g)
    }

    /// The PER-GROUP "Sync" checkbox (round-4 item 3), always enabled, default checked. Toggling
    /// couples/uncouples the group's OWN bores (within-group scope), never other groups.
    private func clearanceSyncRowCheckbox(_ g: SelectionGroup) -> some View {
        ClearanceSyncRowCheckbox(isOn: force.isClearanceSynced(g.id)) { on in
            force.setClearanceSynced(g.id, on, boreFaces: groupClearanceFaces(g))
        }
    }

    /// One keep-clear primitive of a group — a single cleared face, classified by
    /// geometry (a curved face is a `bore`, an explicit planar face is a `plane`), with
    /// its exact bore radius for the "Auto · N mm" labels. `id` is the face id, so
    /// SwiftUI keeps one row per primitive.
    private struct ClearancePrimitive: Identifiable, Equatable {
        let id: FaceID
        let isBore: Bool
        let radiusMM: Double?
        var kind: ClearanceChipKind { isBore ? .bore : .plane }
    }

    /// A group's keep-clear primitives, in selection order — the same faces
    /// `resolvedClearances()` freezes (bores always; planes only when the affix is
    /// explicit, since Auto affixes bores only). Empty when keep-clear is off or the
    /// part has no B-rep geometry.
    private func clearancePrimitives(_ g: SelectionGroup) -> [ClearancePrimitive] {
        guard let mesh = viewerMesh else { return [] }
        // Round-2 T5 root cause: the RENDERER and the RUN both skip a suppressed
        // face (`isClearanceFaceSuppressed`) — but this panel listing did not.
        // Converting an auto clearance to a manual primitive (the row's move icon)
        // suppresses the auto face AND adds the manual primitive, so the panel
        // listed BOTH: a second primitive where only one exists. The listing now
        // reads the ONE shared rule (`ProjectModel.listedClearanceFaces`).
        return project.listedClearanceFaces(g).map { f in
            let bore = FaceTopology.isFastenerBore(f, in: mesh)
            // A fastener bore is always a fitted cylinder, so `faceBoreRadius` is
            // never nil for a bore row — no blank "— mm Auto" (C2, handoff 2026-07-29).
            return ClearancePrimitive(id: f, isBore: bore, radiusMM: bore ? faceBoreRadius(f) : nil)
        }
    }

    /// The editable clearance numbers for a group whose keep-clear is on (keep-clear
    /// v2): bolt margin + axial for a bore, slab depth for a planar face. A field left
    /// at "Auto" shows the REAL geometry-derived suggestion (e.g. "Auto · 2.5 mm"),
    /// now that the bore radius crosses the bridge — no longer the bare word "auto".
    /// The 0-sentinel wire path is unchanged: an Auto field still sends 0 and the core
    /// re-derives it; any number the user types is exactly the number the run uses.
    ///
    /// Round-5 (Task A6 item 2): a group holding SEVERAL mixed primitives no longer
    /// crushes every chip into one wrapping HStack. Each primitive lists on its own
    /// line (kind label + its chips, right-aligned) and the row grows vertically; with
    /// Sync ON the row collapses to the ONE shared chip set plus a "N primitives ·
    /// synced" count. A lone primitive keeps the old single-line look.
    @ViewBuilder private func clearanceEditor(_ g: SelectionGroup) -> some View {
        // LOCKED IN (active) AND explicitly revealed (round-2 T2): the full editor —
        // every primitive on its own line with a "−" to delete it (auto OR manual),
        // plus the manual primitives (handoff group-editing items 2 + 3). The
        // reveal requires a tap on the primitive, one of its faces, or the group
        // row — a face tap that merely grew a selection no longer pops the chips
        // open under the finger. Otherwise: the compact summary.
        if g.id == selection.activeGroupID, chipsRevealedGroup == g.id {
            lockedClearanceEditor(g)
        } else {
            compactClearanceEditor(g)
        }
    }

    // MARK: ★ THE LATTICE STAGE'S GROUP ROW (task 2026-08-14 §3c/§4)
    //
    // Three sections, and the stage decides whether any of them exist:
    //   latticeSummaryRow      the COLLAPSED row (§4d) — the grams handed over and
    //                          the verdict as colour, plus the ALL/SOME/NONE
    //                          coverage the group now SHOWS instead of owning.
    //   latticeGroupDrawer     the drawer beneath it (§4a), headed by the
    //                          out-of-regime flag (§4c).
    //   latticePrimitiveRows   one row per primitive, each with its OWN lattice /
    //                          no-lattice and its OWN depth (§3c/§3d).

    /// ★ §4d — ONE THING COLLAPSED: the grams handed over, and the verdict as
    /// COLOUR. Tapping opens the drawer. Everything else is behind it.
    @ViewBuilder private func latticeSummaryRow(_ g: SelectionGroup) -> some View {
        let block = latticeRoleBlock(g)
        let open = latticeDisclosure.isExpanded(g.id.uuidString)
        let coverage = project.latticeCoverage(g)
        // ★ THE TOTAL AND THE COLOUR COME FROM THE FACES, NOT FROM A GROUP CARD
        // (maintainer, 2026-08-17). `latticeDrawer(g)` and its card are gone: the
        // grams are the SUM of what the latticed selectables hand over, and the
        // colour is the worst verdict among them. Both describe things that
        // exist; the group card described a slab no primitive owned.
        let cards = latticedSelectableCards(g)
        let handedOverG = cards.reduce(0.0) { $0 + $1.heldMassG }
        let collapsedValue = cards.isEmpty || handedOverG <= 0
            ? "—" : String(format: "%.1f g", handedOverG)
        let tint = latticeVerdictTint(
            LatticeFaceCardDerivation.partSummary(cards).verdict)
        HStack(spacing: DS.Space.s) {
            if let b = block {
                // ★ SAY WHY, IN FIVE WORDS (R7). Never a paragraph, never silence.
                Text(b.reason)
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Button {
                    latticeDisclosure.toggle(g.id.uuidString)
                    if !open { refreshLatticeFaceCards() }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Color.textTertiary.color)
                        // The group SUMMARY (§3c) — all / some / none, not a decision.
                        Text(coverage.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .padding(.vertical, 3).padding(.horizontal, DS.Space.xs)
                            .background(Capsule().fill(DS.Color.fillSelected.color))
                        Spacer(minLength: 0)
                        // ★ THE ONE NUMBER: what this group's latticed faces hand
                        // the lattice, summed.
                        Text(collapsedValue)
                            .dsStyle(DS.TypeScale.bodyStrong).monospacedDigit()
                            .foregroundStyle(tint.color)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lattice-summary-\(g.id.uuidString)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ★ §3(a) — THE BADGE RIDES THE COLLAPSED ROW. His words: "We shouldn't
        // have to expand the drawer to see all the data presented to know EXACTLY
        // how to fix any issue."
        if block == nil { latticeDiagnosisBadge(g) }
    }

    /// ★ §3 — THE BADGE AND ITS (i), on the collapsed row.
    ///
    /// The badge says what is wrong in plain words (§3d — "Out of regime" is
    /// jargon and meant nothing to him) and the (i) opens the pop-up that names
    /// EVERY failure with its number, its target and the fix with its value
    /// (§3b/§3c).
    @ViewBuilder private func latticeDiagnosisBadge(_ g: SelectionGroup) -> some View {
        let d = latticeDiagnosis(g)
        if let badge = d.badge {
            let tint = latticeVerdictTint(d.severity)
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button { diagnosisPopoverGroup = g.id } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How to fix this")
                .accessibilityIdentifier("lattice-diagnosis-info-\(g.id.uuidString)")
                .popover(isPresented: Binding(
                    get: { diagnosisPopoverGroup == g.id },
                    set: { if !$0 { diagnosisPopoverGroup = nil } })) {
                    latticeDiagnosisPopover(d)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint.color)
            .padding(.vertical, 4).padding(.horizontal, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(tint.opacity(0.16).color))
            .accessibilityIdentifier("lattice-diagnosis-\(g.id.uuidString)")
        }
    }

    /// ★ §3(b)/§3(e) — THE POP-UP: every failure, and it LEADS WITH THE FIX.
    private func latticeDiagnosisPopover(_ d: LatticeFaceDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(d.problems.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.what)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                    ForEach(p.fixes, id: \.self) { fix in
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(DS.Color.accent.color)
                            Text(fix)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                        }
                    }
                    Text(p.measured)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
        }
        .padding(DS.Space.ml)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityIdentifier("lattice-diagnosis-popover")
    }

    /// The diagnosis for one group, from its card plus core's own two floors.
    /// ★ THE GROUP'S BADGE, FROM ITS FACES (maintainer, 2026-08-17). It was built
    /// from `latticeFaceCards[g.id]` — the group card derived at `g.faces.first`,
    /// which is the fabrication he asked to be removed. It is now the union of
    /// the diagnoses of the selectables that are ACTUALLY latticed, so the badge
    /// describes things that exist and that a handle can move.
    private func latticeDiagnosis(_ g: SelectionGroup) -> LatticeFaceDiagnosis {
        let limits = TopOptKit.latticeLimits(topology: project.lattice.lattice.id)
        let nozzle = project.printParams.strutLineWidthMM
        let each = latticedSelectableCards(g).map {
            LatticeFaceDiagnosis.of(card: $0,
                                    cellsPerMemberFloor: limits.minCellsPerMember,
                                    nozzleWidthMM: nozzle)
        }
        return LatticeFaceDiagnosis.merged(each)
    }

    /// The cards for the selectables in `g` that carry a lattice role — the only
    /// ones whose regime a badge or a total may speak for. A selectable set to
    /// Solid or Off has no lattice to certify and must not colour the group.
    private func latticedSelectableCards(_ g: SelectionGroup) -> [LatticeFaceCard] {
        project.latticeSelectableRefs(g).compactMap { ref in
            guard project.latticeSelectableRole(ref, in: g.id) == .include,
                  let c = latticeSelectableCards[ref.key] else { return nil }
            return c
        }
    }

    // ★ `latticeGroupDrawer` IS GONE (maintainer, 2026-08-17): "There is a 'per
    // Group' set of notes regarding the lattice that doesn't make sense. It
    // should be per face *only*." It rendered a cell, a density, a strut and a
    // cells-across derived at `g.faces.first` — one arbitrary face standing for
    // the whole group, at a depth no primitive owns and no handle drags. The
    // drawer layout below is unchanged and is still what every SELECTABLE row
    // opens; only the group's copy of it is removed. `WorkspaceStageVisibility
    // .rowSections` no longer lists `.latticeDrawer`, so it is not built.

    /// ★ THE ONE DRAWER LAYOUT. A group row and a selectable row render THIS —
    /// so "a region and a face behave identically" (bar R13) is a property of
    /// there being one view, not of two views being kept in step.
    /// The keypad's starting value for one row, parsed from the string the row
    /// already renders — "10.0 mm" ▸ 10.0, "27%" ▸ 27. Pure, so the parsing that
    /// the wrong-setter bug got away with is now assertable.
    static func latticeRowSeed(_ row: LatticeDrawerRow) -> Double {
        Double(row.value
            .replacingOccurrences(of: " mm", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
    }

    @ViewBuilder private func latticeDrawerBody<G: Gesture>(
        _ drawer: LatticeRegionDrawer, depthDrag: G, identifier: String,
        writeDepth: ((Double) -> Void)? = nil,
        // ★ THE DENSITY'S OWN SETTER (maintainer, 2026-08-17). It takes PERCENT,
        // because that is what the keypad shows and what the row renders; the
        // model and the job speak fractions, and the ONE conversion happens at
        // the call site, exactly as `sectorDensityRow` on the lattice page does.
        writeDensity: ((Double) -> Void)? = nil,
        // ★ THE IN-PLANE EXPAND'S SETTER (maintainer, 2026-08-17), in mm like
        // the depth — and separate from it, because they grow different axes.
        writeExpand: ((Double) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let head = drawer.headline {
                let tint = latticeVerdictTint(head.verdict)
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(head.verdict.label)
                        .font(.system(size: 11, weight: .heavy))
                    Text(head.text)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .opacity(0.85)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint.color)
                .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
                .background(RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .fill(tint.opacity(0.16).color))
            }
            ForEach(Array(drawer.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DS.Space.s) {
                    Text(row.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Color.textQuaternary.color)
                    Spacer(minLength: 0)
                    // ★ §4b — a DERIVED row gets no gesture and no control
                    // chrome: it is a fact, not a picker.
                    //
                    // ★ AND A MODIFIABLE ROW IS KEYED BY ITS OWN LABEL — PR 334's
                    // GAP 2, CLOSED. This branch used to attach `depthDrag` to
                    // EVERY modifiable row and hardcode the `-depth` identifier,
                    // which was safe only while "Depth" was the sole control. Now
                    // that "Per region" reveals a second one, the Density row
                    // would have inherited the DEPTH's drag and a duplicate id —
                    // a control that silently edits the wrong number. Each row
                    // gets its own slug, and only the depth gets the depth drag.
                    if row.modifiable {
                        let slug = row.label.lowercased()
                        let padKey = "\(identifier)-\(slug)"
                        // ★ THE SETTER IS THE ROW'S OWN (maintainer, 2026-08-17).
                        // One `writeDepth` used to serve every modifiable row, so
                        // the Density keypad wrote the depth. The row's `kind`
                        // chooses both the setter and the unit now.
                        let write: ((Double) -> Void)? =
                            row.kind == .density ? writeDensity
                            : row.kind == .expand ? writeExpand
                            : writeDepth
                        Text(row.value)
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .padding(.vertical, 3).padding(.horizontal, DS.Space.sm)
                            .background(Capsule().fill(DS.Color.fillSelected.color))
                            .contentShape(Rectangle())
                            .modifier(LatticeDrawerRowGesture(
                                isDepth: row.kind == .depth, drag: depthDrag))
                            // ★ §5 — AND IT TYPES. His rule, stated twice: "Any
                            // input MUST be selectable and a small numeric
                            // keyboard pop-up to input the number — NOT just touch
                            // inputs." A 0.05 mm-per-point scrub cannot land on a
                            // round number by finger. The drag stays as the coarse
                            // adjustment and writes through the same setter.
                            .onTapGesture { if write != nil { depthPadKey = padKey } }
                            .numberPad(Binding(get: { depthPadKey == padKey },
                                               set: { if !$0 { depthPadKey = nil } }),
                                       // ★ THE ROW'S OWN UNIT. "DENSITY 35 mm"
                                       // is what the shared-setter bug looked
                                       // like on screen.
                                       config: .init(title: row.label,
                                                     unit: row.unit,
                                                     allowsDecimal: true),
                                       // …and its own seed: the depth reads
                                       // "10.0 mm", the density reads "27%".
                                       seed: Self.latticeRowSeed(row)) { v in
                                guard let v, let write else { return }
                                write(v)
                            }
                            .accessibilityIdentifier(padKey)
                    } else {
                        Text(row.value)
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                }
            }
            if drawer.held {
                // ★ THE BARRIER, NAMED. Protect + lattice is ONE slab (§1c of the
                // barrier task, unchanged).
                Label("held", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
        }
        .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
            .fill(DS.Color.fillSubtle.color))
        .accessibilityIdentifier(identifier)
    }

    /// ★ PR 334's GAP 2, as a type. Only the DEPTH row carries the depth drag;
    /// every other modifiable row (today: Density, under "Per region") is a
    /// tappable control with its own identifier and no inherited gesture.
    private struct LatticeDrawerRowGesture<G: Gesture>: ViewModifier {
        let isDepth: Bool
        let drag: G
        func body(content: Content) -> some View {
            if isDepth { content.gesture(drag) } else { content }
        }
    }

    /// ★ §3c — ONE ROW PER SELECTABLE, each with its own lattice / no-lattice.
    /// "Otherwise, what the fuck are they doing?" — they decide now, and since PR
    /// 331 a REGION is one of them and behaves identically (bar R13).
    @ViewBuilder private func latticePrimitiveRows(_ g: SelectionGroup) -> some View {
        let block = latticeRoleBlock(g)
        if block == nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(project.latticeSelectableRefs(g), id: \.key) { ref in
                    latticePrimitiveRow(g, ref)
                    // ★ §4 (the interrupt's §2b) — THE DRAWER OPENS BENEATH A
                    // REGION ROW TOO, through the SAME disclosure the row's
                    // chevron writes. For a region that bit is PR 331's
                    // `collapsed`, so expanding the row reveals its numbers AND
                    // its children at once — which is what §5(b) describes a
                    // deliberate expand doing, and it is one mechanism, not two.
                    if latticeDisclosure.isExpanded(ref, regions: project.faceRegions) {
                        latticeSelectableDrawer(g, ref)
                        // ★ §1(a) — THE FACES, AS CHILDREN OF THE REGION. They
                        // are not rows of their own any more (see
                        // `latticeSelectableRefs`); they appear here, under the
                        // region that owns them, and only when it is open.
                        if let rid = ref.regionID { latticeRegionFaceChildren(rid) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ★ §1(b) — A FACE INSIDE A REGION INHERITS AND SHOWS NO CHIPS OF ITS OWN.
    ///
    /// Deliberately not a `latticePrimitiveRow`: no Lattice/Solid/Off, no depth
    /// pill, no disclosure. It is a LIST OF WHAT IS IN THE REGION — the answer to
    /// "which faces did my filter actually catch?" — and giving it controls would
    /// rebuild the twenty-three-row page one level down.
    @ViewBuilder private func latticeRegionFaceChildren(_ rid: RegionID) -> some View {
        let faces = project.latticeRegionMemberFaces(rid)
        if !faces.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(faces, id: \.self) { f in
                    HStack(spacing: DS.Space.xs) {
                        // A leader dot, so a child reads as belonging to the row
                        // above it rather than as a row that lost its controls.
                        Circle().fill(DS.Color.textQuaternary.color)
                            .frame(width: 3, height: 3)
                        Text("Face \(project.runFaceID(f))")
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(DS.Color.textQuaternary.color)
                        Spacer(minLength: 0)
                    }
                    .accessibilityIdentifier("lattice-region-child-\(rid)-\(f)")
                }
            }
            .padding(.leading, DS.Space.xl)
            .padding(.top, 2)
            .accessibilityIdentifier("lattice-region-children-\(rid)")
        }
    }

    private func latticePrimitiveRow(_ g: SelectionGroup,
                                     _ ref: LatticeSelectableRef) -> some View {
        let role = project.latticeSelectableRole(ref, in: g.id)
        let dimmed = latticeRowIsBelowTheSmallFaceFloor(ref)
        return HStack(spacing: DS.Space.xs) {
            // ★ R12 — THE ONE DISCLOSURE. For a REGION this chevron writes PR
            // 331's own `FaceRegion.collapsed`, the same field the Regions sheet
            // writes, so the two lists can never disagree about whether a split
            // is open — and expanding reveals this row's numbers and its children
            // together. For a face or a primitive it writes the same
            // `LatticeRowDisclosure`. One type, one call, no second state.
            Button {
                latticeDisclosure.toggle(ref, regions: &project.faceRegions)
            } label: {
                Image(systemName: latticeDisclosure.isExpanded(
                        ref, regions: project.faceRegions)
                      ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lattice-row-disclose-\(ref.key)")
            Text(latticePrimitiveName(ref))
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Color.textTertiary.color)
            // ★ THE ONE HONEST DIFFERENCE (the interrupt's §3). The choice is
            // CAPTURED, and the row says the run will freeze this region without
            // latticing it — core's `lattice.regions` are geometry predicates and
            // a region is a voxel set (PR 331 §6). Three words, not silence.
            if !ref.latticeReachesTheRun, role != nil {
                Text(Self.latticeRegionNotConsumed)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Color.warning.color)
                    .padding(.vertical, 2).padding(.horizontal, 5)
                    .background(Capsule().fill(DS.Color.warning.opacity(0.16).color))
                    .accessibilityIdentifier("lattice-region-frozen-only")
            }
            Spacer(minLength: 0)
            latticePrimitiveChip(g, ref, .include, label: "Lattice", on: role == .include)
            latticePrimitiveChip(g, ref, .exclude, label: "Solid", on: role == .exclude)
            latticePrimitiveChip(g, ref, .off, label: "Off", on: role == nil)
            Text(String(format: "%.1f mm", project.latticeSlabDepthMM(ref, in: g.id)))
                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(DS.Color.textSecondary.color)
                .padding(.vertical, 3).padding(.horizontal, DS.Space.xs)
                .background(Capsule().fill(DS.Color.fillSelected.color))
                .contentShape(Rectangle())
                .gesture(latticePrimitiveDepthDrag(g, ref))
                // ★ §5 — AND IT TYPES. Same setter as the drag and as the 3D
                // handle, so §2(d)'s "they cannot diverge" survives the third
                // route to the number.
                .onTapGesture { depthPadKey = "row-depth-\(ref.key)" }
                .numberPad(Binding(get: { depthPadKey == "row-depth-\(ref.key)" },
                                   set: { if !$0 { depthPadKey = nil } }),
                           config: .init(title: "Depth", unit: "mm",
                                         allowsDecimal: true),
                           seed: project.latticeSlabDepthMM(ref, in: g.id)) { v in
                    guard let v else { return }
                    project.writeLatticeDepthMM(ref, mm: v)
                    refreshLatticeFaceCards()
                }
                .accessibilityIdentifier("lattice-primitive-depth-\(ref.key)")
        }
        // ★ R14 — PR 331's SMALL-FACE POLICY (§5c): rows below the sliver floor
        // are DIMMED, not hidden. Hiding them would lose a selection his CAD does
        // hand him (faces 41-47 are 16 voxels and he uses them). The rule follows
        // the row into this list rather than stopping at the Regions sheet.
        .opacity(dimmed ? 0.55 : 1)
    }

    /// ★ Three words (R7). The region's depth IS consumed — it is PR 331's
    /// per-sector protection depth; what the run cannot consume yet is the
    /// lattice half.
    static let latticeRegionNotConsumed = "Frozen, not latticed"

    /// PR 331 §5c's small-face policy, applied to this list: a selectable holding
    /// fewer voxels than the sliver floor is dimmed. Faces and regions alike, from
    /// PR 331's own estimate at the project's own resolution.
    private func latticeRowIsBelowTheSmallFaceFloor(_ ref: LatticeSelectableRef) -> Bool {
        guard let mesh = viewerMesh, let spacing = voxelSpacingMM else { return false }
        let members: [FaceID]
        switch ref {
        case let .face(_, f): members = [f]
        case .primitive: return false          // a hand-placed slab has no CAD area
        case let .region(_, rid):
            guard let region = project.faceRegions.region(rid) else { return false }
            members = FaceRegionGeometry.members(of: region, in: mesh)
        }
        let voxels = FaceRegionGeometry.memberVoxelEstimate(
            members: members, in: mesh, spacingMM: spacing)
        return voxels < kRegionSliverFloorVoxels
    }

    /// A selectable's short name on its row. Two words at most (R7).
    private func latticePrimitiveName(_ ref: LatticeSelectableRef) -> String {
        switch ref {
        case let .face(_, f): return "Face \(project.runFaceID(f))"
        case .primitive: return "Primitive"
        case let .region(_, rid):
            return project.faceRegions.region(rid)?.name ?? "Region \(rid)"
        }
    }

    /// ★ One primitive's own answer: Lattice / Solid / Off (§3c). Three, not two —
    /// see `LatticeSelectableRole`: without an explicit "not a region", declaring
    /// ONE face of a three-face group would silently declare the other two.
    private func latticePrimitiveChip(_ g: SelectionGroup, _ ref: LatticeSelectableRef,
                                      _ role: LatticeSelectableRole, label: String,
                                      on: Bool) -> some View {
        let tint: RGBA
        switch role {
        case .include: tint = LatticeDensityProxy.densityColor(fraction: 0.5)
        case .exclude: tint = LatticeDensityProxy.densityColor(fraction: 0.8)
        case .off: tint = DS.Color.textQuaternary
        }
        return Button {
            guard !on else { return }   // it already says this; a re-tap is a no-op
            // The declaring tap PINS this primitive's siblings to whatever they
            // resolved to a moment ago, so setting one face never moves another.
            LatticeSelectableRoles.declare(
                role, for: ref, siblings: project.latticeSelectableRefs(g),
                groupRole: project.latticeEligibleRoles()[g.id],
                in: &project.lattice.selectableRoles)
            // The group must carry a role for the eligibility gate to let ANY of
            // its primitives through (§1a), and a primitive saying "lattice here"
            // is the declaration that turns the mode on. Both, from the one tap.
            if role != .off, project.lattice.groupRoles[g.id] == nil {
                project.lattice.groupRoles[g.id] = role.regionRole
                if project.lattice.groupDepthMM[g.id] == nil {
                    project.lattice.groupDepthMM[g.id] =
                        LatticeSlabDepth.clamp(project.lattice.paintDepthMM)
                }
            }
            if role == .include { project.lattice.enabled = true }
            refreshLatticeFaceCards()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                .padding(.vertical, 3).padding(.horizontal, DS.Space.xs)
                .background(Capsule().fill(on ? tint.opacity(0.55).color
                                              : DS.Color.fillSelected.color)
                    .overlay(Capsule().strokeBorder(
                        (on ? tint : DS.Color.strokeSubtle).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(on ? " — on, tap to clear" : "")")
        .accessibilityIdentifier("lattice-role-\(role.rawValue)-\(ref.key)")
    }

    /// Drag the drawer's depth number. It writes the GROUP's depth, which every
    /// primitive without its own number follows.
    private func latticeGroupDepthDrag(_ g: SelectionGroup) -> some Gesture {
        let seedDepth = project.latticeSlabDepthMM(g.id)
        return DragGesture(minimumDistance: 1)
            .onChanged { v in
                let seed = latticeDepthDragSeed ?? seedDepth
                if latticeDepthDragSeed == nil { latticeDepthDragSeed = seedDepth }
                project.writeGroupDepthMM(
                    g.id, mm: seed + Double(v.translation.width) * 0.05)
            }
            .onEnded { _ in
                latticeDepthDragSeed = nil
                refreshLatticeFaceCards()
            }
    }

    /// Drag ONE primitive's own depth (§3d). The same number the 3D depth plane's
    /// handle writes, and the same number that face is protected to (R4).
    private func latticePrimitiveDepthDrag(_ g: SelectionGroup,
                                           _ ref: LatticeSelectableRef) -> some Gesture {
        let seedDepth = project.latticeSlabDepthMM(ref, in: g.id)
        return DragGesture(minimumDistance: 1)
            .onChanged { v in
                let seed = latticeDepthDragSeed ?? seedDepth
                if latticeDepthDragSeed == nil { latticeDepthDragSeed = seedDepth }
                // ★ THE SAME DETENT CALL THE 3D HANDLE MAKES.
                project.writeLatticeDepthMM(
                    ref,
                    mm: snappedDepthMM(seed + Double(v.translation.width) * 0.05))
            }
            .onEnded { _ in
                latticeDepthDragSeed = nil
                latticeDepthDetent = nil
                refreshLatticeFaceCards()
            }
    }

    /// ★ THE ONE DETENT CALL BOTH DEPTH DRAGS GO THROUGH (maintainer,
    /// 2026-08-17: "I'd like ... the primitive to have magnetic detents").
    ///
    /// ★ THE MAGNET THAT MATTERS IS AT THE DEPTH THIS REGION STARTS TO CERTIFY —
    /// core's `N* × min_printable_cell`, 5.87 mm at his 0.45 mm bead. That is the
    /// number this whole task turned on and the one he had no way to find: the
    /// card did not show it, and the card's own arithmetic implied 24.65 mm,
    /// which was 4.2× wrong. Round millimetres come along as ordinary magnets.
    ///
    /// The held candidate lives in `latticeDepthDetent` so the hysteresis spans
    /// frames; `onEnded` clears it. A FRESH entry ticks the same haptic the
    /// design box's face detent ticks — a held one must not buzz every frame.
    private func snappedDepthMM(_ rawMM: Double) -> Double {
        let r = LatticeDepthDetent.resolve(
            rawMM: rawMM,
            candidates: LatticeDepthDetent.candidates(
                topology: project.lattice.topologyID,
                minExtrudableWidthMM: project.printParams.strutLineWidthMM),
            current: latticeDepthDetent)
        latticeDepthDetent = r.snapped
        if r.didSnap { ClearanceHaptics.detent() }
        return r.mm
    }

    /// ★ §8(c) — SELECTING "PER REGION" IS WHAT MAKES PR 334's DRAWER ROW APPEAR.
    /// That is the entire wiring: PR 334 built the conditional row and asserted it
    /// as two exact cases, and recorded that "NOTHING CAN SET IT TRUE TODAY"
    /// because `LatticeDensityMode` had no per-region case. It has one now, and
    /// this is the single expression that connects them.
    ///
    /// ★ It survived the removal of the group drawer (2026-08-17) — it belongs to
    /// the SELECTABLE drawer and was only sitting next to the group's copy.
    private var perRegionDensity: Bool {
        project.lattice.densityMode == .perRegion
    }

    /// ★ THE DRAWER BENEATH ONE SELECTABLE (the interrupt's §2b) — the SAME
    /// builder and the same layout the group row uses, so a region row and a face
    /// row are not "similar", they are the same drawer (bar R13). The one thing
    /// that differs is stated by the builder, not by this view: a region's
    /// lattice choice cannot reach the run yet.
    @ViewBuilder private func latticeSelectableDrawer(_ g: SelectionGroup,
                                                      _ ref: LatticeSelectableRef) -> some View {
        // ★ THIS SELECTABLE'S OWN CARD, derived at THIS selectable's own depth
        // (task 2026-08-17-lattice-stage-repair §2). It was the GROUP's card
        // under a per-selectable depth label until this task, which is why
        // dragging a face's handle moved the number and nothing under it.
        let drawer = LatticeRegionDrawer.make(
            card: latticeSelectableCards[ref.key],
            depthMM: project.latticeSlabDepthMM(ref, in: g.id),
            held: force.isProtected(g.id),
            latticeReachesTheRun: ref.latticeReachesTheRun,
            perRegionDensity: perRegionDensity,
            expandMM: project.latticeExpandMM(ref))
        latticeDrawerBody(drawer, depthDrag: latticePrimitiveDepthDrag(g, ref),
                          identifier: "lattice-drawer-\(ref.key)",
                          writeDepth: { mm in
                              project.writeLatticeDepthMM(ref, mm: mm)
                              refreshLatticeFaceCards()
                          },
                          // ★ THE KEYPAD SPEAKS PERCENT; the project and the job
                          // speak fraction, as core's band does. ONE conversion,
                          // here — the same shape `sectorDensityRow` uses.
                          writeDensity: { pct in
                              project.writeLatticeDensity(ref, fraction: pct / 100)
                              refreshLatticeFaceCards()
                          },
                          writeExpand: { mm in
                              project.writeLatticeExpandMM(ref, mm: mm)
                              refreshLatticeFaceCards()
                          })
            .padding(.leading, DS.Space.m)
    }

    private func latticeVerdictTint(_ v: LatticeFaceCard.Verdict) -> RGBA {
        switch v {
        case .certified: return DS.Color.okGreen
        case .outOfRegime: return DS.Color.warning
        case .noMaterial: return DS.Color.textQuaternary
        }
    }

    /// Why this group may not carry a lattice role, or nil (§1a/§1d). Reads the
    /// group's EFFECTIVE keep-clear, auto rule included, so an auto-cleared bore
    /// is blocked for the reason it is actually blocked.
    private func latticeRoleBlock(_ g: SelectionGroup) -> LatticeFaceRoleGate.Block? {
        LatticeFaceRoleGate.block(
            kind: force.kind(for: g.id),
            protected: force.isProtected(g.id),
            // EXPLICIT only — an anchored bore's AUTO bolt clearance is a derived
            // default, not a declaration, and must not refuse a real anchor.
            keepClearOn: force.keepClearAffix(for: g.id) == .on)
    }

    /// Recompute every role face's card. ONE voxelization for all of them
    /// (`TopOptKit.faceSlabPreview`) at a PREVIEW resolution, off the main thread.
    /// The resolution is the preview's, not the run's — it is stated on the card
    /// row as the material figure it is, and the depth→layers rounding is core's
    /// own, so the number tracks the run's rule at the run's grid too.
    private func refreshLatticeFaceCards() {
        guard let path = project.importedFile?.path else {
            latticeFaceCards = [:]
            latticeSelectableCards = [:]
            return
        }
        // ★ ONE ENTRY PER DRAWER, AT THAT DRAWER'S OWN DEPTH (task
        // 2026-08-17-lattice-stage-repair §2). `latticeCardInputs` resolves each
        // one through `latticeSlabDepthMM`, the same call the 3D handle and the
        // protection spec go through, so the card is derived at the depth the row
        // is labelled with. `face_slab_preview` walks each (face, depth) pair
        // independently, so the same face appearing twice at two depths is two
        // honest answers, not a collision.
        let inputs = project.latticeCardInputs()
        var keys: [String] = []
        var ids: [Int] = []
        var depths: [Double] = []
        var rhos: [Double?] = []
        for i in inputs {
            keys.append(i.key)
            ids.append(i.faceID)
            depths.append(i.depthMM)
            rhos.append(i.declaredDensity)
        }
        guard !ids.isEmpty else {
            latticeFaceCards = [:]
            latticeSelectableCards = [:]
            return
        }
        let keysCopy = keys
        let groupKeys = Set(selection.groups.map(\.id.uuidString))
        latticeCardsToken += 1
        let token = latticeCardsToken
        let resolution = Self.latticeCardPreviewResolution
        let topology = project.lattice.lattice
        let widthMM = project.printParams.strutLineWidthMM
        let densityGCM3 = model.densityGCm3(for: project.material)
        let depthsCopy = depths
        let rhosCopy = rhos
        Task.detached(priority: .userInitiated) {
            guard let preview = try? TopOptKit.faceSlabPreview(
                stepPath: path, faceIDs: ids, depthsMM: depthsCopy,
                resolution: resolution) else { return }
            var byKey: [String: LatticeFaceCard] = [:]
            for (i, fid) in ids.enumerated() where i < preview.voxels.count {
                byKey[keysCopy[i]] = LatticeFaceCardDerivation.card(
                    faceID: fid, depthMM: depthsCopy[i],
                    heldVoxels: preview.voxels[i], spacingMM: preview.spacingMM,
                    densityGCM3: densityGCM3, topology: topology,
                    // ★ THE MODE'S OWN DENSITY, WHICH NO CALL SITE PASSED UNTIL
                    // NOW (task 2026-08-17-lattice-stage-repair §1d). nil is
                    // AUTO and means core derives; a number is what the user
                    // stated, resolved by `ProjectModel.latticeDeclaredDensity`
                    // through the same precedence the emitted job uses. Without
                    // this the card read the identical figure in Uniform, in
                    // Per-region and in Auto — which is why "stuck at 5%" was
                    // true in every mode.
                    declaredDensity: rhosCopy[i],
                    // ★ PRINTABILITY IS USER INPUT AND HAS NO DEFAULT (task
                    // 2026-08-13-lattice-as-a-material §1b). `widthMM` is the
                    // project's own strut line width — the SAME value this
                    // closure already hands `latticeCellBounds` two lines up, so
                    // the card's verdict and the cell bounds it is judged
                    // against cannot disagree about the nozzle. A card built
                    // without it would fall back to "cannot tell", never to a
                    // silent pass.
                    minExtrudableWidthMM: widthMM)
            }
            // The group cards keep their UUID key (the group row reads them by
            // group id); everything else is keyed by `LatticeSelectableRef.key`.
            var groupCards: [UUID: LatticeFaceCard] = [:]
            var selectableCards: [String: LatticeFaceCard] = [:]
            for (k, c) in byKey {
                if groupKeys.contains(k), let id = UUID(uuidString: k) {
                    groupCards[id] = c
                } else {
                    selectableCards[k] = c
                }
            }
            let finalGroupCards = groupCards
            let finalSelectableCards = selectableCards
            await MainActor.run {
                guard token == latticeCardsToken else { return }   // a newer drag won
                latticeFaceCards = finalGroupCards
                latticeSelectableCards = finalSelectableCards
            }
        }
    }

    /// The face-card preview grid. Coarse ON PURPOSE: the card answers "does this
    /// barrier hand the lattice anything", which does not need the run's 128.
    static let latticeCardPreviewResolution = 48

    /// The compact (unlocked) clearance summary — the pre-handoff layout, unchanged.
    @ViewBuilder private func compactClearanceEditor(_ g: SelectionGroup) -> some View {
        let prims = clearancePrimitives(g)
        let synced = force.isClearanceSynced(g.id)
        switch ClearanceChipLayout.rowMode(primitiveCount: prims.count, synced: synced) {
        case .none:
            EmptyView()
        case .single:
            clearancePrimitiveLine(g, prims[0], showKind: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
        case .perPrimitive:
            // Sync OFF: one line per primitive, each independently editable. The Sync box
            // heads the stack (right-aligned, under the trash icon); the row grows tall.
            VStack(alignment: .trailing, spacing: 5) {
                clearanceSyncRowCheckbox(g)
                ForEach(prims) { clearancePrimitiveLine(g, $0, showKind: true) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        case .synced(let count):
            // Sync ON: the one shared chip set (representative bore + plane) plus the count.
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: DS.Space.xs) {
                    clearanceSyncRowCheckbox(g)
                    Text(ClearanceChipLayout.syncedCountLabel(count))
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
                sharedClearanceChips(g, prims: prims)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 2)
        }
    }

    /// The LOCKED editor (handoff group-editing): the group's keep-out laid out one
    /// primitive per line, each with a "−" to delete it. AUTO primitives delete by
    /// suppressing their face (the over-find escape hatch, BAR B3); MANUAL primitives
    /// delete from the store. When the group has more than one auto bore, the Sync box
    /// still couples their values.
    @ViewBuilder private func lockedClearanceEditor(_ g: SelectionGroup) -> some View {
        let autoPrims = clearancePrimitives(g)
        let manual = project.manualPrimitives(in: g.id)
        VStack(alignment: .trailing, spacing: 6) {
            if autoPrims.count > 1 { clearanceSyncRowCheckbox(g) }
            ForEach(autoPrims) { p in
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    primitiveDeleteButton("delete-auto-\(p.id)") { project.deleteAutoClearance(face: p.id) }
                    // G2: grab an AUTO-found clearance's gizmo → convert it to an explicit
                    // MANUAL primitive (its geometry becomes user-supplied) and select it.
                    if selection.activeGroupID == g.id {
                        // Round-2 T6: the move icon is the ONLY way to grab a
                        // primitive from the panel — a real 44 pt target now, not
                        // a bare 12 pt glyph.
                        Button {
                            selectNewPrimitive(project.convertAutoClearanceToManual(face: p.id, in: g.id), in: g.id)
                        } label: {
                            Image(systemName: "move.3d").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DS.Color.accent.color.opacity(0.9))
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                                    .fill(DS.Color.accent.opacity(0.14).color))
                                .contentShape(Rectangle().inset(by: -5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("grab-auto-\(p.id)")
                        .accessibilityLabel("Convert to a movable primitive")
                    }
                    clearancePrimitiveLine(g, p, showKind: true)
                }
            }
            ForEach(manual) { mp in
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    primitiveDeleteButton("delete-manual-\(mp.id.uuidString)") {
                        project.removeManualPrimitive(id: mp.id, from: g.id)
                    }
                    manualPrimitiveLine(g, mp)
                }
            }
            if autoPrims.isEmpty && manual.isEmpty {
                Text("No keep-out yet — tap + to add one.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 2)
    }

    /// The per-primitive "−" delete affordance (handoff item 2) — the counterpart to
    /// "+", and the more-used half because the finder OVER-finds.
    private func primitiveDeleteButton(_ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .accessibilityIdentifier(id)
    }

    /// One MANUAL primitive's editable lines — the same "Margin/Axial/Depth" chips an
    /// auto primitive shows, but reading/writing the primitive's OWN override (a manual
    /// primitive is never part of the group's shared-sync set). Tinted the clearance
    /// red + tagged "(manual)" so it reads distinctly from a found bore.
    @ViewBuilder private func manualPrimitiveLine(_ g: SelectionGroup, _ mp: ManualPrimitive) -> some View {
        // DEFECT 1: the panel reads the SAME `clearanceMetric(groupID:faceID:role:)` the
        // 3D-viewport chip reads (keyed by the primitive's sentinel faceID), so the two chips
        // for one value can never diverge again — they are literally the same call.
        let key = ProjectModel.manualFaceKey(mp.id)
        VStack(alignment: .trailing, spacing: 4) {
            Text(mp.kind == .bolt ? "Cylinder · manual" : "Plane · manual")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(Self.clearanceTint)
            if mp.kind == .bolt {
                clearanceMetricRow("Margin", metricPill("Margin", g.id, key, .margin))
                clearanceMetricRow("Axial", metricPill("Axial", g.id, key, .axial))
            } else {
                // A plane's in-plane FOOTPRINT (Length × Width) alongside how far it
                // sticks out (Depth). Without Length/Width the slab had extent only in
                // Depth — useless as a keep-out. Each metric is its OWN labelled row, so
                // no chip is ever two rows high (P6).
                clearanceMetricRow("Length", extentPill("Length", g.id, mp, .length))
                clearanceMetricRow("Width", extentPill("Width", g.id, mp, .width))
                clearanceMetricRow("Depth", metricPill("Depth", g.id, key, .slabDepth))
            }
        }
    }

    /// Which in-plane axis of a manual slab an `extentPill` edits.
    private enum PlaneExtent { case length, width }

    /// A Selections-panel pill for a manual PLANE's FULL in-plane extent (Length/Width).
    /// Unlike a clearance metric there is NO "Auto": the extent is the primitive's own
    /// geometry, always a concrete number — so the pill is number-only (no Auto badge,
    /// no ↺ reset: `showChrome: false`). It DISPLAYS the FULL extent (2·half — what a
    /// user measures with calipers) and writes back through the ÷2 boundary in
    /// `ProjectModel.setManualLength`/`setManualWidth`. It reads the SAME
    /// `mp.halfUMM`/`halfWMM` the viewport slab (`resolvedClearances`) and the run spec
    /// (`ManualPrimitive.spec()`) read — one source, so the number can't diverge (P1).
    private func extentPill(_ title: String, _ gid: UUID, _ mp: ManualPrimitive,
                            _ which: PlaneExtent) -> GlassValuePill {
        let full = (which == .length ? mp.halfUMM : mp.halfWMM) * 2
        return GlassValuePill(title: title, valueMM: full, autoMM: nil,
                              compact: true, showTitle: false, showChrome: false) {
            switch which {
            case .length: project.setManualLength(id: mp.id, in: gid, mm: $0)
            case .width:  project.setManualWidth(id: mp.id, in: gid, mm: $0)
            }
        }
    }

    /// A Selections-panel value pill bound to the ONE clearance-value source (DEFECT 1) —
    /// keyed by `(group, faceID)` so a manual primitive (sentinel faceID) and an auto bore
    /// go through the identical read/write the viewport chip uses.
    private func metricPill(_ title: String, _ gid: UUID, _ faceID: Int,
                            _ role: ClearanceMetric.Role) -> GlassValuePill {
        let m = project.clearanceMetric(groupID: gid, faceID: faceID, role: role)
        return GlassValuePill(title: title, valueMM: m?.override, autoMM: m?.auto,
                              compact: true, showTitle: false) {
            project.writeClearanceMetric(groupID: gid, faceID: faceID, role: role, mm: $0)
        }
    }

    /// One primitive's lines: a kind label (Bore / Plane) heading its value metrics, each on
    /// its OWN labeled row — "Margin:" + a number-only chip, "Axial:" + a number-only chip for
    /// a bore, "Depth:" for a plane — reading+writing THIS primitive's effective override
    /// (per-bore when unsynced). Right-aligned.
    ///
    /// Round-6 item 2: the caption ("Margin:" / "Axial:" / "Depth:") is TEXT OUTSIDE a
    /// number-only chip (`showTitle: false`), and each metric gets its own row. The old layout
    /// packed a captioned Margin pill + a captioned Axial pill into one HStack, which — under the
    /// 300 pt panel, right-aligned below the trash icon — wrapped mid-word into a two-row smoosh.
    /// One metric per row can't wrap; the HARD RULE (a chip is never two rows high) holds.
    @ViewBuilder private func clearancePrimitiveLine(_ g: SelectionGroup, _ p: ClearancePrimitive,
                                                     showKind: Bool) -> some View {
        // DEFECT 1: same single source (`clearanceMetric`) as the viewport chip — keyed by the
        // real B-rep faceID here.
        let faceID = Int(p.id)
        VStack(alignment: .trailing, spacing: 4) {
            if showKind {
                Text(ClearanceChipLayout.kindLabel(p.kind))
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
            if p.isBore {
                clearanceMetricRow("Margin", metricPill("Margin", g.id, faceID, .margin))
                clearanceMetricRow("Axial", metricPill("Axial", g.id, faceID, .axial))
            } else {
                clearanceMetricRow("Depth", metricPill("Depth", g.id, faceID, .slabDepth))
            }
        }
    }

    /// One Selections-panel clearance metric: the caption as text OUTSIDE the chip ("Margin:")
    /// beside a number-only pill (round-6 item 2). The whole row is right-aligned by the enclosing
    /// stack; `.fixedSize` keeps the caption + pill on one line so nothing wraps.
    private func clearanceMetricRow(_ label: String, _ pill: GlassValuePill) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text("\(label):")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
            pill
        }
        .fixedSize()
    }

    /// The ONE shared chip set a synced group shows (Task A6 item 2): Margin + Axial
    /// from the representative bore and Depth from the representative plane. Every
    /// primitive reads the group's shared override when synced, so editing here moves
    /// them all together.
    @ViewBuilder private func sharedClearanceChips(_ g: SelectionGroup, prims: [ClearancePrimitive]) -> some View {
        // Round-6 item 2: stack the representative bore + plane VERTICALLY (each already lays its
        // metrics out as its own labeled rows), so a group with both never packs four chips across
        // one 300 pt line and wraps.
        VStack(alignment: .trailing, spacing: 4) {
            if let bore = prims.first(where: { $0.isBore }) {
                clearancePrimitiveLine(g, bore, showKind: false)
            }
            if let plane = prims.first(where: { !$0.isBore }) {
                clearancePrimitiveLine(g, plane, showKind: false)
            }
        }
    }

    /// The clearance-volume red, matched to the viewport render (MetalMeshView keep-out).
    /// Sourced from the shared `DS.Color.clearance` token (keep-clear Phase B).
    static let clearanceTint = DS.Color.clearance.color

    /// The Face-protection (preserve-skin) mint-teal — a COOL "preserved" tint,
    /// distinct from the WARM red "forbidden" clearance, the green anchor, AND every
    /// group-palette accent (handoff 124). The RGB is deliberately unique so the mesh
    /// shader recognises a protected face BY THIS COLOUR and draws the crosshatch over
    /// it (`Self.protectFaceRGB` / the shader's `PROTECT_RGB` must stay in lockstep).
    static let protectFaceRGB = SIMD3<Float>(0.18, 0.88, 0.78)
    static let protectTint = Color(red: 0.18, green: 0.88, blue: 0.78)

    /// The row's Protect AFFIX control (handoff 124): a shield toggle in the same row
    /// as the group's role. Purely explicit — ON iff the user protected the group;
    /// tapping toggles it. Hidden for a part with no B-rep faces (STL — no face skin
    /// to preserve).
    @ViewBuilder private func protectAffixToggle(_ g: SelectionGroup) -> some View {
        if let mesh = viewerMesh, !mesh.faceGeometry.isEmpty {
            let on = force.isProtected(g.id)
            Button {
                force.setProtected(g.id, !on)
            } label: {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(on ? Self.protectTint : DS.Color.textQuaternary.color)
                    .padding(.vertical, 2).padding(.horizontal, on ? 6 : 4)
                    .background(Capsule().fill(on ? Self.protectTint.opacity(0.16) : Color.clear)
                        .overlay(Capsule().strokeBorder(
                            on ? Color.clear : DS.Color.strokeSubtle.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            // Task 2026-08-04-protect-freeze-vs-solidity: Protect is a FREEZE and
            // nothing else. The old copy ("preserves this face's own material")
            // read as a promise of SOLIDITY, which it never was — whether the
            // kept material is solid or latticed is the Lattice page's decision,
            // exactly as for any other kept material. Say the freeze, and say
            // where the other decision lives.
            .help(on ? "Protected — the optimizer may not change this face's shape. Solid or latticed is set on the Lattice page. Tap to turn it off."
                     : "Protect — freeze this face's skin so the optimizer may not reshape it. It does not decide solid vs latticed.")
        }
    }

    /// The row's keep-clear AFFIX control (keep-clear v2): a nosign toggle in the same
    /// row as the group's role. It reads ON for an auto-clearanced anchored bore
    /// (labelled "Auto") or an explicit affix; tapping toggles it. Turning OFF an auto
    /// bore SUPPRESSES that bore's automatic clearance for the run (an explicit
    /// override). Hidden for a part with no B-rep faces (STL — nothing to keep clear).
    @ViewBuilder private func keepClearAffixToggle(_ g: SelectionGroup) -> some View {
        if let mesh = viewerMesh, !mesh.faceGeometry.isEmpty {
            let on = project.keepClearIsOn(g)
            let isAuto = on && force.keepClearOrigin(g.id) == .auto
            Button {
                force.setKeepClear(g.id, on: !on, autoDefault: project.keepClearAutoDefault(g))
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "nosign").font(.system(size: 10, weight: .bold))
                    if isAuto {
                        Text("Auto").dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                    }
                }
                .foregroundStyle(on ? Self.clearanceTint : DS.Color.textQuaternary.color)
                .padding(.vertical, 2).padding(.horizontal, on ? 6 : 4)
                .background(Capsule().fill(on ? Self.clearanceTint.opacity(0.16) : Color.clear)
                    .overlay(Capsule().strokeBorder(
                        on ? Color.clear : DS.Color.strokeSubtle.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .help(on ? "Keep clear is on — the optimizer won’t grow material in this volume. Tap to turn it off."
                     : "Keep clear — reserve this volume as empty for a bolt head / washer / mating face.")
        }
    }

    private func removeGroup(_ id: UUID) {
        selection.remove(id)
        force.clearKind(id)
        force.sync(groups: selection.groups)
    }

    /// Leave the locked group (handoff item 3): close any open rename and unlock the
    /// active group. Fired by a tap on empty Selections-area space.
    private func leaveGroupEditing() {
        renamingGroup = nil
        addingPrimitiveGroup = nil
        chipsRevealedGroup = nil
        selection.clearActive()
    }

    // MARK: in-scene force arrows (D6)

    /// The load groups (drawn as arrows, with tappable weight pills at their tails).
    private var loadGroups: [SelectionGroup] {
        selection.groups.filter { force.kind(for: $0.id).isLoad }
    }

    /// A load's arrow endpoints on screen: tip at the application point when the
    /// force presses into the face, else tail at it (D6). Nil if it can't project.
    private func loadArrowGeometry(_ g: SelectionGroup, mesh: ViewerMesh,
                                   proj: CameraProjection) -> (tail: CGPoint, tip: CGPoint)? {
        guard let cm = groupCentroidModel(g), let nm = groupNormalModel(g) else { return nil }
        let worldN = simd_normalize(settleQuat.act(nm))
        let dir = ForceModel.directionVector(force.kind(for: g.id).loadDirection ?? .gravity,
                                             groupNormal: worldN)
        let base = settledWorld(cm)
        let step = max(mesh.bounds.radius, 1e-3) * 0.35
        guard let pBase = proj.project(base), let pStep = proj.project(base + dir * step) else { return nil }
        var ux = pStep.x - pBase.x, uy = pStep.y - pBase.y
        let mag = max(1e-3, hypot(ux, uy)); ux /= mag; uy /= mag
        let len: CGFloat = 74
        let into = ForceModel.arrowTipAtApplicationPoint(direction: dir, faceNormal: worldN)
        let tail = into ? CGPoint(x: pBase.x - ux * len, y: pBase.y - uy * len) : pBase
        let tip  = into ? pBase : CGPoint(x: pBase.x + ux * len, y: pBase.y + uy * len)
        return (tail, tip)
    }

    /// Every load group's arrow shaft, projected into the stage (tapered, group
    /// colour). The tappable weight pill at each tail lives in `loadOverlays`.
    private var arrowsOverlay: some View {
        Canvas { ctx, _ in
            guard let mesh = viewerMesh, let proj = projection, force.phase == .edit else { return }
            for g in loadGroups {
                if let geo = loadArrowGeometry(g, mesh: mesh, proj: proj) {
                    drawArrow(ctx, from: geo.tail, to: geo.tip, color: g.color.color)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A tapered arrow polygon from `a` (tail) to `b` (tip) — the prototype's shaft
    /// widths + arrowhead.
    /// `w0`/`w1` are the shaft half-widths at tail/neck and `headMax` caps the arrowhead
    /// length — defaulted to the slim force-arrow look; the stubby gravity arrow passes larger
    /// values (round 2 item 3) so it reads as a solid direction indicator.
    private func drawArrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color,
                           w0: CGFloat = 5.5, w1: CGFloat = 2.2, headMax: CGFloat = 16) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len, px = -uy, py = ux
        let head = min(headMax, len * 0.4)
        let hb = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        var path = Path()
        path.move(to: CGPoint(x: a.x + px * w0, y: a.y + py * w0))
        path.addLine(to: CGPoint(x: hb.x + px * w1, y: hb.y + py * w1))
        path.addLine(to: CGPoint(x: hb.x + px * head * 0.55, y: hb.y + py * head * 0.55))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: hb.x - px * head * 0.55, y: hb.y - py * head * 0.55))
        path.addLine(to: CGPoint(x: hb.x - px * w1, y: hb.y - py * w1))
        path.addLine(to: CGPoint(x: a.x - px * w0, y: a.y - py * w0))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }

    // MARK: floating controls at each arrow (D3/D4/D5) — tappable to re-select

    /// The interactive overlays anchored to the 3D selection:
    ///   * the active PENDING group → the Anchor | Load chip at its centroid;
    ///   * every LOAD → a weight pill at its arrow tail — the active one is the full
    ///     scrub/type pill + snap row, the others are dim pills you TAP to re-select
    ///     (so a set force is edited by tapping its arrow, never via the list only).
    /// Nothing here removes a group; removal is the panel trash icon only.
    private var loadOverlays: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack(alignment: .topLeading) {
                if force.phase == .edit, let mesh = viewerMesh, let proj = projection {
                    let placed = keepOutResolved(proj)
                    if let g = activeGroup, force.kind(for: g.id).isPending {
                        let pt = groupScreen(g)
                        // Keep-out pass owns placement (handoff 2026-07-27): the action bar is
                        // nudged clear of the weight pills. Fallback = the old centroid-above anchor.
                        let fallback = CGPoint(x: pt?.x ?? W / 2,
                                               y: pt.map { clamp($0.y - 60, H) } ?? H - 150)
                        anchorLoadChip(g)
                            .position(placed["load.pendingchip"]?.center ?? fallback)
                    }
                    ForEach(loadGroups) { g in
                        if let arrow = loadArrowGeometry(g, mesh: mesh, proj: proj) {
                            let active = g.id == selection.activeGroupID
                            // Keep-out pass owns placement (handoff 2026-07-27): the weight pill is
                            // nudged clear of neighbours. Fallback = the old tail anchor.
                            let anchor = CGPoint(x: arrow.tail.x, y: clamp(arrow.tail.y - (active ? 26 : 0), H))
                            let center = placed["load.\(g.id.uuidString)"]?.center ?? anchor
                            Group {
                                if active {
                                    VStack(spacing: DS.Space.xs) {
                                        weightPill(g)
                                        snapRow(g)
                                    }
                                } else {
                                    dimPill(g).onTapGesture { selection.setActive(g.id) }
                                }
                            }
                            .position(center)
                        }
                    }
                }
            }
        }
    }

    /// Keep a floated overlay on-screen vertically.
    private func clamp(_ y: CGFloat, _ height: CGFloat) -> CGFloat {
        Swift.min(Swift.max(y, 70), Swift.max(80, height - 80))
    }

    private func anchorLoadChip(_ g: SelectionGroup) -> some View {
        HStack(spacing: DS.Space.xs) {
            Button { force.makeAnchor(g.id); selection.clearActive() } label: {
                chipLabel("lock.fill", "Anchor")
                    .foregroundStyle(DS.Color.accentGreen.color)
                    .background(Capsule().fill(DS.Color.accentGreen.opacity(0.2).color))
            }
            .buttonStyle(.plain)
            Button {
                force.makeLoad(g.id)
                model.toast = "Load added along gravity — scrub the weight, or pick Push / Pull"
            } label: {
                chipLabel("arrow.down", "Load")
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .background(Capsule().fill(DS.Color.accent.color))
            }
            .buttonStyle(.plain)
            // Keep-clear v2 — "Keep clear" is an ATTRIBUTE, not a role: on a bare face
            // it creates a keep-clear-only selection; on a face that already has a role
            // it AFFIXES (the row control toggles it there). Either way it never
            // changes the group's role — `setKeepClearAffix` sets the attribute only.
            Button {
                force.setKeepClearAffix(g.id, .on)
                selection.clearActive()
                model.toast = "Keep clear — the optimizer won't grow material in this volume"
            } label: {
                chipLabel("nosign", "Keep clear")
                    .foregroundStyle(Self.clearanceTint)
                    .background(Capsule().fill(Self.clearanceTint.opacity(0.16)))
            }
            .buttonStyle(.plain)
            // Handoff 124 — "Protect" (preserve-skin) is an ATTRIBUTE like Keep clear
            // but the OPPOSITE polarity: it freezes the face's OWN material so the
            // optimizer may not touch it. Affixes on the group; never changes its role.
            //
            // Task 2026-08-04-protect-freeze-vs-solidity: the toast said "will
            // preserve this face's material", which users read as "will keep it
            // SOLID". It never meant that and now must not say it — the material
            // is kept, and the Lattice page decides what the kept material IS.
            Button {
                force.setProtected(g.id, true)
                selection.clearActive()
                model.toast = "Protected — the optimizer may not reshape this face. Solid or latticed is set on the Lattice page."
            } label: {
                chipLabel("shield.lefthalf.filled", "Protect")
                    .foregroundStyle(Self.protectTint)
                    .background(Capsule().fill(Self.protectTint.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(Capsule().fill(DS.Surface.panel.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    private func chipLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(text).dsStyle(DS.TypeScale.callout).fontWeight(.bold)
        }
        .padding(.vertical, 10).padding(.horizontal, DS.Space.l)
    }

    /// The Gravity / Push / Pull snap row for the active load (no delete here —
    /// removal is the panel trash only).
    private func snapRow(_ g: SelectionGroup) -> some View {
        let dir = force.kind(for: g.id).loadDirection ?? .gravity
        return HStack(spacing: DS.Space.xxs) {
            ForEach(LoadDirection.allCases, id: \.self) { d in
                Button { force.setDirection(g.id, d) } label: {
                    Text(d.title)
                        .dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                        .foregroundStyle((d == dir ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                        .padding(.vertical, 7).padding(.horizontal, DS.Space.m)
                        .background(Capsule().fill(d == dir ? DS.Color.fillSelected.color : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(DS.Surface.panel.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
    }

    /// A non-active load's weight pill: dim, with a colour dot, tappable to re-select
    /// that load for editing (the fix for "I had to use the list on the left").
    private func dimPill(_ g: SelectionGroup) -> some View {
        HStack(spacing: 6) {
            Circle().fill(g.color.color).frame(width: 7, height: 7)
            Text(force.formattedWeight(kg: force.kind(for: g.id).weightKg ?? 0))
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundStyle(g.color.color)
        }
        .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
        .background(Capsule().fill(DS.Surface.bar.color)
            .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        .opacity(0.9)
        .contentShape(Capsule())
    }

    @ViewBuilder private func weightPill(_ g: SelectionGroup) -> some View {
        let kg = force.kind(for: g.id).weightKg ?? ForceModel.defaultWeightKg
        // The value is shown/entered in the CURRENT unit (kg or lbs); the pad emits in
        // that unit and we convert back to kg on the way into the model, so typing a
        // number never silently changes the unit.
        let shown = force.unit == .kg ? kg : kg * ForceModel.kgToLb
        Text(force.formattedWeight(kg: kg))
            .font(.system(size: 14, weight: .heavy)).tracking(-0.2)
            .foregroundStyle(g.color.color)
            .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.dialog.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if scrubBase == nil { scrubBase = kg }
                        force.setWeight(g.id, kg: force.scrub(kg: scrubBase ?? kg,
                                                              byPoints: Double(v.translation.width)))
                    }
                    .onEnded { v in
                        let moved = abs(v.translation.width) > 4
                        scrubBase = nil
                        if !moved { weightPadGroup = g.id }   // a tap → open the number pad
                    }
            )
            .numberPad(Binding(get: { weightPadGroup == g.id },
                               set: { if !$0 { weightPadGroup = nil } }),
                       config: .init(title: "Weight", unit: force.unit.label, allowsDecimal: true),
                       seed: shown) { v in
                if let v, v > 0 {
                    force.setWeight(g.id, kg: force.unit == .kg ? v : v / ForceModel.kgToLb)
                }
            }
    }

    // MARK: bottom bar — hint + Optimize

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            // ★ THE HINT CAPSULE IS GONE FROM THE LATTICE AND SURFACE STAGES
            // (maintainer, 2026-08-17: "Please also remove the 'tap more faces to
            // grow the selection...' chip. Remove that from both the lattice and
            // the Surfaces stage. This should give enough room for both Optimize
            // and Lattice buttons.").
            //
            // ★ IT STAYS ON TOPOLOGY, where it is the only thing telling a new
            // user how to make a selection at all. On the other two stages the
            // selection already exists — that is the precondition for being
            // there — so the sentence is noise occupying the width the second
            // action button needs.
            if visible.showsSelectionHint {
                Text(hint)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.72).color)
                    .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(DS.Surface.bar.color))
                    .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.1).color, lineWidth: 1))
            }
            Spacer()
            ComputeLocationControl(compute: compute)
            printParamsButton
            // ★ LATTICE, TO THE LEFT OF OPTIMIZE (maintainer, 2026-08-17: "Make
            // it exactly like Optimize button, but to the left of it").
            latticeThisButton
            optimizeButton
        }
        // ★ THE BAR MEASURES ITSELF. Its height is not a constant: Optimize grows
        // a second line when it is DISABLED (it says what is missing), and the
        // hint capsule wraps. The chip cluster above it used a hardcoded 50, so a
        // taller bar ran straight through the Gravity chip — his screenshot.
        //
        // ★ THIS MEASUREMENT MUST SIT INSIDE THE `maxHeight: .infinity` FRAME, NOT
        // OUTSIDE IT. Mounted after that frame, the GeometryReader measures the
        // EXPANDED frame — the whole viewport, ~1376 pt — instead of the bar's own
        // ~90. Every view that clears the bar then pads itself off the bottom of
        // the screen and the ZStack grows to twice the display, taking the top
        // chrome, the orientation gizmo, the stage buttons and the bar itself out
        // of view (SwiftUI logs it as "Bound preference BottomBarHeightKey tried
        // to update multiple times per frame"). Pinned by
        // `BottomBarMeasurementTests.testTheMeasurementIsPublishedInsideTheExpandedFrame`.
        .background(GeometryReader { g in
            Color.clear.preference(key: BottomBarHeightKey.self,
                                   value: g.size.height)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, DS.Space.xl4)
        .padding(.bottom, DS.Space.xl4)
    }

    private var hint: String {
        if force.phase == .setup { return "Tap the face that points at the floor · drag to orbit" }
        if let g = activeGroup {
            let k = force.kind(for: g.id)
            if k.isPending { return "Tap more faces to grow the selection, then choose Anchor or Load" }
            if k.isLoad { return "Scrub the weight left–right · tap it to type · Push / Pull follow the face" }
        }
        return "Tap a face to select · tap a set arrow to edit its load · drag to orbit"
    }

    /// The groups carrying a LATTICE role (bar Z10). A group set to "lattice here"
    /// or "no lattice here" is a COMPLETE declaration, like keep-clear and
    /// Protect — it must not leave the group PENDING and refuse Optimize.
    private var latticeRoleGroupIDs: Set<UUID> {
        // ELIGIBLE roles only (task 2026-08-12 §1a/§1d) — a role stored against a
        // group that has since become ineligible must not satisfy the pending
        // check, because it will not reach the job either.
        Set(project.latticeEligibleRoles().keys)
    }

    /// Optimize is enabled once gravity is set and no group is pending, AND either
    /// "Minimize plastic" is on (self-weight or force-driven removal) OR a full
    /// force load case is declared (≥1 anchor + ≥1 load — the off-with-forces case).
    private var canOptimize: Bool {
        guard run.phase != .running else { return false }   // not while a run is in flight
        // The core refuses a GRADED lattice job on an expanded domain BEFORE any
        // solve, so the button that would submit one is disabled with that reason
        // rather than inviting a configuration the run cannot honour (task
        // 2026-08-03-variant-entry-gating-and-retention, failure B; narrowed from
        // "any lattice" to "graded" by the device-failure task, because PR 285
        // taught core to run the uniform case).
        guard latticeDesignBoxConflict == nil else { return false }
        guard force.canOptimize(in: selection.groups,
                                minimizePlastic: project.minimizePlastic,
                                latticeRoleGroups: latticeRoleGroupIDs)
        else { return false }
        // Grey out until the inputs change from the last optimized run.
        if let last = lastRunRequest, model.makeRunRequest() == last { return false }
        return true
    }

    /// The GRADED-lattice-plus-design-box conflict in the CURRENT setup, or nil.
    /// One rule, shared by the workspace Optimize button and the lattice page's own.
    /// A UNIFORM lattice under a design box is supported by core (PR 285) and is
    /// not gated here — it was, until the device-failure task found the app still
    /// refusing what core had learned to do.
    private var latticeDesignBoxConflict: String? {
        LatticeCoreCapability.liveConflict(latticeEnabled: project.lattice.enabled,
                                           designBoxActive: project.designBox.isActive,
                                           graded: project.lattice.densityMode == .auto)
    }

    /// The Optimize sub-label, reflecting the minimize-plastic mode + the load case.
    private var optimizeSummary: String {
        if let why = latticeDesignBoxConflict { return why }
        if force.phase == .setup { return "set gravity first" }
        if force.hasPending(in: selection.groups,
                            latticeRoleGroups: latticeRoleGroupIDs) {
            return "finish the pending group"
        }
        // NAME THE MODE, IN BOTH MODES (task 2026-08-03-growth-ladder, bar G7).
        // With the box off this line used to name only the load case, so the one
        // place the user sees before pressing Optimize said nothing about the fact
        // that the run would GROW material rather than remove it.
        let mode = LadderMode.of(minimizePlastic: project.minimizePlastic)
        let a = force.anchorCount(in: selection.groups), l = force.loadCount(in: selection.groups)
        if a > 0 && l > 0 {
            let base = "\(a) anchor\(a > 1 ? "s" : "") · \(l) load\(l > 1 ? "s" : "")"
            return mode.summaryToken + " · " + base
        }
        if project.minimizePlastic { return mode.summaryToken + " · self-weight" }
        return "needs an anchor and a load"
    }

    /// The M7.params "Print Parameters" entry (design: the sliders pill paired with
    /// Optimize). Opens the print-parameters sheet; always available in the workspace.
    private var printParamsButton: some View {
        Button { model.openPrintParams() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .semibold))
                Text("Print Parameters").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .padding(.vertical, 11).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    /// ★ "LATTICE" — LATTICE THE SELECTION, DO NOT OPTIMIZE (maintainer,
    /// 2026-08-17: "implement a 'Lattice This' button just above the 'Optimize'
    /// button ... which only lattices the selection and does not optimize").
    ///
    /// ★ IT NEEDED A CORE MODE, AND NOW HAS ONE. Core took exactly three modes
    /// and the only latticing one — `lattice_variant` — is DEFINED by the
    /// finished design it selects: it refuses without a `variant` block naming a
    /// design.bin and a rung. There is no design when nothing has been optimized.
    /// `lattice_part` asks the other question — lattice the part AS IMPORTED —
    /// and shares the whole pipeline: same load case, same certification solves,
    /// same grading law, same mesh emission.
    ///
    /// Same stature as Optimize, deliberately: it is the other thing you can ask
    /// this screen to DO, not a modifier on the first.
    private var latticeThisButton: some View {
        let ok = canLatticeThis
        return Button {
            guard ok else { return }
            requestLatticeRun()
        } label: {
            VStack(spacing: 1) {
                Text("Lattice").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Text(latticeThisSummary)
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle((ok ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.vertical, 11).padding(.horizontal, DS.Space.xl3)
            .background(Capsule().fill(ok ? DS.Color.accent.color : DS.Color.fillDisabled.color)
                .overlay(Capsule().strokeBorder(ok ? .clear : DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(ok ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!ok)
        .accessibilityIdentifier("lattice-this-button")
    }

    /// ★ WHAT IT NEEDS, AND IT SAYS SO WHILE DISABLED — the same rule Optimize
    /// follows. A lattice run needs a lattice to build: the mode on, and at least
    /// one selectable actually set to Lattice.
    /// ★ IT RUNS ON DEVICE TOO (maintainer, 2026-08-17: "Can you please make it
    /// run on the iPad as well. I imagine that the lattice work is much less
    /// intensive than optimization").
    ///
    /// ★ HE WAS RIGHT ABOUT THE COST AND THE GATE IS GONE. A lattice run has NO
    /// LADDER — a small fixed number of certification solves — so it was never
    /// the optimizer's cost that kept it on the LAN. It was PLUMBING: `jobMode`
    /// reached core through the job document and only the LAN path wrote one.
    /// `RunModel.latticeBridgeRunner` now writes the SAME document to a temp
    /// directory and hands it to core's own parser, so both routes run the same
    /// job. The only requirement left is a lattice to build.
    var canLatticeThis: Bool {
        project.lattice.enabled && !project.latticeJobRegions().regions.isEmpty
    }

    private var latticeThisSummary: String {
        guard project.lattice.enabled else { return "lattice mode is off" }
        let n = project.latticeJobRegions().regions
            .filter { $0.role == .include }.count
        if n == 0 { return "nothing set to lattice" }
        return "\(n) region\(n > 1 ? "s" : "") · no optimization"
    }

    private var optimizeButton: some View {
        let ok = canOptimize
        return Button {
            guard ok else { return }
            requestRun()
        } label: {
            VStack(spacing: 1) {
                Text("Optimize").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Text(optimizeSummary)
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle((ok ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.vertical, 11).padding(.horizontal, DS.Space.xl5)
            .background(Capsule().fill(ok ? DS.Color.accent.color : DS.Color.fillDisabled.color)
                .overlay(Capsule().strokeBorder(ok ? .clear : DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(ok ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!ok)
    }
}

#Preview("Workspace — force & gravity") {
    let m = AppModel(materialsPath: nil)
    m.open(RecentProject(name: "Shelf Bracket v2", materialName: "PLA", process: .fdm))
    return WorkspacePlaceholder(model: m, project: m.project!)
}
