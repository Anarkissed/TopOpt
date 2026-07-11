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
    /// Snap the settle instead of animating it, for reduced-motion users (D2).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// Voxel resolution for the run. The design copy references 128³; the on-device
    /// value is a maintainer performance decision (ROADMAP M7.10 / M6.3 projection
    /// cost), so this stays a single tunable constant rather than being scattered.
    private static let runResolution = 64

    public init(model: AppModel, project: ProjectModel) {
        self.model = model
        self.project = project
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: viewerMesh,
                          selection: selection,
                          faceTints: roleTints,                 // D3/D5: anchor faces tint green
                          settleRotation: settleQuat,           // D2: settle onto the floor
                          settleAnimated: !reduceMotion,
                          showGround: showGround,
                          faceToolActive: true,                 // D1: tap always selects (routed by phase)
                          onPickFace: handlePick,
                          onProjection: { projection = $0 })
                .ignoresSafeArea()

            arrowsOverlay.ignoresSafeArea()                     // D6: in-scene force arrow shafts

            chrome
            if force.phase == .setup {
                gravityBanner
            } else {
                if force.gravityIsSet { topRightControls }
                if viewerMesh != nil { selectionsPanel }
            }
            loadOverlays.ignoresSafeArea()                      // D3/D4/D5: tappable pills at each arrow
            bottomBar
            RunScreen(model: run,                               // M7.7: progress card + failure sheets
                      materialName: project.material,
                      resolution: Self.runResolution,
                      onRetry: startRun)
                .ignoresSafeArea()
            if run.phase == .succeeded, let outcome = run.outcome {  // M7.8: results screen
                ResultsScreen(projectName: project.name, outcome: outcome,
                              onClose: { run.reset() },
                              onExport: { model.toast = "Export (.3mf) arrives in M7.9" })
                    .ignoresSafeArea()
            }
        }
    }

    /// Start the M7.7 optimize run for the current load case. Gated on the same
    /// `canOptimize` the button uses; nil request only if a file/material is
    /// somehow missing (Optimize is disabled in that case).
    private func startRun() {
        guard canOptimize else { return }
        guard let request = model.makeRunRequest(resolution: Self.runResolution) else {
            model.toast = "Can’t start — import a model and choose a material first."
            return
        }
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
                Text(project.name).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                Text(project.material)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
            }
            .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.12).color, lineWidth: 1)))
            .foregroundStyle(DS.Color.textPrimary.color)
        }
        .padding(.top, DS.Space.xl3)
        .padding(.leading, DS.Space.xl4)
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
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, DS.Space.xl3)
        .padding(.trailing, DS.Space.xl4)
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

    // MARK: left Selections panel (design) with the kg/lbs toggle

    private var selectionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.opacity(0.7).color)
                    Text("Selections").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                }
                Spacer()
                unitToggle
            }
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.ml).padding(.bottom, DS.Space.m)

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
            }
        }
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .padding(.top, 82)
        .padding(.leading, DS.Space.xl4)
        .frame(maxHeight: 520, alignment: .top)
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
            RoundedRectangle(cornerRadius: 4).fill(tint.color)
                .frame(width: 11, height: 11)
                .shadow(color: tint.opacity(0.4).color, radius: 4)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Group", text: binding(for: g))
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.TypeScale.callout.size, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(force.panelKindLabel(for: g.id))
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textQuaternary.color)
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
        force.canOptimize(in: selection.groups, minimizePlastic: project.minimizePlastic)
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
