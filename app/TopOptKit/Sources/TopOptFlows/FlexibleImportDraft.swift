// FlexibleImportDraft — round 7 · U21, batch A (NEW-FLEX-TAB): New TopOpt's [Flexible] tab.
//
// His words (notes of 2026-10-21, Img4 and Img5): "There is no "flexible" tab or option. This was supposed to have been done.
// There should be a flexible tab next to "filament" and "resin" that has a drop down of the different flexible filaments we
// have listed. This should then lead right to the Flexible Lattice stage."
//
// The import sheet (main's ImportSheet.swift) carries four approved hooks (H41–H44, the reviewer's ruling of 2026-10-22 06:38):
//   H41  this draft as a @StateObject (inert: the gates live in H42–H44)
//   H42  `flexDraft.available` (the flexible filament list loaded) ⇒ the three-segment picker below; else today's two segments,
//        byte-identical
//   H43  `flexDraft.on` (Flexible chosen) ⇒ the "Flexible filament" dropdown; else today's material dropdown
//   H44  `flexDraft.on` ⇒ Continue = `continueFlexible` (today's Continue, then a new Flexible setup and the one-shot landing);
//        else today's `continueToWorkspace()`
// and WorkspacePlaceholder's H45 takes the one-shot (`FlexibleNewProject`) and opens the Lattice stage, which under Flexible is
// the Flexible Lattice stage (the mode modal is never asked: `lattice.flexible` is set).
//
// Under the hood a Flexible project stays an FDM print (ProcessKind keeps its two cases; a third persisted case would read as
// resin in main's `process == .fdm ? … : …` code) with the FDM material Topology runs on (ABS by default, as his pad has); the
// filament lives in `lattice.flexible.materialID`. The print-parameters sheet still opens first (bead width).

import SwiftUI
import TopOptKit
import TopOptDesign

/// The sheet's Flexible state while it is open (a @StateObject of ImportSheet, so a re-opened sheet starts on Filament again).
@MainActor
public final class FlexibleImportDraft: ObservableObject {

    /// flexible_materials.json in the Model card's order: the filaments with squish data first, then by name.
    public let catalogue: [FlexMaterialInfo]
    /// [Flexible] is the chosen segment.
    @Published public var on = false
    /// The filament picked; the Model card's default (the first with squish data) until he picks another.
    @Published public var materialID: String?

    /// Tests only: the catalogue's path when the app bundle has none (a test runner's Bundle.main is xctest's).
    nonisolated(unsafe) static var testMaterialsPath: String?
    /// ★ RED CONTROL: the picker without [Flexible] (today's two segments).
    nonisolated(unsafe) static var controlNoFlexibleTab = false
    /// ★ RED CONTROL: picking Filament or Resin leaves [Flexible] on (Continue would still make a Flexible project).
    nonisolated(unsafe) static var controlSegmentsKeepFlexible = false

    public init(materialsPath: String?) {
        let path = materialsPath ?? Self.testMaterialsPath
        catalogue = Self.ordered(path.flatMap { try? FlexibleCore.materials(path: $0) } ?? [])
        materialID = catalogue.first { $0.noPrediction == nil }?.id ?? catalogue.first?.id
    }

    /// H42's gate: the list loaded (a build without it keeps today's sheet).
    public var available: Bool { !catalogue.isEmpty }
    /// H44: Continue also needs a filament when Flexible is chosen; always true otherwise.
    public var canContinue: Bool { !on || materialID != nil }

    public var material: FlexMaterialInfo? { catalogue.first { $0.id == materialID } }

    /// The Model card's order (FlexibleStageModel.loadCatalogue's sort).
    nonisolated static func ordered(_ c: [FlexMaterialInfo]) -> [FlexMaterialInfo] {
        c.sorted {
            ($0.noPrediction == nil) != ($1.noPrediction == nil) ? $0.noPrediction == nil : $0.displayName < $1.displayName
        }
    }

    // MARK: the three segments

    public enum Segment: Hashable { case filament, resin, flexible }

    static let flexibleTitle = "Flexible"

    var segments: [SegmentedGlass<Segment>.Segment] {
        var out: [SegmentedGlass<Segment>.Segment] = [.init(.filament, ProcessKind.fdm.segmentTitle),
                                                      .init(.resin, ProcessKind.resin.segmentTitle)]
        if !Self.controlNoFlexibleTab { out.append(.init(.flexible, Self.flexibleTitle)) }
        return out
    }

    func selected(_ model: AppModel) -> Segment {
        on ? .flexible : (model.process == .fdm ? .filament : .resin)
    }

    /// A segment tapped. Filament and Resin write `model.process` exactly as today's two segments do (one assignment of the
    /// tapped value); Flexible writes `.fdm` (its Topology runs on the FDM material) and turns the draft on.
    func select(_ seg: Segment, _ model: AppModel) {
        switch seg {
        case .filament:
            if !Self.controlSegmentsKeepFlexible { on = false }
            model.process = .fdm
        case .resin:
            if !Self.controlSegmentsKeepFlexible { on = false }
            model.process = .resin
        case .flexible:
            on = true
            model.process = .fdm
        }
    }

    // MARK: Continue (H44)

    /// Today's Continue, then the new project becomes a new Flexible setup (nothing read in from Topology, his Img7) with the
    /// picked filament, saved, and the workspace asked to open on the Flexible Lattice stage once.
    public func continueFlexible(_ model: AppModel) {
        guard let id = materialID else { return }
        if model.process != .fdm { model.process = .fdm }
        let before = model.project.map { ObjectIdentifier($0) }
        model.continueToWorkspace()
        guard let p = model.project, ObjectIdentifier(p) != before, model.screen == .workspace else { return }
        p.lattice.flexible = .newSetup(materialID: id)
        model.persistCurrentProject()
        FlexibleNewProject.requestLatticeStage(for: p.id)
    }

    // MARK: the dropdown's lines

    /// A menu line: the FULL name (the sheet's field is ~476 pt, wider than the Model card's 400 pt row) and whether core
    /// has squish data for it.
    static func menuLine(_ m: FlexMaterialInfo) -> String {
        m.displayName + (m.noPrediction == nil ? " · squish data" : " · no squish data")
    }
    static let menuLabel = "Flexible filament"
}

/// The one-shot landing: New TopOpt's Flexible tab asks; the workspace of THAT project takes it once (H45).
@MainActor
public enum FlexibleNewProject {
    private static var pending: UUID?
    public static func requestLatticeStage(for id: UUID) { pending = id }
    /// True once, for the project that asked; false for any other (and afterwards).
    public static func takeLatticeStage(for id: UUID) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }
}

/// H42's picker: today's segmented control with [Flexible] beside Filament and Resin.
struct FlexibleImportProcessPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var draft: FlexibleImportDraft

    var body: some View {
        SegmentedGlass(draft.segments, selection: Binding(get: { draft.selected(model) }, set: { draft.select($0, model) }))
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["importProcessPicker": g.frame(in: .global)])
            }.allowsHitTesting(false))
    }
}

/// H43's dropdown: the flexible filaments, styled as today's material dropdown.
struct FlexibleImportFilamentMenu: View {
    @ObservedObject var draft: FlexibleImportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(FlexibleImportDraft.menuLabel)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
            Menu {
                ForEach(draft.catalogue) { c in
                    Button(FlexibleImportDraft.menuLine(c)) { draft.materialID = c.id }
                }
            } label: {
                HStack {
                    Text(draft.material?.displayName ?? "—")
                        .dsStyle(DS.TypeScale.body)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // the field keeps today's height: switching tabs never moves the sheet
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
            .accessibilityIdentifier("import-flexible-filament-menu")
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["importFlexibleMenu": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }
}
