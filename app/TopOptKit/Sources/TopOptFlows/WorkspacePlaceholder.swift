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
    @State private var typingWeight: UUID?
    @State private var weightText = ""
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
    /// M7.dom-app: the design box captured at the start of a handle drag, so each
    /// drag applies an absolute delta from where the box was when the drag began
    /// (nil = no drag in progress). Same for a keep-out (with its index).
    @State private var dragBaseBox: DesignBoxBounds?
    @State private var dragBaseKeepOut: (index: Int, bounds: DesignBoxBounds)?

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
            MetalMeshView(mesh: viewerMesh,
                          camera: cameraModel,
                          selection: selection,
                          faceTints: roleTints,                 // D3/D5: anchor faces tint green
                          settleRotation: settleQuat,           // D2: settle onto the floor
                          settleAnimated: !reduceMotion,
                          showGround: showGround,
                          faceToolActive: true,                 // D1: tap always selects (routed by phase)
                          onPickFace: handlePick,
                          onProjection: { projection = $0 },
                          // M7.dom-app: the translucent design box + keep-outs (model
                          // space); nil when the tool is off → nothing drawn.
                          designBox: showDesignGizmo ? project.designBox.box : nil,
                          keepOutBoxes: showDesignGizmo ? project.designBox.keepOuts : [])
                .ignoresSafeArea()

            arrowsOverlay.ignoresSafeArea()                     // D6: in-scene force arrow shafts
            if showDesignGizmo { designGizmoOverlay.ignoresSafeArea() }  // dom-app resize/move handles

            chrome
            if force.phase == .setup {
                gravityBanner
            } else {
                if force.gravityIsSet { topRightControls }
                if viewerMesh != nil { selectionsPanel }
                if showDesignGizmo { designBoxPanel }
            }
            loadOverlays.ignoresSafeArea()                      // D3/D4/D5: tappable pills at each arrow
            if viewerMesh != nil { orientationGizmo }           // shared ViewCube (top-left)
            bottomBar
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
                              onExport: { model.toast = "Export (.3mf) arrives in M7.9" },
                              onSeeOriginal: { viewOriginal = true })
                    .ignoresSafeArea()
            }
            // Returning to the saved variants from the original view.
            if viewOriginal, let outcome = run.outcome, outcome.variants.contains(where: { $0.accepted }) {
                seeResultsChip
            }
        }
    }

    /// Start the M7.7 optimize run for the current load case. Gated on the same
    /// `canOptimize` the button uses; nil request only if a file/material is
    /// somehow missing (Optimize is disabled in that case).
    /// A top-center chip to return to the saved variants from the original view.
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
            .padding(.top, 80)   // clear the top chrome row
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The liquid-glass orientation widget, moved to the RIGHT side (gizmo-liquid-glass-
    /// reskin task, item 2). Unlike ResultsScreen — whose right rail is clear below the
    /// Export button — the SETUP screen's right rail is congested: the gravity / minimize /
    /// quality / design-box chips (`topRightControls`) fill the top-right (≈y 22–230) and
    /// the design-box PANEL (`designBoxPanel`, 260pt wide, top inset 210 ⇒ ≈y 210–460) takes
    /// the upper-right whenever that tool is active. There is no ~300pt top-right slot free
    /// of both, so the gizmo is anchored BOTTOM-right instead — clear of the top controls
    /// and, in portrait, clear of the design-box panel; it clears the bottom bar's
    /// Optimize / print-params buttons via the bottom inset. Residual caveat (handoff): in
    /// SHORT LANDSCAPE with the design-box tool open the case's top edge can graze the
    /// panel's lower edge (~70pt) — reported, not silently worked around.
    private var orientationGizmo: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                OrientationGizmoView(camera: cameraModel)
            }
        }
        .padding(.trailing, DS.Space.xl3)
        .padding(.bottom, DS.Space.xl4 + 50 + DS.Space.m)   // clear the bottom bar buttons
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
        run.runner = compute.activeRemote.map { RunModel.remoteRunner($0) } ?? RunModel.bridgeRunner
        run.start(request)
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
        return tints
    }

    // MARK: tap routing (D1/D2)

    /// Tapped-face callback from the viewer. In the gravity-setup phase a tap picks
    /// the floor-facing face and sets gravity; otherwise it routes into the selection
    /// via `WorkspaceTap` — re-selecting a set group, or growing/starting one — and
    /// never removes anything (removal is the panel trash only).
    private func handlePick(_ faceID: FaceID) {
        guard let mesh = viewerMesh else { return }
        if force.phase == .setup {
            if let n = mesh.faceNormal(faceID) {
                force.setGravity(faceNormal: n, face: faceID)
                model.toast = "Gravity set — the part now rests the way it will in real life"
            }
            return
        }
        let loop = FaceTopology.loop(fromFace: faceID, in: mesh)
        WorkspaceTap.route(faceID: faceID, loop: loop, selection: &selection, force: force)
        force.sync(groups: selection.groups)
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
        }
        .padding(.top, DS.Space.xl3)
        .padding(.leading, DS.Space.xl4)
        .alert("Rename project", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { model.renameCurrentProject(to: nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
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
            Text("Tap the face that points at the floor in real life. Drag to orbit, pinch to zoom.")
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

    /// Top-right stack: the gravity chip and, below it, the "Minimize plastic"
    /// toggle (per the maintainer's placement — below the Gravity set · Change area).
    private var topRightControls: some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            gravityChip
            minimizePlasticChip
            qualityChip
            designBoxChip
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, DS.Space.xl3)
        .padding(.trailing, DS.Space.xl4)
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
            Button {
                force.enterGravitySetup()
                selection.clearActive()
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

    /// The design-box control panel (top-right, below the chips): a short explainer,
    /// Reset (back to the default grow-room box), Add keep-out, and per-keep-out
    /// remove. The sizing itself is the on-scene drag handles.
    private var designBoxPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "cube.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accentGreen.color)
                Text("Design Box").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                    .foregroundStyle(DS.Color.textPrimary.color)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 210)          // clear the gravity / minimize / quality / design chips
        .padding(.trailing, DS.Space.xl4)
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

    /// The full on-scene gizmo: six resize handles + a centre move handle for the
    /// design box, and the same for each keep-out.
    private var designGizmoOverlay: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                if let proj = projection, let box = project.designBox.box {
                    // Design-box centre move handle. The drag gesture is attached to
                    // the SIZED handle BEFORE `.position`: `.position` makes a view
                    // greedily fill all offered space, so a gesture applied AFTER it
                    // would capture drags across the WHOLE stage — swallowing the
                    // camera's orbit/pinch-zoom while the gizmo is up (the bug). Bound
                    // before positioning, each drag only fires on its own handle, so
                    // camera navigation still reaches the Metal view underneath.
                    if let c = proj.project(settledWorld(box.center)) {
                        moveHandle(color: Self.designGreen)
                            .gesture(designMoveDrag())
                            .position(c)
                    }
                    // Design-box face resize handles.
                    ForEach(0..<6, id: \.self) { i in
                        let axis = i / 2, isMax = (i % 2 == 1)
                        if let pt = faceHandleScreen(box, axis: axis, isMax: isMax, proj: proj) {
                            resizeHandle(color: Self.designGreen, axis: axis)
                                .gesture(designFaceDrag(axis: axis, isMax: isMax))
                                .position(pt)
                        }
                    }
                    // Keep-out handles.
                    ForEach(Array(project.designBox.keepOuts.enumerated()), id: \.offset) { idx, ko in
                        if let c = proj.project(settledWorld(ko.center)) {
                            moveHandle(color: Self.keepOutRed)
                                .gesture(keepOutMoveDrag(idx))
                                .position(c)
                        }
                        ForEach(0..<6, id: \.self) { i in
                            let axis = i / 2, isMax = (i % 2 == 1)
                            if let pt = faceHandleScreen(ko, axis: axis, isMax: isMax, proj: proj) {
                                resizeHandle(color: Self.keepOutRed, axis: axis)
                                    .gesture(keepOutFaceDrag(idx, axis: axis, isMax: isMax))
                                    .position(pt)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A face-resize handle: a small coloured square (draggable along its axis).
    private func resizeHandle(color: Color, axis: Int) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: 20, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: color.opacity(0.5), radius: 4)
            .contentShape(Rectangle().inset(by: -12))
    }

    /// A centre move handle: a ringed dot (draggable to slide the whole box).
    private func moveHandle(color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.28))
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(color, lineWidth: 2))
            .overlay(Image(systemName: "move.3d").font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white))
            .contentShape(Circle())
    }

    // The model-space delta (mm) a drag represents along one axis (settled).
    private func axisDelta(fromWorld world: SIMD3<Float>, axis: Int, drag: CGSize,
                           proj: CameraProjection) -> Float {
        DesignBoxDrag.axisDelta(handleWorld: world, worldAxis: settledAxis(axis),
                                drag: CGVector(dx: drag.width, dy: drag.height),
                                projection: proj, probe: handleProbe)
    }

    private func designFaceDrag(axis: Int, isMax: Bool) -> some Gesture {
        DragGesture()
            .onChanged { v in
                guard let proj = projection, let mesh = viewerMesh else { return }
                if dragBaseBox == nil { dragBaseBox = project.designBox.box }
                guard let base = dragBaseBox else { return }
                let world = settledWorld(base.faceCenter(axis: axis, isMax: isMax))
                let delta = axisDelta(fromWorld: world, axis: axis, drag: v.translation, proj: proj)
                let target = (isMax ? base.max[axis] : base.min[axis]) + delta
                var next = base
                next = next.movingFace(axis: axis, isMax: isMax, to: target,
                                       minSize: DesignBoxModel.minSize(for: mesh.bounds))
                project.designBox.box = next
            }
            .onEnded { _ in dragBaseBox = nil }
    }

    private func designMoveDrag() -> some Gesture {
        DragGesture()
            .onChanged { v in
                guard let proj = projection else { return }
                if dragBaseBox == nil { dragBaseBox = project.designBox.box }
                guard let base = dragBaseBox else { return }
                let world = settledWorld(base.center)
                // Slide in the ground plane (model X + Z); vertical is via face handles.
                let dx = axisDelta(fromWorld: world, axis: 0, drag: v.translation, proj: proj)
                let dz = axisDelta(fromWorld: world, axis: 2, drag: v.translation, proj: proj)
                project.designBox.box = base.translated(by: SIMD3<Float>(dx, 0, dz))
            }
            .onEnded { _ in dragBaseBox = nil }
    }

    private func keepOutFaceDrag(_ index: Int, axis: Int, isMax: Bool) -> some Gesture {
        DragGesture()
            .onChanged { v in
                guard let proj = projection, let mesh = viewerMesh,
                      project.designBox.keepOuts.indices.contains(index) else { return }
                if dragBaseKeepOut?.index != index {
                    dragBaseKeepOut = (index, project.designBox.keepOuts[index])
                }
                guard let base = dragBaseKeepOut?.bounds else { return }
                let world = settledWorld(base.faceCenter(axis: axis, isMax: isMax))
                let delta = axisDelta(fromWorld: world, axis: axis, drag: v.translation, proj: proj)
                let target = (isMax ? base.max[axis] : base.min[axis]) + delta
                project.designBox.keepOuts[index] = base.movingFace(
                    axis: axis, isMax: isMax, to: target,
                    minSize: DesignBoxModel.minSize(for: mesh.bounds))
            }
            .onEnded { _ in dragBaseKeepOut = nil }
    }

    private func keepOutMoveDrag(_ index: Int) -> some Gesture {
        DragGesture()
            .onChanged { v in
                guard let proj = projection,
                      project.designBox.keepOuts.indices.contains(index) else { return }
                if dragBaseKeepOut?.index != index {
                    dragBaseKeepOut = (index, project.designBox.keepOuts[index])
                }
                guard let base = dragBaseKeepOut?.bounds else { return }
                let world = settledWorld(base.center)
                let dx = axisDelta(fromWorld: world, axis: 0, drag: v.translation, proj: proj)
                let dz = axisDelta(fromWorld: world, axis: 2, drag: v.translation, proj: proj)
                project.designBox.keepOuts[index] = base.translated(by: SIMD3<Float>(dx, 0, dz))
            }
            .onEnded { _ in dragBaseKeepOut = nil }
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
                if !selectionsCollapsed { unitToggle }
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)

            if !selectionsCollapsed {
                Divider().overlay(DS.Color.strokeSubtle.color)
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
        // Bottom-left, above the bottom bar. One animation keyed on the collapse
        // state so the header + body move together (not at different speeds).
        .animation(DS.Motion.emphasized, value: selectionsCollapsed)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, DS.Space.xl4)
        .padding(.bottom, 96)
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
        return HStack(alignment: .top, spacing: DS.Space.s) {
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
                TextField("Group", text: binding(for: g))
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(force.panelKindLabel(for: g.id))
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                clearanceEditor(g)
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
            Button { removeGroup(g.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 11).padding(.leading, DS.Space.l).padding(.trailing, DS.Space.m)
        .background(active ? DS.Color.fillSubtle.color : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(active ? tint.color : .clear).frame(width: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.setActive(g.id) }
        .overlay(alignment: .bottom) { Divider().overlay(DS.Color.strokeSubtle.color) }
    }

    private func binding(for g: SelectionGroup) -> Binding<String> {
        Binding(get: { selection.groups.first { $0.id == g.id }?.name ?? g.name },
                set: { selection.rename(g.id, to: $0) })
    }

    /// Whether a group contributes a bolt clearance (has a curved/bore face) and/or a
    /// face-slab clearance (has a planar face while explicitly Keep-clear). Handoff 100.
    private func groupClearanceShape(_ g: SelectionGroup) -> (bolt: Bool, slab: Bool) {
        guard let mesh = viewerMesh else { return (false, false) }
        let k = force.kind(for: g.id)
        guard k.isAnchor || k.isClearance else { return (false, false) }
        var bolt = false, slab = false
        for f in g.faces {
            if FaceTopology.isCurved(f, in: mesh) { bolt = true }
            else if k.isClearance { slab = true }   // anchor groups only clear bores
        }
        return (bolt, slab)
    }

    /// The editable clearance numbers for a group that produces one (handoff 100):
    /// bolt margin + axial length for an anchored/keep-clear bore, slab depth for a
    /// keep-clear planar face. 0 shows/means "auto" (the core's geometry-derived
    /// suggestion) — an honest label, not a fabricated mm. The number the user types
    /// is exactly the number the run uses.
    @ViewBuilder private func clearanceEditor(_ g: SelectionGroup) -> some View {
        let shape = groupClearanceShape(g)
        if shape.bolt || shape.slab {
            let ov = force.clearanceOverride(for: g.id)
            HStack(spacing: DS.Space.m) {
                Image(systemName: "nosign").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textQuaternary.color)
                if shape.bolt {
                    clearanceField("margin", ov.concentricMarginMM) {
                        force.setClearanceMargin(g.id, mm: $0)
                    }
                    clearanceField("axial", ov.axialClearanceMM) {
                        force.setClearanceAxial(g.id, mm: $0)
                    }
                }
                if shape.slab {
                    clearanceField("slab", ov.slabDepthMM) {
                        force.setClearanceSlab(g.id, mm: $0)
                    }
                }
                Text("mm").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            }
        }
    }

    /// One clearance mm field. Empty text = nil = "auto" (the suggestion). Commits on
    /// submit; a non-positive / unparseable value reverts to auto.
    private func clearanceField(_ label: String, _ value: Double?,
                                _ set: @escaping (Double?) -> Void) -> some View {
        let text = Binding<String>(
            get: { value.map { String(format: "%g", $0) } ?? "" },
            set: { s in
                let t = s.trimmingCharacters(in: .whitespaces)
                if let v = Double(t), v > 0 { set(v) } else if t.isEmpty { set(nil) }
            })
        return HStack(spacing: 2) {
            Text(label).dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textQuaternary.color)
            TextField("auto", text: text)
                .textFieldStyle(.plain)
                .frame(width: 34)
                .multilineTextAlignment(.center)
                .font(.system(size: DS.TypeScale.caption.size, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary.color)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1)
                }
        }
    }

    private func removeGroup(_ id: UUID) {
        selection.remove(id)
        force.clearKind(id)
        force.sync(groups: selection.groups)
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
    private func drawArrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len, px = -uy, py = ux
        let head = min(16, len * 0.4), w0: CGFloat = 5.5, w1: CGFloat = 2.2
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
                    if let g = activeGroup, force.kind(for: g.id).isPending {
                        let pt = groupScreen(g)
                        anchorLoadChip(g)
                            .position(x: pt?.x ?? W / 2,
                                      y: pt.map { clamp($0.y - 60, H) } ?? H - 150)
                    }
                    ForEach(loadGroups) { g in
                        if let arrow = loadArrowGeometry(g, mesh: mesh, proj: proj) {
                            let active = g.id == selection.activeGroupID
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
                            .position(x: arrow.tail.x, y: clamp(arrow.tail.y - (active ? 26 : 0), H))
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
            // Handoff 100 — "Keep clear": reserve the space in front of this face as
            // empty (a bounded slab). An anchored BORE gets a bolt clearance
            // automatically; this is the explicit opt-in for a planar mounting face.
            Button {
                force.makeClearance(g.id)
                selection.clearActive()
                model.toast = "Keep clear — the optimizer won't grow material here"
            } label: {
                chipLabel("nosign", "Keep clear")
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .background(Capsule().fill(DS.Color.fillSelected.color))
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
        if typingWeight == g.id {
            HStack(spacing: 4) {
                TextField("", text: $weightText)
                    .textFieldStyle(.plain)
                    .frame(width: 64)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .onSubmit { commitTypedWeight(g.id) }
                Text(force.unit.label).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textSecondary.color)
            }
            .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.dialog.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        } else {
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
                            if !moved {   // a tap → type
                                let shown = force.unit == .kg ? kg : kg * ForceModel.kgToLb
                                weightText = String(format: "%.1f", shown)
                                typingWeight = g.id
                            }
                        }
                )
        }
    }

    private func commitTypedWeight(_ id: UUID) {
        if let v = Double(weightText), v > 0 {
            force.setWeight(id, kg: force.unit == .kg ? v : v / ForceModel.kgToLb)
        }
        typingWeight = nil
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

    /// Optimize is enabled once gravity is set and no group is pending, AND either
    /// "Minimize plastic" is on (self-weight or force-driven removal) OR a full
    /// force load case is declared (≥1 anchor + ≥1 load — the off-with-forces case).
    private var canOptimize: Bool {
        guard run.phase != .running else { return false }   // not while a run is in flight
        guard force.canOptimize(in: selection.groups, minimizePlastic: project.minimizePlastic)
        else { return false }
        // Grey out until the inputs change from the last optimized run.
        if let last = lastRunRequest, model.makeRunRequest() == last { return false }
        return true
    }

    /// The Optimize sub-label, reflecting the minimize-plastic mode + the load case.
    private var optimizeSummary: String {
        if force.phase == .setup { return "set gravity first" }
        if force.hasPending(in: selection.groups) { return "finish the pending group" }
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
