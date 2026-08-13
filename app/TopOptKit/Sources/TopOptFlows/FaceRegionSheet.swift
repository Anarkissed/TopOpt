// FaceRegionSheet.swift — the Regions surface (task 2026-08-14-face-regions).
//
// LAYOUT ONLY. Every number, every verdict and every enable/disable comes from
// `FaceRegionSheetModel`, which is a pure value type and is unit-tested; this
// file decides where things sit.
//
// THE THREE THINGS IT DOES, in the order he asked for them:
//   1. SELECT — a filter with a live match count, correctable by tap.
//   2. UNION  — the matches become ONE region, one row, one role, one depth.
//   3. SPLIT  — a grid in the region's own coordinates, priced before it runs.
//
// ★ COPY BUDGET (bar R7). The longest string in this file is 24 words; every
// other line is a label or a number. Nothing here explains at length what a
// count can state.

#if canImport(SwiftUI)
import SwiftUI
import TopOptDesign

@available(iOS 16.0, macOS 13.0, *)
public struct FaceRegionSheet: View {
    @Binding var model: FaceRegionModel
    @Binding var selection: SelectionModel
    /// The region a viewer tap corrects. Owned by the workspace so its tap
    /// router can see it — the sheet SELECTS, the viewer EDITS (§2c).
    @Binding var selected: RegionID?
    let mesh: ViewerMesh?
    let resolution: Int
    /// Called after any edit so the workspace can re-render highlights and
    /// re-arm Optimize.
    let onChange: () -> Void
    let onClose: () -> Void

    @State private var sheet = FaceRegionSheetModel()
    @State private var rotateStep = 0

    public init(model: Binding<FaceRegionModel>, selection: Binding<SelectionModel>,
                selectedRegion: Binding<RegionID?>,
                mesh: ViewerMesh?, resolution: Int,
                onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._model = model
        self._selection = selection
        self._selected = selectedRegion
        self.mesh = mesh
        self.resolution = resolution
        self.onChange = onChange
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            header
            Divider().overlay(DS.Color.strokeSubtle.color)
            if !sheet.drift.isEmpty { driftBanner }
            selectSection
            Divider().overlay(DS.Color.strokeSubtle.color)
            regionList
            if let r = selectedRegion { splitSection(r) }
        }
        .padding(DS.Space.xl)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .onAppear { refresh() }
    }

    private var selectedRegion: FaceRegion? {
        selected.flatMap { model.region($0) }
    }

    private func refresh() {
        sheet.refresh(mesh: mesh, resolution: resolution, model: model,
                      selectedRegion: selected)
    }

    // MARK: - header

    private var header: some View {
        HStack {
            Text("Regions").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.bold)
                .foregroundStyle(DS.Color.textPrimary.color)
            Spacer()
            Button { onClose() } label: {
                Text("Done").dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.accent.color)
            }
            .buttonStyle(.plain)
        }
    }

    /// ★ REPORTED, NEVER ABSORBED (§3c). A union whose filter used to catch seven
    /// faces and now catches five is a CAD edit the user has to see before running.
    private var driftBanner: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(sheet.drift, id: \.id) { d in
                Text("\(d.name): \(d.then) → \(d.now) faces since you made it")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - §2 select

    private var selectSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Picker("", selection: $sheet.preset) {
                ForEach(FaceRegionSheetModel.Preset.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sheet.preset) { _ in refresh() }

            if sheet.preset == .bores {
                slider(title: "Radius", value: $sheet.boreRadiusMM,
                       range: 0.5...40, unit: "mm")
            } else {
                slider(title: "Size", value: $sheet.sizeFraction,
                       range: 0.02...1.0, unit: "× median")
            }

            HStack {
                Text(sheet.matchLabel).dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textSecondary.color)
                Spacer()
                Button { commitUnion() } label: {
                    Text("Combine").dsStyle(DS.TypeScale.footnote)
                        .foregroundStyle(sheet.matched.isEmpty
                                         ? DS.Color.textQuaternary.color
                                         : DS.Color.accent.color)
                }
                .buttonStyle(.plain)
                .disabled(sheet.matched.isEmpty)
            }
            Text("Tap a face on the model to add or drop it.")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textQuaternary.color)
        }
    }

    private func slider(title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(title).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textTertiary.color)
                Spacer()
                Text(String(format: "%.2f %@", value.wrappedValue, unit))
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            Slider(value: value, in: range) { editing in if !editing { refresh() } }
        }
    }

    private func commitUnion() {
        guard !sheet.matched.isEmpty else { return }
        let id = model.union(faces: sheet.matched, named: sheet.preset.title,
                             filter: sheet.filter,
                             matchedAtAuthor: sheet.matched.count)
        // The union lands in the ACTIVE group so it immediately carries that
        // group's role and depth — one region, one role, one number.
        if let g = selection.activeGroupID {
            selection.addRegions([id], to: g)
        } else {
            let g = selection.addGroup()
            selection.addRegions([id], to: g)
        }
        selected = id
        refresh()
        onChange()
    }

    // MARK: - §5(b) the list

    private var regionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sheet.rows.isEmpty {
                Text("No regions yet.").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textQuaternary.color)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sheet.rows) { row in regionRow(row) }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func regionRow(_ row: FaceRegionSheetModel.Row) -> some View {
        HStack(spacing: DS.Space.s) {
            if row.childCount > 0 {
                Button {
                    model.setCollapsed(row.id, !row.collapsed)
                    refresh()
                } label: {
                    Image(systemName: row.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Text(row.name).dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textPrimary.color)
            Spacer()
            Text(row.childCount > 0
                 ? "\(row.childCount) parts · \(row.voxels) vox"
                 : "\(row.memberFaces)f · \(row.voxels) vox")
                .dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.vertical, DS.Space.xs)
        // ★ §5(c) — below the floor is DIMMED, never hidden. Hiding would lose a
        // selection the CAD does in fact hand him.
        .opacity(row.underFloor ? 0.45 : 1)
        .background(selected == row.id
                    ? DS.Color.accent.color.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = row.id }
    }

    // MARK: - §4 split

    @ViewBuilder
    private func splitSection(_ region: FaceRegion) -> some View {
        Divider().overlay(DS.Color.strokeSubtle.color)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            // ★ THE LABELS FOLLOW THE FRAME. On a shared axis the two families
            // are sectors AROUND it and slabs ALONG it; on the PCA fallback they
            // are cuts across the long axis and across the short one. Calling
            // both "Around/Along" would describe a rotation the split does not
            // make.
            HStack {
                let cyl = mesh.flatMap { sheet.gridPreview(of: region, in: $0) }
                    .map { !$0.pcaFallback } ?? false
                stepper(cyl ? "Around" : "Long axis", $sheet.gridN)
                stepper(cyl ? "Along" : "Short axis", $sheet.gridM)
            }
            if let mesh, let preview = sheet.gridPreview(of: region, in: mesh) {
                if preview.pcaFallback {
                    // ★ §4(b), the mixed case, said out loud.
                    Text("No shared axis — cuts follow the shape's long axis.")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textQuaternary.color)
                }
                Text(preview.verdict.ok
                     ? "\(preview.cells) pieces · smallest \(preview.verdict.minCellVoxels) vox"
                     : preview.verdict.reason)
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(preview.verdict.ok
                                     ? DS.Color.textSecondary.color : DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.l) {
                    Button {
                        model.splitGrid(region.id, cells: sheet.gridCells(of: region, in: mesh))
                        refresh()
                        onChange()
                    } label: {
                        Text("Split").dsStyle(DS.TypeScale.footnote)
                            .foregroundStyle(preview.verdict.ok
                                             ? DS.Color.accent.color
                                             : DS.Color.textQuaternary.color)
                    }
                    .buttonStyle(.plain)
                    .disabled(!preview.verdict.ok)

                    // ★ A BUTTON, NOT A DRAG (§4a). Cycles the snap candidates:
                    // across the long axis, along it, then 45° and 135°.
                    Button {
                        rotateStep += 1
                        refresh()
                    } label: {
                        Text("Rotate").dsStyle(DS.TypeScale.footnote)
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let n = sheet.manualSplitNormal(of: region, in: mesh,
                                                           step: rotateStep) {
                            let members = FaceRegionGeometry.members(of: region, in: mesh)
                            let frame = FaceRegionGeometry.frame(members: members, in: mesh)
                            model.splitManual(region.id, point: frame.origin, normal: n)
                            refresh()
                            onChange()
                        }
                    } label: {
                        Text("Cut once").dsStyle(DS.TypeScale.footnote)
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                HStack(spacing: DS.Space.l) {
                    if !model.children(of: region.id).isEmpty {
                        Button {
                            model.revertSplit(region.id)
                            refresh()
                            onChange()
                        } label: {
                            Text("Undo split").dsStyle(DS.TypeScale.caption)
                                .foregroundStyle(DS.Color.textSecondary.color)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        let members = FaceRegionGeometry.members(of: region, in: mesh)
                        let back = model.dissolve(region.id, resolvedMembers: members)
                        selection.removeRegions([region.id])
                        if let g = selection.activeGroupID { selection.addFaces(back, to: g) }
                        selected = nil
                        refresh()
                        onChange()
                    } label: {
                        Text("Dissolve").dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(title).dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
            Button { value.wrappedValue = Swift.max(1, value.wrappedValue - 1); refresh() }
                label: { Text("−").foregroundStyle(DS.Color.textSecondary.color) }
                .buttonStyle(.plain)
            Text("\(value.wrappedValue)").dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(minWidth: 18)
            Button { value.wrappedValue = Swift.min(64, value.wrappedValue + 1); refresh() }
                label: { Text("+").foregroundStyle(DS.Color.textSecondary.color) }
                .buttonStyle(.plain)
        }
    }
}
#endif
