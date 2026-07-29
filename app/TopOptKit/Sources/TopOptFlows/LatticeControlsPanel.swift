// LatticeControlsPanel.swift — the lattice-mode controls (handoff 2026-07-29-lattice-
// mode-ui). A self-contained card the workspace floats leading-anchored: the LATTICE
// MODE toggle, a topology picker with a true-geometry sample per type (the proxy's own
// sample-patch path), the cell-size and density-range controls (the shared NumberPad),
// and the region summary. Every bound comes from `LatticeBounds` — which reads the
// certifiable band + cells-per-member ceiling from CORE at runtime — so nothing here is
// hardcoded, and every clamp shows its reason (the two ★ bars). The 3D density preview
// (PR-229) is the viewer's own surface shading, driven from these settings elsewhere;
// this card carries the sample patch + gradient legend as the "what the cells look like"
// reference.

import SwiftUI
import TopOptDesign
import TopOptKit

struct LatticeControlsPanel: View {
    @ObservedObject var project: ProjectModel
    @ObservedObject var proxy: LatticeProxyModel
    /// The certifiable limits, read from core for the CURRENT topology.
    let limits: TopOptKit.LatticeLimits
    let partVolumeMM3: Double
    /// The governing member width (mm) for the cells-per-member readout, or nil.
    let memberMM: Double?
    /// Place a fresh region primitive of this kind (reuses the manual-primitive flow).
    var onPlaceRegion: (ManualPrimitive.Kind) -> Void
    var onClearRegion: () -> Void

    @StateObject private var thumbs = LatticeThumbnailCache()
    @State private var showRegionKindPicker = false

    private var s: LatticeSettings { project.lattice }
    private var bounds: LatticeBounds {
        LatticeBounds.compute(settings: s, limits: limits,
                              memberMM: memberMM ?? 0,
                              lineWidthMM: project.printParams.wallLineWidthOuterMM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if s.enabled {
                topologySection
                cellSection
                densitySection
                regionSection
                if !advisories.isEmpty { advisoriesSection }
                LatticeProxyLegend(model: proxy, partVolumeMM3: partVolumeMM3, memberMM: memberMM)
                    .padding(.top, DS.Space.xxs)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .animation(DS.Motion.emphasized, value: s.enabled)
        .animation(DS.Motion.emphasized, value: s.topologyID)
    }

    // MARK: mode toggle

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(s.enabled ? accent : DS.Color.textSecondary.color)
            Text("LATTICE").dsStyle(DS.TypeScale.overline)
                .foregroundStyle(DS.Color.textSecondary.color)
            Spacer(minLength: DS.Space.s)
            Toggle("", isOn: Binding(get: { s.enabled },
                                     set: { project.lattice.enabled = $0 }))
                .labelsHidden()
                .tint(accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lattice mode")
        .accessibilityValue(s.enabled ? "on" : "off")
    }

    // MARK: topology picker (sample per type)

    private var topologySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            sectionLabel("TOPOLOGY")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(LatticeType.family) { t in
                        topologyCard(t)
                    }
                }
                .padding(.vertical, 2)
            }
            if let reason = bounds.topologyReason {
                reasonLabel(reason, warn: true)
            }
        }
    }

    private func topologyCard(_ t: LatticeType) -> some View {
        let selected = t.id == s.topologyID
        let certifiable = TopOptKit.latticeLimits(topology: t.id).certifiable
        return Button { project.lattice.topologyID = t.id } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                        .fill(DS.Surface.valuePill.color)
                    if let img = thumbs.image(for: t) {
                        Image(decorative: img, scale: 1)
                            .resizable().scaledToFit().padding(4)
                    } else {
                        Image(systemName: "cube.transparent")
                            .foregroundStyle(DS.Color.textTertiary.color)
                    }
                }
                .frame(width: 62, height: 62)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                    .strokeBorder(selected ? accent : DS.Color.strokeSubtle.color,
                                  lineWidth: selected ? 2 : 1))
                Text(t.displayName)
                    .font(.system(size: 9.5, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? DS.Color.textPrimary.color : DS.Color.textSecondary.color)
                    .lineLimit(1).frame(width: 66)
                Text(certifiable ? "certifiable" : "preview")
                    .font(.system(size: 8, weight: .bold)).tracking(0.3)
                    .foregroundStyle(certifiable ? accent : DS.Color.textTertiary.color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.displayName), \(certifiable ? "certifiable" : "preview only")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: cell size

    private var cellSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                sectionLabel("CELL SIZE")
                Spacer()
                LatticeValueChip(title: "Cell", value: s.cellMM, unit: "mm",
                                 decimals: true, accent: accent) { v in
                    if let v, v > 0 { project.lattice.cellMM = v }
                }
            }
            if memberMM != nil {
                Text(String(format: "%.1f cells across the member", bounds.cellsAcrossMember))
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            if let reason = bounds.cellReason {
                reasonLabel(reason, warn: bounds.cellOverCeiling)
            }
        }
    }

    // MARK: density range

    private var densitySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            sectionLabel("DENSITY RANGE")
            HStack(spacing: DS.Space.s) {
                LatticeValueChip(title: "Min", value: s.minRelativeDensity * 100, unit: "%",
                                 decimals: false, accent: accent) { v in
                    if let v { project.lattice.minRelativeDensity = max(0, min(1, v / 100)) }
                }
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Color.textTertiary.color)
                LatticeValueChip(title: "Max", value: s.maxRelativeDensity * 100, unit: "%",
                                 decimals: false, accent: accent) { v in
                    if let v { project.lattice.maxRelativeDensity = max(0, min(1, v / 100)) }
                }
            }
            if limits.certifiable {
                Text("Certifiable band \(pct(limits.rhoMin))–\(pct(limits.rhoMax)) (from core)")
                    .dsStyle(DS.TypeScale.footnote)
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            if let r = bounds.densityLoReason { reasonLabel(r, warn: true) }
            if let r = bounds.densityHiReason { reasonLabel(r, warn: true) }
            if let r = bounds.strutReason { reasonLabel(r, warn: true) }
        }
    }

    // MARK: region (reuses the manual-primitive placement + gizmo)

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                sectionLabel("REGION")
                Spacer()
                if s.region == nil {
                    Button { showRegionKindPicker = true } label: {
                        Label("Place", systemImage: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Lattice region shape", isPresented: $showRegionKindPicker) {
                        Button("Cylinder") { onPlaceRegion(.bolt) }
                        Button("Slab") { onPlaceRegion(.face) }
                    }
                } else {
                    Button(role: .destructive) { onClearRegion() } label: {
                        Label("Clear", systemImage: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DS.Color.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(s.region == nil
                 ? "Whole solid part. Place a region to scope the preview — it reuses the manual-primitive gizmo."
                 : "\(s.region!.kind == .bolt ? "Cylinder" : "Slab") region — drag its gizmo to move it.")
                .dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: advisories (honest scope notes)

    private var advisories: [String] {
        var out: [String] = []
        if s.region != nil {
            out.append("The region scopes the preview; this build lattices the whole solid interior "
                     + "(worker generation carries no sub-region yet).")
        }
        if limits.certifiable && limits.minCellsPerMember <= 0 {
            out.append("Cell-vs-member is a guide — core has not yet certified a cells-per-member ceiling.")
        }
        return out
    }

    private var advisoriesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(advisories, id: \.self) { reasonLabel($0, warn: false) }
        }
    }

    // MARK: shared chrome

    private var accent: Color { LatticeDensityProxy.densityColor(fraction: 0.7).color }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).dsStyle(DS.TypeScale.overlineSmall).foregroundStyle(DS.Color.textTertiary.color)
    }

    private func reasonLabel(_ t: String, warn: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 9, weight: .bold))
            Text(t).dsStyle(DS.TypeScale.footnote)
        }
        .foregroundStyle((warn ? DS.Color.warning : DS.Color.textTertiary).color)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

/// A compact numeric chip for the lattice panel — a tap opens the shared NumberPad; the
/// parsed value flows through `onSet` (so it registers on the SAME undo history as every
/// other edit). One row high (BAR U6). `%` values are passed to/from the caller directly.
private struct LatticeValueChip: View {
    let title: String
    let value: Double
    let unit: String
    let decimals: Bool
    let accent: Color
    let onSet: (Double?) -> Void
    @State private var pad = false

    var body: some View {
        Button { pad = true } label: {
            HStack(spacing: 3) {
                Text(decimals ? String(format: "%g", (value * 100).rounded() / 100)
                              : "\(Int(value.rounded()))")
                    .font(.system(size: 14, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(DS.Color.textPrimary.color)
                Text(unit).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.textTertiary.color)
            }
            .padding(.vertical, 6).padding(.horizontal, DS.Space.m)
            .background(Capsule().fill(DS.Surface.dialog.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .numberPad($pad, config: .init(title: title, unit: unit, allowsDecimal: decimals),
                   seed: value) { onSet($0) }
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(unit)")
    }
}

/// Memoised per-topology sample-patch thumbnails for the picker, rendered through the
/// SAME path the viewer proxy uses (`LatticeSamplePatch.mesh` → `MeshThumbnail`), so a
/// picked lattice previews the exact cell the worker would generate. Rendered once per
/// topology and cached (the geometry is fixed per type at the preview density).
@MainActor
final class LatticeThumbnailCache: ObservableObject {
    private var cache: [String: CGImage] = [:]
    private let size = 120
    private let cells = 2
    // Render-only (NOT a control bound): a fixed cell + a mid density so every topology's
    // sample reads legibly at the same scale. The user's cell/density drive the live 3D
    // preview + the run, not this fixed thumbnail. Cell reuses the shared default so no
    // stray literal exists.
    private let previewDensity = 0.5

    func image(for t: LatticeType) -> CGImage? {
        if let c = cache[t.id] { return c }
        let mesh = LatticeSamplePatch.mesh(lattice: t, cellMM: LatticeSettings.defaultCellMM,
                                           cells: cells, relativeDensity: previewDensity)
        let img = MeshThumbnail.cgImage(for: mesh, size: size)
        if let img { cache[t.id] = img }
        return img
    }
}
