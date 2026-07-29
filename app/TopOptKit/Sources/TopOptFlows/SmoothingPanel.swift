// SmoothingPanel — the "Smooth & re-certify" control on the results screen (handoff
// 2026-07-28-constrained-smooth-ui). A thin SwiftUI shell over SmoothingModel: it
// reads ONLY the model's honesty-gated surface, so the numbers on screen are always
// the re-analysed ones. Device QA (the /app/ house standard); the honesty logic it
// renders is unit-tested in SmoothingModelTests.
import SwiftUI

struct SmoothingPanel: View {
    @ObservedObject var model: SmoothingModel
    /// Export the smoothed mesh at this path (the caller owns the share sheet).
    var onExport: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            control
            Text(SmoothingModel.sell)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            phaseBody
        }
        .padding(18)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var header: some View {
        HStack {
            Label("Smooth & re-certify", systemImage: "wand.and.rays")
                .font(.headline)
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Strength")
                Spacer()
                Text(String(format: "%.2f", model.strength))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: $model.strength, in: 0...1)
                .disabled(model.isWorking)
            Button {
                Task { await model.apply() }
            } label: {
                Text(model.isWorking ? "Re-certifying…" : "Smooth & re-certify")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply)
        }
    }

    @ViewBuilder private var phaseBody: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) { ProgressView(); Text(model.verdictText ?? "") }
                .font(.subheadline)
        case .couldNotCertify:
            noticeCard(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Couldn't re-certify",
                       body: model.verdictText ?? "Try a lower strength.")
        case .failed(let msg):
            noticeCard(icon: "xmark.octagon.fill", tint: .red,
                       title: "Smoothing failed", body: msg)
        case .certified(let r):
            receiptView(r)
        }
    }

    // ── The receipt (the SELL): provenance pill + verdict + re-analysed numbers ──
    @ViewBuilder private func receiptView(_ r: SmoothingModel.Receipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                pill
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .popover(isPresented: $showInfo) {
                        Text(model.quantizationInfo)
                            .font(.footnote).padding(16).frame(maxWidth: 320)
                    }
                Spacer()
            }
            // The verdict — the honest re-analysed gate result.
            HStack(spacing: 6) {
                Image(systemName: r.accepted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.accepted ? .green : .orange)
                Text(model.verdictText ?? "")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            grid(r)
            Text(model.driftLine(r)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if r.minFeatureLimited {
                Text("Strength was capped to keep the minimum feature width printable.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button {
                onExport(r.smoothedMeshPath)
            } label: {
                Label("Export smoothed STL", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var pill: some View {
        Text(SmoothingModel.pillText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder private func grid(_ r: SmoothingModel.Receipt) -> some View {
        let rows: [(String, String)] = [
            ("Margin (re-analysed)",
             String(format: "%.2f  (req %.2f)", r.marginWorstCase, r.marginRequired)),
            ("Peak stress", String(format: "%.1f MPa", r.maxStressMPa)),
            ("Mass (voxel / mesh)",
             String(format: "%.1f / %.1f g", r.voxelMassGrams, r.meshMassGrams)),
            ("Frozen vertices", "\(r.frozenVertices) / \(r.totalVertices)"),
            ("Taubin pairs", "\(r.pairsApplied) / \(r.pairsRequested)"),
        ]
        VStack(spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder private func noticeCard(icon: String, tint: Color, title: String,
                                         body text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}
