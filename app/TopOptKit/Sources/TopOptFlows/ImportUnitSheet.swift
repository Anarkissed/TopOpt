// ImportUnitSheet.swift — the mesh unit question, and the refusal sheet
// (handoff 134).
//
// Both are thin renderings of the pure models in ImportInspection.swift: every
// string and every decision is computed there and tested headlessly, so these
// views hold layout only.

import SwiftUI
import TopOptDesign

/// "What are these numbers in?" — asked once, for a mesh file, before import.
///
/// An STL stores bare coordinates with no unit anywhere in the format, and the
/// core's 3MF reader does not read the package's unit attribute either. Guessing
/// wrong is a 25.4x error in every force, mass and print parameter downstream,
/// so the app asks — with the measured size, which usually makes the answer
/// obvious at a glance.
public struct ImportUnitSheet: View {
    @ObservedObject var model: AppModel
    let prompt: ImportUnitPrompt
    @State private var choice: PartUnit

    public init(model: AppModel, prompt: ImportUnitPrompt) {
        self.model = model
        self.prompt = prompt
        _choice = State(initialValue: prompt.suggestedUnit)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What size is this model?").dsStyle(DS.TypeScale.title)
            Text("“\(prompt.fileName)” doesn’t say what unit its numbers are in — "
               + "mesh files don’t carry one.")
                .dsStyle(DS.TypeScale.subhead)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            SegmentedGlass(PartUnit.allCases.map { .init($0, $0.title) },
                           selection: $choice)
                .padding(.top, DS.Space.xl2)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "ruler")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                    Text(prompt.sizeHint)
                        .dsStyle(DS.TypeScale.caption)
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let rec = prompt.recommendation {
                    HStack(alignment: .top, spacing: DS.Space.xs) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                        Text(rec)
                            .dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("As \(choice.title.lowercased()), this part is "
                   + "\(ImportUnitPrompt.format(prompt.sizeMM(as: choice))) mm across.")
                    .dsStyle(DS.TypeScale.caption)
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.top, DS.Space.xxs)
            }
            .padding(.top, DS.Space.l)

            HStack(spacing: DS.Space.m) {
                Spacer()
                PillButton("Cancel", style: .secondary) { model.cancelUnitPrompt() }
                PillButton("Import", style: .primary, systemImage: "arrow.down.circle") {
                    model.resolveUnits(choice)
                }
            }
            .padding(.top, DS.Space.xl4)
        }
        .padding(DS.Space.xl6)
        .frame(width: 520, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}

/// The refusal sheet: why a mesh can't be used, and what to do about it.
///
/// Deliberately a SHEET and not a toast. A refusal is the end of the user's
/// attempt — it deserves the room to say what is wrong in their terms, name the
/// scope honestly, and point somewhere useful. The core's own diagnostic is
/// kept verbatim at the bottom rather than replaced, so a technical user can
/// see exactly what was measured.
public struct ImportRefusalSheet: View {
    @ObservedObject var model: AppModel
    let refusal: ImportRefusal

    public init(model: AppModel, refusal: ImportRefusal) {
        self.model = model
        self.refusal = refusal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(DS.Color.warning.color)
                Text(refusal.title).dsStyle(DS.TypeScale.title)
            }
            Text("“\(refusal.fileName)”")
                .dsStyle(DS.TypeScale.subhead)
                .foregroundStyle(DS.Color.textTertiary.color)
                .lineLimit(1)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: DS.Space.ml) {
                ForEach(Array(refusal.reasons.enumerated()), id: \.offset) { _, reason in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason.headline)
                            .dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(reason.detail)
                            .dsStyle(DS.TypeScale.caption)
                            .foregroundStyle(DS.Color.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, DS.Space.xl2)

            if !refusal.suggestions.isEmpty {
                Text("WHAT YOU CAN DO")
                    .dsStyle(DS.TypeScale.overline)
                    .foregroundStyle(DS.Color.textQuaternary.color)
                    .padding(.top, DS.Space.xl2)
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(Array(refusal.suggestions.enumerated()), id: \.offset) { _, s in
                        HStack(alignment: .top, spacing: DS.Space.xs) {
                            Text("•").dsStyle(DS.TypeScale.caption)
                                .foregroundStyle(DS.Color.textTertiary.color)
                            Text(s).dsStyle(DS.TypeScale.caption)
                                .foregroundStyle(DS.Color.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, DS.Space.sm)
            }

            Text(refusal.scopeNote)
                .dsStyle(DS.TypeScale.caption2)
                .foregroundStyle(DS.Color.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xl2)

            HStack(spacing: DS.Space.m) {
                Spacer()
                PillButton("Choose another file", style: .primary,
                           systemImage: "folder") { model.dismissRefusal() }
            }
            .padding(.top, DS.Space.xl4)
        }
        .padding(DS.Space.xl6)
        .frame(width: 560, alignment: .leading)
        .foregroundStyle(DS.Color.textPrimary.color)
    }
}

#Preview("ImportUnitSheet") {
    let m = AppModel(materialsPath: nil)
    return ZStack {
        DS.Color.background.color.ignoresSafeArea()
        GlassSheet {
            ImportUnitSheet(model: m,
                            prompt: ImportUnitPrompt(fileName: "bracket.stl",
                                                     largestDimension: 4.72))
        }
    }
}
