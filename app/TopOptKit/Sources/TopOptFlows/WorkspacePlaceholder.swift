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
import TopOptKit
import TopOptDesign

public struct WorkspacePlaceholder: View {
    @ObservedObject var model: AppModel
    /// The render-ready mesh, built once from the retained import; nil until a part
    /// is present.
    @State private var viewerMesh: ViewerMesh?
    /// The face-selection groups (design `groups` + `activeGroupId`).
    @State private var selection = SelectionModel()
    /// The force & gravity state layered over the selection (roles/direction/weight).
    @State private var force = ForceModel()
    /// The load group whose weight is being typed (nil = none / scrub mode).
    @State private var typingWeight: UUID?
    @State private var weightText = ""
    @State private var scrubBase: Double?

    public init(model: AppModel) { self.model = model }

    /// Identity that changes when a different part is imported, so the viewer mesh
    /// is rebuilt only then (not on every SwiftUI update).
    private var meshID: String {
        guard let m = model.importedMesh else { return "none" }
        return "\(m.vertexCount)-\(m.triangleCount)"
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.background.color.ignoresSafeArea()
            MetalMeshView(mesh: viewerMesh,
                          selection: selection,
                          faceToolActive: true,   // D1: tap always selects (routed by phase)
                          onPickFace: handlePick)
                .ignoresSafeArea()

            chrome
            if force.phase == .setup {
                gravityBanner
            } else {
                if force.gravityIsSet { gravityChip }
                if viewerMesh != nil { selectionsPanel }
            }
            activeControls
            bottomBar
        }
        .task(id: meshID) { rebuildMesh() }
    }

    private func rebuildMesh() {
        guard let m = model.importedMesh else { viewerMesh = nil; return }
        viewerMesh = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs)
        selection = SelectionModel()   // a fresh part starts with no groups
        force = ForceModel()           // …and in the gravity-setup phase
    }

    // MARK: tap routing (D1/D2)

    /// Tapped-face callback from the viewer. In the gravity-setup phase a tap picks
    /// the floor-facing face and sets gravity; otherwise it toggles the tapped
    /// face's whole loop (the hole, or just the face) into the active group.
    private func handlePick(_ faceID: FaceID) {
        guard let mesh = viewerMesh else { return }
        if force.phase == .setup {
            if let n = mesh.faceNormal(faceID) {
                force.setGravity(faceNormal: n, face: faceID)
                model.toast = "Gravity set — the part now rests the way it will in real life"
            }
            return
        }
        selection.pickFaces(FaceTopology.loop(fromFace: faceID, in: mesh))
        force.sync(groups: selection.groups)
    }

    private var activeGroup: SelectionGroup? { selection.activeGroup }

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
                Text(model.projectName).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Rectangle().fill(DS.Color.textPrimary.opacity(0.15).color).frame(width: 1, height: 14)
                Text(model.selectedMaterial ?? "")
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
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, DS.Space.xl3)
        .padding(.trailing, DS.Space.xl4)
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

    // MARK: active-group controls (Anchor|Load chip · snap row · weight pill)

    /// Bottom-centre control cluster for the active selection. In-scene floating at
    /// the projected group centroid is a renderer follow-up (see the file header);
    /// this presents the same controls at the foot of the stage.
    @ViewBuilder private var activeControls: some View {
        if force.phase == .edit, let g = activeGroup {
            let kind = force.kind(for: g.id)
            VStack(spacing: DS.Space.sm) {
                Spacer()
                if kind.isPending {
                    anchorLoadChip(g)
                } else if kind.isLoad {
                    loadControls(g)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 96)
            .allowsHitTesting(true)
        }
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
            Button { removeGroup(g.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
                    .padding(DS.Space.sm)
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

    private func loadControls(_ g: SelectionGroup) -> some View {
        let dir = force.kind(for: g.id).loadDirection ?? .gravity
        return VStack(spacing: DS.Space.s) {
            weightPill(g)
            HStack(spacing: DS.Space.xxs) {
                ForEach(LoadDirection.allCases, id: \.self) { d in
                    Button { force.setDirection(g.id, d) } label: {
                        Text(d.title)
                            .dsStyle(DS.TypeScale.caption).fontWeight(.bold)
                            .foregroundStyle((d == dir ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                            .padding(.vertical, 8).padding(.horizontal, DS.Space.ml)
                            .background(Capsule().fill(d == dir ? DS.Color.fillSelected.color : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Button { removeGroup(g.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .padding(.vertical, 8).padding(.horizontal, DS.Space.m)
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .background(Capsule().fill(DS.Surface.panel.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .dsShadow(DS.Shadow.panel)
        }
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
                .foregroundStyle(DS.Color.textSecondary.color)
                .padding(.vertical, 8).padding(.horizontal, DS.Space.l)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Color.textPrimary.opacity(0.07).color, lineWidth: 1))
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
        return "Tap faces to select · tap a group to edit it · drag to orbit"
    }

    private var optimizeButton: some View {
        let ok = force.canOptimize(in: selection.groups)
        return Button {
            guard ok else { return }
            model.toast = "Load case ready — \(force.optimizeSummary(in: selection.groups)) "
                        + "(\(force.formattedWeight(kg: force.totalLoadKg(in: selection.groups))) total). Run is next."
        } label: {
            VStack(spacing: 1) {
                Text("Optimize").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                Text(force.optimizeSummary(in: selection.groups))
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
    return WorkspacePlaceholder(model: m)
}
