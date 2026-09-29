// FlexibleExportSheet — the Export modal (task 2026-09-29-flexible-screens, overnight
// round; maintainer: "an 'export' button that will pull up a modal to either export gcode
// or an stl").
//
// ★ STL: the generated lattice as one closed solid — the part outside the lattice region
// plus the walls — meshed from FlexibleLatticeField.solid, the SAME function the preview
// draws (the app is the source of truth for this geometry until core's C2 exists). Written
// in slabs straight to a file, so memory stays flat; the share sheet takes it from there.
//
// ★ G-CODE: NOT READY YET, and it says why (maintainer, 2026-09-29: "STL now, G-code
// next"). ARCHITECTURE §2: TopOpt does not slice. DECISIONS 2026-09-27 item 6 allows
// post-processing a slicer's G-code for foaming filaments (C5) — not built yet.

import SwiftUI
import TopOptDesign

public struct FlexibleExportSheet: View {
    public struct Estimate: Equatable {
        public let triangles: Int
        public let bytes: Int
    }
    public struct Quality: Identifiable, Equatable {
        public let id: String
        public let label: String
        /// sample pitch as a fraction of the wall thickness t
        public let pitchOverWall: Double
    }
    public static let qualities: [Quality] = [
        .init(id: "draft", label: "Draft", pitchOverWall: 1 / 2.0),
        .init(id: "standard", label: "Standard", pitchOverWall: 1 / 2.5),
        .init(id: "fine", label: "Fine", pitchOverWall: 1 / 3.0),
    ]

    let wallMM: Double
    let fileName: String
    let summary: String
    let estimate: (Double) -> Estimate?
    let export: (Double, URL, @escaping (Double) -> Bool) async throws -> Estimate
    let onClose: () -> Void

    @State private var quality = "standard"
    @State private var progress: Double?
    @State private var cancelled = false
    @State private var result: String?
    @State private var error: String?
    @State private var shareURL: URL?

    public init(wallMM: Double, fileName: String, summary: String,
                estimate: @escaping (Double) -> Estimate?,
                export: @escaping (Double, URL, @escaping (Double) -> Bool) async throws -> Estimate,
                onClose: @escaping () -> Void) {
        self.wallMM = wallMM; self.fileName = fileName; self.summary = summary
        self.estimate = estimate; self.export = export; self.onClose = onClose
    }

    private var pitch: Double {
        wallMM * (Self.qualities.first { $0.id == quality }?.pitchOverWall ?? 0.4)
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45)).ignoresSafeArea()
                .onTapGesture { if progress == nil { onClose() } }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Export").font(.system(size: 27, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    Text(summary).font(.system(size: 15)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color).padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain).disabled(progress != nil)
                    .accessibilityIdentifier("flexible-export-close")
                }
                HStack(alignment: .top, spacing: DS.Space.m) {
                    stlCard
                    gcodeCard
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 820)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
        }
        .accessibilityIdentifier("flexible-export-sheet")
        #if os(iOS)
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        #endif
    }

    private func card<C: View>(_ title: String, _ tagline: String, accent: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(accent).frame(width: 10, height: 10)
                Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            }
            Text(tagline).font(.system(size: 13, weight: .medium)).foregroundStyle(accent)
            content()
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Surface.dialog.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
    }

    private var stlCard: some View {
        card("STL", "The part with its lattice, one closed solid", accent: FlexibleStageStyle.accent) {
            Text("Meshed from the same geometry the preview draws. Walls \(String(format: "%.2f", wallMM)) mm.")
                .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            FlexChips(options: Self.qualities.map { ($0.id, $0.label) }, selection: quality, id: "flexible-export-quality") {
                if progress == nil { quality = $0 }
            }
            if let e = estimate(pitch) {
                Text(String(format: "About %@ triangles, %@ — sampled every %.2f mm.",
                            Self.count(e.triangles), Self.bytes(e.bytes), pitch))
                    .font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                // ★ A whole-part lattice meshed at a bead's resolution is BIG (the 100 × 100 ×
                // 20 mm pad: 1.3 GB at Standard). Say so before the export, not after.
                if e.bytes > Self.largeBytes {
                    Text("Large file: a slicer may be slow to open it. Draft is the smallest.")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flexible-export-large")
                }
            }
            if let p = progress {
                ProgressView(value: p).tint(FlexibleStageStyle.accent)
                Button("Cancel") { cancelled = true }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
            }
            if let r = result { Text(r).font(.system(size: 12)).foregroundStyle(DS.Color.okGreen.color) }
            if let e = error { Text(e).font(.system(size: 12)).foregroundStyle(DS.Color.danger.color).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: DS.Space.m)
            Button { runExport() } label: {
                Text(progress == nil ? "Export STL" : "Exporting…")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlexibleStageStyle.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s)
            }
            .buttonStyle(.borderedProminent).tint(FlexibleStageStyle.accent)
            .disabled(progress != nil)
            .accessibilityIdentifier("flexible-export-stl")
        }
    }

    private var gcodeCard: some View {
        card("G-code", "Not ready yet", accent: DS.Color.textTertiary.color) {
            Text("TopOpt does not slice (ARCHITECTURE §2). Slice the STL in Bambu Studio.")
                .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("What comes next (DECISIONS 2026-09-27 item 6): for foaming filaments, the app will post-process your sliced G-code to set the tested nozzle temperature and flow per layer.")
                .font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.m)
            Text("Export G-code")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textDisabled.color)
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s + 6)
                .background(Capsule().fill(DS.Color.fillDisabled.color))
                .accessibilityIdentifier("flexible-export-gcode-disabled")
        }
    }

    private func runExport() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        cancelled = false
        result = nil
        error = nil
        progress = 0
        let pitch = self.pitch
        Task {
            do {
                let e = try await export(pitch, url) { p in
                    Task { @MainActor in progress = p }
                    return !cancelled
                }
                progress = nil
                result = "Wrote \(Self.count(e.triangles)) triangles, \(Self.bytes(e.bytes))."
                shareURL = url
            } catch {
                progress = nil
                self.error = cancelled ? "Cancelled — the partial file was deleted." : "\(error)"
            }
        }
    }

    /// Above this the sheet warns that the file is large (500 MB).
    static let largeBytes = 500 << 20

    static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1e6) : n >= 1000 ? String(format: "%.0f k", Double(n) / 1e3) : "\(n)"
    }
    static func bytes(_ b: Int) -> String {
        b >= 1 << 30 ? String(format: "%.2f GB", Double(b) / Double(1 << 30))
            : b >= 1 << 20 ? String(format: "%.0f MB", Double(b) / Double(1 << 20)) : String(format: "%.0f kB", Double(b) / 1024)
    }
}
