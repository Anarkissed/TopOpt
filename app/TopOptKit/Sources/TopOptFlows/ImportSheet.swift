// ImportSheet.swift — the M7.3 import sheet ("New TopOpt").
//
// Matches docs/design/TopOpt.dc.html IMPORT SHEET: title + subtitle, a file row
// with a Browse button, the Filament(FDM)/Resin(SLA) segmented control, a
// material dropdown for the active family, and Cancel/Continue. Browse uses
// `.fileImporter` (SwiftUI's wrapper over UIDocumentPicker on iPadOS) limited to
// STEP/STL; the picked file is imported through the bridge and the core diagnostic
// is toasted on failure (handled in AppModel.importFile). The card body only —
// RootView presents it centered over the design's blurred scrim.

import SwiftUI
import UniformTypeIdentifiers
import TopOptDesign

public struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @State private var browsing = false

    public init(model: AppModel) { self.model = model }

    /// STEP + STL + 3MF content types for the picker (by extension; none has a
    /// dependable system UTType). Falls back to `.data` so a device without the
    /// declared types still lets the user choose a file. 3MF joined the list in
    /// handoff 134, when mesh formats gained selectable faces.
    private static let allowedTypes: [UTType] = {
        let exts = ["stl", "3mf", "step", "stp"]
        let types = exts.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }()

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New TopOpt").dsStyle(DS.TypeScale.title)
            Text("Import a model and choose your print material.")
                .dsStyle(DS.TypeScale.subhead)
                .foregroundStyle(DS.Color.textTertiary.color)
                .padding(.top, 3)

            fileRow.padding(.top, DS.Space.xl3)

            Text("PRINT PROCESS")
                .dsStyle(DS.TypeScale.overline)
                .foregroundStyle(DS.Color.textQuaternary.color)
                .padding(.top, DS.Space.xl2)
            SegmentedGlass(
                [.init(ProcessKind.fdm, ProcessKind.fdm.segmentTitle),
                 .init(ProcessKind.resin, ProcessKind.resin.segmentTitle)],
                selection: $model.process
            )
            .padding(.top, DS.Space.sm)

            materialDropdown.padding(.top, DS.Space.l)

            minimizePlasticRow.padding(.top, DS.Space.l)

            qualityPicker.padding(.top, DS.Space.l)

            HStack(spacing: DS.Space.m) {
                Spacer()
                PillButton("Cancel", style: .secondary) { model.cancelImport() }
                PillButton("Continue", style: .primary, systemImage: "sparkles",
                           isEnabled: model.canContinue) { model.continueToWorkspace() }
            }
            .padding(.top, DS.Space.xl5)
        }
        .padding(DS.Space.xl6)
        .frame(width: 540, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
        .fileImporter(isPresented: $browsing,
                      allowedContentTypes: Self.allowedTypes,
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
    }

    // MARK: file row

    @ViewBuilder private var fileRow: some View {
        HStack(spacing: DS.Space.ml) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DS.Color.accent.opacity(0.16).color)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: "cube")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(DS.Color.accent.color))
            VStack(alignment: .leading, spacing: 1) {
                if let file = model.importedFile {
                    Text(file.name).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                        .lineLimit(1)
                    Text(file.detail)
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textTertiary.color)
                    // Handoff 134: the importer may have welded duplicate points
                    // or re-oriented triangles. It changed the user's geometry,
                    // so it says so rather than leaving them to wonder.
                    if let repaired = model.importRepairNote {
                        Text(repaired)
                            .dsStyle(DS.TypeScale.caption2)
                            .foregroundStyle(DS.Color.textQuaternary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No model selected").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                    Text("Choose a STEP, STL or 3MF file to begin")
                        .dsStyle(DS.TypeScale.caption2)
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            Spacer(minLength: DS.Space.s)
            Button { browsing = true } label: {
                Text("Browse…")
                    .dsStyle(DS.TypeScale.subhead).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.vertical, 9).padding(.horizontal, DS.Space.l)
                    .background(Capsule().fill(DS.Color.fillSubtle.color)
                        .overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DS.Space.ml)
        .padding(.horizontal, DS.Space.l)
        .background {
            // Design's file-row radius is 16 (not in the DS.Radius scale).
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Color.textPrimary.opacity(0.05).color)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(DS.Color.textPrimary.opacity(0.09).color, lineWidth: 1))
        }
    }

    // MARK: resolution / quality picker

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Detail").dsStyle(DS.TypeScale.footnote)
                .foregroundStyle(DS.Color.textSecondary.color)
            SegmentedGlass(RunQuality.allCases.map { .init($0, $0.title) }, selection: $model.quality)
            Text(model.quality.detail).dsStyle(DS.TypeScale.caption)
                .foregroundStyle(DS.Color.textTertiary.color)
        }
    }

    // MARK: minimize-plastic toggle

    private var minimizePlasticRow: some View {
        Button { model.minimizePlastic.toggle() } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: model.minimizePlastic ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle((model.minimizePlastic ? DS.Color.accent : DS.Color.textTertiary).color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Minimize plastic").dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                    Text("Remove material where it isn’t needed. Turn off to just handle your forces.")
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    // MARK: material dropdown

    @ViewBuilder private var materialDropdown: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(model.process.materialLabel)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            Menu {
                ForEach(model.currentMaterials) { opt in
                    Button(opt.name) { model.selectMaterial(opt.name) }
                }
            } label: {
                HStack {
                    Text(model.selectedMaterial ?? "—")
                        .dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textPrimary.color)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
                .padding(.vertical, 11).padding(.horizontal, DS.Space.m)
                .background {
                    RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                        .fill(DS.Color.fillSubtle.color)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                            .strokeBorder(DS.Color.textPrimary.opacity(0.11).color, lineWidth: 1))
                }
            }
            .disabled(model.currentMaterials.isEmpty)
        }
    }

    // MARK: pick handling

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.toast = "Couldn’t open file: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            // Copy into a stable app-owned temp path (the picked URL is only valid
            // inside the security-scoped access); import from there so the core can
            // re-read it later in the pipeline.
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: url, to: dst)
            } catch {
                model.toast = "Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
            // Handoff 134: `pickedFile` (not `importFile`) — it inspects a mesh
            // first, so a broken file gets the refusal sheet and a clean one
            // gets the unit question before anything is imported. A STEP goes
            // straight through, exactly as before.
            model.pickedFile(atPath: dst.path, displayName: url.lastPathComponent)
        }
    }
}

#Preview("ImportSheet") {
    let m = AppModel(materialsPath: nil)
    return ZStack {
        DS.Color.background.color.ignoresSafeArea()
        DS.Color.scrim.color.ignoresSafeArea()
        GlassSheet { ImportSheet(model: m) }
    }
}
