// LatticeProxyLegend.swift — the honest face of the lattice proxy (handoff
// 2026-07-28-lattice-viewer-proxy). A compact card that makes the proxy legible and,
// above all, HONEST (requirement 1): it states plainly that the coloured part is a
// DENSITY PREVIEW, not the exported lattice geometry, and shows a small true-geometry
// sample patch so the user can see what the cells actually are. It conveys the two
// things that matter (requirement 2): WHERE the lattice is dense (the colour on the
// part) and HOW DENSE (the ρ scale here), plus the cost it saves versus rendering the
// real mesh.
//
// It draws at a fixed corner and, through ViewportKeepOut, registers only as a low
// priority `.label`, so it floats clear of the gizmo, chips and design box rather
// than fighting them (requirement V4).

import SwiftUI
import TopOptDesign

/// The lattice-proxy legend + honest banner + sample patch + cost line.
public struct LatticeProxyLegend: View {
    @ObservedObject var model: LatticeProxyModel
    /// The part's solid volume (mm³) for the cost comparison; 0 hides the cost line.
    let partVolumeMM3: Double
    /// A representative member thickness (mm) for the cells-across readout; nil hides.
    let memberMM: Double?

    public init(model: LatticeProxyModel, partVolumeMM3: Double, memberMM: Double? = nil) {
        self.model = model
        self.partVolumeMM3 = partVolumeMM3
        self.memberMM = memberMM
    }

    private var lattice: LatticeType { model.params.lattice }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            banner
            sampleRow
            gradientRow
            factsRow
            if partVolumeMM3 > 0 { costRow }
        }
        .padding(DS.Space.m)
        .frame(width: 260)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
    }

    // The honest label — the first thing read, so the preview is never mistaken for
    // the exported geometry.
    private var banner: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LatticeDensityProxy.densityColor(fraction: 0.7).color)
            VStack(alignment: .leading, spacing: 1) {
                Text("LATTICE PREVIEW").dsStyle(DS.TypeScale.footnote)
                    .tracking(0.8).foregroundStyle(DS.Color.textPrimary.color)
                Text("density proxy — not the exported geometry")
                    .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
            }
        }
    }

    // The true-geometry sample patch + its honest triangle count.
    private var sampleRow: some View {
        HStack(spacing: DS.Space.sm) {
            patchThumb
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample cells").dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textSecondary.color)
                Text("true geometry · \(model.samplePatchTriangles.formatted()) tris")
                    .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
                Text(lattice.displayName).dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var patchThumb: some View {
        if let img = model.samplePatchThumbnail() {
            Image(img, scale: 1, label: Text("lattice sample"))
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                    .strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: DS.Radius.field)
                .fill(DS.Color.fillSubtle.color).frame(width: 56, height: 56)
        }
    }

    // The density scale: sparse → dense, labelled with the actual ρ range.
    private var gradientRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LinearGradient(colors: model.legendStops().map {
                Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(Capsule())
            HStack {
                Text("sparse · \(pct(model.params.densitySpan.lo))")
                    .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
                Spacer()
                Text("dense · \(pct(model.params.densitySpan.hi))")
                    .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
            }
            Text("colour = local relative density")
                .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textQuaternary.color)
        }
    }

    private var factsRow: some View {
        HStack(spacing: DS.Space.m) {
            fact("cell", String(format: "%.0f mm", model.params.cellMM))
            if let m = memberMM {
                fact("cells/member", String(format: "%.1f", model.cellsAcrossMember(m)))
            }
        }
    }

    private var costRow: some View {
        let c = model.cost(volumeMM3: partVolumeMM3)
        return VStack(alignment: .leading, spacing: 2) {
            Text("on device: \(c.proxyTriangles.formatted()) tris · \(mb(c.proxyGPUBytes))")
                .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textSecondary.color)
            Text("real lattice: \(c.realTriangles.formatted()) tris · \(mb(c.realGPUBytes)) · \(ratioLabel(c.gpuRatio)) heavier")
                .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
            Text(value).dsStyle(DS.TypeScale.caption).foregroundStyle(DS.Color.textPrimary.color)
        }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func mb(_ bytes: Int) -> String {
        let m = Double(bytes) / (1024 * 1024)
        return m >= 100 ? String(format: "%.0f MB", m)
             : m >= 1 ? String(format: "%.1f MB", m)
             : String(format: "%.0f KB", Double(bytes) / 1024)
    }
    private func ratioLabel(_ r: Double) -> String { String(format: "%.0f×", r) }
}
