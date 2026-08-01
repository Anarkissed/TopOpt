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

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: stageMesh,
                          camera: cameraModel,
                          selection: selection,
                          faceTints: roleTints,                 // D3/D5: anchor faces tint green
                          settleRotation: settleQuat,           // D2: settle onto the floor
                          settleAnimated: !reduceMotion,
                          showGround: showGround,
                          faceToolActive: true,                 // D1: tap always selects (routed by phase)
                          onPickFace: handlePick,
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
                          stressTints: showSmoothingPage ? smoothBrush.vertexTints()
                                                         : latticeProxyTints,
                          // M7.dom-app: the translucent design box + keep-outs (model
                          // space); nil when the tool is off → nothing drawn.
                          designBox: showDesignGizmo ? project.designBox.box : nil,
                          keepOutBoxes: showDesignGizmo ? project.designBox.keepOuts : [],
                          // Keep-clear v2 (Part 3): the true red clearance volumes, drawn
                          // whenever gravity is set (edit phase) so the user can SEE and
                          // reason about every keep-out; the selected group's volume brightens.
                          clearanceVolumes: force.phase == .edit ? clearanceRenderItems : [],
                          // Strut preview (2026-07-30 alignment handoff, bar A3): while the
                          // raymarched lattice layer is up there is ONE visible object — the
                          // body is not drawn at all (alpha 0), it only keeps serving the
                          // pick/id pass; face markings read on the lattice instead (A4).
                          // 1 (opaque) otherwise — byte-identical when off.
                          bodyAlpha: (showStrutPreview && strutScene != nil) ? 0 : 1,
                          // Detent face-highlight pulse (item 2): flash the snapped part face.
                          detentPulse: detentPulse,
                          // Paint mode (handoff 2026-07-25): when on, a one-finger drag brushes
                          // triangles into the active group; `paintFaceIDs` re-labels painted
                          // triangles so the highlight + picker treat them as one face (live paint
                          // highlight). `onBrush` resolves the covered triangles and applies the
                          // stroke; two-finger drag still orbits.
                          paintActive: paintActive,
                          paintFaceIDs: project.effectivePaintFaceIDs(),
                          onBrush: handleBrush)
                .ignoresSafeArea()

            // Strut preview: the raymarched true-strut layer, riding the SAME shared
            // orbit camera AND the same settle model transform as the mesh view (one
            // transform, one camera — the 2026-07-30 alignment fix), with the mesh
            // view's own face tints so markings read on the lattice (the body is not
            // drawn while this layer is up, bar A3). Non-interactive — orbit/tap
            // gestures fall through to the mesh view, whose pick structure is intact.
            if showStrutPreview, let scene = strutScene {
                LatticeSDFPreviewView(camera: cameraModel, scene: scene,
                                      params: latticeProxy.params,
                                      sceneToken: strutSceneToken,
                                      modelRotation: settleQuat,
                                      modelCenter: meshCenter,
                                      faceTints: roleTints)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            arrowsOverlay.ignoresSafeArea()                     // D6: in-scene force arrow shafts
            // Gravity direction (round 2, item 4): the arrow is shown ONLY while gravity is
            // being edited (the setup phase, below) — the persistent dim arrow + "down" tag are
            // REMOVED as viewport clutter; the "Gravity set · <axis>" chip is the at-a-glance
            // readout the rest of the time.
            if showDesignGizmo { designGizmoOverlay.ignoresSafeArea() }  // dom-app resize/move handles
            // DEFECT 2: the manual-primitive transform gizmo (translate on one axis / plane /
            // freely, rotate, + copy) — drawn on the active group's primitives so they can be
            // grabbed. Rendered BENEATH the clearance chips below, so the 330 pt gizmo box can
            // never occlude a value chip (the chip/knob hit areas are small and the rest of that
            // overlay is hit-transparent, so gizmo drags in empty box space still reach it).
            if force.phase == .edit { primitiveGizmoOverlay.ignoresSafeArea() }
            // The lattice region's transform gizmo — only while the lattice panel is open
            // and a region exists, so it never coincides with the force gizmo (U5).
            latticeRegionGizmoOverlay.ignoresSafeArea()
            // Keep-clear Phase B: the draggable clearance handles (wall → margin, caps →
            // axial, face → depth) and the floating glass value pill near the selection — ON TOP
            // of the gizmo so the values stay readable while transforming.
            if force.phase == .edit { clearanceHandlesOverlay.ignoresSafeArea() }

            if !showLatticePage { chrome }
            if force.phase == .setup {
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
            } else if !showLatticePage {
                // The Design Box drawer now lives INSIDE `bottomRightControls` (item 11), so it
                // is no longer placed separately here.
                if force.gravityIsSet { bottomRightControls }
                if viewerMesh != nil { selectionsPanel }
                if viewerMesh != nil { latticePreviewOverlay }
                // Round-2 T1: the big Lattice entry button — top right, LEFT of the
                // position gizmo, Optimize's stature, and it SAYS what is missing.
                if viewerMesh != nil { latticeEntryButtonOverlay }
            }
            if !showLatticePage { loadOverlays.ignoresSafeArea() }  // D3/D4/D5: tappable pills at each arrow
            // Round-2 L6 root cause: this was the ONE piece of workspace chrome not
            // gated behind the lattice page, and its Metal-backed glass composited
            // OVER the page's pure-SwiftUI chrome regardless of ZStack order — the
            // page's RUN SIM button rendered BEHIND it. The fix is structural, not
            // a z nudge: the page hides ALL workspace chrome (its own rule), the
            // gizmo included.
            if viewerMesh != nil, !showLatticePage, !showSmoothingPage { orientationGizmo }
            if !showLatticePage, !showSmoothingPage { bottomBar }
            // The full-screen lattice page (handoff 2026-07-30-lattice-page): chrome
            // over the SAME live stage — the workspace chrome above is hidden while
            // it is open, so exactly one set of controls exists at a time.
            if showLatticePage { latticePageOverlay }
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
            // AE6: the SAME Selections library, over the SAME model. One view, one
            // selection system — never a second selection UX for a third page.
            if showSmoothingPage, smoothingPageModel?.libraryOpen == true,
               force.phase == .edit, viewerMesh != nil {
                selectionsPanel
            }
            // AE7: the position gizmo sits in the SAME corner on every page. On the
            // lattice page it is hidden for the L6 compositing reason (its
            // Metal-backed glass composited over that page's pure-SwiftUI chrome);
            // here it is mounted ABOVE the page instead, so it keeps its shared
            // `PageChrome` corner without landing under anything.
            if showSmoothingPage, viewerMesh != nil { orientationGizmo }
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
                              })
                    .ignoresSafeArea()
            }
            // Returning to the saved variants from the original view.
            if viewOriginal, !showLatticePage, let outcome = run.outcome,
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
        .padding(.top, DS.Space.s)
        .padding(.trailing, DS.Space.s)
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
        run.runner = compute.activeRemote.map { RunModel.remoteRunner($0) } ?? RunModel.bridgeRunner
        // A remote run's liveness is RemoteRun's (queue- + heartbeat-aware); only a
        // LOCAL run arms RunModel's setup-stall watchdog (handoff 129).
        run.start(request, remote: isRemote)
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
            for f in g.faces { tints[f] = v }
        }
        // Handoff 124 — a protected face gets the UNIQUE protect mint-teal, applied
        // AFTER the role tints so it wins: the mesh shader recognises this exact
        // colour and draws a CROSSHATCH over the face ("preserved", distinct from the
        // red clearance VOLUMES that read "forbidden").
        let p = Self.protectFaceRGB
        for g in selection.groups where force.isProtected(g.id) {
            for f in g.faces { tints[f] = SIMD4<Float>(p.x, p.y, p.z, 1) }
        }
        return tints
    }

    /// The per-vertex density tints the lattice proxy paints the body with, or nil when
    /// the proxy is off (body keeps its neutral clay). Uniform in the workspace (no
    /// demand field pre-run); the density GRADING engages wherever a von Mises field is
    /// supplied (see LatticeDensityProxy.tints).
    private var latticeProxyTints: [SIMD4<Float>]? {
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

    /// The clearance volumes to render (keep-clear v2 Part 3), each tagged whether its
    /// group is the ACTIVE selection so the viewport brightens it. Built from the same
    /// resolved geometry the run freezes (`ProjectModel.clearanceVolumes`).
    private var clearanceRenderItems: [ClearanceRenderItem] {
        let active = selection.activeGroupID
        var items = project.clearanceVolumes().map {
            // Round-2: a lattice-role group's volumes are REGIONS, tinted the
            // density ramp's indigo family instead of the keep-out red — include
            // (latticed) mid-violet, exclude (kept solid) deep indigo.
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
        if showLatticePage {
            if latticePageModel.libraryOpen {
                let loop = FaceTopology.loop(fromFace: faceID, in: mesh)
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
        let loop = FaceTopology.loop(fromFace: faceID, in: mesh)
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
    private func handleBrush(_ center: CGPoint, _ phase: BrushPhase) {
        // On the SMOOTHING page the same gesture paints SMOOTHING strength onto the
        // variant's own surface (handoff 2026-08-02-smoothing-page). It is routed
        // here rather than given its own gesture so the brush feels identical on
        // both pages — and it hit-tests the VARIANT mesh, which is what the stage
        // is showing, so a stroke can never land on the original part's geometry.
        if showSmoothingPage {
            guard let mesh = smoothVariantMesh, let proj = projection else { return }
            switch phase {
            case .began, .moved:
                let tris = BrushHitTest.triangles(under: center,
                                                  radiusPoints: brushRadiusPoints,
                                                  mesh: mesh, projection: proj,
                                                  modelRotation: settleQuat,
                                                  modelCenter: meshCenter)
                guard !tris.isEmpty else { return }
                smoothBrush.paint(paintErasing ? .erase : .add,
                                  triangles: tris.map { Int32($0) })
            case .ended:
                break
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
            for f in g.faces { if let c = mesh.faceCentroid(f) { pts.append(c) } }
        }
        return pts
    }

    /// A group's model-space centroid (mean of its faces' centroids).
    private func groupCentroidModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var sum = SIMD3<Float>.zero, n = 0
        for f in g.faces { if let c = mesh.faceCentroid(f) { sum += c; n += 1 } }
        return n > 0 ? sum / Float(n) : nil
    }

    /// A group's model-space outward normal (mean of its faces' normals).
    private func groupNormalModel(_ g: SelectionGroup) -> SIMD3<Float>? {
        guard let mesh = viewerMesh else { return nil }
        var acc = SIMD3<Float>.zero, found = false
        for f in g.faces { if let nrm = mesh.faceNormal(f) { acc += nrm; found = true } }
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
            HStack(spacing: DS.Space.s) {
                // Round-2 T1: the Lattice chip that lived here became the big
                // top-right entry button (`latticeEntryButtonOverlay`).
                if project.lattice.enabled { strutPreviewChip }
            }
            // Honesty banner (bar P1): whenever the strut layer is up the user is told
            // in place what they are looking at — the live analytic strut field, not
            // the worker's exported mesh.
            if showStrutPreview, let scene = strutScene {
                Text(scene.preview.previewLabel)
                    .dsStyle(DS.TypeScale.caption2)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.vertical, DS.Space.xs).padding(.horizontal, DS.Space.s)
                    .background(Capsule().fill(DS.Surface.panel.color.opacity(0.9)))
            }
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
            } else if showStrutPreview,
                      let scene = strutScene,
                      scene.preview.lattice.id != latticeProxy.params.latticeID {
                buildStrutScene()
            }
        }
        .onChange(of: showLatticePage) { open in if open { syncLatticeProxy() } }
        // Graded follow-up: when a run's accepted variants land (streamed or final),
        // rebake the strut scene so its radii grade by the fresh von Mises field.
        // Keyed on acceptedCount (cheap, Equatable); no-op while the preview is off.
        .onChange(of: run.outcome?.acceptedCount ?? -1) { _ in
            if showStrutPreview { buildStrutScene() }
        }
        .onAppear { syncLatticeProxy() }
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
    private func openLatticePage(variantIndex: Int?,
                                 smoothed: SmoothKeptResult? = nil) {
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
            let artifacts = project.relatticeArtifacts
            let why: RelatticeUnavailable? = artifacts != nil
                ? nil
                : (o.computedRemotely ? .runPredatesDesignStore : .computedOnDevice)
            latticeVariantContext = LatticeVariantContext(
                runName: project.name, variantIndex: idx,
                requestedVolumeFraction: v.requestedVolumeFraction,
                massGrams: v.massGrams, worstCaseMargin: v.worstCaseMargin,
                accepted: v.accepted,
                meshVertices: v.meshVertices, meshIndices: v.meshIndices,
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
        let v = o.variants[variantIndex]
        let ctx = SmoothPageEntry.context(
            runName: project.name, variantIndex: variantIndex,
            requestedVolumeFraction: v.requestedVolumeFraction,
            massGrams: v.massGrams, reportedMargin: v.worstCaseMargin,
            accepted: v.accepted, meshVertices: v.meshVertices,
            meshIndices: v.meshIndices,
            // The RUN's own record of whether it generated a lattice — not the
            // project's current lattice settings (AE8, reverse).
            latticed: o.latticeReport != nil,
            retainedJob: project.relatticeArtifacts?.jobJSON,
            modelPath: project.importedFile?.path)

        smoothVariantMesh = ViewerMesh(vertices: v.meshVertices, indices: v.meshIndices,
                                       faceIDs: [], faceGeometry: [],
                                       pseudoFaces: false, smoothShaded: true)
        smoothedVariantMesh = nil

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
            })

        // The freeze mask, from CORE's own predicate resolution. Until it arrives
        // the brush is inert and the page says so — it must not paint into the
        // unknown.
        smoothBrush = SmoothBrushModel(indices: v.meshIndices,
                                       vertexCount: v.meshVertices.count / 3,
                                       freeze: .unavailable)
        showSmoothingPage = true
        if let lc = ctx.loadCase {
            let modelPath = ctx.modelPath
            Task {
                let mask = try? await Task.detached(priority: .userInitiated) {
                    try TopOptKit.smoothFreezeMask(
                        modelPath: modelPath, meshPath: inPath,
                        resolution: lc.resolution,
                        anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
                        buildDirection: lc.buildDirection,
                        infillPercent: lc.infillPercent, freeze: lc.freeze)
                }.value
                guard let mask else { return }
                smoothBrush = SmoothBrushModel(
                    indices: v.meshIndices, vertexCount: v.meshVertices.count / 3,
                    freeze: SmoothFreezeMask(frozen: mask.frozen,
                                             toleranceMM: mask.toleranceMM))
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
                    onKeep: {
                        let lines = smoothBrush.summaries()
                            .filter { !$0.inert }
                            .map { String(format: "%@ %.2f (%d tri)", $0.name,
                                          $0.strength, $0.triangles) }
                        if !page.keep(regionLines: lines) {
                            model.toast = "Nothing to keep — re-certify first."
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
                    // AE6: open the SAME `selectionsPanel` the TO page and the
                    // lattice page mount, over the SAME `project.selection`. This
                    // page has no selection UX of its own to open.
                    onOpenLibrary: { page.libraryOpen.toggle() },
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
    }

    /// LATTICE THIS VARIANT (bar Z7). Submits the `lattice_variant` job against
    /// the RETAINED design + the RETAINED job document — no ladder runs. Refused
    /// (with the reason already on the button) when the run kept neither, and
    /// refused when there is no worker: the certification solves run where the
    /// core runs, and the on-device bridge has no lattice path at all.
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
        // The regions the page authored, as EXPLICIT GEOMETRY PREDICATES (bar
        // Z11): on a variant only placed primitives are emitted, because a face
        // id would resolve against the ORIGINAL part's surface, which this design
        // no longer has.
        let emission = project.variantLatticeJobRegions()
        if emission.skippedFaces > 0 {
            latticePageModel.post(
                note: "\(emission.skippedFaces) face selection(s) were not carried "
                    + "onto this variant — an optimized surface has no faces to "
                    + "resolve them against. Place a region instead.")
        }
        // The SAME spec builder the optimize request uses — only the regions
        // differ, and they differ for the Z11 reason above.
        let spec = project.lattice.runSpec(
            topology: project.lattice.topologyID,
            memberMM: project.lattice.regionMemberMM ?? 0,
            lineWidthMM: project.printParams.wallLineWidthOuterMM,
            regions: emission.regions)
        let jobJSON: Data
        do {
            jobJSON = try RelatticeJobBuilder.build(
                original: art.jobJSON,
                variantVolumeFraction: ctx.requestedVolumeFraction,
                designFileName: "design.bin", lattice: spec)
        } catch {
            model.toast = "Can’t build the re-lattice job: \(error)"
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
        run.runner = { _, _, _ in try RelatticeRun.run(inputs).outcome }
        guard let request = model.makeRunRequest() else { return }
        closeLatticePage()
        run.start(request, remote: true)
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
                    onOptimize: { startRun() },
                    onRelattice: { startRelatticeRun() },
                    onClose: { closeLatticePage() },
                    onBackToSetup: { closeLatticePage() },
                    // L17: the page's Refresh re-runs the preview with the CURRENT
                    // settings — a fresh strut-scene bake + proxy sync.
                    onRefreshPreview: {
                        syncLatticeProxy()
                        buildStrutScene()
                    })
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
            .foregroundStyle(showStrutPreview
                ? LatticeDensityProxy.densityColor(fraction: 0.75).color
                : DS.Color.textSecondary.color)
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.panel.color)
                .overlay(Capsule().strokeBorder(
                    (showStrutPreview ? LatticeDensityProxy.densityColor(fraction: 0.6).opacity(0.6)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: latticeID)
            DispatchQueue.main.async {
                strutScene = scene
                strutSceneToken += 1
            }
        }
    }

    /// Round-2 T1: the big LATTICE entry button — Optimize's stature (height 64,
    /// filled when ready), TOP RIGHT, LEFT of the position gizmo. Greyed until
    /// gravity AND an anchor AND a load are all set, and the sub-line SAYS what
    /// is missing instead of just disabling.
    private var latticeEntryButtonOverlay: some View {
        let entry = LatticeEntryButtonGate.compute(gravitySet: force.gravityIsSet,
                                                   anchors: force.anchorCount(in: selection.groups),
                                                   loads: force.loadCount(in: selection.groups))
        return Button {
            guard entry.enabled else { return }
            openLatticePage(variantIndex: nil)
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "square.grid.3x3.fill").font(.system(size: 14, weight: .bold))
                    Text(project.lattice.enabled ? "Lattice · on" : "Lattice")
                        .dsStyle(DS.TypeScale.headline)
                }
                Text(entry.subtitle)
                    .font(.system(size: 11.5, weight: .semibold)).opacity(0.72)
                    .lineLimit(1)
            }
            .foregroundStyle((entry.enabled ? DS.Color.textPrimary : DS.Color.textDisabled).color)
            .padding(.horizontal, DS.Space.xl5).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall)
                .fill(entry.enabled
                    ? LatticeDensityProxy.densityColor(fraction: 0.75).opacity(0.85).color
                    : DS.Color.fillDisabled.color))
            .dsShadow(entry.enabled ? DS.Shadow.accentGlow : DS.Shadow.panel)
        }
        .buttonStyle(.plain)
        .disabled(!entry.enabled)
        .accessibilityLabel(entry.enabled ? "Open lattice"
                            : "Lattice — needs \(entry.missing.joined(separator: " and "))")
        // Top-right, LEFT of the 210 pt orientation gizmo in the absolute corner.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, OrientationGizmoView.standardSize + DS.Space.s * 2)
        .padding(.top, DS.Space.s + (OrientationGizmoView.standardSize - 64) / 2)
        .help("Lattice mode — pick a topology, cell size and density range, bounded by what core certifies.")
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
        .padding(.trailing, DS.Space.xl4)
        .padding(.bottom, DS.Space.xl4 + 50 + DS.Space.m)   // clear the bottom bar buttons (Optimize)
        .onPreferenceChange(SettingsChipWidthKey.self) { settingsChipWidths = $0 }
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
            // The Paint toggle needs a mesh to brush on.
            case .paint: return viewerMesh != nil
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

    /// The "Minimize plastic" toggle chip (D: pursue material reduction). Off with
    /// forces set → optimize just handles the forces; on → the reduction ladder.
    private var minimizePlasticChip: some View {
        Button { project.minimizePlastic.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: project.minimizePlastic ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle((project.minimizePlastic ? DS.Color.accent : DS.Color.textTertiary).color)
                Text("Minimize plastic").dsStyle(DS.TypeScale.caption).fontWeight(.semibold)
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

    // MARK: left Selections panel (design) with the kg/lbs toggle

    private var selectionsPanel: some View {
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
            }
        }
        .frame(width: 300, alignment: .leading)
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
        // Bottom-left, above the bottom bar. One animation keyed on the collapse
        // state so the header + body move together (not at different speeds).
        .animation(DS.Motion.emphasized, value: selectionsCollapsed)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, DS.Space.xl4)
        .padding(.bottom, 96)
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
                if !showLatticePage {
                    Button { removeGroup(g.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
                    }
                    .buttonStyle(.plain)
                }
                // "+ a primitive" — revealed once the group is LOCKED IN (active).
                // Tapping asks CYLINDER or PLANE (handoff item 1). In the lattice
                // context (a role group) the primitive becomes a lattice REGION.
                if active {
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
          // Round-2 L22: in the lattice context every group row carries the ROLE
          // control — "Lattice here" (include) / "No lattice" (exclude), tap the
          // lit chip again to clear. An attribute on the ONE model's group.
          if showLatticePage { latticeRoleControl(g) }
          // Item 4: the clearance chips (+ per-row Sync box) sit right-aligned to the row's
          // trailing edge, directly below the trash icon — not left-aligned in the name column.
          clearanceEditor(g)
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

    /// Round-2 L22: the per-group LATTICE ROLE control, shown only in the lattice
    /// context. Roles live in `LatticeSettings.groupRoles` keyed by the group's id
    /// — an attribute over the ONE selection model, never a second group store.
    private func latticeRoleControl(_ g: SelectionGroup) -> some View {
        let current = project.lattice.groupRoles[g.id]
        return HStack(spacing: DS.Space.xs) {
            latticeRoleChip(g, .include, label: "Lattice here", on: current == .include)
            latticeRoleChip(g, .exclude, label: "No lattice", on: current == .exclude)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latticeRoleChip(_ g: SelectionGroup, _ role: LatticeGroupRole,
                                 label: String, on: Bool) -> some View {
        let tint = role == .include
            ? LatticeDensityProxy.densityColor(fraction: 0.5)
            : LatticeDensityProxy.densityColor(fraction: 0.8)
        return Button {
            // Tap the lit chip again to CLEAR the role — always additive to the
            // group itself (M2: nothing here touches faces or membership).
            project.lattice.groupRoles[g.id] = on ? nil : role
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: role == .include ? "square.grid.3x3.fill" : "square.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(label).dsStyle(DS.TypeScale.footnote).fontWeight(.bold)
            }
            .foregroundStyle((on ? DS.Color.textPrimary : DS.Color.textTertiary).color)
            .padding(.vertical, 5).padding(.horizontal, DS.Space.sm)
            .background(Capsule().fill(on ? tint.opacity(0.55).color : DS.Color.fillSelected.color)
                .overlay(Capsule().strokeBorder(on ? tint.color : DS.Color.strokeSubtle.color,
                                                lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(on ? " — on, tap to clear" : "")")
        .accessibilityIdentifier("lattice-role-\(role.rawValue)-\(g.id.uuidString)")
    }

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
            .help(on ? "Protected — the optimizer preserves this face's own material. Tap to turn it off."
                     : "Protect — freeze this face's skin so the optimizer may not touch it.")
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
            Button {
                force.setProtected(g.id, true)
                selection.clearActive()
                model.toast = "Protected — the optimizer will preserve this face's material"
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
            Text(hint)
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.72).color)
                .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
                .background(Capsule().fill(DS.Surface.bar.color))
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.1).color, lineWidth: 1))
            Spacer()
            ComputeLocationControl(compute: compute)
            printParamsButton
            optimizeButton
        }
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
        Set(project.lattice.groupRoles.keys)
    }

    /// Optimize is enabled once gravity is set and no group is pending, AND either
    /// "Minimize plastic" is on (self-weight or force-driven removal) OR a full
    /// force load case is declared (≥1 anchor + ≥1 load — the off-with-forces case).
    private var canOptimize: Bool {
        guard run.phase != .running else { return false }   // not while a run is in flight
        guard force.canOptimize(in: selection.groups,
                                minimizePlastic: project.minimizePlastic,
                                latticeRoleGroups: latticeRoleGroupIDs)
        else { return false }
        // Grey out until the inputs change from the last optimized run.
        if let last = lastRunRequest, model.makeRunRequest() == last { return false }
        return true
    }

    /// The Optimize sub-label, reflecting the minimize-plastic mode + the load case.
    private var optimizeSummary: String {
        if force.phase == .setup { return "set gravity first" }
        if force.hasPending(in: selection.groups,
                            latticeRoleGroups: latticeRoleGroupIDs) {
            return "finish the pending group"
        }
        let a = force.anchorCount(in: selection.groups), l = force.loadCount(in: selection.groups)
        if a > 0 && l > 0 {
            let base = "\(a) anchor\(a > 1 ? "s" : "") · \(l) load\(l > 1 ? "s" : "")"
            return project.minimizePlastic ? "minimize plastic · " + base : base
        }
        if project.minimizePlastic { return "minimize plastic · self-weight" }
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

    private var optimizeButton: some View {
        let ok = canOptimize
        return Button {
            guard ok else { return }
            startRun()
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
